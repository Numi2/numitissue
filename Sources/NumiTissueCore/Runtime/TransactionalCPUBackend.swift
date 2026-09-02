import Foundation

public enum NTModulePhase: UInt8, Codable, CaseIterable, Comparable, Sendable {
    case stimulus = 0
    case synapse = 10
    case membrane = 20
    case spikeDetection = 30
    case routing = 40
    case fastField = 50
    case molecular = 60
    case glia = 70
    case plasticity = 80
    case mechanics = 90
    case development = 100
    case fidelity = 110
    case observation = 120
    case validation = 130

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@frozen
public struct NTStepContext: Sendable {
    public var transaction: TransactionID
    public var transactionStart: TissueTime
    public var transactionEnd: TissueTime
    public var currentTime: TissueTime
    public var deltaTicks: UInt64
    public var deltaSeconds: Float
    public var input: NTStepInput
    public var deliveredEvents: [NTNeuralEvent]
    public var fastStepIndex: UInt64
    public var communicationBlockIndex: UInt64

    public init(
        transaction: TransactionID,
        transactionStart: TissueTime,
        transactionEnd: TissueTime,
        currentTime: TissueTime,
        deltaTicks: UInt64,
        input: NTStepInput,
        deliveredEvents: [NTNeuralEvent],
        fastStepIndex: UInt64,
        communicationBlockIndex: UInt64
    ) {
        self.transaction = transaction
        self.transactionStart = transactionStart
        self.transactionEnd = transactionEnd
        self.currentTime = currentTime
        self.deltaTicks = deltaTicks
        self.deltaSeconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        self.input = input
        self.deliveredEvents = deliveredEvents
        self.fastStepIndex = fastStepIndex
        self.communicationBlockIndex = communicationBlockIndex
    }
}

public protocol NTStepModule: Sendable {
    var name: String { get }
    var phase: NTModulePhase { get }
    /// A value of one runs every 25-microsecond base tick. The backend only calls a module
    /// when the module interval divides the current absolute time exactly.
    var intervalTicks: UInt64 { get }
    func execute(state: inout NTWorldRuntimeState, context: NTStepContext) throws
}

public struct NTModulePipeline: Sendable {
    public private(set) var modules: [any NTStepModule]

    public init(modules: [any NTStepModule] = []) {
        self.modules = modules.sorted {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.intervalTicks != $1.intervalTicks { return $0.intervalTicks < $1.intervalTicks }
            return $0.name < $1.name
        }
    }

    public mutating func register(_ module: any NTStepModule) {
        modules.append(module)
        modules.sort {
            if $0.phase != $1.phase { return $0.phase < $1.phase }
            if $0.intervalTicks != $1.intervalTicks { return $0.intervalTicks < $1.intervalTicks }
            return $0.name < $1.name
        }
    }

    public func modules(dueAt time: TissueTime) -> [any NTStepModule] {
        modules.filter { module in
            module.intervalTicks > 0 && time.tick.isMultiple(of: module.intervalTicks)
        }
    }
}

/// Ephemeral execution state. Only `snapshot` is authoritative across a commit boundary;
/// all other members are rebuilt or checkpointed with the transaction runtime.
public struct NTWorldRuntimeState: Sendable {
    public var snapshot: NTWorldSnapshot
    public var eventWheel: NTEventWheel
    public var routeTable: NTRouteTable
    public var tileEventQueues: [NTTileEventQueues]
    public var activeCurrentsNanoamps: [UInt64: Float]
    public var activeChemicalStimuli: [UInt64: Float]
    public var generatedEvents: [NTNeuralEvent]
    public var outputSpikes: [NTSpike]
    public var populationSamples: [NTPopulationSample]
    public var fieldSamples: [NTFieldSample]
    public var motorChannels: [UInt16: Float]
    public var autonomicChannels: [UInt16: Float]
    public var metabolicDemandWatts: Float
    public var diagnostics: [NTDiagnostic]
    public var promotedTiles: [TileID]
    public var demotedTiles: [TileID]
    public var scratchScalars: [String: Float]

