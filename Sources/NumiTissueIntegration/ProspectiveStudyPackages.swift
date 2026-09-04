import Foundation
import NumiTissueIO

public struct ProspectiveBlindRunAssignment: Sendable, Hashable, Codable {
    public var ordinal: Int
    public var blindedID: String
    public var replicateID: String
    public var stratum: String
    public var runSeed: UInt64

    public init(
        ordinal: Int,
        blindedID: String,
        replicateID: String,
        stratum: String,
        runSeed: UInt64
    ) {
        self.ordinal = ordinal
        self.blindedID = blindedID
        self.replicateID = replicateID
        self.stratum = stratum
        self.runSeed = runSeed
    }

    public func validated() throws -> Self {
        guard ordinal >= 0,
              ProspectiveStudyIdentifier.isStable(blindedID),
              ProspectiveStudyIdentifier.isStable(replicateID),
              ProspectiveStudyIdentifier.isStable(stratum) else {
            throw ProspectiveStudyFactoryError.invalidRunAssignment
        }
        return self
    }
}

public struct ProspectivePublicStudyPackage: Sendable, Hashable, Codable {
    public var protocolValue: ProspectiveExperimentProtocol
    public var assignments: [ProspectiveBlindRunAssignment]
    public var campaign: ScientificCampaignManifest
    public var protocolSHA256: ScientificSHA256Digest
    public var assignmentsSHA256: ScientificSHA256Digest

    public init(
        protocolValue: ProspectiveExperimentProtocol,
        assignments: [ProspectiveBlindRunAssignment],
        campaign: ScientificCampaignManifest,
        protocolSHA256: ScientificSHA256Digest,
        assignmentsSHA256: ScientificSHA256Digest
    ) {
        self.protocolValue = protocolValue
        self.assignments = assignments
        self.campaign = campaign
        self.protocolSHA256 = protocolSHA256
        self.assignmentsSHA256 = assignmentsSHA256
    }

    public func validated(
        against sourceFreeze: ProspectiveModelFreezeCertificate
    ) throws -> Self {
        let freeze = try sourceFreeze.validated()
        let protocolValue = try protocolValue.validated(against: freeze)
        guard !assignments.isEmpty,
              assignments.map(\.ordinal).sorted() == Array(assignments.indices),
              Set(assignments.map {
                  "\($0.blindedID)::\($0.replicateID)"
              }).count == assignments.count,
              protocolSHA256 == (try protocolValue.sha256()),
              assignmentsSHA256 == ScientificSHA256Digest(
                  data: try ScientificCanonicalJSON.encode(assignments)
              ),
              protocolValue.randomization.generatedScheduleSHA256 == assignmentsSHA256 else {
            throw ProspectiveStudyFactoryError.invalidPublicPackage
        }
        for assignment in assignments { _ = try assignment.validated() }
        let expectedCountByBlind = Dictionary(
            uniqueKeysWithValues: protocolValue.blindingCommitments.map {
                ($0.blindedID, $0.replicateCount)
            }
        )
        let actualCountByBlind = Dictionary(grouping: assignments, by: \.blindedID)
            .mapValues(\.count)
        guard expectedCountByBlind == actualCountByBlind,
              Set(assignments.map(\.stratum)).isSubset(
                  of: Set(protocolValue.randomization.strata)
              ) else {
            throw ProspectiveStudyFactoryError.invalidPublicPackage
        }

        let campaign = try campaign.validated()
        guard campaign.id == protocolValue.id,
              campaign.name == "phase5-\(protocolValue.domain.rawValue)",
              campaign.createdAt == protocolValue.registeredAt,
              campaign.trialCount == assignments.count,
              campaign.metadata["prospective-protocol-sha256"] == protocolSHA256.hexadecimal,
              campaign.metadata["prospective-assignment-sha256"] == assignmentsSHA256.hexadecimal,
              campaign.metadata["model-freeze-sha256"] == (try freeze.sha256()).hexadecimal,
              campaign.metadata["condition-identities"] == "blinded" else {
            throw ProspectiveStudyFactoryError.campaignMismatch
        }
        let trialByID = Dictionary(
            uniqueKeysWithValues: campaign.shards.flatMap(\.trials).map {
                ($0.id, $0)
            }
        )
        let required = Set([
            try freeze.sha256(),
            protocolSHA256,
            assignmentsSHA256
        ])
        for assignment in assignments {
            let trialID = UInt64(assignment.ordinal + 1)
            guard let trial = trialByID[trialID],
                  trial.randomSeed == assignment.runSeed,
                  trial.modelDigest == freeze.modelSHA256,
                  trial.parameterDigest == freeze.parametersSHA256,
                  Set(trial.requiredArtifactDigests) == required,
                  trial.metadata["blinded-id"] == assignment.blindedID,
                  trial.metadata["replicate-id"] == assignment.replicateID,
                  trial.metadata["stratum"] == assignment.stratum,
                  trial.metadata["prospective"] == "true" else {
                throw ProspectiveStudyFactoryError.campaignMismatch
            }
        }
        return self
    }
}

public struct ProspectiveCustodianPackage: Sendable, Hashable, Codable {
    public var blindingKey: ProspectiveBlindingKey
    public var keySHA256: ScientificSHA256Digest
    public var publicProtocolSHA256: ScientificSHA256Digest
    public var assignmentScheduleSHA256: ScientificSHA256Digest
    public var randomizationSeed: UInt64
    public var randomizationSeedCommitmentSHA256: ScientificSHA256Digest

