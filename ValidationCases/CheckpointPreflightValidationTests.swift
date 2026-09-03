import Foundation
import XCTest
import NumiTissue

final class CheckpointPreflightValidationTests: XCTestCase {
    func testWrongBackendIdentityIsRejectedBeforeLoad() async throws {
        let opaque = try RuntimeBackendCheckpointArchive.encode(
            backendIdentifier: "numitissue.reference.wrong",
            payloadVersion: 1,
            payload: CPUReferenceCheckpointState(
                eventWheel: EventDelayWheel(
                    originTick: 0,
                    capacity: 65_536
                ).snapshot()
            )
        )
        let checkpoint = try TissueCheckpoint.make(
            state: ValidationFixtures.passiveState(),
            simulatorVersion: "validation",
            randomSeed: 1,
            modelDigest: ValidationFixtures.modelDigest,
            opaqueModelState: opaque
        )
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let session = NumiTissueSession(backend: backend)

        do {
            try await session.load(
                model: ValidationFixtures.emptyModel(),
                checkpoint: checkpoint,
                expectedModelDigest: ValidationFixtures.modelDigest
            )
            XCTFail("Checkpoint with the wrong backend identity was accepted")
        } catch NumiTissueSessionError.backendCheckpointPreflightFailed(let reason) {
            XCTAssertTrue(reason.contains("does not match"), reason)
        } catch {
            XCTFail("Unexpected preflight error: \(error)")
        }

        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: ValidationFixtures.passiveState()
        )
        XCTAssertEqual((await session.time()).tick, 0)
        XCTAssertEqual(await session.epoch(), 0)
    }

    func testWrongEventWheelTickIsRejectedBeforeLoad() async throws {
        let payload = CPUReferenceCheckpointState(
            eventWheel: EventDelayWheel(
                originTick: 1,
                capacity: 65_536
            ).snapshot()
        )
        let opaque = try RuntimeBackendCheckpointArchive.encode(
            backendIdentifier: "numitissue.reference.cpu",
            payloadVersion: 1,
            payload: payload
        )
        let checkpoint = try TissueCheckpoint.make(
            state: ValidationFixtures.passiveState(),
            simulatorVersion: "validation",
            randomSeed: 1,
            modelDigest: ValidationFixtures.modelDigest,
            opaqueModelState: opaque
        )
        let backend = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let session = NumiTissueSession(backend: backend)

        do {
            try await session.load(
                model: ValidationFixtures.emptyModel(),
                checkpoint: checkpoint,
                expectedModelDigest: ValidationFixtures.modelDigest
            )
            XCTFail("Checkpoint with a mismatched event-wheel tick was accepted")
        } catch NumiTissueSessionError.backendCheckpointPreflightFailed(let reason) {
            XCTAssertTrue(reason.contains("does not match committed tissue tick"), reason)
        } catch {
            XCTFail("Unexpected preflight error: \(error)")
        }

        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: ValidationFixtures.passiveState()
        )
        XCTAssertEqual((await session.time()).tick, 0)
    }

    func testParticipantMutationInvalidatesAuxiliaryDigest() throws {
        var checkpoint = try TissueCheckpoint.make(
            state: ValidationFixtures.passiveState(),
            simulatorVersion: "validation",
            randomSeed: 1,
            modelDigest: ValidationFixtures.modelDigest,
            opaqueModelState: Data([1, 2, 3]),
            suiteParticipantState: ["brain": Data([4, 5, 6])]
        )
        checkpoint.suiteParticipantState["brain"]?.append(7)

        XCTAssertThrowsError(try checkpoint.validated()) { error in
            guard case TissueCheckpointError.auxiliaryStateDigestMismatch = error else {
                return XCTFail("Unexpected participant-state error: \(error)")
            }
        }
    }

    func testBackendCheckpointArchiveRejectsOversizedEnvelopeBeforeDecode() {
        let data = Data(repeating: 0, count: 1_025)
        XCTAssertThrowsError(
            try RuntimeBackendCheckpointArchive.decode(
                CPUReferenceCheckpointState.self,
                from: data,
                expectedBackendIdentifier: "numitissue.reference.cpu",
                expectedPayloadVersion: 1,
                maximumEnvelopeBytes: 1_024
            )
        ) { error in
            guard case RuntimeBackendCheckpointError.envelopeTooLarge(1_025) = error else {
                return XCTFail("Unexpected bounded-decode error: \(error)")
            }
        }
    }
}
