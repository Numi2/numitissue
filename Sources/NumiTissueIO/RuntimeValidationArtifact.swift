import Foundation
import NumiTissueRuntime

public enum RuntimeValidationArtifactKind: String, Sendable, Hashable, Codable, CaseIterable {
    case differentialTransaction
    case rollbackCertificate
    case reproducibilityCertificate
    case benchmarkReport
    case compactStateDigest
}

public struct RuntimeValidationArtifact<Payload: Codable & Sendable>: Codable, Sendable {
    public var schemaVersion: UInt32
    public var kind: RuntimeValidationArtifactKind
    public var createdAt: Date
    public var payloadSHA256: ScientificSHA256Digest
    public var metadata: [String: String]
    public var payload: Payload

    public init(
        kind: RuntimeValidationArtifactKind,
        payload: Payload,
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) throws {
        guard metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw RuntimeValidationArtifactError.invalidMetadata
        }
        self.schemaVersion = 1
        self.kind = kind
        self.createdAt = createdAt
        self.payloadSHA256 = ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(payload)
        )
        self.metadata = metadata
        self.payload = payload
    }

    public func validated(
        expectedKind: RuntimeValidationArtifactKind? = nil
    ) throws -> Self {
        guard schemaVersion == 1 else {
            throw RuntimeValidationArtifactError.unsupportedSchema(schemaVersion)
        }
        if let expectedKind, kind != expectedKind {
            throw RuntimeValidationArtifactError.kindMismatch(
                expected: expectedKind,
                actual: kind
            )
        }
        guard metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw RuntimeValidationArtifactError.invalidMetadata
        }
        let actual = ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(payload)
        )
        guard actual == payloadSHA256 else {
            throw RuntimeValidationArtifactError.payloadDigestMismatch(
                expected: payloadSHA256,
                actual: actual
            )
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func artifactSHA256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public typealias DifferentialTransactionArtifact = RuntimeValidationArtifact<DifferentialTransactionReport>
public typealias RollbackCertificateArtifact = RuntimeValidationArtifact<RuntimeRollbackCertificate>
public typealias ReproducibilityCertificateArtifact = RuntimeValidationArtifact<RuntimeReproducibilityCertificate>
public typealias RuntimeBenchmarkArtifact = RuntimeValidationArtifact<RuntimeBenchmarkReport>

public enum RuntimeValidationArtifactIO {
    public static func makeDifferential(
        _ report: DifferentialTransactionReport,
        metadata: [String: String] = [:]
    ) throws -> DifferentialTransactionArtifact {
        try RuntimeValidationArtifact(
            kind: .differentialTransaction,
            payload: report,
            metadata: metadata
        )
    }

    public static func makeRollback(
        _ certificate: RuntimeRollbackCertificate,
        metadata: [String: String] = [:]
    ) throws -> RollbackCertificateArtifact {
        try RuntimeValidationArtifact(
            kind: .rollbackCertificate,
            payload: certificate,
            metadata: metadata
        )
    }

    public static func makeReproducibility(
        _ certificate: RuntimeReproducibilityCertificate,
        metadata: [String: String] = [:]
    ) throws -> ReproducibilityCertificateArtifact {
        try RuntimeValidationArtifact(
            kind: .reproducibilityCertificate,
            payload: certificate,
            metadata: metadata
        )
    }

    public static func makeBenchmark(
        _ report: RuntimeBenchmarkReport,
        metadata: [String: String] = [:]
    ) throws -> RuntimeBenchmarkArtifact {
        try RuntimeValidationArtifact(
            kind: .benchmarkReport,
            payload: report,
            metadata: metadata
        )
    }

    public static func encode<Payload>(
        _ artifact: RuntimeValidationArtifact<Payload>
    ) throws -> Data where Payload: Codable & Sendable {
        try artifact.canonicalData()
    }

    public static func decode<Payload>(
        _ type: Payload.Type,
        from data: Data,
        expectedKind: RuntimeValidationArtifactKind
    ) throws -> RuntimeValidationArtifact<Payload>
    where Payload: Codable & Sendable {
        let artifact = try ScientificCanonicalJSON.decode(
            RuntimeValidationArtifact<Payload>.self,
            from: data
        )
        return try artifact.validated(expectedKind: expectedKind)
    }

    public static func write<Payload>(
        _ artifact: RuntimeValidationArtifact<Payload>,
        to url: URL,
        overwrite: Bool = false
    ) throws where Payload: Codable & Sendable {
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw RuntimeValidationArtifactError.destinationExists(url.path)
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        try artifact.canonicalData().write(to: url, options: [.atomic])
    }

    public static func read<Payload>(
        _ type: Payload.Type,
        from url: URL,
        expectedKind: RuntimeValidationArtifactKind
    ) throws -> RuntimeValidationArtifact<Payload>
    where Payload: Codable & Sendable {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(type, from: data, expectedKind: expectedKind)
    }
}

public struct RuntimeValidationArtifactProbe: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var kind: RuntimeValidationArtifactKind
    public var createdAt: Date
    public var payloadSHA256: ScientificSHA256Digest
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32,
        kind: RuntimeValidationArtifactKind,
        createdAt: Date,
        payloadSHA256: ScientificSHA256Digest,
        metadata: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.createdAt = createdAt
        self.payloadSHA256 = payloadSHA256
        self.metadata = metadata
    }
}

