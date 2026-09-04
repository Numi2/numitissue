import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime
import NumiTissueIO

/// Adds process-local prepare/idempotent commit semantics to an existing tissue backend.
/// Does not claim durable shadow state across process death. The wrapped backend must be exclusively
/// owned by this adapter, and its commit must advance epoch/time exactly as the runtime contract says.
public actor PreparedTissueBackendAdapter: PreparedTissueSuiteBackend {
    public nonisolated let name: String
    public nonisolated let capabilities: TissueRuntimeCapabilities
    private let backend: any NumiTissueExecutionBackend
    private var context: ExecutionContext?
    private var token: SuiteCommitToken?
    private var lastCommitted: (SuiteCommitToken, SuiteTransactionContext)?
    private var operating = false
    private var failed = false
    public init(backend: any NumiTissueExecutionBackend) {
        self.backend = backend; self.name = backend.name; self.capabilities = backend.capabilities
    }
    private func enter() throws {
        guard !operating, !failed else { throw RuntimeExecutionError.transactionInProgress }
        operating = true
    }
    private func same(_ c: ExecutionContext, _ other: ExecutionContext) -> Bool {
        c.transaction == other.transaction && c.epoch == other.epoch && c.startTime == other.startTime &&
            c.endTime == other.endTime && c.randomSeed == other.randomSeed && c.cadence == other.cadence
    }
    private func canonical(_ c: ExecutionContext) -> SuiteTransactionContext {
        .init(transaction: c.transaction, epoch: c.epoch, startTime: c.startTime,
              endTime: c.endTime, randomSeed: c.randomSeed)
    }
    public func load(model: CompiledTissueModel, initialState: TissueRuntimeState) async throws {
        try enter(); defer { operating = false }
        try await backend.load(model: model, initialState: initialState)
    }
    public func beginShadowStep(context c: ExecutionContext, input: RuntimeInputFrame) async throws {
        try enter(); defer { operating = false }
        guard context == nil else { throw RuntimeExecutionError.transactionInProgress }
        context = c; token = nil
        do { try await backend.beginShadowStep(context: c, input: input) }
        catch { await backend.rollbackShadow(context: c); context = nil; throw error }
    }
    public func execute(phase: RuntimePhase, tickRange: Range<UInt64>, context c: ExecutionContext) async throws {
        try enter(); defer { operating = false }
        guard let context, same(context, c), token == nil else { throw RuntimeExecutionError.staleTransaction }
        try await backend.execute(phase: phase, tickRange: tickRange, context: c)
    }
    public func collectOutput(context c: ExecutionContext) async throws -> RuntimeOutputFrame {
        try enter(); defer { operating = false }
        guard let context, same(context, c) else { throw RuntimeExecutionError.staleTransaction }
        return try await backend.collectOutput(context: c)
    }
    public func validateShadow(context c: ExecutionContext) async throws -> [RuntimeValidationIssue] {
        try enter(); defer { operating = false }
        guard let context, same(context, c) else { throw RuntimeExecutionError.staleTransaction }
        return try await backend.validateShadow(context: c)
    }
    public func prepareSuiteCommit(context c: ExecutionContext) async throws -> SuiteCommitToken {
        try enter(); defer { operating = false }
        guard let context, same(context, c), c.epoch < UInt64.max else { throw RuntimeExecutionError.staleTransaction }
        if let token { return token }
        let issues = try await backend.validateShadow(context: c)
        guard !issues.contains(where: { $0.severity == .reject }) else { throw RuntimeExecutionError.rejected(issues) }
        let output = try await backend.collectOutput(context: c)
        struct Identity: Encodable { var context: SuiteTransactionContext; var output: RuntimeOutputFrame; var participant: String }
        let hash = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(
            Identity(context: canonical(c), output: output, participant: name))).hexadecimal
        guard let digest = UInt64(hash.prefix(16), radix: 16) else { throw RuntimeExecutionError.backend("token digest") }
        let prepared = SuiteCommitToken(transaction: c.transaction, participant: name, digest: digest)
        token = prepared
        return prepared
    }
    public func commitSuitePrepared(_ proposed: SuiteCommitToken, context c: ExecutionContext) async throws {
        try enter(); defer { operating = false }
        if let previous = lastCommitted, previous.0 == proposed, previous.1 == canonical(c) { return }
        guard let context, same(context, c), proposed == token else { throw RuntimeExecutionError.staleTransaction }
        do { try await backend.commitShadow(context: c) }
        catch {
            // A backend may publish and then fail to acknowledge. Inspect authority rather than
            // blindly invoking the non-idempotent commit a second time.
            let actual = try await backend.exportCommittedState()
            if actual.time != c.endTime || actual.epoch != c.epoch + 1 { throw error }
        }
        let actual = try await backend.exportCommittedState()
        guard actual.time == c.endTime, actual.epoch == c.epoch + 1 else {
            failed = true; throw RuntimeExecutionError.backend("prepared commit did not publish expected authority")
        }
        lastCommitted = (proposed, canonical(c)); self.context = nil; token = nil
    }
    public func commitShadow(context c: ExecutionContext) async throws {
        // Direct use still obeys prepare/idempotent publish; the suite journal decision is owned
        // by NumiSuiteCoordinator, not this numerical adapter.
        let prepared = try await prepareSuiteCommit(context: c)
        try await commitSuitePrepared(prepared, context: c)
    }
    public func rollbackSuitePrepared(_ proposed: SuiteCommitToken, context c: ExecutionContext) async {
        guard proposed == token else { return }
        await rollbackShadow(context: c)
    }
    public func rollbackShadow(context c: ExecutionContext) async {
        guard !operating, let context, same(context, c) else { return }
        operating = true; defer { operating = false }
        await backend.rollbackShadow(context: c)
        self.context = nil; token = nil
    }
    public func counters(context c: ExecutionContext) async -> RuntimeCounters { await backend.counters(context: c) }
    public func exportCommittedState() async throws -> TissueRuntimeState {
        try enter(); defer { operating = false }
        return try await backend.exportCommittedState()
    }
}
