import Foundation
import NumiTissueIO

public protocol NeuralDeviceSidecarTransport: Sendable {
    /// Serialize bounded exchanges, never retry a stimulation write automatically, and preserve
    /// an ambiguous-delivery error when the child or transport dies after submission.
    func exchange(_ request: Data, timeoutNanoseconds: UInt64) async throws -> Data
}

private struct SidecarResponse: Codable, Sendable {
    var ok: Bool; var code: String?; var message: String?; var frame: UInt64?
    var frame_duration_us: UInt64?; var channels: Int?; var simulator: Bool?; var stop_confirmed: Bool?
    var id: String?; var status: String?; var accepted_frame: UInt64?; var scheduled_frame: UInt64?
    var end_frame: UInt64?; var armed_until_frame: UInt64?
    var delivery: String?; var observed_stims: [ObservedStim]?
    struct ObservedStim: Codable, Sendable, Hashable { var timestamp: UInt64; var channel: Int }
}

/// Historical type name retained; this is a reviewed SDK SIMULATOR boundary, not a hardware audit
/// certificate. Physical CL1 is blocked until independently measured interlocks are implemented.
/// It does not conform to WatchdogNeuralCultureBackend and cannot enter a physical guarded session.
public actor CL1AuditedAdapter {
    public struct Phase: Codable, Sendable {
        public var duration_us: UInt64
        public var current_ua: Double
        public init(durationMicroseconds: UInt64, currentMicroamperes: Double) {
            duration_us = durationMicroseconds; current_ua = currentMicroamperes
        }
    }
    public struct Pulse: Codable, Sendable {
        public var channel: Int
        public var timestamp_frames: UInt64
        public var phases: [Phase]
        public init(channel: Int, timestampFrames: UInt64, phases: [Phase]) {
            self.channel = channel; timestamp_frames = timestampFrames; self.phases = phases
        }
    }
    private struct Submitted: Sendable {
        var pulses: [Pulse]
        var deadlineFrame: UInt64
        var acceptedFrame: UInt64?
    }
    private let transport: any NeuralDeviceSidecarTransport
    private var stopped = true, latched = false, busy = false
    private var submitted: [UUID: Submitted] = [:]
    private var frameNanoseconds: UInt64?
    private var channels: Int?
    private var leaseExpiry: UInt64?
    public init(transport: any NeuralDeviceSidecarTransport) { self.transport = transport }

    public func stop(reason: String) async throws -> Bool {
        stopped = true; latched = true
        struct P: Codable, Sendable { var reason: String }
        let response = try await call("stop", P(reason: reason), timeout: 1_000_000_000)
        return response.simulator == true && response.stop_confirmed == true
    }

    public func verifyIdentity() async throws -> (channels: Int, simulator: Bool, frameNanoseconds: UInt64) {
        guard !busy, !latched else { throw ClosedLoopError.latched("simulator adapter busy or stopped") }
        busy = true; defer { busy = false }
        struct Empty: Codable, Sendable {}
        let response = try await call("identity", Empty(), timeout: 1_000_000_000)
        guard !latched, let count = response.channels, count > 0, count <= 4096,
              response.simulator == true, let frameUS = response.frame_duration_us, frameUS > 0 else {
            stopped = true; latched = true
            throw ClosedLoopError.unsafe("CL SDK Simulator identity required; physical admission is unavailable")
        }
        let ns = try LoopArithmetic.multiply(frameUS, 1_000)
        frameNanoseconds = ns; channels = count
        return (count, true, ns)
    }

    public func armSimulator(untilFrame: UInt64, hostTimeoutNanoseconds: UInt64) async throws {
        guard !busy, !latched, stopped, frameNanoseconds != nil, channels != nil,
              (1_000_000...1_000_000_000).contains(hostTimeoutNanoseconds) else {
            throw ClosedLoopError.invalid("verify simulator identity before one-shot arming")
        }
        busy = true; defer { busy = false }
        struct P: Codable, Sendable { var armed_until_frame: UInt64; var watchdog_ns: UInt64 }
        let response = try await call("arm-simulator",
            P(armed_until_frame: untilFrame, watchdog_ns: hostTimeoutNanoseconds), timeout: 1_000_000_000)
        guard !latched, response.simulator == true, response.armed_until_frame == untilFrame,
              let now = response.frame, now < untilFrame else {
            try? await stop(reason: "simulator arm response mismatch")
            throw ClosedLoopError.unsafe("simulator arm identity/expiry")
        }
        stopped = false; leaseExpiry = untilFrame
    }

    @available(*, unavailable, message: "Manual arming bypass removed. Use verified simulator identity plus armSimulator; physical admission is unsupported.")
    public func markArmedForVerifiedSidecar() {}

    @available(*, unavailable, message: "Explicit complete-waveform deadlineFrame is required.")
    public func submit(id: UUID, pulses: [Pulse]) async throws -> NeuralStimulationReceipt {
        throw ClosedLoopError.invalid("explicit deadline required")
    }

    public func submit(id: UUID, pulses: [Pulse], deadlineFrame: UInt64) async throws -> NeuralStimulationReceipt {
        guard !busy, !stopped, !latched, submitted[id] == nil, submitted.count < 10_000,
              let frameNanoseconds, let channels, let leaseExpiry,
              !pulses.isEmpty, pulses.count <= 64,
              Set(pulses.map(\.channel)).count == pulses.count,
              Set(pulses.map(\.timestamp_frames)).count == 1,
              deadlineFrame <= leaseExpiry else {
            throw ClosedLoopError.invalid("CL simulator request state, bounds or deadline")
        }
        for pulse in pulses {
            guard pulse.channel >= 0, pulse.channel < channels,
                  (2...3).contains(pulse.phases.count), pulse.timestamp_frames < deadlineFrame else {
                throw ClosedLoopError.invalid("CL simulator channel/phase count")
            }
            var signed = 0.0, absolute = 0.0
            for phase in pulse.phases {
                guard (20...20_000).contains(phase.duration_us), phase.duration_us.isMultiple(of: 20),
                      phase.current_ua.isFinite, abs(phase.current_ua) <= 3 else {
                    throw ClosedLoopError.invalid("CL simulator waveform representation")
                }
                signed += Double(phase.duration_us) * phase.current_ua
                absolute += Double(phase.duration_us) * abs(phase.current_ua)
            }
            guard absolute > 0, abs(signed) <= absolute * 1e-6 else {
                throw ClosedLoopError.invalid("simulator waveform must be charge balanced")
            }
        }
        busy = true; defer { busy = false }
        struct P: Codable, Sendable { var id: String; var pulses: [Pulse]; var deadline_frame: UInt64 }
        submitted[id] = .init(pulses: pulses, deadlineFrame: deadlineFrame)
        do {
            let response = try await call("stim.submit", P(id: id.uuidString.lowercased(), pulses: pulses,
                deadline_frame: deadlineFrame), timeout: 1_000_000_000)
            guard !stopped, !latched, response.simulator == true, UUID(uuidString: response.id ?? "") == id,
                  response.status == "accepted", let accepted = response.accepted_frame,
                  let scheduled = response.scheduled_frame, scheduled == pulses[0].timestamp_frames,
                  accepted <= scheduled, let end = response.end_frame, end <= deadlineFrame else {
                throw ClosedLoopError.ambiguousDelivery(id)
            }
            submitted[id]?.acceptedFrame = accepted
            return .init(requestID: id, status: .accepted,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(accepted, frameNanoseconds),
                message: "SDK simulator accepted; not physical execution evidence")
        } catch {
            _ = try? await stop(reason: "simulator submission failed or ambiguous")
            throw ClosedLoopError.ambiguousDelivery(id)
        }
    }

    public func reconcile(id: UUID) async throws -> NeuralStimulationReceipt {
        guard !busy, let frameNanoseconds, let request = submitted[id] else {
            throw ClosedLoopError.invalid("unknown simulator request")
        }
        busy = true; defer { busy = false }
        struct P: Codable, Sendable { var id: String }
        let response = try await call("stim.observe", P(id: id.uuidString.lowercased()), timeout: 2_000_000_000)
        guard response.simulator == true, UUID(uuidString: response.id ?? "") == id,
              let accepted = response.accepted_frame, let scheduled = response.scheduled_frame,
              scheduled == request.pulses[0].timestamp_frames, accepted <= scheduled,
              request.acceptedFrame.map({ $0 == accepted }) ?? true else {
            throw ClosedLoopError.ambiguousDelivery(id)
        }
        switch response.status {
        case "executed":
            let expected = Set(request.pulses.map { SidecarResponse.ObservedStim(timestamp: $0.timestamp_frames, channel: $0.channel) })
            guard let observed = response.observed_stims, observed.count == expected.count,
                  Set(observed) == expected else { throw ClosedLoopError.ambiguousDelivery(id) }
            return .init(requestID: id, status: .executed,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(accepted, frameNanoseconds),
                executedAtNanoseconds: try LoopArithmetic.multiply(scheduled, frameNanoseconds),
                message: "Exact SDK simulator Stim events matched; electrode voltage/charge was not physically measured")
        case "accepted":
            return .init(requestID: id, status: .accepted,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(accepted, frameNanoseconds),
                message: "SDK simulator delivery pending")
        default: throw ClosedLoopError.ambiguousDelivery(id)
        }
    }

    private func call<P: Codable & Sendable>(_ op: String, _ payload: P, timeout: UInt64) async throws -> SidecarResponse {
        let payloadData = try JSONEncoder().encode(payload)
        guard var object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ClosedLoopError.invalid("sidecar payload object")
        }
        object["op"] = op
        let request = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard request.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar request") }
        let data = try await transport.exchange(request, timeoutNanoseconds: timeout)
        guard data.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar response") }
        let response = try JSONDecoder().decode(SidecarResponse.self, from: data)
        guard response.ok else { throw ClosedLoopError.unsafe(response.message ?? response.code ?? "sidecar rejection") }
        return response
    }
}

