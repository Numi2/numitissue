import Foundation
import NumiTissueIO

/// Process boundary used by vendor SDK sidecars. Production transports must enforce one child process,
/// bounded JSON messages, stderr capture, process-death stop escalation and no shell interpolation.
public protocol NeuralDeviceSidecarTransport: Sendable {
    func exchange(_ request: Data, timeoutNanoseconds: UInt64) async throws -> Data
}

private struct SidecarEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    var op: String
    var payload: Payload
}
private struct SidecarResponse: Codable, Sendable {
    var ok: Bool
    var code: String?
    var message: String?
    var frame: UInt64?
    var frame_duration_us: UInt64?
    var channels: Int?
    var simulator: Bool?
    var stop_confirmed: Bool?
    var id: String?
    var status: String?
    var accepted_frame: UInt64?
    var scheduled_frame: UInt64?
    var delivery: String?
    var observed_stims: [ObservedStim]?
    struct ObservedStim: Codable, Sendable { var timestamp: UInt64; var channel: Int }
}

/// CL1 adapter semantics follow the public CL API: 25 kHz frame timestamps, 80-us minimum lead,
/// 20-us lead/phase quantum, interrupt() for queued-channel cancellation, and analysis Stim events
/// for delivery reconciliation. cl.open() does not itself stop the device.
public actor CL1AuditedAdapter {
    public struct Identity: Codable, Sendable {
        public var systemID: String; public var chipID: String; public var cellBatchID: String
    }
    public struct Phase: Codable, Sendable { public var duration_us: UInt64; public var current_ua: Double }
    public struct Pulse: Codable, Sendable {
        public var channel: Int; public var timestamp_frames: UInt64; public var phases: [Phase]
    }
    private let transport: any NeuralDeviceSidecarTransport
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    private var stopped = true
    private var submitted = Set<UUID>()
    public init(transport: any NeuralDeviceSidecarTransport) { self.transport = transport }

    public func stop(reason: String) async throws -> Bool {
        stopped = true
        struct P: Codable { var reason: String }
        let response = try await call("stop", P(reason: reason), timeout: 1_000_000_000)
        return response.ok && response.stop_confirmed == true
    }

    public func submit(id: UUID, pulses: [Pulse]) async throws -> NeuralStimulationReceipt {
        guard !stopped, !submitted.contains(id), !pulses.isEmpty, pulses.count <= 64,
              pulses.allSatisfy({ $0.phases.count == 2 || $0.phases.count == 4 || $0.phases.count == 6 }) else {
            throw ClosedLoopError.invalid("CL1 request state or shape")
        }
        struct P: Codable { var id: String; var pulses: [Pulse] }
        submitted.insert(id) // at-most-once before suspension
        do {
            let response = try await call("stim.submit", P(id: id.uuidString, pulses: pulses), timeout: 1_000_000_000)
            guard response.ok, response.id == id.uuidString, let accepted = response.accepted_frame,
                  let scheduled = response.scheduled_frame, accepted <= scheduled else {
                stopped = true; throw ClosedLoopError.ambiguousDelivery(id)
            }
            return .init(requestID: id, status: .accepted, acceptedAtNanoseconds: accepted * 40_000,
                         executedAtNanoseconds: nil, message: "CL1 queued; delivery requires Stim observation")
        } catch {
            stopped = true
            throw ClosedLoopError.ambiguousDelivery(id)
        }
    }

    public func reconcile(id: UUID) async throws -> NeuralStimulationReceipt {
        struct P: Codable { var id: String }
        let response = try await call("stim.observe", P(id: id.uuidString), timeout: 2_000_000_000)
        guard response.ok, response.id == id.uuidString else { throw ClosedLoopError.ambiguousDelivery(id) }
        switch response.status {
        case "executed":
            guard let scheduled = response.scheduled_frame,
                  let observed = response.observed_stims, !observed.isEmpty,
                  observed.allSatisfy({ $0.timestamp == scheduled }) else {
                throw ClosedLoopError.ambiguousDelivery(id)
            }
            return .init(requestID: id, status: .executed,
                         acceptedAtNanoseconds: (response.accepted_frame ?? scheduled) * 40_000,
                         executedAtNanoseconds: scheduled * 40_000,
                         message: "CL1 stimulation observed in device analysis stream")
        case "accepted":
            return .init(requestID: id, status: .accepted,
                         acceptedAtNanoseconds: (response.accepted_frame ?? 0) * 40_000,
                         message: "CL1 delivery still pending observation")
        default: throw ClosedLoopError.ambiguousDelivery(id)
        }
    }

    public func markArmedForVerifiedSidecar() { stopped = false }

    private func call<P: Codable & Sendable>(_ op: String, _ payload: P, timeout: UInt64) async throws -> SidecarResponse {
        let request = try encoder.encode(SidecarEnvelope(op: op, payload: payload))
        guard request.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar request") }
        let data = try await transport.exchange(request, timeoutNanoseconds: timeout)
        guard data.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar response") }
        let response = try decoder.decode(SidecarResponse.self, from: data)
        if !response.ok { throw ClosedLoopError.unsafe(response.message ?? response.code ?? "sidecar rejection") }
        return response
    }
}

/// FinalSpark public NeuroPlatform v2 is network-mediated. Its documentation states a minimum
/// 5-second recovery after uploading stimulation parameters and describes <200-ms closed loops as
/// challenging. Therefore this adapter deliberately DOES NOT implement exact-timestamp
/// `NeuralCultureBackend.stimulate`. It exposes configuration/trigger evidence as an asynchronous
/// experimental action whose physical delivery remains unknown unless separately measured.
public struct FinalSparkAuditedContract: Sendable {
    public static let minimumPostUploadSettleNanoseconds: UInt64 = 5_000_000_000
    public static let exactRealtimeSchedulingSupported = false
    public static let deliveryReceiptSupported = false
    public static let requiredCleanupOperation = "IntanController.disable_all_stim"

    public static func validateTrigger(_ values: [Int]) throws {
        guard values.count == 16 else { throw ClosedLoopError.invalid("FinalSpark trigger requires exactly 16 integers") }
    }

    public static func requireSettled(uploadCompletedHostNanoseconds: UInt64,
                                      currentHostNanoseconds: UInt64) throws {
        guard currentHostNanoseconds >= uploadCompletedHostNanoseconds,
              currentHostNanoseconds - uploadCompletedHostNanoseconds >= minimumPostUploadSettleNanoseconds else {
            throw ClosedLoopError.unsafe("FinalSpark stimulation configuration is still settling")
        }
    }

    public static func rejectAsHardRealtimeBackend() throws -> Never {
        throw ClosedLoopError.unsafe("FinalSpark public network API cannot satisfy exact device-clock closed-loop semantics")
    }
}
