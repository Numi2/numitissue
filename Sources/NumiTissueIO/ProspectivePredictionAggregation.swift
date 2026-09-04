import Foundation

extension ProspectivePredictionScorer {
    static func aggregate(
        forecasterID: String,
        scores: [ProspectiveSeriesScore],
        rules: [String: ProspectiveScoringRule]
    ) throws -> ProspectiveForecasterScore {
        let selected = scores.filter { $0.forecasterID == forecasterID }
        guard !selected.isEmpty else {
            throw ProspectiveScoringError.noForecasterScores(forecasterID)
        }
        var total = 0.0
        var weightTotal = 0.0
        var primaryTotal = 0.0
        var primaryWeight = 0.0
        var replicateAccumulators: [String: WeightedAccumulator] = [:]
        var targetAccumulators: [String: WeightedAccumulator] = [:]
        var observationCount = 0
        var matchedCount = 0

        for score in selected {
            guard let rule = rules[score.scoringRuleID] else {
                throw ProspectiveScoringError.unknownScoringRule(score.scoringRuleID)
            }
            total += rule.weight * score.score
            weightTotal += rule.weight
            if rule.primary {
                primaryTotal += rule.weight * score.score
                primaryWeight += rule.weight
                let key = replicateKey(
                    blindedID: score.blindedID,
                    replicateID: score.replicateID
                )
                replicateAccumulators[key, default: WeightedAccumulator()]
                    .add(value: score.score, weight: rule.weight)
            }
            targetAccumulators[score.targetID, default: WeightedAccumulator()]
                .add(value: score.score, weight: rule.weight)
            observationCount += score.validObservationCount
            matchedCount += score.matchedObservationCount
        }
        guard weightTotal > 0,
              primaryWeight > 0 else {
            throw ProspectiveScoringError.noPrimaryScores(forecasterID)
        }
        let result = ProspectiveForecasterScore(
            forecasterID: forecasterID,
            aggregateScore: total / weightTotal,
            primaryAggregateScore: primaryTotal / primaryWeight,
            observationCount: observationCount,
            matchedObservationCount: matchedCount,
            scoringRuleCount: Set(selected.map(\.scoringRuleID)).count,
            replicateScores: try replicateAccumulators.mapValues { try $0.mean() },
            targetScores: try targetAccumulators.mapValues { try $0.mean() }
        )
        return try result.validated()
    }

    static func compare(
        candidate: ProspectiveForecasterScore,
        baseline: ProspectiveForecasterScore,
        definition: ProspectiveBaselineDefinition,
        criteria: ProspectiveSuccessCriteria
    ) throws -> ProspectiveBaselineComparison {
        let keys = Set(candidate.replicateScores.keys)
            .intersection(baseline.replicateScores.keys)
            .sorted()
        guard keys.count >= criteria.minimumCompletedReplicates else {
            throw ProspectiveScoringError.insufficientPairedReplicates(
                definition.id,
                keys.count
            )
        }
        let pairs = try keys.map { key -> (Double, Double) in
            guard let candidateValue = candidate.replicateScores[key],
                  let baselineValue = baseline.replicateScores[key] else {
                throw ProspectiveScoringError.invalidBaselineComparison(
                    definition.id
                )
            }
            return (candidateValue, baselineValue)
        }
        let observedCandidate = pairs.map { $0.0 }.reduce(0, +) / Double(pairs.count)
        let observedBaseline = pairs.map { $0.1 }.reduce(0, +) / Double(pairs.count)
        let observedImprovement = relativeImprovement(
            candidate: observedCandidate,
            baseline: observedBaseline
        )
        var generator = ProspectiveBootstrapRandom(
            seed: criteria.bootstrapSeed ^ ScientificSeed.hash(definition.id)
        )
        var bootstrap: [Double] = []
        bootstrap.reserveCapacity(criteria.bootstrapReplicates)
        for _ in 0..<criteria.bootstrapReplicates {
            var candidateTotal = 0.0
            var baselineTotal = 0.0
            for _ in pairs.indices {
                let pair = pairs[generator.index(upperBound: pairs.count)]
                candidateTotal += pair.0
                baselineTotal += pair.1
            }
            bootstrap.append(relativeImprovement(
                candidate: candidateTotal / Double(pairs.count),
                baseline: baselineTotal / Double(pairs.count)
            ))
        }
        bootstrap.sort()
        let tail = (1 - criteria.confidenceLevel) / 2
        let lower = percentile(bootstrap, probability: tail)
        let upper = percentile(bootstrap, probability: 1 - tail)
        let passed = observedImprovement >= criteria.minimumRelativeImprovement &&
            lower >= criteria.minimumRelativeImprovement
        return try ProspectiveBaselineComparison(
            baselineID: definition.id,
            requiredForSuccess: definition.requiredForSuccess,
            pairedReplicateCount: pairs.count,
            candidatePrimaryScore: observedCandidate,
            baselinePrimaryScore: observedBaseline,
            relativeImprovement: observedImprovement,
            confidenceLevel: criteria.confidenceLevel,
            lowerConfidenceBound: lower,
            upperConfidenceBound: upper,
            requiredImprovement: criteria.minimumRelativeImprovement,
            passed: passed
        ).validated()
    }

