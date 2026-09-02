import Foundation

public struct WetwareElectrodeGeometry: Sendable, Hashable, Codable {
    public var id: UInt32
    public var areaSquareMicrometers: Double
    public var positionMicrometers: SIMD3<Double>
    public var impedanceOhmsAtOneKilohertz: Double?
    public var material: String?

    public init(
        id: UInt32,
        areaSquareMicrometers: Double,
        positionMicrometers: SIMD3<Double>,
        impedanceOhmsAtOneKilohertz: Double? = nil,
        material: String? = nil
    ) {
        self.id = id
        self.areaSquareMicrometers = areaSquareMicrometers
        self.positionMicrometers = positionMicrometers
        self.impedanceOhmsAtOneKilohertz = impedanceOhmsAtOneKilohertz
        self.material = material
    }

    public func validated() throws -> Self {
        guard areaSquareMicrometers.isFinite,
              areaSquareMicrometers > 0,
              positionMicrometers.x.isFinite,
              positionMicrometers.y.isFinite,
              positionMicrometers.z.isFinite,
              impedanceOhmsAtOneKilohertz?.isFinite != false,
              impedanceOhmsAtOneKilohertz.map({ $0 > 0 }) != false else {
            throw WetwareProtocolError.invalidElectrode(id)
        }
        return self
    }

    public var areaSquareCentimeters: Double {
        areaSquareMicrometers * 1e-8
    }
}

public struct WetwareBiphasicPulse: Sendable, Hashable, Codable {
    public var cathodicAmplitudeMicroamps: Double
    public var cathodicPhaseMicroseconds: Double
    public var interphaseGapMicroseconds: Double
    public var anodicAmplitudeMicroamps: Double
    public var anodicPhaseMicroseconds: Double

    public init(
        cathodicAmplitudeMicroamps: Double,
        cathodicPhaseMicroseconds: Double,
        interphaseGapMicroseconds: Double,
        anodicAmplitudeMicroamps: Double,
        anodicPhaseMicroseconds: Double
    ) {
        self.cathodicAmplitudeMicroamps = cathodicAmplitudeMicroamps
        self.cathodicPhaseMicroseconds = cathodicPhaseMicroseconds
        self.interphaseGapMicroseconds = interphaseGapMicroseconds
        self.anodicAmplitudeMicroamps = anodicAmplitudeMicroamps
        self.anodicPhaseMicroseconds = anodicPhaseMicroseconds
    }

    public static func chargeBalanced(
        amplitudeMicroamps: Double,
        phaseMicroseconds: Double,
        interphaseGapMicroseconds: Double = 50
    ) -> Self {
        Self(
            cathodicAmplitudeMicroamps: amplitudeMicroamps,
            cathodicPhaseMicroseconds: phaseMicroseconds,
            interphaseGapMicroseconds: interphaseGapMicroseconds,
            anodicAmplitudeMicroamps: amplitudeMicroamps,
            anodicPhaseMicroseconds: phaseMicroseconds
        )
    }

    public func validated() throws -> Self {
        let values = [
            cathodicAmplitudeMicroamps,
            cathodicPhaseMicroseconds,
            interphaseGapMicroseconds,
            anodicAmplitudeMicroamps,
            anodicPhaseMicroseconds
        ]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              cathodicAmplitudeMicroamps > 0,
              anodicAmplitudeMicroamps > 0,
              cathodicPhaseMicroseconds > 0,
              anodicPhaseMicroseconds > 0 else {
            throw WetwareProtocolError.invalidPulse
        }
        return self
    }

    public var cathodicChargeMicrocoulombs: Double {
        cathodicAmplitudeMicroamps * cathodicPhaseMicroseconds * 1e-6
    }

    public var anodicChargeMicrocoulombs: Double {
        anodicAmplitudeMicroamps * anodicPhaseMicroseconds * 1e-6
    }

