import Foundation
import XCTest
import NumiTissue
import NumiTissueRuntime

final class ReproducibilityValidationTests: XCTestCase {
    func testSameSeedReferenceRunsProduceIdenticalTransactionIdentities() async throws {
        let verifier = RuntimeReproducibilityVerifier(
            backendFactory: {
                CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "reproducibility-reference"
                    )
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState(),
            configuration: RuntimeReproducibilityConfiguration(
                repetitions: 3,
                transactionsPerRun: 3,
                randomSeed: 0x1234,
                requireBackendCheckpointIdentity: true
            )
        )

        let certificate = try await verifier.verify(
            input: { ordinal, time in
                RuntimeInputFrame(
                    afferentEvents: [
                        RoutedEvent(
                            arrivalTick: time.tick + 20,
                            source: UInt64(ordinal + 1),
                            destination: 0,
                            amplitude: Float(ordinal + 1) * 0.01,
                            kind: .analogAfferent,
                            sequence: UInt32(ordinal)
                        )
                    ]
                )
            },
            metadata: ["case": "phase2.same-seed-reference"]
        )

        XCTAssertTrue(certificate.passed)
        XCTAssertEqual(certificate.runs.count, 3)
        XCTAssertTrue(certificate.runs.allSatisfy {
            $0.steps.count == 3 && $0.failureDescription == nil
        })
        XCTAssertTrue(certificate.mismatches.isEmpty)
        XCTAssertEqual(
            certificate.metadata["case"],
            "phase2.same-seed-reference"
        )
        let baseline = certificate.runs[0].steps
        for run in certificate.runs.dropFirst() {
            XCTAssertEqual(run.steps, baseline)
        }
    }

    func testReplayCertificateRejectsMissingBackendCheckpointIdentity() async throws {
        let verifier = RuntimeReproducibilityVerifier(
            backendFactory: {
                let base = CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "non-checkpoint-wrapper-base"
                    )
                )
                return try FaultInjectingTissueBackend(
                    wrapped: base,
                    plan: RuntimeFaultPlan(rules: [])
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState(),
            configuration: RuntimeReproducibilityConfiguration(
                repetitions: 2,
                transactionsPerRun: 1,
                requireBackendCheckpointIdentity: true
            )
        )

        let certificate = try await verifier.verify()
        XCTAssertFalse(certificate.passed)
        XCTAssertEqual(certificate.runs.count, 2)
        XCTAssertTrue(certificate.runs.allSatisfy {
            $0.failureDescription?.contains("checkpoint state") == true
        })
    }
}
