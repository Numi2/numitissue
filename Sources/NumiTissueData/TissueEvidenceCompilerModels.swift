import Foundation
import NumiTissueCore
import NumiTissueModels

public enum TissueEvidenceDiagnosticSeverity: String, Codable, Sendable, CaseIterable {
    case information
    case warning
    case error
}

public struct TissueEvidenceDiagnostic: Codable, Sendable, Equatable {
    public var severity: TissueEvidenceDiagnosticSeverity
    public var code: String
    public var path: String
    public var message: String
    public var evidenceRecordIDs: [String]

    public init(
        severity: TissueEvidenceDiagnosticSeverity,
        code: String,
        path: String,
        message: String,
        evidenceRecordIDs: [String] = []
    ) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
        self.evidenceRecordIDs = evidenceRecordIDs
    }
}

public struct TissueEvidenceCompilerConfiguration: Codable, Sendable, Equatable {
    public var modelSchemaVersion: UInt32
    public var minimumObjectConfidence: Double
    public var rejectIncompleteMorphologies: Bool
    public var rejectUnresolvedEvidence: Bool
    public var maximumAllowedConflict: Double
    public var allowAutapses: Bool
    public var normalizeOrientations: Bool
    public var metadataValueByteLimit: Int

    public init(
        modelSchemaVersion: UInt32 = NumiTissueCore.NumiTissueBuild.modelSchemaVersion,
        minimumObjectConfidence: Double = 0.2,
        rejectIncompleteMorphologies: Bool = false,
        rejectUnresolvedEvidence: Bool = false,
        maximumAllowedConflict: Double = 0.85,
        allowAutapses: Bool = false,
        normalizeOrientations: Bool = true,
        metadataValueByteLimit: Int = 16_384
    ) {
        self.modelSchemaVersion = modelSchemaVersion
        self.minimumObjectConfidence = minimumObjectConfidence
        self.rejectIncompleteMorphologies = rejectIncompleteMorphologies
        self.rejectUnresolvedEvidence = rejectUnresolvedEvidence
        self.maximumAllowedConflict = maximumAllowedConflict
        self.allowAutapses = allowAutapses
        self.normalizeOrientations = normalizeOrientations
        self.metadataValueByteLimit = metadataValueByteLimit
    }

    public func validated() throws -> Self {
        guard modelSchemaVersion > 0,
              minimumObjectConfidence.isFinite,
              (0...1).contains(minimumObjectConfidence),
              maximumAllowedConflict.isFinite,
              (0...1).contains(maximumAllowedConflict),
              metadataValueByteLimit >= 256 else {
            throw TissueEvidenceCompilerError.invalidConfiguration
        }
        return self
    }
}

public struct TissueEvidenceCompilationReport: Codable, Sendable, Equatable {
    public var blueprintDigest: String
    public var sourceDatasetReferences: [String]
    public var evidenceRecordCount: Int
    public var resolvedEvidenceCount: Int
    public var unresolvedEvidenceCount: Int
    public var provenanceNodeCount: Int
    public var provenanceEdgeCount: Int
    public var identifierRegistry: StableIdentifierRegistry
    public var diagnostics: [TissueEvidenceDiagnostic]

    public init(
        blueprintDigest: String,
        sourceDatasetReferences: [String],
        evidenceRecordCount: Int,
        resolvedEvidenceCount: Int,
        unresolvedEvidenceCount: Int,
        provenanceNodeCount: Int,
        provenanceEdgeCount: Int,
        identifierRegistry: StableIdentifierRegistry,
        diagnostics: [TissueEvidenceDiagnostic]
    ) {
        self.blueprintDigest = blueprintDigest
        self.sourceDatasetReferences = sourceDatasetReferences
        self.evidenceRecordCount = evidenceRecordCount
        self.resolvedEvidenceCount = resolvedEvidenceCount
        self.unresolvedEvidenceCount = unresolvedEvidenceCount
        self.provenanceNodeCount = provenanceNodeCount
        self.provenanceEdgeCount = provenanceEdgeCount
        self.identifierRegistry = identifierRegistry
        self.diagnostics = diagnostics
    }

    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

public struct TissueEvidenceCompilation: Sendable {
    public var model: TissueModel
    public var report: TissueEvidenceCompilationReport

    public init(model: TissueModel, report: TissueEvidenceCompilationReport) {
        self.model = model
        self.report = report
    }
}

public struct ExecutableTissueEvidenceCompilation: Sendable {
    public var source: TissueEvidenceCompilation
    public var executable: CompiledTissueModel

    public init(
        source: TissueEvidenceCompilation,
        executable: CompiledTissueModel
    ) {
        self.source = source
        self.executable = executable
    }
}

public enum TissueEvidenceCompilerError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case lowConfidence(path: String, confidence: Double)
    case incompleteMorphology(String)
    case unresolvedEvidence(Int)
    case evidenceConflict(path: String, score: Double)
    case autapseRejected(String)
    case nonRepresentableFloat(path: String, value: Double)
    case missingReference(String)
    case metadataValueTooLarge(key: String, bytes: Int)
    case invalidOrientation(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Tissue evidence compiler configuration is invalid."
        case .lowConfidence(let path, let confidence):
            return "Canonical object \(path) confidence \(confidence) is below the compiler threshold."
        case .incompleteMorphology(let identifier):
            return "Morphology \(identifier) is incomplete and incomplete morphologies are disabled."
        case .unresolvedEvidence(let count):
            return "Evidence fusion contains \(count) unresolved groups."
        case .evidenceConflict(let path, let score):
            return "Resolved evidence \(path) conflict score \(score) exceeds the compiler threshold."
        case .autapseRejected(let identifier):
            return "Synapse \(identifier) is an autapse and autapses are disabled."
        case .nonRepresentableFloat(let path, let value):
            return "Value \(value) at \(path) cannot be represented as Float."
        case .missingReference(let value):
            return "Tissue evidence compiler is missing reference \(value)."
        case .metadataValueTooLarge(let key, let bytes):
            return "Metadata value \(key) uses \(bytes) bytes and exceeds the configured limit."
        case .invalidOrientation(let identifier):
            return "Cell \(identifier) has an invalid orientation quaternion."
        }
    }
}
