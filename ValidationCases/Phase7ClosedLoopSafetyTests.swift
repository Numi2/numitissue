import XCTest
import NumiTissueIntegration
import NumiTissueIO

@MainActor
final class Phase7ClosedLoopSafetyTests: XCTestCase {
    private func request() throws -> NeuralStimulationRequest {
        .init(id: UUID(), plan: try ClosedLoopReplayExample.plan(), scheduledTimeNanoseconds: 10_000_000,
              deadlineNanoseconds: 20_000_000)
    }
    private func evaluate(_ request: NeuralStimulationRequest,
                          envelope: ClosedLoopSafetyEnvelope = ClosedLoopReplayExample.envelope(),
                          history: [ClosedLoopExposure] = []) throws -> ClosedLoopSafetyDecision {
        try ClosedLoopSafetyEvaluator.evaluate(request: request, configuration: ClosedLoopReplayExample.configuration(),
            destinations: [.init(rawValue: 1): 0], envelope: envelope, deviceNowNanoseconds: 1_000_000,
            deviceMinimumLeadNanoseconds: 0, timestampResolutionNanoseconds: 1_000, history: history)
    }
    func testBalancedPlanProducesConservativeReservation() throws {
        let result = try evaluate(request())
        XCTAssertEqual(result.exposures.count, 1)
        XCTAssertEqual(result.totalAbsoluteChargeCoulombs, 2e-10, accuracy: 1e-16)
        XCTAssertEqual(result.endNanoseconds, 10_250_000)
    }
    func testCachedRuntimeStimulusCannotBeSubstituted() throws {
        var r = try request(); r.plan.runtimeStimuli[0].amplitude = 0.1
        XCTAssertThrowsError(try evaluate(r))
    }
    func testUnsafeCurrentIsRejectedBeforeDispatch() throws {
        var r = try request(); r.plan.pulses[0].phases[0].amplitudeAmperes = 0.1
        XCTAssertThrowsError(try evaluate(r))
    }
    func testNonfiniteEnvelopeIsRejected() throws {
        var e = ClosedLoopReplayExample.envelope(); e.maximumPhaseChargeCoulombs = .nan
        XCTAssertThrowsError(try evaluate(request(), envelope: e))
    }
    func testDeadlineDoesNotMeanExecuteImmediately() throws {
        var r = try request(); r.scheduledTimeNanoseconds = 1_000_000
        XCTAssertThrowsError(try evaluate(r))
        r.scheduledTimeNanoseconds = 10_000_000; r.deadlineNanoseconds = 10_100_000
        XCTAssertThrowsError(try evaluate(r))
    }
    func testMissingDeadlineIsRejected() throws {
        var r = try request(); r.deadlineNanoseconds = nil
        XCTAssertThrowsError(try evaluate(r))
    }
    func testLargeAbsoluteTickCannotOverflowLegacyCompiler() throws {
        var r = try request()
        r.plan.pulses[0].startTick = UInt64.max - 2
        r.plan.startTick = UInt64.max - 2; r.plan.endTick = UInt64.max
        XCTAssertThrowsError(try evaluate(r))
    }
    func testPulseExpansionIsBounded() throws {
        var r = try request(); r.plan.pulses[0].repetitions = UInt32.max
        XCTAssertThrowsError(try evaluate(r))
    }
    func testRecoveryAppliesAcrossRequests() throws {
        let h = ClosedLoopExposure(requestID: UUID(), electrode: .init(rawValue: 1),
            startNanoseconds: 9_900_000, endNanoseconds: 10_200_000,
            absoluteChargeCoulombs: 1e-10, activeNanoseconds: 200_000)
        XCTAssertThrowsError(try evaluate(request(), history: [h]))
    }
    func testRollingChargeIncludesAcceptedAndUnknownReservations() throws {
        let e = ClosedLoopReplayExample.envelope()
        let h = ClosedLoopExposure(requestID: UUID(), electrode: .init(rawValue: 1),
            startNanoseconds: 1_000_000, endNanoseconds: 2_000_000,
            absoluteChargeCoulombs: e.maximumRollingChargePerElectrodeCoulombs,
            activeNanoseconds: 100_000)
        XCTAssertThrowsError(try evaluate(request(), history: [h]))
    }
    func testClockMapRejectsBackwardStaleAndOverflowTimes() throws {
        var map = ClosedLoopClockMap(hostAnchorNanoseconds: 100, deviceAnchorNanoseconds: 1_000,
            uncertaintyNanoseconds: 10, maximumAgeNanoseconds: 100, deviceClockID: "fixture")
        XCTAssertEqual(try map.deviceTime(hostNow: 150, maximumUncertainty: 10), 1_050)
        XCTAssertThrowsError(try map.deviceTime(hostNow: 99, maximumUncertainty: 10))
        XCTAssertThrowsError(try map.deviceTime(hostNow: 201, maximumUncertainty: 10))
        XCTAssertThrowsError(try map.deviceTime(hostNow: 150, maximumUncertainty: 9))
        map.deviceAnchorNanoseconds = UInt64.max
        XCTAssertThrowsError(try map.deviceTime(hostNow: 150, maximumUncertainty: 10))
    }
    func testReplayExampleHasDeterministicJournalAndNoPhysicalOutput() async throws {
        let first = try await ClosedLoopReplayExample.run()
        let second = try await ClosedLoopReplayExample.run()
        XCTAssertEqual(first.journalSHA256, second.journalSHA256)
        XCTAssertEqual(first.summary.completedWindows, 2)
        XCTAssertEqual(first.summary.submittedRequests, 2)
        XCTAssertTrue(first.summary.safeStopConfirmed)
        XCTAssertEqual(first.receipts.filter { $0.status == .executed }.count, 1)
        XCTAssertEqual(first.receipts.filter { $0.status == .cancelled }.count, 1)
    }
    func testJournalPayloadTamperingBreaksChain() async throws {
        let run = UUID(), log = try MemoryClosedLoopJournal(runID: UUID())
        try await log.append(kind: "a", deviceNanoseconds: 1, payload: Data([1]))
        try await log.append(kind: "b", deviceNanoseconds: 2, payload: Data([2]))
        var records = await log.snapshot()
        XCTAssertThrowsError(try ClosedLoopJournalVerifier.verify(records, expectedRunID: run))
        let actualRun = try XCTUnwrap(records.first?.runID)
        _ = try ClosedLoopJournalVerifier.verify(records, expectedRunID: actualRun)
        records[0].payload = Data([9])
        XCTAssertThrowsError(try ClosedLoopJournalVerifier.verify(records, expectedRunID: actualRun))
    }
    func testReplayCannotBeAuthorizedAsPhysicalWithMemoryJournal() async throws {
        let config = ClosedLoopReplayExample.configuration()
        let backend = try ReplayNeuralCultureBackend(recordings: ClosedLoopReplayExample.recordings(), sessionID: UUID())
        let session = try await backend.open(cultureID: "fixture", configuration: config)
        let identity = ClosedLoopDeviceIdentity(serial: "fixture", firmware: "fixture", clockID: "fixture",
            electrodeMapSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(config.electrodes)))
        let log = try MemoryClosedLoopJournal(runID: UUID())
        XCTAssertThrowsError(try GuardedNeuralCultureSession(runID: UUID(), backend: backend, session: session,
            environment: .livingCulture, identity: identity, configuration: config, destinations: [.init(rawValue: 1): 0],
            envelope: ClosedLoopReplayExample.envelope(), audit: log, admission: { _ in UInt64.max }))
    }
    func testLostAcknowledgementStopsAndIsNeverResubmitted() async throws {
        let config = ClosedLoopReplayExample.configuration()
        let base = try ReplayNeuralCultureBackend(recordings: ClosedLoopReplayExample.recordings(), sessionID: UUID())
        let backend = AckLossLoopBackend(base: base)
        let session = try await backend.open(cultureID: "fixture", configuration: config)
        let identity = ClosedLoopDeviceIdentity(serial: "fixture", firmware: "fixture", clockID: "fixture",
            electrodeMapSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(config.electrodes)))
        let log = try MemoryClosedLoopJournal(runID: UUID())
        let guarded = try GuardedNeuralCultureSession(runID: UUID(), backend: backend, session: session,
            environment: .emulator, identity: identity, configuration: config, destinations: [.init(rawValue: 1): 0],
            envelope: ClosedLoopReplayExample.envelope(), audit: log)
        try await guarded.admit(nonphysicalExpiryNanoseconds: 1_000_000_000)
        let recording = try await guarded.observe(ClosedLoopReplayExample.recordings()[0].request)
        let digest = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(recording))
        let request = NeuralStimulationRequest(plan: try ClosedLoopReplayExample.plan(),
            scheduledTimeNanoseconds: 11_000_000, deadlineNanoseconds: 15_000_000)
        do { _ = try await guarded.submit(request, basedOn: digest); XCTFail("must report ambiguous delivery") }
        catch ClosedLoopError.ambiguousDelivery(let id) { XCTAssertEqual(id, request.id) }
        let state = await guarded.currentState()
        XCTAssertEqual(state, .stopped)
        do { _ = try await guarded.submit(request, basedOn: digest); XCTFail("must remain latched") }
        catch {}
        let calls = await backend.stimulationCalls
        XCTAssertEqual(calls, 1)
    }
}

