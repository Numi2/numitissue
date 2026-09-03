import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct Rallpack1Configuration: Sendable, Hashable, Codable {
    public var axialResistivityOhmMeter: Double
    public var membraneResistivityOhmMeterSquared: Double
    public var membraneCapacitanceFaradPerMeterSquared: Double
    public var reversalMillivolts: Double
    public var diameterMicrometers: Double
    public var lengthMicrometers: Double
    public var injectedCurrentNanoamps: Double
    public var compartmentCount: Int
    public var integrationStepMilliseconds: Double
    public var sampleMilliseconds: Double
    public var durationMilliseconds: Double
    public var measurementProportions: [Double]

    public init(
        axialResistivityOhmMeter: Double = 1,
        membraneResistivityOhmMeterSquared: Double = 4,
        membraneCapacitanceFaradPerMeterSquared: Double = 0.01,
        reversalMillivolts: Double = -65,
        diameterMicrometers: Double = 1,
        lengthMicrometers: Double = 1_000,
        injectedCurrentNanoamps: Double = 0.1,
        compartmentCount: Int = 1_000,
        integrationStepMilliseconds: Double = 0.01,
        sampleMilliseconds: Double = 0.01,
        durationMilliseconds: Double = 250,
        measurementProportions: [Double] = [0, 1]
    ) {
        self.axialResistivityOhmMeter = axialResistivityOhmMeter
        self.membraneResistivityOhmMeterSquared = membraneResistivityOhmMeterSquared
        self.membraneCapacitanceFaradPerMeterSquared =
            membraneCapacitanceFaradPerMeterSquared
        self.reversalMillivolts = reversalMillivolts
        self.diameterMicrometers = diameterMicrometers
        self.lengthMicrometers = lengthMicrometers
        self.injectedCurrentNanoamps = injectedCurrentNanoamps
        self.compartmentCount = compartmentCount
        self.integrationStepMilliseconds = integrationStepMilliseconds
        self.sampleMilliseconds = sampleMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.measurementProportions = measurementProportions
    }

    public func validated() throws -> Self {
        let positive = [
            axialResistivityOhmMeter,
            membraneResistivityOhmMeterSquared,
            membraneCapacitanceFaradPerMeterSquared,
            diameterMicrometers,
            lengthMicrometers,
            integrationStepMilliseconds,
            sampleMilliseconds,
            durationMilliseconds
        ]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }),
              reversalMillivolts.isFinite,
              injectedCurrentNanoamps.isFinite,
              compartmentCount > 1,
              measurementProportions.count == 2,
              measurementProportions.allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }),
              sampleMilliseconds >= integrationStepMilliseconds else {
            throw Rallpack1Error.invalidConfiguration
        }
        _ = try integralCount(
            durationMilliseconds / integrationStepMilliseconds,
            name: "duration/integration step"
        )
        _ = try integralCount(
            sampleMilliseconds / integrationStepMilliseconds,
            name: "sample/integration step"
        )
        return self
    }

    fileprivate func integralCount(_ value: Double, name: String) throws -> Int {
        guard value.isFinite, value > 0, value <= Double(Int.max) else {
            throw Rallpack1Error.nonIntegralGrid(name)
        }
        let rounded = value.rounded()
        guard abs(value - rounded) <= 1e-10 * max(1, abs(value)) else {
            throw Rallpack1Error.nonIntegralGrid(name)
        }
        return Int(rounded)
    }
}

public struct Rallpack1Trace: Sendable, Hashable, Codable {
    public var timeMilliseconds: [Double]
    public var proximalVoltageMillivolts: [Double]
    public var distalVoltageMillivolts: [Double]

    public init(
        timeMilliseconds: [Double],
        proximalVoltageMillivolts: [Double],
        distalVoltageMillivolts: [Double]
    ) {
        self.timeMilliseconds = timeMilliseconds
        self.proximalVoltageMillivolts = proximalVoltageMillivolts
        self.distalVoltageMillivolts = distalVoltageMillivolts
    }

