import Foundation
import NumiTissueCore

public extension RuntimeStateDigestBuilder {
    static func metadataDigest(state: TissueRuntimeState) -> RuntimeComparisonDigest {
        var digest = RuntimeDigestAccumulator(domain: 0x4D45_5441_4441_5441)
        digest.combine(state.time.tick)
        digest.combine(state.epoch)
        digest.combine(state.capacity.tiles)
        digest.combine(state.capacity.cells)
        digest.combine(state.capacity.segments)
        digest.combine(state.capacity.compartments)
        digest.combine(state.capacity.synapses)
        digest.combine(state.capacity.events)
        digest.combine(state.capacity.fieldValues)
        digest.combine(state.capacity.microdomains)
        digest.combine(state.capacity.molecularSpecies)
        return digest.finalize()
    }

    static func pendingEventsDigest(
        _ sourceEvents: [RuntimePendingEvent]
    ) -> RuntimeComparisonDigest {
        let events = sourceEvents.sorted()
        var digest = RuntimeDigestAccumulator(domain: 0x4556_454E_5453_0001)
        digest.combine(events.count)
        for event in events {
            digest.combine(event.arrivalTick)
            digest.combine(event.source)
            switch event.target {
            case .synapse(let identifier):
                digest.combine(UInt8(0))
                digest.combine(identifier.rawValue)
            case .raw(let value):
                digest.combine(UInt8(1))
                digest.combine(value)
            }
            digest.combine(event.amplitude)
            digest.combine(event.kind.rawValue)
            digest.combine(event.flags)
            digest.combine(event.sequence)
        }
        return digest.finalize()
    }
}

public extension RuntimePhaseDigestSnapshot {
    init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        transaction: TransactionID,
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        counts: RuntimeCapacity,
        pendingEventCount: Int,
        poolDigests: RuntimePoolDigests,
        counters: RuntimeCounters,
        metadata: [String: String] = [:]
    ) {
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.transaction = transaction
        self.phase = phase
        self.tickRange = tickRange
        self.counts = counts
        self.pendingEventCount = pendingEventCount
        self.poolDigests = poolDigests
        self.counters = counters
        self.metadata = metadata
    }
}
