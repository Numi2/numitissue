import Foundation
import NumiTissueRuntime

@frozen
public struct CPUReferenceCheckpointState: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var eventWheel: EventDelayWheelSnapshot

    public init(
        schemaVersion: UInt32 = 1,
        eventWheel: EventDelayWheelSnapshot
    ) {
        self.schemaVersion = schemaVersion
        self.eventWheel = eventWheel
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw CPUReferenceCheckpointStateError.unsupportedVersion(
                schemaVersion
            )
        }
        _ = try eventWheel.validated()
        return self
    }
}

extension CPUReferenceTissueBackend: RuntimeBackendCheckpointStateProvider {
    nonisolated public var checkpointBackendIdentifier: String {
        "numitissue.reference.cpu"
    }

    public func validateBackendCheckpointState(
        _ data: Data,
        committedState: TissueRuntimeState
    ) async throws {
        let payload = try Self.decodeCheckpointState(data)
        guard payload.eventWheel.originTick == committedState.time.tick else {
            throw CPUReferenceBackendError.eventWheelStateMismatch(
                wheel: payload.eventWheel.originTick,
                committed: committedState.time.tick
            )
        }
    }

    public func exportBackendCheckpointState() async throws -> Data {
        let snapshot = try await exportEventWheelSnapshot()
        let payload = try CPUReferenceCheckpointState(
            eventWheel: snapshot
        ).validated()
        return try RuntimeBackendCheckpointArchive.encode(
            backendIdentifier: checkpointBackendIdentifier,
            payloadVersion: 1,
            payload: payload,
            metadata: [
                "numitissue.state": "committed",
                "numitissue.event-order": "timestamp-destination-source-kind-sequence"
            ]
        )
    }

    public func restoreBackendCheckpointState(_ data: Data) async throws {
        let payload = try Self.decodeCheckpointState(data)
        try await restoreEventWheelSnapshot(payload.eventWheel)
    }

    private nonisolated static func decodeCheckpointState(
        _ data: Data
    ) throws -> CPUReferenceCheckpointState {
        try RuntimeBackendCheckpointArchive.decode(
            CPUReferenceCheckpointState.self,
            from: data,
            expectedBackendIdentifier: "numitissue.reference.cpu",
            expectedPayloadVersion: 1
        ).validated()
    }
}

public enum CPUReferenceCheckpointStateError: Error, Sendable, CustomStringConvertible {
    case unsupportedVersion(UInt32)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported CPU-reference checkpoint-state version \(version)."
        }
    }
}
