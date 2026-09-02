import Foundation
import NumiTissueCore
import NumiTissueModels

public enum RuntimePhase: UInt8, Sendable, CaseIterable, Codable {
    case ingestInputs
    case buildWorklists
    case deliverEvents
    case decaySynapses
    case updateChannels
    case solveCableTrees
    case detectSpikes
    case routeSpikes
    case updateFastFields
    case updateMolecularDomains
    case updateGliaAndMetabolism
    case applyPlasticity
    case updateCellMechanics
    case updateDevelopment
    case updateStructuralPlasticity
    case updateAdaptiveFidelity
    case collectOutputs
    case validate
}

@frozen
public struct RuntimeCadence: Sendable, Hashable, Codable {
    public static let fastQuantumTicks: UInt64 = 1             // 25 us
    public static let routingBlockTicks: UInt64 = 10           // 250 us
    public static let transactionTicks: UInt64 = 200           // 5 ms
    public static let homeostasisTicks: UInt64 = 800            // 20 ms
    public static let cellMechanicsTicks: UInt64 = 4_000        // 100 ms
    public static let developmentalTicks: UInt64 = 40_000       // 1 s
    public static let structuralTicks: UInt64 = 400_000         // 10 s

    public var transactionTicks: UInt64
    public var routingBlockTicks: UInt64
    public var fastQuantumTicks: UInt64
    public var cellMechanicsTicks: UInt64
    public var developmentalTicks: UInt64
    public var structuralTicks: UInt64

    public init(
        transactionTicks: UInt64 = Self.transactionTicks,
        routingBlockTicks: UInt64 = Self.routingBlockTicks,
        fastQuantumTicks: UInt64 = Self.fastQuantumTicks,
        cellMechanicsTicks: UInt64 = Self.cellMechanicsTicks,
        developmentalTicks: UInt64 = Self.developmentalTicks,
        structuralTicks: UInt64 = Self.structuralTicks
    ) {
        precondition(transactionTicks > 0)
        precondition(routingBlockTicks > 0 && transactionTicks.isMultiple(of: routingBlockTicks))
        precondition(fastQuantumTicks > 0 && routingBlockTicks.isMultiple(of: fastQuantumTicks))
        self.transactionTicks = transactionTicks
        self.routingBlockTicks = routingBlockTicks
        self.fastQuantumTicks = fastQuantumTicks
        self.cellMechanicsTicks = cellMechanicsTicks
        self.developmentalTicks = developmentalTicks
        self.structuralTicks = structuralTicks
    }
}

@frozen
public struct TissueStimulus: Sendable, Hashable, Codable {
    public var destination: UInt64
    public var startTick: UInt64
    public var durationTicks: UInt32
    public var amplitude: Float
    public var kind: UInt16
    public var flags: UInt16

    public init(destination: UInt64, startTick: UInt64, durationTicks: UInt32, amplitude: Float, kind: UInt16, flags: UInt16 = 0) {
        self.destination = destination
        self.startTick = startTick
        self.durationTicks = durationTicks
        self.amplitude = amplitude
        self.kind = kind
        self.flags = flags
    }
}

@frozen
public struct RuntimeInputFrame: Sendable, Codable {
    public var afferentEvents: [RoutedEvent]
    public var stimuli: [TissueStimulus]
    public var neuromodulators: SIMD8<Float>
    public var hormones: SIMD8<Float>
    public var metabolicBoundary: SIMD8<Float>
    public var mechanicalBoundaryToken: UInt64
    public var behavioralContextToken: UInt64

    public init(
        afferentEvents: [RoutedEvent] = [],
        stimuli: [TissueStimulus] = [],
        neuromodulators: SIMD8<Float> = .zero,
        hormones: SIMD8<Float> = .zero,
        metabolicBoundary: SIMD8<Float> = .zero,
        mechanicalBoundaryToken: UInt64 = 0,
        behavioralContextToken: UInt64 = 0
    ) {
        self.afferentEvents = afferentEvents
        self.stimuli = stimuli
        self.neuromodulators = neuromodulators
        self.hormones = hormones
        self.metabolicBoundary = metabolicBoundary
        self.mechanicalBoundaryToken = mechanicalBoundaryToken
        self.behavioralContextToken = behavioralContextToken
    }
}

@frozen
public struct RuntimeOutputFrame: Sendable, Codable {
    public var startTime: TissueTime
    public var endTime: TissueTime
    public var efferentEvents: [RoutedEvent]
    public var populationActivity: [Float]
    public var localFieldPotentials: [Float]
    public var metabolicDemand: [Float]
    public var damageEvents: [RoutedEvent]
    public var uncertainty: Float
    public var plasticityMagnitude: Float

