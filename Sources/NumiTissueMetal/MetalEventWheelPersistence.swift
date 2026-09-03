#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

public enum MetalPersistentEventTarget: Sendable, Hashable, Codable {
    case synapse(SynapseID)
    case raw(UInt64)
}

public struct MetalPersistentScheduledEvent: Sendable, Hashable, Codable {
    public var arrivalTick: UInt64
    public var source: UInt64
    public var target: MetalPersistentEventTarget
    public var kindAndFlags: UInt32
    public var sequence: UInt32
    public var amplitude: Float
    public var payload0: Float
    public var payload1: Float
    public var payload2: Float

    public init(
        arrivalTick: UInt64,
        source: UInt64,
        target: MetalPersistentEventTarget,
        kindAndFlags: UInt32,
        sequence: UInt32,
        amplitude: Float,
        payload0: Float = 0,
        payload1: Float = 0,
        payload2: Float = 0
    ) {
        self.arrivalTick = arrivalTick
        self.source = source
        self.target = target
        self.kindAndFlags = kindAndFlags & ~Self.deliveredFlag
        self.sequence = sequence
        self.amplitude = amplitude
        self.payload0 = payload0
        self.payload1 = payload1
        self.payload2 = payload2
    }

    public static let deliveredFlag: UInt32 = 0x8000_0000

    public func validated() throws -> Self {
        guard amplitude.isFinite,
              payload0.isFinite,
              payload1.isFinite,
              payload2.isFinite else {
            throw MetalEventWheelPersistenceError.nonFiniteEvent
        }
        var result = self
        result.kindAndFlags &= ~Self.deliveredFlag
        return result
    }

    fileprivate init(
        metalEvent: MetalEvent,
        state: TissueRuntimeState
    ) throws {
        let arrivalTick = Self.combine(
            low: metalEvent.arrivalTickLo,
            high: metalEvent.arrivalTickHi
        )
        let source = Self.combine(
            low: metalEvent.sourceLo,
            high: metalEvent.sourceHi
        )
        let destination = Self.combine(
            low: metalEvent.destinationLo,
            high: metalEvent.destinationHi
        )
        let target: MetalPersistentEventTarget
        if destination < UInt64(state.synapses.count) {
            let synapse = state.synapses[Int(destination)]
            if Int(synapse.sourceRouteIndex) < state.compartments.count,
               state.compartments[Int(synapse.sourceRouteIndex)].id.rawValue == source {
                target = .synapse(synapse.id)
            } else {
                target = .raw(destination)
            }
        } else {
            target = .raw(destination)
        }
        self.init(
            arrivalTick: arrivalTick,
            source: source,
            target: target,
            kindAndFlags: metalEvent.kindAndFlags,
            sequence: metalEvent.sequence,
            amplitude: metalEvent.amplitude,
            payload0: metalEvent.payload0,
            payload1: metalEvent.payload1,
            payload2: metalEvent.payload2
        )
        _ = try validated()
    }

    fileprivate func metalEvent(
        synapseIndexByID: [SynapseID: UInt32]
    ) throws -> MetalEvent {
        let destination: UInt64
        switch target {
        case .synapse(let id):
            guard let index = synapseIndexByID[id] else {
                throw MetalEventWheelPersistenceError.missingSynapse(id)
            }
            destination = UInt64(index)
        case .raw(let value):
            destination = value
        }
        return MetalEvent(
            arrivalTickLo: UInt32(truncatingIfNeeded: arrivalTick),
            arrivalTickHi: UInt32(truncatingIfNeeded: arrivalTick >> 32),
            sourceLo: UInt32(truncatingIfNeeded: source),
            sourceHi: UInt32(truncatingIfNeeded: source >> 32),
            destinationLo: UInt32(truncatingIfNeeded: destination),
            destinationHi: UInt32(truncatingIfNeeded: destination >> 32),
            kindAndFlags: kindAndFlags & ~Self.deliveredFlag,
            sequence: sequence,
            amplitude: amplitude,
            payload0: payload0,
            payload1: payload1,
            payload2: payload2
        )
    }

    private static func combine(low: UInt32, high: UInt32) -> UInt64 {
        UInt64(low) | (UInt64(high) << 32)
    }
}

