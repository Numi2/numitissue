import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

public enum NumiSuiteStepStatus: String, Sendable, Hashable, Codable {
    case committed
    case rejected
    case inDoubt
    case failed
}

public struct NumiSuiteStepResult: Sendable {
    public var status: NumiSuiteStepStatus
    public var context: SuiteTransactionContext
    public var tissueOutput: RuntimeOutputFrame
    public var motorOutput: NumiBrainMotorFrame
    public var physicsObservation: NumanXObservationFrame?
    public var issues: [SuiteValidationIssue]
    public var counters: RuntimeCounters
    public var errorDescription: String?

    public init(
        status: NumiSuiteStepStatus,
        context: SuiteTransactionContext,
        tissueOutput: RuntimeOutputFrame,
        motorOutput: NumiBrainMotorFrame,
        physicsObservation: NumanXObservationFrame? = nil,
        issues: [SuiteValidationIssue] = [],
        counters: RuntimeCounters = RuntimeCounters(),
        errorDescription: String? = nil
    ) {
        self.status = status
        self.context = context
        self.tissueOutput = tissueOutput
        self.motorOutput = motorOutput
        self.physicsObservation = physicsObservation
        self.issues = issues
        self.counters = counters
        self.errorDescription = errorDescription
    }
}

public struct SuiteCommitToken: Sendable, Hashable, Codable {
    public var transaction: TransactionID
    public var participant: String
    public var digest: UInt64

    public init(transaction: TransactionID, participant: String, digest: UInt64) {
        self.transaction = transaction
        self.participant = participant
        self.digest = digest
    }
}

/// Optional stronger two-phase-commit interfaces. Production NumiBrain and NumanX endpoints should
/// implement these so the coordinator can make every participant durable before publishing state.
public protocol PreparedNumiBrainEndpoint: NumiBrainTransactionalEndpoint {
    func prepareCommit(context: SuiteTransactionContext) async throws -> SuiteCommitToken
    func commitPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async throws
    func rollbackPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async
}

public protocol PreparedNumanXEndpoint: NumanXTransactionalEndpoint {
    func prepareCommit(context: SuiteTransactionContext) async throws -> SuiteCommitToken
    func commitPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async throws
    func rollbackPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async
}

