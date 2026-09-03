#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
extension Metal4TissueBackend {
    public func collectOutput(
        context executionContext: ExecutionContext
    ) async throws -> RuntimeOutputFrame {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        try await ensureSubmitted()

        let counter = arena.transient.counters.contents().load(
            as: MetalRuntimeCounters.self
        )
        let generated64 = UInt64(counter.generatedSpikesLo) |
            (UInt64(counter.generatedSpikesHi) << 32)
        guard generated64 <= UInt64(arena.transient.eventCapacity) else {
            throw MetalRuntimeError.capacityExceeded("output events")
        }
        let generated = Int(generated64)
        let pointer = arena.transient.outputEvents.contents().bindMemory(
            to: MetalEvent.self,
            capacity: max(generated, 1)
        )
        var output = RuntimeOutputFrame(
            startTime: executionContext.startTime,
            endTime: executionContext.endTime
        )
        output.efferentEvents.reserveCapacity(generated)
        for index in 0..<generated {
            output.efferentEvents.append(pointer[index].metal4RoutedEvent)
        }

        let tileCount = arena.committedCPUState.tiles.count
        let scalars = arena.transient.outputScalars.contents().bindMemory(
            to: Float.self,
            capacity: max(16 + tileCount * 4, 1)
        )
        output.populationActivity.reserveCapacity(tileCount)
        output.localFieldPotentials.reserveCapacity(tileCount)
        output.metabolicDemand.reserveCapacity(tileCount)
        var damage: Float = 0
        for tile in 0..<tileCount {
            let base = 16 + tile * 4
            output.localFieldPotentials.append(scalars[base])
            output.populationActivity.append(scalars[base + 2])
            output.metabolicDemand.append(max(scalars[base + 3], 0))
            damage = max(damage, scalars[base + 3])
        }
        output.uncertainty = arena.committedCPUState.tiles
            .map(\.uncertaintyScore)
            .max() ?? 0
        output.plasticityMagnitude = abs(scalars[0])
        if damage > 0.5 {
            output.damageEvents.append(
                RoutedEvent(
                    arrivalTick: executionContext.endTime.tick,
                    source: 0,
                    destination: 0,
                    amplitude: damage,
                    kind: .damage
                )
            )
        }
        return output
    }

    public func validateShadow(
        context executionContext: ExecutionContext
    ) async throws -> [RuntimeValidationIssue] {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        try await ensureSubmitted()

        let counters = arena.transient.counters.contents().load(
            as: MetalRuntimeCounters.self
        )
        let reportedCount = Int(counters.validationCount)
        let count = min(
            reportedCount,
            arena.transient.validationCapacity
        )
        let records = arena.transient.validationRecords.contents().bindMemory(
            to: MetalValidationRecord.self,
            capacity: max(count, 1)
        )
        var issues: [RuntimeValidationIssue] = []
        issues.reserveCapacity(count + 2)
        for index in 0..<count {
            let record = records[index]
            issues.append(
                RuntimeValidationIssue(
                    severity: record.severity == 0 ? .warning : .reject,
                    code: record.code,
                    entity: UInt64(record.entityLo) |
                        (UInt64(record.entityHi) << 32),
                    value: record.value,
                    message: Self.validationMessage(
                        code: record.code,
                        index: record.index
                    )
                )
            )
        }
        if reportedCount > arena.transient.validationCapacity {
            issues.append(
                RuntimeValidationIssue(
                    severity: .reject,
                    code: ValidationCode.eventOverflow,
                    entity: 0,
                    value: Float(reportedCount),
                    message: "Metal 4 validation records exceeded bounded capacity \(arena.transient.validationCapacity)"
                )
            )
        }

        if !issues.contains(where: { $0.severity == .reject }) {
            do {
                try await prepareFidelityMigrationIfNeeded(
                    context: executionContext
                )
            } catch {
                issues.append(
                    RuntimeValidationIssue(
                        severity: .reject,
                        code: ValidationCode.invalidTopology,
                        entity: 0,
                        value: 0,
                        message: "Adaptive-fidelity migration rejected: \(error)"
                    )
                )
            }
        }
        return issues
    }

