import Foundation
import NumiTissueCore

public enum RoutedEventKind: UInt16, Sendable, Codable, CaseIterable {
    case spike = 0
    case analogAfferent = 1
    case transmitterRelease = 2
    case neuromodulatorPulse = 3
    case electrodeStimulus = 4
    case damage = 5
    case topologyMutation = 6
    case cellMigration = 7
    case fieldSource = 8
    case userDefined = 65_535
}

@frozen
public struct RoutedEvent: Sendable, Hashable, Codable, Comparable {
    public var arrivalTick: UInt64
    public var source: UInt64
    public var destination: UInt64
    public var amplitude: Float
    public var kind: RoutedEventKind
    public var flags: UInt16
    public var sequence: UInt32

    public init(
        arrivalTick: UInt64,
        source: UInt64,
        destination: UInt64,
        amplitude: Float = 1,
        kind: RoutedEventKind = .spike,
        flags: UInt16 = 0,
        sequence: UInt32 = 0
    ) {
        self.arrivalTick = arrivalTick
        self.source = source
        self.destination = destination
        self.amplitude = amplitude
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.arrivalTick != rhs.arrivalTick { return lhs.arrivalTick < rhs.arrivalTick }
        if lhs.destination != rhs.destination { return lhs.destination < rhs.destination }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.sequence < rhs.sequence
    }
}

@frozen
public struct LongRangeRoute: Sendable, Hashable, Codable {
    public var id: RouteID
    public var source: UInt64
    public var destination: UInt64
    public var delayTicks: UInt32
    public var gain: Float
    public var lossProbability: Float
    public var destinationTileIndex: UInt32
    public var flags: UInt32

    public init(
        id: RouteID,
        source: UInt64,
        destination: UInt64,
        delayTicks: UInt32,
        gain: Float = 1,
        lossProbability: Float = 0,
        destinationTileIndex: UInt32,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.delayTicks = delayTicks
        self.gain = gain
        self.lossProbability = min(max(lossProbability, 0), 1)
        self.destinationTileIndex = destinationTileIndex
        self.flags = flags
    }
}

@frozen
public struct RouteFanout: Sendable, Hashable, Codable {
    public var source: UInt64
    public var routeRange: RuntimeRange

    public init(source: UInt64, routeRange: RuntimeRange) {
        self.source = source
        self.routeRange = routeRange
    }
}

public enum EventOverflowPolicy: UInt8, Sendable, Hashable, Codable {
    case rejectTransaction
    case dropLowestAmplitude
    case dropLatest
}

public enum EventRoutingError: Error, Sendable, CustomStringConvertible {
    case eventInPast(arrival: UInt64, current: UInt64)
    case horizonExceeded(arrival: UInt64, horizonEnd: UInt64)
    case capacityExceeded(capacity: Int)
    case invalidRouteRange
    case unsupportedSnapshotVersion(UInt32)
    case invalidSnapshot(String)

    public var description: String {
        switch self {
        case .eventInPast(let arrival, let current): return "Event at tick \(arrival) precedes current tick \(current)"
        case .horizonExceeded(let arrival, let end): return "Event at tick \(arrival) exceeds delay-wheel horizon ending at \(end)"
        case .capacityExceeded(let capacity): return "Event queue exceeded capacity \(capacity)"
        case .invalidRouteRange: return "Route fanout references an invalid route range"
        case .unsupportedSnapshotVersion(let version): return "Unsupported event-wheel snapshot version \(version)"
        case .invalidSnapshot(let reason): return "Invalid event-wheel snapshot: \(reason)"
        }
    }
}

/// Portable checkpoint representation of a bounded delay wheel. Events retain their assigned
/// sequence numbers, so restore does not change ordering among otherwise identical events.
@frozen
public struct EventDelayWheelSnapshot: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var originTick: UInt64
    public var bucketCount: Int
    public var bucketWidthTicks: UInt64
    public var capacity: Int
    public var overflowPolicy: EventOverflowPolicy
    public var nextSequence: UInt32
    public var events: [RoutedEvent]

    public init(
        schemaVersion: UInt32 = 1,
        originTick: UInt64,
        bucketCount: Int,
        bucketWidthTicks: UInt64,
        capacity: Int,
        overflowPolicy: EventOverflowPolicy,
        nextSequence: UInt32,
        events: [RoutedEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.originTick = originTick
        self.bucketCount = bucketCount
        self.bucketWidthTicks = bucketWidthTicks
        self.capacity = capacity
        self.overflowPolicy = overflowPolicy
        self.nextSequence = nextSequence
        self.events = events
    }

    public var horizonEndTick: UInt64 {
        originTick &+ UInt64(bucketCount) &* bucketWidthTicks
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw EventRoutingError.unsupportedSnapshotVersion(schemaVersion)
        }
        guard bucketCount > 1,
              bucketWidthTicks > 0,
              capacity > 0,
              events.count <= capacity else {
            throw EventRoutingError.invalidSnapshot("invalid dimensions or capacity")
        }
        let horizon = horizonEndTick
        guard horizon >= originTick else {
            throw EventRoutingError.invalidSnapshot("horizon overflow")
        }
        var ordered = events
        guard ordered.allSatisfy({
            $0.arrivalTick >= originTick &&
            $0.arrivalTick < horizon &&
            $0.amplitude.isFinite
        }) else {
            throw EventRoutingError.invalidSnapshot("event outside horizon or non-finite amplitude")
        }
        let sequences = Set(ordered.map(\.sequence))
        guard sequences.count == ordered.count,
              !sequences.contains(nextSequence) else {
            throw EventRoutingError.invalidSnapshot("active event sequence collision")
        }
        ordered.sort()
        var result = self
        result.events = ordered
        return result
    }
}

