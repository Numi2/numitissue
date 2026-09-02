import Foundation
import NumiTissueCore
import NumiTissueModels

public struct BiologicalAttribution: Codable, Sendable, Equatable {
    public var confidence: Double
    public var evidenceRecordIDs: [String]
    public var provenanceNodeIDs: [String]
    public var datasetReferences: [String]
    public var notes: String?

    public init(
        confidence: Double = 1,
        evidenceRecordIDs: [String] = [],
        provenanceNodeIDs: [String] = [],
        datasetReferences: [String] = [],
        notes: String? = nil
    ) {
        self.confidence = confidence
        self.evidenceRecordIDs = evidenceRecordIDs
        self.provenanceNodeIDs = provenanceNodeIDs
        self.datasetReferences = datasetReferences
        self.notes = notes
    }

    public func validated() throws -> Self {
        guard confidence.isFinite,
              (0...1).contains(confidence),
              Set(evidenceRecordIDs).count == evidenceRecordIDs.count,
              Set(provenanceNodeIDs).count == provenanceNodeIDs.count,
              Set(datasetReferences).count == datasetReferences.count else {
            throw CanonicalBiologyError.invalidAttribution
        }
        return self
    }

    public func merging(_ other: Self) -> Self {
        let combinedConfidence = 1 - (1 - confidence) * (1 - other.confidence)
        return Self(
            confidence: max(0, min(1, combinedConfidence)),
            evidenceRecordIDs: Array(
                Set(evidenceRecordIDs).union(other.evidenceRecordIDs)
            ).sorted(),
            provenanceNodeIDs: Array(
                Set(provenanceNodeIDs).union(other.provenanceNodeIDs)
            ).sorted(),
            datasetReferences: Array(
                Set(datasetReferences).union(other.datasetReferences)
            ).sorted(),
            notes: [notes, other.notes]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .nilIfEmpty
        )
    }
}

