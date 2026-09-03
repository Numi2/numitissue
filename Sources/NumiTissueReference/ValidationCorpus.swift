import Foundation
import NumiTissueCore
import NumiTissueIO

public enum ValidationDomain: String, Codable, Sendable, Hashable, CaseIterable {
    case electrophysiology
    case synapse
    case plasticity
    case molecular
    case extracellularField
    case metabolism
    case development
    case transaction
    case adaptiveFidelity
    case interoperability
}

public enum ValidationTier: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case smoke
    case analytical
    case crossSimulator
    case experimental

    public static func < (lhs: Self, rhs: Self) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ value: Self) -> Int {
        switch value {
        case .smoke: return 0
        case .analytical: return 1
        case .crossSimulator: return 2
        case .experimental: return 3
        }
    }
}

public enum ValidationReferenceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case analytical
    case invariant
    case neuron
    case arbor
    case steps
    case efel
    case experimental
    case numiTissueBaseline
}

public enum ValidationComparisonKind: String, Codable, Sendable, Hashable, CaseIterable {
    case scalar
    case trace
    case spikes
    case distribution
    case conservation
    case exactDigest
    case topologyInvariant
}

public struct ValidationReferenceSpecification: Codable, Sendable, Hashable {
    public var kind: ValidationReferenceKind
    public var engine: String
    public var version: String?
    public var artifactPath: String?
    public var sourceURI: String?
    public var citation: String?
    public var metadata: [String: String]

    public init(
        kind: ValidationReferenceKind,
        engine: String,
        version: String? = nil,
        artifactPath: String? = nil,
        sourceURI: String? = nil,
        citation: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.kind = kind
        self.engine = engine
        self.version = version
        self.artifactPath = artifactPath
        self.sourceURI = sourceURI
        self.citation = citation
        self.metadata = metadata
    }

    public func validated(caseID: String) throws -> Self {
        guard !engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              version?.isEmpty != true,
              artifactPath.map(ValidationCorpusPath.isSafeRelativePath) != false,
              sourceURI?.isEmpty != true,
              citation?.isEmpty != true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationCorpusError.invalidReference(caseID)
        }
        return self
    }
}

public struct ValidationAcceptanceCriterion: Codable, Sendable, Hashable {
    public var id: String
    public var observable: String
    public var unit: String
    public var comparison: ValidationComparisonKind
    public var absoluteTolerance: Double?
    public var relativeTolerance: Double?
    public var rootMeanSquareTolerance: Double?
    public var maximumSpikeTimeDifferenceMilliseconds: Double?
    public var allowedMissingFraction: Double?
    public var minimumCorrelation: Double?
    public var conservationRelativeTolerance: Double?
    public var minimumSampleCount: Int?
    public var metadata: [String: String]

    public init(
        id: String,
        observable: String,
        unit: String,
        comparison: ValidationComparisonKind,
        absoluteTolerance: Double? = nil,
        relativeTolerance: Double? = nil,
        rootMeanSquareTolerance: Double? = nil,
        maximumSpikeTimeDifferenceMilliseconds: Double? = nil,
        allowedMissingFraction: Double? = nil,
        minimumCorrelation: Double? = nil,
        conservationRelativeTolerance: Double? = nil,
        minimumSampleCount: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.observable = observable
        self.unit = unit
        self.comparison = comparison
        self.absoluteTolerance = absoluteTolerance
        self.relativeTolerance = relativeTolerance
        self.rootMeanSquareTolerance = rootMeanSquareTolerance
        self.maximumSpikeTimeDifferenceMilliseconds = maximumSpikeTimeDifferenceMilliseconds
        self.allowedMissingFraction = allowedMissingFraction
        self.minimumCorrelation = minimumCorrelation
        self.conservationRelativeTolerance = conservationRelativeTolerance
        self.minimumSampleCount = minimumSampleCount
        self.metadata = metadata
    }

