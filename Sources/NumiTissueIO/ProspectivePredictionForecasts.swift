import Foundation

public struct ProspectiveQuantile: Sendable, Hashable, Codable {
    public var probability: Double
    public var value: Double

    public init(probability: Double, value: Double) {
        self.probability = probability
        self.value = value
    }

    public func validated() throws -> Self {
        guard probability.isFinite,
              probability > 0,
              probability < 1,
              value.isFinite else {
            throw ProspectivePredictionError.invalidQuantile
        }
        return self
    }
}

public struct ProspectiveForecastPoint: Sendable, Hashable, Codable {
    public var timeSeconds: Double
    public var quantiles: [ProspectiveQuantile]

    public init(timeSeconds: Double, quantiles: [ProspectiveQuantile]) {
        self.timeSeconds = timeSeconds
        self.quantiles = quantiles
    }

    public func validated() throws -> Self {
        guard timeSeconds.isFinite,
              timeSeconds >= 0,
              quantiles.count >= 3,
              quantiles.count <= 1_001 else {
            throw ProspectivePredictionError.invalidForecastPoint
        }
        for quantile in quantiles { _ = try quantile.validated() }
        let ordered = quantiles.sorted { $0.probability < $1.probability }
        guard ordered == quantiles,
              Set(quantiles.map(\.probability)).count == quantiles.count,
              zip(quantiles, quantiles.dropFirst()).allSatisfy({ $0.value <= $1.value }),
              quantiles.contains(where: { abs($0.probability - 0.5) <= 1e-12 }) else {
            throw ProspectivePredictionError.invalidForecastPoint
        }
        return self
    }
}

public struct ProspectiveForecastSeries: Sendable, Hashable, Codable {
    public var blindedID: String
    public var targetID: String
    public var unit: String
    public var points: [ProspectiveForecastPoint]
    public var metadata: [String: String]

    public init(
        blindedID: String,
        targetID: String,
        unit: String,
        points: [ProspectiveForecastPoint],
        metadata: [String: String] = [:]
    ) {
        self.blindedID = blindedID
        self.targetID = targetID
        self.unit = unit
        self.points = points
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(blindedID),
              ProspectiveIdentifier.isStable(targetID),
              !unit.isEmpty,
              !points.isEmpty,
              points.count <= 1_000_000,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidForecastSeries
        }
        for point in points { _ = try point.validated() }
        guard zip(points, points.dropFirst()).allSatisfy({
            $0.timeSeconds < $1.timeSeconds
        }) else {
            throw ProspectivePredictionError.invalidForecastSeries
        }
        return self
    }
}

public enum ProspectiveForecastAuthorityKind: String, Sendable, Hashable, Codable {
    case frozenModel = "frozen-model"
    case baseline
}

public struct ProspectiveForecastAuthority: Sendable, Hashable, Codable {
    public var kind: ProspectiveForecastAuthorityKind
    public var identifier: String
    public var modelFreezeSHA256: ScientificSHA256Digest?
    public var configurationSHA256: ScientificSHA256Digest

    public init(
        kind: ProspectiveForecastAuthorityKind,
        identifier: String,
        modelFreezeSHA256: ScientificSHA256Digest? = nil,
        configurationSHA256: ScientificSHA256Digest
    ) {
        self.kind = kind
        self.identifier = identifier
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.configurationSHA256 = configurationSHA256
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(identifier) else {
            throw ProspectivePredictionError.invalidForecastAuthority
        }
        switch kind {
        case .frozenModel:
            guard modelFreezeSHA256 != nil else {
                throw ProspectivePredictionError.invalidForecastAuthority
            }
        case .baseline:
            guard modelFreezeSHA256 == nil else {
                throw ProspectivePredictionError.invalidForecastAuthority
            }
        }
        return self
    }
}

