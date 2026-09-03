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
    public var physiologyObservation: NumanXPhysiologyObservation?
    public var physiologyControl: NumiBrainPhysiologyControl?
    public var physiologyFeedback: TissuePhysiologyFeedback?
    public var issues: [SuiteValidationIssue]
    public var counters: RuntimeCounters
    public var errorDescription: String?

    public init(
        status: NumiSuiteStepStatus,
        context: SuiteTransactionContext,
        tissueOutput: RuntimeOutputFrame,
        motorOutput: NumiBrainMotorFrame,
        physicsObservation: NumanXObservationFrame? = nil,
        physiologyObservation: NumanXPhysiologyObservation? = nil,
        physiologyControl: NumiBrainPhysiologyControl? = nil,
        physiologyFeedback: TissuePhysiologyFeedback? = nil,
        issues: [SuiteValidationIssue] = [],
        counters: RuntimeCounters = RuntimeCounters(),
        errorDescription: String? = nil
    ) {
        self.status = status
        self.context = context
        self.tissueOutput = tissueOutput
        self.motorOutput = motorOutput
        self.physicsObservation = physicsObservation
        self.physiologyObservation = physiologyObservation
        self.physiologyControl = physiologyControl
        self.physiologyFeedback = physiologyFeedback
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
    func recordInDoubt(
        context: SuiteTransactionContext,
        tokens: [SuiteCommitToken],
        reason: String
    ) async throws
}

public extension SuiteTransactionJournal {
    func recordInDoubt(
        context: SuiteTransactionContext,
        tokens: [SuiteCommitToken],
        reason: String
    ) async throws {
        try await recordAborted(
            context: context,
            reason: "IN_DOUBT: \(reason); prepared=\(tokens.map(\.participant).joined(separator: ","))"
        )
    }
}

public actor InMemorySuiteTransactionJournal: SuiteTransactionJournal {
    public enum Entry: Sendable {
        case prepared(SuiteTransactionContext, [SuiteCommitToken])
        case committed(SuiteTransactionContext)
        case aborted(SuiteTransactionContext, String)
        case inDoubt(SuiteTransactionContext, [SuiteCommitToken], String)
    }

    private(set) public var entries: [Entry] = []

    public init() {}

    public func recordPrepared(
        context: SuiteTransactionContext,
        tokens: [SuiteCommitToken]
    ) {
        entries.append(.prepared(context, tokens))
    }

    public func recordCommitted(context: SuiteTransactionContext) {
        entries.append(.committed(context))
    }

    public func recordAborted(context: SuiteTransactionContext, reason: String) {
        entries.append(.aborted(context, reason))
    }

    public func recordInDoubt(
        context: SuiteTransactionContext,
        tokens: [SuiteCommitToken],
        reason: String
    ) {
        entries.append(.inDoubt(context, tokens, reason))
    }
}

