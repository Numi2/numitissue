import Foundation

public enum BiologicalEntityKind: String, Codable, Sendable, CaseIterable, Hashable {
    case cell
    case cellType
    case compartment
    case connectionClass
    case experiment
    case extracellularField
    case ionChannel
    case molecularMechanism
    case morphology
    case population
    case specimen
    case synapse
    case tissueRegion
    case tissueVolume
    case vasculature
}

public struct BiologicalEntityKey: Codable, Sendable, Hashable, Comparable {
    public var kind: BiologicalEntityKind
    public var identifier: String
    public var datasetReference: String?
    public var specimenID: String?
    public var taxonomy: CellTaxonomyIdentity?
    public var coordinate: [Double]?
    public var coordinateFrameID: String?

    public init(
        kind: BiologicalEntityKind,
        identifier: String,
        datasetReference: String? = nil,
        specimenID: String? = nil,
        taxonomy: CellTaxonomyIdentity? = nil,
        coordinate: [Double]? = nil,
        coordinateFrameID: String? = nil
    ) {
        self.kind = kind
        self.identifier = identifier
        self.datasetReference = datasetReference
        self.specimenID = specimenID
        self.taxonomy = taxonomy
        self.coordinate = coordinate
        self.coordinateFrameID = coordinateFrameID
    }

    public var semanticKey: String {
        let coordinateKey = coordinate?
            .map { String($0.bitPattern, radix: 16) }
            .joined(separator: ",") ?? "-"
        return [
            kind.rawValue,
            identifier,
            specimenID ?? "-",
            taxonomy?.species.curie ?? "-",
            taxonomy?.cellClass?.curie ?? "-",
            taxonomy?.cellSubclass?.curie ?? "-",
            taxonomy?.transcriptomicType?.curie ?? "-",
            taxonomy?.morphologicalType?.curie ?? "-",
            taxonomy?.electrophysiologicalType?.curie ?? "-",
            taxonomy?.brainRegion?.curie ?? "-",
            coordinateFrameID ?? "-",
            coordinateKey
        ].joined(separator: "\u{1f}")
    }

    public var stableKey: String {
        [datasetReference ?? "-", semanticKey].joined(separator: "\u{1f}")
    }

    public func validated() throws -> Self {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EvidenceError.invalidEntity(identifier)
        }
        if let taxonomy { _ = try taxonomy.validated() }
        if let coordinate {
            guard coordinate.count == 3,
                  coordinate.allSatisfy(\.isFinite),
                  coordinateFrameID?.isEmpty == false else {
                throw EvidenceError.invalidEntity(identifier)
            }
        } else if coordinateFrameID != nil {
            throw EvidenceError.invalidEntity(identifier)
        }
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.stableKey < rhs.stableKey
    }
}

public struct BiologicalProperty: Codable, Sendable, Hashable, Comparable {
    public var path: String
    public var label: String
    public var expectedDimension: UnitDimension?

    public init(
        path: String,
        label: String,
        expectedDimension: UnitDimension? = nil
    ) {
        self.path = path
        self.label = label
        self.expectedDimension = expectedDimension
    }

    public func validated() throws -> Self {
        guard !path.isEmpty, !label.isEmpty else {
            throw EvidenceError.invalidProperty(path)
        }
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.path < rhs.path
    }

