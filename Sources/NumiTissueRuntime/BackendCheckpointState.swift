import Foundation

/// Backends use this envelope for runtime state that is not represented by `TissueRuntimeState`,
/// such as delayed events, backend-specific random streams, and resumable scheduler state.
@frozen
public struct RuntimeBackendCheckpointEnvelope: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var backendIdentifier: String
    public var payloadVersion: UInt32
    public var payload: Data
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        backendIdentifier: String,
        payloadVersion: UInt32,
        payload: Data,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.backendIdentifier = backendIdentifier
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.metadata = metadata
    }

    public func validated(
        expectedBackendIdentifier: String? = nil,
        maximumPayloadBytes: Int = 512 * 1_024 * 1_024
    ) throws -> Self {
        guard schemaVersion == 1 else {
            throw RuntimeBackendCheckpointError.unsupportedEnvelopeVersion(
                schemaVersion
            )
        }
        guard !backendIdentifier.isEmpty,
              payloadVersion > 0,
              payload.count <= maximumPayloadBytes,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw RuntimeBackendCheckpointError.invalidEnvelope
        }
        if let expectedBackendIdentifier,
           backendIdentifier != expectedBackendIdentifier {
            throw RuntimeBackendCheckpointError.backendMismatch(
                expected: expectedBackendIdentifier,
                actual: backendIdentifier
            )
        }
        return self
    }
}

/// A backend that can preserve all state needed for deterministic continuation across a process
/// boundary. Implementations must export committed state only and reject restore during an open
/// transaction.
public protocol RuntimeBackendCheckpointStateProvider: NumiTissueExecutionBackend {
    var checkpointBackendIdentifier: String { get }
    func exportBackendCheckpointState() async throws -> Data
    func restoreBackendCheckpointState(_ data: Data) async throws
}

public enum RuntimeBackendCheckpointArchive {
    public static func encode<Payload: Encodable>(
        backendIdentifier: String,
        payloadVersion: UInt32,
        payload: Payload,
        metadata: [String: String] = [:]
    ) throws -> Data {
        guard !backendIdentifier.isEmpty, payloadVersion > 0 else {
            throw RuntimeBackendCheckpointError.invalidEnvelope
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadData: Data
        do {
            payloadData = try encoder.encode(payload)
        } catch {
            throw RuntimeBackendCheckpointError.payloadEncoding(
                String(describing: error)
            )
        }
        let envelope = try RuntimeBackendCheckpointEnvelope(
            backendIdentifier: backendIdentifier,
            payloadVersion: payloadVersion,
            payload: payloadData,
            metadata: metadata
        ).validated()
        do {
            return try encoder.encode(envelope)
        } catch {
            throw RuntimeBackendCheckpointError.envelopeEncoding(
                String(describing: error)
            )
        }
    }

    public static func decode<Payload: Decodable>(
        _ type: Payload.Type,
        from data: Data,
        expectedBackendIdentifier: String,
        expectedPayloadVersion: UInt32,
        maximumEnvelopeBytes: Int = 512 * 1_024 * 1_024
    ) throws -> Payload {
        guard data.count <= maximumEnvelopeBytes else {
            throw RuntimeBackendCheckpointError.envelopeTooLarge(data.count)
        }
        let decoder = PropertyListDecoder()
        let envelope: RuntimeBackendCheckpointEnvelope
        do {
            envelope = try decoder.decode(
                RuntimeBackendCheckpointEnvelope.self,
                from: data
            )
        } catch {
            throw RuntimeBackendCheckpointError.envelopeDecoding(
                String(describing: error)
            )
        }
        let validated = try envelope.validated(
            expectedBackendIdentifier: expectedBackendIdentifier,
            maximumPayloadBytes: maximumEnvelopeBytes
        )
        guard validated.payloadVersion == expectedPayloadVersion else {
            throw RuntimeBackendCheckpointError.unsupportedPayloadVersion(
                validated.payloadVersion
            )
        }
        do {
            return try decoder.decode(type, from: validated.payload)
        } catch {
            throw RuntimeBackendCheckpointError.payloadDecoding(
                String(describing: error)
            )
        }
    }
}

public enum RuntimeBackendCheckpointError: Error, Sendable, CustomStringConvertible {
    case unsupportedEnvelopeVersion(UInt32)
    case unsupportedPayloadVersion(UInt32)
    case invalidEnvelope
    case backendMismatch(expected: String, actual: String)
    case envelopeTooLarge(Int)
    case payloadEncoding(String)
    case envelopeEncoding(String)
    case envelopeDecoding(String)
    case payloadDecoding(String)

    public var description: String {
        switch self {
        case .unsupportedEnvelopeVersion(let version):
            return "Unsupported backend-checkpoint envelope version \(version)."
        case .unsupportedPayloadVersion(let version):
            return "Unsupported backend-checkpoint payload version \(version)."
        case .invalidEnvelope:
            return "Backend-checkpoint envelope is invalid."
        case .backendMismatch(let expected, let actual):
            return "Checkpoint backend \(actual) does not match required backend \(expected)."
        case .envelopeTooLarge(let bytes):
            return "Backend-checkpoint envelope exceeds the bounded size: \(bytes) bytes."
        case .payloadEncoding(let reason):
            return "Backend-checkpoint payload encoding failed: \(reason)"
        case .envelopeEncoding(let reason):
            return "Backend-checkpoint envelope encoding failed: \(reason)"
        case .envelopeDecoding(let reason):
            return "Backend-checkpoint envelope decoding failed: \(reason)"
        case .payloadDecoding(let reason):
            return "Backend-checkpoint payload decoding failed: \(reason)"
        }
    }
}
