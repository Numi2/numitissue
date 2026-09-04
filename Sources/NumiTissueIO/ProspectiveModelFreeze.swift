import Foundation

public struct ProspectiveModelFreezeCertificate: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var id: UUID
    public var name: String
    public var frozenAt: Date
    public var calibrationDataCutoff: Date
    public var sourceRepository: String
    public var sourceCommit: String
    public var sourceTreeSHA256: ScientificSHA256Digest
    public var simulatorVersion: String
    public var numericalProfile: String
    public var backend: String
    public var modelSHA256: ScientificSHA256Digest
    public var parametersSHA256: ScientificSHA256Digest
    public var checkpointSHA256: ScientificSHA256Digest
    public var executionConfigurationSHA256: ScientificSHA256Digest
    public var trainingCorpusSHA256: [ScientificSHA256Digest]
    public var calibrationEvidenceSHA256: [ScientificSHA256Digest]
    public var validationEvidenceSHA256: [ScientificSHA256Digest]
    public var sourceTreeDirty: Bool
    public var prohibitsPostFreezeParameterChanges: Bool
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: UUID = UUID(),
        name: String,
        frozenAt: Date,
        calibrationDataCutoff: Date,
        sourceRepository: String,
        sourceCommit: String,
        sourceTreeSHA256: ScientificSHA256Digest,
        simulatorVersion: String,
        numericalProfile: String,
        backend: String,
        modelSHA256: ScientificSHA256Digest,
        parametersSHA256: ScientificSHA256Digest,
        checkpointSHA256: ScientificSHA256Digest,
        executionConfigurationSHA256: ScientificSHA256Digest,
        trainingCorpusSHA256: [ScientificSHA256Digest],
        calibrationEvidenceSHA256: [ScientificSHA256Digest],
        validationEvidenceSHA256: [ScientificSHA256Digest],
        sourceTreeDirty: Bool,
        prohibitsPostFreezeParameterChanges: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.frozenAt = frozenAt
        self.calibrationDataCutoff = calibrationDataCutoff
        self.sourceRepository = sourceRepository
        self.sourceCommit = sourceCommit
        self.sourceTreeSHA256 = sourceTreeSHA256
        self.simulatorVersion = simulatorVersion
        self.numericalProfile = numericalProfile
        self.backend = backend
        self.modelSHA256 = modelSHA256
        self.parametersSHA256 = parametersSHA256
        self.checkpointSHA256 = checkpointSHA256
        self.executionConfigurationSHA256 = executionConfigurationSHA256
        self.trainingCorpusSHA256 = trainingCorpusSHA256
        self.calibrationEvidenceSHA256 = calibrationEvidenceSHA256
        self.validationEvidenceSHA256 = validationEvidenceSHA256
        self.sourceTreeDirty = sourceTreeDirty
        self.prohibitsPostFreezeParameterChanges = prohibitsPostFreezeParameterChanges
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              calibrationDataCutoff <= frozenAt,
              ProspectiveIdentifier.isRepository(sourceRepository),
              ProspectiveIdentifier.isGitObject(sourceCommit),
              !simulatorVersion.isEmpty,
              !numericalProfile.isEmpty,
              !backend.isEmpty,
              !trainingCorpusSHA256.isEmpty,
              !calibrationEvidenceSHA256.isEmpty,
              !validationEvidenceSHA256.isEmpty,
              Set(trainingCorpusSHA256).count == trainingCorpusSHA256.count,
              Set(calibrationEvidenceSHA256).count == calibrationEvidenceSHA256.count,
              Set(validationEvidenceSHA256).count == validationEvidenceSHA256.count,
              sourceTreeDirty == false,
              prohibitsPostFreezeParameterChanges,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidModelFreeze
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public enum ProspectiveBaselineKind: String, Sendable, Hashable, Codable, CaseIterable {
    case persistence
    case historicalMean = "historical-mean"
    case linearRecovery = "linear-recovery"
    case reducedModel = "reduced-model"
    case externalReference = "external-reference"
    case custom
}

public struct ProspectiveBaselineDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var kind: ProspectiveBaselineKind
    public var configurationSHA256: ScientificSHA256Digest
    public var sourceArtifactSHA256: [ScientificSHA256Digest]
    public var trainingDataCutoff: Date
    public var requiredForSuccess: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        kind: ProspectiveBaselineKind,
        configurationSHA256: ScientificSHA256Digest,
        sourceArtifactSHA256: [ScientificSHA256Digest] = [],
        trainingDataCutoff: Date,
        requiredForSuccess: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.configurationSHA256 = configurationSHA256
        self.sourceArtifactSHA256 = sourceArtifactSHA256
        self.trainingDataCutoff = trainingDataCutoff
        self.requiredForSuccess = requiredForSuccess
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(id),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(sourceArtifactSHA256).count == sourceArtifactSHA256.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidBaseline(id)
        }
        return self
    }
}

