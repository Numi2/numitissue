import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

public enum NumiSuiteStepStatus: String, Sendable, Hashable, Codable {
    case committed, rejected, inDoubt, failed
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
    public init(status: NumiSuiteStepStatus, context: SuiteTransactionContext,
                tissueOutput: RuntimeOutputFrame, motorOutput: NumiBrainMotorFrame,
                physicsObservation: NumanXObservationFrame? = nil,
                physiologyObservation: NumanXPhysiologyObservation? = nil,
                physiologyControl: NumiBrainPhysiologyControl? = nil,
                physiologyFeedback: TissuePhysiologyFeedback? = nil,
                issues: [SuiteValidationIssue] = [], counters: RuntimeCounters = .init(),
                errorDescription: String? = nil) {
        self.status = status; self.context = context; self.tissueOutput = tissueOutput
        self.motorOutput = motorOutput; self.physicsObservation = physicsObservation
        self.physiologyObservation = physiologyObservation; self.physiologyControl = physiologyControl
        self.physiologyFeedback = physiologyFeedback; self.issues = issues
        self.counters = counters; self.errorDescription = errorDescription
    }
}

public struct SuiteCommitToken: Sendable, Hashable, Codable {
    public var transaction: TransactionID
    public var participant: String
    public var digest: UInt64
    public init(transaction: TransactionID, participant: String, digest: UInt64) {
        self.transaction = transaction; self.participant = participant; self.digest = digest
    }
}

/// Prepared commits must be idempotent for the same token. Prepared state must remain recoverable
/// until the journal's terminal decision. An acknowledgement failure must not destroy prepared state.
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
public protocol PreparedTissueSuiteBackend: NumiTissueExecutionBackend {
    func prepareSuiteCommit(context: ExecutionContext) async throws -> SuiteCommitToken
    func commitSuitePrepared(_ token: SuiteCommitToken, context: ExecutionContext) async throws
    func rollbackSuitePrepared(_ token: SuiteCommitToken, context: ExecutionContext) async
}

public protocol SuiteTransactionJournal: Sendable {
    func recordPrepared(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws
    func recordCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws
    func hasCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws -> Bool
    func recordCommitted(context: SuiteTransactionContext) async throws
    func recordAborted(context: SuiteTransactionContext, reason: String) async throws
    func recordInDoubt(context: SuiteTransactionContext, tokens: [SuiteCommitToken], reason: String) async throws
}
public extension SuiteTransactionJournal {
    func recordCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws {
        throw SuiteCoordinatorError.unsupported("journal cannot persist commit decision")
    }
    func hasCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) async throws -> Bool {
        throw SuiteCoordinatorError.unsupported("journal cannot resolve decision")
    }
    func recordInDoubt(context: SuiteTransactionContext, tokens: [SuiteCommitToken], reason: String) async throws {
        // In-doubt is NOT an abort. Old journals must explicitly implement this state.
        throw SuiteCoordinatorError.unsupported("journal cannot represent in-doubt")
    }
}

/// Process-local development journal. Not a crash-durable prepared-transaction authority.
public actor InMemorySuiteTransactionJournal: SuiteTransactionJournal {
    public enum Entry: Sendable {
        case prepared(SuiteTransactionContext, [SuiteCommitToken])
        case commitDecided(SuiteTransactionContext, [SuiteCommitToken])
        case committed(SuiteTransactionContext)
        case aborted(SuiteTransactionContext, String)
        case inDoubt(SuiteTransactionContext, [SuiteCommitToken], String)
    }
    private(set) public var entries: [Entry] = []
    private var decisions: [TransactionID: (SuiteTransactionContext, [SuiteCommitToken])] = [:]
    public init() {}
    public func recordPrepared(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) {
        entries.append(.prepared(context, tokens))
    }
    public func recordCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) throws {
        if let prior = decisions[context.transaction] {
            guard prior.0 == context, prior.1 == tokens else { throw SuiteCoordinatorError.unsupported("conflicting decision") }
            return
        }
        decisions[context.transaction] = (context, tokens)
        entries.append(.commitDecided(context, tokens))
    }
    public func hasCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) -> Bool {
        guard let prior = decisions[context.transaction] else { return false }
        return prior.0 == context && prior.1 == tokens
    }
    public func recordCommitted(context: SuiteTransactionContext) { entries.append(.committed(context)) }
    public func recordAborted(context: SuiteTransactionContext, reason: String) throws {
        guard decisions[context.transaction] == nil else { throw SuiteCoordinatorError.unsupported("abort after commit decision") }
        entries.append(.aborted(context, reason))
    }
    public func recordInDoubt(context: SuiteTransactionContext, tokens: [SuiteCommitToken], reason: String) {
        entries.append(.inDoubt(context, tokens, reason))
    }
}

