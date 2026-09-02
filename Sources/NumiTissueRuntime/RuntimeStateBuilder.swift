import Foundation
import NumiTissueCore

public struct RuntimeCellBlueprint: Sendable, Hashable, Codable {
    public var id: CellID
    public var lineage: LineageID
    public var tile: TileCoordinate
    public var typeIndex: UInt16
    public var developmentalState: UInt16
    public var fidelity: FidelityLevel
    public var position: Float4
    public var orientation: Float4
    public var semiAxes: Float4
    public var regulatoryState: [Float]
    public var energyReserve: Float

    public init(
        id: CellID,
        lineage: LineageID,
        tile: TileCoordinate,
        typeIndex: UInt16,
        developmentalState: UInt16 = 0,
        fidelity: FidelityLevel = .cellAgent,
        position: Float4,
        orientation: Float4 = Float4(0, 0, 0, 1),
        semiAxes: Float4 = Float4(5, 5, 5, 0),
        regulatoryState: [Float] = Array(repeating: 0, count: 32),
        energyReserve: Float = 1
    ) {
        self.id = id
        self.lineage = lineage
        self.tile = tile
        self.typeIndex = typeIndex
        self.developmentalState = developmentalState
        self.fidelity = fidelity
        self.position = position
        self.orientation = orientation
        self.semiAxes = semiAxes
        self.regulatoryState = regulatoryState
        self.energyReserve = energyReserve
    }
}

public struct RuntimeSegmentBlueprint: Sendable, Hashable, Codable {
    public var id: SegmentID
    public var parentLocalIndex: Int?
    public var type: UInt16
    public var flags: UInt16
    public var start: Float4
    public var end: Float4
    public var radiusMicrometers: Float
    public var myelinFraction: Float
    public var growthRateMicrometersPerSecond: Float
    public var structuralScore: Float

    public init(
        id: SegmentID,
        parentLocalIndex: Int? = nil,
        type: UInt16,
        flags: UInt16 = 0,
        start: Float4,
        end: Float4,
        radiusMicrometers: Float,
        myelinFraction: Float = 0,
        growthRateMicrometersPerSecond: Float = 0,
        structuralScore: Float = 0
    ) {
        self.id = id
        self.parentLocalIndex = parentLocalIndex
        self.type = type
        self.flags = flags
        self.start = start
        self.end = end
        self.radiusMicrometers = radiusMicrometers
        self.myelinFraction = myelinFraction
        self.growthRateMicrometersPerSecond = growthRateMicrometersPerSecond
        self.structuralScore = structuralScore
    }
}

public struct RuntimeCompartmentBlueprint: Sendable, Hashable, Codable {
    public var id: CompartmentID
    public var parentLocalIndex: Int?
    public var voltageMillivolts: Float
    public var capacitanceNanofarads: Float
    public var axialConductanceMicrosiemens: Float
    public var mechanismState: [Float]
    public var flags: UInt32

    public init(
        id: CompartmentID,
        parentLocalIndex: Int? = nil,
        voltageMillivolts: Float = -65,
        capacitanceNanofarads: Float,
        axialConductanceMicrosiemens: Float = 0,
        mechanismState: [Float] = Array(repeating: 0, count: 16),
        flags: UInt32 = 0
    ) {
        self.id = id
        self.parentLocalIndex = parentLocalIndex
        self.voltageMillivolts = voltageMillivolts
        self.capacitanceNanofarads = capacitanceNanofarads
        self.axialConductanceMicrosiemens = axialConductanceMicrosiemens
        self.mechanismState = mechanismState
        self.flags = flags
    }
}

public struct RuntimeNeuronBlueprint: Sendable, Hashable, Codable {
    public var cellID: CellID
    public var segments: [RuntimeSegmentBlueprint]
    public var compartments: [RuntimeCompartmentBlueprint]
    public var segmentCompartmentLocalIndices: [Int?]

    public init(
        cellID: CellID,
        segments: [RuntimeSegmentBlueprint],
        compartments: [RuntimeCompartmentBlueprint],
        segmentCompartmentLocalIndices: [Int?]
    ) {
        self.cellID = cellID
        self.segments = segments
        self.compartments = compartments
        self.segmentCompartmentLocalIndices = segmentCompartmentLocalIndices
    }
}

