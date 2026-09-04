import Foundation

public enum ProspectiveExclusionTiming: String, Sendable, Hashable, Codable, CaseIterable {
    case beforeIntervention = "before-intervention"
    case beforeUnblinding = "before-unblinding"
}

public struct ProspectiveExclusionRule: Sendable, Hashable, Codable {
    public var code: String
    public var description: String
    public var timing: ProspectiveExclusionTiming
    public var objective: Bool

    public init(
        code: String,
        description: String,
        timing: ProspectiveExclusionTiming,
        objective: Bool = true
    ) {
        self.code = code
        self.description = description
        self.timing = timing
        self.objective = objective
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(code),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              objective else {
            throw ProspectivePredictionError.invalidExclusionRule(code)
        }
        return self
    }
}

public struct ProspectiveStoppingRule: Sendable, Hashable, Codable {
    public var code: String
    public var description: String
    public var safetyCritical: Bool

    public init(code: String, description: String, safetyCritical: Bool = true) {
        self.code = code
        self.description = description
        self.safetyCritical = safetyCritical
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(code),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProspectivePredictionError.invalidStoppingRule(code)
        }
        return self
    }
}

public struct ProspectiveRandomizationPlan: Sendable, Hashable, Codable {
    public var algorithm: String
    public var seedCommitmentSHA256: ScientificSHA256Digest
    public var blockSize: Int
    public var strata: [String]
    public var assignmentCount: Int
    public var generatedScheduleSHA256: ScientificSHA256Digest?

    public init(
        algorithm: String,
        seedCommitmentSHA256: ScientificSHA256Digest,
        blockSize: Int,
        strata: [String] = [],
        assignmentCount: Int,
        generatedScheduleSHA256: ScientificSHA256Digest? = nil
    ) {
        self.algorithm = algorithm
        self.seedCommitmentSHA256 = seedCommitmentSHA256
        self.blockSize = blockSize
        self.strata = strata
        self.assignmentCount = assignmentCount
        self.generatedScheduleSHA256 = generatedScheduleSHA256
    }

    public func validated(expectedAssignments: Int) throws -> Self {
        guard !algorithm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              blockSize > 0,
              assignmentCount == expectedAssignments,
              generatedScheduleSHA256 != nil,
              strata.allSatisfy(ProspectiveIdentifier.isStable),
              Set(strata).count == strata.count else {
            throw ProspectivePredictionError.invalidRandomization
        }
        return self
    }
}

