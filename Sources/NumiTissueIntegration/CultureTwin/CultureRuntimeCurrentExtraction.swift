import Foundation
import NumiTissueCore
import NumiTissueRuntime

/// Geometry uses stable compartment IDs (plus an optional checked namespace offset), not pool
/// indices. Topology migration must rebuild this mapping and the associated lead-field identity.
public struct CultureRuntimeSourceMap: Sendable, Hashable, Codable {
    public var sourceIDByCompartmentIndex: [UInt64]
    public var sourceGeometryByCompartmentIndex: [CultureCurrentSource]
    public init(sourceIDByCompartmentIndex: [UInt64], sourceGeometryByCompartmentIndex: [CultureCurrentSource]) {
        self.sourceIDByCompartmentIndex = sourceIDByCompartmentIndex
        self.sourceGeometryByCompartmentIndex = sourceGeometryByCompartmentIndex
    }
    public func validated(compartmentCount: Int) throws -> Self {
        guard compartmentCount > 0, sourceIDByCompartmentIndex.count == compartmentCount,
              sourceGeometryByCompartmentIndex.count == compartmentCount,
              Set(sourceIDByCompartmentIndex).count == compartmentCount else {
            throw CultureTwinError.invalid("runtime source-map dimensions")
        }
        for (index, source) in sourceGeometryByCompartmentIndex.enumerated() {
            _ = try source.validated()
            guard source.id == sourceIDByCompartmentIndex[index] else { throw CultureTwinError.invalid("source identity") }
        }
        return self
    }
    public static func from(state: TissueRuntimeState, sourceIDBase: UInt64 = 1) throws -> Self {
        guard !state.compartments.isEmpty, sourceIDBase > 0,
              Set(state.compartments.map(\.id)).count == state.compartments.count else {
            throw CultureTwinError.invalid("compartment identity or namespace")
        }
        var segments: [Int: RuntimeSegmentState] = [:]
        for segment in state.segments where segment.compartmentIndex != RuntimeCompartmentState.invalidIndex {
            let index = Int(segment.compartmentIndex)
            guard index < state.compartments.count, segments[index] == nil else {
                throw CultureTwinError.invalid("invalid or ambiguous compartment geometry")
            }
            segments[index] = segment
        }
        var geometry: [CultureCurrentSource] = []
        geometry.reserveCapacity(state.compartments.count)
        for index in state.compartments.indices {
            guard let segment = segments[index], segment.radiusMicrometers.isFinite,
                  segment.radiusMicrometers > 0 else { throw CultureTwinError.invalid("missing source geometry or radius") }
            let sum = state.compartments[index].id.rawValue.addingReportingOverflow(sourceIDBase - 1)
            guard !sum.overflow else { throw CultureTwinError.invalid("source identifier overflow") }
            let start = SIMD3<Double>(Double(segment.start.x), Double(segment.start.y), Double(segment.start.z))
            let end = SIMD3<Double>(Double(segment.end.x), Double(segment.end.y), Double(segment.end.z))
            let length = CultureGeometry.length(end - start)
            geometry.append(try CultureCurrentSource(id: sum.partialValue,
                geometry: length > 1e-9 ? .uniformLine : .point,
                startMicrometers: start, endMicrometers: length > 1e-9 ? end : start,
                radiusMicrometers: Double(segment.radiusMicrometers)).validated())
        }
        return try Self(sourceIDByCompartmentIndex: geometry.map(\.id),
                        sourceGeometryByCompartmentIndex: geometry).validated(compartmentCount: state.compartments.count)
    }
}

public struct CultureMembraneCurrentBalance: Sendable, Codable {
    public let totalOutwardAmperes: [Double]
    public let capacitiveOutwardAmperes: [Double]
    public let ionicAndSynapticOutwardAmperes: [Double]
}

public enum CultureRuntimeCurrentExtractor {
    /// KCL: C*dV/dt + I_ionic,out + I_syn,out = I_injected,in + I_axial,in.
    /// Extracellular sources use TOTAL membrane current INCLUDING capacitance:
    /// I_total,out = I_injected,in + I_axial,in. Subtracting C*dV/dt returns the ionic/synaptic
    /// component, not the total. nF*mV/ms = nA; uS*mV = nA; output is converted to amperes.
    /// Current-clamp experiments also need their explicit extracellular return electrode source.
    public static func totalOutwardTransmembraneCurrentsAmperes(state: TissueRuntimeState,
                                                               dtMilliseconds: Double) throws -> [Double] {
        try balance(state: state, dtMilliseconds: dtMilliseconds).totalOutwardAmperes
    }
    public static func balance(state: TissueRuntimeState, dtMilliseconds: Double) throws -> CultureMembraneCurrentBalance {
        guard dtMilliseconds.isFinite, dtMilliseconds > 0, !state.compartments.isEmpty else {
            throw CultureTwinError.invalid("transmembrane-current interval or state")
        }
        let cells = state.compartments, count = state.compartments.count
        var children = [[Int]](repeating: [], count: count), roots: [Int] = []
        for (i, c) in cells.enumerated() {
            guard c.voltageMillivolts.isFinite, c.previousVoltageMillivolts.isFinite,
                  c.capacitanceNanofarads.isFinite, c.capacitanceNanofarads >= 0,
                  c.injectedCurrentNanoamps.isFinite, c.axialConductanceMicrosiemens.isFinite,
                  c.axialConductanceMicrosiemens >= 0 else { throw CultureTwinError.invalid("compartment electrical state") }
            if c.parentIndex == RuntimeCompartmentState.invalidIndex { roots.append(i) }
            else {
                let parent = Int(c.parentIndex)
                guard parent < count, parent != i, cells[parent].neuronIndex == c.neuronIndex else {
                    throw CultureTwinError.invalid("compartment cable topology")
                }
                children[parent].append(i)
            }
        }
        var visited = 0, stack = roots
        while let i = stack.popLast() { visited += 1; stack.append(contentsOf: children[i]) }
        guard visited == count else { throw CultureTwinError.invalid("cyclic compartment graph") }
        var axial = [Double](repeating: 0, count: count)
        // Evaluate each edge once, with equal and opposite contributions.
        for (i, c) in cells.enumerated() where c.parentIndex != RuntimeCompartmentState.invalidIndex {
            let parent = Int(c.parentIndex)
            let flux = Double(c.axialConductanceMicrosiemens) *
                (Double(cells[parent].voltageMillivolts) - Double(c.voltageMillivolts))
            axial[i] += flux; axial[parent] -= flux
        }
        var total: [Double] = [], cap: [Double] = [], ionic: [Double] = []
        total.reserveCapacity(count); cap.reserveCapacity(count); ionic.reserveCapacity(count)
        for (i, c) in cells.enumerated() {
            let all = Double(c.injectedCurrentNanoamps) + axial[i]
            let capacitive = Double(c.capacitanceNanofarads) *
                (Double(c.voltageMillivolts) - Double(c.previousVoltageMillivolts)) / dtMilliseconds
            let channels = all - capacitive
            guard all.isFinite, capacitive.isFinite, channels.isFinite else {
                throw CultureTwinError.invalid("membrane current overflow")
            }
            total.append(all * 1e-9); cap.append(capacitive * 1e-9); ionic.append(channels * 1e-9)
        }
        return .init(totalOutwardAmperes: total, capacitiveOutwardAmperes: cap,
                     ionicAndSynapticOutwardAmperes: ionic)
    }
}
