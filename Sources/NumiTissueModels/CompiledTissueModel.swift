import Foundation
import NumiTissueCore

@frozen
public struct CompiledTissueModel: Sendable {
    public var configuration: NumiTissueConfiguration
    public var manifest: ExecutableManifest
    public var allocation: RuntimeAllocationPlan
    public var sourceMetadata: [String: String]

    public var tileCoordinates: [TileCoordinate]
    public var tileHeaders: [GPUTileHeader]
    public var tileMembership: [CompiledTileMembership]

    public var cells: [GPUCellState]
    public var cellPrograms: [GPUCellProgram]
    public var neuriteSegments: [GPUNeuriteSegment]
    public var compartments: [GPUCompartmentState]
    public var compartmentAdjacency: [GPUCompartmentAdjacency]
    public var neurons: [GPUCompiledNeuron]
    public var neuronRouting: [GPUNeuronRouting]
    public var morphologyLevelOffsets: [UInt32]
    public var morphologyLevelIndices: [UInt32]
    public var morphologyChildIndices: [UInt32]

    public var synapses: [GPUSynapseState]
    public var synapseParameters: [GPUSynapseParameter]
    public var outgoingRoutes: [GPULongRangeRoute]

    public var fieldVoxels: [GPUFieldVoxel]
    public var fieldParameters: [GPUFieldParameter]

    public var mechanismSets: [GPUMechanismSet]
    public var channelParameters: [GPUChannelParameter]

    public var regulatoryPrograms: [GPURegulatoryProgram]
    public var regulatoryMatrix: [Float4]
    public var regulatoryBiases: [Float]
    public var fateTransitions: [GPUFateTransition]
    public var growthPrograms: [GPUGrowthProgram]
    public var glialPrograms: [GPUGlialProgram]

    public var microdomainHeaders: [GPUMicrodomainHeader]
    public var molecularSpecies: [GPUMolecularSpeciesState]
    public var molecularReactions: [GPUMolecularReaction]

    public var populations: [CompiledPopulation]
    public var populationTable: [GPUCompiledPopulation]
    public var populationMembers: [UInt32]

    public init(
        configuration: NumiTissueConfiguration,
        manifest: ExecutableManifest,
        allocation: RuntimeAllocationPlan,
        sourceMetadata: [String: String],
        tileCoordinates: [TileCoordinate],
        tileHeaders: [GPUTileHeader],
        tileMembership: [CompiledTileMembership],
        cells: [GPUCellState],
        cellPrograms: [GPUCellProgram],
        neuriteSegments: [GPUNeuriteSegment],
        compartments: [GPUCompartmentState],
        compartmentAdjacency: [GPUCompartmentAdjacency],
        neurons: [GPUCompiledNeuron],
        neuronRouting: [GPUNeuronRouting],
        morphologyLevelOffsets: [UInt32],
        morphologyLevelIndices: [UInt32],
        morphologyChildIndices: [UInt32],
        synapses: [GPUSynapseState],
        synapseParameters: [GPUSynapseParameter],
        outgoingRoutes: [GPULongRangeRoute],
        fieldVoxels: [GPUFieldVoxel],
        fieldParameters: [GPUFieldParameter],
        mechanismSets: [GPUMechanismSet],
        channelParameters: [GPUChannelParameter],
        regulatoryPrograms: [GPURegulatoryProgram],
        regulatoryMatrix: [Float4],
        regulatoryBiases: [Float],
        fateTransitions: [GPUFateTransition],
        growthPrograms: [GPUGrowthProgram],
        glialPrograms: [GPUGlialProgram],
        microdomainHeaders: [GPUMicrodomainHeader],
        molecularSpecies: [GPUMolecularSpeciesState],
        molecularReactions: [GPUMolecularReaction],
        populations: [CompiledPopulation],
        populationTable: [GPUCompiledPopulation],
        populationMembers: [UInt32]
    ) {
        self.configuration = configuration
        self.manifest = manifest
        self.allocation = allocation
        self.sourceMetadata = sourceMetadata
        self.tileCoordinates = tileCoordinates
        self.tileHeaders = tileHeaders
        self.tileMembership = tileMembership
        self.cells = cells
        self.cellPrograms = cellPrograms
        self.neuriteSegments = neuriteSegments
        self.compartments = compartments
        self.compartmentAdjacency = compartmentAdjacency
        self.neurons = neurons
        self.neuronRouting = neuronRouting
        self.morphologyLevelOffsets = morphologyLevelOffsets
        self.morphologyLevelIndices = morphologyLevelIndices
        self.morphologyChildIndices = morphologyChildIndices
        self.synapses = synapses
        self.synapseParameters = synapseParameters
        self.outgoingRoutes = outgoingRoutes
        self.fieldVoxels = fieldVoxels
        self.fieldParameters = fieldParameters
        self.mechanismSets = mechanismSets
        self.channelParameters = channelParameters
        self.regulatoryPrograms = regulatoryPrograms
        self.regulatoryMatrix = regulatoryMatrix
        self.regulatoryBiases = regulatoryBiases
        self.fateTransitions = fateTransitions
        self.growthPrograms = growthPrograms
        self.glialPrograms = glialPrograms
        self.microdomainHeaders = microdomainHeaders
        self.molecularSpecies = molecularSpecies
        self.molecularReactions = molecularReactions
        self.populations = populations
        self.populationTable = populationTable
        self.populationMembers = populationMembers
    }
}