public struct ProspectiveExperimentProtocol: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var id: UUID
    public var version: String
    public var title: String
    public var domain: ProspectiveStudyDomain
    public var registeredAt: Date
    public var predictionDeadline: Date
    public var plannedExperimentStart: Date
    public var calibrationDataCutoff: Date
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var hypotheses: [String]
    public var blindingCommitments: [ProspectiveBlindingCommitment]
    public var blindingCommitmentSetSHA256: ScientificSHA256Digest
    public var randomization: ProspectiveRandomizationPlan
    public var targets: [ProspectivePredictionTarget]
    public var baselines: [ProspectiveBaselineDefinition]
    public var scoringRules: [ProspectiveScoringRule]
    public var successCriteria: ProspectiveSuccessCriteria
    public var exclusions: [ProspectiveExclusionRule]
    public var stoppingRules: [ProspectiveStoppingRule]
    public var prohibitsPostFreezeParameterChanges: Bool
    public var unblindingRequiresSealedObservations: Bool
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: UUID,
        version: String,
        title: String,
        domain: ProspectiveStudyDomain,
        registeredAt: Date,
        predictionDeadline: Date,
        plannedExperimentStart: Date,
        calibrationDataCutoff: Date,
        modelFreezeSHA256: ScientificSHA256Digest,
        hypotheses: [String],
        blindingCommitments: [ProspectiveBlindingCommitment],
        blindingCommitmentSetSHA256: ScientificSHA256Digest,
        randomization: ProspectiveRandomizationPlan,
        targets: [ProspectivePredictionTarget],
        baselines: [ProspectiveBaselineDefinition],
        scoringRules: [ProspectiveScoringRule],
        successCriteria: ProspectiveSuccessCriteria,
        exclusions: [ProspectiveExclusionRule],
        stoppingRules: [ProspectiveStoppingRule],
        prohibitsPostFreezeParameterChanges: Bool = true,
        unblindingRequiresSealedObservations: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.title = title
        self.domain = domain
        self.registeredAt = registeredAt
        self.predictionDeadline = predictionDeadline
        self.plannedExperimentStart = plannedExperimentStart
        self.calibrationDataCutoff = calibrationDataCutoff
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.hypotheses = hypotheses
        self.blindingCommitments = blindingCommitments
        self.blindingCommitmentSetSHA256 = blindingCommitmentSetSHA256
        self.randomization = randomization
        self.targets = targets
        self.baselines = baselines
        self.scoringRules = scoringRules
        self.successCriteria = successCriteria
        self.exclusions = exclusions
        self.stoppingRules = stoppingRules
        self.prohibitsPostFreezeParameterChanges = prohibitsPostFreezeParameterChanges
        self.unblindingRequiresSealedObservations = unblindingRequiresSealedObservations
        self.metadata = metadata
    }

    public func validated(
        against freeze: ProspectiveModelFreezeCertificate? = nil
    ) throws -> Self {
        guard schemaVersion == 1,
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              calibrationDataCutoff <= registeredAt,
              registeredAt <= predictionDeadline,
              predictionDeadline <= plannedExperimentStart,
              !hypotheses.isEmpty,
              hypotheses.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(hypotheses).count == hypotheses.count,
              !blindingCommitments.isEmpty,
              !targets.isEmpty,
              targets.contains(where: \.primary),
              !baselines.isEmpty,
              baselines.contains(where: \.requiredForSuccess),
              !scoringRules.isEmpty,
              scoringRules.contains(where: \.primary),
              !exclusions.isEmpty,
              !stoppingRules.isEmpty,
              prohibitsPostFreezeParameterChanges,
              unblindingRequiresSealedObservations,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidProtocol
        }
        for commitment in blindingCommitments { _ = try commitment.validated() }
        for target in targets { _ = try target.validated() }
        for baseline in baselines { _ = try baseline.validated() }
        for rule in scoringRules { _ = try rule.validated() }
        for exclusion in exclusions { _ = try exclusion.validated() }
        for stopping in stoppingRules { _ = try stopping.validated() }
        _ = try successCriteria.validated()

        guard Set(blindingCommitments.map(\.blindedID)).count == blindingCommitments.count,
              Set(targets.map(\.id)).count == targets.count,
              Set(baselines.map(\.id)).count == baselines.count,
              Set(scoringRules.map(\.id)).count == scoringRules.count,
              Set(exclusions.map(\.code)).count == exclusions.count,
              Set(stoppingRules.map(\.code)).count == stoppingRules.count else {
            throw ProspectivePredictionError.duplicateProtocolIdentifier
        }
        let targetIDs = Set(targets.map(\.id))
        guard scoringRules.allSatisfy({ targetIDs.contains($0.targetID) }) else {
            throw ProspectivePredictionError.unknownScoringTarget
        }
        let expectedAssignments = blindingCommitments.reduce(0) {
            $0 + $1.replicateCount
        }
        _ = try randomization.validated(expectedAssignments: expectedAssignments)
        guard try ProspectiveBlindingKey.commitmentSetDigest(blindingCommitments) == blindingCommitmentSetSHA256 else {
            throw ProspectivePredictionError.blindingSetMismatch
        }
        if let freeze {
            _ = try freeze.validated()
            guard try freeze.sha256() == modelFreezeSHA256,
                  freeze.calibrationDataCutoff == calibrationDataCutoff,
                  freeze.frozenAt <= registeredAt else {
                throw ProspectivePredictionError.protocolFreezeMismatch
            }
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(try validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}
