import Foundation
import NumiTissueCore
import NumiTissueModels

public enum TissueEventKind: UInt16, Sendable, CaseIterable {
    case synapticRelease = 0
    case injectedCurrentPulse = 1
    case extracellularStimulus = 2
    case neuromodulatorPulse = 3
    case emittedSpike = 4
}

struct ScheduledEvent: Sendable, Comparable {
    var absoluteTick: UInt64
    var sequence: UInt64
    var event: GPUEvent

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.absoluteTick == rhs.absoluteTick && lhs.sequence == rhs.sequence
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.absoluteTick != rhs.absoluteTick { return lhs.absoluteTick < rhs.absoluteTick }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.event.address.y != rhs.event.address.y { return lhs.event.address.y < rhs.event.address.y }
        return lhs.event.address.x < rhs.event.address.x
    }
}

struct EventMinHeap: Sendable {
    private(set) var storage: [ScheduledEvent] = []

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var nextTick: UInt64? { storage.first?.absoluteTick }

    mutating func reserveCapacity(_ count: Int) {
        storage.reserveCapacity(count)
    }

    mutating func insert(_ element: ScheduledEvent) {
        storage.append(element)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) >> 1
            guard storage[child] < storage[parent] else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeFirst() -> ScheduledEvent? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let result = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { break }
            let right = left + 1
            let child = right < storage.count && storage[right] < storage[left] ? right : left
            guard storage[child] < storage[parent] else { break }
            storage.swapAt(parent, child)
            parent = child
        }
        return result
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    func flattenedEvents(relativeTo baseTick: UInt64) -> [GPUEvent] {
        storage.sorted().map { item in
            var event = item.event
            let relative = item.absoluteTick >= baseTick ? item.absoluteTick - baseTick : 0
            event.address.z = clampUInt32(relative)
            return event
        }
    }
}

struct ReferenceStaticTopology: Sendable {
    var compartmentToTile: [UInt32]
    var compartmentToCell: [UInt32]
    var cellToTile: [UInt32]
    var incomingSynapses: [[UInt32]]
    var outgoingRoutesBySource: [[UInt32]]
    var synapseToTile: [UInt32]
    var tileIndexByCoordinate: [TileCoordinate: Int]

    init(model: CompiledTissueModel) {
        let compartmentCount = model.compartments.count
        let cellCount = model.cells.count
        self.compartmentToTile = [UInt32](repeating: UInt32.max, count: compartmentCount)
        self.compartmentToCell = [UInt32](repeating: UInt32.max, count: compartmentCount)
        self.cellToTile = [UInt32](repeating: UInt32.max, count: cellCount)
        self.synapseToTile = [UInt32](repeating: UInt32.max, count: model.synapses.count)
        self.tileIndexByCoordinate = Dictionary(
            uniqueKeysWithValues: model.tileCoordinates.enumerated().map { ($0.element, $0.offset) }
        )

        for (tileIndex, membership) in model.tileMembership.enumerated() {
            let tile = UInt32(tileIndex)
            for index in membership.cellIndices where Int(index) < cellCount { cellToTile[Int(index)] = tile }
            for index in membership.compartmentIndices where Int(index) < compartmentCount { compartmentToTile[Int(index)] = tile }
            for index in membership.synapseIndices where Int(index) < synapseToTile.count { synapseToTile[Int(index)] = tile }
        }
        for neuron in model.neurons {
            let start = Int(neuron.compartmentRange.x)
            let end = min(start + Int(neuron.compartmentRange.y), compartmentCount)
            for index in start..<end { compartmentToCell[index] = neuron.identity.x }
        }

        self.incomingSynapses = Array(repeating: [], count: compartmentCount)
        for (index, synapse) in model.synapses.enumerated() {
            let target = Int(synapse.routing.x)
            if target < incomingSynapses.count { incomingSynapses[target].append(UInt32(index)) }
        }
        for index in incomingSynapses.indices { incomingSynapses[index].sort() }

        self.outgoingRoutesBySource = Array(repeating: [], count: compartmentCount)
        for (routeIndex, route) in model.outgoingRoutes.enumerated() {
            let source = Int(route.addressing.x)
            if source < outgoingRoutesBySource.count {
                outgoingRoutesBySource[source].append(UInt32(routeIndex))
            }
        }
        for index in outgoingRoutesBySource.indices { outgoingRoutesBySource[index].sort() }
    }
}