    public var chargeImbalanceFraction: Double {
        let denominator = max(cathodicChargeMicrocoulombs, anodicChargeMicrocoulombs, 1e-15)
        return abs(cathodicChargeMicrocoulombs - anodicChargeMicrocoulombs) / denominator
    }

    public var totalPulseMicroseconds: Double {
        cathodicPhaseMicroseconds + interphaseGapMicroseconds + anodicPhaseMicroseconds
    }
}

public struct WetwareStimulationTrain: Sendable, Hashable, Codable {
    public var electrodeIDs: [UInt32]
    public var pulse: WetwareBiphasicPulse
    public var frequencyHertz: Double
    public var durationMilliseconds: Double
    public var onsetMilliseconds: Double
    public var jitterStandardDeviationMicroseconds: Double
    public var encodingChannel: String?
    public var metadata: [String: String]

    public init(
        electrodeIDs: [UInt32],
        pulse: WetwareBiphasicPulse,
        frequencyHertz: Double,
        durationMilliseconds: Double,
        onsetMilliseconds: Double = 0,
        jitterStandardDeviationMicroseconds: Double = 0,
        encodingChannel: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.electrodeIDs = electrodeIDs
        self.pulse = pulse
        self.frequencyHertz = frequencyHertz
        self.durationMilliseconds = durationMilliseconds
        self.onsetMilliseconds = onsetMilliseconds
        self.jitterStandardDeviationMicroseconds = jitterStandardDeviationMicroseconds
        self.encodingChannel = encodingChannel
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !electrodeIDs.isEmpty,
              Set(electrodeIDs).count == electrodeIDs.count,
              frequencyHertz.isFinite,
              frequencyHertz > 0,
              durationMilliseconds.isFinite,
              durationMilliseconds > 0,
              onsetMilliseconds.isFinite,
              onsetMilliseconds >= 0,
              jitterStandardDeviationMicroseconds.isFinite,
              jitterStandardDeviationMicroseconds >= 0 else {
            throw WetwareProtocolError.invalidTrain
        }
        _ = try pulse.validated()
        return self
    }

    public var dutyCycle: Double {
        frequencyHertz * pulse.totalPulseMicroseconds * 1e-6
    }

    public var nominalPulseCount: UInt64 {
        let value = floor(frequencyHertz * durationMilliseconds * 1e-3)
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value)
    }
}

public enum WetwareReadoutFeature: String, Sendable, Hashable, Codable, CaseIterable {
    case spikeCount
    case firingRate
    case firstSpikeLatency
    case interspikeInterval
    case burstRate
    case synchrony
    case localFieldPotentialPower
    case localFieldPotentialPhase
    case populationVector
}

public struct WetwareReadoutWindow: Sendable, Hashable, Codable {
    public var electrodeIDs: [UInt32]
    public var startMilliseconds: Double
    public var durationMilliseconds: Double
    public var feature: WetwareReadoutFeature
    public var lowerBandHertz: Double?
    public var upperBandHertz: Double?
    public var outputChannel: String

    public init(
        electrodeIDs: [UInt32],
        startMilliseconds: Double,
        durationMilliseconds: Double,
        feature: WetwareReadoutFeature,
        lowerBandHertz: Double? = nil,
        upperBandHertz: Double? = nil,
        outputChannel: String
    ) {
        self.electrodeIDs = electrodeIDs
        self.startMilliseconds = startMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.feature = feature
        self.lowerBandHertz = lowerBandHertz
        self.upperBandHertz = upperBandHertz
        self.outputChannel = outputChannel
    }

    public func validated() throws -> Self {
        guard !electrodeIDs.isEmpty,
              Set(electrodeIDs).count == electrodeIDs.count,
              startMilliseconds.isFinite,
              startMilliseconds >= 0,
              durationMilliseconds.isFinite,
              durationMilliseconds > 0,
              !outputChannel.isEmpty,
              lowerBandHertz?.isFinite != false,
              upperBandHertz?.isFinite != false else {
            throw WetwareProtocolError.invalidReadout(outputChannel)
        }
        if feature == .localFieldPotentialPower || feature == .localFieldPotentialPhase {
            guard let lowerBandHertz,
                  let upperBandHertz,
                  lowerBandHertz >= 0,
                  upperBandHertz > lowerBandHertz else {
                throw WetwareProtocolError.invalidReadout(outputChannel)
            }
        }
        return self
    }
}