    public init(startTime: TissueTime, endTime: TissueTime) {
        self.startTime = startTime
        self.endTime = endTime
        self.efferentEvents = []
        self.populationActivity = []
        self.localFieldPotentials = []
        self.metabolicDemand = []
        self.damageEvents = []
        self.uncertainty = 0
        self.plasticityMagnitude = 0
    }
}

public enum RuntimeCommitStatus: String, Sendable, Codable {
    case committed
    case committedWithPromotion
    case substepped
    case capacityLimited
    case rejectedNumerical
    case rejectedBiologicalBounds
    case rejectedEventOverflow
    case invalidModel
    case backendFailure
}

@frozen
public struct RuntimeValidationIssue: Sendable, Hashable, Codable {
    public enum Severity: UInt8, Sendable, Codable { case warning, reject }

    public var severity: Severity
    public var code: UInt32
    public var entity: UInt64
    public var value: Float
    public var message: String

    public init(severity: Severity, code: UInt32, entity: UInt64 = 0, value: Float = 0, message: String) {
        self.severity = severity
        self.code = code
        self.entity = entity
        self.value = value
        self.message = message
    }
}

@frozen
public struct RuntimeCounters: Sendable, Hashable, Codable {
    public var activeTiles: UInt32 = 0
    public var activeCompartments: UInt32 = 0
    public var deliveredEvents: UInt64 = 0
    public var generatedSpikes: UInt64 = 0
    public var routedEvents: UInt64 = 0
    public var molecularFirings: UInt64 = 0
    public var promotedEntities: UInt32 = 0
    public var demotedEntities: UInt32 = 0
    public var structuralMutations: UInt32 = 0
    public var rejectedMutations: UInt32 = 0
    public var numericalSubsteps: UInt32 = 0

    public init() {}
}

@frozen
public struct RuntimeStepResult: Sendable, Codable {
    public var transaction: TransactionID
    public var status: RuntimeCommitStatus
    public var output: RuntimeOutputFrame
    public var counters: RuntimeCounters
    public var validationIssues: [RuntimeValidationIssue]
    public var backendDurationNanoseconds: UInt64

    public init(
        transaction: TransactionID,
        status: RuntimeCommitStatus,
        output: RuntimeOutputFrame,
        counters: RuntimeCounters = RuntimeCounters(),
        validationIssues: [RuntimeValidationIssue] = [],
        backendDurationNanoseconds: UInt64 = 0
    ) {
        self.transaction = transaction
        self.status = status
        self.output = output
        self.counters = counters
        self.validationIssues = validationIssues
        self.backendDurationNanoseconds = backendDurationNanoseconds
    }
}

@frozen
public struct ExecutionContext: Sendable {
    public var transaction: TransactionID
    public var epoch: UInt64
    public var startTime: TissueTime
    public var endTime: TissueTime
    public var randomSeed: UInt64
    public var cadence: RuntimeCadence

    public init(transaction: TransactionID, epoch: UInt64, startTime: TissueTime, randomSeed: UInt64, cadence: RuntimeCadence) {
        self.transaction = transaction
        self.epoch = epoch
        self.startTime = startTime
        self.endTime = startTime + cadence.transactionTicks
        self.randomSeed = randomSeed
        self.cadence = cadence
    }
}

public protocol NumiTissueExecutionBackend: Sendable {
    var name: String { get }
    var capabilities: TissueRuntimeCapabilities { get }

    func load(model: CompiledTissueModel, initialState: TissueRuntimeState) async throws
    func beginShadowStep(context: ExecutionContext, input: RuntimeInputFrame) async throws
    func execute(phase: RuntimePhase, tickRange: Range<UInt64>, context: ExecutionContext) async throws
    func collectOutput(context: ExecutionContext) async throws -> RuntimeOutputFrame
    func validateShadow(context: ExecutionContext) async throws -> [RuntimeValidationIssue]
    func commitShadow(context: ExecutionContext) async throws
    func rollbackShadow(context: ExecutionContext) async
    func counters(context: ExecutionContext) async -> RuntimeCounters
    func exportCommittedState() async throws -> TissueRuntimeState
}

public enum RuntimeExecutionError: Error, Sendable, CustomStringConvertible {
    case notLoaded
    case alreadyLoaded
    case transactionInProgress
    case staleTransaction
    case rejected([RuntimeValidationIssue])
    case backend(String)

