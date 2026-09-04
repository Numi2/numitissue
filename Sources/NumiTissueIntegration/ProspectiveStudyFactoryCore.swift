import Foundation
import NumiTissueIO

extension ProspectiveNeuralTissueStudyFactory {
    static func makeStudy(
        freeze sourceFreeze: ProspectiveModelFreezeCertificate,
        configuration sourceConfiguration: ProspectiveStudyFactoryConfiguration,
        secrets sourceSecrets: ProspectiveStudyFactorySecrets,
        title: String,
        domain: ProspectiveStudyDomain,
        conditions sourceConditions: [ProspectiveExperimentalCondition],
        targets sourceTargets: [ProspectivePredictionTarget],
        hypotheses: [String],
        workUnitsPerRun: UInt64
    ) throws -> ProspectiveNeuralTissueStudyPackage {
        let freeze = try sourceFreeze.validated()
        let configuration = try sourceConfiguration.validated()
        let secrets = try sourceSecrets.validated()
        guard workUnitsPerRun > 0 else {
            throw ProspectiveStudyFactoryError.invalidWorkEstimate
        }
        let conditions = try sourceConditions.map { try $0.validated() }
        guard !conditions.isEmpty,
              Set(conditions.map(\.id)).count == conditions.count else {
            throw ProspectiveStudyFactoryError.invalidConditionSet
        }
        let targets = try sourceTargets.map { try $0.validated() }
        guard !targets.isEmpty,
              targets.contains(where: \.primary),
              Set(targets.map(\.id)).count == targets.count else {
            throw ProspectiveStudyFactoryError.invalidTargetSet
        }

        let labels = ProspectiveStudyCryptography.blindedLabelOrder(
            count: conditions.count,
            studyID: configuration.studyID,
            seed: secrets.randomizationSeed
        )
        let blindedIDByConditionID = Dictionary(
            uniqueKeysWithValues: zip(
                conditions.sorted { $0.id < $1.id }.map(\.id),
                labels
            )
        )
        let nonceByConditionID = Dictionary(uniqueKeysWithValues: conditions.map {
            ($0.id, ProspectiveStudyCryptography.conditionNonce(
                studyID: configuration.studyID,
                conditionID: $0.id,
                secret: secrets.blindingSecret
            ))
        })
        let replicateCountByConditionID = Dictionary(
            uniqueKeysWithValues: conditions.map {
                ($0.id, configuration.replicateCountPerCondition)
            }
        )
        let strataByConditionID = Dictionary(
            uniqueKeysWithValues: conditions.map {
                ($0.id, ["culture-batch": configuration.cultureBatch])
            }
        )
        let blinded = try ProspectiveBlindingFactory.make(
            studyID: configuration.studyID,
            createdAt: configuration.registeredAt,
            custodian: configuration.custodian,
            conditions: conditions,
            blindedIDByConditionID: blindedIDByConditionID,
            nonceByConditionID: nonceByConditionID,
            replicateCountByConditionID: replicateCountByConditionID,
            strataByConditionID: strataByConditionID,
            metadata: [
                "key-distribution": "custodian-only",
                "nonce-derivation": "sha256-domain-separated-v1"
            ]
        )
        let assignments = try makeAssignments(
            commitments: blinded.commitments,
            cultureBatch: configuration.cultureBatch,
            studyID: configuration.studyID,
            randomizationSeed: secrets.randomizationSeed
        )
        let assignmentsDigest = ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(assignments)
        )
        let freezeDigest = try freeze.sha256()
        let seedCommitment = ProspectiveStudyCryptography
            .randomizationSeedCommitment(
                studyID: configuration.studyID,
                seed: secrets.randomizationSeed
            )
        let baselines = baselineDefinitions(
            domain: domain,
            freeze: freeze,
            cutoff: freeze.calibrationDataCutoff
        )
        let scoringRules = scoringRules(for: targets)
        let protocolValue = try ProspectiveExperimentProtocol(
            id: configuration.studyID,
            version: "1.0.0",
            title: title,
            domain: domain,
            registeredAt: configuration.registeredAt,
            predictionDeadline: configuration.predictionDeadline,
            plannedExperimentStart: configuration.plannedExperimentStart,
            calibrationDataCutoff: freeze.calibrationDataCutoff,
            modelFreezeSHA256: freezeDigest,
            hypotheses: hypotheses,
            blindingCommitments: blinded.commitments,
            blindingCommitmentSetSHA256: blinded.key.commitmentSetSHA256,
            randomization: ProspectiveRandomizationPlan(
                algorithm: "balanced-permuted-block-v1",
                seedCommitmentSHA256: seedCommitment,
                blockSize: conditions.count,
                strata: [configuration.cultureBatch],
                assignmentCount: assignments.count,
                generatedScheduleSHA256: assignmentsDigest
            ),
            targets: targets,
            baselines: baselines,
            scoringRules: scoringRules,
            successCriteria: successCriteria(
                assignmentCount: assignments.count,
                replicateCountPerCondition: configuration.replicateCountPerCondition,
                seed: secrets.randomizationSeed
            ),
            exclusions: standardExclusions(domain: domain),
            stoppingRules: standardStoppingRules(domain: domain),
            metadata: configuration.metadata.merging([
                "suite-coupling": "NumiTissue-NumiBrain-NumanX",
                "forecast-form": "quantile-distribution",
                "unblinding-policy": "single-reveal-after-observation-seal",
                "condition-identities": "blinded",
                "randomization": "balanced-permuted-block-v1"
            ], uniquingKeysWith: { explicit, _ in explicit })
        ).validated(against: freeze)
        let protocolDigest = try protocolValue.sha256()
        let requiredDigests = [
            freezeDigest,
            protocolDigest,
            assignmentsDigest
        ].sorted { $0.hexadecimal < $1.hexadecimal }
        let trials = assignments.map { assignment in
            ScientificCampaignTrial(
                id: UInt64(assignment.ordinal + 1),
                randomSeed: assignment.runSeed,
                estimatedWorkUnits: workUnitsPerRun,
                modelDigest: freeze.modelSHA256,
                parameterDigest: freeze.parametersSHA256,
                requiredArtifactDigests: requiredDigests,
                metadata: [
                    "blinded-id": assignment.blindedID,
                    "replicate-id": assignment.replicateID,
                    "stratum": assignment.stratum,
                    "prospective": "true",
                    "unblinded-condition-available": "false"
                ]
            )
        }
        let campaign = try ScientificCampaignSharder.makeManifest(
            name: "phase5-\(domain.rawValue)",
            trials: trials,
            shardCount: min(configuration.shardCount, trials.count),
            campaignID: configuration.studyID,
            createdAt: configuration.registeredAt,
            metadata: [
                "prospective-protocol-sha256": protocolDigest.hexadecimal,
                "prospective-assignment-sha256": assignmentsDigest.hexadecimal,
                "model-freeze-sha256": freezeDigest.hexadecimal,
                "condition-identities": "blinded",
                "randomization-seed-commitment-sha256": seedCommitment.hexadecimal
            ]
        )
        let publicPackage = ProspectivePublicStudyPackage(
            protocolValue: protocolValue,
            assignments: assignments,
            campaign: campaign,
            protocolSHA256: protocolDigest,
            assignmentsSHA256: assignmentsDigest
        )
        let custodianPackage = ProspectiveCustodianPackage(
            blindingKey: blinded.key,
            keySHA256: try blinded.key.sha256(),
            publicProtocolSHA256: protocolDigest,
            assignmentScheduleSHA256: assignmentsDigest,
            randomizationSeed: secrets.randomizationSeed,
            randomizationSeedCommitmentSHA256: seedCommitment
        )
        return try ProspectiveNeuralTissueStudyPackage(
            publicPackage: publicPackage,
            custodianPackage: custodianPackage
        ).validated(against: freeze)
    }

    static func sustainedHypoxiaWaveform() -> [ProspectiveWaveformPoint] {
        [
            .init(timeSeconds: 0, value: 0.21),
            .init(timeSeconds: 300, value: 0.21),
            .init(timeSeconds: 360, value: 0.075),
            .init(timeSeconds: 1_800, value: 0.075),
            .init(timeSeconds: 1_860, value: 0.21),
            .init(timeSeconds: 3_600, value: 0.21)
        ]
    }

    static func intermittentOxygenWaveform() -> [ProspectiveWaveformPoint] {
        [
            .init(timeSeconds: 0, value: 0.21),
            .init(timeSeconds: 300, value: 0.21),
            .init(timeSeconds: 360, value: 0.11),
            .init(timeSeconds: 600, value: 0.11),
            .init(timeSeconds: 660, value: 0.21),
            .init(timeSeconds: 900, value: 0.21),
            .init(timeSeconds: 960, value: 0.075),
            .init(timeSeconds: 1_200, value: 0.075),
            .init(timeSeconds: 1_260, value: 0.21),
            .init(timeSeconds: 1_500, value: 0.21),
            .init(timeSeconds: 1_560, value: 0.05),
            .init(timeSeconds: 1_800, value: 0.05),
            .init(timeSeconds: 1_860, value: 0.21),
            .init(timeSeconds: 3_600, value: 0.21)
        ]
    }

    static func oxygenTarget(
        id: String,
        depth: Double,
        grid: [Double],
        primary: Bool
    ) -> ProspectivePredictionTarget {
        ProspectivePredictionTarget(
            id: id,
            title: "Dissolved oxygen at \(Int(depth)) micrometers",
            kind: .continuousTimeSeries,
            quantity: "dissolved-oxygen-fraction",
            unit: "fraction",
            region: "tissue-depth",
            depthMicrometers: depth,
            timeGridSeconds: grid,
            alignment: .linear,
            alignmentToleranceSeconds: 5,
            primary: primary,
            weight: primary ? 1.5 : 0.75,
            measurementStandardError: 0.005
        )
    }

    static func baselineDefinitions(
        domain: ProspectiveStudyDomain,
        freeze: ProspectiveModelFreezeCertificate,
        cutoff: Date
    ) -> [ProspectiveBaselineDefinition] {
        func baseline(
            id: String,
            title: String,
            kind: ProspectiveBaselineKind,
            required: Bool,
            usesTrainingData: Bool
        ) -> ProspectiveBaselineDefinition {
            ProspectiveBaselineDefinition(
                id: id,
                title: title,
                kind: kind,
                configurationSHA256: ProspectiveStudyCryptography.digest(
                    "numitissue.phase5.baseline.v1:\(domain.rawValue):\(id)"
                ),
                sourceArtifactSHA256: usesTrainingData
                    ? freeze.trainingCorpusSHA256
                    : [],
                trainingDataCutoff: cutoff,
                requiredForSuccess: required,
                metadata: ["domain": domain.rawValue]
            )
        }
        switch domain {
        case .intermittentOxygen:
            return [
                baseline(id: "persistence", title: "Last-observation persistence", kind: .persistence, required: true, usesTrainingData: false),
                baseline(id: "linear-recovery", title: "Piecewise linear suppression and recovery", kind: .linearRecovery, required: true, usesTrainingData: true),
                baseline(id: "historical-mean", title: "Historical-condition mean", kind: .historicalMean, required: false, usesTrainingData: true)
            ]
        case .receptorChannelBlocker:
            return [
                baseline(id: "persistence", title: "Last-observation persistence", kind: .persistence, required: true, usesTrainingData: false),
                baseline(id: "historical-mean", title: "Historical perturbation mean", kind: .historicalMean, required: true, usesTrainingData: true)
            ]
        case .injurySpreadingDepolarization:
            return [
                baseline(id: "persistence", title: "No-propagation persistence", kind: .persistence, required: true, usesTrainingData: false),
                baseline(id: "reduced-model", title: "Reduced reaction-diffusion injury model", kind: .reducedModel, required: true, usesTrainingData: true)
            ]
        case .developmentalOrganoidTrajectory:
            return [
                baseline(id: "historical-mean", title: "Historical developmental mean", kind: .historicalMean, required: true, usesTrainingData: true),
                baseline(id: "reduced-model", title: "Reduced logistic developmental trajectory", kind: .reducedModel, required: true, usesTrainingData: true)
            ]
        }
    }

    static func scoringRules(
        for targets: [ProspectivePredictionTarget]
    ) -> [ProspectiveScoringRule] {
        targets.flatMap { target in
            let start = target.timeGridSeconds.first ?? 0
            let end = target.timeGridSeconds.last ?? start
            let window = ProspectiveTimeWindow(startSeconds: start, endSeconds: end)
            var values = [ProspectiveScoringRule(
                id: "\(target.id)-crps",
                targetID: target.id,
                metric: .quantileCRPS,
                timeWindow: window,
                weight: target.weight,
                primary: target.primary,
                metadata: ["proper-score": "true"]
            )]
            if target.kind == .eventTime || target.kind == .scalar {
                values.append(ProspectiveScoringRule(
                    id: "\(target.id)-endpoint",
                    targetID: target.id,
                    metric: .absoluteEndpointError,
                    timeWindow: window,
                    weight: target.weight * 0.25,
                    primary: false
                ))
            } else {
                values.append(ProspectiveScoringRule(
                    id: "\(target.id)-wis",
                    targetID: target.id,
                    metric: .weightedIntervalScore,
                    timeWindow: window,
                    weight: target.weight * 0.5,
                    primary: false,
                    metadata: ["proper-score": "true"]
                ))
            }
            return values
        }
    }

    static func successCriteria(
        assignmentCount: Int,
        replicateCountPerCondition: Int,
        seed: UInt64
    ) -> ProspectiveSuccessCriteria {
        ProspectiveSuccessCriteria(
            minimumRelativeImprovement: 0.05,
            confidenceLevel: 0.90,
            bootstrapReplicates: 20_000,
            bootstrapSeed: ProspectiveStudyCryptography.mixedSeed(seed, 0x5048_4153_4535),
            maximumAbsoluteCoverageError: 0.10,
            minimumCoverageSampleCount: max(assignmentCount * 2, 24),
            minimumObservationFraction: 0.95,
            minimumCompletedReplicates: max(6, replicateCountPerCondition / 2),
            maximumMajorProtocolDeviations: 0,
            requireAllPrimaryTargets: true,
            requireNoPostFreezeMutation: true,
            requireNoPostUnblindingMutation: true
        )
    }

    static func standardExclusions(
        domain: ProspectiveStudyDomain
    ) -> [ProspectiveExclusionRule] {
        var rules: [ProspectiveExclusionRule] = [
            .init(code: "preintervention-contamination", description: "Culture contamination was detected before intervention.", timing: .beforeIntervention),
            .init(code: "preintervention-health", description: "Preregistered viability or baseline-activity threshold was not met before intervention.", timing: .beforeIntervention),
            .init(code: "electrode-impedance", description: "Required recording electrodes were outside the preregistered impedance range before intervention.", timing: .beforeIntervention),
            .init(code: "acquisition-dropout", description: "Recorded samples fell below the preregistered completeness threshold before unblinding.", timing: .beforeUnblinding)
        ]
        if domain == .intermittentOxygen {
            rules.append(.init(
                code: "oxygen-sensor-failure",
                description: "A depth oxygen sensor failed calibration or continuity checks before unblinding.",
                timing: .beforeUnblinding
            ))
        }
        return rules
    }

    static func standardStoppingRules(
        domain: ProspectiveStudyDomain
    ) -> [ProspectiveStoppingRule] {
        var rules: [ProspectiveStoppingRule] = [
            .init(code: "temperature-safety", description: "Stop if tissue temperature exits the approved culture range."),
            .init(code: "ph-safety", description: "Stop if extracellular pH exits the approved safety range."),
            .init(code: "contamination", description: "Stop immediately on evidence of culture contamination."),
            .init(code: "hardware-fault", description: "Stop on stimulation, perfusion or acquisition hardware fault.")
        ]
        if domain == .intermittentOxygen {
            rules.append(.init(
                code: "oxygen-safety",
                description: "Stop if dissolved oxygen remains below the approved minimum-duration threshold."
            ))
        }
        return rules
    }

    static func makeAssignments(
        commitments: [ProspectiveBlindingCommitment],
        cultureBatch: String,
        studyID: UUID,
        randomizationSeed: UInt64
    ) throws -> [ProspectiveBlindRunAssignment] {
        let commitments = try commitments
            .map { try $0.validated() }
            .sorted { $0.blindedID < $1.blindedID }
        guard let replicateCount = commitments.first?.replicateCount,
              commitments.allSatisfy({ $0.replicateCount == replicateCount }) else {
            throw ProspectiveStudyFactoryError.unbalancedCommitments
        }
        var output: [ProspectiveBlindRunAssignment] = []
        output.reserveCapacity(commitments.count * replicateCount)
        var ordinal = 0
        for replicateIndex in 0..<replicateCount {
            let blockSeed = ProspectiveStudyCryptography.mixedSeed(
                randomizationSeed,
                ProspectiveStudyCryptography.stableSeed(
                    "assignment-block:\(studyID.uuidString.lowercased()):\(replicateIndex)"
                )
            )
            let order = ProspectiveStudyCryptography.shuffled(
                commitments.map(\.blindedID),
                seed: blockSeed
            )
            guard Set(order) == Set(commitments.map(\.blindedID)) else {
                throw ProspectiveStudyFactoryError.randomizationFailure
            }
            for blindedID in order {
                let runSeed = ProspectiveStudyCryptography.mixedSeed(
                    randomizationSeed,
                    UInt64(ordinal + 1) ^ ProspectiveStudyCryptography.stableSeed(blindedID)
                )
                output.append(try ProspectiveBlindRunAssignment(
                    ordinal: ordinal,
                    blindedID: blindedID,
                    replicateID: "replicate-\(String(format: "%04d", replicateIndex + 1))",
                    stratum: cultureBatch,
                    runSeed: runSeed
                ).validated())
                ordinal += 1
            }
        }
        guard output.count == commitments.count * replicateCount,
              output.map(\.ordinal) == Array(output.indices) else {
            throw ProspectiveStudyFactoryError.randomizationFailure
        }
        return output
    }
}