    public static let cellKind = Self(
        path: "cell.kind",
        label: "Cell kind"
    )
    public static let cellDensity = Self(
        path: "population.cell_density",
        label: "Cell density",
        expectedDimension: .numberDensity
    )
    public static let position = Self(
        path: "cell.position",
        label: "Cell position",
        expectedDimension: .length
    )
    public static let somaRadius = Self(
        path: "cell.soma.radius",
        label: "Soma radius",
        expectedDimension: .length
    )
    public static let membraneCapacitance = Self(
        path: "cell.membrane.capacitance",
        label: "Membrane capacitance",
        expectedDimension: .capacitance
    )
    public static let leakConductance = Self(
        path: "cell.membrane.leak_conductance",
        label: "Leak conductance",
        expectedDimension: .conductance
    )
    public static let leakReversalPotential = Self(
        path: "cell.membrane.leak_reversal",
        label: "Leak reversal potential",
        expectedDimension: .voltage
    )
    public static let restingPotential = Self(
        path: "cell.electrophysiology.resting_potential",
        label: "Resting membrane potential",
        expectedDimension: .voltage
    )
    public static let inputResistance = Self(
        path: "cell.electrophysiology.input_resistance",
        label: "Input resistance",
        expectedDimension: .resistance
    )
    public static let membraneTimeConstant = Self(
        path: "cell.electrophysiology.membrane_time_constant",
        label: "Membrane time constant",
        expectedDimension: .time
    )
    public static let spikeThreshold = Self(
        path: "cell.electrophysiology.spike_threshold",
        label: "Spike threshold",
        expectedDimension: .voltage
    )
    public static let maximumConductance = Self(
        path: "ion_channel.maximum_conductance",
        label: "Maximum conductance",
        expectedDimension: .conductance
    )
    public static let reversalPotential = Self(
        path: "ion_channel.reversal_potential",
        label: "Ion reversal potential",
        expectedDimension: .voltage
    )
    public static let synapticWeight = Self(
        path: "synapse.weight",
        label: "Synaptic weight"
    )
    public static let synapticDelay = Self(
        path: "synapse.delay",
        label: "Synaptic delay",
        expectedDimension: .time
    )
    public static let connectionProbability = Self(
        path: "connection.probability",
        label: "Connection probability",
        expectedDimension: .dimensionless
    )
    public static let releaseProbability = Self(
        path: "synapse.release_probability",
        label: "Release probability",
        expectedDimension: .dimensionless
    )
    public static let synapticRiseTime = Self(
        path: "synapse.rise_time",
        label: "Synaptic rise time",
        expectedDimension: .time
    )
    public static let synapticDecayTime = Self(
        path: "synapse.decay_time",
        label: "Synaptic decay time",
        expectedDimension: .time
    )
    public static let conductionVelocity = Self(
        path: "axon.conduction_velocity",
        label: "Conduction velocity",
        expectedDimension: .velocity
    )
}

public struct CategoricalProbability: Codable, Sendable, Hashable {
    public var category: String
    public var probability: Double

    public init(category: String, probability: Double) {
        self.category = category
        self.probability = probability
    }

    public func validated() throws -> Self {
        guard !category.isEmpty,
              probability.isFinite,
              (0...1).contains(probability) else {
            throw EvidenceError.invalidCategoricalProbability(category)
        }
        return self
    }
}

public enum EvidenceValue: Codable, Sendable, Equatable {
    case scalar(Double)
    case interval(lower: Double, upper: Double)
    case gaussian(mean: Double, standardDeviation: Double, sampleCount: UInt64?)
    case samples([Double])
    case vector([Double])
    case category(String)
    case categoryProbabilities([CategoricalProbability])
    case boolean(Bool)
    case text(String)

    public var isNumeric: Bool {
        switch self {
        case .scalar, .interval, .gaussian, .samples, .vector:
            return true
        case .category, .categoryProbabilities, .boolean, .text:
            return false
        }
    }

    public func validated() throws -> Self {
        switch self {
        case .scalar(let value):
            guard value.isFinite else { throw EvidenceError.nonFiniteValue }
        case .interval(let lower, let upper):
            guard lower.isFinite, upper.isFinite, lower <= upper else {
                throw EvidenceError.invalidInterval
            }
        case .gaussian(let mean, let standardDeviation, let sampleCount):
            guard mean.isFinite,
                  standardDeviation.isFinite,
                  standardDeviation >= 0,
                  sampleCount.map({ $0 > 0 }) ?? true else {
                throw EvidenceError.invalidDistribution
            }
        case .samples(let values), .vector(let values):
            guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
                throw EvidenceError.nonFiniteValue
            }
        case .category(let value), .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EvidenceError.emptyValue
            }
        case .categoryProbabilities(let values):
            guard !values.isEmpty,
                  Set(values.map(\.category)).count == values.count else {
                throw EvidenceError.invalidDistribution
            }
            for value in values { _ = try value.validated() }
            let sum = values.reduce(0) { $0 + $1.probability }
            guard sum.isFinite, sum > 0, sum <= 1.000_001 else {
                throw EvidenceError.invalidDistribution
            }
        case .boolean:
            break
        }
        return self
    }
}

