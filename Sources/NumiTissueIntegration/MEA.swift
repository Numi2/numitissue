import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct ElectrodeID: RawRepresentable, Sendable, Hashable, Codable, Comparable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ElectrodeShape: String, Sendable, Hashable, Codable {
    case disk
    case square
    case shank
    case spherical
}

public struct MEAElectrode: Sendable, Hashable, Codable {
    public var id: ElectrodeID
    public var positionMicrometers: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var shape: ElectrodeShape
    public var widthMicrometers: Float
    public var heightMicrometers: Float
    public var impedanceOhmsAt1kHz: Float
    public var capacitanceFarads: Float
    public var accessResistanceOhms: Float
    public var thermalNoiseVoltsRMS: Float
    public var gain: Float
    public var offsetVolts: Float
    public var enabled: Bool

    public init(
        id: ElectrodeID,
        positionMicrometers: SIMD3<Float>,
        normal: SIMD3<Float> = SIMD3(0, 0, 1),
        shape: ElectrodeShape = .disk,
        widthMicrometers: Float = 30,
        heightMicrometers: Float = 30,
        impedanceOhmsAt1kHz: Float = 100_000,
        capacitanceFarads: Float = 1e-9,
        accessResistanceOhms: Float = 10_000,
        thermalNoiseVoltsRMS: Float = 3e-6,
        gain: Float = 1,
        offsetVolts: Float = 0,
        enabled: Bool = true
    ) {
        self.id = id
        self.positionMicrometers = positionMicrometers
        self.normal = normal
        self.shape = shape
        self.widthMicrometers = widthMicrometers
        self.heightMicrometers = heightMicrometers
        self.impedanceOhmsAt1kHz = impedanceOhmsAt1kHz
        self.capacitanceFarads = capacitanceFarads
        self.accessResistanceOhms = accessResistanceOhms
        self.thermalNoiseVoltsRMS = thermalNoiseVoltsRMS
        self.gain = gain
        self.offsetVolts = offsetVolts
        self.enabled = enabled
    }

    public var geometricAreaSquareMeters: Float {
        let width = widthMicrometers * 1e-6
        let height = heightMicrometers * 1e-6
        switch shape {
        case .disk: return .pi * 0.25 * width * width
        case .square: return width * width
        case .shank: return width * height
        case .spherical: return 4 * .pi * 0.25 * width * width
        }
    }
}

public struct MEAConfiguration: Sendable, Hashable, Codable {
    public var electrodes: [MEAElectrode]
    public var sampleRateHertz: Double
    public var extracellularConductivitySiemensPerMeter: Float
    public var referenceElectrode: ElectrodeID?
    public var highPassHertz: Float
    public var lowPassHertz: Float
    public var adcBits: UInt8
    public var adcRangeVolts: ClosedRange<Float>

    public init(
        electrodes: [MEAElectrode],
        sampleRateHertz: Double = 20_000,
        extracellularConductivitySiemensPerMeter: Float = 0.3,
        referenceElectrode: ElectrodeID? = nil,
        highPassHertz: Float = 1,
        lowPassHertz: Float = 7_500,
        adcBits: UInt8 = 16,
        adcRangeVolts: ClosedRange<Float> = -0.01...0.01
    ) {
        self.electrodes = electrodes
        self.sampleRateHertz = sampleRateHertz
        self.extracellularConductivitySiemensPerMeter = extracellularConductivitySiemensPerMeter
        self.referenceElectrode = referenceElectrode
        self.highPassHertz = highPassHertz
        self.lowPassHertz = lowPassHertz
        self.adcBits = adcBits
        self.adcRangeVolts = adcRangeVolts
    }

    public func validated() throws -> Self {
        guard !electrodes.isEmpty else { throw MEAError.noElectrodes }
        guard Set(electrodes.map(\.id)).count == electrodes.count else { throw MEAError.duplicateElectrode }
        guard sampleRateHertz.isFinite, sampleRateHertz > 0 else { throw MEAError.invalidSampleRate }
        guard extracellularConductivitySiemensPerMeter > 0 else { throw MEAError.invalidConductivity }
        guard highPassHertz >= 0, lowPassHertz > highPassHertz, Double(lowPassHertz) < sampleRateHertz * 0.5 else { throw MEAError.invalidFilter }
        guard adcBits >= 8, adcBits <= 32, adcRangeVolts.lowerBound < adcRangeVolts.upperBound else { throw MEAError.invalidADC }
        if let referenceElectrode, !electrodes.contains(where: { $0.id == referenceElectrode }) { throw MEAError.unknownElectrode(referenceElectrode) }
        for electrode in electrodes {
            guard electrode.positionMicrometers.x.isFinite, electrode.positionMicrometers.y.isFinite, electrode.positionMicrometers.z.isFinite else { throw MEAError.nonFiniteElectrode(electrode.id) }
            guard electrode.widthMicrometers > 0, electrode.heightMicrometers > 0, electrode.geometricAreaSquareMeters > 0 else { throw MEAError.invalidArea(electrode.id) }
            guard electrode.impedanceOhmsAt1kHz > 0, electrode.accessResistanceOhms >= 0, electrode.capacitanceFarads >= 0 else { throw MEAError.invalidImpedance(electrode.id) }
        }
        return self
    }
}

