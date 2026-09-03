import Foundation

public enum NTEventKind: UInt8, Codable, CaseIterable, Sendable {
    case spike
    case synapticRelease
    case currentPulseStart
    case currentPulseEnd
    case transmitterRelease
    case neuromodulatorPulse
    case cellMigration
    case topologyMutation
    case fieldSource
    case custom
}

@frozen
public struct NTNeuralEvent: Codable, Hashable, Sendable, Comparable {
    public var deliveryTime: TissueTime
    public var kind: NTEventKind
    public var source: UInt64
    public var destination: UInt64
    public var route: RouteID
    public var payload0: Float
    public var payload1: Float
    public var sequence: UInt64

    public init(
        deliveryTime: TissueTime,
        kind: NTEventKind,
        source: UInt64,
        destination: UInt64,
        route: RouteID = .init(rawValue: 0),
        payload0: Float = 0,
        payload1: Float = 0,
        sequence: UInt64 = 0
    ) {
        self.deliveryTime = deliveryTime
        self.kind = kind
        self.source = source
        self.destination = destination
        self.route = route
        self.payload0 = payload0
        self.payload1 = payload1
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.deliveryTime != rhs.deliveryTime { return lhs.deliveryTime < rhs.deliveryTime }
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.destination != rhs.destination { return lhs.destination < rhs.destination }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.sequence < rhs.sequence
    }
}

/// Deterministic circular timing wheel. Each bin is ordered only when drained, keeping insertion O(1)
/// while preserving stable cross-backend event delivery.
public struct NTEventWheel: Codable, Sendable {
    public private(set) var cursor: TissueTime
    public let wheelSize: Int
    public let binWidthTicks: UInt64
    public let maximumEvents: Int
    private var bins: [[NTNeuralEvent]]
    private var overflow: [NTNeuralEvent]
    private var eventCount: Int
    private var nextSequence: UInt64

    public init(
        cursor: TissueTime = .init(),
        wheelSize: Int = 4_096,
        binWidthTicks: UInt64 = 1,
        maximumEvents: Int = 1_048_576
    ) throws {
        guard wheelSize > 1, binWidthTicks > 0, maximumEvents > 0 else {
            throw NTRuntimeError.invalidConfiguration("Event wheel dimensions must be positive.")
        }
        self.cursor = cursor
        self.wheelSize = wheelSize
        self.binWidthTicks = binWidthTicks
        self.maximumEvents = maximumEvents
        self.bins = Array(repeating: [], count: wheelSize)
        self.overflow = []
        self.eventCount = 0
        self.nextSequence = 1
    }

    public var count: Int { eventCount }
    public var isEmpty: Bool { eventCount == 0 }
    public var horizonTicks: UInt64 { UInt64(wheelSize) * binWidthTicks }

    public mutating func schedule(_ sourceEvent: NTNeuralEvent) throws {
        guard sourceEvent.deliveryTime >= cursor else {
            throw NTRuntimeError.invalidModel("Cannot schedule an event before the event-wheel cursor.")
        }
        guard eventCount < maximumEvents else {
            throw NTRuntimeError.resourceExhausted("Event wheel reached its capacity of \(maximumEvents).")
        }
        var event = sourceEvent
        if event.sequence == 0 {
            event.sequence = nextSequence
            nextSequence &+= 1
        }
        let distance = event.deliveryTime.tick - cursor.tick
        if distance < horizonTicks {
            bins[binIndex(for: event.deliveryTime)].append(event)
        } else {
            insertOverflow(event)
        }
        eventCount += 1
    }

    public mutating func schedule<S: Sequence>(contentsOf events: S) throws where S.Element == NTNeuralEvent {
        for event in events { try schedule(event) }
    }

    /// Returns all events with delivery time <= `time`, ordered by the canonical event comparator.
    public mutating func drain(through time: TissueTime) throws -> [NTNeuralEvent] {
        guard time >= cursor else {
            throw NTRuntimeError.internalInvariant("Event wheel cannot move backward.")
        }
        var delivered: [NTNeuralEvent] = []
        while cursor <= time {
            promoteOverflow()
            let index = binIndex(for: cursor)
            if !bins[index].isEmpty {
                var retained: [NTNeuralEvent] = []
                retained.reserveCapacity(bins[index].count)
                for event in bins[index] {
                    if event.deliveryTime <= time {
                        delivered.append(event)
                        eventCount -= 1
                    } else {
                        retained.append(event)
                    }
                }
                bins[index] = retained
            }
            if cursor == time { break }
            let remaining = time.tick - cursor.tick
            cursor.tick &+= min(binWidthTicks, remaining)
        }
        delivered.sort()
        return delivered
    }

