import Foundation

public enum DatasetRepresentation: String, Codable, Sendable, CaseIterable, Hashable {
    case annotations
    case cellMetadata
    case connectivityEdges
    case electrophysiologyFeatures
    case electrophysiologyTraces
    case expressionMatrix
    case morphologySkeleton
    case segmentationLabels
    case spatialCoordinates
    case surfaceMesh
    case synapseLocations
    case tissueImage
    case vasculatureGraph
    case voxelField
}

public enum OntologyMatchMode: String, Codable, Sendable, CaseIterable {
    case exact
    case exactOrMappedEquivalent
    case includeDescendants
    case includeAncestors
}

public enum DatasetSamplingStrategy: String, Codable, Sendable, CaseIterable {
    case all
    case deterministicReservoir
    case stratified
    case highestConfidence
    case spatiallyUniform
}

public struct DatasetSamplingPolicy: Codable, Sendable, Equatable {
    public var strategy: DatasetSamplingStrategy
    public var targetCount: UInt64?
    public var strataPropertyPaths: [String]
    public var withReplacement: Bool
    public var deterministicSeed: UInt64

    public init(
        strategy: DatasetSamplingStrategy = .all,
        targetCount: UInt64? = nil,
        strataPropertyPaths: [String] = [],
        withReplacement: Bool = false,
        deterministicSeed: UInt64 = 0
    ) {
        self.strategy = strategy
        self.targetCount = targetCount
        self.strataPropertyPaths = strataPropertyPaths
        self.withReplacement = withReplacement
        self.deterministicSeed = deterministicSeed
    }

    public func validated() throws -> Self {
        guard Set(strataPropertyPaths).count == strataPropertyPaths.count,
              strataPropertyPaths.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetSelectionError.invalidSamplingPolicy
        }
        switch strategy {
        case .all:
            guard targetCount == nil,
                  strataPropertyPaths.isEmpty,
                  !withReplacement else {
                throw DatasetSelectionError.invalidSamplingPolicy
            }
        case .stratified:
            guard let targetCount,
                  targetCount > 0,
                  !strataPropertyPaths.isEmpty else {
                throw DatasetSelectionError.invalidSamplingPolicy
            }
        case .deterministicReservoir, .highestConfidence, .spatiallyUniform:
            guard let targetCount, targetCount > 0 else {
                throw DatasetSelectionError.invalidSamplingPolicy
            }
        }
        return self
    }
}

public struct DatasetSpatialWindow: Codable, Sendable, Equatable {
    public var bounds: CoordinateBounds
    public var includeIntersectingGeometry: Bool
    public var padding: UnitValue?

    public init(
        bounds: CoordinateBounds,
        includeIntersectingGeometry: Bool = true,
        padding: UnitValue? = nil
    ) {
        self.bounds = bounds
        self.includeIntersectingGeometry = includeIntersectingGeometry
        self.padding = padding
    }

    public func validated() throws -> Self {
        _ = try bounds.validated()
        if let padding {
            guard padding.unit.dimension == .length,
                  padding.value.isFinite,
                  padding.value >= 0 else {
                throw DatasetSelectionError.invalidSpatialWindow(bounds.frameID)
            }
        }
        return self
    }
}

public struct DatasetTemporalWindow: Codable, Sendable, Equatable {
    public var start: UnitValue
    public var end: UnitValue
    public var reference: String

    public init(start: UnitValue, end: UnitValue, reference: String = "recording-start") {
        self.start = start
        self.end = end
        self.reference = reference
    }

    public func validated() throws -> Self {
        guard start.unit.dimension == .time,
              end.unit.dimension == .time,
              !reference.isEmpty else {
            throw DatasetSelectionError.invalidTemporalWindow
        }
        let startSeconds = try start.converted(to: .second).value
        let endSeconds = try end.converted(to: .second).value
        guard startSeconds >= 0, startSeconds <= endSeconds else {
            throw DatasetSelectionError.invalidTemporalWindow
        }
        return self
    }
}

public struct DatasetSelectionBudget: Codable, Sendable, Equatable {
    public var maximumEntities: UInt64
    public var maximumCells: UInt64
    public var maximumSynapses: UInt64
    public var maximumAssets: UInt64
    public var maximumTransferredBytes: UInt64
    public var maximumDecodedBytes: UInt64
    public var maximumConcurrentRequests: Int

    public init(
        maximumEntities: UInt64 = 5_000_000,
        maximumCells: UInt64 = 1_000_000,
        maximumSynapses: UInt64 = 100_000_000,
        maximumAssets: UInt64 = 100_000,
        maximumTransferredBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        maximumDecodedBytes: UInt64 = 256 * 1_024 * 1_024 * 1_024,
        maximumConcurrentRequests: Int = 8
    ) {
        self.maximumEntities = maximumEntities
        self.maximumCells = maximumCells
        self.maximumSynapses = maximumSynapses
        self.maximumAssets = maximumAssets
        self.maximumTransferredBytes = maximumTransferredBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumConcurrentRequests = maximumConcurrentRequests
    }

