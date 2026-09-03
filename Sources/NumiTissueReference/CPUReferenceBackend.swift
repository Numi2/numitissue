import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

/// Deterministic double-precision-oriented semantic reference. It is not intended for throughput;
/// every production Metal kernel is expected to match this backend on bounded validation models.
public actor CPUReferenceTissueBackend: NumiTissueExecutionBackend {
    nonisolated public let name = "NumiTissue CPU Reference"
    nonisolated public let capabilities: TissueRuntimeCapabilities

    private let validator: RuntimeStateValidator
    private let molecularProgram: CPUReferenceMolecularProgram
    private var model: CompiledTissueModel?
    private var committed: TissueRuntimeState?
    private var shadow: TissueRuntimeState?
    private var currentContext: ExecutionContext?
    private var input = RuntimeInputFrame()
    private var eventWheel: EventDelayWheel?
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
        self.committed = initialState
        self.eventWheel = EventDelayWheel(
            originTick: initialState.time.tick,
            capacity: max(initialState.capacity.events, 65_536),
            overflowPolicy: .rejectTransaction
        )
    }

    public func beginShadowStep(context: ExecutionContext, input: RuntimeInputFrame) async throws {
        guard let committed, var wheel = eventWheel else { throw RuntimeExecutionError.notLoaded }
        guard currentContext == nil else { throw RuntimeExecutionError.transactionInProgress }
        guard committed.epoch == context.epoch && committed.time == context.startTime else { throw RuntimeExecutionError.staleTransaction }
        shadow = committed
        currentContext = context
        self.input = input
        generatedEvents.removeAll(keepingCapacity: true)
        output = RuntimeOutputFrame(startTime: context.startTime, endTime: context.endTime)
        runtimeCounters = RuntimeCounters()
        cachedIssues.removeAll(keepingCapacity: true)
        if wheel.currentTick < context.startTime.tick {
            _ = try wheel.pop(through: context.startTime.tick)
        }
        eventWheel = wheel
    }

    public func execute(phase: RuntimePhase, tickRange: Range<UInt64>, context: ExecutionContext) async throws {
        guard var state = shadow, var wheel = eventWheel else { throw MetalIndependentReferenceError.noShadowState }
        switch phase {
        case .ingestInputs:
            try wheel.schedule(contentsOf: input.afferentEvents)
            for stimulus in input.stimuli {
                try wheel.schedule(RoutedEvent(
                    arrivalTick: stimulus.startTick,
                    source: 0,
                    destination: stimulus.destination,
                    amplitude: stimulus.amplitude,
                    kind: .electrodeStimulus,
                    flags: stimulus.flags,
                    sequence: stimulus.durationTicks
                ))
            }
        case .buildWorklists:
            let worklists = RuntimeWorklistBuilder().build(state: state, at: tickRange.lowerBound)
            runtimeCounters.activeTiles = UInt32(clamping: Set(worklists.electricalTiles + worklists.fastFieldTiles + worklists.molecularTiles).count)
            runtimeCounters.activeCompartments = UInt32(clamping: worklists.electricalTiles.reduce(into: 0) { count, tileIndex in
                if Int(tileIndex) < state.tiles.count { count += Int(state.tiles[Int(tileIndex)].compartmentRange.count) }
            })
        case .deliverEvents:
            let events = try wheel.pop(through: tickRange.upperBound)
            CPUReferenceKernels.deliver(events: events, state: &state)
            runtimeCounters.deliveredEvents &+= UInt64(events.count)
        case .decaySynapses:
            CPUReferenceKernels.decaySynapses(state: &state, dtMilliseconds: ticksToMilliseconds(tickRange.count))
        case .updateChannels:
            CPUReferenceKernels.updateChannels(state: &state, dtMilliseconds: ticksToMilliseconds(tickRange.count))
        case .solveCableTrees:
            try ReferenceCableTreeSolver.solve(
                state: &state,
                dtMilliseconds: ticksToMilliseconds(tickRange.count)
            )
        case .detectSpikes:
            let spikes = CPUReferenceKernels.detectSpikes(state: &state, tickRange: tickRange)
            generatedEvents.append(contentsOf: spikes)
            runtimeCounters.generatedSpikes &+= UInt64(spikes.count)
        case .routeSpikes:
            let routed = CPUReferenceKernels.route(spikes: generatedEvents, state: state, tick: tickRange.upperBound)
            try wheel.schedule(contentsOf: routed)
            runtimeCounters.routedEvents &+= UInt64(routed.count)
            CPUReferenceKernels.clearSpikeFlags(state: &state)
            generatedEvents.removeAll(keepingCapacity: true)
        case .updateFastFields:
            CPUReferenceKernels.updateFields(state: &state, dtMilliseconds: ticksToMilliseconds(tickRange.count))
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
            CPUReferenceKernels.updateGliaAndMetabolism(state: &state, dtSeconds: ticksToSeconds(tickRange.count))
        case .applyPlasticity:
            CPUReferenceKernels.applyPlasticity(state: &state, modulators: input.neuromodulators, dtSeconds: ticksToSeconds(tickRange.count))
        case .updateCellMechanics:
            CPUReferenceKernels.updateCellMechanics(state: &state, dtSeconds: ticksToSeconds(tickRange.count))
        case .updateDevelopment:
            runtimeCounters.structuralMutations &+= UInt32(clamping: CPUReferenceKernels.updateDevelopment(state: &state, dtSeconds: max(ticksToSeconds(tickRange.count), 1)))
        case .updateStructuralPlasticity:
            runtimeCounters.structuralMutations &+= UInt32(clamping: CPUReferenceKernels.updateStructuralPlasticity(state: &state))
        case .updateAdaptiveFidelity:
            var manager = AdaptiveFidelityManager()
            let tiles = Array(state.tiles.indices).map(UInt32.init)
            let decisions = manager.decide(state: state, tileIndices: tiles, at: tickRange.upperBound)
            manager.apply(decisions, to: &state)
            runtimeCounters.promotedEntities &+= UInt32(clamping: decisions.filter { $0.kind == .promote }.count)
            runtimeCounters.demotedEntities &+= UInt32(clamping: decisions.filter { $0.kind == .demote }.count)
        case .collectOutputs:
            output = CPUReferenceKernels.collectOutput(state: state, start: context.startTime, end: context.endTime)
        case .validate:
            cachedIssues = validator.validate(state)
        }
        shadow = state
        eventWheel = wheel
    }

    public func collectOutput(context: ExecutionContext) async throws -> RuntimeOutputFrame {
        guard currentContext?.transaction == context.transaction else { throw RuntimeExecutionError.staleTransaction }
        return output
    }

    public func validateShadow(context: ExecutionContext) async throws -> [RuntimeValidationIssue] {
        guard currentContext?.transaction == context.transaction else { throw RuntimeExecutionError.staleTransaction }
        if cachedIssues.isEmpty, let shadow { cachedIssues = validator.validate(shadow) }
        return cachedIssues
    }

    public func commitShadow(context: ExecutionContext) async throws {
        guard currentContext?.transaction == context.transaction, var state = shadow else { throw RuntimeExecutionError.staleTransaction }
        state.time = context.endTime
        state.epoch = context.epoch &+ 1
        committed = state
        shadow = nil
        currentContext = nil
    }

    public func rollbackShadow(context: ExecutionContext) async {
        shadow = nil
        currentContext = nil
        generatedEvents.removeAll(keepingCapacity: true)
        cachedIssues.removeAll(keepingCapacity: true)
        if let committed {
            eventWheel = EventDelayWheel(
                originTick: committed.time.tick,
                capacity: max(committed.capacity.events, 65_536),
                overflowPolicy: .rejectTransaction
            )
        }
    }

    public func counters(context: ExecutionContext) async -> RuntimeCounters { runtimeCounters }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        guard let committed else { throw RuntimeExecutionError.notLoaded }
        guard currentContext == nil else { throw RuntimeExecutionError.transactionInProgress }
        return committed
    }

    @inline(__always)
    private func ticksToMilliseconds(_ ticks: Int) -> Float { Float(ticks) * 0.025 }

    @inline(__always)
    private func ticksToSeconds(_ ticks: Int) -> Float { Float(ticks) * 0.000_025 }
}

public enum MetalIndependentReferenceError: Error, Sendable {
    case noShadowState
}