public struct ProspectiveForecastBundle: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var id: UUID
    public var protocolSHA256: ScientificSHA256Digest
    public var authority: ProspectiveForecastAuthority
    public var issuedAt: Date
    public var experimentStartNotBefore: Date
    public var series: [ProspectiveForecastSeries]
    public var randomSeeds: [UInt64]
    public var supportingArtifactSHA256: [ScientificSHA256Digest]
    public var generatedWithoutProspectiveObservations: Bool
    public var postFreezeMutationDetected: Bool
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: UUID = UUID(),
        protocolSHA256: ScientificSHA256Digest,
        authority: ProspectiveForecastAuthority,
        issuedAt: Date,
        experimentStartNotBefore: Date,
        series: [ProspectiveForecastSeries],
        randomSeeds: [UInt64],
        supportingArtifactSHA256: [ScientificSHA256Digest] = [],
        generatedWithoutProspectiveObservations: Bool = true,
        postFreezeMutationDetected: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.protocolSHA256 = protocolSHA256
        self.authority = authority
        self.issuedAt = issuedAt
        self.experimentStartNotBefore = experimentStartNotBefore
        self.series = series
        self.randomSeeds = randomSeeds
        self.supportingArtifactSHA256 = supportingArtifactSHA256
        self.generatedWithoutProspectiveObservations = generatedWithoutProspectiveObservations
        self.postFreezeMutationDetected = postFreezeMutationDetected
        self.metadata = metadata
    }

    public func validated(
        for protocolValue: ProspectiveExperimentProtocol? = nil,
        freeze: ProspectiveModelFreezeCertificate? = nil
    ) throws -> Self {
        guard schemaVersion == 1,
              !series.isEmpty,
              !randomSeeds.isEmpty,
              Set(randomSeeds).count == randomSeeds.count,
              Set(supportingArtifactSHA256).count == supportingArtifactSHA256.count,
              generatedWithoutProspectiveObservations,
              postFreezeMutationDetected == false,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidForecastBundle
        }
        _ = try authority.validated()
        for value in series { _ = try value.validated() }
        let keys = series.map { "\($0.blindedID)::\($0.targetID)" }
        guard Set(keys).count == keys.count else {
            throw ProspectivePredictionError.duplicateForecastSeries
        }
        if let protocolValue {
            let protocolValue = try protocolValue.validated(against: freeze)
            guard protocolSHA256 == (try protocolValue.sha256()),
                  issuedAt <= protocolValue.predictionDeadline,
                  issuedAt < protocolValue.plannedExperimentStart,
                  experimentStartNotBefore == protocolValue.plannedExperimentStart else {
                throw ProspectivePredictionError.forecastProtocolMismatch
            }
            let blindIDs = Set(protocolValue.blindingCommitments.map(\.blindedID))
            let targetByID = Dictionary(uniqueKeysWithValues: protocolValue.targets.map { ($0.id, $0) })
            guard series.allSatisfy({ value in
                blindIDs.contains(value.blindedID) &&
                    targetByID[value.targetID]?.unit == value.unit
            }) else {
                throw ProspectivePredictionError.forecastProtocolMismatch
            }
            let expected = Set(
                blindIDs.flatMap { blindedID in
                    targetByID.keys.map { "\(blindedID)::\($0)" }
                }
            )
            guard Set(keys) == expected else {
                throw ProspectivePredictionError.incompleteForecastBundle
            }
            switch authority.kind {
            case .frozenModel:
                guard authority.identifier == "numitissue",
                      authority.modelFreezeSHA256 == protocolValue.modelFreezeSHA256 else {
                    throw ProspectivePredictionError.forecastProtocolMismatch
                }
            case .baseline:
                guard let baseline = protocolValue.baselines.first(where: {
                    $0.id == authority.identifier
                }),
                baseline.configurationSHA256 == authority.configurationSHA256 else {
                    throw ProspectivePredictionError.forecastProtocolMismatch
                }
            }
        }
        if let freeze, authority.kind == .frozenModel {
            guard try freeze.sha256() == authority.modelFreezeSHA256,
                  freeze.executionConfigurationSHA256 == authority.configurationSHA256 else {
                throw ProspectivePredictionError.forecastFreezeMismatch
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