    static func relativeImprovement(
        candidate: Double,
        baseline: Double
    ) -> Double {
        (baseline - candidate) / max(abs(baseline), 1e-12)
    }

    static func percentile(
        _ sorted: [Double],
        probability: Double
    ) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = min(max(probability, 0), 1) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }

    static func completedReplicateCount(
        scores: [ProspectiveSeriesScore],
        candidateID: String,
        primaryRuleIDs: Set<String>
    ) -> Int {
        let selected = scores.filter {
            $0.forecasterID == candidateID && primaryRuleIDs.contains($0.scoringRuleID)
        }
        let grouped = Dictionary(grouping: selected) {
            replicateKey(blindedID: $0.blindedID, replicateID: $0.replicateID)
        }
        return grouped.values.filter { values in
            Set(values.map(\.scoringRuleID)) == primaryRuleIDs
        }.count
    }

    static func failureReasons(
        protocolValue: ProspectiveExperimentProtocol,
        comparisons: [ProspectiveBaselineComparison],
        coverage: [ProspectiveCoverageReport],
        compliance: ProspectiveProtocolCompliance,
        seriesScores: [ProspectiveSeriesScore],
        candidateID: String
    ) -> [String] {
        let criteria = protocolValue.successCriteria
        var reasons: [String] = []
        if comparisons.filter(\.requiredForSuccess).contains(where: { !$0.passed }) {
            reasons.append("baseline-improvement-not-demonstrated")
        }
        let qualifiedCoverage = coverage.filter {
            $0.sampleCount >= criteria.minimumCoverageSampleCount
        }
        if qualifiedCoverage.isEmpty {
            reasons.append("insufficient-calibration-samples")
        } else if qualifiedCoverage.contains(where: {
            $0.absoluteCoverageError > criteria.maximumAbsoluteCoverageError
        }) {
            reasons.append("predictive-intervals-miscalibrated")
        }
        if compliance.observationFraction < criteria.minimumObservationFraction {
            reasons.append("observation-completeness-below-threshold")
        }
        if compliance.completedReplicateCount < criteria.minimumCompletedReplicates {
            reasons.append("completed-replicates-below-threshold")
        }
        if compliance.majorDeviationCount > criteria.maximumMajorProtocolDeviations {
            reasons.append("major-protocol-deviation-limit-exceeded")
        }
        if compliance.disqualifyingDeviationCount > 0 {
            reasons.append("disqualifying-protocol-deviation")
        }
        if criteria.requireNoPostFreezeMutation && !compliance.noPostFreezeMutation {
            reasons.append("post-freeze-mutation-detected")
        }
        if criteria.requireNoPostUnblindingMutation && !compliance.noPostUnblindingMutation {
            reasons.append("post-unblinding-mutation-detected")
        }
        if !compliance.modelFreezeMatched {
            reasons.append("model-freeze-mismatch")
        }
        if !compliance.forecastsIssuedBeforeDeadline {
            reasons.append("candidate-forecast-issued-after-deadline")
        }
        if !compliance.baselinesIssuedBeforeDeadline {
            reasons.append("baseline-forecast-issued-after-deadline")
        }
        if !compliance.observationsAcquiredBlind {
            reasons.append("observations-not-acquired-blind")
        }
        if !compliance.observationsSealedBeforeUnblinding {
            reasons.append("observations-not-sealed-before-unblinding")
        }
        if criteria.requireAllPrimaryTargets {
            let primaryRuleIDs = Set(protocolValue.scoringRules.filter(\.primary).map(\.id))
            let observedPrimary = Set(seriesScores.filter {
                $0.forecasterID == candidateID
            }.map(\.scoringRuleID)).intersection(primaryRuleIDs)
            if observedPrimary != primaryRuleIDs {
                reasons.append("primary-target-score-missing")
            }
        }
        return Array(Set(reasons)).sorted()
    }

    static func forecastKey(
        blindedID: String,
        targetID: String
    ) -> String {
        "\(blindedID)::\(targetID)"
    }

    static func replicateKey(
        blindedID: String,
        replicateID: String
    ) -> String {
        "\(blindedID)::\(replicateID)"
    }

    static func observationSort(
        _ lhs: ProspectiveObservationSeries,
        _ rhs: ProspectiveObservationSeries
    ) -> Bool {
        (lhs.blindedID, lhs.targetID, lhs.replicateID) <
            (rhs.blindedID, rhs.targetID, rhs.replicateID)
    }

    static func seriesScoreSort(
        _ lhs: ProspectiveSeriesScore,
        _ rhs: ProspectiveSeriesScore
    ) -> Bool {
        (lhs.forecasterID, lhs.blindedID, lhs.targetID, lhs.replicateID, lhs.scoringRuleID) <
            (rhs.forecasterID, rhs.blindedID, rhs.targetID, rhs.replicateID, rhs.scoringRuleID)
    }
}