    public func validated() throws -> Self {
        guard !timeMilliseconds.isEmpty,
              timeMilliseconds.count == proximalVoltageMillivolts.count,
              timeMilliseconds.count == distalVoltageMillivolts.count,
              timeMilliseconds.allSatisfy(\.isFinite),
              proximalVoltageMillivolts.allSatisfy(\.isFinite),
              distalVoltageMillivolts.allSatisfy(\.isFinite) else {
            throw Rallpack1Error.invalidTrace
        }
        for index in timeMilliseconds.indices.dropFirst()
            where timeMilliseconds[index] <= timeMilliseconds[index - 1] {
            throw Rallpack1Error.invalidTrace
        }
        return self
    }
}

public struct Rallpack1Comparison: Sendable, Hashable, Codable {
    public var proximalRelativeRMSError: Double
    public var distalRelativeRMSError: Double
    public var tolerance: Double

    public init(
        proximalRelativeRMSError: Double,
        distalRelativeRMSError: Double,
        tolerance: Double
    ) {
        self.proximalRelativeRMSError = proximalRelativeRMSError
        self.distalRelativeRMSError = distalRelativeRMSError
        self.tolerance = tolerance
    }

    public var passed: Bool {
        proximalRelativeRMSError < tolerance &&
            distalRelativeRMSError < tolerance
    }
}

public enum Rallpack1 {
    public static func analyticalTrace(
        configuration source: Rallpack1Configuration = Rallpack1Configuration(),
        seriesTolerance: Double = 1e-8
    ) throws -> Rallpack1Trace {
        let configuration = try source.validated()
        guard seriesTolerance.isFinite, seriesTolerance > 0 else {
            throw Rallpack1Error.invalidSeriesTolerance
        }
        let sampleCount = try configuration.integralCount(
            configuration.durationMilliseconds /
                configuration.sampleMilliseconds,
            name: "duration/sample step"
        )
        let times = (0...sampleCount).map {
            Double($0) * configuration.sampleMilliseconds
        }
        let proximal = try times.map {
            try membraneVoltage(
                timeMilliseconds: $0,
                proportion: configuration.measurementProportions[0],
                configuration: configuration,
                tolerance: seriesTolerance
            )
        }
        let distal = try times.map {
            try membraneVoltage(
                timeMilliseconds: $0,
                proportion: configuration.measurementProportions[1],
                configuration: configuration,
                tolerance: seriesTolerance
            )
        }
        return try Rallpack1Trace(
            timeMilliseconds: times,
            proximalVoltageMillivolts: proximal,
            distalVoltageMillivolts: distal
        ).validated()
    }

    public static func numiTissueTrace(
        configuration source: Rallpack1Configuration = Rallpack1Configuration()
    ) throws -> Rallpack1Trace {
        let configuration = try source.validated()
        var state = try makeRuntimeState(configuration: configuration)
        let plan = try ReferenceCableTreePlan(compartments: state.compartments)
        let totalSteps = try configuration.integralCount(
            configuration.durationMilliseconds /
                configuration.integrationStepMilliseconds,
            name: "duration/integration step"
        )
        let sampleStride = try configuration.integralCount(
            configuration.sampleMilliseconds /
                configuration.integrationStepMilliseconds,
            name: "sample/integration step"
        )
        var times = [0.0]
        var proximal = [configuration.reversalMillivolts]
        var distal = [configuration.reversalMillivolts]
        let expectedSamples = totalSteps / sampleStride + 1
        times.reserveCapacity(expectedSamples)
        proximal.reserveCapacity(expectedSamples)
        distal.reserveCapacity(expectedSamples)

        for step in 1...totalSteps {
            try plan.solve(
                state: &state,
                dtMilliseconds: Float(
                    configuration.integrationStepMilliseconds
                )
            )
            if step.isMultiple(of: sampleStride) {
                times.append(
                    Double(step) *
                        configuration.integrationStepMilliseconds
                )
                proximal.append(
                    Double(state.compartments[0].voltageMillivolts)
                )
                distal.append(
                    Double(
                        state.compartments[
                            configuration.compartmentCount - 1
                        ].voltageMillivolts
                    )
                )
            }
        }
        return try Rallpack1Trace(
            timeMilliseconds: times,
            proximalVoltageMillivolts: proximal,
            distalVoltageMillivolts: distal
        ).validated()
    }