public enum EvidenceMethod: String, Codable, Sendable, CaseIterable, Hashable {
    case directMeasurement
    case automatedSegmentation
    case manualReconstruction
    case patchClamp
    case opticalImaging
    case electronMicroscopy
    case spatialAssay
    case sequencing
    case modelFit
    case simulation
    case literatureExtraction
    case expertCuration
    case statisticalInference
    case generatedPrior
    case unknown
}

public enum EvidenceCurationState: String, Codable, Sendable, CaseIterable, Hashable {
    case raw
    case automaticallyNormalized
    case manuallyReviewed
    case independentlyReplicated
    case deprecated
}

public enum EvidenceQualityFlag: String, Codable, Sendable, CaseIterable, Hashable {
    case alignmentUncertain
    case duplicated
    case estimated
    case failedQualityControl
    case incompleteMetadata
    case licenseRestricted
    case lowSignal
    case modelDerived
    case outlier
    case reconstructionGap
    case superseded
    case truncated
}

public struct EvidenceQuality: Codable, Sendable, Equatable {
    public var confidence: Double
    public var method: EvidenceMethod
    public var curation: EvidenceCurationState
    public var sampleCount: UInt64?
    public var standardError: UnitValue?
    public var flags: Set<EvidenceQualityFlag>
    public var notes: String?

    public init(
        confidence: Double,
        method: EvidenceMethod,
        curation: EvidenceCurationState = .raw,
        sampleCount: UInt64? = nil,
        standardError: UnitValue? = nil,
        flags: Set<EvidenceQualityFlag> = [],
        notes: String? = nil
    ) {
        self.confidence = confidence
        self.method = method
        self.curation = curation
        self.sampleCount = sampleCount
        self.standardError = standardError
        self.flags = flags
        self.notes = notes
    }

    public var excludedByDefault: Bool {
        flags.contains(.failedQualityControl) ||
            flags.contains(.superseded) ||
            curation == .deprecated
    }

    public func validated() throws -> Self {
        guard confidence.isFinite,
              (0...1).contains(confidence),
              sampleCount.map({ $0 > 0 }) ?? true else {
            throw EvidenceError.invalidQuality
        }
        if let standardError {
            _ = try standardError.validated()
            guard standardError.value >= 0 else {
                throw EvidenceError.invalidQuality
            }
        }
        return self
    }
}

public struct EvidenceRecord: Codable, Sendable, Equatable {
    public var id: String
    public var entity: BiologicalEntityKey
    public var property: BiologicalProperty
    public var value: EvidenceValue
    public var unit: BiologicalUnit?
    public var source: BiologicalDataSource
    public var modalities: Set<BiologicalDataModality>
    public var datasetReference: String
    public var assetID: String?
    public var specimen: SpecimenIdentity?
    public var coordinateFrameID: String?
    public var quality: EvidenceQuality
    public var provenanceNodeIDs: [String]
    public var observedAt: Date?
    public var metadata: [String: String]

