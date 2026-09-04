import Foundation
import NumiTissueIO

public struct ProspectiveCustodianRunDirective: Sendable, Hashable, Codable {
    public var ordinal: Int
    public var blindedID: String
    public var replicateID: String
    public var stratum: String
    public var runSeed: UInt64
    public var condition: ProspectiveExperimentalCondition

    public init(
        ordinal: Int,
        blindedID: String,
        replicateID: String,
        stratum: String,
        runSeed: UInt64,
        condition: ProspectiveExperimentalCondition
    ) {
        self.ordinal = ordinal
        self.blindedID = blindedID
        self.replicateID = replicateID
        self.stratum = stratum
        self.runSeed = runSeed
        self.condition = condition
    }

    public func validated() throws -> Self {
        guard ordinal >= 0,
              ProspectiveStudyIdentifier.isStable(blindedID),
              ProspectiveStudyIdentifier.isStable(replicateID),
              ProspectiveStudyIdentifier.isStable(stratum),
              runSeed != 0 else {
            throw ProspectiveStudyFactoryError.invalidRunAssignment
        }
        _ = try condition.validated()
        return self
    }
}

public struct ProspectiveCustodianExecutionPlan: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var studyID: UUID
    public var protocolSHA256: ScientificSHA256Digest
    public var publicAssignmentSHA256: ScientificSHA256Digest
    public var blindingKeySHA256: ScientificSHA256Digest
    public var directives: [ProspectiveCustodianRunDirective]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        studyID: UUID,
        protocolSHA256: ScientificSHA256Digest,
        publicAssignmentSHA256: ScientificSHA256Digest,
        blindingKeySHA256: ScientificSHA256Digest,
        directives: [ProspectiveCustodianRunDirective],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.studyID = studyID
        self.protocolSHA256 = protocolSHA256
        self.publicAssignmentSHA256 = publicAssignmentSHA256
        self.blindingKeySHA256 = blindingKeySHA256
        self.directives = directives
        self.metadata = metadata
    }

    public func validated(
        publicPackage: ProspectivePublicStudyPackage,
        custodianPackage: ProspectiveCustodianPackage
    ) throws -> Self {
        let protocolValue = try publicPackage.protocolValue.validated()
        _ = try custodianPackage.validated(protocolValue: protocolValue)
        guard schemaVersion == 1,
              studyID == protocolValue.id,
              protocolSHA256 == publicPackage.protocolSHA256,
              publicAssignmentSHA256 == publicPackage.assignmentsSHA256,
              blindingKeySHA256 == custodianPackage.keySHA256,
              directives.count == publicPackage.assignments.count,
              directives.map(\.ordinal) == Array(directives.indices),
              Set(directives.map { "\($0.blindedID)::\($0.replicateID)" }).count == directives.count,
              metadata.keys.allSatisfy(ProspectiveStudyIdentifier.isMetadataKey) else {
            throw ProspectiveStudyFactoryError.invalidCustodianPackage
        }
        for directive in directives { _ = try directive.validated() }
        let assignmentByOrdinal = Dictionary(
            uniqueKeysWithValues: publicPackage.assignments.map { ($0.ordinal, $0) }
        )
        let conditionByBlind = Dictionary(
            uniqueKeysWithValues: custodianPackage.blindingKey.entries.map {
                ($0.blindedID, $0.condition)
            }
        )
        for directive in directives {
            guard let assignment = assignmentByOrdinal[directive.ordinal],
                  let condition = conditionByBlind[directive.blindedID],
                  assignment.blindedID == directive.blindedID,
                  assignment.replicateID == directive.replicateID,
                  assignment.stratum == directive.stratum,
                  assignment.runSeed == directive.runSeed,
                  condition == directive.condition else {
                throw ProspectiveStudyFactoryError.invalidCustodianPackage
            }
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(self)
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public extension ProspectiveNeuralTissueStudyPackage {
    func makeCustodianExecutionPlan(
        against freeze: ProspectiveModelFreezeCertificate
    ) throws -> ProspectiveCustodianExecutionPlan {
        let package = try validated(against: freeze)
        let conditionByBlindID = Dictionary(
            uniqueKeysWithValues: package.custodianPackage.blindingKey.entries.map {
                ($0.blindedID, $0.condition)
            }
        )
        let directives = try package.publicPackage.assignments.map { assignment in
            guard let condition = conditionByBlindID[assignment.blindedID] else {
                throw ProspectiveStudyFactoryError.invalidCustodianPackage
            }
            return try ProspectiveCustodianRunDirective(
                ordinal: assignment.ordinal,
                blindedID: assignment.blindedID,
                replicateID: assignment.replicateID,
                stratum: assignment.stratum,
                runSeed: assignment.runSeed,
                condition: condition
            ).validated()
        }
        let plan = ProspectiveCustodianExecutionPlan(
            studyID: package.publicPackage.protocolValue.id,
            protocolSHA256: package.publicPackage.protocolSHA256,
            publicAssignmentSHA256: package.publicPackage.assignmentsSHA256,
            blindingKeySHA256: package.custodianPackage.keySHA256,
            directives: directives,
            metadata: [
                "distribution": "custodian-secure-environment-only",
                "contains-unblinded-conditions": "true"
            ]
        )
        return try plan.validated(
            publicPackage: package.publicPackage,
            custodianPackage: package.custodianPackage
        )
    }
}