    public init(
        blindingKey: ProspectiveBlindingKey,
        keySHA256: ScientificSHA256Digest,
        publicProtocolSHA256: ScientificSHA256Digest,
        assignmentScheduleSHA256: ScientificSHA256Digest,
        randomizationSeed: UInt64,
        randomizationSeedCommitmentSHA256: ScientificSHA256Digest
    ) {
        self.blindingKey = blindingKey
        self.keySHA256 = keySHA256
        self.publicProtocolSHA256 = publicProtocolSHA256
        self.assignmentScheduleSHA256 = assignmentScheduleSHA256
        self.randomizationSeed = randomizationSeed
        self.randomizationSeedCommitmentSHA256 = randomizationSeedCommitmentSHA256
    }

    public func validated(
        protocolValue sourceProtocol: ProspectiveExperimentProtocol
    ) throws -> Self {
        let protocolValue = try sourceProtocol.validated()
        _ = try blindingKey.validated(
            commitments: protocolValue.blindingCommitments
        )
        let expectedSeedCommitment = ProspectiveStudyCryptography
            .randomizationSeedCommitment(
                studyID: protocolValue.id,
                seed: randomizationSeed
            )
        guard blindingKey.studyID == protocolValue.id,
              keySHA256 == (try blindingKey.sha256()),
              publicProtocolSHA256 == (try protocolValue.sha256()),
              assignmentScheduleSHA256 == protocolValue.randomization.generatedScheduleSHA256,
              randomizationSeedCommitmentSHA256 == expectedSeedCommitment,
              protocolValue.randomization.seedCommitmentSHA256 == expectedSeedCommitment else {
            throw ProspectiveStudyFactoryError.invalidCustodianPackage
        }
        return self
    }
}

public struct ProspectiveNeuralTissueStudyPackage: Sendable, Hashable, Codable {
    public var publicPackage: ProspectivePublicStudyPackage
    public var custodianPackage: ProspectiveCustodianPackage

    public init(
        publicPackage: ProspectivePublicStudyPackage,
        custodianPackage: ProspectiveCustodianPackage
    ) {
        self.publicPackage = publicPackage
        self.custodianPackage = custodianPackage
    }

    public func validated(
        against freeze: ProspectiveModelFreezeCertificate
    ) throws -> Self {
        _ = try publicPackage.validated(against: freeze)
        _ = try custodianPackage.validated(
            protocolValue: publicPackage.protocolValue
        )
        return self
    }
}

public struct ProspectiveStudyFactoryConfiguration: Sendable, Hashable, Codable {
    public var studyID: UUID
    public var registeredAt: Date
    public var predictionDeadline: Date
    public var plannedExperimentStart: Date
    public var custodian: String
    public var replicateCountPerCondition: Int
    public var shardCount: Int
    public var cultureBatch: String
    public var metadata: [String: String]

    public init(
        studyID: UUID,
        registeredAt: Date,
        predictionDeadline: Date,
        plannedExperimentStart: Date,
        custodian: String,
        replicateCountPerCondition: Int = 12,
        shardCount: Int = 4,
        cultureBatch: String = "batch-1",
        metadata: [String: String] = [:]
    ) {
        self.studyID = studyID
        self.registeredAt = registeredAt
        self.predictionDeadline = predictionDeadline
        self.plannedExperimentStart = plannedExperimentStart
        self.custodian = custodian
        self.replicateCountPerCondition = replicateCountPerCondition
        self.shardCount = shardCount
        self.cultureBatch = cultureBatch
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard registeredAt < predictionDeadline,
              predictionDeadline < plannedExperimentStart,
              !custodian.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              replicateCountPerCondition >= 6,
              replicateCountPerCondition <= 10_000,
              shardCount > 0,
              shardCount <= 1_024,
              ProspectiveStudyIdentifier.isStable(cultureBatch),
              metadata.keys.allSatisfy(
                  ProspectiveStudyIdentifier.isMetadataKey
              ) else {
            throw ProspectiveStudyFactoryError.invalidConfiguration
        }
        return self
    }
}

public struct ProspectiveStudyFactorySecrets: Sendable, Hashable, Codable {
    public var randomizationSeed: UInt64
    public var blindingSecret: String

    public init(randomizationSeed: UInt64, blindingSecret: String) {
        self.randomizationSeed = randomizationSeed
        self.blindingSecret = blindingSecret
    }

    public func validated() throws -> Self {
        let byteCount = blindingSecret.utf8.count
        guard randomizationSeed != 0,
              byteCount >= 32,
              byteCount <= 4_096 else {
            throw ProspectiveStudyFactoryError.invalidSecrets
        }
        return self
    }
}

public enum ProspectiveStudySecretFactory {
    public static func generate() -> ProspectiveStudyFactorySecrets {
        var generator = SystemRandomNumberGenerator()
        var seed = UInt64.random(in: UInt64.min...UInt64.max, using: &generator)
        if seed == 0 { seed = 1 }
        let bytes = (0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        let secret = bytes.map {
            String(format: "%02x", $0)
        }.joined()
        return ProspectiveStudyFactorySecrets(
            randomizationSeed: seed,
            blindingSecret: secret
        )
    }
}