    public init(
        id: String,
        entity: BiologicalEntityKey,
        property: BiologicalProperty,
        value: EvidenceValue,
        unit: BiologicalUnit? = nil,
        source: BiologicalDataSource,
        modalities: Set<BiologicalDataModality>,
        datasetReference: String,
        assetID: String? = nil,
        specimen: SpecimenIdentity? = nil,
        coordinateFrameID: String? = nil,
        quality: EvidenceQuality,
        provenanceNodeIDs: [String] = [],
        observedAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.entity = entity
        self.property = property
        self.value = value
        self.unit = unit
        self.source = source
        self.modalities = modalities
        self.datasetReference = datasetReference
        self.assetID = assetID
        self.specimen = specimen
        self.coordinateFrameID = coordinateFrameID
        self.quality = quality
        self.provenanceNodeIDs = provenanceNodeIDs
        self.observedAt = observedAt
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty, !datasetReference.isEmpty, !modalities.isEmpty else {
            throw EvidenceError.invalidRecord(id)
        }
        _ = try entity.validated()
        _ = try property.validated()
        _ = try value.validated()
        _ = try quality.validated()
        if let specimen { _ = try specimen.validated() }

        if value.isNumeric, let expected = property.expectedDimension {
            guard let unit, unit.dimension == expected else {
                throw EvidenceError.unitMismatch(
                    record: id,
                    expected: expected,
                    actual: unit?.dimension
                )
            }
        }
        if !value.isNumeric, unit != nil {
            throw EvidenceError.unexpectedUnit(id)
        }
        if let standardError = quality.standardError {
            let measurementUnit = unit ?? .dimensionless
            guard standardError.unit.dimension == measurementUnit.dimension else {
                throw EvidenceError.unitMismatch(
                    record: id,
                    expected: measurementUnit.dimension,
                    actual: standardError.unit.dimension
                )
            }
        }
        return self
    }
}

public struct EvidenceBatch: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var dataset: DatasetVersion
    public var assets: [DataAsset]
    public var records: [EvidenceRecord]
    public var ontology: OntologyRegistry
    public var provenance: ProvenanceGraph
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        dataset: DatasetVersion,
        assets: [DataAsset] = [],
        records: [EvidenceRecord],
        ontology: OntologyRegistry = OntologyRegistry(),
        provenance: ProvenanceGraph = ProvenanceGraph(),
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.dataset = dataset
        self.assets = assets
        self.records = records
        self.ontology = ontology
        self.provenance = provenance
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw EvidenceError.unsupportedSchema(schemaVersion)
        }
        _ = try dataset.validated()
        _ = try ontology.validated()
        _ = try provenance.validated()
        guard Set(assets.map(\.id)).count == assets.count,
              Set(records.map(\.id)).count == records.count else {
            throw EvidenceError.duplicateIdentifier
        }

        let assetIDs = Set(assets.map(\.id))
        let provenanceIDs = Set(provenance.nodes.map(\.id))
        for asset in assets {
            _ = try asset.validated()
            guard asset.dataset.stableReference == dataset.stableReference else {
                throw EvidenceError.datasetMismatch(asset.id)
            }
        }
        for record in records {
            _ = try record.validated()
            guard record.source == dataset.source,
                  record.datasetReference == dataset.stableReference else {
                throw EvidenceError.datasetMismatch(record.id)
            }
            if let assetID = record.assetID, !assetIDs.contains(assetID) {
                throw EvidenceError.unknownAsset(assetID)
            }
            guard record.provenanceNodeIDs.allSatisfy(provenanceIDs.contains) else {
                throw EvidenceError.unknownProvenance(record.id)
            }
        }
        return self
    }
}

public struct EvidenceQuery: Codable, Sendable, Equatable {
    public var entityKinds: Set<BiologicalEntityKind>?
    public var entityIdentifiers: Set<String>?
    public var propertyPaths: Set<String>?
    public var sources: Set<BiologicalDataSource>?
    public var modalities: Set<BiologicalDataModality>?
    public var minimumConfidence: Double
    public var includeExcluded: Bool

    public init(
        entityKinds: Set<BiologicalEntityKind>? = nil,
        entityIdentifiers: Set<String>? = nil,
        propertyPaths: Set<String>? = nil,
        sources: Set<BiologicalDataSource>? = nil,
        modalities: Set<BiologicalDataModality>? = nil,
        minimumConfidence: Double = 0,
        includeExcluded: Bool = false
    ) {
        self.entityKinds = entityKinds
        self.entityIdentifiers = entityIdentifiers
        self.propertyPaths = propertyPaths
        self.sources = sources
        self.modalities = modalities
        self.minimumConfidence = minimumConfidence
        self.includeExcluded = includeExcluded
    }

