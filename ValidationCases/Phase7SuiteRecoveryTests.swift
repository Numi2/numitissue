import XCTest
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime
import NumiTissueIntegration
import NumiTissueIO

@MainActor
final class Phase7SuiteRecoveryTests: XCTestCase {
    private func brain(reject: Bool = false) throws -> SnapshotNumiBrainEndpoint<Phase7Counter> {
        try .init(name: "fixture-brain", initialState: .init(steps: 0),
            command: { _, _, _ in .init() },
            integrate: { state, _, _ in (state: .init(steps: state.steps + 1), motor: .init()) },
            validate: { _ in reject ? [.init(source: .brain, severity: .reject, code: 7001, message: "injected validation rejection")] : [] })
    }
    private func physics() throws -> SnapshotNumanXEndpoint<Phase7Counter> {
        try .init(name: "fixture-physics", initialState: .init(steps: 0),
            observe: { _, time in .init(time: time) },
            integrate: { state, _, _ in .init(steps: state.steps + 1) }, validate: { _ in [] })
    }
    func testPartialPublicationNeverRollsBackAndCanRecoverIdempotently() async throws {
        let raw = Phase7FixtureTissueBackend()
        let tissue = PreparedTissueBackendAdapter(backend: raw)
        let rawBrain = try brain()
        let brain = Phase7AckLossBrain(base: rawBrain)
        let physics = try physics(), journal = InMemorySuiteTransactionJournal()
        let coordinator = NumiSuiteCoordinator(tissue: tissue, brain: brain, physics: physics,
            journal: journal, requirePreparedParticipants: true)
        try await coordinator.load(model: ValidationFixtures.emptyModel(), state: TissueRuntimeState())
        let first = await coordinator.step(randomSeed: 7)
        XCTAssertEqual(first.status, .inDoubt)
        let rawCounts = await raw.counts(), brainRollbacks = await brain.rollbackCalls
        XCTAssertEqual(rawCounts.commits, 1); XCTAssertEqual(rawCounts.rollbacks, 0)
        XCTAssertEqual(brainRollbacks, 0)
        do { _ = try await coordinator.exportTissueState(); XCTFail("partial state must not pass publication fence") }
        catch {}
        let blocked = await coordinator.step(randomSeed: 7)
        XCTAssertEqual(blocked.status, .failed)
        let recovered = try await coordinator.recoverCommit()
        XCTAssertEqual(recovered.status, .committed)
        let brainState = try await rawBrain.snapshot(), physicsState = try await physics.snapshot()
        XCTAssertEqual(brainState.steps, 1); XCTAssertEqual(physicsState.steps, 1)
        let afterCounts = await raw.counts(), tick = await coordinator.currentTime()
        XCTAssertEqual(afterCounts.commits, 1); XCTAssertEqual(afterCounts.rollbacks, 0)
        XCTAssertEqual(tick.tick, 200)
        let entries = await journal.entries
        XCTAssertTrue(entries.contains { if case .commitDecided = $0 { return true }; return false })
        XCTAssertFalse(entries.contains { if case .aborted = $0 { return true }; return false })
    }
    func testValidationRejectionAbortsBeforePublication() async throws {
        let raw = Phase7FixtureTissueBackend(), journal = InMemorySuiteTransactionJournal()
        let brain = try brain(reject: true), physics = try physics()
        let coordinator = NumiSuiteCoordinator(tissue: PreparedTissueBackendAdapter(backend: raw),
            brain: brain, physics: physics, journal: journal, requirePreparedParticipants: true)
        try await coordinator.load(model: ValidationFixtures.emptyModel(), state: TissueRuntimeState())
        let result = await coordinator.step(randomSeed: 7)
        XCTAssertEqual(result.status, .rejected)
        let counts = await raw.counts()
        XCTAssertEqual(counts.commits, 0); XCTAssertEqual(counts.rollbacks, 1)
        let b = try await brain.snapshot(), p = try await physics.snapshot()
        XCTAssertEqual(b.steps, 0); XCTAssertEqual(p.steps, 0)
    }
    func testPreparedEndpointsRejectMutationAndIgnoreDuplicateCommit() async throws {
        let brain = try brain()
        let c = SuiteTransactionContext(transaction: .init(rawValue: 1), epoch: 0,
            startTime: .init(tick: 0), endTime: .init(tick: 200), randomSeed: 1)
        try await brain.beginShadow(context: c, observation: .init(time: c.startTime))
        _ = try await brain.integrateTissue(.init(startTime: c.startTime, endTime: c.endTime), context: c)
        let token = try await brain.prepareCommit(context: c)
        do { _ = try await brain.integrateTissue(.init(startTime: c.startTime, endTime: c.endTime), context: c); XCTFail("mutation after prepare") }
        catch {}
        try await brain.commitPrepared(token, context: c)
        try await brain.commitPrepared(token, context: c)
        await brain.rollbackPrepared(token, context: c)
        let state = try await brain.snapshot()
        XCTAssertEqual(state.steps, 1)
    }
    func testJournalCannotAbortAfterCommitDecision() async throws {
        let journal = InMemorySuiteTransactionJournal()
        let c = SuiteTransactionContext(transaction: .init(rawValue: 2), epoch: 0,
            startTime: .init(tick: 0), endTime: .init(tick: 200), randomSeed: 1)
        let token = SuiteCommitToken(transaction: c.transaction, participant: "fixture", digest: 42)
        await journal.recordPrepared(context: c, tokens: [token])
        try await journal.recordCommitDecision(context: c, tokens: [token])
        do { try await journal.recordAborted(context: c, reason: "invalid rollback"); XCTFail("commit decision is irrevocable") }
        catch {}
        let decided = await journal.hasCommitDecision(context: c, tokens: [token])
        XCTAssertTrue(decided)
    }
    func testDurableJournalPreservesRecoveryDecisionAndRejectsSecondWriter() async throws {
        let root = try ValidationFixtures.temporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("suite.jsonl"), runID = UUID()
        let journal = try DurableSuiteTransactionJournal(url: url, runID: runID)
        let c = SuiteTransactionContext(transaction: .init(rawValue: 3), epoch: 0,
            startTime: .init(tick: 0), endTime: .init(tick: 200), randomSeed: 1)
        let token = SuiteCommitToken(transaction: c.transaction, participant: "fixture", digest: 42)
        try await journal.recordPrepared(context: c, tokens: [token])
        try await journal.recordCommitDecision(context: c, tokens: [token])
        XCTAssertThrowsError(try DurableSuiteTransactionJournal(url: url, runID: runID, reopenExisting: true))
        let decisions = try await journal.recoveryDecisions()
        XCTAssertEqual(decisions.count, 1); XCTAssertTrue(decisions[0].commitDecided)
        let bytes = try Data(contentsOf: url)
        let records = try bytes.split(separator: 10).map {
            try ScientificCanonicalJSON.decode(ClosedLoopAuditRecord.self, from: Data($0))
        }
        _ = try ClosedLoopJournalVerifier.verify(records, expectedRunID: runID)
        do { try await journal.recordAborted(context: c, reason: "no"); XCTFail("abort after commit decision") }
        catch {}
    }
}