    public func commitShadow(
        context executionContext: ExecutionContext
    ) async throws {
        guard let activeArena = arena else {
            throw MetalRuntimeError.stateNotLoaded
        }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        try await ensureSubmitted()
        try await prepareFidelityMigrationIfNeeded(
            context: executionContext
        )

        retainedCounters = (
            executionContext.transaction,
            activeArena.transient.counters.contents()
                .load(as: MetalRuntimeCounters.self)
                .runtimeCounters()
        )

        if let pending = fidelityMigration.pending {
            try await installMigratedState(pending.state)
        } else {
            activeArena.commit(
                time: executionContext.endTime,
                epoch: executionContext.epoch &+ 1
            )
        }
        fidelityMigration.commit()
        explicitFidelityPlanStaged = false
        lastEncodingStatistics = currentEncodingStatistics
        clearOpenTransaction()
    }

    public func rollbackShadow(
        context executionContext: ExecutionContext
    ) async {
        guard currentContext?.transaction == executionContext.transaction else {
            return
        }
        if let session = encodingSession {
            metal4Context.abandon(session.lease)
            encodingSession = nil
        }
        if let arena {
            retainedCounters = (
                executionContext.transaction,
                arena.transient.counters.contents()
                    .load(as: MetalRuntimeCounters.self)
                    .runtimeCounters()
            )
            arena.rollback()
        }
        fidelityMigration.rollback()
        explicitFidelityPlanStaged = false
        lastEncodingStatistics = currentEncodingStatistics
        clearOpenTransaction()
    }

