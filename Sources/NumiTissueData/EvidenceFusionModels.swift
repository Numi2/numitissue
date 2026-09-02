import Foundation

public enum EvidenceFusionStrategy: String, Codable, Sendable, CaseIterable {
    case authoritativeSource
    case inverseVariance
    case robustHuber
    case weightedMedian
    case requireAgreement
}

public struct EvidenceFusionPolicy: Codable, Sendable, Equatable {
    public var strategy: EvidenceFusionStrategy
    public var sourcePriority: [BiologicalDataSource]
    public var minimumConfidence: Double
    public var minimumSupport: Int
    public var excludedFlags: Set<EvidenceQualityFlag>
    public var targetUnit: BiologicalUnit?
    public var allowCrossSpecies: Bool
    public var allowCrossSpecimen: Bool
    public var outlierZScore: Double
    public var huberDelta: Double
    public var maximumIterations: Int
    public var maximumConflictScore: Double
    public var agreementAbsoluteTolerance: Double
    public var agreementRelativeTolerance: Double
    public var fallbackRelativeStandardError: Double
    public var fallbackAbsoluteStandardError: Double

    public init(
        strategy: EvidenceFusionStrategy = .robustHuber,
        sourcePriority: [BiologicalDataSource] = [
            .microns,
            .allenCellTypes,
            .allenBrainCellAtlas,
            .blueBrain,
            .dandi,
            .h01,
            .modelDB,
            .neuroMorpho,
            .ebrains,
            .brainImageLibrary,
            .custom
        ],
        minimumConfidence: Double = 0.25,
        minimumSupport: Int = 1,
        excludedFlags: Set<EvidenceQualityFlag> = [
            .failedQualityControl,
            .superseded,
            .duplicated
        ],
        targetUnit: BiologicalUnit? = nil,
        allowCrossSpecies: Bool = false,
        allowCrossSpecimen: Bool = true,
        outlierZScore: Double = 4.5,
        huberDelta: Double = 1.5,
        maximumIterations: Int = 24,
        maximumConflictScore: Double = 0.85,
        agreementAbsoluteTolerance: Double = 0,
        agreementRelativeTolerance: Double = 0.05,
        fallbackRelativeStandardError: Double = 0.1,
        fallbackAbsoluteStandardError: Double = 1e-9
    ) {
        self.strategy = strategy
        self.sourcePriority = sourcePriority
        self.minimumConfidence = minimumConfidence
        self.minimumSupport = minimumSupport
        self.excludedFlags = excludedFlags
        self.targetUnit = targetUnit
        self.allowCrossSpecies = allowCrossSpecies
        self.allowCrossSpecimen = allowCrossSpecimen
        self.outlierZScore = outlierZScore
        self.huberDelta = huberDelta
        self.maximumIterations = maximumIterations
        self.maximumConflictScore = maximumConflictScore
        self.agreementAbsoluteTolerance = agreementAbsoluteTolerance
        self.agreementRelativeTolerance = agreementRelativeTolerance
        self.fallbackRelativeStandardError = fallbackRelativeStandardError
        self.fallbackAbsoluteStandardError = fallbackAbsoluteStandardError
    }

    public func validated() throws -> Self {
        guard minimumConfidence.isFinite,
              (0...1).contains(minimumConfidence),
              minimumSupport > 0,
              Set(sourcePriority).count == sourcePriority.count,
              outlierZScore.isFinite,
              outlierZScore > 0,
              huberDelta.isFinite,
              huberDelta > 0,
              maximumIterations > 0,
              maximumConflictScore.isFinite,
              (0...1).contains(maximumConflictScore),
              agreementAbsoluteTolerance.isFinite,
              agreementAbsoluteTolerance >= 0,
              agreementRelativeTolerance.isFinite,
              agreementRelativeTolerance >= 0,
              fallbackRelativeStandardError.isFinite,
              fallbackRelativeStandardError > 0,
              fallbackAbsoluteStandardError.isFinite,
              fallbackAbsoluteStandardError > 0 else {
            throw EvidenceFusionError.invalidPolicy
        }
        return self
    }

    public func sourceRank(_ source: BiologicalDataSource) -> Int {
        sourcePriority.firstIndex(of: source) ?? sourcePriority.count
    }
}

public enum EvidenceRejectionReason: String, Codable, Sendable, CaseIterable {
    case belowConfidence
    case excludedQuality
    case incompatibleEntity
    case incompatibleSpecies
    case incompatibleSpecimen
    case incompatibleUnit
    case lowerAuthority
    case outlier
    case unsupportedValue
}

public struct EvidenceRejection: Codable, Sendable, Equatable {
    public var recordID: String
    public var reason: EvidenceRejectionReason
    public var detail: String?

