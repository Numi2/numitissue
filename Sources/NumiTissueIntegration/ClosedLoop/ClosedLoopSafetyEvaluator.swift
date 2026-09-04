import Foundation
import NumiTissueIO

/// Conservative full-pulse reservation, including interphase gaps. Accepted, executed and
/// unknown-delivery pulses retain their reservations. No automatic refund on transport failure.
public struct ClosedLoopExposure: Sendable, Hashable, Codable {
    public var requestID: UUID
    public var electrode: ElectrodeID
    public var startNanoseconds: UInt64
    public var endNanoseconds: UInt64
    public var absoluteChargeCoulombs: Double
    public var activeNanoseconds: UInt64
    public init(requestID: UUID, electrode: ElectrodeID, startNanoseconds: UInt64,
                endNanoseconds: UInt64, absoluteChargeCoulombs: Double, activeNanoseconds: UInt64) {
        self.requestID = requestID; self.electrode = electrode
        self.startNanoseconds = startNanoseconds; self.endNanoseconds = endNanoseconds
        self.absoluteChargeCoulombs = absoluteChargeCoulombs; self.activeNanoseconds = activeNanoseconds
    }
}

public struct ClosedLoopSafetyDecision: Sendable, Codable {
    public let requestSHA256: ScientificSHA256Digest
    public let envelopeSHA256: ScientificSHA256Digest
    public let exposures: [ClosedLoopExposure]
    public let totalAbsoluteChargeCoulombs: Double
    public let endNanoseconds: UInt64
}