/// FinalSpark public network API is not represented as an exact-timestamp, autonomous-watchdog
/// NeuralCultureBackend. No configuration/trigger acknowledgement is a measured delivery receipt.
public struct FinalSparkAuditedContract: Sendable {
    public static let minimumPostUploadSettleNanoseconds: UInt64 = 5_000_000_000
    public static let exactRealtimeSchedulingSupported = false
    public static let deliveryReceiptSupported = false
    public static let requiredCleanupOperation = "IntanController.disable_all_stim"
    public static func validateTrigger(_ values: [Int]) throws {
        guard values.count == 16 else { throw ClosedLoopError.invalid("FinalSpark trigger requires exactly 16 integers") }
    }
    public static func requireSettled(uploadCompletedHostNanoseconds: UInt64, currentHostNanoseconds: UInt64) throws {
        guard currentHostNanoseconds >= uploadCompletedHostNanoseconds,
              currentHostNanoseconds - uploadCompletedHostNanoseconds >= minimumPostUploadSettleNanoseconds else {
            throw ClosedLoopError.unsafe("FinalSpark stimulation configuration is still settling")
        }
    }
    public static func rejectAsHardRealtimeBackend() throws -> Never {
        throw ClosedLoopError.unsafe("FinalSpark public network API cannot satisfy exact device-clock closed-loop semantics")
    }
}