    public func counters(
        context executionContext: ExecutionContext
    ) async -> RuntimeCounters {
        if let retainedCounters,
           retainedCounters.transaction == executionContext.transaction {
            return retainedCounters.value
        }
        guard let arena else { return RuntimeCounters() }
        return arena.transient.counters.contents()
            .load(as: MetalRuntimeCounters.self)
            .runtimeCounters()
    }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        return try await arena.downloadCommittedState()
    }

    func ensureEncodingCapacity(
        requiredCommands: Int
    ) async throws {
        guard requiredCommands > 0 else { return }
        guard let session else {
            throw MetalRuntimeError.noOpenTransaction
        }
        let projected = session.statistics.commandCount
            .addingReportingOverflow(requiredCommands)
        guard !projected.overflow else {
            throw Metal4BackendExecutionError.commandCountOverflow
        }
        guard projected.partialValue >
                metal4Configuration.maximumDispatchesPerGroup else {
            return
        }

        switch metal4Configuration.batchingMode {
        case .unifiedTransaction:
            throw Metal4BackendExecutionError.unifiedGroupCapacityExceeded(
                required: projected.partialValue,
                capacity: metal4Configuration.maximumDispatchesPerGroup
            )
        case .phaseBoundaries, .boundedDispatchGroups:
            try await submitCurrentGroup()
            try startContinuationGroup()
            guard requiredCommands <=
                    metal4Configuration.maximumDispatchesPerGroup else {
                throw Metal4BackendExecutionError.singleOperationTooLarge(
                    required: requiredCommands,
                    capacity: metal4Configuration.maximumDispatchesPerGroup
                )
            }
        }
    }

    func finishPhaseGroupIfRequired(
        after phase: RuntimePhase
    ) async throws {
        guard metal4Configuration.batchingMode == .phaseBoundaries else {
            return
        }
        let submitted = try await submitCurrentGroup()
        if submitted, phase != .validate {
            try startContinuationGroup()
        }
    }

    @discardableResult
    func submitCurrentGroup() async throws -> Bool {
        guard let session = encodingSession else {
            return false
        }
        let statistics = session.statistics
        if statistics.commandCount == 0 {
            metal4Context.abandon(session.lease)
            encodingSession = nil
            commandSubmitted = true
            return false
        }

        try session.markEnded()
        accumulate(statistics)
        encodingSession = nil
        commandSubmitted = true
        _ = try await metal4Context.submit(session.lease)
        return true
    }

    func ensureSubmitted() async throws {
        if encodingSession != nil {
            _ = try await submitCurrentGroup()
        } else if !commandSubmitted {
            throw MetalRuntimeError.noOpenTransaction
        }
    }

    func startContinuationGroup() throws {
        guard currentContext != nil else {
            throw MetalRuntimeError.noOpenTransaction
        }
        guard encodingSession == nil else {
            throw Metal4BackendExecutionError.continuationWhileEncoding
        }
        let lease = try metal4Context.beginUnifiedComputePass()
        encodingSession = Metal4EncodingSession(
            lease: lease,
            configuration: metal4Configuration,
            telemetry: metal4Context.telemetry
        )
        phaseHeaderRing?.reset()
        commandSubmitted = false
    }

    func accumulate(_ statistics: Metal4EncodingStatistics) {
        currentEncodingStatistics.commandCount += statistics.commandCount
        currentEncodingStatistics.dispatchCount += statistics.dispatchCount
        currentEncodingStatistics.blitCount += statistics.blitCount
        currentEncodingStatistics.barrierCount += statistics.barrierCount
        currentEncodingStatistics.directDispatchCount +=
            statistics.directDispatchCount
        currentEncodingStatistics.indirectDispatchCount +=
            statistics.indirectDispatchCount
        currentEncodingStatistics.encodedThreadCount &+=
            statistics.encodedThreadCount
    }

    func prepareFidelityMigrationIfNeeded(
        context executionContext: ExecutionContext
    ) async throws {
        guard !fidelityPreparationAttempted else { return }
        fidelityPreparationAttempted = true
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        let counters = arena.transient.counters.contents().load(
            as: MetalRuntimeCounters.self
        )
        guard explicitFidelityPlanStaged ||
                counters.promotedEntities > 0 ||
                counters.demotedEntities > 0 else {
            return
        }
        let shadow = try await arena.downloadShadowState()
        _ = try fidelityMigration.prepare(
            committedTemplate: arena.committedCPUState,
            shadow: shadow,
            execution: executionContext
        )
    }

    func installMigratedState(
        _ state: TissueRuntimeState
    ) async throws {
        guard let shaders = shaderLibrary,
              let activeArena = arena else {
            throw MetalRuntimeError.stateNotLoaded
        }
        var normalized = state
        normalized.reserveCapacity(normalized.capacity)
        try normalized.validateCapacity()

        let migratedEventWheel = try await activeArena.exportPersistentEventWheel(
            state: normalized,
            routingBlockTicks: checkpointRoutingBlockTicks ??
                RuntimeCadence.routingBlockTicks,
            minimumArrivalTick: normalized.time.tick,
            wheel: activeArena.transient.shadowEventWheel
        )
        let replacement = try MetalStateArena(
            context: context,
            initialState: normalized
        )
        try await replacement.uploadInitialState(normalized)
        let tables = try makeArgumentTables(
            arena: replacement,
            shaders: shaders
        )
        try await clearPersistentTransientState(
            arena: replacement,
            shaders: shaders,
            table: try shadowArgumentTable(
                in: tables,
                arena: replacement
            )
        )
        try await replacement.importPersistentEventWheel(
            migratedEventWheel,
            state: normalized
        )

        arena = replacement
        argumentTables = tables
        argumentTableCache.invalidateAll()
        maxCableDepth = Self.cableDepth(in: normalized)
        try refreshStableResidency()
    }

    func makeArgumentTables(
        arena: MetalStateArena,
        shaders: MetalShaderLibrary
    ) throws -> [ObjectIdentifier: MetalArgumentTable] {
        let committed = try MetalArgumentTable(
            context: context,
            shaderLibrary: shaders,
            state: arena.committed,
            transient: arena.transient,
            label: "NumiTissue.Metal4.arguments.committed",
            eventWheel: arena.transient.committedEventWheel
        )
        let shadow = try MetalArgumentTable(
            context: context,
            shaderLibrary: shaders,
            state: arena.shadow,
            transient: arena.transient,
            label: "NumiTissue.Metal4.arguments.shadow",
            eventWheel: arena.transient.shadowEventWheel
        )
        return [
            ObjectIdentifier(arena.committed): committed,
            ObjectIdentifier(arena.shadow): shadow
        ]
    }

    func shadowArgumentTable(
        in tables: [ObjectIdentifier: MetalArgumentTable],
        arena: MetalStateArena
    ) throws -> MetalArgumentTable {
        guard let table = tables[ObjectIdentifier(arena.shadow)] else {
            throw MetalRuntimeError.stateNotLoaded
        }
        return table
    }

    func refreshStableResidency() throws {
        guard let arena,
              let ring = phaseHeaderRing else {
            throw MetalRuntimeError.stateNotLoaded
        }
        lastStableResidencySnapshot = try stableResidency.install(
            allocations: Metal4ResidencyCatalog.allocations(
                context: context,
                arena: arena,
                argumentTables: Array(argumentTables.values),
                phaseHeaderRing: ring,
                pipelines: cachedPipelines
            ),
            label: "NumiTissue.Metal4.stable"
        )
    }

    func clearOpenTransaction() {
        if let activeOverlayBuffers {
            _ = argumentTableCache.invalidate(referencing: [
                activeOverlayBuffers.groups,
                activeOverlayBuffers.records,
                activeOverlayBuffers.parameters
            ])
        }
        transactionResidency.clear()
        currentContext = nil
        currentInput = nil
        encodingSession = nil
        commandSubmitted = false
        stagedOverlay = nil
        activeOverlayBuffers = nil
        fidelityPreparationAttempted = false
        lastTransactionResidencySnapshot = nil
    }

    static func validationMessage(
        code: UInt32,
        index: UInt32
    ) -> String {
        switch code {
        case ValidationCode.nonFinite:
            return "Non-finite GPU state at index \(index)"
        case ValidationCode.negativeConcentration:
            return "Negative concentration at index \(index)"
        case ValidationCode.invalidTopology:
            return "Invalid packed topology at index \(index)"
        case ValidationCode.eventOverflow:
            return "GPU event bucket overflow"
        case ValidationCode.voltageBounds:
            return "Membrane voltage outside configured bounds"
        case ValidationCode.positiveCellVolume:
            return "Cell geometry outside configured bounds"
        case ValidationCode.metabolicBounds:
            return "Metabolic or damage state outside configured bounds"
        case ValidationCode.weightBounds:
            return "Synaptic weight outside configured bounds"
        default:
            return "NumiTissue Metal 4 validation code \(code) at index \(index)"
        }
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
private extension MetalEvent {
    var metal4RoutedEvent: RoutedEvent {
        RoutedEvent(
            arrivalTick: UInt64(arrivalTickLo) |
                (UInt64(arrivalTickHi) << 32),
            source: UInt64(sourceLo) | (UInt64(sourceHi) << 32),
            destination: UInt64(destinationLo) |
                (UInt64(destinationHi) << 32),
            amplitude: amplitude,
            kind: RoutedEventKind(
                rawValue: UInt16(truncatingIfNeeded: kindAndFlags)
            ) ?? .userDefined,
            flags: UInt16(truncatingIfNeeded: kindAndFlags >> 16),
            sequence: sequence
        )
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4BackendExecutionError: Error, Sendable, CustomStringConvertible {
    case commandCountOverflow
    case unifiedGroupCapacityExceeded(required: Int, capacity: Int)
    case singleOperationTooLarge(required: Int, capacity: Int)
    case continuationWhileEncoding

    public var description: String {
        switch self {
        case .commandCountOverflow:
            return "Metal 4 command count overflowed"
        case .unifiedGroupCapacityExceeded(let required, let capacity):
            return "Unified Metal 4 transaction requires \(required) commands but capacity is \(capacity)"
        case .singleOperationTooLarge(let required, let capacity):
            return "Metal 4 operation requires \(required) commands but group capacity is \(capacity)"
        case .continuationWhileEncoding:
            return "Cannot start a Metal 4 continuation while another group is encoding"
        }
    }
}
#endif
