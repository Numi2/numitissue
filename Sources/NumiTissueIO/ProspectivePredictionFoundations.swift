import Foundation

public enum ProspectiveStudyDomain: String, Sendable, Hashable, Codable, CaseIterable {
    case intermittentOxygen = "intermittent-oxygen"
    case receptorChannelBlocker = "receptor-channel-blocker"
    case injurySpreadingDepolarization = "injury-spreading-depolarization"
    case developmentalOrganoidTrajectory = "developmental-organoid-trajectory"
}

public enum ProspectiveTargetKind: String, Sendable, Hashable, Codable, CaseIterable {
    case continuousTimeSeries = "continuous-time-series"
    case scalar
    case eventTime = "event-time"
    case probability
}

public enum ProspectiveTargetTransform: String, Sendable, Hashable, Codable, CaseIterable {
    case identity
    case logarithmic
    case logit
    case normalizedToBaseline = "normalized-to-baseline"

    public func apply(_ value: Double) throws -> Double {
        guard value.isFinite else { throw ProspectivePredictionError.nonFiniteValue }
        switch self {
        case .identity, .normalizedToBaseline:
            return value
        case .logarithmic:
            guard value > 0 else { throw ProspectivePredictionError.invalidTransformedValue }
            return log(value)
        case .logit:
            guard value > 0, value < 1 else { throw ProspectivePredictionError.invalidTransformedValue }
            return log(value / (1 - value))
        }
    }
}

public enum ProspectiveForecastAlignment: String, Sendable, Hashable, Codable, CaseIterable {
    case exact
    case nearest
    case linear
}

public struct ProspectiveTimeWindow: Sendable, Hashable, Codable {
    public var startSeconds: Double
    public var endSeconds: Double

    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public func validated() throws -> Self {
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= 0,
              endSeconds >= startSeconds else {
            throw ProspectivePredictionError.invalidTimeWindow
        }
        return self
    }

    public func contains(_ value: Double, tolerance: Double = 0) -> Bool {
        value >= startSeconds - tolerance && value <= endSeconds + tolerance
    }
}

public struct ProspectivePredictionTarget: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var kind: ProspectiveTargetKind
    public var quantity: String
    public var unit: String
    public var region: String?
    public var depthMicrometers: Double?
    public var timeGridSeconds: [Double]
    public var alignment: ProspectiveForecastAlignment
    public var alignmentToleranceSeconds: Double
    public var transform: ProspectiveTargetTransform
    public var primary: Bool
    public var weight: Double
    public var measurementStandardError: Double?
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        kind: ProspectiveTargetKind,
        quantity: String,
        unit: String,
        region: String? = nil,
        depthMicrometers: Double? = nil,
        timeGridSeconds: [Double],
        alignment: ProspectiveForecastAlignment = .linear,
        alignmentToleranceSeconds: Double = 0.5,
        transform: ProspectiveTargetTransform = .identity,
        primary: Bool = false,
        weight: Double = 1,
        measurementStandardError: Double? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.quantity = quantity
        self.unit = unit
        self.region = region
        self.depthMicrometers = depthMicrometers
        self.timeGridSeconds = timeGridSeconds
        self.alignment = alignment
        self.alignmentToleranceSeconds = alignmentToleranceSeconds
        self.transform = transform
        self.primary = primary
        self.weight = weight
        self.measurementStandardError = measurementStandardError
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(id),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              region?.isEmpty != true,
              depthMicrometers.map({ $0.isFinite && $0 >= 0 }) ?? true,
              alignmentToleranceSeconds.isFinite,
              alignmentToleranceSeconds >= 0,
              weight.isFinite,
              weight > 0,
              measurementStandardError.map({ $0.isFinite && $0 > 0 }) ?? true,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidTarget(id)
        }
        guard !timeGridSeconds.isEmpty,
              timeGridSeconds.count <= 1_000_000,
              timeGridSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timeGridSeconds, timeGridSeconds.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw ProspectivePredictionError.invalidTargetTimeGrid(id)
        }
        switch kind {
        case .scalar, .eventTime, .probability:
            guard timeGridSeconds.count == 1 else {
                throw ProspectivePredictionError.invalidTargetTimeGrid(id)
            }
        case .continuousTimeSeries:
            break
        }
        return self
    }
}

