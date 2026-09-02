import Foundation

// MARK: - Mutable production state

@frozen
public struct NTGateState: Codable, Hashable, Sendable {
    public var sodiumActivation: Float
    public var sodiumInactivation: Float
    public var potassiumActivation: Float
    public var calciumLActivation: Float
    public var calciumLInactivation: Float
    public var calciumTActivation: Float
    public var calciumTInactivation: Float
    public var hcnActivation: Float
    public var mActivation: Float
    public var calciumActivatedPotassium: Float
    public var optogeneticOpen: Float
    public var reserve0: Float

    public init(
        sodiumActivation: Float = 0.05,
        sodiumInactivation: Float = 0.6,
        potassiumActivation: Float = 0.32,
        calciumLActivation: Float = 0,
        calciumLInactivation: Float = 1,
        calciumTActivation: Float = 0,
        calciumTInactivation: Float = 1,
        hcnActivation: Float = 0.1,
        mActivation: Float = 0,
        calciumActivatedPotassium: Float = 0,
        optogeneticOpen: Float = 0,
        reserve0: Float = 0
    ) {
        self.sodiumActivation = sodiumActivation
        self.sodiumInactivation = sodiumInactivation
        self.potassiumActivation = potassiumActivation
        self.calciumLActivation = calciumLActivation
        self.calciumLInactivation = calciumLInactivation
        self.calciumTActivation = calciumTActivation
        self.calciumTInactivation = calciumTInactivation
        self.hcnActivation = hcnActivation
        self.mActivation = mActivation
        self.calciumActivatedPotassium = calciumActivatedPotassium
        self.optogeneticOpen = optogeneticOpen
        self.reserve0 = reserve0
    }

    public init(serialized values: ArraySlice<Float>) {
        let v = Array(values)
        self.init(
            sodiumActivation: v[safe: 0] ?? 0.05,
            sodiumInactivation: v[safe: 1] ?? 0.6,
            potassiumActivation: v[safe: 2] ?? 0.32,
            calciumLActivation: v[safe: 3] ?? 0,
            calciumLInactivation: v[safe: 4] ?? 1,
            calciumTActivation: v[safe: 5] ?? 0,
            calciumTInactivation: v[safe: 6] ?? 1,
            hcnActivation: v[safe: 7] ?? 0.1,
            mActivation: v[safe: 8] ?? 0,
            calciumActivatedPotassium: v[safe: 9] ?? 0,
            optogeneticOpen: v[safe: 10] ?? 0,
            reserve0: v[safe: 11] ?? 0
        )
    }

    public var serialized: [Float] {
        [
            sodiumActivation, sodiumInactivation, potassiumActivation,
            calciumLActivation, calciumLInactivation,
            calciumTActivation, calciumTInactivation,
            hcnActivation, mActivation, calciumActivatedPotassium,
            optogeneticOpen, reserve0
        ]
    }
}

@frozen
public struct NTProductionCell: Codable, Hashable, Sendable {
    public var record: NTCellRecord
    public var forcePiconewtons: NTVector3
    public var extracellularMatrixAttachment: Float
    public var motilityPersistence: Float
    public var accumulatedGrowthMicrometers: Float
    public var divisionHazardIntegral: Float
    public var differentiationHazardIntegral: Float
    public var apoptosisHazardIntegral: Float
    public var lastStructuralUpdate: TissueTime

    public init(record: NTCellRecord) {
        self.record = record
        self.forcePiconewtons = .zero
        self.extracellularMatrixAttachment = 0.5
        self.motilityPersistence = 0.8
        self.accumulatedGrowthMicrometers = 0
        self.divisionHazardIntegral = 0
        self.differentiationHazardIntegral = 0
        self.apoptosisHazardIntegral = 0
        self.lastStructuralUpdate = .init()
    }
}

