import Foundation
import NumiTissueIO

public protocol NeuralDeviceSidecarTransport: Sendable {
    func exchange(_ request: Data, timeoutNanoseconds: UInt64) async throws -> Data
}

private struct SidecarResponse: Codable, Sendable {
    var ok: Bool; var code: String?; var message: String?; var frame: UInt64?
    var frame_duration_us: UInt64?; var channels: Int?; var simulator: Bool?; var stop_confirmed: Bool?
    var id: String?; var status: String?; var accepted_frame: UInt64?; var scheduled_frame: UInt64?
    var delivery: String?; var observed_stims: [ObservedStim]?
    struct ObservedStim: Codable, Sendable { var timestamp: UInt64; var channel: Int }
}

/// CL1 adapter semantics follow the public CL API: frame timestamps, 80-us minimum lead,
/// 20-us stimulation quantum, interrupt() cancellation and observed Stim events for reconciliation.
/// This wrapper cannot arm itself; the embedding application must first verify sidecar identity,
/// simulator/physical mode and an operator lease, then call markArmedForVerifiedSidecar().
public actor CL1AuditedAdapter {
    public struct Phase: Codable, Sendable { public var duration_us: UInt64; public var current_ua: Double }
    public struct Pulse: Codable, Sendable { public var channel: Int; public var timestamp_frames: UInt64; public var phases: [Phase] }
    private let transport: any NeuralDeviceSidecarTransport
    private let encoder = JSONEncoder(), decoder = JSONDecoder()
    private var stopped = true
    private var submitted = Set<UUID>()
    private var frameNanoseconds: UInt64?
    public init(transport: any NeuralDeviceSidecarTransport) { self.transport = transport }

    public func stop(reason: String) async throws -> Bool {
        stopped = true
        struct P: Codable { var reason: String }
        let response = try await call("stop", P(reason: reason), timeout: 1_000_000_000)
        return response.stop_confirmed == true
    }

    public func verifyIdentity() async throws -> (channels: Int, simulator: Bool, frameNanoseconds: UInt64) {
        struct Empty: Codable {}
        let response = try await call("identity", Empty(), timeout: 1_000_000_000)
        guard let channels = response.channels, channels > 0, channels <= 4096,
              let simulator = response.simulator, let frameUS = response.frame_duration_us, frameUS > 0 else {
            throw ClosedLoopError.invalid("CL1 identity/capabilities")
        }
        let ns = try LoopArithmetic.multiply(frameUS, 1_000)
        frameNanoseconds = ns
        return (channels, simulator, ns)
    }

    public func submit(id: UUID, pulses: [Pulse]) async throws -> NeuralStimulationReceipt {
        guard !stopped, !submitted.contains(id), let frameNanoseconds,
              !pulses.isEmpty, pulses.count <= 64,
              pulses.allSatisfy({ $0.phases.count == 2 || $0.phases.count == 4 || $0.phases.count == 6 }) else {
            throw ClosedLoopError.invalid("CL1 request state or shape")
        }
        struct P: Codable { var id: String; var pulses: [Pulse] }
        submitted.insert(id)
        do {
            let response = try await call("stim.submit", P(id: id.uuidString, pulses: pulses), timeout: 1_000_000_000)
            guard response.id == id.uuidString, let accepted = response.accepted_frame,
                  let scheduled = response.scheduled_frame, accepted <= scheduled else {
                stopped = true; throw ClosedLoopError.ambiguousDelivery(id)
            }
            return .init(requestID: id, status: .accepted,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(accepted, frameNanoseconds),
                message: "CL1 queued; delivery requires observed Stim reconciliation")
        } catch { stopped = true; throw ClosedLoopError.ambiguousDelivery(id) }
    }

    public func reconcile(id: UUID) async throws -> NeuralStimulationReceipt {
        guard let frameNanoseconds else { throw ClosedLoopError.invalid("CL1 identity not verified") }
        struct P: Codable { var id: String }
        let response = try await call("stim.observe", P(id: id.uuidString), timeout: 2_000_000_000)
        guard response.id == id.uuidString else { throw ClosedLoopError.ambiguousDelivery(id) }
        switch response.status {
        case "executed":
            guard let scheduled = response.scheduled_frame,
                  let observed = response.observed_stims, !observed.isEmpty,
                  observed.allSatisfy({ $0.timestamp == scheduled }) else { throw ClosedLoopError.ambiguousDelivery(id) }
            return .init(requestID: id, status: .executed,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(response.accepted_frame ?? scheduled, frameNanoseconds),
                executedAtNanoseconds: try LoopArithmetic.multiply(scheduled, frameNanoseconds),
                message: "CL1 stimulation observed in device analysis stream")
        case "accepted":
            return .init(requestID: id, status: .accepted,
                acceptedAtNanoseconds: try LoopArithmetic.multiply(response.accepted_frame ?? 0, frameNanoseconds),
                message: "CL1 delivery pending observation")
        default: throw ClosedLoopError.ambiguousDelivery(id)
        }
    }

    public func markArmedForVerifiedSidecar() { stopped = false }

    private func call<P: Codable & Sendable>(_ op: String, _ payload: P, timeout: UInt64) async throws -> SidecarResponse {
        // The Python sidecar intentionally uses a flat JSON object so logs are directly inspectable.
        let payloadData = try encoder.encode(payload)
        guard var object = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw ClosedLoopError.invalid("sidecar payload must encode as an object")
        }
        object["op"] = op
        let request = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard request.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar request") }
        let data = try await transport.exchange(request, timeoutNanoseconds: timeout)
        guard data.count <= 1_048_576 else { throw ClosedLoopError.capacity("sidecar response") }
        let response = try decoder.decode(SidecarResponse.self, from: data)
        if !response.ok { throw ClosedLoopError.unsafe(response.message ?? response.code ?? "sidecar rejection") }
        return response
    }
}

/// FinalSpark NeuroPlatform v2 is network-mediated. Public documentation specifies at least five
/// seconds after upload_stimparam before triggering/reading and says <200-ms loops are challenging.
/// Therefore it is not represented as an exact-timestamp NeuralCultureBackend. Delivery remains
/// unknown unless separately measured; cleanup must call IntanController.disable_all_stim().
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