public struct WetwareReinforcementRule: Sendable, Hashable, Codable {
    public enum Polarity: String, Sendable, Hashable, Codable {
        case reward
        case punishment
        case neutral
    }

    public var triggerMetric: String
    public var comparison: String
    public var threshold: Double
    public var latencyMilliseconds: Double
    public var trainIndex: Int
    public var polarity: Polarity

    public init(
        triggerMetric: String,
        comparison: String,
        threshold: Double,
        latencyMilliseconds: Double,
        trainIndex: Int,
        polarity: Polarity
    ) {
        self.triggerMetric = triggerMetric
        self.comparison = comparison
        self.threshold = threshold
        self.latencyMilliseconds = latencyMilliseconds
        self.trainIndex = trainIndex
        self.polarity = polarity
    }

    public func validated(trainCount: Int) throws -> Self {
        let supported = ["<", "<=", ">", ">=", "==", "!="]
        guard !triggerMetric.isEmpty,
              supported.contains(comparison),
              threshold.isFinite,
              latencyMilliseconds.isFinite,
              latencyMilliseconds >= 0,
              trainIndex >= 0,
              trainIndex < trainCount else {
            throw WetwareProtocolError.invalidReinforcement
        }
        return self
    }
}

public struct WetwareExperimentProtocol: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var electrodes: [WetwareElectrodeGeometry]
    public var stimulationTrains: [WetwareStimulationTrain]
    public var readouts: [WetwareReadoutWindow]
    public var reinforcementRules: [WetwareReinforcementRule]
    public var trialDurationMilliseconds: Double
    public var intertrialIntervalMilliseconds: Double
    public var trialCount: Int
    public var randomSeed: UInt64
    public var targetBackend: String?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        electrodes: [WetwareElectrodeGeometry],
        stimulationTrains: [WetwareStimulationTrain],
        readouts: [WetwareReadoutWindow],
        reinforcementRules: [WetwareReinforcementRule] = [],
        trialDurationMilliseconds: Double,
        intertrialIntervalMilliseconds: Double = 0,
        trialCount: Int,
        randomSeed: UInt64,
        targetBackend: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.electrodes = electrodes
        self.stimulationTrains = stimulationTrains
        self.readouts = readouts
        self.reinforcementRules = reinforcementRules
        self.trialDurationMilliseconds = trialDurationMilliseconds
        self.intertrialIntervalMilliseconds = intertrialIntervalMilliseconds
        self.trialCount = trialCount
        self.randomSeed = randomSeed
        self.targetBackend = targetBackend
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              !electrodes.isEmpty,
              Set(electrodes.map(\.id)).count == electrodes.count,
              trialDurationMilliseconds.isFinite,
              trialDurationMilliseconds > 0,
              intertrialIntervalMilliseconds.isFinite,
              intertrialIntervalMilliseconds >= 0,
              trialCount > 0 else {
            throw WetwareProtocolError.invalidProtocol(name)
        }
        for electrode in electrodes { _ = try electrode.validated() }
        let electrodeIDs = Set(electrodes.map(\.id))
        for train in stimulationTrains {
            _ = try train.validated()
            guard Set(train.electrodeIDs).isSubset(of: electrodeIDs),
                  train.onsetMilliseconds + train.durationMilliseconds <= trialDurationMilliseconds else {
                throw WetwareProtocolError.invalidTrain
            }
        }
        for readout in readouts {
            _ = try readout.validated()
            guard Set(readout.electrodeIDs).isSubset(of: electrodeIDs),
                  readout.startMilliseconds + readout.durationMilliseconds <= trialDurationMilliseconds else {
                throw WetwareProtocolError.invalidReadout(readout.outputChannel)
            }
        }
        for rule in reinforcementRules {
            _ = try rule.validated(trainCount: stimulationTrains.count)
        }
        return self
    }
}

