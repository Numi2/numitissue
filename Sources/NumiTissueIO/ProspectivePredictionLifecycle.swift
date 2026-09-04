import Foundation

public enum ProspectiveProtocolDeviationSeverity: String, Sendable, Hashable, Codable, CaseIterable {
    case informational
    case minor
    case major
    case disqualifying
}

public struct ProspectiveProtocolDeviation: Sendable, Hashable, Codable {
    public var code: String
    public var severity: ProspectiveProtocolDeviationSeverity
    public var detectedAt: Date
    public var description: String
    public var affectedBlindedIDs: [String]
    public var affectedReplicateIDs: [String]
    public var artifactSHA256: [ScientificSHA256Digest]

    public init(
        code: String,
        severity: ProspectiveProtocolDeviationSeverity,
        detectedAt: Date,
        description: String,
        affectedBlindedIDs: [String] = [],
        affectedReplicateIDs: [String] = [],
        artifactSHA256: [ScientificSHA256Digest] = []
    ) {
        self.code = code
        self.severity = severity
        self.detectedAt = detectedAt
        self.description = description
        self.affectedBlindedIDs = affectedBlindedIDs
        self.affectedReplicateIDs = affectedReplicateIDs
        self.artifactSHA256 = artifactSHA256
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(code),
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              affectedBlindedIDs.allSatisfy(ProspectiveIdentifier.isStable),
              affectedReplicateIDs.allSatisfy(ProspectiveIdentifier.isStable),
              Set(affectedBlindedIDs).count == affectedBlindedIDs.count,
              Set(affectedReplicateIDs).count == affectedReplicateIDs.count,
              Set(artifactSHA256).count == artifactSHA256.count else {
            throw ProspectivePredictionError.invalidProtocolDeviation(code)
        }
        return self
    }
}