public struct CanonicalPopulation: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var region: OntologyTerm?
    public var regionLabel: String
    public var tags: [String]
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        name: String,
        region: OntologyTerm? = nil,
        regionLabel: String,
        tags: [String] = [],
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.name = name
        self.region = region
        self.regionLabel = regionLabel
        self.tags = tags
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "population")
        try requireCanonicalName(name, kind: "population")
        guard !regionLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(tags).count == tags.count else {
            throw CanonicalBiologyError.invalidPopulation(id)
        }
        if let region { _ = try region.validated() }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalMorphology: Codable, Sendable, Equatable {
    public var id: String
    public var morphology: NeuronMorphology
    public var coordinateFrame: CoordinateFrame
    public var isComplete: Bool
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        morphology: NeuronMorphology,
        coordinateFrame: CoordinateFrame = .canonicalMicrometers,
        isComplete: Bool = true,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.morphology = morphology
        self.coordinateFrame = coordinateFrame
        self.isComplete = isComplete
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "morphology")
        try morphology.validate()
        _ = try coordinateFrame.validated()
        guard coordinateFrame.identifier == CoordinateFrame.canonicalMicrometers.identifier,
              coordinateFrame.unit == .micrometer else {
            throw CanonicalBiologyError.nonCanonicalCoordinateFrame(
                coordinateFrame.identifier
            )
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalMechanismSet: Codable, Sendable, Equatable {
    public var id: String
    public var mechanism: MechanismSet
    public var ontologyTerms: [OntologyTerm]
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        mechanism: MechanismSet,
        ontologyTerms: [OntologyTerm] = [],
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.mechanism = mechanism
        self.ontologyTerms = ontologyTerms
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "mechanism")
        try requireCanonicalName(mechanism.name, kind: "mechanism")
        guard mechanism.temperatureCelsius.isFinite,
              mechanism.q10.isFinite,
              mechanism.q10 > 0,
              !mechanism.channels.isEmpty else {
            throw CanonicalBiologyError.invalidMechanism(id)
        }
        for channel in mechanism.channels {
            guard !channel.name.isEmpty,
                  channel.maximumConductance.isFinite,
                  channel.maximumConductance >= 0,
                  channel.reversalPotentialMillivolts.isFinite,
                  channel.activationGate.parameters.allFinite,
                  channel.inactivationGate.parameters.allFinite else {
                throw CanonicalBiologyError.invalidMechanism(id)
            }
        }
        for term in ontologyTerms { _ = try term.validated() }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalRegulatoryProgram: Codable, Sendable, Equatable {
    public var id: String
    public var program: RegulatoryProgram
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        program: RegulatoryProgram,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.program = program
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "regulatory program")
        try requireCanonicalName(program.name, kind: "regulatory program")
        guard program.timeConstantsSeconds0.allPositiveFinite,
              program.timeConstantsSeconds1.allPositiveFinite,
              program.recurrentRows.allSatisfy(\.allFinite),
              program.biases.allSatisfy(\.isFinite),
              program.divisionHazardPerSecond.isFinite,
              program.divisionHazardPerSecond >= 0,
              program.apoptosisHazardPerSecond.isFinite,
              program.apoptosisHazardPerSecond >= 0 else {
            throw CanonicalBiologyError.invalidRegulatoryProgram(id)
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalGlialProgram: Codable, Sendable, Equatable {
    public var id: String
    public var program: GlialProgram
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        program: GlialProgram,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.program = program
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "glial program")
        try requireCanonicalName(program.name, kind: "glial program")
        guard program.uptakeRates.allFinite,
              program.releaseRates.allFinite,
              program.activationThresholds.allFinite,
              program.spatialRadiusMicrometers.isFinite,
              program.spatialRadiusMicrometers > 0 else {
            throw CanonicalBiologyError.invalidGlialProgram(id)
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalCellType: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var taxonomy: CellTaxonomyIdentity
    public var kind: CellKind
    public var defaultFidelity: FidelityLevel
    public var morphologyID: String?
    public var mechanismSetID: String?
    public var regulatoryProgramID: String?
    public var glialProgramID: String?
    public var radiusMicrometers: Double
    public var membraneCapacitance: Double
    public var leakConductance: Double
    public var leakReversalMillivolts: Double
    public var attribution: BiologicalAttribution
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        taxonomy: CellTaxonomyIdentity,
        kind: CellKind,
        defaultFidelity: FidelityLevel,
        morphologyID: String? = nil,
        mechanismSetID: String? = nil,
        regulatoryProgramID: String? = nil,
        glialProgramID: String? = nil,
        radiusMicrometers: Double = 5,
        membraneCapacitance: Double = 1,
        leakConductance: Double = 0.1,
        leakReversalMillivolts: Double = -65,
        attribution: BiologicalAttribution = BiologicalAttribution(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.taxonomy = taxonomy
        self.kind = kind
        self.defaultFidelity = defaultFidelity
        self.morphologyID = morphologyID
        self.mechanismSetID = mechanismSetID
        self.regulatoryProgramID = regulatoryProgramID
        self.glialProgramID = glialProgramID
        self.radiusMicrometers = radiusMicrometers
        self.membraneCapacitance = membraneCapacitance
        self.leakConductance = leakConductance
        self.leakReversalMillivolts = leakReversalMillivolts
        self.attribution = attribution
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "cell type")
        try requireCanonicalName(name, kind: "cell type")
        _ = try taxonomy.validated()
        guard radiusMicrometers.isFinite,
              radiusMicrometers > 0,
              membraneCapacitance.isFinite,
              membraneCapacitance > 0,
              leakConductance.isFinite,
              leakConductance >= 0,
              leakReversalMillivolts.isFinite else {
            throw CanonicalBiologyError.invalidCellType(id)
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalCell: Codable, Sendable, Equatable {
    public var id: String
    public var lineageID: String
    public var cellTypeID: String
    public var populationID: String
    public var positionMicrometers: [Double]
    public var orientationQuaternion: [Double]
    public var fidelityOverride: FidelityLevel?
    public var attribution: BiologicalAttribution
    public var metadata: [String: String]

    public init(
        id: String,
        lineageID: String,
        cellTypeID: String,
        populationID: String,
        positionMicrometers: [Double],
        orientationQuaternion: [Double] = [0, 0, 0, 1],
        fidelityOverride: FidelityLevel? = nil,
        attribution: BiologicalAttribution = BiologicalAttribution(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.lineageID = lineageID
        self.cellTypeID = cellTypeID
        self.populationID = populationID
        self.positionMicrometers = positionMicrometers
        self.orientationQuaternion = orientationQuaternion
        self.fidelityOverride = fidelityOverride
        self.attribution = attribution
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "cell")
        try requireCanonicalIdentifier(lineageID, kind: "lineage")
        guard !cellTypeID.isEmpty,
              !populationID.isEmpty,
              positionMicrometers.count == 3,
              positionMicrometers.allSatisfy(\.isFinite),
              orientationQuaternion.count == 4,
              orientationQuaternion.allSatisfy(\.isFinite),
              orientationQuaternion.reduce(0, { $0 + $1 * $1 }) > 1e-20 else {
            throw CanonicalBiologyError.invalidCell(id)
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalSynapseType: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var receptor: ReceptorKind
    public var riseMilliseconds: Double
    public var decayMilliseconds: Double
    public var reversalPotentialMillivolts: Double
    public var defaultWeight: Double
    public var shortTermPlasticity: ShortTermPlasticity?
    public var stdp: STDPParameters?
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        name: String,
        receptor: ReceptorKind,
        riseMilliseconds: Double,
        decayMilliseconds: Double,
        reversalPotentialMillivolts: Double,
        defaultWeight: Double,
        shortTermPlasticity: ShortTermPlasticity? = nil,
        stdp: STDPParameters? = nil,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.name = name
        self.receptor = receptor
        self.riseMilliseconds = riseMilliseconds
        self.decayMilliseconds = decayMilliseconds
        self.reversalPotentialMillivolts = reversalPotentialMillivolts
        self.defaultWeight = defaultWeight
        self.shortTermPlasticity = shortTermPlasticity
        self.stdp = stdp
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "synapse type")
        try requireCanonicalName(name, kind: "synapse type")
        guard riseMilliseconds.isFinite,
              riseMilliseconds >= 0,
              decayMilliseconds.isFinite,
              decayMilliseconds > 0,
              reversalPotentialMillivolts.isFinite,
              defaultWeight.isFinite,
              defaultWeight >= 0 else {
            throw CanonicalBiologyError.invalidSynapseType(id)
        }
        if let shortTermPlasticity {
            guard shortTermPlasticity.utilization.isFinite,
                  (0...1).contains(shortTermPlasticity.utilization),
                  shortTermPlasticity.recoveryMilliseconds.isFinite,
                  shortTermPlasticity.recoveryMilliseconds >= 0,
                  shortTermPlasticity.facilitationMilliseconds.isFinite,
                  shortTermPlasticity.facilitationMilliseconds >= 0 else {
                throw CanonicalBiologyError.invalidSynapseType(id)
            }
        }
        if let stdp {
            guard stdp.positiveAmplitude.isFinite,
                  stdp.negativeAmplitude.isFinite,
                  stdp.positiveTimeConstantMilliseconds.isFinite,
                  stdp.positiveTimeConstantMilliseconds > 0,
                  stdp.negativeTimeConstantMilliseconds.isFinite,
                  stdp.negativeTimeConstantMilliseconds > 0,
                  stdp.eligibilityTimeConstantMilliseconds.isFinite,
                  stdp.eligibilityTimeConstantMilliseconds > 0,
                  stdp.learningRate.isFinite,
                  stdp.learningRate >= 0,
                  stdp.minimumWeight.isFinite,
                  stdp.maximumWeight.isFinite,
                  stdp.minimumWeight <= stdp.maximumWeight else {
                throw CanonicalBiologyError.invalidSynapseType(id)
            }
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalSynapse: Codable, Sendable, Equatable {
    public var id: String
    public var synapseTypeID: String
    public var presynapticCellID: String
    public var postsynapticCellID: String
    public var postsynapticMorphologyNode: UInt32?
    public var weight: Double?
    public var delayMilliseconds: Double
    public var positionMicrometers: [Double]?
    public var attribution: BiologicalAttribution
    public var metadata: [String: String]

    public init(
        id: String,
        synapseTypeID: String,
        presynapticCellID: String,
        postsynapticCellID: String,
        postsynapticMorphologyNode: UInt32? = nil,
        weight: Double? = nil,
        delayMilliseconds: Double = 1,
        positionMicrometers: [Double]? = nil,
        attribution: BiologicalAttribution = BiologicalAttribution(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.synapseTypeID = synapseTypeID
        self.presynapticCellID = presynapticCellID
        self.postsynapticCellID = postsynapticCellID
        self.postsynapticMorphologyNode = postsynapticMorphologyNode
        self.weight = weight
        self.delayMilliseconds = delayMilliseconds
        self.positionMicrometers = positionMicrometers
        self.attribution = attribution
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "synapse")
        guard !synapseTypeID.isEmpty,
              !presynapticCellID.isEmpty,
              !postsynapticCellID.isEmpty,
              presynapticCellID != postsynapticCellID ||
                metadata["allow_autapse"] == "true",
              weight.map({ $0.isFinite && $0 >= 0 }) ?? true,
              delayMilliseconds.isFinite,
              delayMilliseconds >= 0 else {
            throw CanonicalBiologyError.invalidSynapse(id)
        }
        if let positionMicrometers {
            guard positionMicrometers.count == 3,
                  positionMicrometers.allSatisfy(\.isFinite) else {
                throw CanonicalBiologyError.invalidSynapse(id)
            }
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalFieldSpecies: Codable, Sendable, Equatable {
    public var id: String
    public var descriptor: FieldSpeciesDescriptor
    public var ontologyTerm: OntologyTerm?
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        descriptor: FieldSpeciesDescriptor,
        ontologyTerm: OntologyTerm? = nil,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.descriptor = descriptor
        self.ontologyTerm = ontologyTerm
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "field species")
        try requireCanonicalName(descriptor.name, kind: "field species")
        guard descriptor.diffusionMicrometersSquaredPerMillisecond.isFinite,
              descriptor.diffusionMicrometersSquaredPerMillisecond >= 0,
              descriptor.decayPerMillisecond.isFinite,
              descriptor.decayPerMillisecond >= 0,
              descriptor.baseline.isFinite,
              descriptor.minimum.isFinite,
              descriptor.maximum.isFinite,
              descriptor.minimum <= descriptor.baseline,
              descriptor.baseline <= descriptor.maximum else {
            throw CanonicalBiologyError.invalidFieldSpecies(id)
        }
        if let ontologyTerm { _ = try ontologyTerm.validated() }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalMolecularNetwork: Codable, Sendable, Equatable {
    public var id: String
    public var network: MolecularNetwork
    public var ontologyTerms: [OntologyTerm]
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        network: MolecularNetwork,
        ontologyTerms: [OntologyTerm] = [],
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.network = network
        self.ontologyTerms = ontologyTerms
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "molecular network")
        try requireCanonicalName(network.name, kind: "molecular network")
        guard !network.species.isEmpty,
              network.voxelCount > 0,
              network.species.allSatisfy({
                  !$0.name.isEmpty &&
                    $0.initialAmount.isFinite &&
                    $0.initialAmount >= $0.minimumAmount &&
                    $0.diffusionCoefficient.isFinite &&
                    $0.diffusionCoefficient >= 0 &&
                    $0.minimumAmount.isFinite
              }),
              network.reactions.allSatisfy({
                  !$0.name.isEmpty &&
                    $0.forwardRate.isFinite &&
                    $0.forwardRate >= 0 &&
                    ($0.reverseRate?.isFinite ?? true) &&
                    ($0.reverseRate.map { $0 >= 0 } ?? true)
              }) else {
            throw CanonicalBiologyError.invalidMolecularNetwork(id)
        }
        for term in ontologyTerms { _ = try term.validated() }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalMolecularDomain: Codable, Sendable, Equatable {
    public var id: String
    public var networkID: String
    public var cellID: String
    public var morphologyNode: UInt32?
    public var fieldVoxel: UInt32?
    public var attribution: BiologicalAttribution

    public init(
        id: String,
        networkID: String,
        cellID: String,
        morphologyNode: UInt32? = nil,
        fieldVoxel: UInt32? = nil,
        attribution: BiologicalAttribution = BiologicalAttribution()
    ) {
        self.id = id
        self.networkID = networkID
        self.cellID = cellID
        self.morphologyNode = morphologyNode
        self.fieldVoxel = fieldVoxel
        self.attribution = attribution
    }

    public func validated() throws -> Self {
        try requireCanonicalIdentifier(id, kind: "molecular domain")
        guard !networkID.isEmpty, !cellID.isEmpty else {
            throw CanonicalBiologyError.invalidMolecularDomain(id)
        }
        _ = try attribution.validated()
        return self
    }
}

public struct CanonicalTissueBlueprint: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var name: String
    public var metadata: [String: String]
    public var sourceDatasets: [DatasetVersion]
    public var ontology: OntologyRegistry
    public var provenance: ProvenanceGraph
    public var evidence: [EvidenceRecord]
    public var resolvedEvidence: [ResolvedEvidence]

    public var populations: [CanonicalPopulation]
    public var morphologies: [CanonicalMorphology]
    public var mechanismSets: [CanonicalMechanismSet]
    public var regulatoryPrograms: [CanonicalRegulatoryProgram]
    public var glialPrograms: [CanonicalGlialProgram]
    public var cellTypes: [CanonicalCellType]
    public var cells: [CanonicalCell]
    public var synapseTypes: [CanonicalSynapseType]
    public var synapses: [CanonicalSynapse]
    public var fieldSpecies: [CanonicalFieldSpecies]
    public var molecularNetworks: [CanonicalMolecularNetwork]
    public var molecularDomains: [CanonicalMolecularDomain]

    public init(
        schemaVersion: UInt32 = 1,
        name: String,
        metadata: [String: String] = [:],
        sourceDatasets: [DatasetVersion] = [],
        ontology: OntologyRegistry = OntologyRegistry(),
        provenance: ProvenanceGraph = ProvenanceGraph(),
        evidence: [EvidenceRecord] = [],
        resolvedEvidence: [ResolvedEvidence] = [],
        populations: [CanonicalPopulation] = [],
        morphologies: [CanonicalMorphology] = [],
        mechanismSets: [CanonicalMechanismSet] = [],
        regulatoryPrograms: [CanonicalRegulatoryProgram] = [],
        glialPrograms: [CanonicalGlialProgram] = [],
        cellTypes: [CanonicalCellType] = [],
        cells: [CanonicalCell] = [],
        synapseTypes: [CanonicalSynapseType] = [],
        synapses: [CanonicalSynapse] = [],
        fieldSpecies: [CanonicalFieldSpecies] = [],
        molecularNetworks: [CanonicalMolecularNetwork] = [],
        molecularDomains: [CanonicalMolecularDomain] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.metadata = metadata
        self.sourceDatasets = sourceDatasets
        self.ontology = ontology
        self.provenance = provenance
        self.evidence = evidence
        self.resolvedEvidence = resolvedEvidence
        self.populations = populations
        self.morphologies = morphologies
        self.mechanismSets = mechanismSets
        self.regulatoryPrograms = regulatoryPrograms
        self.glialPrograms = glialPrograms
        self.cellTypes = cellTypes
        self.cells = cells
        self.synapseTypes = synapseTypes
        self.synapses = synapses
        self.fieldSpecies = fieldSpecies
        self.molecularNetworks = molecularNetworks
        self.molecularDomains = molecularDomains
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw CanonicalBiologyError.unsupportedSchema(schemaVersion)
        }
        try requireCanonicalName(name, kind: "tissue blueprint")
        for dataset in sourceDatasets { _ = try dataset.validated() }
        _ = try ontology.validated()
        _ = try provenance.validated()
        for record in evidence { _ = try record.validated() }

        try requireUniqueCanonicalIDs(populations.map(\.id), kind: "population")
        try requireUniqueCanonicalIDs(morphologies.map(\.id), kind: "morphology")
        try requireUniqueCanonicalIDs(mechanismSets.map(\.id), kind: "mechanism")
        try requireUniqueCanonicalIDs(
            regulatoryPrograms.map(\.id),
            kind: "regulatory program"
        )
        try requireUniqueCanonicalIDs(glialPrograms.map(\.id), kind: "glial program")
        try requireUniqueCanonicalIDs(cellTypes.map(\.id), kind: "cell type")
        try requireUniqueCanonicalIDs(cells.map(\.id), kind: "cell")
        try requireUniqueCanonicalIDs(synapseTypes.map(\.id), kind: "synapse type")
        try requireUniqueCanonicalIDs(synapses.map(\.id), kind: "synapse")
        try requireUniqueCanonicalIDs(fieldSpecies.map(\.id), kind: "field species")
        try requireUniqueCanonicalIDs(
            molecularNetworks.map(\.id),
            kind: "molecular network"
        )
        try requireUniqueCanonicalIDs(
            molecularDomains.map(\.id),
            kind: "molecular domain"
        )

        for value in populations { _ = try value.validated() }
        for value in morphologies { _ = try value.validated() }
        for value in mechanismSets { _ = try value.validated() }
        for value in regulatoryPrograms { _ = try value.validated() }
        for value in glialPrograms { _ = try value.validated() }
        for value in cellTypes { _ = try value.validated() }
        for value in cells { _ = try value.validated() }
        for value in synapseTypes { _ = try value.validated() }
        for value in synapses { _ = try value.validated() }
        for value in fieldSpecies { _ = try value.validated() }
        for value in molecularNetworks { _ = try value.validated() }
        for value in molecularDomains { _ = try value.validated() }

        try requireUniqueCanonicalNames(populations.map(\.name), kind: "population")
        try requireUniqueCanonicalNames(
            morphologies.map(\.morphology.name),
            kind: "morphology"
        )
        try requireUniqueCanonicalNames(
            mechanismSets.map(\.mechanism.name),
            kind: "mechanism"
        )
        try requireUniqueCanonicalNames(
            regulatoryPrograms.map(\.program.name),
            kind: "regulatory program"
        )
        try requireUniqueCanonicalNames(
            glialPrograms.map(\.program.name),
            kind: "glial program"
        )
        try requireUniqueCanonicalNames(cellTypes.map(\.name), kind: "cell type")
        try requireUniqueCanonicalNames(synapseTypes.map(\.name), kind: "synapse type")
        try requireUniqueCanonicalNames(
            fieldSpecies.map(\.descriptor.name),
            kind: "field species"
        )
        try requireUniqueCanonicalNames(
            molecularNetworks.map(\.network.name),
            kind: "molecular network"
        )

        let datasetReferences = Set(sourceDatasets.map(\.stableReference))
        let evidenceIDs = Set(evidence.map(\.id))
        let provenanceIDs = Set(provenance.nodes.map(\.id))
        for attribution in allAttributions {
            guard Set(attribution.datasetReferences).isSubset(of: datasetReferences),
                  Set(attribution.evidenceRecordIDs).isSubset(of: evidenceIDs),
                  Set(attribution.provenanceNodeIDs).isSubset(of: provenanceIDs) else {
                throw CanonicalBiologyError.unknownAttributionReference
            }
        }

        let populationIDs = Set(populations.map(\.id))
        let morphologyIDs = Set(morphologies.map(\.id))
        let mechanismIDs = Set(mechanismSets.map(\.id))
        let regulatoryIDs = Set(regulatoryPrograms.map(\.id))
        let glialIDs = Set(glialPrograms.map(\.id))
        let cellTypeIDs = Set(cellTypes.map(\.id))
        let cellIDs = Set(cells.map(\.id))
        let synapseTypeIDs = Set(synapseTypes.map(\.id))
        let networkIDs = Set(molecularNetworks.map(\.id))

        for type in cellTypes {
            guard type.morphologyID.map(morphologyIDs.contains) ?? true,
                  type.mechanismSetID.map(mechanismIDs.contains) ?? true,
                  type.regulatoryProgramID.map(regulatoryIDs.contains) ?? true,
                  type.glialProgramID.map(glialIDs.contains) ?? true else {
                throw CanonicalBiologyError.unknownReference("cell type \(type.id)")
            }
        }
        for cell in cells {
            guard cellTypeIDs.contains(cell.cellTypeID),
                  populationIDs.contains(cell.populationID) else {
                throw CanonicalBiologyError.unknownReference("cell \(cell.id)")
            }
        }
        for synapse in synapses {
            guard synapseTypeIDs.contains(synapse.synapseTypeID),
                  cellIDs.contains(synapse.presynapticCellID),
                  cellIDs.contains(synapse.postsynapticCellID) else {
                throw CanonicalBiologyError.unknownReference("synapse \(synapse.id)")
            }
        }
        for domain in molecularDomains {
            guard networkIDs.contains(domain.networkID),
                  cellIDs.contains(domain.cellID) else {
                throw CanonicalBiologyError.unknownReference(
                    "molecular domain \(domain.id)"
                )
            }
        }
        return self
    }

    public var allAttributions: [BiologicalAttribution] {
        populations.map(\.attribution) +
            morphologies.map(\.attribution) +
            mechanismSets.map(\.attribution) +
            regulatoryPrograms.map(\.attribution) +
            glialPrograms.map(\.attribution) +
            cellTypes.map(\.attribution) +
            cells.map(\.attribution) +
            synapseTypes.map(\.attribution) +
            synapses.map(\.attribution) +
            fieldSpecies.map(\.attribution) +
            molecularNetworks.map(\.attribution) +
            molecularDomains.map(\.attribution)
    }
}

private func requireCanonicalIdentifier(_ value: String, kind: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CanonicalBiologyError.emptyIdentifier(kind)
    }
}

private func requireCanonicalName(_ value: String, kind: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CanonicalBiologyError.emptyName(kind)
    }
}

private func requireUniqueCanonicalIDs(_ values: [String], kind: String) throws {
    guard Set(values).count == values.count else {
        throw CanonicalBiologyError.duplicateIdentifier(kind)
    }
}

private func requireUniqueCanonicalNames(_ values: [String], kind: String) throws {
    guard Set(values).count == values.count else {
        throw CanonicalBiologyError.duplicateName(kind)
    }
}

private extension SIMD4 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }

    var allPositiveFinite: Bool {
        allFinite && x > 0 && y > 0 && z > 0 && w > 0
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

public enum CanonicalBiologyError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case emptyIdentifier(String)
    case emptyName(String)
    case duplicateIdentifier(String)
    case duplicateName(String)
    case invalidAttribution
    case invalidPopulation(String)
    case nonCanonicalCoordinateFrame(String)
    case invalidMechanism(String)
    case invalidRegulatoryProgram(String)
    case invalidGlialProgram(String)
    case invalidCellType(String)
    case invalidCell(String)
    case invalidSynapseType(String)
    case invalidSynapse(String)
    case invalidFieldSpecies(String)
    case invalidMolecularNetwork(String)
    case invalidMolecularDomain(String)
    case unknownAttributionReference
    case unknownReference(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let value):
            return "Unsupported canonical tissue schema \(value)."
        case .emptyIdentifier(let kind):
            return "Canonical \(kind) identifier is empty."
        case .emptyName(let kind):
            return "Canonical \(kind) name is empty."
        case .duplicateIdentifier(let kind):
            return "Canonical tissue contains duplicate \(kind) identifiers."
        case .duplicateName(let kind):
            return "Canonical tissue contains duplicate \(kind) names."
        case .invalidAttribution:
            return "Biological attribution is invalid."
        case .invalidPopulation(let id):
            return "Canonical population \(id) is invalid."
        case .nonCanonicalCoordinateFrame(let id):
            return "Morphology frame \(id) is not normalized to canonical micrometers."
        case .invalidMechanism(let id):
            return "Canonical mechanism \(id) is invalid."
        case .invalidRegulatoryProgram(let id):
            return "Canonical regulatory program \(id) is invalid."
        case .invalidGlialProgram(let id):
            return "Canonical glial program \(id) is invalid."
        case .invalidCellType(let id):
            return "Canonical cell type \(id) is invalid."
        case .invalidCell(let id):
            return "Canonical cell \(id) is invalid."
        case .invalidSynapseType(let id):
            return "Canonical synapse type \(id) is invalid."
        case .invalidSynapse(let id):
            return "Canonical synapse \(id) is invalid."
        case .invalidFieldSpecies(let id):
            return "Canonical field species \(id) is invalid."
        case .invalidMolecularNetwork(let id):
            return "Canonical molecular network \(id) is invalid."
        case .invalidMolecularDomain(let id):
            return "Canonical molecular domain \(id) is invalid."
        case .unknownAttributionReference:
            return "Canonical tissue attribution references undeclared evidence, provenance, or data."
        case .unknownReference(let value):
            return "Canonical tissue has an unknown reference: \(value)."
        }
    }
}
