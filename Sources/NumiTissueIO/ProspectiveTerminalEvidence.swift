import Foundation

public struct ProspectiveTerminalEvidence: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var freeze: ProspectiveModelFreezeCertificate
    public var protocolValue: ProspectiveExperimentProtocol
    public var candidateForecast: ProspectiveForecastBundle
    public var baselineForecasts: [ProspectiveForecastBundle]
    public var observations: ProspectiveObservationBundle
    public var blindingKey: ProspectiveBlindingKey
    public var unblinding: ProspectiveUnblindingRecord
    public var immutability: ProspectiveImmutabilityAttestation
    public var score: ProspectiveScoreReport
    public var ledger: ProspectiveEvidenceLedger
    public var sealedAt: Date
    public var sealedBy: String
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        freeze: ProspectiveModelFreezeCertificate,
        protocolValue: ProspectiveExperimentProtocol,
        candidateForecast: ProspectiveForecastBundle,
        baselineForecasts: [ProspectiveForecastBundle],
        observations: ProspectiveObservationBundle,
        blindingKey: ProspectiveBlindingKey,
        unblinding: ProspectiveUnblindingRecord,
        immutability: ProspectiveImmutabilityAttestation,
        score: ProspectiveScoreReport,
        ledger: ProspectiveEvidenceLedger,
        sealedAt: Date,
        sealedBy: String,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.freeze = freeze
        self.protocolValue = protocolValue
        self.candidateForecast = candidateForecast
        self.baselineForecasts = baselineForecasts
        self.observations = observations
        self.blindingKey = blindingKey
        self.unblinding = unblinding
        self.immutability = immutability
        self.score = score
        self.ledger = ledger
        self.sealedAt = sealedAt
        self.sealedBy = sealedBy
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        let freeze = try freeze.validated()
        let protocolValue = try protocolValue.validated(against: freeze)
        let candidate = try candidateForecast.validated(for: protocolValue, freeze: freeze)
        guard candidate.authority.kind == .frozenModel else {
            throw ProspectiveEvidenceError.candidateAuthorityRequired
        }
        guard !baselineForecasts.isEmpty else {
            throw ProspectiveEvidenceError.missingBaselineForecast
        }
        var baselineIDs = Set<String>()
        for baseline in baselineForecasts {
            let value = try baseline.validated(for: protocolValue, freeze: freeze)
            guard value.authority.kind == .baseline,
                  baselineIDs.insert(value.authority.identifier).inserted else {
                throw ProspectiveEvidenceError.invalidBaselineForecast
            }
        }
        _ = try observations.validated(for: protocolValue)
        _ = try blindingKey.validated(commitments: protocolValue.blindingCommitments)
        _ = try unblinding.validated(
            protocolValue: protocolValue,
            observations: observations,
            key: blindingKey
        )
        _ = try immutability.validated(
            protocolValue: protocolValue,
            freeze: freeze,
            prediction: candidate
        )
        _ = try score.validated()
        _ = try ledger.validated()
        guard schemaVersion == 1,
              !sealedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey),
              protocolValue.prospectiveStudyIdentifier == ledger.studyID,
              ledger.modelFreezeSHA256 == (try freeze.sha256()),
              ledger.protocolSHA256 == (try protocolValue.sha256()),
              score.modelFreezeSHA256 == (try freeze.sha256()),
              score.protocolSHA256 == (try protocolValue.sha256()),
              score.candidateForecastSHA256 == (try candidate.sha256()),
              score.observationBundleSHA256 == (try observations.sha256()),
              score.blindingKeySHA256 == (try blindingKey.sha256()),
              score.unblindingRecordSHA256 == (try unblinding.sha256()),
              score.immutabilityAttestationSHA256 == (try immutability.sha256()),
              Set(score.baselineForecastSHA256.keys) == baselineIDs,
              sealedAt >= score.scoredAt,
              (ledger.events.last?.recordedAt ?? sealedAt) <= sealedAt else {
            throw ProspectiveEvidenceError.evidenceMismatch
        }
        let actualBaselines = try Dictionary(uniqueKeysWithValues: baselineForecasts.map {
            ($0.authority.identifier, try $0.sha256())
        })
        guard score.baselineForecastSHA256 == actualBaselines else {
            throw ProspectiveEvidenceError.evidenceMismatch
        }
        let eventsByKind = Dictionary(grouping: ledger.events, by: \.kind)
        func singleEvent(_ kind: ProspectiveEvidenceEventKind) throws -> ProspectiveEvidenceEvent {
            guard let values = eventsByKind[kind], values.count == 1,
                  let event = values.first else {
                throw ProspectiveEvidenceError.ledgerArtifactMismatch(kind)
            }
            return event
        }
        let freezeDigest = try freeze.sha256()
        let protocolDigest = try protocolValue.sha256()
        let candidateDigest = try candidate.sha256()
        let observationDigest = try observations.sha256()
        let unblindingDigest = try unblinding.sha256()
        let immutabilityDigest = try immutability.sha256()
        let scoreDigest = try score.sha256()
        guard try singleEvent(.modelFrozen).artifactSHA256 == freezeDigest,
              try singleEvent(.protocolRegistered).artifactSHA256 == protocolDigest,
              try singleEvent(.candidateForecastSealed).artifactSHA256 == candidateDigest,
              try singleEvent(.experimentStarted).artifactSHA256 == protocolValue.randomization.generatedScheduleSHA256,
              try singleEvent(.observationBundleSealed).artifactSHA256 == observationDigest,
              try singleEvent(.unblinded).artifactSHA256 == unblindingDigest,
              try singleEvent(.immutabilityVerified).artifactSHA256 == immutabilityDigest,
              try singleEvent(.scoreSealed).artifactSHA256 == scoreDigest,
              try singleEvent(.evidenceClosed).artifactSHA256 == scoreDigest else {
            throw ProspectiveEvidenceError.evidenceMismatch
        }
        let baselineEvents = eventsByKind[.baselineForecastSealed] ?? []
        guard baselineEvents.count == actualBaselines.count,
              Set(baselineEvents.map(\.artifactSHA256)) == Set(actualBaselines.values),
              ledger.events.count == 9 + baselineEvents.count else {
            throw ProspectiveEvidenceError.ledgerArtifactMismatch(.baselineForecastSealed)
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