public struct ProspectiveImmutabilityAttestation: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var protocolSHA256: ScientificSHA256Digest
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var predictionBundleSHA256: ScientificSHA256Digest
    public var observedModelSHA256: ScientificSHA256Digest
    public var observedParametersSHA256: ScientificSHA256Digest
    public var observedCheckpointSHA256: ScientificSHA256Digest
    public var observedExecutionConfigurationSHA256: ScientificSHA256Digest
    public var checkedAt: Date
    public var checkedAfterUnblinding: Bool
    public var modelArtifactReadOnly: Bool
    public var parameterArtifactReadOnly: Bool
    public var mutationDetected: Bool
    public var evidenceArtifactSHA256: [ScientificSHA256Digest]

    public init(
        schemaVersion: UInt32 = 1,
        protocolSHA256: ScientificSHA256Digest,
        modelFreezeSHA256: ScientificSHA256Digest,
        predictionBundleSHA256: ScientificSHA256Digest,
        observedModelSHA256: ScientificSHA256Digest,
        observedParametersSHA256: ScientificSHA256Digest,
        observedCheckpointSHA256: ScientificSHA256Digest,
        observedExecutionConfigurationSHA256: ScientificSHA256Digest,
        checkedAt: Date,
        checkedAfterUnblinding: Bool,
        modelArtifactReadOnly: Bool,
        parameterArtifactReadOnly: Bool,
        mutationDetected: Bool,
        evidenceArtifactSHA256: [ScientificSHA256Digest]
    ) {
        self.schemaVersion = schemaVersion
        self.protocolSHA256 = protocolSHA256
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.predictionBundleSHA256 = predictionBundleSHA256
        self.observedModelSHA256 = observedModelSHA256
        self.observedParametersSHA256 = observedParametersSHA256
        self.observedCheckpointSHA256 = observedCheckpointSHA256
        self.observedExecutionConfigurationSHA256 = observedExecutionConfigurationSHA256
        self.checkedAt = checkedAt
        self.checkedAfterUnblinding = checkedAfterUnblinding
        self.modelArtifactReadOnly = modelArtifactReadOnly
        self.parameterArtifactReadOnly = parameterArtifactReadOnly
        self.mutationDetected = mutationDetected
        self.evidenceArtifactSHA256 = evidenceArtifactSHA256
    }

    public func validated(
        protocolValue: ProspectiveExperimentProtocol,
        freeze: ProspectiveModelFreezeCertificate,
        prediction: ProspectiveForecastBundle
    ) throws -> Self {
        guard schemaVersion == 1,
              !evidenceArtifactSHA256.isEmpty,
              Set(evidenceArtifactSHA256).count == evidenceArtifactSHA256.count,
              checkedAfterUnblinding,
              modelArtifactReadOnly,
              parameterArtifactReadOnly,
              mutationDetected == false else {
            throw ProspectivePredictionError.invalidImmutabilityAttestation
        }
        let protocolDigest = try protocolValue.sha256()
        let freezeDigest = try freeze.sha256()
        let predictionDigest = try prediction.sha256()
        guard protocolSHA256 == protocolDigest,
              modelFreezeSHA256 == freezeDigest,
              predictionBundleSHA256 == predictionDigest,
              observedModelSHA256 == freeze.modelSHA256,
              observedParametersSHA256 == freeze.parametersSHA256,
              observedCheckpointSHA256 == freeze.checkpointSHA256,
              observedExecutionConfigurationSHA256 == freeze.executionConfigurationSHA256 else {
            throw ProspectivePredictionError.immutabilityMismatch
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

public struct ProspectiveUnblindingRecord: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var protocolSHA256: ScientificSHA256Digest
    public var observationBundleSHA256: ScientificSHA256Digest
    public var blindingKeySHA256: ScientificSHA256Digest
    public var revealedAt: Date
    public var revealedBy: String
    public var observationWasSealedBeforeReveal: Bool
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        protocolSHA256: ScientificSHA256Digest,
        observationBundleSHA256: ScientificSHA256Digest,
        blindingKeySHA256: ScientificSHA256Digest,
        revealedAt: Date,
        revealedBy: String,
        observationWasSealedBeforeReveal: Bool,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.protocolSHA256 = protocolSHA256
        self.observationBundleSHA256 = observationBundleSHA256
        self.blindingKeySHA256 = blindingKeySHA256
        self.revealedAt = revealedAt
        self.revealedBy = revealedBy
        self.observationWasSealedBeforeReveal = observationWasSealedBeforeReveal
        self.metadata = metadata
    }

    public func validated(
        protocolValue: ProspectiveExperimentProtocol,
        observations: ProspectiveObservationBundle,
        key: ProspectiveBlindingKey
    ) throws -> Self {
        let protocolValue = try protocolValue.validated()
        _ = try observations.validated(for: protocolValue)
        _ = try key.validated(commitments: protocolValue.blindingCommitments)
        guard schemaVersion == 1,
              protocolSHA256 == (try protocolValue.sha256()),
              observationBundleSHA256 == (try observations.sha256()),
              blindingKeySHA256 == (try key.sha256()),
              revealedAt >= observations.sealedAt,
              !revealedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              observationWasSealedBeforeReveal,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidUnblindingRecord
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

enum ProspectiveIdentifier {
    static func isStable(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 256,
              value.first?.isLetter == true else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "-" || scalar == "." || scalar == "_"
        }
    }

    static func isMetadataKey(_ value: String) -> Bool {
        isStable(value)
    }

    static func isRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy { isStable(String($0)) }
    }

    static func isGitObject(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

public enum ProspectivePredictionError: Error, Sendable, CustomStringConvertible {
    case nonFiniteValue
    case invalidTransformedValue
    case invalidTimeWindow
    case invalidTarget(String)
    case invalidTargetTimeGrid(String)
    case invalidWaveform
    case invalidCondition(String)
    case invalidBlindingCommitment(String)
    case invalidBlindingKeyEntry(String)
    case invalidBlindingKey
    case invalidBlindingRequest
    case blindingCommitmentMismatch(String)
    case blindingSetMismatch
    case invalidModelFreeze
    case invalidBaseline(String)
    case invalidScoringRule(String)
    case invalidSuccessCriteria
    case invalidExclusionRule(String)
    case invalidStoppingRule(String)
    case invalidRandomization
    case invalidProtocol
    case duplicateProtocolIdentifier
    case unknownScoringTarget
    case protocolFreezeMismatch
    case invalidQuantile
    case invalidForecastPoint
    case invalidForecastSeries
    case invalidForecastAuthority
    case invalidForecastBundle
    case duplicateForecastSeries
    case forecastProtocolMismatch
    case forecastFreezeMismatch
    case incompleteForecastBundle
    case invalidObservationPoint
    case invalidObservationSeries
    case invalidObservationBundle
    case duplicateObservationSeries
    case observationProtocolMismatch
    case observationReplicateMismatch(String)
    case incompleteObservationBundle
    case invalidProtocolDeviation(String)
    case invalidImmutabilityAttestation
    case immutabilityMismatch
    case invalidUnblindingRecord

    public var description: String {
        switch self {
        case .nonFiniteValue: return "Prospective value is non-finite."
        case .invalidTransformedValue: return "Prospective value is outside the transform domain."
        case .invalidTimeWindow: return "Prospective scoring time window is invalid."
        case .invalidTarget(let id): return "Prospective target \(id) is invalid."
        case .invalidTargetTimeGrid(let id): return "Prospective target \(id) has an invalid time grid."
        case .invalidWaveform: return "Prospective intervention waveform is invalid."
        case .invalidCondition(let id): return "Prospective condition \(id) is invalid."
        case .invalidBlindingCommitment(let id): return "Blinding commitment \(id) is invalid."
        case .invalidBlindingKeyEntry(let id): return "Blinding key entry \(id) is invalid."
        case .invalidBlindingKey: return "Prospective blinding key is invalid."
        case .invalidBlindingRequest: return "Prospective blinding request is incomplete or ambiguous."
        case .blindingCommitmentMismatch(let id): return "Blinding commitment \(id) does not match its reveal."
        case .blindingSetMismatch: return "Blinding commitment-set digest does not match."
        case .invalidModelFreeze: return "Prospective model-freeze certificate is invalid."
        case .invalidBaseline(let id): return "Prospective baseline \(id) is invalid."
        case .invalidScoringRule(let id): return "Prospective scoring rule \(id) is invalid."
        case .invalidSuccessCriteria: return "Prospective success criteria are invalid."
        case .invalidExclusionRule(let code): return "Prospective exclusion rule \(code) is invalid."
        case .invalidStoppingRule(let code): return "Prospective stopping rule \(code) is invalid."
        case .invalidRandomization: return "Prospective randomization plan is invalid."
        case .invalidProtocol: return "Prospective experiment protocol is invalid."
        case .duplicateProtocolIdentifier: return "Prospective protocol contains duplicate identifiers."
        case .unknownScoringTarget: return "Prospective scoring rule references an unknown target."
        case .protocolFreezeMismatch: return "Prospective protocol does not match the model-freeze certificate."
        case .invalidQuantile: return "Prospective forecast quantile is invalid."
        case .invalidForecastPoint: return "Prospective forecast point is invalid."
        case .invalidForecastSeries: return "Prospective forecast series is invalid."
        case .invalidForecastAuthority: return "Prospective forecast authority is invalid."
        case .invalidForecastBundle: return "Prospective forecast bundle is invalid."
        case .duplicateForecastSeries: return "Prospective forecast bundle contains duplicate series."
        case .forecastProtocolMismatch: return "Prospective forecast bundle does not match the registered protocol."
        case .forecastFreezeMismatch: return "Prospective forecast bundle does not match the frozen model."
        case .incompleteForecastBundle: return "Prospective forecast bundle does not cover every blinded condition and target."
        case .invalidObservationPoint: return "Prospective observation point is invalid."
        case .invalidObservationSeries: return "Prospective observation series is invalid."
        case .invalidObservationBundle: return "Prospective observation bundle is invalid."
        case .duplicateObservationSeries: return "Prospective observation bundle contains duplicate series."
        case .observationProtocolMismatch: return "Prospective observation bundle does not match the protocol."
        case .observationReplicateMismatch(let id): return "Observed replicate count does not match blinded condition \(id)."
        case .incompleteObservationBundle: return "Prospective observations do not cover every preregistered target and replicate."
        case .invalidProtocolDeviation(let code): return "Prospective protocol deviation \(code) is invalid."
        case .invalidImmutabilityAttestation: return "Prospective immutability attestation is invalid."
        case .immutabilityMismatch: return "Observed model artifacts do not match the frozen model."
        case .invalidUnblindingRecord: return "Prospective unblinding record is invalid."
        }
    }
}
