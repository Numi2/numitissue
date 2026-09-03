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

    public func exportBackendCheckpointState() async throws -> Data {
        let payload = try CPUReferenceCheckpointState(
            eventWheel: exportEventWheelSnapshot()
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
        let payload = try RuntimeBackendCheckpointArchive.decode(
            CPUReferenceCheckpointState.self,
            from: data,
            expectedBackendIdentifier: checkpointBackendIdentifier,
            expectedPayloadVersion: 1
        ).validated()
        try restoreEventWheelSnapshot(payload.eventWheel)
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
