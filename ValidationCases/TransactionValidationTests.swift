import Foundation
import XCTest
import NumiTissue

final class TransactionValidationTests: XCTestCase {
    func testStaleContextIsRejectedBeforeShadowMutation() async throws {
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let state = ValidationFixtures.passiveState()
        try await backend.load(
            model: ValidationFixtures.emptyModel(),
            initialState: state
        )

        do {
            try await backend.beginShadowStep(
                context: ValidationFixtures.context(
                    transaction: 1,
                    epoch: 1,
                    startTick: 0
                ),
                input: RuntimeInputFrame()
            )
            XCTFail("Stale epoch was accepted")
        } catch RuntimeExecutionError.staleTransaction {
            // Expected.
        } catch {
            XCTFail("Unexpected stale-context error: \(error)")
        }

        let committed = try await backend.exportCommittedState()
        XCTAssertEqual(try TissueStateDigest.compute(committed), try TissueStateDigest.compute(state))
    }

    func testDelayedCommittedEventSurvivesShadowRollback() async throws {
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        try await backend.load(
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )

        let first = ValidationFixtures.context(
            transaction: 1,
            epoch: 0,
            startTick: 0
        )
        let future = RoutedEvent(
            arrivalTick: 300,
            source: 99,
            destination: 0,
            amplitude: 2.25,
            kind: .analogAfferent
        )
        try await backend.beginShadowStep(
            context: first,
            input: RuntimeInputFrame(afferentEvents: [future])
        )
        try await backend.execute(
            phase: .ingestInputs,
            tickRange: 0..<200,
            context: first
        )
        try await backend.execute(
            phase: .deliverEvents,
            tickRange: 0..<200,
            context: first
        )
        try await backend.commitShadow(context: first)

        let committedWheel = try await backend.exportEventWheelSnapshot()
        XCTAssertEqual(committedWheel.originTick, 200)
        XCTAssertEqual(committedWheel.events.count, 1)
        XCTAssertEqual(committedWheel.events[0].arrivalTick, 300)

        let rejectedAttempt = ValidationFixtures.context(
            transaction: 2,
            epoch: 1,
            startTick: 200
        )
        try await backend.beginShadowStep(
            context: rejectedAttempt,
            input: RuntimeInputFrame()
        )
        try await backend.execute(
            phase: .deliverEvents,
            tickRange: 200..<310,
            context: rejectedAttempt
        )
        await backend.rollbackShadow(context: rejectedAttempt)

        let afterRollback = try await backend.exportEventWheelSnapshot()
        XCTAssertEqual(afterRollback, committedWheel)

        let retry = ValidationFixtures.context(
            transaction: 3,
            epoch: 1,
            startTick: 200
        )
        try await backend.beginShadowStep(
            context: retry,
            input: RuntimeInputFrame()
        )
        try await backend.execute(
            phase: .deliverEvents,
            tickRange: 200..<400,
            context: retry
        )
        try await backend.commitShadow(context: retry)

        let committed = try await backend.exportCommittedState()
        XCTAssertEqual(committed.time.tick, 400)
        XCTAssertEqual(committed.epoch, 2)
        XCTAssertEqual(
            committed.compartments[0].injectedCurrentNanoamps,
            2.25,
            accuracy: 1e-7
        )
        XCTAssertTrue(
            try await backend.exportEventWheelSnapshot().events.isEmpty
        )
    }

    func testIncompleteEventAdvanceCannotCommit() async throws {
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        try await backend.load(
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )
        let context = ValidationFixtures.context(
            transaction: 1,
            epoch: 0,
            startTick: 0
        )
        try await backend.beginShadowStep(
            context: context,
            input: RuntimeInputFrame()
        )

        do {
            try await backend.commitShadow(context: context)
            XCTFail("Incomplete transaction committed")
        } catch CPUReferenceBackendError.incompleteEventAdvance(
            expected: 200,
            actual: 0
        ) {
            // Expected.
        } catch {
            XCTFail("Unexpected incomplete-commit error: \(error)")
        }
        await backend.rollbackShadow(context: context)
        let committed = try await backend.exportCommittedState()
        XCTAssertEqual(committed.time.tick, 0)
        XCTAssertEqual(committed.epoch, 0)
    }

    func testValidationRejectionRollsBackBiologyAndInputEvents() async throws {
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let session = NumiTissueSession(backend: backend)
        let initial = ValidationFixtures.passiveState()
        let initialDigest = try TissueStateDigest.compute(initial)
        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: initial
        )

