import Foundation

public enum ProspectivePredictionScorer {
    public static let calibrationLevels: [Double] = [0.50, 0.80, 0.90, 0.95]

    public static func score(
        protocol sourceProtocol: ProspectiveExperimentProtocol,
        freeze sourceFreeze: ProspectiveModelFreezeCertificate,
        candidate sourceCandidate: ProspectiveForecastBundle,
        baselines sourceBaselines: [ProspectiveForecastBundle],
        observations sourceObservations: ProspectiveObservationBundle,
        blindingKey sourceKey: ProspectiveBlindingKey,
        unblinding sourceUnblinding: ProspectiveUnblindingRecord,
        immutability sourceImmutability: ProspectiveImmutabilityAttestation,
        deviations sourceDeviations: [ProspectiveProtocolDeviation] = [],
        scoredAt: Date,
        metadata: [String: String] = [:]
    ) throws -> ProspectiveScoreReport {
        let freeze = try sourceFreeze.validated()
        let protocolValue = try sourceProtocol.validated(against: freeze)
        let candidate = try sourceCandidate.validated(
            for: protocolValue,
            freeze: freeze
        )
        guard candidate.authority.kind == .frozenModel else {
            throw ProspectiveScoringError.candidateAuthorityRequired
        }
        let observations = try sourceObservations.validated(for: protocolValue)
        let key = try sourceKey.validated(
            commitments: protocolValue.blindingCommitments
        )
        let unblinding = try sourceUnblinding.validated(
            protocolValue: protocolValue,
            observations: observations,
            key: key
        )
        let immutability = try sourceImmutability.validated(
            protocolValue: protocolValue,
            freeze: freeze,
            prediction: candidate
        )
        guard scoredAt >= unblinding.revealedAt,
              sourceDeviations.allSatisfy({ $0.detectedAt <= scoredAt }),
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveScoringError.invalidScoringTimeline
        }
        let deviations = try sourceDeviations.map { try $0.validated() }

        let declaredBaselines = Dictionary(
            uniqueKeysWithValues: protocolValue.baselines.map { ($0.id, $0) }
        )
        var baselineByID: [String: ProspectiveForecastBundle] = [:]
        for source in sourceBaselines {
            let baseline = try source.validated(for: protocolValue)
            guard baseline.authority.kind == .baseline,
                  declaredBaselines[baseline.authority.identifier] != nil,
                  baselineByID.updateValue(
                      baseline,
                      forKey: baseline.authority.identifier
                  ) == nil else {
                throw ProspectiveScoringError.invalidBaselineBundle
            }
        }
        let requiredBaselineIDs = Set(protocolValue.baselines
            .filter(\.requiredForSuccess)
            .map(\.id))
        guard requiredBaselineIDs.isSubset(of: Set(baselineByID.keys)) else {
            throw ProspectiveScoringError.missingRequiredBaseline
        }

        let targetByID = Dictionary(
            uniqueKeysWithValues: protocolValue.targets.map { ($0.id, $0) }
        )
        let ruleByID = Dictionary(
            uniqueKeysWithValues: protocolValue.scoringRules.map { ($0.id, $0) }
        )
        let conditionByBlindID = Dictionary(
            uniqueKeysWithValues: key.entries.map {
                ($0.blindedID, $0.condition.id)
            }
        )
        let candidateForecasts = try forecastMap(candidate)
        var baselineForecasts: [String: [String: ProspectiveForecastSeries]] = [:]
        for baselineID in baselineByID.keys.sorted() {
            guard let bundle = baselineByID[baselineID] else { continue }
            baselineForecasts[baselineID] = try forecastMap(bundle)
        }

        var seriesScores: [ProspectiveSeriesScore] = []
        var coverageAccumulator = CoverageAccumulator(levels: calibrationLevels)
        var validObservations = 0
        var matchedObservations = 0

