import Foundation

public struct ProspectiveCoverageReport: Sendable, Hashable, Codable {
    public var nominalLevel: Double
    public var sampleCount: Int
    public var coveredCount: Int
    public var empiricalCoverage: Double
    public var absoluteCoverageError: Double
    public var meanIntervalWidth: Double

    public init(
        nominalLevel: Double,
        sampleCount: Int,
        coveredCount: Int,
        empiricalCoverage: Double,
        absoluteCoverageError: Double,
        meanIntervalWidth: Double
    ) {
        self.nominalLevel = nominalLevel
        self.sampleCount = sampleCount
        self.coveredCount = coveredCount
        self.empiricalCoverage = empiricalCoverage
        self.absoluteCoverageError = absoluteCoverageError
        self.meanIntervalWidth = meanIntervalWidth
    }

    public func validated() throws -> Self {
        guard nominalLevel.isFinite,
              nominalLevel > 0,
              nominalLevel < 1,
              sampleCount > 0,
              coveredCount >= 0,
              coveredCount <= sampleCount,
              empiricalCoverage.isFinite,
              empiricalCoverage >= 0,
              empiricalCoverage <= 1,
              absoluteCoverageError.isFinite,
              absoluteCoverageError >= 0,
              absoluteCoverageError <= 1,
              meanIntervalWidth.isFinite,
              meanIntervalWidth >= 0 else {
            throw ProspectiveScoringError.invalidCoverageReport
        }
        return self
    }
}

public struct ProspectiveSeriesScore: Sendable, Hashable, Codable {
    public var forecasterID: String
    public var blindedID: String
    public var conditionID: String
    public var targetID: String
    public var replicateID: String
    public var scoringRuleID: String
    public var metric: ProspectiveScoringMetric
    public var validObservationCount: Int
    public var matchedObservationCount: Int
    public var score: Double

    public init(
        forecasterID: String,
        blindedID: String,
        conditionID: String,
        targetID: String,
        replicateID: String,
        scoringRuleID: String,
        metric: ProspectiveScoringMetric,
        validObservationCount: Int,
        matchedObservationCount: Int,
        score: Double
    ) {
        self.forecasterID = forecasterID
        self.blindedID = blindedID
        self.conditionID = conditionID
        self.targetID = targetID
        self.replicateID = replicateID
        self.scoringRuleID = scoringRuleID
        self.metric = metric
        self.validObservationCount = validObservationCount
        self.matchedObservationCount = matchedObservationCount
        self.score = score
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(forecasterID),
              ProspectiveIdentifier.isStable(blindedID),
              ProspectiveIdentifier.isStable(conditionID),
              ProspectiveIdentifier.isStable(targetID),
              ProspectiveIdentifier.isStable(replicateID),
              ProspectiveIdentifier.isStable(scoringRuleID),
              validObservationCount > 0,
              matchedObservationCount > 0,
              matchedObservationCount <= validObservationCount,
              score.isFinite,
              score >= 0 else {
            throw ProspectiveScoringError.invalidSeriesScore
        }
        return self
    }
}

public struct ProspectiveForecasterScore: Sendable, Hashable, Codable {
    public var forecasterID: String
    public var aggregateScore: Double
    public var primaryAggregateScore: Double
    public var observationCount: Int
    public var matchedObservationCount: Int
    public var scoringRuleCount: Int
    public var replicateScores: [String: Double]
    public var targetScores: [String: Double]

    public init(
        forecasterID: String,
        aggregateScore: Double,
        primaryAggregateScore: Double,
        observationCount: Int,
        matchedObservationCount: Int,
        scoringRuleCount: Int,
        replicateScores: [String: Double],
        targetScores: [String: Double]
    ) {
        self.forecasterID = forecasterID
        self.aggregateScore = aggregateScore
        self.primaryAggregateScore = primaryAggregateScore
        self.observationCount = observationCount
        self.matchedObservationCount = matchedObservationCount
        self.scoringRuleCount = scoringRuleCount
        self.replicateScores = replicateScores
        self.targetScores = targetScores
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(forecasterID),
              aggregateScore.isFinite,
              aggregateScore >= 0,
              primaryAggregateScore.isFinite,
              primaryAggregateScore >= 0,
              observationCount > 0,
              matchedObservationCount > 0,
              matchedObservationCount <= observationCount,
              scoringRuleCount > 0,
              !replicateScores.isEmpty,
              replicateScores.keys.allSatisfy(ProspectiveIdentifier.isCompositeKey),
              replicateScores.values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              targetScores.keys.allSatisfy(ProspectiveIdentifier.isStable),
              targetScores.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ProspectiveScoringError.invalidForecasterScore(forecasterID)
        }
        return self
    }
}

