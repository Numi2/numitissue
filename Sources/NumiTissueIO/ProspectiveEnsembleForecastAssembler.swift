import Foundation

public struct ProspectiveEnsembleMemberSeries: Sendable, Hashable, Codable {
    public var memberID: String
    public var randomSeed: UInt64
    public var blindedID: String
    public var targetID: String
    public var unit: String
    public var points: [ProspectiveWaveformPoint]
    public var sourceArtifactSHA256: [ScientificSHA256Digest]
    public var metadata: [String: String]

    public init(
        memberID: String,
        randomSeed: UInt64,
        blindedID: String,
        targetID: String,
        unit: String,
        points: [ProspectiveWaveformPoint],
        sourceArtifactSHA256: [ScientificSHA256Digest] = [],
        metadata: [String: String] = [:]
    ) {
        self.memberID = memberID
        self.randomSeed = randomSeed
        self.blindedID = blindedID
        self.targetID = targetID
        self.unit = unit
        self.points = points
        self.sourceArtifactSHA256 = sourceArtifactSHA256
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(memberID),
              randomSeed != 0,
              ProspectiveIdentifier.isStable(blindedID),
              ProspectiveIdentifier.isStable(targetID),
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !points.isEmpty,
              points.count <= 1_000_000,
              Set(sourceArtifactSHA256).count == sourceArtifactSHA256.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveEnsembleForecastError.invalidMemberSeries
        }
        for point in points { _ = try point.validated() }
        guard zip(points, points.dropFirst()).allSatisfy({
            $0.timeSeconds < $1.timeSeconds
        }) else {
            throw ProspectiveEnsembleForecastError.invalidMemberSeries
        }
        return self
    }
}

public struct ProspectiveEnsembleForecastConfiguration: Sendable, Hashable, Codable {
    public var quantileProbabilities: [Double]
    public var minimumMemberCount: Int
    public var maximumMemberCount: Int
    public var requireIdenticalMemberSetAcrossSeries: Bool
    public var metadata: [String: String]

    public init(
        quantileProbabilities: [Double] = [
            0.025, 0.05, 0.10, 0.25, 0.50,
            0.75, 0.90, 0.95, 0.975
        ],
        minimumMemberCount: Int = 32,
        maximumMemberCount: Int = 1_000_000,
        requireIdenticalMemberSetAcrossSeries: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.quantileProbabilities = quantileProbabilities
        self.minimumMemberCount = minimumMemberCount
        self.maximumMemberCount = maximumMemberCount
        self.requireIdenticalMemberSetAcrossSeries = requireIdenticalMemberSetAcrossSeries
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard quantileProbabilities.count >= 3,
              quantileProbabilities.count <= 1_001,
              quantileProbabilities.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
              zip(quantileProbabilities, quantileProbabilities.dropFirst()).allSatisfy({ $0 < $1 }),
              quantileProbabilities.contains(where: { abs($0 - 0.5) <= 1e-12 }),
              minimumMemberCount >= 3,
              maximumMemberCount >= minimumMemberCount,
              maximumMemberCount <= 1_000_000,
              requireIdenticalMemberSetAcrossSeries,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveEnsembleForecastError.invalidConfiguration
        }
        let required = Set(ProspectivePredictionScorer.calibrationLevels.flatMap { level in
            let alpha = 1 - level
            return [alpha / 2, 1 - alpha / 2]
        } + [0.5])
        guard required.allSatisfy({ probability in
            quantileProbabilities.contains(where: {
                abs($0 - probability) <= 1e-12
            })
        }) else {
            throw ProspectiveEnsembleForecastError.missingCalibrationQuantile
        }
        return self
    }
}