public struct RuntimeSynapseBlueprint: Sendable, Hashable, Codable {
    public var id: SynapseID
    public var sourceCompartmentID: CompartmentID
    public var targetCompartmentID: CompartmentID
    public var parameterIndex: UInt16
    public var flags: UInt16
    public var delayTicks: UInt32
    public var weight: Float
    public var utilization: Float
    public var resources: Float

    public init(
        id: SynapseID,
        sourceCompartmentID: CompartmentID,
        targetCompartmentID: CompartmentID,
        parameterIndex: UInt16 = 0,
        flags: UInt16 = 0,
        delayTicks: UInt32,
        weight: Float,
        utilization: Float = 0.2,
        resources: Float = 1
    ) {
        self.id = id
        self.sourceCompartmentID = sourceCompartmentID
        self.targetCompartmentID = targetCompartmentID
        self.parameterIndex = parameterIndex
        self.flags = flags
        self.delayTicks = delayTicks
        self.weight = weight
        self.utilization = utilization
        self.resources = resources
    }
}

public struct RuntimeMicrodomainBlueprint: Sendable, Hashable, Codable {
    public var id: MicrodomainID
    public var ownerCellID: CellID
    public var ownerCompartmentID: CompartmentID?
    public var reactionNetworkIndex: UInt16
    public var solverKind: UInt8
    public var flags: UInt8
    public var species: [Float]
    public var volumeFemtoliters: Float
    public var temperatureKelvin: Float

    public init(
        id: MicrodomainID,
        ownerCellID: CellID,
        ownerCompartmentID: CompartmentID? = nil,
        reactionNetworkIndex: UInt16,
        solverKind: UInt8,
        flags: UInt8 = 0,
        species: [Float],
        volumeFemtoliters: Float,
        temperatureKelvin: Float = 310.15
    ) {
        self.id = id
        self.ownerCellID = ownerCellID
        self.ownerCompartmentID = ownerCompartmentID
        self.reactionNetworkIndex = reactionNetworkIndex
        self.solverKind = solverKind
        self.flags = flags
        self.species = species
        self.volumeFemtoliters = volumeFemtoliters
        self.temperatureKelvin = temperatureKelvin
    }
}

public struct RuntimeFieldInitialization: Sendable, Hashable, Codable {
    public var concentrations: SIMD12<Float>
    public var diffusionScales: SIMD12<Float>

    public init(
        concentrations: SIMD12<Float> = SIMD12(3.5, 1.2, 0, 0.2, 1, 0, 7.4, 1, 0, 0, 0, 1),
        diffusionScales: SIMD12<Float> = SIMD12(0.001, 0.001, 0.002, 0.0002, 0.0001, 0.0002, 0.0001, 0.00005, 0.0001, 0.0001, 0.00005, 0)
    ) {
        self.concentrations = concentrations
        self.diffusionScales = diffusionScales
    }
}

public struct TissueRuntimeStateBuilder: Sendable {
    public var time: TissueTime
    public var epoch: UInt64
    public var fieldInitialization: RuntimeFieldInitialization
    public var fieldResolution: Int
    public var fieldChannels: Int

    private var tiles = Set<TileCoordinate>()
    private var cells: [RuntimeCellBlueprint] = []
    private var neurons: [CellID: RuntimeNeuronBlueprint] = [:]
    private var synapses: [RuntimeSynapseBlueprint] = []
    private var microdomains: [RuntimeMicrodomainBlueprint] = []

    public init(
        time: TissueTime = TissueTime(),
        epoch: UInt64 = 0,
        fieldInitialization: RuntimeFieldInitialization = RuntimeFieldInitialization(),
        fieldResolution: Int = 32,
        fieldChannels: Int = 12
    ) {
        self.time = time
        self.epoch = epoch
        self.fieldInitialization = fieldInitialization
        self.fieldResolution = fieldResolution
        self.fieldChannels = fieldChannels
    }

    public mutating func addTile(_ coordinate: TileCoordinate) { tiles.insert(coordinate) }