private struct Phase7Counter: Codable, Sendable { var steps: Int }

private actor Phase7FixtureTissueBackend: NumiTissueExecutionBackend {
    nonisolated let name = "fixture-tissue"
    nonisolated let capabilities = ValidationFixtures.capabilities(name: "fixture-tissue")
    private var committed: TissueRuntimeState?
    private var shadow: TissueRuntimeState?
    private var commits = 0, rollbacks = 0
    func load(model: CompiledTissueModel, initialState: TissueRuntimeState) throws { committed = initialState }
    func beginShadowStep(context: ExecutionContext, input: RuntimeInputFrame) throws {
        guard shadow == nil, let committed else { throw RuntimeExecutionError.transactionInProgress }
        shadow = committed
    }
    func execute(phase: RuntimePhase, tickRange: Range<UInt64>, context: ExecutionContext) {}
    func collectOutput(context: ExecutionContext) -> RuntimeOutputFrame { .init(startTime: context.startTime, endTime: context.endTime) }
    func validateShadow(context: ExecutionContext) -> [RuntimeValidationIssue] { [] }
    func commitShadow(context: ExecutionContext) throws {
        guard var state = shadow else { throw RuntimeExecutionError.staleTransaction }
        state.time = context.endTime; state.epoch = context.epoch + 1
        committed = state; shadow = nil; commits += 1
    }
    func rollbackShadow(context: ExecutionContext) { shadow = nil; rollbacks += 1 }
    func counters(context: ExecutionContext) -> RuntimeCounters { .init() }
    func exportCommittedState() throws -> TissueRuntimeState {
        guard let committed else { throw RuntimeExecutionError.notLoaded }; return committed
    }
    func counts() -> (commits: Int, rollbacks: Int) { (commits, rollbacks) }
}

private actor Phase7AckLossBrain: PreparedNumiBrainEndpoint {
    nonisolated let name = "fixture-brain"
    let base: SnapshotNumiBrainEndpoint<Phase7Counter>
    private var failOnce = true
    private(set) var rollbackCalls = 0
    init(base: SnapshotNumiBrainEndpoint<Phase7Counter>) { self.base = base }
    func committedTissueCommand(observation: NumanXObservationFrame, context: SuiteTransactionContext) async throws -> NumiBrainTissueCommand {
        try await base.committedTissueCommand(observation: observation, context: context)
    }
    func beginShadow(context: SuiteTransactionContext, observation: NumanXObservationFrame) async throws {
        try await base.beginShadow(context: context, observation: observation)
    }
    func integrateTissue(_ output: RuntimeOutputFrame, context: SuiteTransactionContext) async throws -> NumiBrainMotorFrame {
        try await base.integrateTissue(output, context: context)
    }
    func validateShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue] { try await base.validateShadow(context: context) }
    func prepareCommit(context: SuiteTransactionContext) async throws -> SuiteCommitToken { try await base.prepareCommit(context: context) }
    func commitPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async throws {
        try await base.commitPrepared(token, context: context)
        if failOnce { failOnce = false; throw SuiteCoordinatorError.participantCommitFailed("injected post-publication acknowledgement loss") }
    }
    func commitShadow(context: SuiteTransactionContext) async throws { try await base.commitShadow(context: context) }
    func rollbackPrepared(_ token: SuiteCommitToken, context: SuiteTransactionContext) async {
        rollbackCalls += 1; await base.rollbackPrepared(token, context: context)
    }
    func rollbackShadow(context: SuiteTransactionContext) async { rollbackCalls += 1; await base.rollbackShadow(context: context) }
}