    public func validated(caseID: String) throws -> Self {
        let nonnegative = [
            absoluteTolerance,
            relativeTolerance,
            rootMeanSquareTolerance,
            maximumSpikeTimeDifferenceMilliseconds,
            conservationRelativeTolerance
        ].allSatisfy { value in
            value.map({ $0.isFinite && $0 >= 0 }) ?? true
        }
        guard ValidationCorpusPath.isStableIdentifier(id),
              !observable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              nonnegative,
              allowedMissingFraction.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              minimumCorrelation.map({ $0.isFinite && (-1...1).contains($0) }) ?? true,
              minimumSampleCount.map({ $0 > 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationCorpusError.invalidCriterion(caseID: caseID, criterionID: id)
        }

        let hasTraceTolerance = absoluteTolerance != nil || relativeTolerance != nil ||
            rootMeanSquareTolerance != nil || minimumCorrelation != nil
        switch comparison {
        case .scalar, .trace:
            guard hasTraceTolerance else {
                throw ValidationCorpusError.missingTolerance(caseID: caseID, criterionID: id)
            }
        case .spikes:
            guard maximumSpikeTimeDifferenceMilliseconds != nil,
                  allowedMissingFraction != nil else {
                throw ValidationCorpusError.missingTolerance(caseID: caseID, criterionID: id)
            }
        case .distribution:
            guard relativeTolerance != nil || rootMeanSquareTolerance != nil else {
                throw ValidationCorpusError.missingTolerance(caseID: caseID, criterionID: id)
            }
        case .conservation:
            guard conservationRelativeTolerance != nil else {
                throw ValidationCorpusError.missingTolerance(caseID: caseID, criterionID: id)
            }
        case .exactDigest, .topologyInvariant:
            break
        }
        return self
    }
}

public struct ScientificValidationCaseManifest: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var id: String
    public var title: String
    public var summary: String
    public var domain: ValidationDomain
    public var tier: ValidationTier
    public var deterministic: Bool
    public var modelPath: String?
    public var inputPath: String?
    public var reference: ValidationReferenceSpecification
    public var criteria: [ValidationAcceptanceCriterion]
    public var tags: [String]
    public var requiredProfiles: [NumericalProfile]
    public var randomSeeds: [UInt64]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: String,
        title: String,
        summary: String,
        domain: ValidationDomain,
        tier: ValidationTier,
        deterministic: Bool,
        modelPath: String? = nil,
        inputPath: String? = nil,
        reference: ValidationReferenceSpecification,
        criteria: [ValidationAcceptanceCriterion],
        tags: [String] = [],
        requiredProfiles: [NumericalProfile] = [.scientific],
        randomSeeds: [UInt64] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.summary = summary
        self.domain = domain
        self.tier = tier
        self.deterministic = deterministic
        self.modelPath = modelPath
        self.inputPath = inputPath
        self.reference = reference
        self.criteria = criteria
        self.tags = tags
        self.requiredProfiles = requiredProfiles
        self.randomSeeds = randomSeeds
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw ValidationCorpusError.unsupportedSchema(schemaVersion)
        }
        guard ValidationCorpusPath.isStableIdentifier(id),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              modelPath.map(ValidationCorpusPath.isSafeRelativePath) != false,
              inputPath.map(ValidationCorpusPath.isSafeRelativePath) != false,
              !criteria.isEmpty,
              Set(criteria.map(\.id)).count == criteria.count,
              Set(tags).count == tags.count,
              tags.allSatisfy(ValidationCorpusPath.isStableIdentifier),
              !requiredProfiles.isEmpty,
              Set(requiredProfiles).count == requiredProfiles.count,
              Set(randomSeeds).count == randomSeeds.count,
              deterministic || !randomSeeds.isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationCorpusError.invalidCase(id)
        }
        _ = try reference.validated(caseID: id)
        for criterion in criteria {
            _ = try criterion.validated(caseID: id)
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public struct ValidationCorpusEntry: Codable, Sendable, Hashable {
    public var id: String
    public var manifestPath: String
    public var required: Bool
    public var tier: ValidationTier

    public init(id: String, manifestPath: String, required: Bool = true, tier: ValidationTier) {
        self.id = id
        self.manifestPath = manifestPath
        self.required = required
        self.tier = tier
    }

    public func validated() throws -> Self {
        guard ValidationCorpusPath.isStableIdentifier(id),
              ValidationCorpusPath.isSafeRelativePath(manifestPath) else {
            throw ValidationCorpusError.invalidEntry(id)
        }
        return self
    }
}

public struct ScientificValidationCorpusIndex: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var name: String
    public var corpusVersion: String
    public var entries: [ValidationCorpusEntry]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        name: String,
        corpusVersion: String,
        entries: [ValidationCorpusEntry],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.corpusVersion = corpusVersion
        self.entries = entries
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw ValidationCorpusError.unsupportedSchema(schemaVersion)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !corpusVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entries.isEmpty,
              Set(entries.map(\.id)).count == entries.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationCorpusError.invalidIndex
        }
        for entry in entries { _ = try entry.validated() }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public enum ValidationCaseExecutionStatus: String, Codable, Sendable, Hashable {
    case passed
    case failed
    case skipped
    case error
}