public enum ProspectiveEnsembleForecastAssembler {
    public static func assemble(
        protocol sourceProtocol: ProspectiveExperimentProtocol,
        freeze sourceFreeze: ProspectiveModelFreezeCertificate? = nil,
        authority sourceAuthority: ProspectiveForecastAuthority,
        issuedAt: Date,
        memberSeries sourceSeries: [ProspectiveEnsembleMemberSeries],
        supportingArtifactSHA256 sourceSupporting: [ScientificSHA256Digest],
        configuration sourceConfiguration: ProspectiveEnsembleForecastConfiguration = .init(),
        metadata: [String: String] = [:]
    ) throws -> ProspectiveForecastBundle {
        let protocolValue = try sourceProtocol.validated(against: sourceFreeze)
        let authority = try sourceAuthority.validated()
        let configuration = try sourceConfiguration.validated()
        guard issuedAt <= protocolValue.predictionDeadline,
              issuedAt < protocolValue.plannedExperimentStart,
              !sourceSeries.isEmpty,
              !sourceSupporting.isEmpty,
              Set(sourceSupporting).count == sourceSupporting.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveEnsembleForecastError.invalidRequest
        }
        let series = try sourceSeries.map { try $0.validated() }
        let seriesKeys = series.map {
            "\($0.memberID)::\($0.blindedID)::\($0.targetID)"
        }
        guard Set(seriesKeys).count == seriesKeys.count else {
            throw ProspectiveEnsembleForecastError.duplicateMemberSeries
        }
        let targets = Dictionary(
            uniqueKeysWithValues: protocolValue.targets.map { ($0.id, $0) }
        )
        let blindedIDs = Set(protocolValue.blindingCommitments.map(\.blindedID))
        guard series.allSatisfy({ value in
            blindedIDs.contains(value.blindedID) &&
                targets[value.targetID]?.unit == value.unit
        }) else {
            throw ProspectiveEnsembleForecastError.protocolMismatch
        }

        let memberIDs = Set(series.map(\.memberID))
        let randomSeedByMember = try uniqueSeedMap(series)
        guard memberIDs.count >= configuration.minimumMemberCount,
              memberIDs.count <= configuration.maximumMemberCount else {
            throw ProspectiveEnsembleForecastError.memberCountOutOfRange
        }
        let expectedForecastKeys = Set(blindedIDs.flatMap { blindedID in
            targets.keys.map { "\(blindedID)::\($0)" }
        })
        let grouped = Dictionary(grouping: series) {
            "\($0.blindedID)::\($0.targetID)"
        }
        guard Set(grouped.keys) == expectedForecastKeys else {
            throw ProspectiveEnsembleForecastError.incompleteEnsemble
        }
        for values in grouped.values {
            guard Set(values.map(\.memberID)) == memberIDs else {
                throw ProspectiveEnsembleForecastError.inconsistentMemberSet
            }
        }

        var forecastSeries: [ProspectiveForecastSeries] = []
        forecastSeries.reserveCapacity(expectedForecastKeys.count)
        for key in expectedForecastKeys.sorted() {
            guard let values = grouped[key],
                  let first = values.first,
                  let target = targets[first.targetID] else {
                throw ProspectiveEnsembleForecastError.incompleteEnsemble
            }
            for value in values {
                guard value.points.map(\.timeSeconds) == target.timeGridSeconds else {
                    throw ProspectiveEnsembleForecastError.timeGridMismatch(key)
                }
            }
            let orderedMembers = values.sorted { $0.memberID < $1.memberID }
            let points = try target.timeGridSeconds.indices.map { index in
                let samples = orderedMembers.map { $0.points[index].value }.sorted()
                let quantiles = configuration.quantileProbabilities.map { probability in
                    ProspectiveQuantile(
                        probability: probability,
                        value: empiricalQuantile(samples, probability: probability)
                    )
                }
                return try ProspectiveForecastPoint(
                    timeSeconds: target.timeGridSeconds[index],
                    quantiles: quantiles
                ).validated()
            }
            forecastSeries.append(try ProspectiveForecastSeries(
                blindedID: first.blindedID,
                targetID: first.targetID,
                unit: first.unit,
                points: points,
                metadata: [
                    "ensemble-members": String(memberIDs.count),
                    "quantile-method": "linear-order-statistic-r7"
                ]
            ).validated())
        }