    public mutating func addCell(_ cell: RuntimeCellBlueprint) throws {
        guard !cells.contains(where: { $0.id == cell.id }) else { throw RuntimeBuilderError.duplicateCell(cell.id.rawValue) }
        guard cell.regulatoryState.count <= 32 else { throw RuntimeBuilderError.regulatoryStateTooLarge(cell.id.rawValue) }
        tiles.insert(cell.tile)
        cells.append(cell)
    }

    public mutating func addNeuron(_ neuron: RuntimeNeuronBlueprint) throws {
        guard cells.contains(where: { $0.id == neuron.cellID }) else { throw RuntimeBuilderError.unknownCell(neuron.cellID.rawValue) }
        guard neurons[neuron.cellID] == nil else { throw RuntimeBuilderError.duplicateNeuron(neuron.cellID.rawValue) }
        guard neuron.segments.count == neuron.segmentCompartmentLocalIndices.count else { throw RuntimeBuilderError.segmentCompartmentCountMismatch }
        for index in neuron.segments.indices {
            if let parent = neuron.segments[index].parentLocalIndex, !(0..<neuron.segments.count).contains(parent) { throw RuntimeBuilderError.invalidLocalParent(index) }
            if let compartment = neuron.segmentCompartmentLocalIndices[index], !(0..<neuron.compartments.count).contains(compartment) { throw RuntimeBuilderError.invalidLocalCompartment(index) }
        }
        for index in neuron.compartments.indices {
            if let parent = neuron.compartments[index].parentLocalIndex, !(0..<neuron.compartments.count).contains(parent) { throw RuntimeBuilderError.invalidLocalParent(index) }
        }
        neurons[neuron.cellID] = neuron
    }

    public mutating func addSynapse(_ synapse: RuntimeSynapseBlueprint) throws {
        guard !synapses.contains(where: { $0.id == synapse.id }) else { throw RuntimeBuilderError.duplicateSynapse(synapse.id.rawValue) }
        synapses.append(synapse)
    }

    public mutating func addMicrodomain(_ microdomain: RuntimeMicrodomainBlueprint) throws {
        guard !microdomains.contains(where: { $0.id == microdomain.id }) else { throw RuntimeBuilderError.duplicateMicrodomain(microdomain.id.rawValue) }
        microdomains.append(microdomain)
    }

