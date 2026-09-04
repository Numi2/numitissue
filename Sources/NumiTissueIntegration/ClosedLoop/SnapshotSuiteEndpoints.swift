import Foundation
import NumiTissueCore
import NumiTissueRuntime
import NumiTissueIO

/// Serialized deep copies prevent mutable reference state from aliasing committed/shadow values.
/// This is a bounded process-local adapter, not a durable remote participant or a hardware port.
private struct SuiteSnapshotSlot<State: Codable & Sendable>: Sendable {
    let name: String
    let maximumBytes: Int
    private(set) var current: State
    private(set) var time: TissueTime
    private(set) var epoch: UInt64
    private(set) var context: SuiteTransactionContext?
    private var staged: State?
    private var prepared: SuiteCommitToken?
    private var previousCommit: (SuiteCommitToken, SuiteTransactionContext)?

    init(name: String, state: State, time: TissueTime, epoch: UInt64, maximumBytes: Int) throws {
        guard !name.isEmpty, maximumBytes > 0, maximumBytes <= 536_870_912 else {
            throw SuiteCoordinatorError.unsupported("snapshot endpoint identity or capacity")
        }
        self.name = name; self.maximumBytes = maximumBytes
        self.current = state; self.time = time; self.epoch = epoch
        self.current = try copy(state)
    }
    func copy(_ state: State) throws -> State {
        let bytes = try ScientificCanonicalJSON.encode(state)
        guard bytes.count <= maximumBytes else { throw SuiteCoordinatorError.unsupported("snapshot capacity") }
        return try ScientificCanonicalJSON.decode(State.self, from: bytes)
    }
    func readCommitted() throws -> State { try copy(current) }
    mutating func begin(_ c: SuiteTransactionContext) throws {
        guard context == nil, c.epoch == epoch, c.startTime == time, c.endTime > time, epoch < UInt64.max else {
            throw SuiteCoordinatorError.unsupported("snapshot transaction context")
        }
        let value = try copy(current)
        staged = value; context = c; prepared = nil
    }
    func shadow(_ c: SuiteTransactionContext) throws -> State {
        guard context == c, let staged else { throw SuiteCoordinatorError.unsupported("snapshot context mismatch") }
        return try copy(staged)
    }
    mutating func replace(_ state: State, context c: SuiteTransactionContext) throws {
        guard context == c, prepared == nil else { throw SuiteCoordinatorError.unsupported("mutation after prepare") }
        staged = try copy(state)
    }
    mutating func prepare(_ c: SuiteTransactionContext) throws -> SuiteCommitToken {
        guard context == c else { throw SuiteCoordinatorError.unsupported("prepare context mismatch") }
        if let prepared { return prepared }
        let payload = try ScientificCanonicalJSON.encode(shadow(c))
        let identity = SnapshotIdentity(participant: name, context: c, stateBytes: payload)
        let sha = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(identity))
        guard let short = UInt64(sha.hexadecimal.prefix(16), radix: 16) else {
            throw SuiteCoordinatorError.unsupported("snapshot token encoding")
        }
        let token = SuiteCommitToken(transaction: c.transaction, participant: name, digest: short)
        prepared = token
        return token
    }
    mutating func commit(_ token: SuiteCommitToken, context c: SuiteTransactionContext) throws {
        if let previousCommit, previousCommit.0 == token, previousCommit.1 == c { return }
        guard context == c, prepared == token, let staged, epoch < UInt64.max else {
            throw SuiteCoordinatorError.unsupported("commit token mismatch")
        }
        // All fallible work happened during prepare. No suspension during authoritative adoption.
        current = staged; time = c.endTime; epoch += 1
        previousCommit = (token, c); context = nil; self.staged = nil; prepared = nil
    }
    mutating func rollback(_ c: SuiteTransactionContext) {
        guard context == c else { return } // A published transaction cannot be rolled back here.
        context = nil; staged = nil; prepared = nil
    }
    private struct SnapshotIdentity: Encodable {
        var participant: String
        var context: SuiteTransactionContext
        var stateBytes: Data
    }
}

public typealias SnapshotBrainCommand<State: Sendable> = @Sendable (
    State, NumanXObservationFrame, SuiteTransactionContext
) throws -> NumiBrainTissueCommand
public typealias SnapshotBrainIntegrator<State: Sendable> = @Sendable (
    State, RuntimeOutputFrame, SuiteTransactionContext
) throws -> (state: State, motor: NumiBrainMotorFrame)
public typealias SnapshotStateValidator<State: Sendable> = @Sendable (State) throws -> [SuiteValidationIssue]

