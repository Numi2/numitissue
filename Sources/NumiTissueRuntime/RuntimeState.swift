import Foundation
import NumiTissueCore

/// Contiguous half-open range used by runtime pools and GPU dispatch tables.
@frozen
public struct RuntimeRange: Sendable, Hashable, Codable {
    public var lowerBound: UInt32
    public var count: UInt32

    public init(lowerBound: UInt32 = 0, count: UInt32 = 0) {
        self.lowerBound = lowerBound
        self.count = count
    }

    public var upperBound: UInt32 { lowerBound &+ count }
    public var isEmpty: Bool { count == 0 }

    @inlinable
    public func contains(_ index: UInt32) -> Bool {
        index >= lowerBound && index < upperBound
    }
}

@frozen
public struct RuntimeCapacity: Sendable, Hashable, Codable {
    public var tiles: Int
    public var cells: Int
    public var segments: Int
    public var compartments: Int
    public var synapses: Int
    public var events: Int
    public var fieldValues: Int
    public var microdomains: Int
    public var molecularSpecies: Int

    public init(
        tiles: Int,
        cells: Int,
        segments: Int,
        compartments: Int,
        synapses: Int,
        events: Int,
        fieldValues: Int,
        microdomains: Int,
        molecularSpecies: Int
    ) {
        self.tiles = tiles
        self.cells = cells
        self.segments = segments
        self.compartments = compartments
        self.synapses = synapses
        self.events = events
        self.fieldValues = fieldValues
        self.microdomains = microdomains
        self.molecularSpecies = molecularSpecies
    }

    public static let empty = Self(
        tiles: 0, cells: 0, segments: 0, compartments: 0, synapses: 0,
        events: 0, fieldValues: 0, microdomains: 0, molecularSpecies: 0
    )
}

@frozen
public struct TileRuntimeState: Sendable, Hashable, Codable {
    public var id: TileID
    public var coordinate: TileCoordinate
    public var flags: UInt32
    public var fidelityMask: UInt32
    public var cellRange: RuntimeRange
    public var segmentRange: RuntimeRange
    public var compartmentRange: RuntimeRange
    public var synapseRange: RuntimeRange
    public var fieldRange: RuntimeRange
    public var microdomainRange: RuntimeRange
    public var lastActiveTick: UInt64
    public var activityScore: Float
    public var uncertaintyScore: Float
    public var damageScore: Float
    public var metabolicStress: Float

    public init(id: TileID, coordinate: TileCoordinate) {
        self.id = id
        self.coordinate = coordinate
        self.flags = 0
        self.fidelityMask = 0
        self.cellRange = RuntimeRange()
        self.segmentRange = RuntimeRange()
        self.compartmentRange = RuntimeRange()
        self.synapseRange = RuntimeRange()
        self.fieldRange = RuntimeRange()
        self.microdomainRange = RuntimeRange()
        self.lastActiveTick = 0
        self.activityScore = 0
        self.uncertaintyScore = 0
        self.damageScore = 0
        self.metabolicStress = 0
    }
}

@frozen
public struct RuntimeCellState: Sendable, Hashable, Codable {
    public var id: CellID
    public var lineage: LineageID
    public var tileIndex: UInt32
    public var typeIndex: UInt16
    public var developmentalState: UInt16
    public var fidelity: FidelityLevel
    public var flags: UInt8
    public var position: Float4
    public var orientation: Float4
    public var semiAxes: Float4
    public var velocity: Float4
    public var ageSeconds: Float
    public var cycleProgress: Float
    public var differentiationProgress: Float
    public var energyReserve: Float
    public var oxygenStress: Float
    public var glucoseStress: Float
    public var damage: Float
    public var apoptosisHazard: Float
    public var regulatoryRange: RuntimeRange