public struct ProspectiveWaveformPoint: Sendable, Hashable, Codable {
    public var timeSeconds: Double
    public var value: Double

    public init(timeSeconds: Double, value: Double) {
        self.timeSeconds = timeSeconds
        self.value = value
    }

    public func validated() throws -> Self {
        guard timeSeconds.isFinite,
              timeSeconds >= 0,
              value.isFinite else {
            throw ProspectivePredictionError.invalidWaveform
        }
        return self
    }
}

public enum ProspectiveWaveformInterpolation: String, Sendable, Hashable, Codable, CaseIterable {
    case step
    case linear
}

public struct ProspectiveExperimentalCondition: Sendable, Hashable, Codable {
    public var id: String
    public var title: String
    public var interventionKind: String
    public var waveformQuantity: String?
    public var waveformUnit: String?
    public var waveformInterpolation: ProspectiveWaveformInterpolation?
    public var waveform: [ProspectiveWaveformPoint]
    public var parameters: [String: Double]
    public var metadata: [String: String]

    public init(
        id: String,
        title: String,
        interventionKind: String,
        waveformQuantity: String? = nil,
        waveformUnit: String? = nil,
        waveformInterpolation: ProspectiveWaveformInterpolation? = nil,
        waveform: [ProspectiveWaveformPoint] = [],
        parameters: [String: Double] = [:],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.interventionKind = interventionKind
        self.waveformQuantity = waveformQuantity
        self.waveformUnit = waveformUnit
        self.waveformInterpolation = waveformInterpolation
        self.waveform = waveform
        self.parameters = parameters
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(id),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !interventionKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parameters.keys.allSatisfy(ProspectiveIdentifier.isStable),
              parameters.values.allSatisfy(\.isFinite),
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidCondition(id)
        }
        if waveform.isEmpty {
            guard waveformQuantity == nil,
                  waveformUnit == nil,
                  waveformInterpolation == nil else {
                throw ProspectivePredictionError.invalidWaveform
            }
        } else {
            guard waveformQuantity?.isEmpty == false,
                  waveformUnit?.isEmpty == false,
                  waveformInterpolation != nil,
                  waveform.count <= 1_000_000 else {
                throw ProspectivePredictionError.invalidWaveform
            }
            for point in waveform { _ = try point.validated() }
            guard zip(waveform, waveform.dropFirst()).allSatisfy({
                $0.timeSeconds < $1.timeSeconds
            }) else {
                throw ProspectivePredictionError.invalidWaveform
            }
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

public struct ProspectiveBlindingCommitment: Sendable, Hashable, Codable {
    public var blindedID: String
    public var conditionCommitmentSHA256: ScientificSHA256Digest
    public var replicateCount: Int
    public var strata: [String: String]

    public init(
        blindedID: String,
        conditionCommitmentSHA256: ScientificSHA256Digest,
        replicateCount: Int,
        strata: [String: String] = [:]
    ) {
        self.blindedID = blindedID
        self.conditionCommitmentSHA256 = conditionCommitmentSHA256
        self.replicateCount = replicateCount
        self.strata = strata
    }

    public func validated() throws -> Self {
        guard ProspectiveIdentifier.isStable(blindedID),
              replicateCount > 0,
              replicateCount <= 1_000_000,
              strata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey),
              strata.values.allSatisfy({ !$0.isEmpty }) else {
            throw ProspectivePredictionError.invalidBlindingCommitment(blindedID)
        }
        return self
    }
}

public struct ProspectiveBlindingKeyEntry: Sendable, Hashable, Codable {
    public var blindedID: String
    public var condition: ProspectiveExperimentalCondition
    public var nonce: String

    public init(
        blindedID: String,
        condition: ProspectiveExperimentalCondition,
        nonce: String
    ) {
        self.blindedID = blindedID
        self.condition = condition
        self.nonce = nonce
    }

    public func commitment(studyID: UUID) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var studyID: UUID
            var blindedID: String
            var condition: ProspectiveExperimentalCondition
            var nonce: String
        }
        _ = try condition.validated()
        guard ProspectiveIdentifier.isStable(blindedID),
              nonce.utf8.count >= 32,
              nonce.utf8.count <= 4_096 else {
            throw ProspectivePredictionError.invalidBlindingKeyEntry(blindedID)
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(Payload(
                studyID: studyID,
                blindedID: blindedID,
                condition: condition,
                nonce: nonce
            ))
        )
    }
}