/// Coordinates reversible SIMULATION participants only. Living cultures and physical actuators
/// must never implement these rollback ports. Use GuardedNeuralCultureSession for physical effects.
/// Publication is fenced by this actor; external direct reads of individual participants are outside
/// the consistency contract. A commit decision may require recovery, never compensating rollback.
public actor NumiSuiteCoordinator {
    private let tissue: any NumiTissueExecutionBackend
    private let brain: any NumiBrainTransactionalEndpoint
    private let physics: any NumanXTransactionalEndpoint
    private let journal: any SuiteTransactionJournal
    private let planner: RuntimePhasePlanner
    private let physiologyCoupler: NumiPhysiologyCoupler
    private let requirePreparedParticipants: Bool
    private var loaded = false
    private var busy = false
    private var halted = false
    private var time = TissueTime()
    private var epoch: UInt64 = 0
    private var nextTransaction: UInt64 = 1
    private var pending: (ExecutionContext, [SuiteCommitToken], NumiSuiteStepResult)?

    public init(tissue: any NumiTissueExecutionBackend, brain: any NumiBrainTransactionalEndpoint,
                physics: any NumanXTransactionalEndpoint,
                journal: any SuiteTransactionJournal = InMemorySuiteTransactionJournal(),
                planner: RuntimePhasePlanner = RuntimePhasePlanner(),
                physiologyCoupler: NumiPhysiologyCoupler = NumiPhysiologyCoupler(),
                requirePreparedParticipants: Bool = false) {
        self.tissue = tissue; self.brain = brain; self.physics = physics; self.journal = journal
        self.planner = planner; self.physiologyCoupler = physiologyCoupler
        self.requirePreparedParticipants = requirePreparedParticipants
    }

    public func load(model: CompiledTissueModel, state: TissueRuntimeState) async throws {
        guard !loaded, !busy, !halted else { throw SuiteCoordinatorError.alreadyLoaded }
        guard Set([tissue.name, brain.name, physics.name]).count == 3,
              ![tissue.name, brain.name, physics.name].contains("") else {
            throw SuiteCoordinatorError.unsupported("participant identities must be distinct")
        }
        if requirePreparedParticipants {
            guard tissue is any PreparedTissueSuiteBackend,
                  brain is any PreparedNumiBrainEndpoint, physics is any PreparedNumanXEndpoint else {
                throw SuiteCoordinatorError.unsupported("all three prepared participants are required")
            }
        }
        busy = true; defer { busy = false }
        do { try await tissue.load(model: model, initialState: state) }
        catch { halted = true; throw error }
        time = state.time; epoch = state.epoch; loaded = true
    }

    public func step(randomSeed: UInt64) async -> NumiSuiteStepResult {
        let transaction = TransactionID(rawValue: nextTransaction)
        let execution = planner.context(startTime: time, epoch: epoch, transaction: transaction, randomSeed: randomSeed)
        let context = SuiteTransactionContext(transaction: transaction, epoch: epoch,
            startTime: execution.startTime, endTime: execution.endTime, randomSeed: randomSeed)
        var result = NumiSuiteStepResult(status: .failed, context: context,
            tissueOutput: .init(startTime: time, endTime: time), motorOutput: .init())
        guard loaded, !busy, !halted, nextTransaction < UInt64.max, epoch < UInt64.max,
              execution.endTime > execution.startTime else {
            result.errorDescription = "Coordinator unloaded, busy, in doubt, halted or time exhausted"
            return result
        }
        busy = true; defer { busy = false }
        nextTransaction += 1
        var beganBrain = false, beganPhysics = false, beganTissue = false
        var decisionAttempted = false
        var tokens: [SuiteCommitToken] = []
        do {
            try Task.checkCancellation()
            var observation = try await physics.committedObservation(at: context.startTime)
            guard observation.time == context.startTime else {
                throw SuiteCoordinatorError.timeMismatch(expected: context.startTime.tick, actual: observation.time.tick)
            }
            let physicsPhysiology = physics as? any NumanXPhysiologyEndpoint
            if let physicsPhysiology {
                let physiological = try await physicsPhysiology.committedPhysiology(at: context.startTime)
                result.physiologyObservation = try physiological.validated(expectedTime: context.startTime)
                observation = try physiologyCoupler.augment(observation: observation, physiology: physiological)
            }
            let command = try await brain.committedTissueCommand(observation: observation, context: context)
            try SuitePhase7Validation.inputs(observation: observation, command: command)
            let input = RuntimeInputFrame(command: command, observation: observation)
            // Mark an attempted begin BEFORE suspension; partial failures also receive cleanup.
            beganBrain = true
            try await brain.beginShadow(context: context, observation: observation)
            if let endpoint = brain as? any NumiBrainPhysiologyEndpoint, let physiological = result.physiologyObservation {
                try await endpoint.integratePhysiologyObservation(physiological, context: context)
            }
            beganPhysics = true; try await physics.beginShadow(context: context)
            beganTissue = true; try await tissue.beginShadowStep(context: execution, input: input)
            for scheduled in planner.plan(startTick: context.startTime.tick) {
                try Task.checkCancellation()
                try await tissue.execute(phase: scheduled.phase, tickRange: scheduled.tickRange, context: execution)
            }
            result.tissueOutput = try await tissue.collectOutput(context: execution)
            guard result.tissueOutput.startTime == context.startTime, result.tissueOutput.endTime == context.endTime else {
                throw SuiteCoordinatorError.unsupported("tissue output interval mismatch")
            }
            let feedback = TissuePhysiologyFeedback(output: result.tissueOutput)
            result.physiologyFeedback = feedback
            result.motorOutput = try await brain.integrateTissue(result.tissueOutput, context: context)
            if let endpoint = brain as? any NumiBrainPhysiologyEndpoint {
                try await endpoint.integrateTissuePhysiology(feedback, context: context)
                let generated = try await endpoint.physiologyControl(context: context)
                result.physiologyControl = try generated.validated()
                result.motorOutput = try physiologyCoupler.merge(physiology: generated, into: result.motorOutput, at: context.endTime.tick)
            }
            try SuitePhase7Validation.outputs(tissue: result.tissueOutput, motor: result.motorOutput)
            let control = try physiologyCoupler.controlFrame(interval: context.startTime..<context.endTime,
                motor: result.motorOutput, physiology: physicsPhysiology == nil ? result.physiologyControl : nil,
                feedback: feedback)
            try await physics.integrate(control, context: context)
            if let endpoint = physicsPhysiology, let physiological = result.physiologyControl {
                try await endpoint.integratePhysiologyControl(physiological, feedback: feedback, context: context)
            }
            result.physicsObservation = try await physics.shadowObservation(context: context)
            guard result.physicsObservation?.time == context.endTime else {
                throw SuiteCoordinatorError.unsupported("physics did not reach joint end time")
            }
            if let endpoint = physicsPhysiology {
                let physiological = try await endpoint.shadowPhysiology(context: context)
                result.physiologyObservation = try physiological.validated(expectedTime: context.endTime)
            }
            let tissueIssues = try await tissue.validateShadow(context: execution)
            result.issues += tissueIssues.map { .init(source: .tissue,
                severity: $0.severity == .reject ? .reject : .warning, code: $0.code, value: $0.value, message: $0.message) }
            result.issues += try await brain.validateShadow(context: context)
            result.issues += try await physics.validateShadow(context: context)
            if let endpoint = brain as? any NumiBrainPhysiologyEndpoint {
                result.issues += try await endpoint.validatePhysiologyShadow(context: context)
            }
            if let endpoint = physicsPhysiology { result.issues += try await endpoint.validatePhysiologyShadow(context: context) }
            result.counters = await tissue.counters(context: execution)
            if result.issues.contains(where: { $0.severity == .reject }) {
                throw RuntimeExecutionError.backend("joint validation rejected")
            }
            if let endpoint = tissue as? any PreparedTissueSuiteBackend {
                tokens.append(try await endpoint.prepareSuiteCommit(context: execution))
            }
            if let endpoint = brain as? any PreparedNumiBrainEndpoint { tokens.append(try await endpoint.prepareCommit(context: context)) }
            if let endpoint = physics as? any PreparedNumanXEndpoint { tokens.append(try await endpoint.prepareCommit(context: context)) }
            guard Set(tokens.map(\.participant)).count == tokens.count,
                  tokens.allSatisfy({ $0.transaction == transaction && [tissue.name, brain.name, physics.name].contains($0.participant) }) else {
                throw SuiteCoordinatorError.unsupported("prepared token identity")
            }
            try await journal.recordPrepared(context: context, tokens: tokens)
            try Task.checkCancellation()
            result.status = .inDoubt
            pending = (execution, tokens, result)
            // Even a failed decision write may have reached stable storage. Fence and recover;
            // do not issue an abort after an ambiguous decision acknowledgement.
            decisionAttempted = true
            try await journal.recordCommitDecision(context: context, tokens: tokens)
            try await publish(context: context, execution: execution, tokens: tokens)
            try await journal.recordCommitted(context: context)
            time = context.endTime; epoch += 1; pending = nil
            result.status = .committed
            return result
        } catch {
            var reason = String(describing: error)
            if decisionAttempted {
                halted = true
                // NO participant rollback after a possible commit decision, even if only one
                // participant published. Retry idempotent prepared commits via recoverCommit().
                do { try await journal.recordInDoubt(context: context, tokens: tokens, reason: reason) }
                catch { reason += "; in-doubt journal failed: \(error)" }
                result.status = .inDoubt
            } else {
                if beganBrain {
                    if let endpoint = brain as? any PreparedNumiBrainEndpoint, let token = tokens.first(where: { $0.participant == brain.name }) {
                        await endpoint.rollbackPrepared(token, context: context)
                    } else { await brain.rollbackShadow(context: context) }
                }
                if beganPhysics {
                    if let endpoint = physics as? any PreparedNumanXEndpoint, let token = tokens.first(where: { $0.participant == physics.name }) {
                        await endpoint.rollbackPrepared(token, context: context)
                    } else { await physics.rollbackShadow(context: context) }
                }
                if beganTissue { await tissue.rollbackShadow(context: execution) }
                do { try await journal.recordAborted(context: context, reason: reason) }
                catch { halted = true; reason += "; abort journal failed: \(error)" }
                result.status = result.issues.contains(where: { $0.severity == .reject }) ? .rejected : .failed
            }
            result.errorDescription = reason
            return result
        }
    }

    /// Process-local recovery of a decided transaction. Cross-process restoration additionally
    /// requires participant-owned durable prepare records; the journal alone cannot reconstruct them.
    public func recoverCommit() async throws -> NumiSuiteStepResult {
        guard !busy, halted, let (execution, tokens, prior) = pending,
              tissue is any PreparedTissueSuiteBackend, brain is any PreparedNumiBrainEndpoint,
              physics is any PreparedNumanXEndpoint, tokens.count == 3 else {
            throw SuiteCoordinatorError.unsupported("complete idempotent prepare state required for recovery")
        }
        busy = true; defer { busy = false }
        guard try await journal.hasCommitDecision(context: prior.context, tokens: tokens) else {
            throw SuiteCoordinatorError.unsupported("no confirmed commit decision; operator reconciliation required")
        }
        try await publish(context: prior.context, execution: execution, tokens: tokens)
        try await journal.recordCommitted(context: prior.context)
        time = prior.context.endTime; epoch = prior.context.epoch + 1
        pending = nil; halted = false
        var result = prior; result.status = .committed; result.errorDescription = nil
        return result
    }

    private func publish(context: SuiteTransactionContext, execution: ExecutionContext, tokens: [SuiteCommitToken]) async throws {
        if let endpoint = tissue as? any PreparedTissueSuiteBackend, let token = tokens.first(where: { $0.participant == tissue.name }) {
            try await endpoint.commitSuitePrepared(token, context: execution)
        } else { try await tissue.commitShadow(context: execution) }
        if let endpoint = brain as? any PreparedNumiBrainEndpoint, let token = tokens.first(where: { $0.participant == brain.name }) {
            try await endpoint.commitPrepared(token, context: context)
        } else { try await brain.commitShadow(context: context) }
        if let endpoint = physics as? any PreparedNumanXEndpoint, let token = tokens.first(where: { $0.participant == physics.name }) {
            try await endpoint.commitPrepared(token, context: context)
        } else { try await physics.commitShadow(context: context) }
    }
    public func exportTissueState() async throws -> TissueRuntimeState {
        guard loaded, !busy, !halted else { throw SuiteCoordinatorError.unsupported("publication fence is closed") }
        return try await tissue.exportCommittedState()
    }
    public func currentTime() -> TissueTime { time }
    public func currentEpoch() -> UInt64 { epoch }
    public func requiresRecovery() -> Bool { halted }
}