public struct MetalEventWheelSnapshot: Sendable, Hashable, Codable {
    public var routingBlockTicks: UInt64
    public var minimumArrivalTick: UInt64
    public var events: [MetalPersistentScheduledEvent]

    public init(
        routingBlockTicks: UInt64,
        minimumArrivalTick: UInt64,
        events: [MetalPersistentScheduledEvent]
    ) {
        self.routingBlockTicks = routingBlockTicks
        self.minimumArrivalTick = minimumArrivalTick
        self.events = events
    }

    public static func empty(
        routingBlockTicks: UInt64,
        minimumArrivalTick: UInt64
    ) -> Self {
        Self(
            routingBlockTicks: routingBlockTicks,
            minimumArrivalTick: minimumArrivalTick,
            events: []
        )
    }

    public func validated() throws -> Self {
        guard routingBlockTicks > 0 else {
            throw MetalEventWheelPersistenceError.invalidRoutingBlockTicks
        }
        var result = self
        result.events = try events.map { event in
            let valid = try event.validated()
            guard valid.arrivalTick >= minimumArrivalTick else {
                throw MetalEventWheelPersistenceError.overdueEvent(
                    arrivalTick: valid.arrivalTick,
                    minimumArrivalTick: minimumArrivalTick
                )
            }
            return valid
        }.sorted(by: Self.eventOrder)
        return result
    }

    public func partitioned(
        for state: TissueRuntimeState,
        additionalEvents: [MetalPersistentScheduledEvent] = []
    ) throws -> (
        active: MetalEventWheelSnapshot,
        deferred: [MetalPersistentScheduledEvent]
    ) {
        let valid = try validated()
        let synapseIDs = Set(state.synapses.map(\.id))
        var active: [MetalPersistentScheduledEvent] = []
        var deferred: [MetalPersistentScheduledEvent] = []
        active.reserveCapacity(valid.events.count + additionalEvents.count)
        deferred.reserveCapacity(additionalEvents.count)

        for source in valid.events + additionalEvents {
            let event = try source.validated()
            guard event.arrivalTick >= minimumArrivalTick else { continue }
            switch event.target {
            case .synapse(let id) where !synapseIDs.contains(id):
                deferred.append(event)
            default:
                active.append(event)
            }
        }
        active.sort(by: Self.eventOrder)
        deferred.sort(by: Self.eventOrder)
        return (
            MetalEventWheelSnapshot(
                routingBlockTicks: valid.routingBlockTicks,
                minimumArrivalTick: valid.minimumArrivalTick,
                events: active
            ),
            deferred
        )
    }

    fileprivate static func eventOrder(
        _ lhs: MetalPersistentScheduledEvent,
        _ rhs: MetalPersistentScheduledEvent
    ) -> Bool {
        if lhs.arrivalTick != rhs.arrivalTick {
            return lhs.arrivalTick < rhs.arrivalTick
        }
        switch (lhs.target, rhs.target) {
        case (.synapse(let left), .synapse(let right)):
            if left != right { return left < right }
        case (.raw(let left), .raw(let right)):
            if left != right { return left < right }
        case (.synapse, .raw):
            return true
        case (.raw, .synapse):
            return false
        }
        if lhs.source != rhs.source {
            return lhs.source < rhs.source
        }
        let lhsKind = lhs.kindAndFlags & 0xFFFF
        let rhsKind = rhs.kindAndFlags & 0xFFFF
        if lhsKind != rhsKind {
            return lhsKind < rhsKind
        }
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.kindAndFlags < rhs.kindAndFlags
    }
}

public extension MetalStateArena {
    static let persistentEventBucketCount = 4_096