public struct WetwareStimulationSafetyEnvelope: Sendable, Hashable, Codable {
    public var maximumAbsoluteCurrentMicroamps: Double
    public var maximumPhaseDurationMicroseconds: Double
    public var maximumChargePerPhaseMicrocoulombs: Double
    public var maximumChargeDensityMicrocoulombsPerSquareCentimeter: Double
    public var maximumDutyCycle: Double
    public var maximumFrequencyHertz: Double
    public var maximumSimultaneouslyActiveElectrodes: Int
    public var maximumChargeImbalanceFraction: Double
    public var minimumInterphaseGapMicroseconds: Double
    public var minimumIntertrialIntervalMilliseconds: Double

    public init(
        maximumAbsoluteCurrentMicroamps: Double,
        maximumPhaseDurationMicroseconds: Double,
        maximumChargePerPhaseMicrocoulombs: Double,
        maximumChargeDensityMicrocoulombsPerSquareCentimeter: Double,
        maximumDutyCycle: Double,
        maximumFrequencyHertz: Double,
        maximumSimultaneouslyActiveElectrodes: Int,
        maximumChargeImbalanceFraction: Double = 0.01,
        minimumInterphaseGapMicroseconds: Double = 0,
        minimumIntertrialIntervalMilliseconds: Double = 0
    ) {
        self.maximumAbsoluteCurrentMicroamps = maximumAbsoluteCurrentMicroamps
        self.maximumPhaseDurationMicroseconds = maximumPhaseDurationMicroseconds
        self.maximumChargePerPhaseMicrocoulombs = maximumChargePerPhaseMicrocoulombs
        self.maximumChargeDensityMicrocoulombsPerSquareCentimeter = maximumChargeDensityMicrocoulombsPerSquareCentimeter
        self.maximumDutyCycle = maximumDutyCycle
        self.maximumFrequencyHertz = maximumFrequencyHertz
        self.maximumSimultaneouslyActiveElectrodes = maximumSimultaneouslyActiveElectrodes
        self.maximumChargeImbalanceFraction = maximumChargeImbalanceFraction
        self.minimumInterphaseGapMicroseconds = minimumInterphaseGapMicroseconds
        self.minimumIntertrialIntervalMilliseconds = minimumIntertrialIntervalMilliseconds
    }

    public func validated() throws -> Self {
        let positive = [
            maximumAbsoluteCurrentMicroamps,
            maximumPhaseDurationMicroseconds,
            maximumChargePerPhaseMicrocoulombs,
            maximumChargeDensityMicrocoulombsPerSquareCentimeter,
            maximumFrequencyHertz
        ].allSatisfy({ $0.isFinite && $0 > 0 })
        guard positive,
              maximumDutyCycle.isFinite,
              maximumDutyCycle > 0,
              maximumDutyCycle <= 1,
              maximumSimultaneouslyActiveElectrodes > 0,
              maximumChargeImbalanceFraction.isFinite,
              maximumChargeImbalanceFraction >= 0,
              minimumInterphaseGapMicroseconds.isFinite,
              minimumInterphaseGapMicroseconds >= 0,
              minimumIntertrialIntervalMilliseconds.isFinite,
              minimumIntertrialIntervalMilliseconds >= 0 else {
            throw WetwareProtocolError.invalidSafetyEnvelope
        }
        return self
    }
}

public enum WetwareSafetyViolation: Sendable, Hashable, Codable {
    case unknownElectrode(train: Int, electrode: UInt32)
    case current(train: Int, measured: Double, limit: Double)
    case phaseDuration(train: Int, measured: Double, limit: Double)
    case chargePerPhase(train: Int, measured: Double, limit: Double)
    case chargeDensity(train: Int, electrode: UInt32, measured: Double, limit: Double)
    case dutyCycle(train: Int, measured: Double, limit: Double)
    case frequency(train: Int, measured: Double, limit: Double)
    case simultaneousElectrodes(train: Int, measured: Int, limit: Int)
    case chargeImbalance(train: Int, measured: Double, limit: Double)
    case interphaseGap(train: Int, measured: Double, limit: Double)
    case intertrialInterval(measured: Double, limit: Double)
}