public struct StimulationPhase: Sendable, Hashable, Codable {
    public var amplitudeAmperes: Float
    public var durationMicroseconds: UInt32

    public init(amplitudeAmperes: Float, durationMicroseconds: UInt32) {
        self.amplitudeAmperes = amplitudeAmperes
        self.durationMicroseconds = durationMicroseconds
    }

    public var chargeCoulombs: Double { Double(amplitudeAmperes) * Double(durationMicroseconds) * 1e-6 }
}

public struct StimulationPulse: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var startTick: UInt64
    public var phases: [StimulationPhase]
    public var interphaseDelayMicroseconds: UInt32
    public var repetitions: UInt32
    public var periodMicroseconds: UInt32
    public var tag: UInt32

    public init(
        electrode: ElectrodeID,
        startTick: UInt64,
        phases: [StimulationPhase],
        interphaseDelayMicroseconds: UInt32 = 0,
        repetitions: UInt32 = 1,
        periodMicroseconds: UInt32 = 0,
        tag: UInt32 = 0
    ) {
        self.electrode = electrode
        self.startTick = startTick
        self.phases = phases
        self.interphaseDelayMicroseconds = interphaseDelayMicroseconds
        self.repetitions = repetitions
        self.periodMicroseconds = periodMicroseconds
        self.tag = tag
    }
}

public struct StimulationSafetyLimits: Sendable, Hashable, Codable {
    public var maximumAbsoluteCurrentAmperes: Float
    public var maximumChargePerPhaseCoulombs: Double
    public var maximumChargeDensityCoulombsPerSquareMeter: Double
    public var maximumNetChargeFraction: Double
    public var minimumInterphaseDelayMicroseconds: UInt32
    public var minimumPeriodMicroseconds: UInt32

    public init(
        maximumAbsoluteCurrentAmperes: Float = 100e-6,
        maximumChargePerPhaseCoulombs: Double = 50e-9,
        maximumChargeDensityCoulombsPerSquareMeter: Double = 0.35,
        maximumNetChargeFraction: Double = 0.01,
        minimumInterphaseDelayMicroseconds: UInt32 = 0,
        minimumPeriodMicroseconds: UInt32 = 100
    ) {
        self.maximumAbsoluteCurrentAmperes = maximumAbsoluteCurrentAmperes
        self.maximumChargePerPhaseCoulombs = maximumChargePerPhaseCoulombs
        self.maximumChargeDensityCoulombsPerSquareMeter = maximumChargeDensityCoulombsPerSquareMeter
        self.maximumNetChargeFraction = maximumNetChargeFraction
        self.minimumInterphaseDelayMicroseconds = minimumInterphaseDelayMicroseconds
        self.minimumPeriodMicroseconds = minimumPeriodMicroseconds
    }
}

public struct CompiledStimulationPlan: Sendable, Hashable, Codable {
    public var pulses: [StimulationPulse]
    public var runtimeStimuli: [TissueStimulus]
    public var totalAbsoluteChargeCoulombs: Double
    public var startTick: UInt64
    public var endTick: UInt64

    public init(pulses: [StimulationPulse], runtimeStimuli: [TissueStimulus], totalAbsoluteChargeCoulombs: Double, startTick: UInt64, endTick: UInt64) {
        self.pulses = pulses
        self.runtimeStimuli = runtimeStimuli
        self.totalAbsoluteChargeCoulombs = totalAbsoluteChargeCoulombs
        self.startTick = startTick
        self.endTick = endTick
    }
}