struct ReferenceWorkingState: Sendable {
    var tileHeaders: [GPUTileHeader]
    var tileMembership: [CompiledTileMembership]
    var cells: [GPUCellState]
    var segments: [GPUNeuriteSegment]
    var compartments: [GPUCompartmentState]
    var neurons: [GPUCompiledNeuron]
    var synapses: [GPUSynapseState]
    var fields: [GPUFieldVoxel]
    var microdomains: [GPUMicrodomainHeader]
    var molecularSpecies: [GPUMolecularSpeciesState]
    var events: EventMinHeap
    var eventSequence: UInt64
    var previousVoltages: [Float]
    var populationSpikeCounts: [UInt64: UInt64]
    var transactionSpikeSources: [UInt32]
    var dynamicIncomingSynapses: [[UInt32]]
    var dynamicOutgoingSynapses: [[UInt32]]
    var cellToTile: [UInt32]
    var compartmentToTile: [UInt32]
    var compartmentToCell: [UInt32]
    var lowActivityTransactions: [UInt32]

    init(model: CompiledTissueModel, topology: ReferenceStaticTopology) {
        self.tileHeaders = model.tileHeaders
        self.tileMembership = model.tileMembership
        self.cells = model.cells
        self.segments = model.neuriteSegments
        self.compartments = model.compartments
        self.neurons = model.neurons
        self.synapses = model.synapses
        self.fields = model.fieldVoxels
        self.microdomains = model.microdomainHeaders
        self.molecularSpecies = model.molecularSpecies
        self.events = EventMinHeap()
        self.events.reserveCapacity(min(Int(model.allocation.eventNodeCapacity), 1_048_576))
        self.eventSequence = 0
        self.previousVoltages = model.compartments.map { $0.voltageAndCurrent.x }
        self.populationSpikeCounts = [:]
        self.transactionSpikeSources = []
        self.dynamicIncomingSynapses = topology.incomingSynapses
        self.dynamicOutgoingSynapses = Array(repeating: [], count: model.compartments.count)
        self.cellToTile = topology.cellToTile
        self.compartmentToTile = topology.compartmentToTile
        self.compartmentToCell = topology.compartmentToCell
        for route in model.outgoingRoutes {
            let source = Int(route.addressing.x)
            guard source < dynamicOutgoingSynapses.count else { continue }
            let start = route.addressing.y
            let count = route.addressing.z
            for offset in 0..<count { dynamicOutgoingSynapses[source].append(start + offset) }
        }
        self.lowActivityTransactions = [UInt32](repeating: 0, count: model.cells.count)
    }

    mutating func schedule(_ event: GPUEvent, at absoluteTick: UInt64) {
        events.insert(.init(absoluteTick: absoluteTick, sequence: eventSequence, event: event))
        eventSequence &+= 1
    }
}

struct ReferenceStepAccumulator: Sendable {
    var metrics: TissueStepMetrics
    var efferentEvents: [GPUEvent] = []
    var damageEvents: [DamageEvent] = []
    var fieldMassBefore: [Double] = Array(repeating: 0, count: FieldChannel.allCases.count)
    var fieldMassAfter: [Double] = Array(repeating: 0, count: FieldChannel.allCases.count)
    var directNeuromodulator: Float4 = .zero
    var eventOverflow = false
    var capacityLimited = false
    var promoted = false

    init(transactionIndex: UInt64) {
        self.metrics = TissueStepMetrics(transactionIndex: transactionIndex)
    }
}

@inline(__always)
func reconstructIdentifier<ID: TissueIdentifier>(_ low: UInt32, _ high: UInt32, _: ID.Type) -> ID {
    ID(rawValue: UInt64(low) | (UInt64(high) << 32))
}

@inline(__always)
func safeIndex(_ value: UInt32, count: Int) -> Int? {
    let index = Int(value)
    return index >= 0 && index < count ? index : nil
}

@inline(__always)
func clampUInt32(_ value: UInt64) -> UInt32 {
    value > UInt64(UInt32.max) ? UInt32.max : UInt32(value)
}