    public init(
        recordID: String,
        reason: EvidenceRejectionReason,
        detail: String? = nil
    ) {
        self.recordID = recordID
        self.reason = reason
        self.detail = detail
    }
}

public struct ResolvedUncertainty: Codable, Sendable, Equatable {
    public var standardError: [Double]
    public var lower95: [Double]
    public var upper95: [Double]
    public var betweenSourceStandardDeviation: [Double]
    public var effectiveSampleSize: Double
    public var categoricalEntropy: Double?

    public init(
        standardError: [Double] = [],
        lower95: [Double] = [],
        upper95: [Double] = [],
        betweenSourceStandardDeviation: [Double] = [],
        effectiveSampleSize: Double = 0,
        categoricalEntropy: Double? = nil
    ) {
        self.standardError = standardError
        self.lower95 = lower95
        self.upper95 = upper95
        self.betweenSourceStandardDeviation = betweenSourceStandardDeviation
        self.effectiveSampleSize = effectiveSampleSize
        self.categoricalEntropy = categoricalEntropy
    }
}

public struct ResolvedEvidence: Codable, Sendable, Equatable {
    public var entity: BiologicalEntityKey
    public var property: BiologicalProperty
    public var value: EvidenceValue
    public var unit: BiologicalUnit?
    public var confidence: Double
    public var conflictScore: Double
    public var uncertainty: ResolvedUncertainty
    public var supportingRecordIDs: [String]
    public var rejectedRecords: [EvidenceRejection]
    public var sourceDatasets: [String]

    public init(
        entity: BiologicalEntityKey,
        property: BiologicalProperty,
        value: EvidenceValue,
        unit: BiologicalUnit?,
        confidence: Double,
        conflictScore: Double,
        uncertainty: ResolvedUncertainty,
        supportingRecordIDs: [String],
        rejectedRecords: [EvidenceRejection],
        sourceDatasets: [String]
    ) {
        self.entity = entity
        self.property = property
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.conflictScore = conflictScore
        self.uncertainty = uncertainty
        self.supportingRecordIDs = supportingRecordIDs
        self.rejectedRecords = rejectedRecords
        self.sourceDatasets = sourceDatasets
    }
}

public struct EvidenceFusionReport: Codable, Sendable, Equatable {
    public var resolved: [ResolvedEvidence]
    public var unresolvedGroups: [EvidenceFusionFailure]

    public init(
        resolved: [ResolvedEvidence] = [],
        unresolvedGroups: [EvidenceFusionFailure] = []
    ) {
        self.resolved = resolved
        self.unresolvedGroups = unresolvedGroups
    }
}

public struct EvidenceFusionFailure: Codable, Sendable, Equatable {
    public var groupKey: String
    public var recordIDs: [String]
    public var reason: String

    public init(groupKey: String, recordIDs: [String], reason: String) {
        self.groupKey = groupKey
        self.recordIDs = recordIDs
        self.reason = reason
    }
}

public enum EvidenceFusionError: Error, Sendable, CustomStringConvertible {
    case invalidPolicy
    case emptyGroup
    case mixedEntities
    case mixedProperties
    case insufficientSupport(required: Int, actual: Int)
    case unsupportedNumericValue(String)
    case nonFiniteCandidate(String)
    case incompatibleUnit(expected: UnitDimension, actual: UnitDimension)
    case incompatibleVectorDimensions
    case requiredAgreementFailed(spread: Double, allowed: Double)
    case conflictExceeded(conflict: Double, maximum: Double)

    public var description: String {
        switch self {
        case .invalidPolicy:
            return "Evidence fusion policy is invalid."
        case .emptyGroup:
            return "Evidence fusion group is empty."
        case .mixedEntities:
            return "Evidence fusion group contains incompatible entities."
        case .mixedProperties:
            return "Evidence fusion group contains multiple properties."
        case .insufficientSupport(let required, let actual):
            return "Evidence fusion requires \(required) records but has \(actual)."
        case .unsupportedNumericValue(let record):
            return "Evidence record \(record) is not a supported scalar measurement."
        case .nonFiniteCandidate(let record):
            return "Evidence record \(record) produced a non-finite candidate."
        case .incompatibleUnit(let expected, let actual):
            return "Evidence fusion expects \(expected.rawValue), not \(actual.rawValue)."
        case .incompatibleVectorDimensions:
            return "Evidence vectors do not have compatible dimensions."
        case .requiredAgreementFailed(let spread, let allowed):
            return "Evidence spread \(spread) exceeds agreement tolerance \(allowed)."
        case .conflictExceeded(let conflict, let maximum):
            return "Evidence conflict \(conflict) exceeds maximum \(maximum)."
        }
    }
}