/// Typed adapter for a pure NumiBrain state transition supplied by the embedding application.
/// Kernels must have no external effects. It does not fabricate a brain model or open another repo.
public actor SnapshotNumiBrainEndpoint<State: Codable & Sendable>: PreparedNumiBrainEndpoint {
    public nonisolated let name: String
    private var slot: SuiteSnapshotSlot<State>
    private let command: SnapshotBrainCommand<State>
    private let integrate: SnapshotBrainIntegrator<State>
    private let validate: SnapshotStateValidator<State>
    public init(name: String, initialState: State, time: TissueTime = .init(), epoch: UInt64 = 0,
                maximumSnapshotBytes: Int = 67_108_864, command: @escaping SnapshotBrainCommand<State>,
                integrate: @escaping SnapshotBrainIntegrator<State>, validate: @escaping SnapshotStateValidator<State>) throws {
        self.name = name
        self.slot = try .init(name: name, state: initialState, time: time, epoch: epoch, maximumBytes: maximumSnapshotBytes)
        self.command = command; self.integrate = integrate; self.validate = validate
    }
    public func committedTissueCommand(observation: NumanXObservationFrame, context: SuiteTransactionContext) throws -> NumiBrainTissueCommand {
        guard context.startTime == slot.time, context.epoch == slot.epoch else {
            throw SuiteCoordinatorError.unsupported("brain committed-state time mismatch")
        }
        return try command(slot.readCommitted(), observation, context)
    }
    public func beginShadow(context: SuiteTransactionContext, observation: NumanXObservationFrame) throws {
        guard observation.time == context.startTime else { throw SuiteCoordinatorError.unsupported("brain observation time") }
        try slot.begin(context)
    }
    public func integrateTissue(_ output: RuntimeOutputFrame, context: SuiteTransactionContext) throws -> NumiBrainMotorFrame {
        let result = try integrate(slot.shadow(context), output, context)
        try slot.replace(result.state, context: context)
        return result.motor
    }
    public func validateShadow(context: SuiteTransactionContext) throws -> [SuiteValidationIssue] {
        try validate(slot.shadow(context))
    }
    public func prepareCommit(context: SuiteTransactionContext) throws -> SuiteCommitToken {
        guard !(try validateShadow(context: context)).contains(where: { $0.severity == .reject }) else {
            throw SuiteCoordinatorError.unsupported("brain shadow rejected")
        }
        return try slot.prepare(context)
    }
    public func commitPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) throws { try slot.commit(token, context: context) }
    public func rollbackPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) {
        guard token.participant == name, token.transaction == context.transaction else { return }
        slot.rollback(context)
    }
    public func commitShadow(context: SuiteTransactionContext) throws {
        let token = try prepareCommit(context: context); try slot.commit(token, context: context)
    }
    public func rollbackShadow(context: SuiteTransactionContext) { slot.rollback(context) }
    public func snapshot() throws -> State { try slot.readCommitted() }
}

public typealias SnapshotPhysicsObserver<State: Sendable> = @Sendable (State, TissueTime) throws -> NumanXObservationFrame
public typealias SnapshotPhysicsIntegrator<State: Sendable> = @Sendable (State, NumanXControlFrame, SuiteTransactionContext) throws -> State

/// Typed adapter for pure NumanX physics transitions. Its controls are simulation inputs only.
public actor SnapshotNumanXEndpoint<State: Codable & Sendable>: PreparedNumanXEndpoint {
    public nonisolated let name: String
    private var slot: SuiteSnapshotSlot<State>
    private let observe: SnapshotPhysicsObserver<State>
    private let integrateState: SnapshotPhysicsIntegrator<State>
    private let validate: SnapshotStateValidator<State>
    public init(name: String, initialState: State, time: TissueTime = .init(), epoch: UInt64 = 0,
                maximumSnapshotBytes: Int = 67_108_864, observe: @escaping SnapshotPhysicsObserver<State>,
                integrate: @escaping SnapshotPhysicsIntegrator<State>, validate: @escaping SnapshotStateValidator<State>) throws {
        self.name = name
        self.slot = try .init(name: name, state: initialState, time: time, epoch: epoch, maximumBytes: maximumSnapshotBytes)
        self.observe = observe; self.integrateState = integrate; self.validate = validate
    }
    public func committedObservation(at time: TissueTime) throws -> NumanXObservationFrame {
        guard slot.time == time else { throw SuiteCoordinatorError.unsupported("physics committed-state time mismatch") }
        return try observe(slot.readCommitted(), time)
    }
    public func beginShadow(context: SuiteTransactionContext) throws { try slot.begin(context) }
    public func integrate(_ control: NumanXControlFrame, context: SuiteTransactionContext) throws {
        guard control.timeRange == context.startTime..<context.endTime else {
            throw SuiteCoordinatorError.unsupported("physics control time interval")
        }
        let updated = try integrateState(slot.shadow(context), control, context)
        try slot.replace(updated, context: context)
    }
    public func shadowObservation(context: SuiteTransactionContext) throws -> NumanXObservationFrame {
        try observe(slot.shadow(context), context.endTime)
    }
    public func validateShadow(context: SuiteTransactionContext) throws -> [SuiteValidationIssue] {
        try validate(slot.shadow(context))
    }
    public func prepareCommit(context: SuiteTransactionContext) throws -> SuiteCommitToken {
        guard !(try validateShadow(context: context)).contains(where: { $0.severity == .reject }) else {
            throw SuiteCoordinatorError.unsupported("physics shadow rejected")
        }
        return try slot.prepare(context)
    }
    public func commitPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) throws { try slot.commit(token, context: context) }
    public func rollbackPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) {
        guard token.participant == name, token.transaction == context.transaction else { return }
        slot.rollback(context)
    }
    public func commitShadow(context: SuiteTransactionContext) throws {
        let token = try prepareCommit(context: context); try slot.commit(token, context: context)
    }
    public func rollbackShadow(context: SuiteTransactionContext) { slot.rollback(context) }
    public func snapshot() throws -> State { try slot.readCommitted() }
}