    func exportPersistentEventWheel(
        state: TissueRuntimeState,
        routingBlockTicks: UInt64,
        minimumArrivalTick: UInt64,
        wheel: MetalEventWheelBuffers? = nil
    ) async throws -> MetalEventWheelSnapshot {
        guard routingBlockTicks > 0 else {
            throw MetalEventWheelPersistenceError.invalidRoutingBlockTicks
        }
        guard transient.eventCapacity >= Self.persistentEventBucketCount else {
            throw MetalEventWheelPersistenceError.eventCapacityTooSmall(
                transient.eventCapacity
            )
        }
        let bucketCapacity = transient.eventCapacity
            / Self.persistentEventBucketCount
        guard bucketCapacity > 0 else {
            throw MetalEventWheelPersistenceError.eventCapacityTooSmall(
                transient.eventCapacity
            )
        }

        guard let counts = context.device.makeBuffer(
            length: transient.eventBucketCounts.length,
            options: .storageModeShared
        ), let events = context.device.makeBuffer(
            length: transient.localEvents.length,
            options: .storageModeShared
        ) else {
            throw MetalRuntimeError.bufferAllocationFailed(label: "NT.Migration.EventBuffers", bytes: transient.eventBucketCounts.length + transient.localEvents.length)
        }
        counts.label = "NT.Migration.EventCounts.Readback"
        events.label = "NT.Migration.Events.Readback"

        let commandBuffer = try context.makeTransferCommandBuffer(
            label: "NT.Migration.ExportEventWheel"
        )
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("NT.Migration.EventWheel")
        }
        blit.copy(
            from: (wheel ?? transient.committedEventWheel).eventBucketCounts,
            sourceOffset: 0,
            to: counts,
            destinationOffset: 0,
            size: (wheel ?? transient.committedEventWheel).eventBucketCounts.length
        )
        blit.copy(
            from: (wheel ?? transient.committedEventWheel).localEvents,
            sourceOffset: 0,
            to: events,
            destinationOffset: 0,
            size: (wheel ?? transient.committedEventWheel).localEvents.length
        )
        blit.endEncoding()
        try await context.awaitCompletion(commandBuffer)

        let countPointer = counts.contents().bindMemory(
            to: UInt32.self,
            capacity: Self.persistentEventBucketCount
        )
        let eventPointer = events.contents().bindMemory(
            to: MetalEvent.self,
            capacity: transient.eventCapacity
        )
        var result: [MetalPersistentScheduledEvent] = []

        for bucket in 0..<Self.persistentEventBucketCount {
            let reported = Int(countPointer[bucket])
            guard reported <= bucketCapacity else {
                throw MetalEventWheelPersistenceError.bucketOverflow(
                    bucket: bucket,
                    reported: reported,
                    capacity: bucketCapacity
                )
            }
            for slot in 0..<reported {
                let event = eventPointer[bucket * bucketCapacity + slot]
                guard event.kindAndFlags
                        & MetalPersistentScheduledEvent.deliveredFlag == 0 else {
                    continue
                }
                let persistent = try MetalPersistentScheduledEvent(
                    metalEvent: event,
                    state: state
                )
                guard persistent.arrivalTick >= minimumArrivalTick else {
                    throw MetalEventWheelPersistenceError.overdueEvent(
                        arrivalTick: persistent.arrivalTick,
                        minimumArrivalTick: minimumArrivalTick
                    )
                }
                result.append(persistent)
            }
        }
        return try MetalEventWheelSnapshot(
            routingBlockTicks: routingBlockTicks,
            minimumArrivalTick: minimumArrivalTick,
            events: result
        ).validated()
    }

    func importPersistentEventWheel(
        _ source: MetalEventWheelSnapshot,
        state: TissueRuntimeState
    ) async throws {
        let snapshot = try source.validated()
        guard transient.eventCapacity >= Self.persistentEventBucketCount else {
            throw MetalEventWheelPersistenceError.eventCapacityTooSmall(
                transient.eventCapacity
            )
        }
        let bucketCapacity = transient.eventCapacity
            / Self.persistentEventBucketCount
        guard bucketCapacity > 0 else {
            throw MetalEventWheelPersistenceError.eventCapacityTooSmall(
                transient.eventCapacity
            )
        }

        var synapseIndexByID: [SynapseID: UInt32] = [:]
        synapseIndexByID.reserveCapacity(state.synapses.count)
        for (index, synapse) in state.synapses.enumerated() {
            guard synapseIndexByID.updateValue(
                UInt32(index),
                forKey: synapse.id
            ) == nil else {
                throw MetalEventWheelPersistenceError.duplicateSynapseID(
                    synapse.id
                )
            }
        }

        guard let counts = context.device.makeBuffer(
            length: transient.eventBucketCounts.length,
            options: .storageModeShared
        ), let events = context.device.makeBuffer(
            length: transient.localEvents.length,
            options: .storageModeShared
        ) else {
            throw MetalRuntimeError.bufferAllocationFailed(label: "NT.Migration.EventBuffers", bytes: transient.eventBucketCounts.length + transient.localEvents.length)
        }
        counts.label = "NT.Migration.EventCounts.Upload"
        events.label = "NT.Migration.Events.Upload"
        memset(counts.contents(), 0, counts.length)
        memset(events.contents(), 0, events.length)

        let countPointer = counts.contents().bindMemory(
            to: UInt32.self,
            capacity: Self.persistentEventBucketCount
        )
        let eventPointer = events.contents().bindMemory(
            to: MetalEvent.self,
            capacity: transient.eventCapacity
        )
        for persistent in snapshot.events {
            let event = try persistent.metalEvent(
                synapseIndexByID: synapseIndexByID
            )
            let bucket = Int(
                (persistent.arrivalTick / snapshot.routingBlockTicks)
                    % UInt64(Self.persistentEventBucketCount)
            )
            let slot = Int(countPointer[bucket])
            guard slot < bucketCapacity else {
                throw MetalEventWheelPersistenceError.bucketOverflow(
                    bucket: bucket,
                    reported: slot + 1,
                    capacity: bucketCapacity
                )
            }
            eventPointer[bucket * bucketCapacity + slot] = event
            countPointer[bucket] = UInt32(slot + 1)
        }

        let commandBuffer = try context.makeTransferCommandBuffer(
            label: "NT.Migration.ImportEventWheel"
        )
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("NT.Migration.EventWheel")
        }
        blit.copy(
            from: counts,
            sourceOffset: 0,
            to: transient.committedEventBucketCounts,
            destinationOffset: 0,
            size: transient.committedEventBucketCounts.length
        )
        blit.copy(
            from: events,
            sourceOffset: 0,
            to: transient.committedLocalEvents,
            destinationOffset: 0,
            size: transient.committedLocalEvents.length
        )
        blit.copy(
            from: counts,
            sourceOffset: 0,
            to: transient.shadowEventWheel.eventBucketCounts,
            destinationOffset: 0,
            size: transient.shadowEventWheel.eventBucketCounts.length
        )
        blit.copy(
            from: events,
            sourceOffset: 0,
            to: transient.shadowEventWheel.localEvents,
            destinationOffset: 0,
            size: transient.shadowEventWheel.localEvents.length
        )
        blit.endEncoding()
        try await context.awaitCompletion(commandBuffer)
    }
}

