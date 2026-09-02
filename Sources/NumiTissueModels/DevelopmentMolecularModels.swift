import Foundation
import NumiTissueCore

@frozen
public struct FateTransition: Codable, Sendable, Hashable {
    public var targetKind: CellKind
    public var baseHazardPerSecond: Float
    public var regulatoryWeights: Float4
    public var fieldWeights: Float4
    public var minimumAgeSeconds: Float

    public init(targetKind: CellKind, baseHazardPerSecond: Float, regulatoryWeights: Float4 = .zero, fieldWeights: Float4 = .zero, minimumAgeSeconds: Float = 0) {
        self.targetKind = targetKind
        self.baseHazardPerSecond = baseHazardPerSecond
        self.regulatoryWeights = regulatoryWeights
        self.fieldWeights = fieldWeights
        self.minimumAgeSeconds = minimumAgeSeconds
    }
}

@frozen
public struct GrowthConeProgram: Codable, Sendable, Hashable {
    public var speedMicrometersPerSecond: Float
    public var persistenceWeight: Float
    public var attractionWeight: Float
    public var repulsionWeight: Float
    public var fasciculationWeight: Float
    public var activityWeight: Float
    public var noiseWeight: Float
    public var branchHazardPerSecond: Float
    public var retractionHazardPerSecond: Float
    public var segmentLengthMicrometers: Float

    public init(
        speedMicrometersPerSecond: Float = 0.25,
        persistenceWeight: Float = 1,
        attractionWeight: Float = 1,
        repulsionWeight: Float = 1,
        fasciculationWeight: Float = 0.25,
        activityWeight: Float = 0.1,
        noiseWeight: Float = 0.05,
        branchHazardPerSecond: Float = 0.001,
        retractionHazardPerSecond: Float = 0.0001,
        segmentLengthMicrometers: Float = 2
    ) {
        self.speedMicrometersPerSecond = speedMicrometersPerSecond
        self.persistenceWeight = persistenceWeight
        self.attractionWeight = attractionWeight
        self.repulsionWeight = repulsionWeight
        self.fasciculationWeight = fasciculationWeight
        self.activityWeight = activityWeight
        self.noiseWeight = noiseWeight
        self.branchHazardPerSecond = branchHazardPerSecond
        self.retractionHazardPerSecond = retractionHazardPerSecond
        self.segmentLengthMicrometers = segmentLengthMicrometers
    }
}

@frozen
public struct RegulatoryProgram: Codable, Sendable, Hashable {
    public var name: String
    public var timeConstantsSeconds0: Float4
    public var timeConstantsSeconds1: Float4
    public var recurrentRows: [Float4]
    public var biases: [Float]
    public var divisionHazardPerSecond: Float
    public var apoptosisHazardPerSecond: Float
    public var fateTransitions: [FateTransition]
    public var growthCone: GrowthConeProgram?

    public init(
        name: String,
        timeConstantsSeconds0: Float4 = Float4(repeating: 60),
        timeConstantsSeconds1: Float4 = Float4(repeating: 60),
        recurrentRows: [Float4] = [],
        biases: [Float] = [],
        divisionHazardPerSecond: Float = 0,
        apoptosisHazardPerSecond: Float = 0,
        fateTransitions: [FateTransition] = [],
        growthCone: GrowthConeProgram? = nil
    ) {
        self.name = name
        self.timeConstantsSeconds0 = timeConstantsSeconds0
        self.timeConstantsSeconds1 = timeConstantsSeconds1
        self.recurrentRows = recurrentRows
        self.biases = biases
        self.divisionHazardPerSecond = divisionHazardPerSecond
        self.apoptosisHazardPerSecond = apoptosisHazardPerSecond
        self.fateTransitions = fateTransitions
        self.growthCone = growthCone
    }
}

public enum GlialProgramKind: UInt16, Codable, Sendable, CaseIterable {
    case astrocyteTerritory = 0
    case oligodendrocyteMyelination = 1
    case microglialSurveillance = 2
}

@frozen
public struct GlialProgram: Codable, Sendable, Hashable {
    public var name: String
    public var kind: GlialProgramKind
    public var uptakeRates: Float4
    public var releaseRates: Float4
    public var activationThresholds: Float4
    public var spatialRadiusMicrometers: Float

    public init(name: String, kind: GlialProgramKind, uptakeRates: Float4 = .zero, releaseRates: Float4 = .zero, activationThresholds: Float4 = .zero, spatialRadiusMicrometers: Float = 50) {
        self.name = name
        self.kind = kind
        self.uptakeRates = uptakeRates
        self.releaseRates = releaseRates
        self.activationThresholds = activationThresholds
        self.spatialRadiusMicrometers = spatialRadiusMicrometers
    }
}

public enum MolecularSolverMode: UInt16, Codable, Sendable, CaseIterable {
    case automatic = 0
    case exactStochastic = 1
    case tauLeap = 2
    case deterministic = 3
}

@frozen
public struct MolecularSpecies: Codable, Sendable, Hashable {
    public var name: String
    public var initialAmount: Float
    public var diffusionCoefficient: Float
    public var minimumAmount: Float

    public init(name: String, initialAmount: Float, diffusionCoefficient: Float = 0, minimumAmount: Float = 0) {
        self.name = name
        self.initialAmount = initialAmount
        self.diffusionCoefficient = diffusionCoefficient
        self.minimumAmount = minimumAmount
    }
}

@frozen
public struct ReactionParticipant: Codable, Sendable, Hashable {
    public var species: String
    public var stoichiometry: Float

