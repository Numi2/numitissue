import Foundation
import NumiTissueCore

public struct TissueModelCompiler: Sendable {
    public let configuration: NumiTissueConfiguration

    public init(configuration: NumiTissueConfiguration = .production) {
        self.configuration = configuration
    }

    public func compile(_ model: TissueModel) throws -> CompiledTissueModel {
        try configuration.validate()
        try validate(model)

        let morphologyByName = Dictionary(
            uniqueKeysWithValues: model.morphologies.map { ($0.name, $0) }
        )
        let prototypeByName = Dictionary(
            uniqueKeysWithValues: model.cellPrototypes.map { ($0.name, $0) }
        )
        let mechanismIndexByName = Dictionary(
            uniqueKeysWithValues: model.mechanismSets.enumerated().map {
                ($0.element.name, UInt32($0.offset))
            }
        )
        let regulatoryIndexByName = Dictionary(
            uniqueKeysWithValues: model.regulatoryPrograms.enumerated().map {
                ($0.element.name, UInt32($0.offset))
            }
        )
        let glialIndexByName = Dictionary(
            uniqueKeysWithValues: model.glialPrograms.enumerated().map {
                ($0.element.name, UInt32($0.offset))
            }
        )
        let synapsePrototypeByName = Dictionary(
            uniqueKeysWithValues: model.synapsePrototypes.map { ($0.name, $0) }
        )
        let synapseParameterIndexByName = Dictionary(
            uniqueKeysWithValues: model.synapsePrototypes.enumerated().map {
                ($0.element.name, UInt32($0.offset))
            }
        )
        let molecularNetworkByName = Dictionary(
            uniqueKeysWithValues: model.molecularNetworks.map { ($0.name, $0) }
        )

        let compiledMechanisms = compileMechanisms(model.mechanismSets)
        let fastQuantumMilliseconds = Float(configuration.scheduler.fastQuantumMicroseconds) / 1_000
        let synapseParameters = model.synapsePrototypes.map {
            GPUSynapseParameter(
                prototype: $0,
                fastQuantumMilliseconds: fastQuantumMilliseconds
            )
        }
        let fieldDescriptors = completeFieldSpecies(model.fieldSpecies)
        let fieldParameters = fieldDescriptors.map {
            GPUFieldParameter(
                species: $0,
                dtMilliseconds: Float(configuration.scheduler.eventBlockMicroseconds) / 1_000,
                voxelWidthMicrometers: configuration.tile.fieldVoxelWidthMicrometers
            )
        }
        let compiledRegulation = compileRegulatoryPrograms(model.regulatoryPrograms)
        let glialPrograms = model.glialPrograms.map(GPUGlialProgram.init)

        let orderedCells = model.cells.sorted {
            let lhsTile = tileCoordinate(for: $0.positionMicrometers)
            let rhsTile = tileCoordinate(for: $1.positionMicrometers)
            return lhsTile == rhsTile ? $0.id < $1.id : lhsTile < rhsTile
        }
        let tileCoordinates = deriveTileCoordinates(from: orderedCells)
        let tileIndexByCoordinate = Dictionary(
            uniqueKeysWithValues: tileCoordinates.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        var tileMembership = tileCoordinates.map(CompiledTileMembership.init)

        let cellProgramsAndIndices = try compileCellPrograms(
            model.cellPrototypes,
            mechanismIndexByName: mechanismIndexByName,
            regulatoryIndexByName: regulatoryIndexByName,
            glialIndexByName: glialIndexByName
        )

        var cells: [GPUCellState] = []
        var segments: [GPUNeuriteSegment] = []
        var compartments: [GPUCompartmentState] = []
        var compartmentAdjacency: [GPUCompartmentAdjacency] = []
        var neurons: [GPUCompiledNeuron] = []
        var neuronRouting: [GPUNeuronRouting] = []
        var morphologyLevelOffsets: [UInt32] = []
        var morphologyLevelIndices: [UInt32] = []
        var morphologyChildIndices: [UInt32] = []

        var cellIndexByID: [CellID: UInt32] = [:]
        var cellTileIndex: [CellID: Int] = [:]
        var cellCompartmentMap: [CellID: [UInt32: UInt32]] = [:]
        var cellOriginalParentMap: [CellID: [UInt32: UInt32?]] = [:]
        var cellSpikeSource: [CellID: UInt32] = [:]
        var neuronIndexBySpikeSource: [UInt32: UInt32] = [:]

        for instance in orderedCells {
            guard let prototype = prototypeByName[instance.prototype] else {
                throw ModelValidationError.unknownReference(
                    "cell prototype \(instance.prototype)"
                )
            }
            guard let programIndex = cellProgramsAndIndices.indexByPrototype[instance.prototype] else {
                throw ModelValidationError.unknownReference(
                    "compiled cell program \(instance.prototype)"
                )
            }
            let coordinate = tileCoordinate(for: instance.positionMicrometers)
            guard let tileIndex = tileIndexByCoordinate[coordinate] else {
                throw ModelValidationError.unknownReference("tile \(coordinate)")
            }
            let fidelity = instance.fidelityOverride ?? prototype.defaultFidelity
            let globalCellIndex = try checkedUInt32(cells.count, "cell index")
            cellIndexByID[instance.id] = globalCellIndex
            cellTileIndex[instance.id] = tileIndex

            var cell = GPUCellState(
                id: instance.id,
                lineage: instance.lineage,
                kind: prototype.kind,
                position: instance.positionMicrometers,
                radius: prototype.radiusMicrometers,
                fidelity: fidelity
            )
            cell.orientation = normalizeQuaternion(instance.orientation)
            cell.identity1.w = programIndex
            cells.append(cell)
            tileMembership[tileIndex].cellIndices.append(globalCellIndex)

            guard fidelity.rawValue >= FidelityLevel.reducedNeuron.rawValue,
                  prototype.kind == .excitatoryNeuron ||
                    prototype.kind == .inhibitoryInterneuron else {
                continue
            }

            let sourceMorphology: NeuronMorphology
            if let morphologyName = prototype.morphology {
                guard let morphology = morphologyByName[morphologyName] else {
                    throw ModelValidationError.unknownReference(
                        "morphology \(morphologyName)"
                    )
                }
                sourceMorphology = morphology
            } else {
                sourceMorphology = Self.somaMorphology(
                    name: "\(prototype.name)-soma",
                    radius: prototype.radiusMicrometers
                )
            }
            let morphology = fidelity == .reducedNeuron
                ? reduce(sourceMorphology, maximumCompartments: 8)
                : sourceMorphology
            let ordered = try morphology.orderedNodesAndLevels()
            let localIndexByNode = Dictionary(
                uniqueKeysWithValues: ordered.nodes.enumerated().map {
                    ($0.element.id, UInt32($0.offset))
                }
            )
            let originalParents = Dictionary(
                uniqueKeysWithValues: sourceMorphology.nodes.map {
                    ($0.id, $0.parent)
                }
            )
            cellOriginalParentMap[instance.id] = originalParents

            let compartmentOffset = try checkedUInt32(
                compartments.count,
                "compartment offset"
            )
            let segmentOffset = try checkedUInt32(segments.count, "segment offset")
            let neuronIndex = try checkedUInt32(neurons.count, "neuron index")
            var nodeToCompartment: [UInt32: UInt32] = [:]

            for (localIndex, node) in ordered.nodes.enumerated() {
                let globalCompartment = compartmentOffset + UInt32(localIndex)
                let globalSegment = segmentOffset + UInt32(localIndex)
                nodeToCompartment[node.id] = globalCompartment

                let parentLocal = node.parent.flatMap { localIndexByNode[$0] }
                let parentGlobal = parentLocal.map { compartmentOffset + $0 } ?? UInt32.max
                let parentPosition = parentLocal.map {
                    ordered.nodes[Int($0)].positionMicrometers
                } ?? node.positionMicrometers

                let localStart = parentPosition
                let localEnd = node.positionMicrometers
                let length = max(
                    length3(localEnd - localStart),
                    node.radiusMicrometers * 0.5
                )
                let axialConductance: Float = parentGlobal == UInt32.max
                    ? 0
                    : 100 * Float.pi * node.radiusMicrometers * node.radiusMicrometers /
                        (150 * length)
                let membraneArea: Float = parentGlobal == UInt32.max
                    ? 4 * Float.pi * node.radiusMicrometers * node.radiusMicrometers
                    : 2 * Float.pi * node.radiusMicrometers * length

                var compartment = GPUCompartmentState(
                    voltageMillivolts: prototype.leakReversalMillivolts
                )
                compartment.passive = Float4(
                    max(prototype.membraneCapacitance * membraneArea * 1e-5, 1e-6),
                    prototype.leakConductance * membraneArea * 1e-5,
                    prototype.leakReversalMillivolts,
                    axialConductance
                )
                compartment.topology = UInt4(
                    parentGlobal,
                    0,
                    0,
                    UInt32(level(of: localIndex, offsets: ordered.levelOffsets))
                )
                let mechanismIndex = prototype.mechanismSet
                    .flatMap { mechanismIndexByName[$0] } ?? UInt32.max
                compartment.mechanism = UInt4(
                    mechanismIndex,
                    globalSegment,
                    neuronIndex,
                    0
                )
                compartments.append(compartment)
                compartmentAdjacency.append(.init())

                let worldStart = instance.positionMicrometers +
                    rotate(localStart, by: cell.orientation)
                let worldEnd = instance.positionMicrometers +
                    rotate(localEnd, by: cell.orientation)
                var segment = GPUNeuriteSegment(
                    start: worldStart,
                    end: worldEnd,
                    radius: node.radiusMicrometers,
                    parent: parentLocal.map { segmentOffset + $0 } ?? UInt32.max,
                    cellIndex: globalCellIndex,
                    kind: node.kind
                )
                segment.topology.w = globalCompartment
                segment.electrical = Float4(
                    axialConductance,
                    compartment.passive.x,
                    0,
                    1
                )
                segments.append(segment)
                tileMembership[tileIndex].segmentIndices.append(globalSegment)
                tileMembership[tileIndex].compartmentIndices.append(globalCompartment)
            }

            compileChildAdjacency(
                orderedNodes: ordered.nodes,
                localIndexByNode: localIndexByNode,
                compartmentOffset: compartmentOffset,
                compartments: &compartments,
                childIndices: &morphologyChildIndices
            )

            let levelOffsetStart = try checkedUInt32(
                morphologyLevelOffsets.count,
                "morphology level offset"
            )
            let levelIndexStart = try checkedUInt32(
                morphologyLevelIndices.count,
                "morphology level index"
            )
            morphologyLevelOffsets.append(
                contentsOf: ordered.levelOffsets.map { levelIndexStart + $0 }
            )
            morphologyLevelIndices.append(
                contentsOf: (0..<ordered.nodes.count).map {
                    compartmentOffset + UInt32($0)
                }
            )

            neurons.append(
                .init(
                    compartmentOffset: compartmentOffset,
                    compartmentCount: UInt32(ordered.nodes.count),
                    levelOffset: levelOffsetStart,
                    levelCount: UInt32(max(ordered.levelOffsets.count - 1, 0)),
                    cellIndex: globalCellIndex,
                    population: instance.population
                )
            )
            neuronRouting.append(.init())
            cellCompartmentMap[instance.id] = nodeToCompartment
            cellSpikeSource[instance.id] = compartmentOffset
            neuronIndexBySpikeSource[compartmentOffset] = neuronIndex
        }

        let compiledSynapses = try compileSynapses(
            connections: model.synapses,
            synapsePrototypeByName: synapsePrototypeByName,
            synapseParameterIndexByName: synapseParameterIndexByName,
            cellSpikeSource: cellSpikeSource,
            cellCompartmentMap: cellCompartmentMap,
            cellOriginalParentMap: cellOriginalParentMap,
            cellTileIndex: cellTileIndex,
            fastQuantumMilliseconds: fastQuantumMilliseconds,
            tileMembership: &tileMembership,
            compartmentCount: compartments.count,
            neuronIndexBySpikeSource: neuronIndexBySpikeSource,
            neuronRouting: &neuronRouting
        )
        compartmentAdjacency = compiledSynapses.compartmentAdjacency

        let voxelsPerTile = try checkedVoxelCount(configuration.tile.fieldGridEdge)
        let fieldVoxels = initializeFields(
            tileCount: tileCoordinates.count,
            voxelsPerTile: voxelsPerTile,
            descriptors: fieldDescriptors
        )

        let compiledMolecules = try compileMolecularDomains(
            domains: model.molecularDomains,
            networkByName: molecularNetworkByName,
            cellIndexByID: cellIndexByID,
            cellTileIndex: cellTileIndex,
            cellCompartmentMap: cellCompartmentMap,
            voxelsPerTile: voxelsPerTile,
            tileMembership: &tileMembership
        )

        try validateTileCapacities(tileMembership)
        let tileHeaders = try makeTileHeaders(
            coordinates: tileCoordinates,
            membership: tileMembership,
            voxelsPerTile: voxelsPerTile
        )
        let compiledPopulations = compilePopulations(
            descriptors: model.populations,
            cells: orderedCells,
            cellIndexByID: cellIndexByID
        )
        let allocation = try makeAllocationPlan(
            tileCount: tileCoordinates.count,
            voxelsPerTile: voxelsPerTile,
            initialSynapseCount: compiledSynapses.synapses.count
        )
        if let limit = configuration.maximumResidentBytes,
           allocation.estimatedTransactionalBytes > limit {
            throw ModelValidationError.capacityExceeded(
                "estimated transactional allocation \(allocation.estimatedTransactionalBytes) bytes exceeds configured limit \(limit) bytes"
            )
        }

        let modelHash = try stableHash(model)
        let sections = makeSections(
            tileHeaders: tileHeaders.count,
            cells: cells.count,
            cellPrograms: cellProgramsAndIndices.programs.count,
            segments: segments.count,
            compartments: compartments.count,
            compartmentAdjacency: compartmentAdjacency.count,
            neurons: neurons.count,
            levelIndices: morphologyLevelIndices.count,
            childIndices: morphologyChildIndices.count,
            synapses: compiledSynapses.synapses.count,
            synapseParameters: synapseParameters.count,
            routes: compiledSynapses.routes.count,
            fields: fieldVoxels.count,
            mechanisms: compiledMechanisms.sets.count,
            channels: compiledMechanisms.channels.count,
            microdomains: compiledMolecules.headers.count,
            molecularSpecies: compiledMolecules.species.count,
            molecularReactions: compiledMolecules.reactions.count,
            populations: compiledPopulations.table.count,
            populationMembers: compiledPopulations.members.count
        )
        let manifest = ExecutableManifest(
            modelName: model.name,
            modelHash: modelHash,
            tileCount: UInt32(tileCoordinates.count),
            sections: sections
        )

        return CompiledTissueModel(
            configuration: configuration,
            manifest: manifest,
            allocation: allocation,
            sourceMetadata: model.metadata,
            tileCoordinates: tileCoordinates,
            tileHeaders: tileHeaders,
            tileMembership: tileMembership,
            cells: cells,
            cellPrograms: cellProgramsAndIndices.programs,
            neuriteSegments: segments,
            compartments: compartments,
            compartmentAdjacency: compartmentAdjacency,
            neurons: neurons,
            neuronRouting: neuronRouting,
            morphologyLevelOffsets: morphologyLevelOffsets,
            morphologyLevelIndices: morphologyLevelIndices,
            morphologyChildIndices: morphologyChildIndices,
            synapses: compiledSynapses.synapses,
            synapseParameters: synapseParameters,
            outgoingRoutes: compiledSynapses.routes,
            fieldVoxels: fieldVoxels,
            fieldParameters: fieldParameters,
            mechanismSets: compiledMechanisms.sets,
            channelParameters: compiledMechanisms.channels,
            regulatoryPrograms: compiledRegulation.programs,
            regulatoryMatrix: compiledRegulation.matrix,
            regulatoryBiases: compiledRegulation.biases,
            fateTransitions: compiledRegulation.transitions,
            growthPrograms: compiledRegulation.growth,
            glialPrograms: glialPrograms,
            microdomainHeaders: compiledMolecules.headers,
            molecularSpecies: compiledMolecules.species,
            molecularReactions: compiledMolecules.reactions,
            populations: compiledPopulations.populations,
            populationTable: compiledPopulations.table,
            populationMembers: compiledPopulations.members
        )
    }
}