public enum ProspectiveScoringMetric: String, Sendable, Hashable, Codable, CaseIterable {
    case quantileCRPS = "quantile-crps"
    case weightedIntervalScore = "weighted-interval-score"
    case rootMeanSquaredError = "root-mean-squared-error"
    case meanAbsoluteError = "mean-absolute-error"
    case absoluteEndpointError = "absolute-endpoint-error"
}

public struct ProspectiveScoringRule: Sendable, Hashable, Codable {
    public var id: String
    public var targetID: String
    public var metric: ProspectiveScoringMetric
    public var timeWindow: ProspectiveTimeWindow
    public var weight: Double
    public var primary: Bool
    public var metadata: [String: String]

    public init(
        id: String,
        targetID: String,
        metric: ProspectiveScoringMetric,
        timeWindow: ProspectiveTimeWindow,
        weight: Double = 1,
        primary: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.targetID = targetID
        self.metric = metric
        self.timeWindow = timeWindow
        self.weight = weight
        self.primary = primary
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(id),
              ProspectiveIdentifier.isStable(targetID),
              weight.isFinite,
              weight > 0,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidScoringRule(id)
        }
        _ = try timeWindow.validated()
        return self
    }
}

public struct ProspectiveSuccessCriteria: Sendable, Hashable, Codable {
    public var minimumRelativeImprovement: Double
    public var confidenceLevel: Double
    public var bootstrapReplicates: Int
    public var bootstrapSeed: UInt64
    public var maximumAbsoluteCoverageError: Double
    public var minimumCoverageSampleCount: Int
    public var minimumObservationFraction: Double
    public var minimumCompletedReplicates: Int
    public var maximumMajorProtocolDeviations: Int
    public var requireAllPrimaryTargets: Bool
    public var requireNoPostFreezeMutation: Bool
    public var requireNoPostUnblindingMutation: Bool

    public init(
        minimumRelativeImprovement: Double = 0.05,
        confidenceLevel: Double = 0.90,
        bootstrapReplicates: Int = 10_000,
        bootstrapSeed: UInt64,
        maximumAbsoluteCoverageError: Double = 0.10,
        minimumCoverageSampleCount: Int = 100,
        minimumObservationFraction: Double = 0.95,
        minimumCompletedReplicates: Int = 6,
        maximumMajorProtocolDeviations: Int = 0,
        requireAllPrimaryTargets: Bool = true,
        requireNoPostFreezeMutation: Bool = true,
        requireNoPostUnblindingMutation: Bool = true
    ) {
        self.minimumRelativeImprovement = minimumRelativeImprovement
        self.confidenceLevel = confidenceLevel
        self.bootstrapReplicates = bootstrapReplicates
        self.bootstrapSeed = bootstrapSeed
        self.maximumAbsoluteCoverageError = maximumAbsoluteCoverageError
        self.minimumCoverageSampleCount = minimumCoverageSampleCount
        self.minimumObservationFraction = minimumObservationFraction
        self.minimumCompletedReplicates = minimumCompletedReplicates
        self.maximumMajorProtocolDeviations = maximumMajorProtocolDeviations
        self.requireAllPrimaryTargets = requireAllPrimaryTargets
        self.requireNoPostFreezeMutation = requireNoPostFreezeMutation
        self.requireNoPostUnblindingMutation = requireNoPostUnblindingMutation
    }

    public func validated() throws -> Self {
        guard minimumRelativeImprovement.isFinite,
              minimumRelativeImprovement >= 0,
              minimumRelativeImprovement < 1,
              confidenceLevel.isFinite,
              confidenceLevel >= 0.80,
              confidenceLevel < 1,
              bootstrapReplicates >= 100,
              bootstrapReplicates <= 1_000_000,
              maximumAbsoluteCoverageError.isFinite,
              maximumAbsoluteCoverageError >= 0,
              maximumAbsoluteCoverageError <= 1,
              minimumCoverageSampleCount > 0,
              minimumObservationFraction.isFinite,
              minimumObservationFraction > 0,
              minimumObservationFraction <= 1,
              minimumCompletedReplicates > 1,
              maximumMajorProtocolDeviations >= 0 else {
            throw ProspectivePredictionError.invalidSuccessCriteria
        }
        return self
    }
}