        for observation in observations.series.sorted(by: observationSort) {
            guard observation.exclusionCode == nil else { continue }
            guard let target = targetByID[observation.targetID],
                  let conditionID = conditionByBlindID[observation.blindedID] else {
                throw ProspectiveScoringError.unknownObservationSeries
            }
            let keyValue = forecastKey(
                blindedID: observation.blindedID,
                targetID: observation.targetID
            )
            guard let candidateSeries = candidateForecasts[keyValue] else {
                throw ProspectiveScoringError.missingForecastSeries(keyValue)
            }
            let rules = protocolValue.scoringRules
                .filter { $0.targetID == observation.targetID }
                .sorted { $0.id < $1.id }
            let calibrationRuleID = rules.first(where: \.primary)?.id ?? rules.first?.id
            for rule in rules {
                let recordsCoverage = rule.id == calibrationRuleID
                let candidateResult = try scoreSeries(
                    forecast: candidateSeries,
                    observation: observation,
                    target: target,
                    rule: rule,
                    recordCoverage: recordsCoverage,
                    coverage: &coverageAccumulator
                )
                if recordsCoverage {
                    validObservations += candidateResult.validCount
                    matchedObservations += candidateResult.matchedCount
                }
                seriesScores.append(ProspectiveSeriesScore(
                    forecasterID: candidate.authority.identifier,
                    blindedID: observation.blindedID,
                    conditionID: conditionID,
                    targetID: observation.targetID,
                    replicateID: observation.replicateID,
                    scoringRuleID: rule.id,
                    metric: rule.metric,
                    validObservationCount: candidateResult.validCount,
                    matchedObservationCount: candidateResult.matchedCount,
                    score: candidateResult.score
                ))

                for baselineID in baselineByID.keys.sorted() {
                    guard let forecast = baselineForecasts[baselineID]?[keyValue] else {
                        throw ProspectiveScoringError.missingForecastSeries(
                            "\(baselineID)::\(keyValue)"
                        )
                    }
                    let baselineResult = try scoreSeriesWithoutCoverage(
                        forecast: forecast,
                        observation: observation,
                        target: target,
                        rule: rule
                    )
                    seriesScores.append(ProspectiveSeriesScore(
                        forecasterID: baselineID,
                        blindedID: observation.blindedID,
                        conditionID: conditionID,
                        targetID: observation.targetID,
                        replicateID: observation.replicateID,
                        scoringRuleID: rule.id,
                        metric: rule.metric,
                        validObservationCount: baselineResult.validCount,
                        matchedObservationCount: baselineResult.matchedCount,
                        score: baselineResult.score
                    ))
                }
            }
        }

        let candidateScore = try aggregate(
            forecasterID: candidate.authority.identifier,
            scores: seriesScores,
            rules: ruleByID
        )
        let baselineScores = try baselineByID.keys.sorted().map { id in
            try aggregate(
                forecasterID: id,
                scores: seriesScores,
                rules: ruleByID
            )
        }
        let baselineScoreByID = Dictionary(
            uniqueKeysWithValues: baselineScores.map { ($0.forecasterID, $0) }
        )

        var comparisons: [ProspectiveBaselineComparison] = []
        for baseline in protocolValue.baselines where baselineByID[baseline.id] != nil {
            guard let score = baselineScoreByID[baseline.id] else {
                throw ProspectiveScoringError.invalidBaselineBundle
            }
            comparisons.append(try compare(
                candidate: candidateScore,
                baseline: score,
                definition: baseline,
                criteria: protocolValue.successCriteria
            ))
        }

        let coverage = try coverageAccumulator.reports().map {
            try $0.validated()
        }
        let observationFraction = validObservations == 0
            ? 0
            : Double(matchedObservations) / Double(validObservations)
        let completedReplicates = completedReplicateCount(
            scores: seriesScores,
            candidateID: candidate.authority.identifier,
            primaryRuleIDs: Set(protocolValue.scoringRules.filter(\.primary).map(\.id))
        )
        let majorDeviationCount = deviations.filter {
            $0.severity == .major
        }.count
        let disqualifyingDeviationCount = deviations.filter {
            $0.severity == .disqualifying
        }.count
        let compliance = ProspectiveProtocolCompliance(
            modelFreezeMatched: candidate.authority.modelFreezeSHA256 == protocolValue.modelFreezeSHA256,
            forecastsIssuedBeforeDeadline: candidate.issuedAt <= protocolValue.predictionDeadline,
            baselinesIssuedBeforeDeadline: baselineByID.values.allSatisfy {
                $0.issuedAt <= protocolValue.predictionDeadline
            },
            observationsAcquiredBlind: observations.operatorBlinded,
            observationsSealedBeforeUnblinding: observations.sealedAt <= unblinding.revealedAt,
            noPostFreezeMutation: immutability.mutationDetected == false,
            noPostUnblindingMutation: immutability.checkedAfterUnblinding && immutability.mutationDetected == false,
            observationFraction: observationFraction,
            completedReplicateCount: completedReplicates,
            majorDeviationCount: majorDeviationCount,
            disqualifyingDeviationCount: disqualifyingDeviationCount
        )

        let reasons = failureReasons(
            protocolValue: protocolValue,
            comparisons: comparisons,
            coverage: coverage,
            compliance: compliance,
            seriesScores: seriesScores,
            candidateID: candidate.authority.identifier
        )
        let baselineDigests = try baselineByID.mapValues { try $0.sha256() }
        let report = ProspectiveScoreReport(
            protocolSHA256: try protocolValue.sha256(),
            modelFreezeSHA256: try freeze.sha256(),
            candidateForecastSHA256: try candidate.sha256(),
            baselineForecastSHA256: baselineDigests,
            observationBundleSHA256: try observations.sha256(),
            blindingKeySHA256: try key.sha256(),
            unblindingRecordSHA256: try unblinding.sha256(),
            immutabilityAttestationSHA256: try immutability.sha256(),
            scoredAt: scoredAt,
            candidate: candidateScore,
            baselines: baselineScores,
            comparisons: comparisons,
            seriesScores: seriesScores.sorted(by: seriesScoreSort),
            coverage: coverage,
            compliance: compliance,
            deviations: deviations,
            passed: reasons.isEmpty,
            failureReasons: reasons,
            metadata: metadata
        )
        return try report.validated()
    }

}