public struct WetwareSafetyReport: Sendable, Hashable, Codable {
    public var protocolID: UUID
    public var violations: [WetwareSafetyViolation]
    public var maximumObservedChargeDensity: Double
    public var maximumObservedDutyCycle: Double

    public init(
        protocolID: UUID,
        violations: [WetwareSafetyViolation],
        maximumObservedChargeDensity: Double,
        maximumObservedDutyCycle: Double
    ) {
        self.protocolID = protocolID
        self.violations = violations
        self.maximumObservedChargeDensity = maximumObservedChargeDensity
        self.maximumObservedDutyCycle = maximumObservedDutyCycle
    }

    public var passed: Bool { violations.isEmpty }
}

public enum WetwareProtocolSafetyValidator {
    public static func validate(
        _ sourceProtocol: WetwareExperimentProtocol,
        envelope sourceEnvelope: WetwareStimulationSafetyEnvelope
    ) throws -> WetwareSafetyReport {
        let protocolValue = try sourceProtocol.validated()
        let envelope = try sourceEnvelope.validated()
        let electrodes = Dictionary(
            uniqueKeysWithValues: protocolValue.electrodes.map { ($0.id, $0) }
        )
        var violations: [WetwareSafetyViolation] = []
        var maximumChargeDensity = 0.0
        var maximumDutyCycle = 0.0

        if protocolValue.intertrialIntervalMilliseconds < envelope.minimumIntertrialIntervalMilliseconds {
            violations.append(.intertrialInterval(
                measured: protocolValue.intertrialIntervalMilliseconds,
                limit: envelope.minimumIntertrialIntervalMilliseconds
            ))
        }

        for (index, train) in protocolValue.stimulationTrains.enumerated() {
            let pulse = train.pulse
            let current = max(
                pulse.cathodicAmplitudeMicroamps,
                pulse.anodicAmplitudeMicroamps
            )
            if current > envelope.maximumAbsoluteCurrentMicroamps {
                violations.append(.current(
                    train: index,
                    measured: current,
                    limit: envelope.maximumAbsoluteCurrentMicroamps
                ))
            }
            let phaseDuration = max(
                pulse.cathodicPhaseMicroseconds,
                pulse.anodicPhaseMicroseconds
            )
            if phaseDuration > envelope.maximumPhaseDurationMicroseconds {
                violations.append(.phaseDuration(
                    train: index,
                    measured: phaseDuration,
                    limit: envelope.maximumPhaseDurationMicroseconds
                ))
            }
            let charge = max(
                pulse.cathodicChargeMicrocoulombs,
                pulse.anodicChargeMicrocoulombs
            )
            if charge > envelope.maximumChargePerPhaseMicrocoulombs {
                violations.append(.chargePerPhase(
                    train: index,
                    measured: charge,
                    limit: envelope.maximumChargePerPhaseMicrocoulombs
                ))
            }
            if pulse.chargeImbalanceFraction > envelope.maximumChargeImbalanceFraction {
                violations.append(.chargeImbalance(
                    train: index,
                    measured: pulse.chargeImbalanceFraction,
                    limit: envelope.maximumChargeImbalanceFraction
                ))
            }
            if pulse.interphaseGapMicroseconds < envelope.minimumInterphaseGapMicroseconds {
                violations.append(.interphaseGap(
                    train: index,
                    measured: pulse.interphaseGapMicroseconds,
                    limit: envelope.minimumInterphaseGapMicroseconds
                ))
            }
            if train.frequencyHertz > envelope.maximumFrequencyHertz {
                violations.append(.frequency(
                    train: index,
                    measured: train.frequencyHertz,
                    limit: envelope.maximumFrequencyHertz
                ))
            }
            maximumDutyCycle = max(maximumDutyCycle, train.dutyCycle)
            if train.dutyCycle > envelope.maximumDutyCycle {
                violations.append(.dutyCycle(
                    train: index,
                    measured: train.dutyCycle,
                    limit: envelope.maximumDutyCycle
                ))
            }
            if train.electrodeIDs.count > envelope.maximumSimultaneouslyActiveElectrodes {
                violations.append(.simultaneousElectrodes(
                    train: index,
                    measured: train.electrodeIDs.count,
                    limit: envelope.maximumSimultaneouslyActiveElectrodes
                ))
            }
            for electrodeID in train.electrodeIDs {
                guard let electrode = electrodes[electrodeID] else {
                    violations.append(.unknownElectrode(
                        train: index,
                        electrode: electrodeID
                    ))
                    continue
                }
                let density = charge / electrode.areaSquareCentimeters
                maximumChargeDensity = max(maximumChargeDensity, density)
                if density > envelope.maximumChargeDensityMicrocoulombsPerSquareCentimeter {
                    violations.append(.chargeDensity(
                        train: index,
                        electrode: electrodeID,
                        measured: density,
                        limit: envelope.maximumChargeDensityMicrocoulombsPerSquareCentimeter
                    ))
                }
            }
        }
        return WetwareSafetyReport(
            protocolID: protocolValue.id,
            violations: violations,
            maximumObservedChargeDensity: maximumChargeDensity,
            maximumObservedDutyCycle: maximumDutyCycle
        )
    }
}