@frozen
public struct NTProductionCompartment: Codable, Hashable, Sendable {
    public var record: NTCompartmentRecord
    public var gates: NTGateState
    public var previousVoltageMillivolts: Float
    public var synapticConductanceExcitatory: Float
    public var synapticConductanceInhibitory: Float
    public var synapticCurrentNanoamps: Float
    public var ionicCurrentNanoamps: Float
    public var extracellularPotentialMillivolts: Float
    public var spikeThresholdMillivolts: Float
    public var resetThresholdMillivolts: Float
    public var lastSpike: TissueTime?
    public var spikeCountWindow: UInt32
    public var calciumFluxMicromolarPerSecond: Float
    public var energyCostPicojoules: Float

    public init(record: NTCompartmentRecord, gates: NTGateState = .init()) {
        self.record = record
        self.gates = gates
        self.previousVoltageMillivolts = record.membraneVoltageMillivolts
        self.synapticConductanceExcitatory = 0
        self.synapticConductanceInhibitory = 0
        self.synapticCurrentNanoamps = 0
        self.ionicCurrentNanoamps = 0
        self.extracellularPotentialMillivolts = 0
        self.spikeThresholdMillivolts = -20
        self.resetThresholdMillivolts = -35
        self.lastSpike = nil
        self.spikeCountWindow = 0
        self.calciumFluxMicromolarPerSecond = 0
        self.energyCostPicojoules = 0
    }
}

@frozen
public struct NTProductionSynapse: Codable, Hashable, Sendable {
    public var record: NTSynapseRecord
    public var riseState: Float
    public var decayState: Float
    public var nmdaBlock: Float
    public var releaseProbability: Float
    public var vesiclePool: Float
    public var postTraceFast: Float
    public var postTraceSlow: Float
    public var homeostaticTargetHertz: Float
    public var lastPreSpike: TissueTime?
    public var lastPostSpike: TissueTime?
    public var pendingDeletion: Bool

    public init(record: NTSynapseRecord) {
        self.record = record
        self.riseState = 0
        self.decayState = record.conductanceMicrosiemens
        self.nmdaBlock = 1
        self.releaseProbability = 1
        self.vesiclePool = 1
        self.postTraceFast = 0
        self.postTraceSlow = 0
        self.homeostaticTargetHertz = 5
        self.lastPreSpike = nil
        self.lastPostSpike = nil
        self.pendingDeletion = false
    }
}

@frozen
public struct NTProductionTile: Codable, Hashable, Sendable {
    public var membership: NTTileMembership
    public var localEvents: NTTileEventQueues
    public var fastFieldMassBefore: [Float]
    public var fastFieldMassAfter: [Float]
    public var promotionAccumulator: Float
    public var demotionAccumulator: Float
    public var structuralEpoch: UInt64

    public init(membership: NTTileMembership, eventCapacity: Int) {
        self.membership = membership
        self.localEvents = NTTileEventQueues(capacityPerQueue: eventCapacity)
        self.fastFieldMassBefore = []
        self.fastFieldMassAfter = []
        self.promotionAccumulator = 0
        self.demotionAccumulator = 0
        self.structuralEpoch = 0
    }
}

@frozen
public struct NTProductionState: Codable, Sendable {
    public var configuration: NTWorldConfiguration
    public var time: TissueTime
    public var nextTransactionRawValue: UInt64
    public var cells: [NTProductionCell]
    public var compartments: [NTProductionCompartment]
    public var synapses: [NTProductionSynapse]
    public var tiles: [NTProductionTile]
    public var fields: [NTFieldBrickState]
    public var microdomains: [NTMicrodomainState]
    public var lineage: [NTLineageEvent]
    public var routeTable: NTRouteTable
    public var eventWheel: NTEventWheel
    public var modelFingerprint: String
    public var metadata: [String: String]

    private var cellIndexByID: [CellID: Int]
    private var compartmentIndexByID: [CompartmentID: Int]
    private var synapseIndexByID: [SynapseID: Int]
    private var tileIndexByID: [TileID: Int]
    private var microdomainIndexByID: [MicrodomainID: Int]