    public func validated() throws -> Self {
        guard maximumEntities > 0,
              maximumCells > 0,
              maximumSynapses > 0,
              maximumAssets > 0,
              maximumTransferredBytes > 0,
              maximumDecodedBytes > 0,
              maximumConcurrentRequests > 0,
              maximumConcurrentRequests <= 256 else {
            throw DatasetSelectionError.invalidBudget
        }
        return self
    }
}

public struct DatasetSelection: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var species: [OntologyTerm]
    public var brainRegions: [OntologyTerm]
    public var cellTypes: [OntologyTerm]
    public var specimenIDs: [String]
    public var entityIdentifiers: [String]
    public var modalities: Set<BiologicalDataModality>
    public var representations: Set<DatasetRepresentation>
    public var spatialWindows: [DatasetSpatialWindow]
    public var temporalWindow: DatasetTemporalWindow?
    public var ontologyMatchMode: OntologyMatchMode
    public var minimumConfidence: Double
    public var requireCompleteGeometry: Bool
    public var includeRestrictedAssets: Bool
    public var sampling: DatasetSamplingPolicy
    public var budget: DatasetSelectionBudget
    public var metadataPredicates: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        species: [OntologyTerm] = [],
        brainRegions: [OntologyTerm] = [],
        cellTypes: [OntologyTerm] = [],
        specimenIDs: [String] = [],
        entityIdentifiers: [String] = [],
        modalities: Set<BiologicalDataModality>,
        representations: Set<DatasetRepresentation>,
        spatialWindows: [DatasetSpatialWindow] = [],
        temporalWindow: DatasetTemporalWindow? = nil,
        ontologyMatchMode: OntologyMatchMode = .exactOrMappedEquivalent,
        minimumConfidence: Double = 0,
        requireCompleteGeometry: Bool = false,
        includeRestrictedAssets: Bool = false,
        sampling: DatasetSamplingPolicy = DatasetSamplingPolicy(),
        budget: DatasetSelectionBudget = DatasetSelectionBudget(),
        metadataPredicates: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.species = species
        self.brainRegions = brainRegions
        self.cellTypes = cellTypes
        self.specimenIDs = specimenIDs
        self.entityIdentifiers = entityIdentifiers
        self.modalities = modalities
        self.representations = representations
        self.spatialWindows = spatialWindows
        self.temporalWindow = temporalWindow
        self.ontologyMatchMode = ontologyMatchMode
        self.minimumConfidence = minimumConfidence
        self.requireCompleteGeometry = requireCompleteGeometry
        self.includeRestrictedAssets = includeRestrictedAssets
        self.sampling = sampling
        self.budget = budget
        self.metadataPredicates = metadataPredicates
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw DatasetSelectionError.unsupportedSchema(schemaVersion)
        }
        guard !modalities.isEmpty,
              !representations.isEmpty,
              minimumConfidence.isFinite,
              (0...1).contains(minimumConfidence),
              Set(species.map(\.curie)).count == species.count,
              Set(brainRegions.map(\.curie)).count == brainRegions.count,
              Set(cellTypes.map(\.curie)).count == cellTypes.count,
              Set(specimenIDs).count == specimenIDs.count,
              Set(entityIdentifiers).count == entityIdentifiers.count,
              specimenIDs.allSatisfy({ !$0.isEmpty }),
              entityIdentifiers.allSatisfy({ !$0.isEmpty }),
              metadataPredicates.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetSelectionError.invalidSelection
        }
        for term in species + brainRegions + cellTypes {
            _ = try term.validated()
        }
        for window in spatialWindows { _ = try window.validated() }
        if let temporalWindow { _ = try temporalWindow.validated() }
        _ = try sampling.validated()
        _ = try budget.validated()
        return self
    }

    public var isSpatiallyBounded: Bool { !spatialWindows.isEmpty }
    public var isEntityBounded: Bool {
        !entityIdentifiers.isEmpty || sampling.targetCount != nil
    }
}

public enum DatasetSelectionError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidSamplingPolicy
    case invalidSpatialWindow(String)
    case invalidTemporalWindow
    case invalidBudget
    case invalidSelection

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported dataset selection schema \(version)."
        case .invalidSamplingPolicy:
            return "Dataset sampling policy is invalid."
        case .invalidSpatialWindow(let frame):
            return "Dataset spatial window in frame \(frame) is invalid."
        case .invalidTemporalWindow:
            return "Dataset temporal window is invalid."
        case .invalidBudget:
            return "Dataset selection budget is invalid."
        case .invalidSelection:
            return "Dataset selection is invalid."
        }
    }
}