public enum StimulationPlanCompiler {
    public static func compile(
        pulses: [StimulationPulse],
        configuration: MEAConfiguration,
        electrodeDestinations: [ElectrodeID: UInt64],
        limits: StimulationSafetyLimits = StimulationSafetyLimits()
    ) throws -> CompiledStimulationPlan {
        let configuration = try configuration.validated()
        let electrodes = Dictionary(uniqueKeysWithValues: configuration.electrodes.map { ($0.id, $0) })
        var runtime: [TissueStimulus] = []
        var totalCharge = 0.0
        var start = UInt64.max
        var end: UInt64 = 0
        for pulse in pulses.sorted(by: { ($0.startTick, $0.electrode) < ($1.startTick, $1.electrode) }) {
            guard let electrode = electrodes[pulse.electrode] else { throw MEAError.unknownElectrode(pulse.electrode) }
            guard electrode.enabled else { throw MEAError.disabledElectrode(pulse.electrode) }
            guard let destination = electrodeDestinations[pulse.electrode] else { throw MEAError.unmappedElectrode(pulse.electrode) }
            guard !pulse.phases.isEmpty else { throw MEAError.emptyPulse(pulse.electrode) }
            guard pulse.repetitions > 0 else { throw MEAError.invalidRepetitionCount }
            if pulse.repetitions > 1 {
                guard pulse.periodMicroseconds >= limits.minimumPeriodMicroseconds else { throw MEAError.periodTooShort(pulse.electrode) }
            }
            guard pulse.interphaseDelayMicroseconds >= limits.minimumInterphaseDelayMicroseconds else { throw MEAError.interphaseDelayTooShort(pulse.electrode) }

            let positive = pulse.phases.reduce(0.0) { $0 + max($1.chargeCoulombs, 0) }
            let negative = pulse.phases.reduce(0.0) { $0 + min($1.chargeCoulombs, 0) }
            let absolute = positive - negative
            guard absolute > 0 else { throw MEAError.zeroChargePulse(pulse.electrode) }
            guard abs(positive + negative) / absolute <= limits.maximumNetChargeFraction else { throw MEAError.unbalancedPulse(pulse.electrode) }

            for phase in pulse.phases {
                guard phase.amplitudeAmperes.isFinite, abs(phase.amplitudeAmperes) <= limits.maximumAbsoluteCurrentAmperes else { throw MEAError.currentLimit(pulse.electrode) }
                let charge = abs(phase.chargeCoulombs)
                guard charge <= limits.maximumChargePerPhaseCoulombs else { throw MEAError.chargeLimit(pulse.electrode) }
                guard charge / Double(electrode.geometricAreaSquareMeters) <= limits.maximumChargeDensityCoulombsPerSquareMeter else { throw MEAError.chargeDensityLimit(pulse.electrode) }
            }

            let pulseDurationMicroseconds = pulse.phases.reduce(UInt64(0)) { $0 + UInt64($1.durationMicroseconds) } + UInt64(pulse.interphaseDelayMicroseconds) * UInt64(max(pulse.phases.count - 1, 0))
            for repetition in 0..<pulse.repetitions {
                var phaseTick = pulse.startTick + microsecondsToTicks(UInt64(repetition) * UInt64(pulse.periodMicroseconds))
                for (phaseIndex, phase) in pulse.phases.enumerated() {
                    let durationTicks = max(UInt32(clamping: microsecondsToTicks(UInt64(phase.durationMicroseconds))), 1)
                    runtime.append(TissueStimulus(
                        destination: destination,
                        startTick: phaseTick,
                        durationTicks: durationTicks,
                        amplitude: phase.amplitudeAmperes,
                        kind: 1,
                        flags: UInt16(clamping: phaseIndex)
                    ))
                    phaseTick += UInt64(durationTicks)
                    if phaseIndex + 1 < pulse.phases.count { phaseTick += microsecondsToTicks(UInt64(pulse.interphaseDelayMicroseconds)) }
                }
            }
            totalCharge += absolute * Double(pulse.repetitions)
            start = min(start, pulse.startTick)
            end = max(end, pulse.startTick + microsecondsToTicks(UInt64(max(pulse.repetitions - 1, 0)) * UInt64(pulse.periodMicroseconds) + pulseDurationMicroseconds))
        }
        return CompiledStimulationPlan(
            pulses: pulses,
            runtimeStimuli: runtime.sorted { ($0.startTick, $0.destination) < ($1.startTick, $1.destination) },
            totalAbsoluteChargeCoulombs: totalCharge,
            startTick: start == UInt64.max ? 0 : start,
            endTick: end
        )
    }

    private static func microsecondsToTicks(_ value: UInt64) -> UInt64 {
        // One NumiTissue fast tick is 25 microseconds.
        (value + 24) / 25
    }
}

public struct MEASampleFrame: Sendable, Hashable, Codable {
    public var startTick: UInt64
    public var sampleRateHertz: Double
    public var electrodeOrder: [ElectrodeID]
    public var samplesByElectrode: [[Float]]

    public init(startTick: UInt64, sampleRateHertz: Double, electrodeOrder: [ElectrodeID], samplesByElectrode: [[Float]]) {
        self.startTick = startTick
        self.sampleRateHertz = sampleRateHertz
        self.electrodeOrder = electrodeOrder
        self.samplesByElectrode = samplesByElectrode
    }

    public var sampleCount: Int { samplesByElectrode.first?.count ?? 0 }
}

public struct DetectedMEASpike: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var sampleIndex: Int
    public var tick: UInt64
    public var amplitudeVolts: Float
    public var polarity: Int8

    public init(electrode: ElectrodeID, sampleIndex: Int, tick: UInt64, amplitudeVolts: Float, polarity: Int8) {
        self.electrode = electrode
        self.sampleIndex = sampleIndex
        self.tick = tick
        self.amplitudeVolts = amplitudeVolts
        self.polarity = polarity
    }
}

