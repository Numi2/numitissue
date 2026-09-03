import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

/// Deterministic correctness-oriented FP32 semantic reference. It is not intended for throughput;
/// every production Metal kernel is expected to match this backend on bounded validation models.
public actor CPUReferenceTissueBackend: NumiTissueExecutionBackend {
    nonisolated public let name = "NumiTissue CPU Reference"
    nonisolated public let capabilities: TissueRuntimeCapabilities

    private let validator: RuntimeStateValidator
    private let molecularProgram: CPUReferenceMolecularProgram
    private var model: CompiledTissueModel?
    private var committed: TissueRuntimeState?
    private var shadow: TissueRuntimeState?
    private var committedEventWheel: EventDelayWheel?
    private var shadowEventWheel: EventDelayWheel?
    private var stagedInterventionState: TissueRuntimeState?
    private var currentContext: ExecutionContext?
    private var input = RuntimeInputFrame()
    private var generatedEvents: [RoutedEvent] = []
    private var output = RuntimeOutputFrame(startTime: TissueTime(), endTime: TissueTime())
    private var runtimeCounters = RuntimeCounters()
    private var cachedIssues: [RuntimeValidationIssue] = []

    public init(
        capabilities: TissueRuntimeCapabilities,
        validationLimits: RuntimeValidationLimits = RuntimeValidationLimits(),
        molecularProgram: CPUReferenceMolecularProgram = CPUReferenceMolecularProgram()
    ) {
        self.capabilities = capabilities
        self.validator = RuntimeStateValidator(limits: validationLimits)
        self.molecularProgram = molecularProgram
    }

    public func load(model: CompiledTissueModel, initialState: TissueRuntimeState) async throws {
        guard committed == nil else { throw RuntimeExecutionError.alreadyLoaded }
        try initialState.validateCapacity()
        let issues = validator.validate(initialState)
        let rejects = issues.filter { $0.severity == .reject }
        guard rejects.isEmpty else { throw RuntimeExecutionError.rejected(rejects) }
        self.model = model
        committed = initialState
        committedEventWheel = EventDelayWheel(
            originTick: initialState.time.tick,
            capacity: max(initialState.capacity.events, 65_536),
            overflowPolicy: .rejectTransaction
        )
    }

    public func beginShadowStep(context: ExecutionContext, input: RuntimeInputFrame) async throws {
        guard let committed, var wheel = committedEventWheel else {
            throw RuntimeExecutionError.notLoaded
        }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        guard committed.epoch == context.epoch,
              committed.time == context.startTime else {
            throw RuntimeExecutionError.staleTransaction
        }
        guard wheel.currentTick <= context.startTime.tick else {
            throw CPUReferenceBackendError.eventWheelAheadOfCommittedTime(
                wheel: wheel.currentTick,
                committed: context.startTime.tick
            )
        }
        if wheel.currentTick < context.startTime.tick {
            let overdue = try wheel.pop(through: context.startTime.tick)
            guard overdue.isEmpty else {
                throw CPUReferenceBackendError.overdueCommittedEvents(
                    count: overdue.count
                )
            }
        }

        shadow = stagedInterventionState ?? committed
        stagedInterventionState = nil
        shadowEventWheel = wheel
        currentContext = context
        self.input = input
        generatedEvents.removeAll(keepingCapacity: true)
        output = RuntimeOutputFrame(
            startTime: context.startTime,
            endTime: context.endTime
        )
        runtimeCounters = RuntimeCounters()
        cachedIssues.removeAll(keepingCapacity: true)
    }

    public func execute(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws {
        guard currentContext?.transaction == context.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        guard var state = shadow, var wheel = shadowEventWheel else {
            throw MetalIndependentReferenceError.noShadowState
        }
        switch phase {
        case .ingestInputs:
            try wheel.schedule(contentsOf: input.afferentEvents)
            let stimuli = input.stimuli.map { stimulus in
                RoutedEvent(
                    arrivalTick: stimulus.startTick,
                    source: 0,
                    destination: stimulus.destination,
                    amplitude: stimulus.amplitude,
                    kind: .electrodeStimulus,
                    flags: stimulus.flags,
                    sequence: stimulus.durationTicks
                )
            }
            try wheel.schedule(contentsOf: stimuli)
        case .buildWorklists:
            let worklists = RuntimeWorklistBuilder().build(
                state: state,
                at: tickRange.lowerBound
            )
            runtimeCounters.activeTiles = UInt32(clamping: Set(
                worklists.electricalTiles +
                worklists.fastFieldTiles +
                worklists.molecularTiles
            ).count)
            runtimeCounters.activeCompartments = UInt32(clamping:
                worklists.electricalTiles.reduce(into: 0) { count, tileIndex in
                    if Int(tileIndex) < state.tiles.count {
                        count += Int(
                            state.tiles[Int(tileIndex)].compartmentRange.count
                        )
                    }
                }
            )
        case .deliverEvents:
            let events = try wheel.pop(through: tickRange.upperBound)
            CPUReferenceKernels.deliver(events: events, state: &state)
            runtimeCounters.deliveredEvents &+= UInt64(events.count)
        case .decaySynapses:
            CPUReferenceKernels.decaySynapses(
                state: &state,
                dtMilliseconds: ticksToMilliseconds(tickRange.count)
            )
        case .updateChannels:
            CPUReferenceKernels.updateChannels(
                state: &state,
                dtMilliseconds: ticksToMilliseconds(tickRange.count)
            )
        case .solveCableTrees:
            try ReferenceCableTreeSolver.solve(
                state: &state,
                dtMilliseconds: ticksToMilliseconds(tickRange.count)
            )
        case .detectSpikes:
            let spikes = CPUReferenceKernels.detectSpikes(
                state: &state,
                tickRange: tickRange
            )
            generatedEvents.append(contentsOf: spikes)
            runtimeCounters.generatedSpikes &+= UInt64(spikes.count)
        case .routeSpikes:
            let routed = CPUReferenceKernels.route(
                spikes: generatedEvents,
                state: state,
                tick: tickRange.upperBound
            )
            try wheel.schedule(contentsOf: routed)
            runtimeCounters.routedEvents &+= UInt64(routed.count)
            CPUReferenceKernels.clearSpikeFlags(state: &state)
            generatedEvents.removeAll(keepingCapacity: true)
        case .updateFastFields:
            CPUReferenceKernels.updateFields(
                state: &state,
                dtMilliseconds: ticksToMilliseconds(tickRange.count)
            )
        case .updateMolecularDomains:
            let firings = CPUReferenceMolecularSolver.step(
                state: &state,
                program: molecularProgram,
                tickRange: tickRange,
                transaction: context.transaction,
                seed: context.randomSeed
            )
            runtimeCounters.molecularFirings &+= UInt64(firings)
        case .updateGliaAndMetabolism:
            CPUReferenceKernels.updateGliaAndMetabolism(
                state: &state,
                dtSeconds: ticksToSeconds(tickRange.count)
            )
        case .applyPlasticity:
            CPUReferenceKernels.applyPlasticity(
                state: &state,
                modulators: input.neuromodulators,
                dtSeconds: ticksToSeconds(tickRange.count)
            )
        case .updateCellMechanics:
            CPUReferenceKernels.updateCellMechanics(
                state: &state,
                dtSeconds: ticksToSeconds(tickRange.count)
            )
        case .updateDevelopment:
            runtimeCounters.structuralMutations &+= UInt32(clamping:
                CPUReferenceKernels.updateDevelopment(
                    state: &state,
                    dtSeconds: max(ticksToSeconds(tickRange.count), 1)
                )
            )
        case .updateStructuralPlasticity:
            runtimeCounters.structuralMutations &+= UInt32(clamping:
                CPUReferenceKernels.updateStructuralPlasticity(state: &state)
            )
        case .updateAdaptiveFidelity:
            var manager = AdaptiveFidelityManager()
            let tiles = Array(state.tiles.indices).map(UInt32.init)
            let decisions = manager.decide(
                state: state,
                tileIndices: tiles,
                at: tickRange.upperBound
            )
            manager.apply(decisions, to: &state)
            runtimeCounters.promotedEntities &+= UInt32(clamping:
                decisions.filter { $0.kind == .promote }.count
            )
            runtimeCounters.demotedEntities &+= UInt32(clamping:
                decisions.filter { $0.kind == .demote }.count
            )
        case .collectOutputs:
            output = CPUReferenceKernels.collectOutput(
                state: state,
                start: context.startTime,
                end: context.endTime
            )
        case .validate:
            cachedIssues = validator.validate(state)
        }
        shadow = state
        shadowEventWheel = wheel
    }

    public func collectOutput(
        context: ExecutionContext
    ) async throws -> RuntimeOutputFrame {
        guard currentContext?.transaction == context.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        return output
    }

    public func validateShadow(
        context: ExecutionContext
    ) async throws -> [RuntimeValidationIssue] {
        guard currentContext?.transaction == context.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        if cachedIssues.isEmpty, let shadow {
            cachedIssues = validator.validate(shadow)
        }
        return cachedIssues
    }

    public func commitShadow(context: ExecutionContext) async throws {
        guard currentContext?.transaction == context.transaction,
              var state = shadow,
              let wheel = shadowEventWheel else {
            throw RuntimeExecutionError.staleTransaction
        }
        guard wheel.currentTick == context.endTime.tick else {
            throw CPUReferenceBackendError.incompleteEventAdvance(
                expected: context.endTime.tick,
                actual: wheel.currentTick
            )
        }
        state.time = context.endTime
        state.epoch = context.epoch &+ 1
        committed = state
        committedEventWheel = wheel
        clearShadowTransaction()
    }

    public func rollbackShadow(context: ExecutionContext) async {
        guard currentContext?.transaction == context.transaction else { return }
        clearShadowTransaction()
    }

    public func counters(context: ExecutionContext) async -> RuntimeCounters {
        runtimeCounters
    }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        guard let committed else { throw RuntimeExecutionError.notLoaded }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        return committed
    }

    public func exportEventWheelSnapshot() async throws -> EventDelayWheelSnapshot {
        guard let wheel = committedEventWheel else {
            throw RuntimeExecutionError.notLoaded
        }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        return try wheel.snapshot().validated()
    }

    public func restoreEventWheelSnapshot(
        _ source: EventDelayWheelSnapshot
    ) async throws {
        guard let committed else { throw RuntimeExecutionError.notLoaded }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        let snapshot = try source.validated()
        guard snapshot.originTick == committed.time.tick else {
            throw CPUReferenceBackendError.eventWheelStateMismatch(
                wheel: snapshot.originTick,
                committed: committed.time.tick
            )
        }
        committedEventWheel = try EventDelayWheel(snapshot: snapshot)
    }

    private func clearShadowTransaction() {
        shadow = nil
        shadowEventWheel = nil
        currentContext = nil
        generatedEvents.removeAll(keepingCapacity: true)
        cachedIssues.removeAll(keepingCapacity: true)
    }

    @inline(__always)
    private func ticksToMilliseconds(_ ticks: Int) -> Float {
        Float(ticks) * 0.025
    }

    @inline(__always)
    private func ticksToSeconds(_ ticks: Int) -> Float {
        Float(ticks) * 0.000_025
    }
}