public struct ProspectiveBlindingKey: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var studyID: UUID
    public var createdAt: Date
    public var custodian: String
    public var entries: [ProspectiveBlindingKeyEntry]
    public var commitmentSetSHA256: ScientificSHA256Digest
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        studyID: UUID,
        createdAt: Date,
        custodian: String,
        entries: [ProspectiveBlindingKeyEntry],
        commitmentSetSHA256: ScientificSHA256Digest,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.studyID = studyID
        self.createdAt = createdAt
        self.custodian = custodian
        self.entries = entries
        self.commitmentSetSHA256 = commitmentSetSHA256
        self.metadata = metadata
    }

    public func validated(
        commitments: [ProspectiveBlindingCommitment]
    ) throws -> Self {
        guard schemaVersion == 1,
              !custodian.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !entries.isEmpty,
              entries.count == commitments.count,
              Set(entries.map(\.blindedID)).count == entries.count,
              Set(entries.map(\.condition.id)).count == entries.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectivePredictionError.invalidBlindingKey
        }
        let commitmentByBlindID = Dictionary(
            uniqueKeysWithValues: commitments.map { ($0.blindedID, $0) }
        )
        for entry in entries {
            guard let expected = commitmentByBlindID[entry.blindedID],
                  try entry.commitment(studyID: studyID) == expected.conditionCommitmentSHA256 else {
                throw ProspectivePredictionError.blindingCommitmentMismatch(entry.blindedID)
            }
        }
        let expectedSet = try Self.commitmentSetDigest(commitments)
        guard expectedSet == commitmentSetSHA256 else {
            throw ProspectivePredictionError.blindingSetMismatch
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(self)
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }

    public static func commitmentSetDigest(
        _ commitments: [ProspectiveBlindingCommitment]
    ) throws -> ScientificSHA256Digest {
        let values = try commitments
            .map { try $0.validated() }
            .sorted { $0.blindedID < $1.blindedID }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(values)
        )
    }
}

public enum ProspectiveBlindingFactory {
    public static func make(
        studyID: UUID,
        createdAt: Date,
        custodian: String,
        conditions: [ProspectiveExperimentalCondition],
        blindedIDByConditionID: [String: String],
        nonceByConditionID: [String: String],
        replicateCountByConditionID: [String: Int],
        strataByConditionID: [String: [String: String]] = [:],
        metadata: [String: String] = [:]
    ) throws -> (
        commitments: [ProspectiveBlindingCommitment],
        key: ProspectiveBlindingKey
    ) {
        guard !conditions.isEmpty,
              Set(conditions.map(\.id)).count == conditions.count,
              Set(blindedIDByConditionID.values).count == conditions.count else {
            throw ProspectivePredictionError.invalidBlindingRequest
        }
        var commitments: [ProspectiveBlindingCommitment] = []
        var entries: [ProspectiveBlindingKeyEntry] = []
        for condition in conditions.sorted(by: { $0.id < $1.id }) {
            _ = try condition.validated()
            guard let blindedID = blindedIDByConditionID[condition.id],
                  let nonce = nonceByConditionID[condition.id],
                  let replicateCount = replicateCountByConditionID[condition.id] else {
                throw ProspectivePredictionError.invalidBlindingRequest
            }
            let entry = ProspectiveBlindingKeyEntry(
                blindedID: blindedID,
                condition: condition,
                nonce: nonce
            )
            entries.append(entry)
            commitments.append(ProspectiveBlindingCommitment(
                blindedID: blindedID,
                conditionCommitmentSHA256: try entry.commitment(studyID: studyID),
                replicateCount: replicateCount,
                strata: strataByConditionID[condition.id] ?? [:]
            ))
        }
        commitments.sort { $0.blindedID < $1.blindedID }
        entries.sort { $0.blindedID < $1.blindedID }
        let digest = try ProspectiveBlindingKey.commitmentSetDigest(commitments)
        let key = ProspectiveBlindingKey(
            studyID: studyID,
            createdAt: createdAt,
            custodian: custodian,
            entries: entries,
            commitmentSetSHA256: digest,
            metadata: metadata
        )
        _ = try key.validated(commitments: commitments)
        return (commitments, key)
    }
}