    public func validated() throws -> Self {
        guard minimumConfidence.isFinite,
              (0...1).contains(minimumConfidence) else {
            throw EvidenceError.invalidQuery
        }
        return self
    }

    public func matches(_ record: EvidenceRecord) -> Bool {
        if let entityKinds, !entityKinds.contains(record.entity.kind) { return false }
        if let entityIdentifiers,
           !entityIdentifiers.contains(record.entity.identifier) { return false }
        if let propertyPaths, !propertyPaths.contains(record.property.path) { return false }
        if let sources, !sources.contains(record.source) { return false }
        if let modalities, record.modalities.isDisjoint(with: modalities) { return false }
        if record.quality.confidence < minimumConfidence { return false }
        if !includeExcluded, record.quality.excludedByDefault { return false }
        return true
    }
}

public struct EvidenceIndex: Sendable {
    public private(set) var records: [EvidenceRecord]

    public init(batches: [EvidenceBatch]) throws {
        var flattened: [EvidenceRecord] = []
        for batch in batches {
            let valid = try batch.validated()
            flattened.append(contentsOf: valid.records)
        }
        guard Set(flattened.map(\.id)).count == flattened.count else {
            throw EvidenceError.duplicateIdentifier
        }
        records = flattened.sorted { $0.id < $1.id }
    }

    public func query(_ query: EvidenceQuery) throws -> [EvidenceRecord] {
        let valid = try query.validated()
        return records.filter(valid.matches)
    }

    public func records(
        for entity: BiologicalEntityKey,
        property: BiologicalProperty? = nil
    ) -> [EvidenceRecord] {
        records.filter {
            $0.entity == entity && (property == nil || $0.property == property)
        }
    }
}

public enum EvidenceError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidEntity(String)
    case invalidProperty(String)
    case invalidCategoricalProbability(String)
    case nonFiniteValue
    case invalidInterval
    case invalidDistribution
    case emptyValue
    case invalidQuality
    case invalidRecord(String)
    case unitMismatch(
        record: String,
        expected: UnitDimension,
        actual: UnitDimension?
    )
    case unexpectedUnit(String)
    case duplicateIdentifier
    case datasetMismatch(String)
    case unknownAsset(String)
    case unknownProvenance(String)
    case invalidQuery

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported evidence schema \(version)."
        case .invalidEntity(let identifier):
            return "Biological entity \(identifier) is invalid."
        case .invalidProperty(let path):
            return "Biological property \(path) is invalid."
        case .invalidCategoricalProbability(let category):
            return "Categorical probability \(category) is invalid."
        case .nonFiniteValue:
            return "Evidence contains a non-finite or empty numeric value."
        case .invalidInterval:
            return "Evidence interval is invalid."
        case .invalidDistribution:
            return "Evidence distribution is invalid."
        case .emptyValue:
            return "Evidence text or category is empty."
        case .invalidQuality:
            return "Evidence quality metadata is invalid."
        case .invalidRecord(let identifier):
            return "Evidence record \(identifier) is invalid."
        case .unitMismatch(let record, let expected, let actual):
            return "Evidence record \(record) expects \(expected.rawValue), not \(actual?.rawValue ?? "no unit")."
        case .unexpectedUnit(let record):
            return "Non-numeric evidence record \(record) cannot carry a numeric unit."
        case .duplicateIdentifier:
            return "Evidence collection contains duplicate identifiers."
        case .datasetMismatch(let identifier):
            return "Evidence or asset \(identifier) does not match its batch dataset."
        case .unknownAsset(let identifier):
            return "Evidence references unknown asset \(identifier)."
        case .unknownProvenance(let identifier):
            return "Evidence record \(identifier) references unknown provenance."
        case .invalidQuery:
            return "Evidence query is invalid."
        }
    }
}