    public init(
        snapshot: NTWorldSnapshot,
        eventWheel: NTEventWheel,
        routeTable: NTRouteTable,
        tileEventQueues: [NTTileEventQueues]
    ) {
        self.snapshot = snapshot
        self.eventWheel = eventWheel
        self.routeTable = routeTable
        self.tileEventQueues = tileEventQueues
        self.activeCurrentsNanoamps = [:]
        self.activeChemicalStimuli = [:]
        self.generatedEvents = []
        self.outputSpikes = []
        self.populationSamples = []
        self.fieldSamples = []
        self.motorChannels = [:]
        self.autonomicChannels = [:]
        self.metabolicDemandWatts = 0
        self.diagnostics = []
        self.promotedTiles = []
        self.demotedTiles = []
        self.scratchScalars = [:]
    }

    public mutating func emit(_ event: NTNeuralEvent) { generatedEvents.append(event) }
    public mutating func emit(_ spike: NTSpike) { outputSpikes.append(spike) }
    public mutating func diagnose(_ diagnostic: NTDiagnostic) { diagnostics.append(diagnostic) }

    public mutating func flushGeneratedEvents() throws {
        generatedEvents.sort()
        try eventWheel.schedule(contentsOf: generatedEvents)
        generatedEvents.removeAll(keepingCapacity: true)
    }

    public mutating func beginTransactionOutputs() {
        outputSpikes.removeAll(keepingCapacity: true)
        populationSamples.removeAll(keepingCapacity: true)
        fieldSamples.removeAll(keepingCapacity: true)
        motorChannels.removeAll(keepingCapacity: true)
        autonomicChannels.removeAll(keepingCapacity: true)
        diagnostics.removeAll(keepingCapacity: true)
        promotedTiles.removeAll(keepingCapacity: true)
        demotedTiles.removeAll(keepingCapacity: true)
        metabolicDemandWatts = 0
        scratchScalars.removeAll(keepingCapacity: true)
    }
}

@frozen
public struct NTCheckpoint: Codable, Sendable {
    public var schemaVersion: UInt32
    public var snapshot: NTWorldSnapshot
    public var eventWheel: NTEventWheel
    public var routeTable: NTRouteTable
    public var activeCurrentsNanoamps: [UInt64: Float]
    public var activeChemicalStimuli: [UInt64: Float]

    public init(state: NTWorldRuntimeState) {
        self.schemaVersion = NumiTissueBuild.snapshotSchemaVersion
        self.snapshot = state.snapshot
        self.eventWheel = state.eventWheel
        self.routeTable = state.routeTable
        self.activeCurrentsNanoamps = state.activeCurrentsNanoamps
        self.activeChemicalStimuli = state.activeChemicalStimuli
    }
}

public actor NTCPUReferenceBackend: NTTissueBackend {
    public private(set) var configuration: NTWorldConfiguration
    private var committed: NTWorldRuntimeState
    private var pipeline: NTModulePipeline

    public var capabilities: NTBackendCapabilities {
        NTBackendCapabilities(
            name: "NumiTissue deterministic CPU reference",
            supportsGPU: false,
            supportsDeterministicReplay: true,
            supportsMolecularMicrodomains: true,
            supportsDynamicTopology: true,
            maximumRecommendedTiles: 8
        )
    }

    public init(
        configuration: NTWorldConfiguration = .init(executionProfile: .deterministic),
        snapshot: NTWorldSnapshot? = nil,
        pipeline: NTModulePipeline = .init()
    ) throws {
        try configuration.validate()
        let initialSnapshot = snapshot ?? NTWorldSnapshot(configuration: configuration)
        let eventCapacity = max(
            1_048_576,
            configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, initialSnapshot.tiles.count)
        )
        let wheel = try NTEventWheel(cursor: initialSnapshot.time, maximumEvents: eventCapacity)
        let routes = try NTRouteTable(compartmentCount: initialSnapshot.compartments.count)
        let queues = initialSnapshot.tiles.map { _ in
            NTTileEventQueues(capacityPerQueue: configuration.resourceBudget.maximumEventsPerBlockPerTile)
        }
        self.configuration = configuration
        self.committed = NTWorldRuntimeState(
            snapshot: initialSnapshot,
            eventWheel: wheel,
            routeTable: routes,
            tileEventQueues: queues
        )
        self.pipeline = pipeline
    }