public struct WetwareProtocolTransferBundle: Sendable, Hashable, Codable {
    public var formatVersion: UInt32
    public var protocolValue: WetwareExperimentProtocol
    public var safetyReport: WetwareSafetyReport
    public var sourceBackend: String
    public var targetBackend: String
    public var createdAt: Date
    public var simulatorVersion: String
    public var calibrationDigest: String?
    public var metadata: [String: String]

    public init(
        formatVersion: UInt32 = 1,
        protocolValue: WetwareExperimentProtocol,
        safetyReport: WetwareSafetyReport,
        sourceBackend: String,
        targetBackend: String,
        createdAt: Date = Date(),
        simulatorVersion: String,
        calibrationDigest: String? = nil,
        metadata: [String: String] = [:]
    ) throws {
        guard safetyReport.protocolID == protocolValue.id,
              safetyReport.passed,
              !sourceBackend.isEmpty,
              !targetBackend.isEmpty,
              !simulatorVersion.isEmpty else {
            throw WetwareProtocolError.invalidTransferBundle
        }
        self.formatVersion = formatVersion
        self.protocolValue = try protocolValue.validated()
        self.safetyReport = safetyReport
        self.sourceBackend = sourceBackend
        self.targetBackend = targetBackend
        self.createdAt = createdAt
        self.simulatorVersion = simulatorVersion
        self.calibrationDigest = calibrationDigest
        self.metadata = metadata
    }
}

public enum WetwareProtocolError: Error, Sendable, CustomStringConvertible {
    case invalidElectrode(UInt32)
    case invalidPulse
    case invalidTrain
    case invalidReadout(String)
    case invalidReinforcement
    case invalidProtocol(String)
    case invalidSafetyEnvelope
    case invalidTransferBundle

    public var description: String {
        switch self {
        case .invalidElectrode(let id): return "Wetware electrode \(id) is invalid"
        case .invalidPulse: return "Wetware stimulation pulse is invalid"
        case .invalidTrain: return "Wetware stimulation train is invalid"
        case .invalidReadout(let value): return "Wetware readout \(value) is invalid"
        case .invalidReinforcement: return "Wetware reinforcement rule is invalid"
        case .invalidProtocol(let value): return "Wetware protocol \(value) is invalid"
        case .invalidSafetyEnvelope: return "Wetware stimulation safety envelope is invalid"
        case .invalidTransferBundle: return "Wetware protocol transfer bundle is invalid"
        }
    }
}