    public mutating func removeAll(keepingCapacity: Bool = true, cursor newCursor: TissueTime = .init()) {
        if keepingCapacity {
            for index in bins.indices { bins[index].removeAll(keepingCapacity: true) }
            overflow.removeAll(keepingCapacity: true)
        } else {
            bins = Array(repeating: [], count: wheelSize)
            overflow = []
        }
        cursor = newCursor
        eventCount = 0
        nextSequence = 1
    }

    public func validate() -> [NTDiagnostic] {
        var diagnostics: [NTDiagnostic] = []
        let actualCount = bins.reduce(0) { $0 + $1.count } + overflow.count
        if actualCount != eventCount {
            diagnostics.append(.init(
                severity: .fatal,
                code: .invalidReference,
                message: "Event-wheel accounting differs from stored event count."
            ))
        }
        if eventCount > maximumEvents {
            diagnostics.append(.init(
                severity: .fatal,
                code: .eventQueueOverflow,
                message: "Event wheel exceeds its configured capacity."
            ))
        }
        for event in overflow where event.deliveryTime < cursor {
            diagnostics.append(.init(
                severity: .fatal,
                code: .spikeOrderingFailure,
                message: "Overflow contains an event older than the cursor.",
                entity: event.source
            ))
        }
        return diagnostics
    }

    private func binIndex(for time: TissueTime) -> Int {
        Int((time.tick / binWidthTicks) % UInt64(wheelSize))
    }

    private mutating func insertOverflow(_ event: NTNeuralEvent) {
        let index = overflow.partitioningIndex { $0 >= event }
        overflow.insert(event, at: index)
    }

    private mutating func promoteOverflow() {
        guard !overflow.isEmpty else { return }
        let limit = cursor.tick &+ horizonTicks
        var promotedCount = 0
        while promotedCount < overflow.count && overflow[promotedCount].deliveryTime.tick < limit {
            let event = overflow[promotedCount]
            bins[binIndex(for: event.deliveryTime)].append(event)
            promotedCount += 1
        }
        if promotedCount > 0 { overflow.removeFirst(promotedCount) }
    }
}

private extension RandomAccessCollection {
    func partitioningIndex(where predicate: (Element) throws -> Bool) rethrows -> Index {
        var low = startIndex
        var count = distance(from: low, to: endIndex)
        while count > 0 {
            let half = count / 2
            let mid = index(low, offsetBy: half)
            if try predicate(self[mid]) {
                count = half
            } else {
                low = index(after: mid)
                count -= half + 1
            }
        }
        return low
    }
}

@frozen
public struct NTRouteRecord: Codable, Hashable, Sendable {
    public var id: RouteID
    public var sourceCompartmentIndex: UInt32
    public var destinationSynapseStart: UInt32
    public var destinationSynapseCount: UInt32
    public var delayTicks: UInt32
    public var failureProbability: Float
    public var amplitudeScale: Float
    public var destinationTile: TileID
    public var flags: UInt32

    public init(
        id: RouteID,
        sourceCompartmentIndex: UInt32,
        destinationSynapseStart: UInt32,
        destinationSynapseCount: UInt32,
        delayTicks: UInt32,
        failureProbability: Float = 0,
        amplitudeScale: Float = 1,
        destinationTile: TileID,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.sourceCompartmentIndex = sourceCompartmentIndex
        self.destinationSynapseStart = destinationSynapseStart
        self.destinationSynapseCount = destinationSynapseCount
        self.delayTicks = delayTicks
        self.failureProbability = failureProbability
        self.amplitudeScale = amplitudeScale
        self.destinationTile = destinationTile
        self.flags = flags
    }
}

public struct NTRouteTable: Codable, Sendable {
    public private(set) var routes: [NTRouteRecord]
    public private(set) var sourceOffsets: [UInt32]
    public private(set) var sourceRouteIndices: [UInt32]
    private var indexByID: [RouteID: UInt32]

    public init(routes: [NTRouteRecord] = [], compartmentCount: Int = 0) throws {
        self.routes = routes
        self.sourceOffsets = []
        self.sourceRouteIndices = []
        self.indexByID = [:]
        try rebuild(compartmentCount: compartmentCount)
    }

    public mutating func replace(routes: [NTRouteRecord], compartmentCount: Int) throws {
        self.routes = routes
        try rebuild(compartmentCount: compartmentCount)
    }

    public func route(id: RouteID) -> NTRouteRecord? {
        guard let index = indexByID[id] else { return nil }
        return routes[Int(index)]
    }