    public func configure(_ configuration: NTWorldConfiguration) async throws {
        try configuration.validate()
        guard committed.snapshot.tiles.count <= configuration.resourceBudget.maximumTiles else {
            throw NTRuntimeError.invalidConfiguration("The loaded world exceeds the new tile budget.")
        }
        self.configuration = configuration
        committed.snapshot.configuration = configuration
    }

    public func register(module: any NTStepModule) {
        pipeline.register(module)
    }

    public func replacePipeline(_ pipeline: NTModulePipeline) {
        self.pipeline = pipeline
    }

    public func setRoutes(_ routes: [NTRouteRecord]) throws {
        try committed.routeTable.replace(routes: routes, compartmentCount: committed.snapshot.compartments.count)
    }

    public func load(snapshot: NTWorldSnapshot) async throws {
        let diagnostics = snapshot.validate()
        if diagnostics.contains(where: { $0.severity >= .error }) {
            throw NTRuntimeError.invalidModel(diagnostics.map(\.message).joined(separator: "; "))
        }
        let wheel = try NTEventWheel(
            cursor: snapshot.time,
            maximumEvents: max(
                1_048_576,
                snapshot.configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, snapshot.tiles.count)
            )
        )
        let routes = try NTRouteTable(compartmentCount: snapshot.compartments.count)
        committed = NTWorldRuntimeState(
            snapshot: snapshot,
            eventWheel: wheel,
            routeTable: routes,
            tileEventQueues: snapshot.tiles.map { _ in
                NTTileEventQueues(capacityPerQueue: snapshot.configuration.resourceBudget.maximumEventsPerBlockPerTile)
            }
        )
        configuration = snapshot.configuration
    }

    public func load(checkpoint: NTCheckpoint) throws {
        guard checkpoint.schemaVersion == NumiTissueBuild.snapshotSchemaVersion else {
            throw NTRuntimeError.snapshotIncompatible("Checkpoint schema is not supported.")
        }
        let diagnostics = checkpoint.snapshot.validate() + checkpoint.eventWheel.validate()
        if diagnostics.contains(where: { $0.severity >= .error }) {
            throw NTRuntimeError.snapshotIncompatible(diagnostics.map(\.message).joined(separator: "; "))
        }
        var state = NTWorldRuntimeState(
            snapshot: checkpoint.snapshot,
            eventWheel: checkpoint.eventWheel,
            routeTable: checkpoint.routeTable,
            tileEventQueues: checkpoint.snapshot.tiles.map { _ in
                NTTileEventQueues(capacityPerQueue: checkpoint.snapshot.configuration.resourceBudget.maximumEventsPerBlockPerTile)
            }
        )
        state.activeCurrentsNanoamps = checkpoint.activeCurrentsNanoamps
        state.activeChemicalStimuli = checkpoint.activeChemicalStimuli
        committed = state
        configuration = checkpoint.snapshot.configuration
    }

    public func step(_ input: NTStepInput) async throws -> NTStepReport {
        guard input.requestedDurationTicks > 0 else {
            throw NTRuntimeError.invalidConfiguration("Requested step duration must be positive.")
        }
        guard input.requestedDurationTicks.isMultiple(of: configuration.fastQuantumTicks) else {
            throw NTRuntimeError.invalidConfiguration("Requested duration must be divisible by the fast quantum.")
        }

        var shadow = committed
        shadow.beginTransactionOutputs()
        let transaction = TransactionID(rawValue: shadow.snapshot.nextTransactionRawValue)
        shadow.snapshot.nextTransactionRawValue &+= 1
        let start = shadow.snapshot.time
        let end = TissueTime(tick: start.tick &+ input.requestedDurationTicks)

        do {
            try enqueue(input: input, transaction: transaction, state: &shadow)
            try executeTransaction(
                state: &shadow,
                input: input,
                transaction: transaction,
                start: start,
                end: end
            )
            shadow.snapshot.time = end
            shadow.outputSpikes.sort()
            let validation = validate(state: shadow)
            shadow.diagnostics.append(contentsOf: validation)
            let failure = rejectionStatus(for: shadow.diagnostics)
            if let failure {
                return report(
                    transaction: transaction,
                    status: failure,
                    state: shadow,
                    start: start,
                    end: start,
                    substeps: UInt32(input.requestedDurationTicks / configuration.fastQuantumTicks)
                )
            }
            committed = shadow
            let status: NTTransactionStatus = shadow.promotedTiles.isEmpty ? .committed : .committedWithPromotion
            return report(
                transaction: transaction,
                status: status,
                state: shadow,
                start: start,
                end: end,
                substeps: UInt32(input.requestedDurationTicks / configuration.fastQuantumTicks)
            )
        } catch let error as NTRuntimeError {
            let diagnostic: NTDiagnostic
            let status: NTTransactionStatus
            switch error {
            case .resourceExhausted:
                status = .rejectedEventOverflow
                diagnostic = .init(severity: .fatal, code: .eventQueueOverflow, message: error.description)
            case .invalidModel:
                status = .invalidModel
                diagnostic = .init(severity: .fatal, code: .invalidReference, message: error.description)
            default:
                status = .rejectedNumerical
                diagnostic = .init(severity: .fatal, code: .nonFiniteState, message: error.description)
            }
            shadow.diagnostics.append(diagnostic)
            return report(
                transaction: transaction,
                status: status,
                state: shadow,
                start: start,
                end: start,
                substeps: 0
            )
        }
    }

    public func snapshot() async throws -> NTWorldSnapshot { committed.snapshot }
    public func checkpoint() -> NTCheckpoint { NTCheckpoint(state: committed) }

    public func reset() async {
        do {
            let snapshot = NTWorldSnapshot(configuration: configuration)
            let wheel = try NTEventWheel(cursor: snapshot.time)
            let routes = try NTRouteTable(compartmentCount: 0)
            committed = NTWorldRuntimeState(snapshot: snapshot, eventWheel: wheel, routeTable: routes, tileEventQueues: [])
        } catch {
            preconditionFailure("Validated default runtime configuration failed to reset: \(error)")
        }
    }

    private func executeTransaction(
        state: inout NTWorldRuntimeState,
        input: NTStepInput,
        transaction: TransactionID,
        start: TissueTime,
        end: TissueTime
    ) throws {
        var current = start
        var fastIndex: UInt64 = 0
        while current < end {
            let next = TissueTime(tick: min(current.tick &+ configuration.fastQuantumTicks, end.tick))
            let events = try state.eventWheel.drain(through: current)
            apply(events: events, state: &state)
            let blockIndex = (current.tick - start.tick) / configuration.communicationBlockTicks
            let context = NTStepContext(
                transaction: transaction,
                transactionStart: start,
                transactionEnd: end,
                currentTime: current,
                deltaTicks: next.tick - current.tick,
                input: input,
                deliveredEvents: events,
                fastStepIndex: fastIndex,
                communicationBlockIndex: blockIndex
            )
            for module in pipeline.modules(dueAt: current) {
                try module.execute(state: &state, context: context)
            }
            try state.flushGeneratedEvents()
            current = next
            fastIndex &+= 1
        }
        let finalEvents = try state.eventWheel.drain(through: end)
        apply(events: finalEvents, state: &state)
    }

    private func enqueue(input: NTStepInput, transaction: TransactionID, state: inout NTWorldRuntimeState) throws {
        for (index, stimulus) in input.stimuli.enumerated() {
            let kind: NTEventKind
            switch stimulus.kind {
            case .sensorySpike: kind = .spike
            case .chemical: kind = .transmitterRelease
            case .neuromodulator: kind = .neuromodulatorPulse
            default: kind = .currentPulseStart
            }
            try state.eventWheel.schedule(.init(
                deliveryTime: stimulus.start,
                kind: kind,
                source: UInt64(index),
                destination: stimulus.target,
                payload0: stimulus.amplitude,
                payload1: stimulus.secondaryAmplitude,
                sequence: (transaction.rawValue << 32) | UInt64(index)
            ))
            if stimulus.durationTicks > 0 && kind == .currentPulseStart {
                try state.eventWheel.schedule(.init(
                    deliveryTime: TissueTime(tick: stimulus.start.tick &+ stimulus.durationTicks),
                    kind: .currentPulseEnd,
                    source: UInt64(index),
                    destination: stimulus.target,
                    payload0: stimulus.amplitude,
                    payload1: stimulus.secondaryAmplitude,
                    sequence: (transaction.rawValue << 32) | UInt64(index) | 0x8000_0000
                ))
            }
        }
    }

    private func apply(events: [NTNeuralEvent], state: inout NTWorldRuntimeState) {
        for event in events {
            switch event.kind {
            case .currentPulseStart:
                state.activeCurrentsNanoamps[event.destination, default: 0] += event.payload0
            case .currentPulseEnd:
                let value = state.activeCurrentsNanoamps[event.destination, default: 0] - event.payload0
                if abs(value) < 1.0e-12 {
                    state.activeCurrentsNanoamps.removeValue(forKey: event.destination)
                } else {
                    state.activeCurrentsNanoamps[event.destination] = value
                }
            case .transmitterRelease:
                state.activeChemicalStimuli[event.destination, default: 0] += event.payload0
            default:
                break
            }
        }
    }

    private func validate(state: NTWorldRuntimeState) -> [NTDiagnostic] {
        var diagnostics = state.snapshot.validate()
        diagnostics.append(contentsOf: state.eventWheel.validate())
        if !state.outputSpikes.elementsEqual(state.outputSpikes.sorted()) {
            diagnostics.append(.init(
                severity: .fatal,
                code: .spikeOrderingFailure,
                message: "Output spikes are not in canonical timestamp order."
            ))
        }
        if !state.metabolicDemandWatts.isFinite || state.metabolicDemandWatts < 0 {
            diagnostics.append(.init(
                severity: .fatal,
                code: .metabolicDemandInvalid,
                message: "Metabolic demand must be finite and nonnegative."
            ))
        }
        return diagnostics
    }

    private func rejectionStatus(for diagnostics: [NTDiagnostic]) -> NTTransactionStatus? {
        guard diagnostics.contains(where: { $0.severity >= .error }) else { return nil }
        if diagnostics.contains(where: { $0.code == .eventQueueOverflow }) { return .rejectedEventOverflow }
        if diagnostics.contains(where: {
            $0.code == .concentrationBelowZero || $0.code == .invalidCellVolume || $0.code == .cellOverlapExceeded
        }) { return .rejectedBiologicalBounds }
        if diagnostics.contains(where: {
            $0.code == .invalidMorphology || $0.code == .invalidReference || $0.code == .unsupportedFeature
        }) { return .invalidModel }
        return .rejectedNumerical
    }

    private func report(
        transaction: TransactionID,
        status: NTTransactionStatus,
        state: NTWorldRuntimeState,
        start: TissueTime,
        end: TissueTime,
        substeps: UInt32
    ) -> NTStepReport {
        let output = NTStepOutput(
            startTime: start,
            endTime: end,
            spikes: state.outputSpikes,
            populations: state.populationSamples,
            fields: state.fieldSamples,
            motorChannels: state.motorChannels,
            autonomicChannels: state.autonomicChannels,
            metabolicDemandWatts: state.metabolicDemandWatts,
            diagnostics: state.diagnostics
        )
        return NTStepReport(
            transaction: transaction,
            status: status,
            output: output,
            substeps: substeps,
            promotedTiles: state.promotedTiles,
            demotedTiles: state.demotedTiles,
            residentBytes: NTMemoryEstimator.estimate(state: state)
        )
    }
}

public enum NTMemoryEstimator {
    public static func estimate(state: NTWorldRuntimeState) -> UInt64 {
        let cells = UInt64(state.snapshot.cells.count) * 320
        let compartments = UInt64(state.snapshot.compartments.count) * 160
        let mechanismState = UInt64(state.snapshot.compartments.mechanismState.count) * 4
        let synapses = UInt64(state.snapshot.synapses.count) * 96
        let fields = UInt64(state.snapshot.fields.reduce(0) { $0 + $1.concentrations.count + $1.sources.count }) * 4
        let microdomains = UInt64(state.snapshot.microdomains.reduce(0) { $0 + $1.speciesAmounts.count }) * 4
        let events = UInt64(state.eventWheel.count) * 64
        let memberships = UInt64(state.snapshot.tiles.reduce(0) {
            $0 + $1.cellIndices.count + $1.compartmentIndices.count + $1.synapseIndices.count + $1.microdomainIndices.count
        }) * 4
        return cells + compartments + mechanismState + synapses + fields + microdomains + events + memberships
    }
}