    public init(
        configuration: NTWorldConfiguration,
        time: TissueTime = .init(),
        cells: [NTProductionCell] = [],
        compartments: [NTProductionCompartment] = [],
        synapses: [NTProductionSynapse] = [],
        tiles: [NTProductionTile] = [],
        fields: [NTFieldBrickState] = [],
        microdomains: [NTMicrodomainState] = [],
        lineage: [NTLineageEvent] = [],
        routes: [NTRouteRecord] = [],
        modelFingerprint: String = "",
        metadata: [String: String] = [:]
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.time = time
        self.nextTransactionRawValue = 1
        self.cells = cells
        self.compartments = compartments
        self.synapses = synapses
        self.tiles = tiles
        self.fields = fields
        self.microdomains = microdomains
        self.lineage = lineage
        self.routeTable = try NTRouteTable(routes: routes, compartmentCount: compartments.count)
        self.eventWheel = try NTEventWheel(
            cursor: time,
            maximumEvents: max(1_048_576, configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, tiles.count))
        )
        self.modelFingerprint = modelFingerprint
        self.metadata = metadata
        self.cellIndexByID = [:]
        self.compartmentIndexByID = [:]
        self.synapseIndexByID = [:]
        self.tileIndexByID = [:]
        self.microdomainIndexByID = [:]
        try rebuildIndices()
    }

    public init(snapshot: NTWorldSnapshot, routes: [NTRouteRecord] = []) throws {
        try snapshot.configuration.validate()
        var productionCells: [NTProductionCell] = []
        productionCells.reserveCapacity(snapshot.cells.count)
        for index in 0..<snapshot.cells.count {
            guard let record = snapshot.cells.record(at: index) else {
                throw NTRuntimeError.invalidModel("Unable to decode cell at index \(index).")
            }
            productionCells.append(NTProductionCell(record: record))
        }

        var productionCompartments: [NTProductionCompartment] = []
        productionCompartments.reserveCapacity(snapshot.compartments.count)
        for index in snapshot.compartments.records.indices {
            let range = snapshot.compartments.stateRange(for: index)
            let gateValues = range.map { snapshot.compartments.mechanismState[$0] } ?? []
            productionCompartments.append(.init(
                record: snapshot.compartments.records[index],
                gates: NTGateState(serialized: gateValues[...])
            ))
        }

        self.configuration = snapshot.configuration
        self.time = snapshot.time
        self.nextTransactionRawValue = snapshot.nextTransactionRawValue
        self.cells = productionCells
        self.compartments = productionCompartments
        self.synapses = snapshot.synapses.records.map(NTProductionSynapse.init(record:))
        self.tiles = snapshot.tiles.map {
            NTProductionTile(
                membership: $0,
                eventCapacity: snapshot.configuration.resourceBudget.maximumEventsPerBlockPerTile
            )
        }
        self.fields = snapshot.fields
        self.microdomains = snapshot.microdomains
        self.lineage = snapshot.lineage
        self.routeTable = try NTRouteTable(routes: routes, compartmentCount: snapshot.compartments.count)
        self.eventWheel = try NTEventWheel(
            cursor: snapshot.time,
            maximumEvents: max(
                1_048_576,
                snapshot.configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, snapshot.tiles.count)
            )
        )
        self.modelFingerprint = snapshot.modelFingerprint
        self.metadata = snapshot.metadata
        self.cellIndexByID = [:]
        self.compartmentIndexByID = [:]
        self.synapseIndexByID = [:]
        self.tileIndexByID = [:]
        self.microdomainIndexByID = [:]
        try rebuildIndices()
    }

    public mutating func rebuildIndices() throws {
        cellIndexByID.removeAll(keepingCapacity: true)
        compartmentIndexByID.removeAll(keepingCapacity: true)
        synapseIndexByID.removeAll(keepingCapacity: true)
        tileIndexByID.removeAll(keepingCapacity: true)
        microdomainIndexByID.removeAll(keepingCapacity: true)

        for (index, cell) in cells.enumerated() {
            guard cellIndexByID.updateValue(index, forKey: cell.record.id) == nil else {
                throw NTRuntimeError.invalidModel("Duplicate cell identifier \(cell.record.id).")
            }
        }
        for (index, compartment) in compartments.enumerated() {
            guard compartmentIndexByID.updateValue(index, forKey: compartment.record.id) == nil else {
                throw NTRuntimeError.invalidModel("Duplicate compartment identifier \(compartment.record.id).")
            }
        }
        for (index, synapse) in synapses.enumerated() {
            guard synapseIndexByID.updateValue(index, forKey: synapse.record.id) == nil else {
                throw NTRuntimeError.invalidModel("Duplicate synapse identifier \(synapse.record.id).")
            }
        }
        for (index, tile) in tiles.enumerated() {
            guard tileIndexByID.updateValue(index, forKey: tile.membership.id) == nil else {
                throw NTRuntimeError.invalidModel("Duplicate tile identifier \(tile.membership.id).")
            }
        }
        for (index, microdomain) in microdomains.enumerated() {
            guard microdomainIndexByID.updateValue(index, forKey: microdomain.id) == nil else {
                throw NTRuntimeError.invalidModel("Duplicate microdomain identifier \(microdomain.id).")
            }
        }
    }

    public func cellIndex(id: CellID) -> Int? { cellIndexByID[id] }
    public func compartmentIndex(id: CompartmentID) -> Int? { compartmentIndexByID[id] }
    public func synapseIndex(id: SynapseID) -> Int? { synapseIndexByID[id] }
    public func tileIndex(id: TileID) -> Int? { tileIndexByID[id] }
    public func microdomainIndex(id: MicrodomainID) -> Int? { microdomainIndexByID[id] }

    @discardableResult
    public mutating func appendCell(_ cell: NTProductionCell) throws -> Int {
        guard cells.count < configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumCellsPerTile else {
            throw NTRuntimeError.resourceExhausted("Global cell capacity exceeded.")
        }
        guard cellIndexByID[cell.record.id] == nil else {
            throw NTRuntimeError.invalidModel("Duplicate cell identifier \(cell.record.id).")
        }
        let index = cells.count
        cells.append(cell)
        cellIndexByID[cell.record.id] = index
        if let tile = tileIndexByID[cell.record.tile] {
            guard tiles[tile].membership.cellIndices.count < configuration.resourceBudget.maximumCellsPerTile else {
                cells.removeLast()
                cellIndexByID.removeValue(forKey: cell.record.id)
                throw NTRuntimeError.resourceExhausted("Destination tile cell capacity exceeded.")
            }
            tiles[tile].membership.cellIndices.append(UInt32(index))
        }
        return index
    }

    @discardableResult
    public mutating func appendCompartment(_ compartment: NTProductionCompartment) throws -> Int {
        guard compartmentIndexByID[compartment.record.id] == nil else {
            throw NTRuntimeError.invalidModel("Duplicate compartment identifier \(compartment.record.id).")
        }
        guard compartments.count < configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumCompartmentsPerTile else {
            throw NTRuntimeError.resourceExhausted("Global compartment capacity exceeded.")
        }
        let index = compartments.count
        compartments.append(compartment)
        compartmentIndexByID[compartment.record.id] = index
        if let tile = tileIndexByID[compartment.record.tile] {
            tiles[tile].membership.compartmentIndices.append(UInt32(index))
        }
        return index
    }

    @discardableResult
    public mutating func appendSynapse(_ synapse: NTProductionSynapse) throws -> Int {
        guard synapseIndexByID[synapse.record.id] == nil else {
            throw NTRuntimeError.invalidModel("Duplicate synapse identifier \(synapse.record.id).")
        }
        guard synapses.count < configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumExplicitSynapsesPerTile else {
            throw NTRuntimeError.resourceExhausted("Global explicit synapse capacity exceeded.")
        }
        let index = synapses.count
        synapses.append(synapse)
        synapseIndexByID[synapse.record.id] = index
        return index
    }

    public mutating func migrateCell(at index: Int, to destination: TileID, at eventTime: TissueTime) throws {
        guard cells.indices.contains(index), let destinationTile = tileIndexByID[destination] else {
            throw NTRuntimeError.invalidModel("Cell migration references an absent cell or tile.")
        }
        let source = cells[index].record.tile
        guard source != destination else { return }
        guard tiles[destinationTile].membership.cellIndices.count < configuration.resourceBudget.maximumCellsPerTile else {
            throw NTRuntimeError.resourceExhausted("Destination tile has no free cell slots.")
        }
        if let sourceTile = tileIndexByID[source] {
            tiles[sourceTile].membership.cellIndices.removeAll { $0 == UInt32(index) }
        }
        tiles[destinationTile].membership.cellIndices.append(UInt32(index))
        cells[index].record.tile = destination
        lineage.append(.init(
            time: eventTime,
            kind: .migrated,
            cell: cells[index].record.id,
            fromTile: source,
            toTile: destination
        ))
    }

    public mutating func compactDeletedTopology() throws {
        let keptSynapses = synapses.filter { !$0.pendingDeletion }
        if keptSynapses.count != synapses.count {
            synapses = keptSynapses
            for index in tiles.indices { tiles[index].membership.synapseIndices.removeAll(keepingCapacity: true) }
            for (index, synapse) in synapses.enumerated() {
                let post = Int(synapse.record.postCompartmentIndex)
                guard compartments.indices.contains(post),
                      let tile = tileIndexByID[compartments[post].record.tile] else { continue }
                tiles[tile].membership.synapseIndices.append(UInt32(index))
            }
        }
        try rebuildIndices()
    }

    public func makeInterchangeSnapshot() throws -> NTWorldSnapshot {
        var cellPool = NTCellPool()
        cellPool.reserveCapacity(cells.count)
        for cell in cells { try cellPool.append(cell.record) }

        var compartmentPool = NTCompartmentPool()
        for compartment in compartments {
            var record = compartment.record
            record.membraneVoltageMillivolts = compartment.record.membraneVoltageMillivolts
            record.calciumMicromolar = compartment.record.calciumMicromolar
            _ = compartmentPool.append(record, mechanismState: compartment.gates.serialized)
        }

        var synapsePool = NTSynapsePool()
        for synapse in synapses { _ = synapsePool.append(synapse.record) }
        try synapsePool.rebuildAdjacency(compartmentCount: compartments.count)

        return NTWorldSnapshot(
            configuration: configuration,
            time: time,
            nextTransactionRawValue: nextTransactionRawValue,
            cells: cellPool,
            compartments: compartmentPool,
            synapses: synapsePool,
            tiles: tiles.map(\.membership),
            fields: fields,
            microdomains: microdomains,
            lineage: lineage,
            modelFingerprint: modelFingerprint,
            metadata: metadata
        )
    }

    public func validate() -> [NTDiagnostic] {
        var diagnostics: [NTDiagnostic] = []
        if cells.count > configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumCellsPerTile {
            diagnostics.append(.init(severity: .fatal, code: .resourceBudgetExceeded, message: "Global cell budget exceeded."))
        }
        if compartments.count > configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumCompartmentsPerTile {
            diagnostics.append(.init(severity: .fatal, code: .resourceBudgetExceeded, message: "Global compartment budget exceeded."))
        }
        if synapses.count > configuration.resourceBudget.maximumTiles * configuration.resourceBudget.maximumExplicitSynapsesPerTile {
            diagnostics.append(.init(severity: .fatal, code: .resourceBudgetExceeded, message: "Global synapse budget exceeded."))
        }
        for compartment in compartments {
            let values = [
                compartment.record.membraneVoltageMillivolts,
                compartment.record.calciumMicromolar,
                compartment.record.sodiumMillimolar,
                compartment.record.potassiumMillimolar,
                compartment.synapticCurrentNanoamps,
                compartment.ionicCurrentNanoamps
            ]
            if values.contains(where: { !$0.isFinite }) {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .nonFiniteState,
                    message: "Production compartment state is non-finite.",
                    entity: compartment.record.id.rawValue,
                    tile: compartment.record.tile
                ))
            }
            if compartment.record.membraneVoltageMillivolts < configuration.voltageMinimumMillivolts ||
                compartment.record.membraneVoltageMillivolts > configuration.voltageMaximumMillivolts {
                diagnostics.append(.init(
                    severity: .error,
                    code: .voltageOutsideBounds,
                    message: "Production compartment voltage exceeded configured bounds.",
                    entity: compartment.record.id.rawValue,
                    tile: compartment.record.tile
                ))
            }
        }
        for synapse in synapses {
            if !synapse.record.weightMicrosiemens.isFinite || synapse.record.weightMicrosiemens < 0 {
                diagnostics.append(.init(
                    severity: .error,
                    code: .plasticityWeightOutsideBounds,
                    message: "Synaptic weight is invalid.",
                    entity: synapse.record.id.rawValue
                ))
            }
        }
        for field in fields { diagnostics.append(contentsOf: field.validate()) }
        diagnostics.append(contentsOf: eventWheel.validate())
        return diagnostics
    }

    public var estimatedResidentBytes: UInt64 {
        UInt64(cells.count) * 448 +
        UInt64(compartments.count) * 256 +
        UInt64(synapses.count) * 192 +
        UInt64(fields.reduce(0) { $0 + $1.concentrations.count + $1.sources.count }) * 4 +
        UInt64(microdomains.reduce(0) { $0 + $1.speciesAmounts.count }) * 4 +
        UInt64(eventWheel.count) * 64
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, time, nextTransactionRawValue, cells, compartments, synapses, tiles
        case fields, microdomains, lineage, routeTable, eventWheel, modelFingerprint, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decode(NTWorldConfiguration.self, forKey: .configuration)
        time = try container.decode(TissueTime.self, forKey: .time)
        nextTransactionRawValue = try container.decode(UInt64.self, forKey: .nextTransactionRawValue)
        cells = try container.decode([NTProductionCell].self, forKey: .cells)
        compartments = try container.decode([NTProductionCompartment].self, forKey: .compartments)
        synapses = try container.decode([NTProductionSynapse].self, forKey: .synapses)
        tiles = try container.decode([NTProductionTile].self, forKey: .tiles)
        fields = try container.decode([NTFieldBrickState].self, forKey: .fields)
        microdomains = try container.decode([NTMicrodomainState].self, forKey: .microdomains)
        lineage = try container.decode([NTLineageEvent].self, forKey: .lineage)
        routeTable = try container.decode(NTRouteTable.self, forKey: .routeTable)
        eventWheel = try container.decode(NTEventWheel.self, forKey: .eventWheel)
        modelFingerprint = try container.decode(String.self, forKey: .modelFingerprint)
        metadata = try container.decode([String: String].self, forKey: .metadata)
        cellIndexByID = [:]
        compartmentIndexByID = [:]
        synapseIndexByID = [:]
        tileIndexByID = [:]
        microdomainIndexByID = [:]
        try rebuildIndices()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(time, forKey: .time)
        try container.encode(nextTransactionRawValue, forKey: .nextTransactionRawValue)
        try container.encode(cells, forKey: .cells)
        try container.encode(compartments, forKey: .compartments)
        try container.encode(synapses, forKey: .synapses)
        try container.encode(tiles, forKey: .tiles)
        try container.encode(fields, forKey: .fields)
        try container.encode(microdomains, forKey: .microdomains)
        try container.encode(lineage, forKey: .lineage)
        try container.encode(routeTable, forKey: .routeTable)
        try container.encode(eventWheel, forKey: .eventWheel)
        try container.encode(modelFingerprint, forKey: .modelFingerprint)
        try container.encode(metadata, forKey: .metadata)
    }
}

public extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