    public func build(capacityScale: Double = 1.25) throws -> TissueRuntimeState {
        guard fieldResolution > 0, fieldResolution <= 128, fieldChannels == 12 else { throw RuntimeBuilderError.invalidFieldShape }
        let orderedTiles = tiles.sorted(by: tileOrder)
        let tileIndex = Dictionary(uniqueKeysWithValues: orderedTiles.enumerated().map { ($0.element, UInt32($0.offset)) })
        let orderedCells = cells.sorted {
            let lhsTile = tileIndex[$0.tile] ?? 0
            let rhsTile = tileIndex[$1.tile] ?? 0
            return lhsTile == rhsTile ? $0.id.rawValue < $1.id.rawValue : lhsTile < rhsTile
        }
        let cellIndex = Dictionary(uniqueKeysWithValues: orderedCells.enumerated().map { ($0.element.id, UInt32($0.offset)) })

        var state = TissueRuntimeState(time: time, epoch: epoch)
        state.tiles = orderedTiles.enumerated().map { index, coordinate in
            TileRuntimeState(id: TileID(rawValue: UInt64(index + 1)), coordinate: coordinate)
        }
        state.cells.reserveCapacity(orderedCells.count)
        state.regulatoryState.reserveCapacity(orderedCells.count * 32)

        for cell in orderedCells {
            let regulatoryLower = UInt32(state.regulatoryState.count)
            state.regulatoryState.append(contentsOf: cell.regulatoryState)
            if cell.regulatoryState.count < 32 { state.regulatoryState.append(contentsOf: repeatElement(0, count: 32 - cell.regulatoryState.count)) }
            var runtime = RuntimeCellState(
                id: cell.id,
                lineage: cell.lineage,
                tileIndex: tileIndex[cell.tile]!,
                typeIndex: cell.typeIndex,
                developmentalState: cell.developmentalState,
                fidelity: cell.fidelity,
                position: cell.position,
                orientation: cell.orientation,
                semiAxes: cell.semiAxes
            )
            runtime.regulatoryRange = RuntimeRange(lowerBound: regulatoryLower, count: 32)
            runtime.energyReserve = cell.energyReserve
            state.cells.append(runtime)
        }

        var compartmentGlobalByID: [CompartmentID: UInt32] = [:]
        var compartmentTileByID: [CompartmentID: UInt32] = [:]
        for (tileNumber, coordinate) in orderedTiles.enumerated() {
            let tileCells = orderedCells.filter { $0.tile == coordinate }
            let segmentStart = UInt32(state.segments.count)
            let compartmentStart = UInt32(state.compartments.count)
            for cell in tileCells {
                guard let neuron = neurons[cell.id] else { continue }
                let globalCell = cellIndex[cell.id]!
                let segmentBase = UInt32(state.segments.count)
                let compartmentBase = UInt32(state.compartments.count)

                for (local, blueprint) in neuron.compartments.enumerated() {
                    let parent = blueprint.parentLocalIndex.map { compartmentBase + UInt32($0) } ?? RuntimeCompartmentState.invalidIndex
                    let mechanismLower = UInt32(state.mechanismState.count)
                    state.mechanismState.append(contentsOf: blueprint.mechanismState)
                    var flags = blueprint.flags
                    flags = (flags & 0xFF00_FFFF) | (UInt32(min(depth(local, in: neuron.compartments), 255)) << 16)
                    let runtime = RuntimeCompartmentState(
                        id: blueprint.id,
                        neuronIndex: globalCell,
                        parentIndex: parent,
                        mechanismRange: RuntimeRange(lowerBound: mechanismLower, count: UInt32(blueprint.mechanismState.count)),
                        voltageMillivolts: blueprint.voltageMillivolts,
                        previousVoltageMillivolts: blueprint.voltageMillivolts,
                        capacitanceNanofarads: blueprint.capacitanceNanofarads,
                        axialConductanceMicrosiemens: blueprint.axialConductanceMicrosiemens,
                        flags: flags
                    )
                    let global = compartmentBase + UInt32(local)
                    compartmentGlobalByID[blueprint.id] = global
                    compartmentTileByID[blueprint.id] = UInt32(tileNumber)
                    state.compartments.append(runtime)
                }

                var childLists = Array(repeating: [Int](), count: neuron.segments.count)
                for (index, segment) in neuron.segments.enumerated() {
                    if let parent = segment.parentLocalIndex { childLists[parent].append(index) }
                }
                for (local, blueprint) in neuron.segments.enumerated() {
                    let parent = blueprint.parentLocalIndex.map { segmentBase + UInt32($0) } ?? RuntimeSegmentState.invalidIndex
                    let children = childLists[local].sorted()
                    let firstChild = children.first.map { segmentBase + UInt32($0) } ?? RuntimeSegmentState.invalidIndex
                    let nextSibling: UInt32
                    if let parentLocal = blueprint.parentLocalIndex,
                       let position = childLists[parentLocal].sorted().firstIndex(of: local),
                       position + 1 < childLists[parentLocal].count {
                        nextSibling = segmentBase + UInt32(childLists[parentLocal].sorted()[position + 1])
                    } else { nextSibling = RuntimeSegmentState.invalidIndex }
                    let compartment = neuron.segmentCompartmentLocalIndices[local].map { compartmentBase + UInt32($0) } ?? RuntimeSegmentState.invalidIndex
                    state.segments.append(RuntimeSegmentState(
                        id: blueprint.id,
                        cellIndex: globalCell,
                        parentSegmentIndex: parent,
                        firstChildIndex: firstChild,
                        nextSiblingIndex: nextSibling,
                        compartmentIndex: compartment,
                        type: blueprint.type,
                        flags: blueprint.flags,
                        start: blueprint.start,
                        end: blueprint.end,
                        radiusMicrometers: blueprint.radiusMicrometers,
                        myelinFraction: blueprint.myelinFraction,
                        growthRateMicrometersPerSecond: blueprint.growthRateMicrometersPerSecond,
                        structuralScore: blueprint.structuralScore
                    ))
                }
            }
            state.tiles[tileNumber].segmentRange = RuntimeRange(lowerBound: segmentStart, count: UInt32(state.segments.count) - segmentStart)
            state.tiles[tileNumber].compartmentRange = RuntimeRange(lowerBound: compartmentStart, count: UInt32(state.compartments.count) - compartmentStart)
        }

        let orderedSynapses = try synapses.sorted { lhs, rhs in
            guard let lhsTile = compartmentTileByID[lhs.targetCompartmentID], let rhsTile = compartmentTileByID[rhs.targetCompartmentID] else { return lhs.id.rawValue < rhs.id.rawValue }
            return lhsTile == rhsTile ? lhs.id.rawValue < rhs.id.rawValue : lhsTile < rhsTile
        }
        for blueprint in orderedSynapses {
            guard let source = compartmentGlobalByID[blueprint.sourceCompartmentID] else { throw RuntimeBuilderError.unknownCompartment(blueprint.sourceCompartmentID.rawValue) }
            guard let target = compartmentGlobalByID[blueprint.targetCompartmentID] else { throw RuntimeBuilderError.unknownCompartment(blueprint.targetCompartmentID.rawValue) }
            state.synapses.append(RuntimeSynapseState(
                id: blueprint.id,
                sourceRouteIndex: source,
                targetCompartmentIndex: target,
                parameterIndex: blueprint.parameterIndex,
                flags: blueprint.flags,
                delayTicks: blueprint.delayTicks,
                weight: blueprint.weight,
                shortTermUtilization: blueprint.utilization,
                shortTermResources: blueprint.resources
            ))
        }

        let voxelsPerTile = fieldResolution * fieldResolution * fieldResolution
        for tile in state.tiles.indices {
            let cellIndices = state.cells.indices.filter { state.cells[$0].tileIndex == UInt32(tile) }
            let lowerCell = cellIndices.first.map(UInt32.init) ?? 0
            state.tiles[tile].cellRange = RuntimeRange(lowerBound: lowerCell, count: UInt32(cellIndices.count))

            let synapseIndices = state.synapses.indices.filter { synapseIndex in
                let target = Int(state.synapses[synapseIndex].targetCompartmentIndex)
                return target < state.compartments.count && state.compartments[target].neuronIndex < UInt32(state.cells.count) && state.cells[Int(state.compartments[target].neuronIndex)].tileIndex == UInt32(tile)
            }
            state.tiles[tile].synapseRange = RuntimeRange(lowerBound: synapseIndices.first.map(UInt32.init) ?? 0, count: UInt32(synapseIndices.count))

            let fieldLower = UInt32(state.fields.count)
            state.fields.reserveCapacity(state.fields.count + voxelsPerTile * fieldChannels)
            for channel in 0..<fieldChannels {
                for _ in 0..<voxelsPerTile {
                    state.fields.append(RuntimeFieldValue(
                        concentration: fieldInitialization.concentrations[channel],
                        diffusionScale: fieldInitialization.diffusionScales[channel]
                    ))
                }
            }
            state.tiles[tile].fieldRange = RuntimeRange(lowerBound: fieldLower, count: UInt32(voxelsPerTile * fieldChannels))
        }

        let orderedMicrodomains = try microdomains.sorted { lhs, rhs in
            guard let lhsCell = cellIndex[lhs.ownerCellID], let rhsCell = cellIndex[rhs.ownerCellID] else { return lhs.id.rawValue < rhs.id.rawValue }
            let lhsTile = state.cells[Int(lhsCell)].tileIndex
            let rhsTile = state.cells[Int(rhsCell)].tileIndex
            return lhsTile == rhsTile ? lhs.id.rawValue < rhs.id.rawValue : lhsTile < rhsTile
        }
        for blueprint in orderedMicrodomains {
            guard let ownerCell = cellIndex[blueprint.ownerCellID] else { throw RuntimeBuilderError.unknownCell(blueprint.ownerCellID.rawValue) }
            let ownerCompartment = try blueprint.ownerCompartmentID.map { id -> UInt32 in
                guard let value = compartmentGlobalByID[id] else { throw RuntimeBuilderError.unknownCompartment(id.rawValue) }
                return value
            } ?? RuntimeMicrodomainState.invalidIndex
            let speciesLower = UInt32(state.molecularSpecies.count)
            state.molecularSpecies.append(contentsOf: blueprint.species)
            state.microdomains.append(RuntimeMicrodomainState(
                id: blueprint.id,
                ownerCellIndex: ownerCell,
                ownerCompartmentIndex: ownerCompartment,
                reactionNetworkIndex: blueprint.reactionNetworkIndex,
                solverKind: blueprint.solverKind,
                flags: blueprint.flags,
                speciesRange: RuntimeRange(lowerBound: speciesLower, count: UInt32(blueprint.species.count)),
                volumeFemtoliters: blueprint.volumeFemtoliters,
                temperatureKelvin: blueprint.temperatureKelvin
            ))
        }
        for tile in state.tiles.indices {
            let indices = state.microdomains.indices.filter { state.cells[Int(state.microdomains[$0].ownerCellIndex)].tileIndex == UInt32(tile) }
            state.tiles[tile].microdomainRange = RuntimeRange(lowerBound: indices.first.map(UInt32.init) ?? 0, count: UInt32(indices.count))
        }

        state.capacity = RuntimeCapacity(
            tiles: scaled(state.tiles.count, capacityScale),
            cells: scaled(state.cells.count, capacityScale),
            segments: scaled(state.segments.count, capacityScale),
            compartments: scaled(state.compartments.count, capacityScale),
            synapses: scaled(state.synapses.count, capacityScale),
            fields: scaled(state.fields.count, capacityScale),
            microdomains: scaled(state.microdomains.count, capacityScale),
            molecularSpecies: scaled(state.molecularSpecies.count, capacityScale),
            events: max(65_536, scaled(state.synapses.count * 2, capacityScale))
        )
        try state.validateCapacity()
        return state
    }