    public func routeIndices(sourceCompartmentIndex: Int) -> ArraySlice<UInt32> {
        guard sourceCompartmentIndex >= 0,
              sourceCompartmentIndex + 1 < sourceOffsets.count else { return [] }
        let start = Int(sourceOffsets[sourceCompartmentIndex])
        let end = Int(sourceOffsets[sourceCompartmentIndex + 1])
        return sourceRouteIndices[start..<end]
    }

    private mutating func rebuild(compartmentCount: Int) throws {
        indexByID.removeAll(keepingCapacity: true)
        var adjacency = Array(repeating: [UInt32](), count: max(0, compartmentCount))
        for (index, route) in routes.enumerated() {
            guard Int(route.sourceCompartmentIndex) < compartmentCount else {
                throw NTRuntimeError.invalidModel("Route source compartment is out of range.")
            }
            guard route.failureProbability >= 0 && route.failureProbability <= 1 else {
                throw NTRuntimeError.invalidModel("Route failure probability must be in [0, 1].")
            }
            guard indexByID.updateValue(UInt32(index), forKey: route.id) == nil else {
                throw NTRuntimeError.invalidModel("Route identifiers must be unique.")
            }
            adjacency[Int(route.sourceCompartmentIndex)].append(UInt32(index))
        }
        sourceOffsets = [0]
        sourceRouteIndices.removeAll(keepingCapacity: true)
        for indices in adjacency {
            sourceRouteIndices.append(contentsOf: indices.sorted { routes[Int($0)].id < routes[Int($1)].id })
            sourceOffsets.append(UInt32(sourceRouteIndices.count))
        }
    }

    private enum CodingKeys: String, CodingKey { case routes, sourceOffsets, sourceRouteIndices }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routes = try container.decode([NTRouteRecord].self, forKey: .routes)
        sourceOffsets = try container.decode([UInt32].self, forKey: .sourceOffsets)
        sourceRouteIndices = try container.decode([UInt32].self, forKey: .sourceRouteIndices)
        indexByID = Dictionary(uniqueKeysWithValues: routes.enumerated().map { ($0.element.id, UInt32($0.offset)) })
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routes, forKey: .routes)
        try container.encode(sourceOffsets, forKey: .sourceOffsets)
        try container.encode(sourceRouteIndices, forKey: .sourceRouteIndices)
    }
}

/// Tile-local queues plus 26 deterministic neighbor queues. Long-range events remain in the route wheel.
public struct NTTileEventQueues: Codable, Hashable, Sendable {
    public var local: [NTNeuralEvent]
    public var edges: [[NTNeuralEvent]]
    public var capacityPerQueue: Int

    public init(capacityPerQueue: Int) {
        self.local = []
        self.edges = Array(repeating: [], count: 26)
        self.capacityPerQueue = capacityPerQueue
        self.local.reserveCapacity(min(capacityPerQueue, 4_096))
    }

    public mutating func enqueueLocal(_ event: NTNeuralEvent) throws {
        guard local.count < capacityPerQueue else {
            throw NTRuntimeError.resourceExhausted("Tile-local event queue overflowed.")
        }
        local.append(event)
    }

    public mutating func enqueue(_ event: NTNeuralEvent, edge: Int) throws {
        guard edges.indices.contains(edge) else {
            throw NTRuntimeError.invalidModel("Neighbor edge index must be in 0..<26.")
        }
        guard edges[edge].count < capacityPerQueue else {
            throw NTRuntimeError.resourceExhausted("Tile edge event queue \(edge) overflowed.")
        }
        edges[edge].append(event)
    }

    public mutating func drainLocal() -> [NTNeuralEvent] {
        local.sort()
        defer { local.removeAll(keepingCapacity: true) }
        return local
    }

    public mutating func drain(edge: Int) -> [NTNeuralEvent] {
        guard edges.indices.contains(edge) else { return [] }
        edges[edge].sort()
        defer { edges[edge].removeAll(keepingCapacity: true) }
        return edges[edge]
    }
}

@frozen
public struct NTEventJournal: Codable, Sendable {
    public private(set) var accepted: [NTNeuralEvent]
    public private(set) var rejected: [NTNeuralEvent]
    public private(set) var generated: [NTNeuralEvent]

    public init() {
        accepted = []
        rejected = []
        generated = []
    }

    public mutating func recordAccepted(_ event: NTNeuralEvent) { accepted.append(event) }
    public mutating func recordRejected(_ event: NTNeuralEvent) { rejected.append(event) }
    public mutating func recordGenerated(_ event: NTNeuralEvent) { generated.append(event) }

    public mutating func canonicalize() {
        accepted.sort()
        rejected.sort()
        generated.sort()
    }
}