public enum MetalIndependentReferenceError: Error, Sendable {
    case noShadowState
}

extension CPUReferenceTissueBackend: InterventionAwareTissueBackend {
    public func stageInterventions(
        _ frame: TissueInterventionFrame,
        context: ExecutionContext
    ) async throws {
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        guard let committed else {
            throw RuntimeExecutionError.notLoaded
        }
        guard committed.epoch == context.epoch,
              committed.time == context.startTime,
              frame.tick == context.startTime.tick else {
            throw RuntimeOverlayError.staleFrame(
                expected: context.startTime.tick,
                received: frame.tick
            )
        }
        var candidate = committed
        try TissueStateInterventionApplier.apply(frame, to: &candidate)
        stagedInterventionState = candidate
    }
}

extension CPUReferenceTissueBackend: RuntimePhaseInspectableBackend {
    nonisolated public var numericalProfile: RuntimeNumericalProfile { .scientific32 }

    public func captureShadowDigest(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimePhaseDigestSnapshot {
        try differentialInspection(
            phase: phase,
            tickRange: tickRange,
            context: context
        ).digestSnapshot
    }

    public func exportShadowInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimeShadowInspection {
        try differentialInspection(
            phase: phase,
            tickRange: tickRange,
            context: context
        )
    }

    private func differentialInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) throws -> RuntimeShadowInspection {
        guard currentContext?.transaction == context.transaction,
              let state = shadow,
              let wheel = shadowEventWheel else {
            throw RuntimeExecutionError.staleTransaction
        }
        let pending = wheel.pendingEvents
            .map { RuntimePendingEvent($0, state: state) }
            .sorted()
        return RuntimeShadowInspection(
            backendName: name,
            numericalProfile: numericalProfile,
            transaction: context.transaction,
            phase: phase,
            tickRange: tickRange,
            state: state,
            pendingEvents: pending,
            counters: runtimeCounters,
            metadata: [
                "eventWheel.currentTick": String(wheel.currentTick),
                "eventWheel.horizonEndTick": String(wheel.horizonEndTick),
                "inspection.readback": "none",
                "precision.authoritativeState": "fp32"
            ]
        )
    }
}

public enum CPUReferenceBackendError: Error, Sendable, CustomStringConvertible {
    case eventWheelAheadOfCommittedTime(wheel: UInt64, committed: UInt64)
    case overdueCommittedEvents(count: Int)
    case incompleteEventAdvance(expected: UInt64, actual: UInt64)
    case eventWheelStateMismatch(wheel: UInt64, committed: UInt64)

    public var description: String {
        switch self {
        case .eventWheelAheadOfCommittedTime(let wheel, let committed):
            return "Committed event wheel is at tick \(wheel), ahead of committed tissue tick \(committed)."
        case .overdueCommittedEvents(let count):
            return "Committed event wheel contains \(count) overdue event(s)."
        case .incompleteEventAdvance(let expected, let actual):
            return "Event wheel reached tick \(actual), but transaction requires tick \(expected)."
        case .eventWheelStateMismatch(let wheel, let committed):
            return "Event-wheel snapshot tick \(wheel) does not match committed tissue tick \(committed)."
        }
    }
}