    public static func compare(
        candidate sourceCandidate: Rallpack1Trace,
        reference sourceReference: Rallpack1Trace,
        relativeRMSTolerance: Double = 0.001
    ) throws -> Rallpack1Comparison {
        let candidate = try sourceCandidate.validated()
        let reference = try sourceReference.validated()
        guard relativeRMSTolerance.isFinite,
              relativeRMSTolerance >= 0,
              candidate.timeMilliseconds == reference.timeMilliseconds else {
            throw Rallpack1Error.incompatibleTraces
        }
        return Rallpack1Comparison(
            proximalRelativeRMSError: relativeRMSError(
                candidate.proximalVoltageMillivolts,
                reference.proximalVoltageMillivolts
            ),
            distalRelativeRMSError: relativeRMSError(
                candidate.distalVoltageMillivolts,
                reference.distalVoltageMillivolts
            ),
            tolerance: relativeRMSTolerance
        )
    }

    public static func makeRuntimeState(
        configuration source: Rallpack1Configuration
    ) throws -> TissueRuntimeState {
        let configuration = try source.validated()
        let count = configuration.compartmentCount
        let segmentLengthMeters =
            configuration.lengthMicrometers * 1e-6 / Double(count)
        let radiusMeters = configuration.diameterMicrometers * 0.5e-6
        let membraneAreaMetersSquared =
            2 * Double.pi * radiusMeters * segmentLengthMeters
        let capacitanceNanofarads =
            configuration.membraneCapacitanceFaradPerMeterSquared *
                membraneAreaMetersSquared * 1e9
        let membraneConductanceMicrosiemens =
            membraneAreaMetersSquared /
                configuration.membraneResistivityOhmMeterSquared * 1e6
        let axialAreaMetersSquared = Double.pi * radiusMeters * radiusMeters
        let axialConductanceMicrosiemens =
            axialAreaMetersSquared /
                (
                    configuration.axialResistivityOhmMeter *
                    segmentLengthMeters
                ) * 1e6

        guard [
            capacitanceNanofarads,
            membraneConductanceMicrosiemens,
            axialConductanceMicrosiemens
        ].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw Rallpack1Error.invalidDiscretization
        }