public actor NumiSuiteCoordinator {
    private let tissue: any NumiTissueExecutionBackend
    private let brain: any NumiBrainTransactionalEndpoint
    private let physics: any NumanXTransactionalEndpoint
    private let journal: any SuiteTransactionJournal
    private let planner: RuntimePhasePlanner
    private let physiologyCoupler: NumiPhysiologyCoupler

    private var loaded = false
    private var time = TissueTime()
    private var epoch: UInt64 = 0
    private var nextTransaction: UInt64 = 1

    public init(
        tissue: any NumiTissueExecutionBackend,
        brain: any NumiBrainTransactionalEndpoint,
        physics: any NumanXTransactionalEndpoint,
        journal: any SuiteTransactionJournal = InMemorySuiteTransactionJournal(),
        planner: RuntimePhasePlanner = RuntimePhasePlanner(),
        physiologyCoupler: NumiPhysiologyCoupler = NumiPhysiologyCoupler()
    ) {
        self.tissue = tissue
        self.brain = brain
        self.physics = physics
        self.journal = journal
        self.planner = planner
        self.physiologyCoupler = physiologyCoupler
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
        let execution = planner.context(
            startTime: time,
            epoch: epoch,
            transaction: transaction,
            randomSeed: randomSeed
        )
        let context = SuiteTransactionContext(
            transaction: transaction,
            epoch: epoch,
            startTime: execution.startTime,
            endTime: execution.endTime,
            randomSeed: randomSeed
        )

        var tissueOutput = RuntimeOutputFrame(
            startTime: context.startTime,
            endTime: context.endTime
        )
        var motorOutput = NumiBrainMotorFrame()
        var observation: NumanXObservationFrame?
        var physiologyObservation: NumanXPhysiologyObservation?
        var physiologyControl: NumiBrainPhysiologyControl?
        var physiologyFeedback: TissuePhysiologyFeedback?
        var issues: [SuiteValidationIssue] = []
        var counters = RuntimeCounters()
        var beganBrain = false
        var beganPhysics = false
        var beganTissue = false
        var publicationStarted = false
        var preparedTokens: [SuiteCommitToken] = []

        guard loaded else {
            return NumiSuiteStepResult(
                status: .failed,
                context: context,
                tissueOutput: tissueOutput,
                motorOutput: motorOutput,
                issues: [
                    SuiteValidationIssue(
                        source: .coordinator,
                        severity: .reject,
                        code: 1,
                        message: "Suite coordinator is not loaded"
                    )
                ]
            )
        }

        do {
            var committedObservation = try await physics.committedObservation(
                at: context.startTime
            )
            guard committedObservation.time == context.startTime else {
                throw SuiteCoordinatorError.timeMismatch(
                    expected: context.startTime.tick,
                    actual: committedObservation.time.tick
                )
            }

            let physicsPhysiology = physics as? any NumanXPhysiologyEndpoint
            if let physicsPhysiology {
                let committedPhysiology = try await physicsPhysiology.committedPhysiology(
                    at: context.startTime
                )
                physiologyObservation = try committedPhysiology.validated(
                    expectedTime: context.startTime
                )
                if let physiologyObservation {
                    committedObservation = try physiologyCoupler.augment(
                        observation: committedObservation,
                        physiology: physiologyObservation
                    )
                }
            }

            let command = try await brain.committedTissueCommand(
                observation: committedObservation,
                context: context
            )
            let runtimeInput = RuntimeInputFrame(
                command: command,
                observation: committedObservation
            )

            try await brain.beginShadow(
                context: context,
                observation: committedObservation
            )
            beganBrain = true
            if let brainPhysiology = brain as? any NumiBrainPhysiologyEndpoint,
               let physiologyObservation {
                try await brainPhysiology.integratePhysiologyObservation(
                    physiologyObservation,
                    context: context
                )
            }

            try await physics.beginShadow(context: context)
            beganPhysics = true
            try await tissue.beginShadowStep(
                context: execution,
                input: runtimeInput
            )
            beganTissue = true

            for scheduled in planner.plan(startTick: context.startTime.tick) {
                try await tissue.execute(
                    phase: scheduled.phase,
                    tickRange: scheduled.tickRange,
                    context: execution
                )
            }

            tissueOutput = try await tissue.collectOutput(context: execution)
            let feedback = TissuePhysiologyFeedback(output: tissueOutput)
            physiologyFeedback = feedback

            motorOutput = try await brain.integrateTissue(
                tissueOutput,
                context: context
            )
            if let brainPhysiology = brain as? any NumiBrainPhysiologyEndpoint {
                try await brainPhysiology.integrateTissuePhysiology(
                    feedback,
                    context: context
                )
                let generated = try await brainPhysiology.physiologyControl(
                    context: context
                )
                physiologyControl = try generated.validated()
                if let physiologyControl {
                    motorOutput = try physiologyCoupler.merge(
                        physiology: physiologyControl,
                        into: motorOutput,
                        at: context.endTime.tick
                    )
                }
            }

            let legacyPhysiology = physicsPhysiology == nil
                ? physiologyControl
                : nil
            let control = try physiologyCoupler.controlFrame(
                interval: context.startTime..<context.endTime,
                motor: motorOutput,
                physiology: legacyPhysiology,
                feedback: feedback
            )
            try await physics.integrate(control, context: context)

            if let physicsPhysiology, let physiologyControl {
                try await physicsPhysiology.integratePhysiologyControl(
                    physiologyControl,
                    feedback: feedback,
                    context: context
                )
            }

            observation = try await physics.shadowObservation(context: context)
            if observation?.time != context.endTime {
                issues.append(
                    SuiteValidationIssue(
                        source: .physics,
                        severity: .reject,
                        code: 2,
                        value: Float(observation?.time.tick ?? 0),
                        message: "NumanX shadow observation did not reach the transaction end time"
                    )
                )
            }

            if let physicsPhysiology {
                let shadowPhysiology = try await physicsPhysiology.shadowPhysiology(
                    context: context
                )
                physiologyObservation = try shadowPhysiology.validated(
                    expectedTime: context.endTime
                )
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

            if let brainPhysiology = brain as? any NumiBrainPhysiologyEndpoint {
                issues.append(
                    contentsOf: try await brainPhysiology.validatePhysiologyShadow(
                        context: context
                    )
                )
            }
            if let physicsPhysiology {
                issues.append(
                    contentsOf: try await physicsPhysiology.validatePhysiologyShadow(
                        context: context
                    )
                )
            }
            counters = await tissue.counters(context: execution)

            if issues.contains(where: { $0.severity == .reject }) {
                await rollbackAll(
                    context: context,
                    execution: execution,
                    beganBrain: beganBrain,
                    beganPhysics: beganPhysics,
                    beganTissue: beganTissue,
                    allowTissueRollback: true,
                    preparedTokens: preparedTokens
                )
                try? await journal.recordAborted(
                    context: context,
                    reason: issues.map(\.message).joined(separator: "; ")
                )
                return NumiSuiteStepResult(
                    status: .rejected,
                    context: context,
                    tissueOutput: tissueOutput,
                    motorOutput: motorOutput,
                    physicsObservation: observation,
                    physiologyObservation: physiologyObservation,
                    physiologyControl: physiologyControl,
                    physiologyFeedback: physiologyFeedback,
                    issues: issues,
                    counters: counters
                )
            }

            if let preparedBrain = brain as? any PreparedNumiBrainEndpoint {
                preparedTokens.append(
                    try await preparedBrain.prepareCommit(context: context)
                )
            }
            if let preparedPhysics = physics as? any PreparedNumanXEndpoint {
                preparedTokens.append(
                    try await preparedPhysics.prepareCommit(context: context)
                )
            }
            try await journal.recordPrepared(
                context: context,
                tokens: preparedTokens
            )

            // Publication begins with the tissue private-buffer authority swap. Any error after
            // this point is journaled as in-doubt rather than falsely reported as an abort.
            publicationStarted = true
            try await tissue.commitShadow(context: execution)

            if let preparedBrain = brain as? any PreparedNumiBrainEndpoint,
               let token = preparedTokens.first(where: {
                   $0.participant == brain.name
               }) {
                try await preparedBrain.commitPrepared(token, context: context)
            } else {
                try await brain.commitShadow(context: context)
            }

            if let preparedPhysics = physics as? any PreparedNumanXEndpoint,
               let token = preparedTokens.first(where: {
                   $0.participant == physics.name
               }) {
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
                physiologyObservation: physiologyObservation,
                physiologyControl: physiologyControl,
                physiologyFeedback: physiologyFeedback,
                issues: issues,
                counters: counters
            )
        } catch {
            let reason = String(describing: error)
            await rollbackAll(
                context: context,
                execution: execution,
                beganBrain: beganBrain,
                beganPhysics: beganPhysics,
                beganTissue: beganTissue,
                allowTissueRollback: !publicationStarted,
                preparedTokens: preparedTokens
            )

            if publicationStarted {
                try? await journal.recordInDoubt(
                    context: context,
                    tokens: preparedTokens,
                    reason: reason
                )
            } else {
                try? await journal.recordAborted(
                    context: context,
                    reason: reason
                )
            }

            issues.append(
                SuiteValidationIssue(
                    source: .coordinator,
                    severity: .reject,
                    code: publicationStarted ? 4 : 3,
                    message: reason
                )
            )
            return NumiSuiteStepResult(
                status: publicationStarted ? .inDoubt : .failed,
                context: context,
                tissueOutput: tissueOutput,
                motorOutput: motorOutput,
                physicsObservation: observation,
                physiologyObservation: physiologyObservation,
                physiologyControl: physiologyControl,
                physiologyFeedback: physiologyFeedback,
                issues: issues,
                counters: counters,
                errorDescription: reason
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
        allowTissueRollback: Bool,
        preparedTokens: [SuiteCommitToken]
    ) async {
        if let preparedBrain = brain as? any PreparedNumiBrainEndpoint,
           let token = preparedTokens.first(where: {
               $0.participant == brain.name
           }) {
            await preparedBrain.rollbackPrepared(token, context: context)
        } else if beganBrain {
            await brain.rollbackShadow(context: context)
        }

        if let preparedPhysics = physics as? any PreparedNumanXEndpoint,
           let token = preparedTokens.first(where: {
               $0.participant == physics.name
           }) {
            await preparedPhysics.rollbackPrepared(token, context: context)
        } else if beganPhysics {
            await physics.rollbackShadow(context: context)
        }

        if beganTissue && allowTissueRollback {
            await tissue.rollbackShadow(context: execution)
        }
    }
}

public enum SuiteCoordinatorError: Error, Sendable, CustomStringConvertible {
    case alreadyLoaded
    case timeMismatch(expected: UInt64, actual: UInt64)
    case participantCommitFailed(String)

    public var description: String {
        switch self {
        case .alreadyLoaded:
            return "NumiSuiteCoordinator is already loaded"
        case .timeMismatch(let expected, let actual):
            return "Committed participant time mismatch: expected \(expected), received \(actual)"
        case .participantCommitFailed(let participant):
            return "Prepared participant \(participant) failed during commit"
        }
    }
}