    public init(
        id: CellID,
        lineage: LineageID,
        tileIndex: UInt32,
        typeIndex: UInt16,
        developmentalState: UInt16 = 0,
        fidelity: FidelityLevel = .cellAgent,
        position: Float4,
        orientation: Float4 = Float4(0, 0, 0, 1),
        semiAxes: Float4 = Float4(repeating: 5)
    ) {
        self.id = id
        self.lineage = lineage
        self.tileIndex = tileIndex
        self.typeIndex = typeIndex
        self.developmentalState = developmentalState
        self.fidelity = fidelity
        self.flags = 0
        self.position = position
        self.orientation = orientation
        self.semiAxes = semiAxes
        self.velocity = .zero
        self.ageSeconds = 0
        self.cycleProgress = 0
        self.differentiationProgress = 0
        self.energyReserve = 1
        self.oxygenStress = 0
        self.glucoseStress = 0
        self.damage = 0
        self.apoptosisHazard = 0
        self.regulatoryRange = RuntimeRange()
    }
}

@frozen
public struct RuntimeSegmentState: Sendable, Hashable, Codable {
    public var id: SegmentID
    public var cellIndex: UInt32
    public var parentSegmentIndex: UInt32
    public var firstChildIndex: UInt32
    public var nextSiblingIndex: UInt32
    public var compartmentIndex: UInt32
    public var type: UInt16
    public var flags: UInt16
    public var start: Float4
    public var end: Float4
    public var radiusMicrometers: Float
    public var myelinFraction: Float
    public var growthRateMicrometersPerSecond: Float
    public var structuralScore: Float

    public static let invalidIndex = UInt32.max
}

@frozen
public struct RuntimeCompartmentState: Sendable, Hashable, Codable {
    public var id: CompartmentID
    public var neuronIndex: UInt32
    public var parentIndex: UInt32
    public var mechanismRange: RuntimeRange
    public var synapseRange: RuntimeRange
    public var voltageMillivolts: Float
    public var previousVoltageMillivolts: Float
    public var capacitanceNanofarads: Float
    public var axialConductanceMicrosiemens: Float
    public var injectedCurrentNanoamps: Float
    public var synapticCurrentNanoamps: Float
    public var intracellularCalciumMicromolar: Float
    public var intracellularSodiumMillimolar: Float
    public var intracellularPotassiumMillimolar: Float
    public var refractoryUntilTick: UInt64
    public var flags: UInt32

    public static let invalidIndex = UInt32.max
}

@frozen
public struct RuntimeSynapseState: Sendable, Hashable, Codable {
    public var id: SynapseID
    public var sourceRouteIndex: UInt32
    public var targetCompartmentIndex: UInt32
    public var parameterIndex: UInt16
    public var flags: UInt16
    public var delayTicks: UInt32
    public var weight: Float
    public var conductance: Float
    public var shortTermUtilization: Float
    public var shortTermResources: Float
    public var preTrace: Float
    public var postTrace: Float
    public var eligibility: Float
    public var consolidation: Float
    public var structuralScore: Float
    public var lastEventTick: UInt64
}

@frozen
public struct RuntimeFieldValue: Sendable, Hashable, Codable {
    public var concentration: Float
    public var source: Float
    public var sink: Float
    public var diffusionScale: Float

    public init(concentration: Float = 0, source: Float = 0, sink: Float = 0, diffusionScale: Float = 1) {
        self.concentration = concentration
        self.source = source
        self.sink = sink
        self.diffusionScale = diffusionScale
    }
}

@frozen
public struct RuntimeMicrodomainState: Sendable, Hashable, Codable {
    public var id: MicrodomainID
    public var ownerCellIndex: UInt32
    public var ownerCompartmentIndex: UInt32
    public var reactionNetworkIndex: UInt16
    public var solverKind: UInt8
    public var flags: UInt8
    public var speciesRange: RuntimeRange
    public var volumeFemtoliters: Float
    public var temperatureKelvin: Float
    public var nextEventTick: UInt64
    public var propensitySum: Float

    public static let invalidIndex = UInt32.max
}

