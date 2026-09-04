import Foundation
import NumiTissueCore
import NumiTissueRuntime

/// Maps runtime compartments onto extracellular current sources and derives the net outward
/// transmembrane current from discrete compartment charge balance.
///
/// Sign convention:
/// - positive axial current is positive *into* the compartment;
/// - positive injected current is positive *into* the compartment;
/// - positive returned transmembrane current is positive *outward* into extracellular space.
///
/// For compartment i, KCL gives:
///   I_mem,out = I_injected + I_axial,in - C dV/dt
/// where synaptic conductance current is already part of the membrane current and therefore is
/// not added independently here. Units are converted from nA/nF/mV/ms to amperes.
public struct CultureRuntimeSourceMap: Sendable, Hashable, Codable {
    public var sourceIDByCompartmentIndex: [UInt64]
    public var sourceGeometryByCompartmentIndex: [CultureCurrentSource]

    public init(
        sourceIDByCompartmentIndex: [UInt64],
        sourceGeometryByCompartmentIndex: [CultureCurrentSource]
    ) {
        self.sourceIDByCompartmentIndex = sourceIDByCompartmentIndex
        self.sourceGeometryByCompartmentIndex = sourceGeometryByCompartmentIndex
    }

    public func validated(compartmentCount: Int) throws -> Self {
        guard compartmentCount > 0,
              sourceIDByCompartmentIndex.count == compartmentCount,
              sourceGeometryByCompartmentIndex.count == compartmentCount,
              Set(sourceIDByCompartmentIndex).count == compartmentCount else {
            throw CultureTwinError.invalid("runtime source-map dimensions")
        }
        for (index, source) in sourceGeometryByCompartmentIndex.enumerated() {
            _ = try source.validated()
            guard source.id == sourceIDByCompartmentIndex[index] else {
                throw CultureTwinError.invalid("runtime source-map identity")
            }
        }
        return self
    }

    public static func from(
        state: TissueRuntimeState,
        sourceIDBase: UInt64 = 1
    ) throws -> Self {
        guard !state.compartments.isEmpty else {
            throw CultureTwinError.invalid("runtime has no compartments")
        }
        var segmentByCompartment: [Int: RuntimeSegmentState] = [:]
        for segment in state.segments where segment.compartmentIndex != RuntimeCompartmentState.invalidIndex {
            let index = Int(segment.compartmentIndex)
            guard index < state.compartments.count else {
                throw CultureTwinError.invalid("segment compartment index")
            }
            if segmentByCompartment.updateValue(segment, forKey: index) != nil {
                throw CultureTwinError.invalid("multiple neurite segments map to one compartment")
            }
        }
        var ids: [UInt64] = []
        var geometry: [CultureCurrentSource] = []
        ids.reserveCapacity(state.compartments.count)
        geometry.reserveCapacity(state.compartments.count)
        for index in state.compartments.indices {
            let id = sourceIDBase &+ UInt64(index)
            guard let segment = segmentByCompartment[index] else {
                throw CultureTwinError.invalid("compartment lacks segment geometry")
            }
            let start = SIMD3<Double>(Double(segment.start.x), Double(segment.start.y), Double(segment.start.z))
            let end = SIMD3<Double>(Double(segment.end.x), Double(segment.end.y), Double(segment.end.z))
            let length = CultureGeometry.length(end - start)
            let source = CultureCurrentSource(
                id: id,
                geometry: length > 1e-9 ? .uniformLine : .point,
                startMicrometers: start,
                endMicrometers: length > 1e-9 ? end : start,
                radiusMicrometers: max(Double(segment.radiusMicrometers), 1e-6)
            )
            ids.append(id)
            geometry.append(try source.validated())
        }
        return try Self(
            sourceIDByCompartmentIndex: ids,
            sourceGeometryByCompartmentIndex: geometry
        ).validated(compartmentCount: state.compartments.count)
    }
}

public enum CultureRuntimeCurrentExtractor {
    public static func totalOutwardTransmembraneCurrentsAmperes(
        state: TissueRuntimeState,
        dtMilliseconds: Double
    ) throws -> [Double] {
        guard dtMilliseconds.isFinite, dtMilliseconds > 0,
              !state.compartments.isEmpty else {
            throw CultureTwinError.invalid("transmembrane-current extraction interval")
        }
        let count = state.compartments.count
        var children: [[Int]] = Array(repeating: [], count: count)
        for (index, compartment) in state.compartments.enumerated() {
            if compartment.parentIndex != RuntimeCompartmentState.invalidIndex {
                let parent = Int(compartment.parentIndex)
                guard parent >= 0, parent < count, parent != index else {
                    throw CultureTwinError.invalid("compartment parent topology")
                }
                children[parent].append(index)
            }
        }
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let compartment = state.compartments[index]
            let voltage = Double(compartment.voltageMillivolts)
            let previous = Double(compartment.previousVoltageMillivolts)
            let capacitance = Double(compartment.capacitanceNanofarads)
            let injected = Double(compartment.injectedCurrentNanoamps)
            guard voltage.isFinite, previous.isFinite, capacitance.isFinite, capacitance >= 0,
                  injected.isFinite else {
                throw CultureTwinError.invalid("nonfinite compartment electrical state")
            }
            var axialIntoNanoamps = 0.0
            if compartment.parentIndex != RuntimeCompartmentState.invalidIndex {
                let parent = state.compartments[Int(compartment.parentIndex)]
                let g = Double(compartment.axialConductanceMicrosiemens)
                guard g.isFinite, g >= 0 else {
                    throw CultureTwinError.invalid("parent axial conductance")
                }
                // microSiemens * millivolts = nanoamps.
                axialIntoNanoamps += g * (Double(parent.voltageMillivolts) - voltage)
            }
            for childIndex in children[index] {
                let child = state.compartments[childIndex]
                let g = Double(child.axialConductanceMicrosiemens)
                guard g.isFinite, g >= 0 else {
                    throw CultureTwinError.invalid("child axial conductance")
                }
                axialIntoNanoamps += g * (Double(child.voltageMillivolts) - voltage)
            }
            // nF * mV / ms = nA.
            let capacitiveNanoamps = capacitance * (voltage - previous) / dtMilliseconds
            let outwardNanoamps = injected + axialIntoNanoamps - capacitiveNanoamps
            guard outwardNanoamps.isFinite else {
                throw CultureTwinError.invalid("transmembrane-current overflow")
            }
            result[index] = outwardNanoamps * 1e-9
        }
        return result
    }
}