    public var description: String {
        switch self {
        case .notLoaded: return "The runtime has not loaded a model"
        case .alreadyLoaded: return "The runtime already owns a model"
        case .transactionInProgress: return "A tissue transaction is already in progress"
        case .staleTransaction: return "The transaction does not match the committed epoch"
        case .rejected(let issues): return "The shadow step was rejected with \(issues.count) issue(s)"
        case .backend(let message): return "Execution backend failure: \(message)"
        }
    }
}

/// Owns the authoritative transaction sequence. GPU backends preserve authority in private heaps;
/// the actor serializes only transaction boundaries and does not drive individual cells from CPU.
public actor NumiTissueRuntime {
    public let model: CompiledTissueModel
    public let backend: any NumiTissueExecutionBackend
    public let cadence: RuntimeCadence
    public let randomSeed: UInt64

    private var committedTime: TissueTime
    private var epoch: UInt64
    private var nextTransactionLocal: UInt64
    private var loaded: Bool
    private var stepping: Bool

    public init(
        model: CompiledTissueModel,
        backend: any NumiTissueExecutionBackend,
        cadence: RuntimeCadence = RuntimeCadence(),
        randomSeed: UInt64 = 0x4E_55_4D_49_54_49_53_53
    ) {
        self.model = model
        self.backend = backend
        self.cadence = cadence
        self.randomSeed = randomSeed
        self.committedTime = TissueTime()
        self.epoch = 0
        self.nextTransactionLocal = 1
        self.loaded = false
        self.stepping = false
    }

    public func load(initialState: TissueRuntimeState) async throws {
        guard !loaded else { throw RuntimeExecutionError.alreadyLoaded }
        try await backend.load(model: model, initialState: initialState)
        committedTime = initialState.time
        epoch = initialState.epoch
        loaded = true
    }

    public func step(input: RuntimeInputFrame = RuntimeInputFrame()) async throws -> RuntimeStepResult {
        guard loaded else { throw RuntimeExecutionError.notLoaded }
        guard !stepping else { throw RuntimeExecutionError.transactionInProgress }
        stepping = true
        defer { stepping = false }

        let id = TransactionID(rawValue: nextTransactionLocal)
        nextTransactionLocal &+= 1
        let context = ExecutionContext(
            transaction: id,
            epoch: epoch,
            startTime: committedTime,
            randomSeed: randomSeed,
            cadence: cadence
        )
        let clock = ContinuousClock()
        let began = clock.now

        do {
            try await backend.beginShadowStep(context: context, input: input)
            try await executeSchedule(context: context)
            var issues = try await backend.validateShadow(context: context)
            let rejects = issues.filter { $0.severity == .reject }
            guard rejects.isEmpty else {
                await backend.rollbackShadow(context: context)
                let output = RuntimeOutputFrame(startTime: context.startTime, endTime: context.startTime)
                let duration = began.duration(to: clock.now).nanosecondsClamped
                return RuntimeStepResult(
                    transaction: id,
                    status: classifyRejection(rejects),
                    output: output,
                    counters: await backend.counters(context: context),
                    validationIssues: issues,
                    backendDurationNanoseconds: duration
                )
            }

            let output = try await backend.collectOutput(context: context)
            try await backend.commitShadow(context: context)
            committedTime = context.endTime
            epoch &+= 1
            let counters = await backend.counters(context: context)
            let status: RuntimeCommitStatus = counters.promotedEntities > 0 ? .committedWithPromotion : .committed
            let duration = began.duration(to: clock.now).nanosecondsClamped
            return RuntimeStepResult(
                transaction: id,
                status: status,
                output: output,
                counters: counters,
                validationIssues: issues,
                backendDurationNanoseconds: duration
            )
        } catch {
            await backend.rollbackShadow(context: context)
            let output = RuntimeOutputFrame(startTime: context.startTime, endTime: context.startTime)
            return RuntimeStepResult(
                transaction: id,
                status: .backendFailure,
                output: output,
                counters: await backend.counters(context: context),
                validationIssues: [RuntimeValidationIssue(severity: .reject, code: 0xFFFF_FFFE, message: String(describing: error))],
                backendDurationNanoseconds: began.duration(to: clock.now).nanosecondsClamped
            )
        }
    }

    public func snapshot() async throws -> TissueRuntimeState {
        guard loaded else { throw RuntimeExecutionError.notLoaded }
        guard !stepping else { throw RuntimeExecutionError.transactionInProgress }
        return try await backend.exportCommittedState()
    }

    public func currentTime() -> TissueTime { committedTime }
    public func currentEpoch() -> UInt64 { epoch }

    private func executeSchedule(context: ExecutionContext) async throws {
        let transactionRange = context.startTime.tick..<context.endTime.tick
        try await backend.execute(phase: .ingestInputs, tickRange: transactionRange, context: context)
        try await backend.execute(phase: .buildWorklists, tickRange: transactionRange, context: context)

        var blockStart = context.startTime.tick
        while blockStart < context.endTime.tick {
            let blockEnd = min(blockStart &+ cadence.routingBlockTicks, context.endTime.tick)
            let block = blockStart..<blockEnd
            try await backend.execute(phase: .deliverEvents, tickRange: block, context: context)

            var fastStart = blockStart
            while fastStart < blockEnd {
                let fastEnd = min(fastStart &+ cadence.fastQuantumTicks, blockEnd)
                let quantum = fastStart..<fastEnd
                try await backend.execute(phase: .decaySynapses, tickRange: quantum, context: context)
                try await backend.execute(phase: .updateChannels, tickRange: quantum, context: context)
                try await backend.execute(phase: .solveCableTrees, tickRange: quantum, context: context)
                try await backend.execute(phase: .detectSpikes, tickRange: quantum, context: context)
                fastStart = fastEnd
            }

            try await backend.execute(phase: .routeSpikes, tickRange: block, context: context)
            try await backend.execute(phase: .updateFastFields, tickRange: block, context: context)
            try await backend.execute(phase: .updateMolecularDomains, tickRange: block, context: context)
            blockStart = blockEnd
        }

        try await backend.execute(phase: .updateGliaAndMetabolism, tickRange: transactionRange, context: context)
        try await backend.execute(phase: .applyPlasticity, tickRange: transactionRange, context: context)

        if crossesCadenceBoundary(transactionRange, cadence: cadence.cellMechanicsTicks) {
            try await backend.execute(phase: .updateCellMechanics, tickRange: transactionRange, context: context)
        }
        if crossesCadenceBoundary(transactionRange, cadence: cadence.developmentalTicks) {
            try await backend.execute(phase: .updateDevelopment, tickRange: transactionRange, context: context)
            try await backend.execute(phase: .updateAdaptiveFidelity, tickRange: transactionRange, context: context)
        }
        if crossesCadenceBoundary(transactionRange, cadence: cadence.structuralTicks) {
            try await backend.execute(phase: .updateStructuralPlasticity, tickRange: transactionRange, context: context)
        }

        try await backend.execute(phase: .collectOutputs, tickRange: transactionRange, context: context)
        try await backend.execute(phase: .validate, tickRange: transactionRange, context: context)
    }

    private func crossesCadenceBoundary(_ range: Range<UInt64>, cadence: UInt64) -> Bool {
        guard cadence > 0, !range.isEmpty else { return false }
        return range.lowerBound / cadence != (range.upperBound - 1) / cadence
            || range.upperBound.isMultiple(of: cadence)
    }

    private func classifyRejection(_ issues: [RuntimeValidationIssue]) -> RuntimeCommitStatus {
        if issues.contains(where: { $0.code == ValidationCode.eventOverflow }) { return .rejectedEventOverflow }
        if issues.contains(where: { $0.code >= ValidationCode.biologicalBase && $0.code < ValidationCode.capacityBase }) {
            return .rejectedBiologicalBounds
        }
        if issues.contains(where: { $0.code >= ValidationCode.capacityBase }) { return .capacityLimited }
        return .rejectedNumerical
    }
}

public enum ValidationCode {
    public static let nonFinite: UInt32 = 1
    public static let negativeConcentration: UInt32 = 2
    public static let invalidTopology: UInt32 = 3
    public static let eventOverflow: UInt32 = 4
    public static let massConservation: UInt32 = 5
    public static let timestampOrder: UInt32 = 6
    public static let biologicalBase: UInt32 = 1_000
    public static let voltageBounds: UInt32 = 1_001
    public static let positiveCellVolume: UInt32 = 1_002
    public static let metabolicBounds: UInt32 = 1_003
    public static let weightBounds: UInt32 = 1_004
    public static let capacityBase: UInt32 = 2_000
}

private extension Duration {
    var nanosecondsClamped: UInt64 {
        let components = self.components
        let seconds = max(Int64(0), components.seconds)
        let attoseconds = max(Int64(0), components.attoseconds)
        let secondsPart = UInt64(clamping: seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if secondsPart.overflow { return UInt64.max }
        let nanos = UInt64(attoseconds / 1_000_000_000)
        let sum = secondsPart.partialValue.addingReportingOverflow(nanos)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}