public enum RuntimeValidationArtifactInspector {
    public static func probe(data: Data) throws -> RuntimeValidationArtifactProbe {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe = try decoder.decode(RuntimeValidationArtifactProbe.self, from: data)
        guard probe.schemaVersion == 1 else {
            throw RuntimeValidationArtifactError.unsupportedSchema(
                probe.schemaVersion
            )
        }
        return probe
    }

    public static func probe(url: URL) throws -> RuntimeValidationArtifactProbe {
        try probe(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func verify(data: Data) throws -> RuntimeValidationArtifactProbe {
        let probe = try self.probe(data: data)
        switch probe.kind {
        case .differentialTransaction:
            _ = try RuntimeValidationArtifactIO.decode(
                DifferentialTransactionReport.self,
                from: data,
                expectedKind: .differentialTransaction
            )
        case .rollbackCertificate:
            _ = try RuntimeValidationArtifactIO.decode(
                RuntimeRollbackCertificate.self,
                from: data,
                expectedKind: .rollbackCertificate
            )
        case .reproducibilityCertificate:
            _ = try RuntimeValidationArtifactIO.decode(
                RuntimeReproducibilityCertificate.self,
                from: data,
                expectedKind: .reproducibilityCertificate
            )
        case .benchmarkReport:
            _ = try RuntimeValidationArtifactIO.decode(
                RuntimeBenchmarkReport.self,
                from: data,
                expectedKind: .benchmarkReport
            )
        case .compactStateDigest:
            throw RuntimeValidationArtifactError.payloadTypeRequired(
                probe.kind
            )
        }
        return probe
    }

    public static func verify(url: URL) throws -> RuntimeValidationArtifactProbe {
        try verify(data: Data(contentsOf: url, options: [.mappedIfSafe]))
    }
}

public enum RuntimeValidationArtifactError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case kindMismatch(
        expected: RuntimeValidationArtifactKind,
        actual: RuntimeValidationArtifactKind
    )
    case invalidMetadata
    case payloadDigestMismatch(
        expected: ScientificSHA256Digest,
        actual: ScientificSHA256Digest
    )
    case destinationExists(String)
    case payloadTypeRequired(RuntimeValidationArtifactKind)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported runtime validation artifact schema \(version)"
        case .kindMismatch(let expected, let actual):
            return "Runtime validation artifact kind is \(actual.rawValue), expected \(expected.rawValue)"
        case .invalidMetadata:
            return "Runtime validation artifact metadata contains an empty key"
        case .payloadDigestMismatch(let expected, let actual):
            return "Runtime validation payload SHA-256 mismatch: expected \(expected), actual \(actual)"
        case .destinationExists(let path):
            return "Runtime validation artifact destination already exists: \(path)"
        case .payloadTypeRequired(let kind):
            return "Verification of \(kind.rawValue) requires its payload type"
        }
    }
}