        let memberIdentity = series
            .sorted {
                ($0.memberID, $0.blindedID, $0.targetID) <
                    ($1.memberID, $1.blindedID, $1.targetID)
            }
            .map { value in
                [
                    value.memberID,
                    value.blindedID,
                    value.targetID,
                    String(value.randomSeed),
                    value.sourceArtifactSHA256.map(\.hexadecimal).sorted().joined(separator: ",")
                ].joined(separator: ":")
            }
            .joined(separator: "\n")
        let memberSetDigest = ScientificSHA256Digest(data: Data(memberIdentity.utf8))
        let allSupporting = Array(Set(
            sourceSupporting + series.flatMap(\.sourceArtifactSHA256)
        )).sorted { $0.hexadecimal < $1.hexadecimal }
        let bundle = ProspectiveForecastBundle(
            protocolSHA256: try protocolValue.sha256(),
            authority: authority,
            issuedAt: issuedAt,
            experimentStartNotBefore: protocolValue.plannedExperimentStart,
            series: forecastSeries.sorted {
                ($0.blindedID, $0.targetID) < ($1.blindedID, $1.targetID)
            },
            randomSeeds: memberIDs.sorted().compactMap { randomSeedByMember[$0] },
            supportingArtifactSHA256: allSupporting,
            generatedWithoutProspectiveObservations: true,
            postFreezeMutationDetected: false,
            metadata: metadata.merging(configuration.metadata, uniquingKeysWith: { explicit, _ in explicit }).merging([
                "assembler": "empirical-ensemble-quantiles-v1",
                "ensemble-member-count": String(memberIDs.count),
                "ensemble-member-set-sha256": memberSetDigest.hexadecimal
            ], uniquingKeysWith: { explicit, _ in explicit })
        )
        return try bundle.validated(for: protocolValue, freeze: sourceFreeze)
    }

    static func uniqueSeedMap(
        _ series: [ProspectiveEnsembleMemberSeries]
    ) throws -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        var seedOwners: [UInt64: String] = [:]
        for value in series {
            if let prior = result[value.memberID], prior != value.randomSeed {
                throw ProspectiveEnsembleForecastError.inconsistentMemberSeed(value.memberID)
            }
            if let priorOwner = seedOwners[value.randomSeed], priorOwner != value.memberID {
                throw ProspectiveEnsembleForecastError.duplicateRandomSeed
            }
            result[value.memberID] = value.randomSeed
            seedOwners[value.randomSeed] = value.memberID
        }
        return result
    }

    static func empiricalQuantile(
        _ sorted: [Double],
        probability: Double
    ) -> Double {
        guard sorted.count > 1 else { return sorted[0] }
        let position = probability * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + fraction * (sorted[upper] - sorted[lower])
    }
}

public enum ProspectiveEnsembleForecastError: Error, Sendable, CustomStringConvertible {
    case invalidMemberSeries
    case invalidConfiguration
    case missingCalibrationQuantile
    case invalidRequest
    case duplicateMemberSeries
    case protocolMismatch
    case memberCountOutOfRange
    case incompleteEnsemble
    case inconsistentMemberSet
    case inconsistentMemberSeed(String)
    case duplicateRandomSeed
    case timeGridMismatch(String)

    public var description: String {
        switch self {
        case .invalidMemberSeries:
            return "Prospective ensemble member series is invalid."
        case .invalidConfiguration:
            return "Prospective ensemble forecast configuration is invalid."
        case .missingCalibrationQuantile:
            return "Prospective quantile grid does not support every calibration interval."
        case .invalidRequest:
            return "Prospective ensemble forecast request is invalid."
        case .duplicateMemberSeries:
            return "Prospective ensemble contains a duplicate member, condition and target series."
        case .protocolMismatch:
            return "Prospective ensemble series does not match a preregistered target or blinded condition."
        case .memberCountOutOfRange:
            return "Prospective ensemble member count is outside the configured bounds."
        case .incompleteEnsemble:
            return "Prospective ensemble does not cover every member, blinded condition and target."
        case .inconsistentMemberSet:
            return "Prospective ensemble uses different member sets across target series."
        case .inconsistentMemberSeed(let id):
            return "Prospective ensemble member \(id) has inconsistent random seeds."
        case .duplicateRandomSeed:
            return "Different prospective ensemble members share a random seed."
        case .timeGridMismatch(let key):
            return "Prospective ensemble series \(key) does not match its preregistered time grid."
        }
    }
}