public enum SuiteCoordinatorError: Error, Sendable, CustomStringConvertible {
    case alreadyLoaded, timeMismatch(expected: UInt64, actual: UInt64), participantCommitFailed(String), unsupported(String)
    public var description: String {
        switch self {
        case .alreadyLoaded: return "NumiSuiteCoordinator already loaded, busy or halted"
        case .timeMismatch(let expected, let actual): return "Participant time mismatch: expected \(expected), received \(actual)"
        case .participantCommitFailed(let participant): return "Prepared participant \(participant) failed during commit"
        case .unsupported(let reason): return "Suite operation unavailable: \(reason)"
        }
    }
}

private enum SuitePhase7Validation {
    static func inputs(observation: NumanXObservationFrame, command: NumiBrainTissueCommand) throws {
        let arrays = [observation.proprioception, observation.touch, observation.vestibular,
            observation.interoception, command.afferentProjection.analogChannels, command.attentionMask]
        guard arrays.allSatisfy({ $0.count <= 1_000_000 && $0.allSatisfy(\.isFinite) }),
              observation.sensoryEvents.count <= 1_000_000, observation.injuryEvents.count <= 1_000_000,
              command.afferentProjection.events.count <= 1_000_000 else {
            throw SuiteCoordinatorError.unsupported("nonfinite or unbounded input; never silently drop analog values")
        }
    }
    static func outputs(tissue: RuntimeOutputFrame, motor: NumiBrainMotorFrame) throws {
        guard [tissue.populationActivity, tissue.localFieldPotentials, tissue.metabolicDemand,
               motor.muscleExcitation, motor.autonomicCommands, motor.glandCommands].allSatisfy({
            $0.count <= 1_000_000 && $0.allSatisfy(\.isFinite)
        }), motor.muscleExcitation.allSatisfy({ (0...1).contains($0) }), motor.confidence.isFinite,
              tissue.uncertainty.isFinite, tissue.plasticityMagnitude.isFinite else {
            throw SuiteCoordinatorError.unsupported("invalid tissue or motor output")
        }
    }
}