/// Deterministic bounded delay wheel. The GPU backend uses the same bucket mapping with atomic
/// reservation and a stable radix pass before delivery.
public struct EventDelayWheel: Sendable {
    public let bucketCount: Int
    public let bucketWidthTicks: UInt64
    public let capacity: Int
    public let overflowPolicy: EventOverflowPolicy

    private var originTick: UInt64
    private var buckets: [[RoutedEvent]]
    private var eventCount: Int
    private var nextSequence: UInt32

    public init(
        originTick: UInt64 = 0,
        bucketCount: Int = 4_096,
        bucketWidthTicks: UInt64 = RuntimeCadence.routingBlockTicks,
        capacity: Int,
        overflowPolicy: EventOverflowPolicy = .rejectTransaction
    ) {
        precondition(bucketCount > 1)
        precondition(bucketWidthTicks > 0)
        precondition(capacity > 0)
        self.bucketCount = bucketCount
        self.bucketWidthTicks = bucketWidthTicks
        self.capacity = capacity
        self.overflowPolicy = overflowPolicy
        self.originTick = originTick
        self.buckets = Array(repeating: [], count: bucketCount)
        self.eventCount = 0
        self.nextSequence = 0
    }

    public init(snapshot source: EventDelayWheelSnapshot) throws {
        let snapshot = try source.validated()
        bucketCount = snapshot.bucketCount
        bucketWidthTicks = snapshot.bucketWidthTicks
        capacity = snapshot.capacity
        overflowPolicy = snapshot.overflowPolicy
        originTick = snapshot.originTick
        buckets = Array(repeating: [], count: snapshot.bucketCount)
        eventCount = snapshot.events.count
        nextSequence = snapshot.nextSequence
        for event in snapshot.events {
            let index = Int(
                (event.arrivalTick / snapshot.bucketWidthTicks) %
                    UInt64(snapshot.bucketCount)
            )
            buckets[index].append(event)
        }
    }

    public var count: Int { eventCount }
    public var currentTick: UInt64 { originTick }
    public var horizonEndTick: UInt64 { originTick &+ UInt64(bucketCount) &* bucketWidthTicks }

    public var pendingEvents: [RoutedEvent] {
        buckets.flatMap { $0 }.sorted()
    }

    public func snapshot() -> EventDelayWheelSnapshot {
        EventDelayWheelSnapshot(
            originTick: originTick,
            bucketCount: bucketCount,
            bucketWidthTicks: bucketWidthTicks,
            capacity: capacity,
            overflowPolicy: overflowPolicy,
            nextSequence: nextSequence,
            events: pendingEvents
        )
    }

    public mutating func schedule(_ input: RoutedEvent) throws {
        guard input.arrivalTick >= originTick else {
            throw EventRoutingError.eventInPast(arrival: input.arrivalTick, current: originTick)
        }
        guard input.arrivalTick < horizonEndTick else {
            throw EventRoutingError.horizonExceeded(arrival: input.arrivalTick, horizonEnd: horizonEndTick)
        }
        guard input.amplitude.isFinite else {
            throw EventRoutingError.invalidSnapshot("scheduled event has non-finite amplitude")
        }

        var event = input
        event.sequence = nextSequence
        nextSequence &+= 1

        if eventCount >= capacity {
            try applyOverflow(with: event)
            return
        }

        let index = bucketIndex(for: event.arrivalTick)
        buckets[index].append(event)
        eventCount += 1
    }

    /// Scheduling a collection is atomic when any element fails. This is required because input
    /// ingestion is part of a transaction: a rejected batch cannot leave an accepted prefix.
    public mutating func schedule<S: Sequence>(contentsOf events: S) throws where S.Element == RoutedEvent {
        let previous = self
        do {
            for event in events { try schedule(event) }
        } catch {
            self = previous
            throw error
        }
    }

    /// Removes all events in [originTick, throughTick), preserving exact timestamp order.
    public mutating func pop(through throughTick: UInt64) throws -> [RoutedEvent] {
        guard throughTick >= originTick else {
            throw EventRoutingError.eventInPast(arrival: throughTick, current: originTick)
        }
        guard throughTick <= horizonEndTick else {
            throw EventRoutingError.horizonExceeded(arrival: throughTick, horizonEnd: horizonEndTick)
        }

        var delivered: [RoutedEvent] = []
        var tick = originTick
        while tick < throughTick {
            let index = bucketIndex(for: tick)
            if !buckets[index].isEmpty {
                var retained: [RoutedEvent] = []
                retained.reserveCapacity(buckets[index].count)
                for event in buckets[index] {
                    if event.arrivalTick < throughTick {
                        delivered.append(event)
                        eventCount -= 1
                    } else {
                        retained.append(event)
                    }
                }
                buckets[index] = retained
            }
            let nextBoundary = ((tick / bucketWidthTicks) &+ 1) &* bucketWidthTicks
            tick = max(tick &+ 1, min(nextBoundary, throughTick))
        }
        originTick = throughTick
        delivered.sort()
        return delivered
    }

