import Foundation

public struct ProspectiveObservationPoint: Sendable, Hashable, Codable {
    public var timeSeconds: Double
    public var value: Double
    public var standardError: Double?
    public var valid: Bool

    public init(
        timeSeconds: Double,
        value: Double,
        standardError: Double? = nil,
        valid: Bool = true
    ) {
        self.timeSeconds = timeSeconds
        self.value = value
        self.standardError = standardError
        self.valid = valid
    }

    public func validated() throws -> Self {
        guard timeSeconds.isFinite,
              timeSeconds >= 0,
              value.isFinite,
              standardError.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw ProspectivePredictionError.invalidObservationPoint
        }
        return self
    }
}

public struct ProspectiveObservationSeries: Sendable, Hashable, Codable {
    public var blindedID: String
    public var targetID: String
    public var replicateID: String
    public var unit: String
    public var points: [ProspectiveObservationPoint]
    public var exclusionCode: String?
    public var qualityFlags: [String]
    public var metadata: [String: String]

    public init(
        blindedID: String,
        targetID: String,
        replicateID: String,
        unit: String,
        points: [ProspectiveObservationPoint],
        exclusionCode: String? = nil,
        qualityFlags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.blindedID = blindedID
        self.targetID = targetID
        self.replicateID = replicateID
        self.unit = unit
        self.points = points
        self.exclusionCode = exclusionCode
        self.qualityFlags = qualityFlags
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(blindedID),
              ProspectiveIdentifier.isStable(targetID),
              ProspectiveIdentifier.isStable(replicateID),
              !unit.isEmpty,
              !points.isEmpty,
              points.count <= 10_000_000,
              exclusionCode.map(ProspectiveIdentifier.isStable) ?? true,
              qualityFlags.allSatisfy(ProspectiveIdentifier.isStable),
              Set(qualityFlags).count == qualityFlags.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidObservationSeries
        }
        for point in points { _ = try point.validated() }
        guard zip(points, points.dropFirst()).allSatisfy({
            $0.timeSeconds < $1.timeSeconds
        }) else {
            throw ProspectivePredictionError.invalidObservationSeries
        }
        return self
    }
}

public struct ProspectiveObservationBundle: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var id: UUID
    public var protocolSHA256: ScientificSHA256Digest
    public var acquiredAt: Date
    public var sealedAt: Date
    public var operatorBlinded: Bool
    public var instrumentCalibrationSHA256: [ScientificSHA256Digest]
    public var rawDataSHA256: [ScientificSHA256Digest]
    public var series: [ProspectiveObservationSeries]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: UUID = UUID(),
        protocolSHA256: ScientificSHA256Digest,
        acquiredAt: Date,
        sealedAt: Date,
        operatorBlinded: Bool,
        instrumentCalibrationSHA256: [ScientificSHA256Digest],
        rawDataSHA256: [ScientificSHA256Digest],
        series: [ProspectiveObservationSeries],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.protocolSHA256 = protocolSHA256
        self.acquiredAt = acquiredAt
        self.sealedAt = sealedAt
        self.operatorBlinded = operatorBlinded
        self.instrumentCalibrationSHA256 = instrumentCalibrationSHA256
        self.rawDataSHA256 = rawDataSHA256
        self.series = series
        self.metadata = metadata
    }

    public func validated(
        for protocolValue: ProspectiveExperimentProtocol? = nil
    ) throws -> Self {
        guard schemaVersion == 1,
              acquiredAt <= sealedAt,
              operatorBlinded,
              !instrumentCalibrationSHA256.isEmpty,
              !rawDataSHA256.isEmpty,
              Set(instrumentCalibrationSHA256).count == instrumentCalibrationSHA256.count,
              Set(rawDataSHA256).count == rawDataSHA256.count,
              !series.isEmpty,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidObservationBundle
        }
        for value in series { _ = try value.validated() }
        let keys = series.map {
            "\($0.blindedID)::\($0.targetID)::\($0.replicateID)"
        }
        guard Set(keys).count == keys.count else {
            throw ProspectivePredictionError.duplicateObservationSeries
        }
        if let protocolValue {
            let protocolValue = try protocolValue.validated()
            guard protocolSHA256 == (try protocolValue.sha256()),
                  acquiredAt >= protocolValue.plannedExperimentStart,
                  sealedAt >= acquiredAt else {
                throw ProspectivePredictionError.observationProtocolMismatch
            }
            let commitments = Dictionary(
                uniqueKeysWithValues: protocolValue.blindingCommitments.map {
                    ($0.blindedID, $0)
                }
            )
            let targets = Dictionary(
                uniqueKeysWithValues: protocolValue.targets.map { ($0.id, $0) }
            )
            let exclusions = Set(protocolValue.exclusions.map(\.code))
            guard series.allSatisfy({ value in
                commitments[value.blindedID] != nil &&
                    targets[value.targetID]?.unit == value.unit &&
                    (value.exclusionCode.map(exclusions.contains) ?? true)
            }) else {
                throw ProspectivePredictionError.observationProtocolMismatch
            }
            let replicateIDsByBlind = Dictionary(grouping: series, by: \.blindedID)
                .mapValues { Set($0.map(\.replicateID)) }
            var expectedSeriesKeys = Set<String>()
            for commitment in protocolValue.blindingCommitments {
                guard let replicateIDs = replicateIDsByBlind[commitment.blindedID],
                      replicateIDs.count == commitment.replicateCount else {
                    throw ProspectivePredictionError.observationReplicateMismatch(
                        commitment.blindedID
                    )
                }
                for replicateID in replicateIDs {
                    for targetID in targets.keys {
                        expectedSeriesKeys.insert(
                            "\(commitment.blindedID)::\(targetID)::\(replicateID)"
                        )
                    }
                }
            }
            guard Set(keys) == expectedSeriesKeys else {
                throw ProspectivePredictionError.incompleteObservationBundle
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