    private func scaled(_ count: Int, _ scale: Double) -> Int { max(count, Int(ceil(Double(max(count, 1)) * max(scale, 1)))) }

    private func tileOrder(_ lhs: TileCoordinate, _ rhs: TileCoordinate) -> Bool {
        if lhs.z != rhs.z { return lhs.z < rhs.z }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.x < rhs.x
    }

    private func depth(_ index: Int, in compartments: [RuntimeCompartmentBlueprint]) -> Int {
        var depth = 0
        var current: Int? = index
        var visited = Set<Int>()
        while let value = current, visited.insert(value).inserted, let parent = compartments[value].parentLocalIndex {
            depth += 1
            current = parent
        }
        return depth
    }
}

public enum RuntimeBuilderError: Error, Sendable, CustomStringConvertible {
    case duplicateCell(UInt64)
    case unknownCell(UInt64)
    case duplicateNeuron(UInt64)
    case duplicateSynapse(UInt64)
    case duplicateMicrodomain(UInt64)
    case unknownCompartment(UInt64)
    case regulatoryStateTooLarge(UInt64)
    case segmentCompartmentCountMismatch
    case invalidLocalParent(Int)
    case invalidLocalCompartment(Int)
    case invalidFieldShape

    public var description: String {
        switch self {
        case .duplicateCell(let id): return "Duplicate cell ID \(id)"
        case .unknownCell(let id): return "Unknown cell ID \(id)"
        case .duplicateNeuron(let id): return "Cell \(id) already has a neuron morphology"
        case .duplicateSynapse(let id): return "Duplicate synapse ID \(id)"
        case .duplicateMicrodomain(let id): return "Duplicate microdomain ID \(id)"
        case .unknownCompartment(let id): return "Unknown compartment ID \(id)"
        case .regulatoryStateTooLarge(let id): return "Cell \(id) has more than 32 regulatory values"
        case .segmentCompartmentCountMismatch: return "Segment-to-compartment mapping count does not match segment count"
        case .invalidLocalParent(let index): return "Invalid local parent index at element \(index)"
        case .invalidLocalCompartment(let index): return "Invalid local compartment index at segment \(index)"
        case .invalidFieldShape: return "Runtime field shape must be 1–128 cubed with exactly 12 channels"
        }
    }
}