/// Mutable authority for the CPU reference runtime. The Metal runtime mirrors these pools in
/// private GPU heaps and uses the same semantic layout, not necessarily the same byte layout.
public struct TissueRuntimeState: Sendable, Codable {
    public var time: TissueTime
    public var epoch: UInt64
    public var tiles: [TileRuntimeState]
    public var cells: [RuntimeCellState]
    public var regulatoryState: [Float]
    public var segments: [RuntimeSegmentState]
    public var compartments: [RuntimeCompartmentState]
    public var mechanismState: [Float]
    public var synapses: [RuntimeSynapseState]
    public var fields: [RuntimeFieldValue]
    public var microdomains: [RuntimeMicrodomainState]
    public var molecularSpecies: [Float]
    public var capacity: RuntimeCapacity

    public init(capacity: RuntimeCapacity = .empty) {
        self.time = TissueTime()
        self.epoch = 0
        self.tiles = []
        self.cells = []
        self.regulatoryState = []
        self.segments = []
        self.compartments = []
        self.mechanismState = []
        self.synapses = []
        self.fields = []
        self.microdomains = []
        self.molecularSpecies = []
        self.capacity = capacity
        reserveCapacity(capacity)
    }

    public mutating func reserveCapacity(_ capacity: RuntimeCapacity) {
        self.capacity = capacity
        tiles.reserveCapacity(capacity.tiles)
        cells.reserveCapacity(capacity.cells)
        segments.reserveCapacity(capacity.segments)
        compartments.reserveCapacity(capacity.compartments)
        synapses.reserveCapacity(capacity.synapses)
        fields.reserveCapacity(capacity.fieldValues)
        microdomains.reserveCapacity(capacity.microdomains)
        molecularSpecies.reserveCapacity(capacity.molecularSpecies)
    }

    public var counts: RuntimeCapacity {
        RuntimeCapacity(
            tiles: tiles.count,
            cells: cells.count,
            segments: segments.count,
            compartments: compartments.count,
            synapses: synapses.count,
            events: 0,
            fieldValues: fields.count,
            microdomains: microdomains.count,
            molecularSpecies: molecularSpecies.count
        )
    }

    public func validateCapacity() throws {
        let current = counts
        guard current.tiles <= capacity.tiles || capacity.tiles == 0 else { throw RuntimeStateError.capacityExceeded("tiles") }
        guard current.cells <= capacity.cells || capacity.cells == 0 else { throw RuntimeStateError.capacityExceeded("cells") }
        guard current.segments <= capacity.segments || capacity.segments == 0 else { throw RuntimeStateError.capacityExceeded("segments") }
        guard current.compartments <= capacity.compartments || capacity.compartments == 0 else { throw RuntimeStateError.capacityExceeded("compartments") }
        guard current.synapses <= capacity.synapses || capacity.synapses == 0 else { throw RuntimeStateError.capacityExceeded("synapses") }
        guard current.fieldValues <= capacity.fieldValues || capacity.fieldValues == 0 else { throw RuntimeStateError.capacityExceeded("fields") }
        guard current.microdomains <= capacity.microdomains || capacity.microdomains == 0 else { throw RuntimeStateError.capacityExceeded("microdomains") }
        guard current.molecularSpecies <= capacity.molecularSpecies || capacity.molecularSpecies == 0 else { throw RuntimeStateError.capacityExceeded("molecular species") }
    }
}

public enum RuntimeStateError: Error, Sendable, CustomStringConvertible {
    case capacityExceeded(String)
    case invalidIndex(pool: String, index: UInt32)
    case invalidRange(pool: String, range: RuntimeRange)
    case nonFinite(pool: String, index: Int)
    case negativeConcentration(index: Int, value: Float)
    case invalidTopology(String)

    public var description: String {
        switch self {
        case .capacityExceeded(let pool): return "Runtime capacity exceeded for \(pool)"
        case .invalidIndex(let pool, let index): return "Invalid \(pool) index \(index)"
        case .invalidRange(let pool, let range): return "Invalid \(pool) range \(range.lowerBound)..<\(range.upperBound)"
        case .nonFinite(let pool, let index): return "Non-finite state in \(pool) at \(index)"
        case .negativeConcentration(let index, let value): return "Negative concentration \(value) at field index \(index)"
        case .invalidTopology(let reason): return "Invalid topology: \(reason)"
        }
    }
}