public struct ValidationCriterionOutcome: Codable, Sendable, Hashable {
    public var criterionID: String
    public var status: ValidationCaseExecutionStatus
    public var measuredValue: Double?
    public var referenceValue: Double?
    public var message: String
    public var metadata: [String: String]

    public init(
        criterionID: String,
        status: ValidationCaseExecutionStatus,
        measuredValue: Double? = nil,
        referenceValue: Double? = nil,
        message: String = "",
        metadata: [String: String] = [:]
    ) {
        self.criterionID = criterionID
        self.status = status
        self.measuredValue = measuredValue
        self.referenceValue = referenceValue
        self.message = message
        self.metadata = metadata
    }
}

public struct ScientificValidationCaseOutcome: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var caseID: String
    public var manifestDigest: ScientificSHA256Digest
    public var status: ValidationCaseExecutionStatus
    public var startedAt: Date
    public var completedAt: Date
    public var profile: NumericalProfile
    public var backend: String
    public var criteria: [ValidationCriterionOutcome]
    public var artifacts: [ScientificArtifactProvenance]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        caseID: String,
        manifestDigest: ScientificSHA256Digest,
        status: ValidationCaseExecutionStatus,
        startedAt: Date,
        completedAt: Date,
        profile: NumericalProfile,
        backend: String,
        criteria: [ValidationCriterionOutcome],
        artifacts: [ScientificArtifactProvenance] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.caseID = caseID
        self.manifestDigest = manifestDigest
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.profile = profile
        self.backend = backend
        self.criteria = criteria
        self.artifacts = artifacts
        self.metadata = metadata
    }

    public func validated(against sourceManifest: ScientificValidationCaseManifest) throws -> Self {
        let manifest = try sourceManifest.validated()
        guard schemaVersion == 1,
              caseID == manifest.id,
              manifestDigest == (try manifest.digest()),
              completedAt >= startedAt,
              !backend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(criteria.map(\.criterionID)) == Set(manifest.criteria.map(\.id)),
              Set(criteria.map(\.criterionID)).count == criteria.count,
              criteria.allSatisfy({
                  $0.measuredValue?.isFinite != false &&
                  $0.referenceValue?.isFinite != false &&
                  $0.metadata.keys.allSatisfy({ !$0.isEmpty })
              }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationCorpusError.invalidOutcome(caseID)
        }
        for artifact in artifacts { _ = try artifact.validated() }
        let derived: ValidationCaseExecutionStatus
        if criteria.contains(where: { $0.status == .error }) { derived = .error }
        else if criteria.contains(where: { $0.status == .failed }) { derived = .failed }
        else if criteria.allSatisfy({ $0.status == .skipped }) { derived = .skipped }
        else { derived = .passed }
        guard status == derived else {
            throw ValidationCorpusError.inconsistentOutcomeStatus(caseID)
        }
        return self
    }
}