        let report = await session.step(
            input: RuntimeInputFrame(
                afferentEvents: [
                    RoutedEvent(
                        arrivalTick: 1,
                        source: 1,
                        destination: 0,
                        amplitude: 100,
                        kind: .analogAfferent
                    )
                ]
            ),
            randomSeed: 7
        )

        XCTAssertEqual(report.status, .rejected)
        XCTAssertTrue(report.issues.contains {
            $0.severity == .reject &&
            ($0.code == ValidationCode.voltageBounds ||
             $0.code == ValidationCode.nonFinite)
        })
        let committed = try await session.exportState()
        XCTAssertEqual(try TissueStateDigest.compute(committed), initialDigest)
        XCTAssertEqual(try await backend.exportEventWheelSnapshot().count, 0)
        XCTAssertEqual(await session.time().tick, 0)
        XCTAssertEqual(await session.epoch(), 0)
    }

    func testCheckpointRoundTripRestoresPendingEventAndParticipantState() async throws {
        let model = ValidationFixtures.emptyModel()
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let session = NumiTissueSession(backend: backend)
        try await session.load(
            model: model,
            state: ValidationFixtures.passiveState()
        )

        let first = await session.step(
            input: RuntimeInputFrame(
                afferentEvents: [
                    RoutedEvent(
                        arrivalTick: 300,
                        source: 77,
                        destination: 0,
                        amplitude: 1.5,
                        kind: .analogAfferent
                    )
                ]
            ),
            randomSeed: 11
        )
        XCTAssertEqual(first.status, .committed)

        let participant = Data("participant-state".utf8)
        let checkpoint = try await session.makeCheckpoint(
            modelDigest: ValidationFixtures.modelDigest,
            randomSeed: 11,
            metadata: ["case": "transaction.checkpoint-pending-events"],
            participantState: ["test-participant": participant]
        )
        XCTAssertNotNil(checkpoint.opaqueModelState)
        XCTAssertEqual(
            checkpoint.suiteParticipantState["test-participant"],
            participant
        )

        let directory = try ValidationFixtures.temporaryDirectory(
            prefix: "numitissue-checkpoint"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.ntissue")
        try TissueCheckpointArchive.write(
            checkpoint,
            to: url,
            compression: .none
        )
        let restoredCheckpoint = try TissueCheckpointArchive.read(
            from: url,
            expectedModelDigest: ValidationFixtures.modelDigest
        )
        XCTAssertEqual(
            restoredCheckpoint.suiteParticipantState["test-participant"],
            participant
        )

        let restoredBackend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(
                name: "Restored CPU Reference"
            )
        )
        let restoredSession = NumiTissueSession(backend: restoredBackend)
        try await restoredSession.load(
            model: model,
            checkpoint: restoredCheckpoint,
            expectedModelDigest: ValidationFixtures.modelDigest
        )
        XCTAssertEqual(await restoredSession.time().tick, 200)
        XCTAssertEqual(await restoredSession.epoch(), 1)

        let second = await restoredSession.step(randomSeed: 12)
        XCTAssertEqual(second.status, .committed)
        XCTAssertEqual(second.counters.deliveredEvents, 1)
        let finalState = try await restoredSession.exportState()
        XCTAssertEqual(finalState.time.tick, 400)
        XCTAssertEqual(finalState.epoch, 2)
        XCTAssertEqual(
            finalState.compartments[0].injectedCurrentNanoamps,
            1.5,
            accuracy: 1e-7
        )
    }

    func testCheckpointArchiveRejectsCorruption() async throws {
        let checkpoint = try TissueCheckpoint.make(
            state: ValidationFixtures.passiveState(),
            simulatorVersion: "validation",
            randomSeed: 1,
            modelDigest: ValidationFixtures.modelDigest,
            opaqueModelState: Data([1, 2, 3])
        )
        let directory = try ValidationFixtures.temporaryDirectory(
            prefix: "numitissue-corruption"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.ntissue")
        try TissueCheckpointArchive.write(
            checkpoint,
            to: url,
            compression: .none
        )
        var archive = try Data(contentsOf: url)
        XCTAssertGreaterThan(archive.count, 48)
        archive[archive.index(before: archive.endIndex)] ^= 0x01

        XCTAssertThrowsError(
            try TissueCheckpointArchive.decode(archive)
        ) { error in
            guard case TissueCheckpointError.checksum = error else {
                return XCTFail("Unexpected corruption error: \(error)")
            }
        }
    }
}