    public init(species: String, stoichiometry: Float = 1) {
        self.species = species
        self.stoichiometry = stoichiometry
    }
}

@frozen
public struct MolecularReaction: Codable, Sendable, Hashable {
    public var name: String
    public var reactants: [ReactionParticipant]
    public var products: [ReactionParticipant]
    public var forwardRate: Float
    public var reverseRate: Float?

    public init(name: String, reactants: [ReactionParticipant], products: [ReactionParticipant], forwardRate: Float, reverseRate: Float? = nil) {
        self.name = name
        self.reactants = reactants
        self.products = products
        self.forwardRate = forwardRate
        self.reverseRate = reverseRate
    }
}

@frozen
public struct MolecularNetwork: Codable, Sendable, Hashable {
    public var name: String
    public var solver: MolecularSolverMode
    public var species: [MolecularSpecies]
    public var reactions: [MolecularReaction]
    public var voxelCount: UInt16

    public init(name: String, solver: MolecularSolverMode = .automatic, species: [MolecularSpecies], reactions: [MolecularReaction], voxelCount: UInt16 = 1) {
        self.name = name
        self.solver = solver
        self.species = species
        self.reactions = reactions
        self.voxelCount = voxelCount
    }
}

@frozen
public struct MolecularDomainInstance: Codable, Sendable, Hashable {
    public var id: MicrodomainID
    public var network: String
    public var cell: CellID
    public var morphologyNode: UInt32?
    public var fieldVoxel: UInt32?

    public init(id: MicrodomainID, network: String, cell: CellID, morphologyNode: UInt32? = nil, fieldVoxel: UInt32? = nil) {
        self.id = id
        self.network = network
        self.cell = cell
        self.morphologyNode = morphologyNode
        self.fieldVoxel = fieldVoxel
    }
}

@frozen
public struct TissueModel: Codable, Sendable {
    public var schemaVersion: UInt32
    public var name: String
    public var metadata: [String: String]
    public var populations: [PopulationDescriptor]
    public var morphologies: [NeuronMorphology]
    public var mechanismSets: [MechanismSet]
    public var cellPrototypes: [CellPrototype]
    public var cells: [CellInstance]
    public var synapsePrototypes: [SynapsePrototype]
    public var synapses: [SynapseConnection]
    public var fieldSpecies: [FieldSpeciesDescriptor]
    public var regulatoryPrograms: [RegulatoryProgram]
    public var glialPrograms: [GlialProgram]
    public var molecularNetworks: [MolecularNetwork]
    public var molecularDomains: [MolecularDomainInstance]

    public init(
        schemaVersion: UInt32 = NumiTissueBuild.modelSchemaVersion,
        name: String,
        metadata: [String: String] = [:],
        populations: [PopulationDescriptor] = [],
        morphologies: [NeuronMorphology] = [],
        mechanismSets: [MechanismSet] = [],
        cellPrototypes: [CellPrototype] = [],
        cells: [CellInstance] = [],
        synapsePrototypes: [SynapsePrototype] = [],
        synapses: [SynapseConnection] = [],
        fieldSpecies: [FieldSpeciesDescriptor] = [],
        regulatoryPrograms: [RegulatoryProgram] = [],
        glialPrograms: [GlialProgram] = [],
        molecularNetworks: [MolecularNetwork] = [],
        molecularDomains: [MolecularDomainInstance] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.metadata = metadata
        self.populations = populations
        self.morphologies = morphologies
        self.mechanismSets = mechanismSets
        self.cellPrototypes = cellPrototypes
        self.cells = cells
        self.synapsePrototypes = synapsePrototypes
        self.synapses = synapses
        self.fieldSpecies = fieldSpecies
        self.regulatoryPrograms = regulatoryPrograms
        self.glialPrograms = glialPrograms
        self.molecularNetworks = molecularNetworks
        self.molecularDomains = molecularDomains
    }
}

public enum ModelValidationError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case duplicateName(String)
    case duplicateIdentifier(UInt64)
    case unknownReference(String)
    case emptyMorphology(String)
    case duplicateMorphologyNode(String)
    case invalidRootCount(String, Int)
    case invalidRadius(String, UInt32)
    case missingParent(String, UInt32, UInt32)
    case morphologyCycle(String, UInt32)
    case invalidSynapse(String)
    case capacityExceeded(String)
    case invalidMolecularNetwork(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(value): return "Unsupported model schema \(value)."
        case let .duplicateName(value): return "Duplicate model name: \(value)."
        case let .duplicateIdentifier(value): return "Duplicate identifier: \(value)."
        case let .unknownReference(value): return "Unknown model reference: \(value)."
        case let .emptyMorphology(value): return "Morphology \(value) is empty."
        case let .duplicateMorphologyNode(value): return "Morphology \(value) contains duplicate node IDs."
        case let .invalidRootCount(value, count): return "Morphology \(value) contains \(count) roots; exactly one is required."
        case let .invalidRadius(value, id): return "Morphology \(value) node \(id) has an invalid radius."
        case let .missingParent(value, id, parent): return "Morphology \(value) node \(id) references missing parent \(parent)."
        case let .morphologyCycle(value, id): return "Morphology \(value) contains a cycle at node \(id)."
        case let .invalidSynapse(value): return "Invalid synapse: \(value)."
        case let .capacityExceeded(value): return "Configured tile capacity exceeded: \(value)."
        case let .invalidMolecularNetwork(value): return "Invalid molecular network: \(value)."
        }
    }
}