public struct ScientificValidationCorpusSummary: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var corpusDigest: ScientificSHA256Digest
    public var generatedAt: Date
    public var outcomes: [ScientificValidationCaseOutcome]
    public var passed: Int
    public var failed: Int
    public var skipped: Int
    public var errors: Int

    public init(
        index: ScientificValidationCorpusIndex,
        outcomes: [ScientificValidationCaseOutcome],
        generatedAt: Date = Date()
    ) throws {
        schemaVersion = 1
        corpusDigest = try index.digest()
        self.generatedAt = generatedAt
        self.outcomes = outcomes.sorted { $0.caseID < $1.caseID }
        passed = outcomes.filter { $0.status == .passed }.count
        failed = outcomes.filter { $0.status == .failed }.count
        skipped = outcomes.filter { $0.status == .skipped }.count
        errors = outcomes.filter { $0.status == .error }.count
    }

    public var isPassing: Bool { failed == 0 && errors == 0 }
}

public enum ScientificValidationCorpusIO {
    public static func loadIndex(from url: URL) throws -> ScientificValidationCorpusIndex {
        try decode(ScientificValidationCorpusIndex.self, from: url).validated()
    }

    public static func loadManifest(from url: URL) throws -> ScientificValidationCaseManifest {
        try decode(ScientificValidationCaseManifest.self, from: url).validated()
    }

    public static func loadManifests(
        index sourceIndex: ScientificValidationCorpusIndex,
        root: URL
    ) throws -> [ScientificValidationCaseManifest] {
        let index = try sourceIndex.validated()
        return try index.entries.map { entry in
            let manifest = try loadManifest(from: root.appendingPathComponent(entry.manifestPath))
            guard manifest.id == entry.id, manifest.tier == entry.tier else {
                throw ValidationCorpusError.entryManifestMismatch(entry.id)
            }
            return manifest
        }
    }

    public static func writeCanonical<T: Encodable>(_ value: T, to url: URL) throws {
        try ScientificCanonicalJSON.encode(value).write(to: url, options: .atomic)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
        } catch {
            throw ValidationCorpusError.decodeFailure(path: url.path, reason: String(describing: error))
        }
    }
}

public enum ValidationCorpusPath {
    public static func isStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.lowercased(),
              value.first?.isLetter == true,
              value.last?.isLetter == true || value.last?.isNumber == true else {
            return false
        }
        return value.utf8.allSatisfy {
            ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 46
        }
    }

    public static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.contains("\0") else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

public enum ValidationCorpusError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidReference(String)
    case invalidCriterion(caseID: String, criterionID: String)
    case missingTolerance(caseID: String, criterionID: String)
    case invalidCase(String)
    case invalidEntry(String)
    case invalidIndex
    case decodeFailure(path: String, reason: String)
    case entryManifestMismatch(String)
    case invalidOutcome(String)
    case inconsistentOutcomeStatus(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported validation-corpus schema \(version)."
        case .invalidReference(let id): return "Validation case \(id) has an invalid reference."
        case .invalidCriterion(let id, let criterion): return "Validation case \(id) has an invalid criterion \(criterion)."
        case .missingTolerance(let id, let criterion): return "Validation case \(id) criterion \(criterion) has no applicable tolerance."
        case .invalidCase(let id): return "Validation case \(id) is invalid."
        case .invalidEntry(let id): return "Validation corpus entry \(id) is invalid."
        case .invalidIndex: return "Validation corpus index is invalid."
        case .decodeFailure(let path, let reason): return "Could not decode validation artifact at \(path): \(reason)"
        case .entryManifestMismatch(let id): return "Validation corpus entry \(id) does not match its manifest."
        case .invalidOutcome(let id): return "Validation outcome for \(id) is invalid."
        case .inconsistentOutcomeStatus(let id): return "Validation outcome status for \(id) disagrees with its criteria."
        }
    }
}
