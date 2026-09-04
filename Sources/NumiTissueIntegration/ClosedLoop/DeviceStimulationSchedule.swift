import Foundation
import NumiTissueIO

/// Device adapters must query these quanta from the selected firmware/SDK. The scheduling frame
/// and stimulation waveform quantum may differ. Neither is implicitly a 25-us tissue tick.
public struct DeviceStimulationTimebase: Sendable, Hashable, Codable {
    public var clockID: String
    public var timestampQuantumNanoseconds: UInt64
    public var phaseQuantumNanoseconds: UInt64
    public init(clockID: String, timestampQuantumNanoseconds: UInt64, phaseQuantumNanoseconds: UInt64) {
        self.clockID = clockID; self.timestampQuantumNanoseconds = timestampQuantumNanoseconds
        self.phaseQuantumNanoseconds = phaseQuantumNanoseconds
    }
    public func validated() throws -> Self {
        guard !clockID.isEmpty, timestampQuantumNanoseconds > 0, phaseQuantumNanoseconds > 0 else {
            throw ClosedLoopError.invalid("device timebase")
        }
        return self
    }
}

public struct DevicePulsePhase: Sendable, Hashable, Codable {
    public var amplitudeMicroamperes: Double
    public var durationPhaseQuanta: UInt64
}
public struct DeviceScheduledPulse: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var timestampFrames: UInt64
    public var phases: [DevicePulsePhase]
    public var interphaseQuanta: UInt64
}
public struct DeviceStimulationSchedule: Sendable, Codable {
    public var schemaVersion: UInt32
    public var requestSHA256: ScientificSHA256Digest
    public var timebase: DeviceStimulationTimebase
    public var pulses: [DeviceScheduledPulse]
    public var safetyEnvelopeSHA256: ScientificSHA256Digest
    public var maximumEndNanoseconds: UInt64
}

public enum DeviceStimulationScheduleCompiler {
    /// Pure compilation; this neither arms a device nor invokes a vendor SDK. The live adapter
    /// must recheck its clock, watchdog, lease and deadline immediately before submission.
    public static func compile(request: NeuralStimulationRequest, configuration: MEAConfiguration,
        destinations: [ElectrodeID: UInt64], envelope: ClosedLoopSafetyEnvelope,
        timebase source: DeviceStimulationTimebase, deviceNowNanoseconds: UInt64,
        minimumLeadNanoseconds: UInt64, history: [ClosedLoopExposure] = []) throws -> DeviceStimulationSchedule {
        let timebase = try source.validated()
        var a = timebase.timestampQuantumNanoseconds, b = timebase.phaseQuantumNanoseconds
        while b > 0 { let remainder = a % b; a = b; b = remainder }
        // The common divisor is used only for initial arithmetic validation. Each timing domain
        // is then checked separately; representability never implies a scheduling approximation.
        let decision = try ClosedLoopSafetyEvaluator.evaluate(request: request, configuration: configuration,
            destinations: destinations, envelope: envelope, deviceNowNanoseconds: deviceNowNanoseconds,
            deviceMinimumLeadNanoseconds: minimumLeadNanoseconds, timestampResolutionNanoseconds: a, history: history)
        var pulses: [DeviceScheduledPulse] = []
        for pulse in request.plan.pulses {
            let phases = try pulse.phases.map { phase -> DevicePulsePhase in
                let duration = try LoopArithmetic.multiply(UInt64(phase.durationMicroseconds), 1_000)
                guard duration.isMultiple(of: timebase.phaseQuantumNanoseconds) else {
                    throw ClosedLoopError.invalid("phase width is not exactly representable by the selected device")
                }
                let amplitude = Double(phase.amplitudeAmperes) * 1e6
                guard amplitude.isFinite else { throw ClosedLoopError.invalid("microampere conversion overflow") }
                return .init(amplitudeMicroamperes: amplitude, durationPhaseQuanta: duration / timebase.phaseQuantumNanoseconds)
            }
            let gap = try LoopArithmetic.multiply(UInt64(pulse.interphaseDelayMicroseconds), 1_000)
            guard gap.isMultiple(of: timebase.phaseQuantumNanoseconds) else {
                throw ClosedLoopError.invalid("interphase gap is not exactly representable")
            }
            let offset = try LoopArithmetic.multiply(pulse.startTick - request.plan.startTick, 25_000)
            for repetition in 0..<pulse.repetitions {
                let repeated = try LoopArithmetic.multiply(UInt64(repetition), UInt64(pulse.periodMicroseconds) * 1_000)
                let ns = try LoopArithmetic.add(request.scheduledTimeNanoseconds, LoopArithmetic.add(offset, repeated))
                guard ns.isMultiple(of: timebase.timestampQuantumNanoseconds) else {
                    throw ClosedLoopError.invalid("start timestamp is not exactly representable; respecify the protocol")
                }
                pulses.append(.init(electrode: pulse.electrode, timestampFrames: ns / timebase.timestampQuantumNanoseconds,
                    phases: phases, interphaseQuanta: gap / timebase.phaseQuantumNanoseconds))
            }
        }
        pulses.sort { ($0.timestampFrames, $0.electrode) < ($1.timestampFrames, $1.electrode) }
        return .init(schemaVersion: 1, requestSHA256: decision.requestSHA256, timebase: timebase,
            pulses: pulses, safetyEnvelopeSHA256: decision.envelopeSHA256, maximumEndNanoseconds: decision.endNanoseconds)
    }
}