    public mutating func reset(originTick: UInt64) {
        self.originTick = originTick
        for index in buckets.indices { buckets[index].removeAll(keepingCapacity: true) }
        eventCount = 0
        nextSequence = 0
    }

    private func bucketIndex(for tick: UInt64) -> Int {
        Int((tick / bucketWidthTicks) % UInt64(bucketCount))
    }

    private mutating func applyOverflow(with event: RoutedEvent) throws {
        switch overflowPolicy {
        case .rejectTransaction:
            throw EventRoutingError.capacityExceeded(capacity: capacity)
        case .dropLatest:
            return
        case .dropLowestAmplitude:
            var candidateBucket: Int?
            var candidateIndex: Int?
            var candidateMagnitude = abs(event.amplitude)
            for bucketIndex in buckets.indices {
                for eventIndex in buckets[bucketIndex].indices {
                    let magnitude = abs(buckets[bucketIndex][eventIndex].amplitude)
                    if magnitude < candidateMagnitude {
                        candidateMagnitude = magnitude
                        candidateBucket = bucketIndex
                        candidateIndex = eventIndex
                    }
                }
            }
            guard let candidateBucket, let candidateIndex else { return }
            buckets[candidateBucket].remove(at: candidateIndex)
            let index = bucketIndex(for: event.arrivalTick)
            buckets[index].append(event)
        }
    }
}

/// Immutable route table with source-contiguous fanout. It is directly serializable into GPU
/// buffers and does not allocate while routing.
public struct EventRouteTable: Sendable {
    public var fanouts: [RouteFanout]
    public var routes: [LongRangeRoute]
    private var fanoutBySource: [UInt64: Int]

    public init(fanouts: [RouteFanout], routes: [LongRangeRoute]) throws {
        self.fanouts = fanouts.sorted { $0.source < $1.source }
        self.routes = routes
        self.fanoutBySource = [:]
        self.fanoutBySource.reserveCapacity(fanouts.count)
        for (index, fanout) in self.fanouts.enumerated() {
            guard Int(fanout.routeRange.upperBound) <= routes.count else { throw EventRoutingError.invalidRouteRange }
            guard fanoutBySource.updateValue(index, forKey: fanout.source) == nil else {
                throw EventRoutingError.invalidRouteRange
            }
        }
    }

    public func route(
        sourceEvent: RoutedEvent,
        transaction: TransactionID,
        randomSeed: UInt64
    ) -> [RoutedEvent] {
        guard let fanoutIndex = fanoutBySource[sourceEvent.source] else { return [] }
        let range = fanouts[fanoutIndex].routeRange
        var output: [RoutedEvent] = []
        output.reserveCapacity(Int(range.count))

        for routeIndex in range.lowerBound..<range.upperBound {
            let route = routes[Int(routeIndex)]
            if route.lossProbability > 0 {
                let address = RandomAddress(
                    transaction: transaction.rawValue,
                    entity: route.id.rawValue,
                    stream: 0x5254,
                    sample: sourceEvent.sequence
                )
                let random = CounterRandom.generate(counter: address.counter(), key: PhiloxKey(seed: randomSeed))
                if CounterRandom.uniform01(random.x) < route.lossProbability { continue }
            }
            output.append(RoutedEvent(
                arrivalTick: sourceEvent.arrivalTick &+ UInt64(route.delayTicks),
                source: sourceEvent.source,
                destination: route.destination,
                amplitude: sourceEvent.amplitude * route.gain,
                kind: sourceEvent.kind,
                flags: sourceEvent.flags
            ))
        }
        return output
    }
}

/// Per-tile ingress and egress state used by CPU reference execution. Directional GPU edge queues
/// use fixed-capacity arrays and the same ordering contract.
public struct TileEventQueues: Sendable {
    public var local: EventDelayWheel
    public var incoming: [RoutedEvent]
    public var outgoing: [RoutedEvent]
    public var overflowed: Bool

    public init(capacity: Int, originTick: UInt64 = 0) {
        self.local = EventDelayWheel(originTick: originTick, capacity: capacity)
        self.incoming = []
        self.outgoing = []
        self.overflowed = false
        incoming.reserveCapacity(min(capacity, 4_096))
        outgoing.reserveCapacity(min(capacity, 4_096))
    }

    public mutating func importIncoming() throws {
        incoming.sort()
        do {
            try local.schedule(contentsOf: incoming)
            incoming.removeAll(keepingCapacity: true)
        } catch {
            overflowed = true
            throw error
        }
    }
}