public struct ProspectiveBaselineComparison: Sendable, Hashable, Codable {
    public var baselineID: String
    public var requiredForSuccess: Bool
    public var pairedReplicateCount: Int
    public var candidatePrimaryScore: Double
    public var baselinePrimaryScore: Double
    public var relativeImprovement: Double
    public var confidenceLevel: Double
    public var lowerConfidenceBound: Double
    public var upperConfidenceBound: Double
    public var requiredImprovement: Double
    public var passed: Bool

    public init(
        baselineID: String,
        requiredForSuccess: Bool,
        pairedReplicateCount: Int,
        candidatePrimaryScore: Double,
        baselinePrimaryScore: Double,
        relativeImprovement: Double,
        confidenceLevel: Double,
        lowerConfidenceBound: Double,
        upperConfidenceBound: Double,
        requiredImprovement: Double,
        passed: Bool
    ) {
        self.baselineID = baselineID
        self.requiredForSuccess = requiredForSuccess
        self.pairedReplicateCount = pairedReplicateCount
        self.candidatePrimaryScore = candidatePrimaryScore
        self.baselinePrimaryScore = baselinePrimaryScore
        self.relativeImprovement = relativeImprovement
        self.confidenceLevel = confidenceLevel
        self.lowerConfidenceBound = lowerConfidenceBound
        self.upperConfidenceBound = upperConfidenceBound
        self.requiredImprovement = requiredImprovement
        self.passed = passed
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(baselineID),
              pairedReplicateCount > 1,
              candidatePrimaryScore.isFinite,
              candidatePrimaryScore >= 0,
              baselinePrimaryScore.isFinite,
              baselinePrimaryScore >= 0,
              relativeImprovement.isFinite,
              confidenceLevel.isFinite,
              confidenceLevel > 0,
              confidenceLevel < 1,
              lowerConfidenceBound.isFinite,
              upperConfidenceBound.isFinite,
              lowerConfidenceBound <= upperConfidenceBound,
              requiredImprovement.isFinite,
              requiredImprovement >= 0,
              requiredImprovement < 1 else {
            throw ProspectiveScoringError.invalidBaselineComparison(baselineID)
        }
        return self
    }
}

public struct ProspectiveProtocolCompliance: Sendable, Hashable, Codable {
    public var modelFreezeMatched: Bool
    public var forecastsIssuedBeforeDeadline: Bool
    public var baselinesIssuedBeforeDeadline: Bool
    public var observationsAcquiredBlind: Bool
    public var observationsSealedBeforeUnblinding: Bool
    public var noPostFreezeMutation: Bool
    public var noPostUnblindingMutation: Bool
    public var observationFraction: Double
    public var completedReplicateCount: Int
    public var majorDeviationCount: Int
    public var disqualifyingDeviationCount: Int

    public init(
        modelFreezeMatched: Bool,
        forecastsIssuedBeforeDeadline: Bool,
        baselinesIssuedBeforeDeadline: Bool,
        observationsAcquiredBlind: Bool,
        observationsSealedBeforeUnblinding: Bool,
        noPostFreezeMutation: Bool,
        noPostUnblindingMutation: Bool,
        observationFraction: Double,
        completedReplicateCount: Int,
        majorDeviationCount: Int,
        disqualifyingDeviationCount: Int
    ) {
        self.modelFreezeMatched = modelFreezeMatched
        self.forecastsIssuedBeforeDeadline = forecastsIssuedBeforeDeadline
        self.baselinesIssuedBeforeDeadline = baselinesIssuedBeforeDeadline
        self.observationsAcquiredBlind = observationsAcquiredBlind
        self.observationsSealedBeforeUnblinding = observationsSealedBeforeUnblinding
        self.noPostFreezeMutation = noPostFreezeMutation
        self.noPostUnblindingMutation = noPostUnblindingMutation
        self.observationFraction = observationFraction
        self.completedReplicateCount = completedReplicateCount
        self.majorDeviationCount = majorDeviationCount
        self.disqualifyingDeviationCount = disqualifyingDeviationCount
    }

