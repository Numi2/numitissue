import Foundation
import XCTest
import NumiTissue
import NumiTissueRuntime

final class RollbackVerificationTests: XCTestCase {
    func testExecutionFailurePreservesStateAndCheckpointIdentity() async throws {
        let verifier = RuntimeRollbackVerifier(
            backendFactory: {
                let base = CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "rollback-reference"
                    )
                )
                let faulting = try FaultInjectingTissueBackend(
                    wrapped: base,
                    plan: RuntimeFaultPlan(rules: [
                        RuntimeFaultRule(
                            identifier: "fail-after-channel-update",
                            site: .afterPhase,
                            transaction: 1,
                            phase: .updateChannels,
                            invocation: 1,
                            action: .fail(
                                code: "phase2.rollback.execution",
                                message: "force rollback after mutating electrical state"
                            )
                        )
                    ])
                )
                return RuntimeRollbackBackendBundle(
                    backend: faulting,
                    checkpointAuthority: base
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )

        let certificate = try await verifier.verify(
            input: { context in
                RuntimeInputFrame(
                    afferentEvents: [
                        RoutedEvent(
                            arrivalTick: context.startTime.tick + 20,
                            source: 77,
                            destination: 0,
                            amplitude: 0.2,
                            kind: .analogAfferent,
                            sequence: 1
                        )
                    ]
                )
            },
            metadata: ["case": "phase2.rollback.execution"]
        )

        XCTAssertTrue(certificate.passed)
        XCTAssertEqual(certificate.trigger, .executionFailure)
        XCTAssertTrue(certificate.stateIdentityPreserved)
        XCTAssertEqual(certificate.checkpointIdentityPreserved, true)
        XCTAssertEqual(
            certificate.baselineStateDigest,
            certificate.finalStateDigest
        )
        XCTAssertEqual(
            certificate.baselineCheckpointDigest,
            certificate.finalCheckpointDigest
        )
        XCTAssertEqual(
            certificate.triggeredFaults.map(\.ruleIdentifier),
            ["fail-after-channel-update"]
        )
        XCTAssertTrue(
            certificate.failureDescription?.contains(
                "phase2.rollback.execution"
            ) == true
        )
    }

    func testValidationRejectionPreservesStateAndCheckpointIdentity() async throws {
        let verifier = RuntimeRollbackVerifier(
            backendFactory: {
                let base = CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "rollback-validation-reference"
                    )
                )
                let faulting = try FaultInjectingTissueBackend(
                    wrapped: base,
                    plan: RuntimeFaultPlan(rules: [
                        RuntimeFaultRule(
                            identifier: "reject-validation",
                            site: .afterValidation,
                            transaction: 1,
                            action: .injectValidationIssue(
                                RuntimeValidationIssue(
                                    severity: .reject,
                                    code: 0xF201,
                                    message: "injected validation rejection"
                                )
                            )
                        )
                    ])
                )
                return RuntimeRollbackBackendBundle(
                    backend: faulting,
                    checkpointAuthority: base
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )

        let certificate = try await verifier.verify(
            metadata: ["case": "phase2.rollback.validation"]
        )

        XCTAssertTrue(certificate.passed)
        XCTAssertEqual(certificate.trigger, .validationRejection)
        XCTAssertTrue(certificate.stateIdentityPreserved)
        XCTAssertEqual(certificate.checkpointIdentityPreserved, true)
        XCTAssertTrue(certificate.validationIssues.contains {
            $0.code == 0xF201 && $0.severity == .reject
        })
    }

    func testExplicitRollbackCanBeCertifiedWithoutInjectedFailure() async throws {
        let verifier = RuntimeRollbackVerifier(
            backendFactory: {
                let base = CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "rollback-explicit-reference"
                    )
                )
                return RuntimeRollbackBackendBundle(
                    backend: base,
                    checkpointAuthority: base
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState(),
            configuration: RuntimeRollbackConfiguration(
                requireInjectedFailure: false,
                requireCheckpointIdentity: true
            )
        )

        let certificate = try await verifier.verify()
        XCTAssertTrue(certificate.passed)
        XCTAssertEqual(certificate.trigger, .explicitRollback)
        XCTAssertTrue(certificate.stateIdentityPreserved)
        XCTAssertEqual(certificate.checkpointIdentityPreserved, true)
    }
}
