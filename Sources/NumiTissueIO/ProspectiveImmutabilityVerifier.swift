import Foundation

public struct ProspectiveArtifactVerification: Sendable, Hashable, Codable {
    public var role: ProspectiveFrozenArtifactRole
    public var relativePath: String
    public var expectedSHA256: ScientificSHA256Digest
    public var actualSHA256: ScientificSHA256Digest
    public var expectedByteCount: UInt64
    public var actualByteCount: UInt64
    public var readOnly: Bool
    public var passed: Bool

    public init(
        role: ProspectiveFrozenArtifactRole,
        relativePath: String,
        expectedSHA256: ScientificSHA256Digest,
        actualSHA256: ScientificSHA256Digest,
        expectedByteCount: UInt64,
        actualByteCount: UInt64,
        readOnly: Bool,
        passed: Bool
    ) {
        self.role = role
        self.relativePath = relativePath
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.expectedByteCount = expectedByteCount
        self.actualByteCount = actualByteCount
        self.readOnly = readOnly
        self.passed = passed
    }
}

public struct ProspectiveImmutabilityVerificationReport: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var checkedAt: Date
    public var checkedAfterUnblinding: Bool
    public var artifacts: [ProspectiveArtifactVerification]
    public var passed: Bool

    public init(
        schemaVersion: UInt32 = 1,
        modelFreezeSHA256: ScientificSHA256Digest,
        checkedAt: Date,
        checkedAfterUnblinding: Bool,
        artifacts: [ProspectiveArtifactVerification],
        passed: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.checkedAt = checkedAt
        self.checkedAfterUnblinding = checkedAfterUnblinding
        self.artifacts = artifacts
        self.passed = passed
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              artifacts.count == ProspectiveFrozenArtifactRole.allCases.count,
              Set(artifacts.map(\.role)).count == artifacts.count,
              passed == artifacts.allSatisfy({ $0.passed }) else {
            throw ProspectiveImmutabilityVerificationError.invalidReport
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

public struct ProspectiveImmutabilityVerification: Sendable, Hashable, Codable {
    public var report: ProspectiveImmutabilityVerificationReport
    public var attestation: ProspectiveImmutabilityAttestation

    public init(
        report: ProspectiveImmutabilityVerificationReport,
        attestation: ProspectiveImmutabilityAttestation
    ) {
        self.report = report
        self.attestation = attestation
    }
}

public enum ProspectiveImmutabilityVerifier {
    public static func verify(
        freezeBundle sourceBundle: ProspectiveModelFreezeBundle,
        rootURL: URL,
        protocolValue sourceProtocol: ProspectiveExperimentProtocol,
        prediction sourcePrediction: ProspectiveForecastBundle,
        unblinding sourceUnblinding: ProspectiveUnblindingRecord,
        checkedAt: Date,
        maximumArtifactBytes: UInt64 = 1_099_511_627_776
    ) throws -> ProspectiveImmutabilityVerification {
        let bundle = try sourceBundle.validated()
        let freeze = bundle.certificate
        let protocolValue = try sourceProtocol.validated(against: freeze)
        let prediction = try sourcePrediction.validated(
            for: protocolValue,
            freeze: freeze
        )
        guard sourceUnblinding.protocolSHA256 == (try protocolValue.sha256()),
              checkedAt >= sourceUnblinding.revealedAt else {
            throw ProspectiveImmutabilityVerificationError.checkBeforeUnblinding
        }
        var verifications: [ProspectiveArtifactVerification] = []
        for expected in bundle.artifacts.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
            let actual: ProspectiveFrozenArtifact
            do {
                actual = try ProspectiveModelFreezeBuilder.inspect(
                    role: expected.role,
                    relativePath: expected.relativePath,
                    mediaType: expected.mediaType,
                    rootURL: rootURL,
                    maximumBytes: maximumArtifactBytes
                )
            } catch {
                throw ProspectiveImmutabilityVerificationError.artifactInspectionFailed(
                    expected.relativePath,
                    String(describing: error)
                )
            }
            let passed = actual.sha256 == expected.sha256 &&
                actual.byteCount == expected.byteCount && actual.readOnly
            verifications.append(ProspectiveArtifactVerification(
                role: expected.role,
                relativePath: expected.relativePath,
                expectedSHA256: expected.sha256,
                actualSHA256: actual.sha256,
                expectedByteCount: expected.byteCount,
                actualByteCount: actual.byteCount,
                readOnly: actual.readOnly,
                passed: passed
            ))
        }
        let report = try ProspectiveImmutabilityVerificationReport(
            modelFreezeSHA256: try freeze.sha256(),
            checkedAt: checkedAt,
            checkedAfterUnblinding: true,
            artifacts: verifications,
            passed: verifications.allSatisfy(\.passed)
        ).validated()
        guard report.passed else {
            throw ProspectiveImmutabilityVerificationError.mutationDetected
        }
        let byRole = Dictionary(uniqueKeysWithValues: verifications.map { ($0.role, $0) })
        guard let model = byRole[.model],
              let parameters = byRole[.parameters],
              let checkpoint = byRole[.checkpoint],
              let configuration = byRole[.executionConfiguration] else {
            throw ProspectiveImmutabilityVerificationError.invalidReport
        }
        let attestation = ProspectiveImmutabilityAttestation(
            protocolSHA256: try protocolValue.sha256(),
            modelFreezeSHA256: try freeze.sha256(),
            predictionBundleSHA256: try prediction.sha256(),
            observedModelSHA256: model.actualSHA256,
            observedParametersSHA256: parameters.actualSHA256,
            observedCheckpointSHA256: checkpoint.actualSHA256,
            observedExecutionConfigurationSHA256: configuration.actualSHA256,
            checkedAt: checkedAt,
            checkedAfterUnblinding: true,
            modelArtifactReadOnly: model.readOnly,
            parameterArtifactReadOnly: parameters.readOnly,
            mutationDetected: false,
            evidenceArtifactSHA256: [try report.sha256()]
        )
        _ = try attestation.validated(
            protocolValue: protocolValue,
            freeze: freeze,
            prediction: prediction
        )
        return ProspectiveImmutabilityVerification(
            report: report,
            attestation: attestation
        )
    }
}

public enum ProspectiveImmutabilityVerificationError: Error, Sendable, CustomStringConvertible {
    case invalidReport
    case checkBeforeUnblinding
    case artifactInspectionFailed(String, String)
    case mutationDetected

    public var description: String {
        switch self {
        case .invalidReport:
            return "Prospective immutability verification report is invalid."
        case .checkBeforeUnblinding:
            return "Post-unblinding immutability verification cannot precede the reveal."
        case .artifactInspectionFailed(let path, let reason):
            return "Unable to inspect frozen artifact \(path): \(reason)"
        case .mutationDetected:
            return "A frozen prospective model artifact changed after certification."
        }
    }
}