private actor AckLossLoopBackend: NonphysicalNeuralCultureBackend {
    nonisolated let name = "NumiTissue recording replay (no physical output)"
    let base: ReplayNeuralCultureBackend
    private(set) var stimulationCalls = 0
    init(base: ReplayNeuralCultureBackend) { self.base = base }
    var capabilities: NeuralCultureBackendCapabilities { get async { await base.capabilities } }
    func open(cultureID: String, configuration: MEAConfiguration) async throws -> NeuralCultureSession {
        try await base.open(cultureID: cultureID, configuration: configuration)
    }
    func close(session: NeuralCultureSession) async throws { try await base.close(session: session) }
    func backendTimeNanoseconds(session: NeuralCultureSession) async throws -> UInt64 { try await base.backendTimeNanoseconds(session: session) }
    func health(session: NeuralCultureSession) async throws -> NeuralCultureHealth { try await base.health(session: session) }
    func record(session: NeuralCultureSession, request: NeuralRecordingRequest) async throws -> NeuralRecording {
        try await base.record(session: session, request: request)
    }
    func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) async throws -> NeuralStimulationReceipt {
        stimulationCalls += 1
        _ = try await base.stimulate(session: session, request: request)
        throw ClosedLoopError.invalid("injected acknowledgement loss after acceptance")
    }
    func cancel(session: NeuralCultureSession, requestID: UUID) async throws { try await base.cancel(session: session, requestID: requestID) }
}