    public func validated() throws -> Self {
        guard observationFraction.isFinite,
              observationFraction >= 0,
              observationFraction <= 1,
              completedReplicateCount >= 0,
              majorDeviationCount >= 0,
              disqualifyingDeviationCount >= 0 else {
            throw ProspectiveScoringError.invalidCompliance
        }
        return self
    }
}

public struct ProspectiveScoreReport: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var protocolSHA256: ScientificSHA256Digest
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var candidateForecastSHA256: ScientificSHA256Digest
    public var baselineForecastSHA256: [String: ScientificSHA256Digest]
    public var observationBundleSHA256: ScientificSHA256Digest
    public var blindingKeySHA256: ScientificSHA256Digest
    public var unblindingRecordSHA256: ScientificSHA256Digest
    public var immutabilityAttestationSHA256: ScientificSHA256Digest
    public var scoredAt: Date
    public var candidate: ProspectiveForecasterScore
    public var baselines: [ProspectiveForecasterScore]
    public var comparisons: [ProspectiveBaselineComparison]
    public var seriesScores: [ProspectiveSeriesScore]
    public var coverage: [ProspectiveCoverageReport]
    public var compliance: ProspectiveProtocolCompliance
    public var deviations: [ProspectiveProtocolDeviation]
    public var passed: Bool
    public var failureReasons: [String]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        protocolSHA256: ScientificSHA256Digest,
        modelFreezeSHA256: ScientificSHA256Digest,
        candidateForecastSHA256: ScientificSHA256Digest,
        baselineForecastSHA256: [String: ScientificSHA256Digest],
        observationBundleSHA256: ScientificSHA256Digest,
        blindingKeySHA256: ScientificSHA256Digest,
        unblindingRecordSHA256: ScientificSHA256Digest,
        immutabilityAttestationSHA256: ScientificSHA256Digest,
        scoredAt: Date,
        candidate: ProspectiveForecasterScore,
        baselines: [ProspectiveForecasterScore],
        comparisons: [ProspectiveBaselineComparison],
        seriesScores: [ProspectiveSeriesScore],
        coverage: [ProspectiveCoverageReport],
        compliance: ProspectiveProtocolCompliance,
        deviations: [ProspectiveProtocolDeviation],
        passed: Bool,
        failureReasons: [String],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.protocolSHA256 = protocolSHA256
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.candidateForecastSHA256 = candidateForecastSHA256
        self.baselineForecastSHA256 = baselineForecastSHA256
        self.observationBundleSHA256 = observationBundleSHA256
        self.blindingKeySHA256 = blindingKeySHA256
        self.unblindingRecordSHA256 = unblindingRecordSHA256
        self.immutabilityAttestationSHA256 = immutabilityAttestationSHA256
        self.scoredAt = scoredAt
        self.candidate = candidate
        self.baselines = baselines
        self.comparisons = comparisons
        self.seriesScores = seriesScores
        self.coverage = coverage
        self.compliance = compliance
        self.deviations = deviations
        self.passed = passed
        self.failureReasons = failureReasons
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !baselines.isEmpty,
              !comparisons.isEmpty,
              !seriesScores.isEmpty,
              Set(baselines.map(\.forecasterID)).count == baselines.count,
              Set(comparisons.map(\.baselineID)).count == comparisons.count,
              baselineForecastSHA256.keys.allSatisfy(ProspectiveIdentifier.isStable),
              Set(failureReasons).count == failureReasons.count,
              failureReasons.allSatisfy(ProspectiveIdentifier.isStable),
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey),
              passed == failureReasons.isEmpty else {
            throw ProspectiveScoringError.invalidScoreReport
        }
        _ = try candidate.validated()
        for value in baselines { _ = try value.validated() }
        for value in comparisons { _ = try value.validated() }
        for value in seriesScores { _ = try value.validated() }
        for value in coverage { _ = try value.validated() }
        _ = try compliance.validated()
        for value in deviations { _ = try value.validated() }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}
