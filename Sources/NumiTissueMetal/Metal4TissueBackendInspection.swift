#if canImport(Metal) && compiler(>=6.2)
import Foundation
import NumiTissueRuntime

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
extension Metal4TissueBackend: RuntimePhaseInspectableBackend {
    nonisolated public var numericalProfile: RuntimeNumericalProfile {
        options.effectiveNumericalProfile
    }

    public func captureShadowDigest(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context executionContext: ExecutionContext
    ) async throws -> RuntimePhaseDigestSnapshot {
        try await differentialInspection(
            phase: phase,
            tickRange: tickRange,
            context: executionContext
        ).digestSnapshot
    }

    public func exportShadowInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context executionContext: ExecutionContext
    ) async throws -> RuntimeShadowInspection {
        try await differentialInspection(
            phase: phase,
            tickRange: tickRange,
            context: executionContext
        )
    }

    func differentialInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context executionContext: ExecutionContext
    ) async throws -> RuntimeShadowInspection {
        guard currentContext?.transaction == executionContext.transaction,
              let arena else {
            throw RuntimeExecutionError.staleTransaction
        }
        try await ensureSubmitted()
        let state = try await arena.downloadShadowState()
        let wheel = try await arena.exportPersistentEventWheel(
            state: state,
            routingBlockTicks: executionContext.cadence.routingBlockTicks,
            minimumArrivalTick: executionContext.startTime.tick,
            wheel: arena.transient.shadowEventWheel
        )
        let pending = wheel.events.map { event -> RuntimePendingEvent in
            let target: RuntimePendingEventTarget
            switch event.target {
            case .synapse(let id): target = .synapse(id)
            case .raw(let value): target = .raw(value)
            }
            return RuntimePendingEvent(
                arrivalTick: event.arrivalTick,
                source: event.source,
                target: target,
                amplitude: event.amplitude,
                kind: RoutedEventKind(
                    rawValue: UInt16(truncatingIfNeeded: event.kindAndFlags)
                ) ?? .userDefined,
                flags: UInt16(truncatingIfNeeded: event.kindAndFlags >> 16),
                sequence: event.sequence
            )
        }.sorted()
        let counters = arena.transient.counters.contents()
            .load(as: MetalRuntimeCounters.self)
            .runtimeCounters()
        let statistics = currentEncodingStatistics
        let inspection = RuntimeShadowInspection(
            backendName: name,
            numericalProfile: numericalProfile,
            transaction: executionContext.transaction,
            phase: phase,
            tickRange: tickRange,
            state: state,
            pendingEvents: pending,
            counters: counters,
            metadata: [
                "device.name": context.capabilities.name,
                "device.registryID": String(context.capabilities.registryID),
                "metal.api": "4",
                "metal.mathProfile": numericalProfile.rawValue,
                "inspection.readback": "full-shadow",
                "inspection.commandBufferSplit": "true",
                "encoding.commands": String(statistics.commandCount),
                "encoding.dispatches": String(statistics.dispatchCount),
                "encoding.blits": String(statistics.blitCount),
                "encoding.barriers": String(statistics.barrierCount)
            ]
        )
        if phase != .validate {
            try startContinuationGroup()
        }
        return inspection
    }
}
#endif