public protocol SuiteTransactionJournal: Sendable {
    func recordPrepared(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws
    func recordCommitted(context: SuiteTransactionContext) async throws
    func recordAborted(context: SuiteTransactionContext, reason: String) async throws
}

public actor InMemorySuiteTransactionJournal: SuiteTransactionJournal {
    public enum Entry: Sendable {
        case prepared(SuiteTransactionContext, [SuiteCommitToken])
        case committed(SuiteTransactionContext)
        case aborted(SuiteTransactionContext, String)
    }

    private(set) public var entries: [Entry] = []
    public init() {}
    public func recordPrepared(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) { entries.append(.prepared(context, tokens)) }
    public func recordCommitted(context: SuiteTransactionContext) { entries.append(.committed(context)) }
    public func recordAborted(context: SuiteTransactionContext, reason: String) { entries.append(.aborted(context, reason)) }
}

public actor NumiSuiteCoordinator {
    private let tissue: any NumiTissueExecutionBackend
    private let brain: any NumiBrainTransactionalEndpoint
    private let physics: any NumanXTransactionalEndpoint
    private let journal: any SuiteTransactionJournal
    private let planner: RuntimePhasePlanner

    private var loaded = false
    private var time = TissueTime()
    private var epoch: UInt64 = 0
    private var nextTransaction: UInt64 = 1

    public init(
        tissue: any NumiTissueExecutionBackend,
        brain: any NumiBrainTransactionalEndpoint,
        physics: any NumanXTransactionalEndpoint,
        journal: any SuiteTransactionJournal = InMemorySuiteTransactionJournal(),
        planner: RuntimePhasePlanner = RuntimePhasePlanner()
    ) {
        self.tissue = tissue
        self.brain = brain
        self.physics = physics
        self.journal = journal
        self.planner = planner
    }

    public func load(model: CompiledTissueModel, state: TissueRuntimeState) async throws {
        guard !loaded else { throw SuiteCoordinatorError.alreadyLoaded }
        try await tissue.load(model: model, initialState: state)
        time = state.time
        epoch = state.epoch
        loaded = true
    }

    public func step(randomSeed: UInt64) async -> NumiSuiteStepResult {
        let transaction = TransactionID(rawValue: nextTransaction)
        nextTransaction &+= 1
        let execution = planner.context(startTime: time, epoch: epoch, transaction: transaction, randomSeed: randomSeed)
        let context = SuiteTransactionContext(
            transaction: transaction,
            epoch: epoch,
            startTime: execution.startTime,
            endTime: execution.endTime,
            randomSeed: randomSeed
        )
        var tissueOutput = RuntimeOutputFrame(startTime: context.startTime, endTime: context.endTime)
        var motorOutput = NumiBrainMotorFrame()
        var observation: NumanXObservationFrame?
        var issues: [SuiteValidationIssue] = []
        var counters = RuntimeCounters()
        var beganBrain = false
        var beganPhysics = false
        var beganTissue = false
        var preparedTokens: [SuiteCommitToken] = []

        guard loaded else {
            return NumiSuiteStepResult(
                status: .failed,
                context: context,
                tissueOutput: tissueOutput,
                motorOutput: motorOutput,
                issues: [SuiteValidationIssue(source: .coordinator, severity: .reject, code: 1, message: "Suite coordinator is not loaded")]
            )
        }

        do {
            let committedObservation = try await physics.committedObservation(at: context.startTime)
            guard committedObservation.time == context.startTime else {
                throw SuiteCoordinatorError.timeMismatch(expected: context.startTime.tick, actual: committedObservation.time.tick)
            }
            let command = try await brain.committedTissueCommand(observation: committedObservation, context: context)
            let runtimeInput = RuntimeInputFrame(command: command, observation: committedObservation)

            try await brain.beginShadow(context: context, observation: committedObservation)
            beganBrain = true
            try await physics.beginShadow(context: context)
            beganPhysics = true
            try await tissue.beginShadowStep(context: execution, input: runtimeInput)
            beganTissue = true

            for scheduled in planner.plan(startTick: context.startTime.tick) {
                try await tissue.execute(phase: scheduled.phase, tickRange: scheduled.tickRange, context: execution)
            }
            tissueOutput = try await tissue.collectOutput(context: execution)
            motorOutput = try await brain.integrateTissue(tissueOutput, context: context)

            let control = NumanXControlFrame(
                timeRange: context.startTime..<context.endTime,
                motor: motorOutput,
                metabolicDemand: tissueOutput.metabolicDemand
            )
            try await physics.integrate(control, context: context)
            observation = try await physics.shadowObservation(context: context)
            if observation?.time != context.endTime {
                issues.append(SuiteValidationIssue(
                    source: .physics,
                    severity: .reject,
                    code: 2,
                    value: Float(observation?.time.tick ?? 0),
                    message: "NumanX shadow observation did not reach the transaction end time"
                ))
            }

            let tissueIssues = try await tissue.validateShadow(context: execution)
            issues.append(contentsOf: tissueIssues.map {
                SuiteValidationIssue(
                    source: .tissue,
                    severity: $0.severity == .reject ? .reject : .warning,
                    code: $0.code,
                    value: $0.value,
                    message: $0.message
                )
            })
            issues.append(contentsOf: try await brain.validateShadow(context: context))
            issues.append(contentsOf: try await physics.validateShadow(context: context))
            counters = await tissue.counters(context: execution)

            if issues.contains(where: { $0.severity == .reject }) {
                await rollbackAll(
                    context: context,
                    execution: execution,
                    beganBrain: beganBrain,
                    beganPhysics: beganPhysics,
                    beganTissue: beganTissue,
                    preparedTokens: preparedTokens
                )
                try? await journal.recordAborted(context: context, reason: issues.map(\.message).joined(separator: "; "))
                return NumiSuiteStepResult(
                    status: .rejected,
                    context: context,
                    tissueOutput: tissueOutput,
                    motorOutput: motorOutput,
                    physicsObservation: observation,
                    issues: issues,
                    counters: counters
                )
            }

            if let preparedBrain = brain as? any PreparedNumiBrainEndpoint {
                preparedTokens.append(try await preparedBrain.prepareCommit(context: context))
            }
            if let preparedPhysics = physics as? any PreparedNumanXEndpoint {
                preparedTokens.append(try await preparedPhysics.prepareCommit(context: context))
            }
            try await journal.recordPrepared(context: context, tokens: preparedTokens)

            // Backend commit is a private-buffer authority swap after successful GPU completion.
            // Prepared external participants are published only after every prepare has succeeded.
            try await tissue.commitShadow(context: execution)
            if let preparedBrain = brain as? any PreparedNumiBrainEndpoint,
               let token = preparedTokens.first(where: { $0.participant == brain.name }) {
                try await preparedBrain.commitPrepared(token, context: context)
            } else {
                try await brain.commitShadow(context: context)
            }
            if let preparedPhysics = physics as? any PreparedNumanXEndpoint,
               let token = preparedTokens.first(where: { $0.participant == physics.name }) {
                try await preparedPhysics.commitPrepared(token, context: context)
            } else {
                try await physics.commitShadow(context: context)
            }
            try await journal.recordCommitted(context: context)
            time = context.endTime
            epoch &+= 1
            return NumiSuiteStepResult(
                status: .committed,
                context: context,
                tissueOutput: tissueOutput,
                motorOutput: motorOutput,
                physicsObservation: observation,
                issues: issues,
                counters: counters
            )
        } catch {
            let publicationMayHaveStarted = preparedTokens.count > 0 && beganTissue
            await rollbackAll(
                context: context,
                execution: execution,
                beganBrain: beganBrain,
                beganPhysics: beganPhysics,
                beganTissue: beganTissue,
                preparedTokens: preparedTokens
            )
            try? await journal.recordAborted(context: context, reason: String(describing: error))
            issues.append(SuiteValidationIssue(
                source: .coordinator,
                severity: .reject,
                code: publicationMayHaveStarted ? 4 : 3,
                message: String(describing: error)
            ))
            return NumiSuiteStepResult(
                status: publicationMayHaveStarted ? .inDoubt : .failed,
                context: context,
                tissueOutput: tissueOutput,
                motorOutput: motorOutput,
                physicsObservation: observation,
                issues: issues,
                counters: counters,
                errorDescription: String(describing: error)
            )
        }
    }

    public func exportTissueState() async throws -> TissueRuntimeState {
        try await tissue.exportCommittedState()
    }

    public func currentTime() -> TissueTime { time }
    public func currentEpoch() -> UInt64 { epoch }

    private func rollbackAll(
        context: SuiteTransactionContext,
        execution: ExecutionContext,
        beganBrain: Bool,
        beganPhysics: Bool,
        beganTissue: Bool,
        preparedTokens: [SuiteCommitToken]
    ) async {
        if let preparedBrain = brain as? any PreparedNumiBrainEndpoint,
           let token = preparedTokens.first(where: { $0.participant == brain.name }) {
            await preparedBrain.rollbackPrepared(token, context: context)
        } else if beganBrain { await brain.rollbackShadow(context: context) }

        if let preparedPhysics = physics as? any PreparedNumanXEndpoint,
           let token = preparedTokens.first(where: { $0.participant == physics.name }) {
            await preparedPhysics.rollbackPrepared(token, context: context)
        } else if beganPhysics { await physics.rollbackShadow(context: context) }

        if beganTissue { await tissue.rollbackShadow(context: execution) }
    }
}

public enum SuiteCoordinatorError: Error, Sendable, CustomStringConvertible {
    case alreadyLoaded
    case timeMismatch(expected: UInt64, actual: UInt64)
    case participantCommitFailed(String)

    public var description: String {
        switch self {
        case .alreadyLoaded: return "NumiSuiteCoordinator is already loaded"
        case .timeMismatch(let expected, let actual): return "Committed participant time mismatch: expected \(expected), received \(actual)"
        case .participantCommitFailed(let participant): return "Prepared participant \(participant) failed during commit"
        }
    }
}