public enum MetalEventWheelPersistenceError: Error, Sendable, CustomStringConvertible {
    case invalidRoutingBlockTicks
    case stateTickMismatch(snapshot: UInt64, committed: UInt64)
    case routingBlockMismatch(snapshot: UInt64, expected: UInt64)
    case eventCapacityTooSmall(Int)
    case bucketOverflow(bucket: Int, reported: Int, capacity: Int)
    case overdueEvent(arrivalTick: UInt64, minimumArrivalTick: UInt64)
    case nonFiniteEvent
    case duplicateSynapseID(SynapseID)
    case missingSynapse(SynapseID)

    public var description: String {
        switch self {
        case .invalidRoutingBlockTicks:
            return "Metal event-wheel routing cadence must be positive"
        case .stateTickMismatch(let snapshot, let committed):
            return "Metal event-wheel snapshot minimum tick \(snapshot) does not match committed tissue tick \(committed)"
        case .routingBlockMismatch(let snapshot, let expected):
            return "Metal event-wheel routing cadence \(snapshot) does not match the active cadence \(expected)"
        case .eventCapacityTooSmall(let capacity):
            return "Metal event capacity \(capacity) is below the 4096-bucket wheel minimum"
        case .bucketOverflow(let bucket, let reported, let capacity):
            return "Metal event bucket \(bucket) contains \(reported) events but capacity is \(capacity)"
        case .overdueEvent(let arrivalTick, let minimumArrivalTick):
            return "Undelivered Metal event at tick \(arrivalTick) is earlier than migration boundary \(minimumArrivalTick)"
        case .nonFiniteEvent:
            return "Metal event-wheel snapshot contains a non-finite payload"
        case .duplicateSynapseID(let id):
            return "Metal event-wheel target state contains duplicate synapse identifier \(id)"
        case .missingSynapse(let id):
            return "Metal event-wheel restoration is missing target synapse \(id)"
        }
    }
}
#endif