public enum ClosedLoopSafetyEvaluator {
    public static func evaluate(request: NeuralStimulationRequest,
        configuration: MEAConfiguration, destinations: [ElectrodeID: UInt64],
        envelope source: ClosedLoopSafetyEnvelope, deviceNowNanoseconds: UInt64,
        deviceMinimumLeadNanoseconds: UInt64, timestampResolutionNanoseconds: UInt64,
        history: [ClosedLoopExposure] = []) throws -> ClosedLoopSafetyDecision {
        let envelope = try source.validated()
        let configuration = try configuration.validated()
        guard timestampResolutionNanoseconds > 0, !request.plan.pulses.isEmpty,
              request.plan.pulses.count <= envelope.maximumExpandedPhases / 2,
              request.plan.runtimeStimuli.count <= envelope.maximumExpandedPhases,
              Float(envelope.maximumCurrentAmperes).isFinite,
              history.count <= 100_000, let deadline = request.deadlineNanoseconds else {
            throw ClosedLoopError.invalid("bounded plan, representable limits and explicit deadline required")
        }
        let earliest = try LoopArithmetic.add(deviceNowNanoseconds,
            max(deviceMinimumLeadNanoseconds, envelope.minimumLeadTimeNanoseconds))
        guard request.scheduledTimeNanoseconds >= earliest,
              request.scheduledTimeNanoseconds <= deadline,
              request.scheduledTimeNanoseconds.isMultiple(of: timestampResolutionNanoseconds) else {
            throw ClosedLoopError.unsafe("late or unrepresentable stimulation timestamp")
        }
        let electrodes = Dictionary(uniqueKeysWithValues: configuration.electrodes.map { ($0.id, $0) })
        let excluded = Set(envelope.excludedElectrodes)
        var result = [ClosedLoopExposure](), expandedCount = 0
        var totalCharge = 0.0
        for pulse in request.plan.pulses {
            guard let electrode = electrodes[pulse.electrode], electrode.enabled,
                  destinations[pulse.electrode] != nil, !excluded.contains(pulse.electrode),
                  electrode.geometricAreaSquareMeters.isFinite, electrode.geometricAreaSquareMeters > 0,
                  electrode.impedanceOhmsAt1kHz.isFinite, electrode.impedanceOhmsAt1kHz > 0,
                  pulse.phases.count >= 2, pulse.phases.count <= 8, pulse.repetitions > 0,
                  pulse.startTick >= request.plan.startTick else {
                throw ClosedLoopError.unsafe("electrode, mapping, geometry or pulse shape")
            }
            let expanded = Int(pulse.repetitions).multipliedReportingOverflow(by: pulse.phases.count)
            guard !expanded.overflow, expanded.partialValue <= envelope.maximumExpandedPhases - expandedCount else {
                throw ClosedLoopError.capacity("expanded phase budget")
            }
            expandedCount += expanded.partialValue
            var active: UInt64 = 0, roundedVirtualTicks: UInt64 = 0
            var signedCharge = 0.0, absoluteCharge = 0.0
            for phase in pulse.phases {
                let amplitude = Double(phase.amplitudeAmperes)
                let duration = try LoopArithmetic.multiply(UInt64(phase.durationMicroseconds), 1_000)
                let charge = abs(amplitude) * Double(duration) * 1e-9
                guard duration > 0, duration.isMultiple(of: timestampResolutionNanoseconds),
                      amplitude.isFinite, abs(amplitude) <= envelope.maximumCurrentAmperes,
                      charge.isFinite, charge <= envelope.maximumPhaseChargeCoulombs,
                      charge / Double(electrode.geometricAreaSquareMeters) <= envelope.maximumPhaseChargeDensityCoulombsPerSquareMeter,
                      abs(amplitude) * Double(electrode.impedanceOhmsAt1kHz) <= envelope.maximumResistiveVoltageEstimate else {
                    throw ClosedLoopError.unsafe("phase duration/current/charge/density/voltage estimate")
                }
                signedCharge += amplitude * Double(duration) * 1e-9
                absoluteCharge += charge
                active = try LoopArithmetic.add(active, duration)
                roundedVirtualTicks = try LoopArithmetic.add(roundedVirtualTicks, ceilTicks(UInt64(phase.durationMicroseconds)))
            }
            guard absoluteCharge.isFinite, absoluteCharge > 0,
                  abs(signedCharge) / absoluteCharge <= envelope.maximumNetChargeFraction else {
                throw ClosedLoopError.unsafe("pulse is not charge balanced")
            }
            let gap = try LoopArithmetic.multiply(UInt64(pulse.interphaseDelayMicroseconds), 1_000)
            guard gap.isMultiple(of: timestampResolutionNanoseconds) else {
                throw ClosedLoopError.invalid("interphase interval is not representable")
            }
            let gaps = UInt64(pulse.phases.count - 1)
            let length = try LoopArithmetic.add(active, LoopArithmetic.multiply(gap, gaps))
            let period = try LoopArithmetic.multiply(UInt64(pulse.periodMicroseconds), 1_000)
            if pulse.repetitions > 1 {
                guard period >= (try LoopArithmetic.add(length, envelope.minimumElectrodeRecoveryNanoseconds)),
                      period.isMultiple(of: timestampResolutionNanoseconds) else {
                    throw ClosedLoopError.unsafe("overlapping repetition or insufficient recovery")
                }
            }
            // Validate BOTH absolute legacy-tick arithmetic and physical relative nanoseconds
            // before calling the legacy compiler, which otherwise uses unchecked additions.
            let lastRepeatUs = try LoopArithmetic.multiply(UInt64(pulse.repetitions - 1), UInt64(pulse.periodMicroseconds))
            let wholeUs = try LoopArithmetic.add(lastRepeatUs, length / 1_000)
            _ = try LoopArithmetic.add(pulse.startTick, ceilTicks(wholeUs))
            roundedVirtualTicks = try LoopArithmetic.add(roundedVirtualTicks,
                LoopArithmetic.multiply(ceilTicks(UInt64(pulse.interphaseDelayMicroseconds)), gaps))
            _ = try LoopArithmetic.add(pulse.startTick, LoopArithmetic.add(ceilTicks(lastRepeatUs), roundedVirtualTicks))
            let relative = try LoopArithmetic.multiply(pulse.startTick - request.plan.startTick, 25_000)
            let first = try LoopArithmetic.add(request.scheduledTimeNanoseconds, relative)
            for repetition in 0..<pulse.repetitions {
                let start = try LoopArithmetic.add(first, LoopArithmetic.multiply(UInt64(repetition), period))
                let end = try LoopArithmetic.add(start, length)
                guard start.isMultiple(of: timestampResolutionNanoseconds), end <= deadline,
                      end - request.scheduledTimeNanoseconds <= envelope.maximumPlanDurationNanoseconds else {
                    throw ClosedLoopError.unsafe("plan duration or delivery deadline exceeded")
                }
                result.append(.init(requestID: request.id, electrode: pulse.electrode,
                    startNanoseconds: start, endNanoseconds: end,
                    absoluteChargeCoulombs: absoluteCharge, activeNanoseconds: active))
                totalCharge += absoluteCharge
            }
        }
        guard totalCharge.isFinite else { throw ClosedLoopError.invalid("total charge overflow") }
        // Physical adapters use original pulse phases. The legacy virtual cache rounds to 25 us;
        // equality here checks integrity only, NOT physical/virtual time-resolution equivalence.
        let rebuilt = try StimulationPlanCompiler.compile(pulses: request.plan.pulses,
            configuration: configuration, electrodeDestinations: destinations,
            limits: .init(maximumAbsoluteCurrentAmperes: Float(envelope.maximumCurrentAmperes),
                maximumChargePerPhaseCoulombs: envelope.maximumPhaseChargeCoulombs,
                maximumChargeDensityCoulombsPerSquareMeter: envelope.maximumPhaseChargeDensityCoulombsPerSquareMeter,
                maximumNetChargeFraction: envelope.maximumNetChargeFraction,
                minimumInterphaseDelayMicroseconds: 0, minimumPeriodMicroseconds: 0))
        guard rebuilt == request.plan else { throw ClosedLoopError.invalid("compiled stimulation cache differs from pulses") }
        try checkCumulative(history + result, envelope: envelope)
        return ClosedLoopSafetyDecision(
            requestSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(request)),
            envelopeSHA256: try envelope.digest(), exposures: result,
            totalAbsoluteChargeCoulombs: totalCharge,
            endNanoseconds: result.map(\.endNanoseconds).max() ?? request.scheduledTimeNanoseconds)
    }

    private static func ceilTicks(_ microseconds: UInt64) throws -> UInt64 {
        try LoopArithmetic.add(microseconds, 24) / 25
    }

    static func checkCumulative(_ exposures: [ClosedLoopExposure], envelope: ClosedLoopSafetyEnvelope) throws {
        guard exposures.count <= 100_000 else { throw ClosedLoopError.capacity("session exposure journal") }
        for exposure in exposures {
            guard exposure.startNanoseconds < exposure.endNanoseconds,
                  exposure.activeNanoseconds <= exposure.endNanoseconds - exposure.startNanoseconds,
                  exposure.absoluteChargeCoulombs.isFinite, exposure.absoluteChargeCoulombs >= 0 else {
                throw ClosedLoopError.invalid("exposure history")
            }
        }
        for group in Dictionary(grouping: exposures, by: \.electrode).values {
            let ordered = group.sorted { $0.startNanoseconds < $1.startNanoseconds }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                guard b.startNanoseconds >= (try LoopArithmetic.add(a.endNanoseconds, envelope.minimumElectrodeRecoveryNanoseconds)) else {
                    throw ClosedLoopError.unsafe("electrode overlap or recovery violation across requests")
                }
            }
            // Entire pulse charge/duration counts whenever a trailing window touches it.
            // Conservative at partial-window boundaries; never undercounts partial delivery.
            var events: [(UInt64, Int, Double, Double)] = []
            for x in ordered {
                events.append((x.startNanoseconds, 1, x.absoluteChargeCoulombs, Double(x.activeNanoseconds)))
                events.append((try LoopArithmetic.add(x.endNanoseconds, envelope.rollingWindowNanoseconds),
                               -1, -x.absoluteChargeCoulombs, -Double(x.activeNanoseconds)))
            }
            events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            var charge = 0.0, active = 0.0
            for event in events {
                charge += event.2; active += event.3
                guard charge <= envelope.maximumRollingChargePerElectrodeCoulombs,
                      active <= Double(envelope.rollingWindowNanoseconds) * envelope.maximumRollingDutyFraction else {
                    throw ClosedLoopError.unsafe("rolling electrode charge or duty budget")
                }
            }
        }
        var edges = exposures.flatMap { [($0.startNanoseconds, 1), ($0.endNanoseconds, -1)] }
        edges.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var concurrency = 0
        for edge in edges {
            concurrency += edge.1
            guard concurrency <= envelope.maximumConcurrentElectrodes else {
                throw ClosedLoopError.unsafe("simultaneous electrode limit")
            }
        }
    }
}