public struct MEASpikeDetector: Sendable {
    public var thresholdStandardDeviations: Float
    public var refractorySamples: Int
    public var negativePolarity: Bool

    public init(thresholdStandardDeviations: Float = 5, refractorySamples: Int = 20, negativePolarity: Bool = true) {
        self.thresholdStandardDeviations = thresholdStandardDeviations
        self.refractorySamples = refractorySamples
        self.negativePolarity = negativePolarity
    }

    public func detect(_ frame: MEASampleFrame) -> [DetectedMEASpike] {
        var result: [DetectedMEASpike] = []
        let ticksPerSample = 40_000.0 / frame.sampleRateHertz
        for (channel, samples) in frame.samplesByElectrode.enumerated() where channel < frame.electrodeOrder.count && !samples.isEmpty {
            let medianValue = median(samples)
            let deviation = median(samples.map { abs($0 - medianValue) })
            let sigma = max(deviation / 0.6745, Float.leastNonzeroMagnitude)
            let threshold = sigma * thresholdStandardDeviations
            var nextAllowed = 0
            for index in samples.indices where index >= nextAllowed {
                let centered = samples[index] - medianValue
                let crossed = negativePolarity ? centered <= -threshold : abs(centered) >= threshold
                guard crossed else { continue }
                result.append(DetectedMEASpike(
                    electrode: frame.electrodeOrder[channel],
                    sampleIndex: index,
                    tick: frame.startTick + UInt64((Double(index) * ticksPerSample).rounded()),
                    amplitudeVolts: centered,
                    polarity: centered < 0 ? -1 : 1
                ))
                nextAllowed = index + refractorySamples
            }
        }
        return result
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? 0.5 * (sorted[middle - 1] + sorted[middle]) : sorted[middle]
    }
}

public enum MEAError: Error, Sendable, CustomStringConvertible {
    case noElectrodes
    case duplicateElectrode
    case unknownElectrode(ElectrodeID)
    case disabledElectrode(ElectrodeID)
    case unmappedElectrode(ElectrodeID)
    case nonFiniteElectrode(ElectrodeID)
    case invalidArea(ElectrodeID)
    case invalidImpedance(ElectrodeID)
    case invalidSampleRate
    case invalidConductivity
    case invalidFilter
    case invalidADC
    case emptyPulse(ElectrodeID)
    case invalidRepetitionCount
    case periodTooShort(ElectrodeID)
    case interphaseDelayTooShort(ElectrodeID)
    case zeroChargePulse(ElectrodeID)
    case unbalancedPulse(ElectrodeID)
    case currentLimit(ElectrodeID)
    case chargeLimit(ElectrodeID)
    case chargeDensityLimit(ElectrodeID)

    public var description: String {
        switch self {
        case .noElectrodes: return "MEA contains no electrodes"
        case .duplicateElectrode: return "MEA contains duplicate electrode IDs"
        case .unknownElectrode(let id): return "Unknown electrode \(id.rawValue)"
        case .disabledElectrode(let id): return "Electrode \(id.rawValue) is disabled"
        case .unmappedElectrode(let id): return "Electrode \(id.rawValue) has no tissue destination"
        case .nonFiniteElectrode(let id): return "Electrode \(id.rawValue) has a non-finite position"
        case .invalidArea(let id): return "Electrode \(id.rawValue) has invalid area"
        case .invalidImpedance(let id): return "Electrode \(id.rawValue) has invalid impedance"
        case .invalidSampleRate: return "MEA sample rate is invalid"
        case .invalidConductivity: return "Extracellular conductivity is invalid"
        case .invalidFilter: return "MEA filter configuration is invalid"
        case .invalidADC: return "MEA ADC configuration is invalid"
        case .emptyPulse(let id): return "Electrode \(id.rawValue) pulse contains no phases"
        case .invalidRepetitionCount: return "Stimulation repetition count is invalid"
        case .periodTooShort(let id): return "Electrode \(id.rawValue) stimulation period is too short"
        case .interphaseDelayTooShort(let id): return "Electrode \(id.rawValue) interphase delay is too short"
        case .zeroChargePulse(let id): return "Electrode \(id.rawValue) pulse has zero charge"
        case .unbalancedPulse(let id): return "Electrode \(id.rawValue) pulse is not charge balanced"
        case .currentLimit(let id): return "Electrode \(id.rawValue) exceeds current limit"
        case .chargeLimit(let id): return "Electrode \(id.rawValue) exceeds charge-per-phase limit"
        case .chargeDensityLimit(let id): return "Electrode \(id.rawValue) exceeds charge-density limit"
        }
    }
}