        var state = TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 1,
                cells: 0,
                segments: 0,
                compartments: count,
                synapses: 0,
                events: 65_536,
                fieldValues: 0,
                microdomains: 0,
                molecularSpecies: 0
            )
        )
        var tile = TileRuntimeState(
            id: TileID(rawValue: 1),
            coordinate: TileCoordinate(x: 0, y: 0, z: 0)
        )
        tile.compartmentRange = RuntimeRange(
            lowerBound: 0,
            count: UInt32(count)
        )
        state.tiles = [tile]
        state.compartments.reserveCapacity(count)
        state.mechanismState = Array(
            repeating: 0,
            count: count * ReferenceCableTreeSolver.mechanismStride
        )

        for index in 0..<count {
            state.compartments.append(
                RuntimeCompartmentState(
                    id: CompartmentID(rawValue: UInt64(index + 1)),
                    neuronIndex: 0,
                    parentIndex: index == 0
                        ? RuntimeCompartmentState.invalidIndex
                        : UInt32(index - 1),
                    voltageMillivolts: Float(
                        configuration.reversalMillivolts
                    ),
                    previousVoltageMillivolts: Float(
                        configuration.reversalMillivolts
                    ),
                    capacitanceNanofarads: Float(capacitanceNanofarads),
                    axialConductanceMicrosiemens: index == 0
                        ? 0
                        : Float(axialConductanceMicrosiemens),
                    injectedCurrentNanoamps: index == 0
                        ? Float(configuration.injectedCurrentNanoamps)
                        : 0
                )
            )
            let base = index * ReferenceCableTreeSolver.mechanismStride
            state.mechanismState[base + 10] =
                Float(membraneConductanceMicrosiemens)
            state.mechanismState[base + 11] = Float(
                membraneConductanceMicrosiemens *
                    configuration.reversalMillivolts
            )
        }
        return state
    }

    private static func membraneVoltage(
        timeMilliseconds: Double,
        proportion: Double,
        configuration: Rallpack1Configuration,
        tolerance: Double
    ) throws -> Double {
        guard timeMilliseconds.isFinite,
              timeMilliseconds >= 0,
              proportion.isFinite,
              (0...1).contains(proportion) else {
            throw Rallpack1Error.invalidTimeOrPosition
        }
        let radiusMicrometers = configuration.diameterMicrometers / 2
        let lambdaMicrometers = sqrt(
            configuration.membraneResistivityOhmMeterSquared *
                radiusMicrometers /
                (2 * configuration.axialResistivityOhmMeter)
        ) * 1_000
        let tauSeconds =
            configuration.membraneResistivityOhmMeterSquared *
                configuration.membraneCapacitanceFaradPerMeterSquared
        let normalizedLength =
            configuration.lengthMicrometers / lambdaMicrometers
        let electricGradient =
            -configuration.injectedCurrentNanoamps *
                configuration.axialResistivityOhmMeter /
                (
                    Double.pi *
                    radiusMicrometers *
                    radiusMicrometers
                )
        let x = (
            configuration.lengthMicrometers -
            proportion * configuration.lengthMicrometers
        ) / lambdaMicrometers
        let normalizedTime = timeMilliseconds * 0.001 / tauSeconds
        let response = try cableResponse(
            x: x,
            time: normalizedTime,
            normalizedLength: normalizedLength,
            tolerance: tolerance
        )
        return configuration.reversalMillivolts -
            lambdaMicrometers * electricGradient * response
    }

    private static func cableResponse(
        x: Double,
        time: Double,
        normalizedLength: Double,
        tolerance: Double
    ) throws -> Double {
        guard time > 0 else { return 0 }
        let infiniteTime = cosh(x) / sinh(normalizedLength)
        var accumulation = exp(-time) / 2
        let relativeTarget = tolerance * time * normalizedLength
        var sign = 1.0

        for term in 1...1_000_000 {
            let a = Double(term) * Double.pi / normalizedLength
            let lambda = 1 + a * a
            let q = exp(-lambda * time) / lambda
            sign = -sign
            if q < sqrt(lambda) * relativeTarget {
                return infiniteTime -
                    2 * accumulation / normalizedLength
            }
            accumulation += sign * cos(a * x) * q
        }
        throw Rallpack1Error.seriesDidNotConverge
    }

    private static func relativeRMSError(
        _ candidate: [Double],
        _ reference: [Double]
    ) -> Double {
        let squared = zip(candidate, reference).reduce(0.0) {
            $0 + ($1.0 - $1.1) * ($1.0 - $1.1)
        }
        let rms = sqrt(squared / Double(reference.count))
        let normalizer = max(
            reference.map(abs).max() ?? 0,
            Double.leastNonzeroMagnitude
        )
        return rms / normalizer
    }
}

public enum Rallpack1Error: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidSeriesTolerance
    case nonIntegralGrid(String)
    case invalidTrace
    case incompatibleTraces
    case invalidDiscretization
    case invalidTimeOrPosition
    case seriesDidNotConverge

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Rallpack 1 configuration is invalid."
        case .invalidSeriesTolerance:
            return "Rallpack 1 series tolerance must be finite and positive."
        case .nonIntegralGrid(let name):
            return "Rallpack 1 time grid \(name) is not integral."
        case .invalidTrace:
            return "Rallpack 1 trace is invalid."
        case .incompatibleTraces:
            return "Rallpack 1 candidate and reference traces are incompatible."
        case .invalidDiscretization:
            return "Rallpack 1 discretization produced invalid lumped parameters."
        case .invalidTimeOrPosition:
            return "Rallpack 1 time or measurement position is invalid."
        case .seriesDidNotConverge:
            return "Rallpack 1 analytical series did not converge."
        }
    }
}
