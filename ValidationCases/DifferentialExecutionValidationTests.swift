import Foundation
import XCTest
import NumiTissue
import NumiTissueRuntime

final class DifferentialExecutionValidationTests: XCTestCase {
    func testCanonicalDigestIsStableAndPoolSensitive() throws {
        let state = ValidationFixtures.passiveState()
        let first = RuntimeStateDigestBuilder.make(state: state)
        let second = RuntimeStateDigestBuilder.make(state: state)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.combined, second.combined)

        var changed = state
        changed.compartments[0].voltageMillivolts += 0.001
        let changedDigest = RuntimeStateDigestBuilder.make(state: changed)
        XCTAssertEqual(first.metadata, changedDigest.metadata)
        XCTAssertNotEqual(first.compartments, changedDigest.compartments)
        XCTAssertNotEqual(first.combined, changedDigest.combined)
    }

    func testFloatToleranceSupportsExplicitULPContract() {
        let reference: Float = 1
        let oneULPAway = Float(bitPattern: reference.bitPattern + 1)
        XCTAssertFalse(RuntimeFloatTolerance.bitwise.accepts(reference, oneULPAway))
        XCTAssertTrue(RuntimeFloatTolerance(
            absolute: 0,
            relative: 0,
            maximumULPDistance: 1
        ).accepts(reference, oneULPAway))
        XCTAssertEqual(
            RuntimeFloatTolerance.ulpDistance(reference, oneULPAway),
            1
        )
    }

    func testIdenticalCPUBackendsPassPhaseDifferentialAndRollback() async throws {
        let reference = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "reference")
        )
        let candidate = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "candidate")
        )
        let runner = DifferentialTissueRunner(
            reference: DifferentialBackendParticipant(
                identifier: "reference",
                backend: reference
            ),
            candidates: [
                DifferentialBackendParticipant(
                    identifier: "candidate",
                    backend: candidate
                )
            ],
            configuration: DifferentialExecutionConfiguration(
                contract: .bitwise,
                commitPolicy: .rollbackAfterComparison,
                inspectedPhases: [
                    .ingestInputs,
                    .deliverEvents,
                    .updateChannels,
                    .solveCableTrees,
                    .updateFastFields,
                    .collectOutputs,
                    .validate
                ]
            )
        )
        let state = ValidationFixtures.passiveState()
        try await runner.load(
            model: ValidationFixtures.emptyModel(),
            initialState: state
        )

        let report = await runner.step(randomSeed: 7)
        XCTAssertTrue(report.passed, report.failureDescription ?? "differential failure")
        XCTAssertEqual(
            report.disposition.rawValue,
            DifferentialTransactionDisposition.rolledBackAfterComparison.rawValue
        )
        XCTAssertNil(report.firstDivergentPhaseOrdinal)
        XCTAssertFalse(report.phaseReports.isEmpty)
        XCTAssertTrue(report.phaseReports.allSatisfy(\.passed))
        XCTAssertTrue(report.outputReports.allSatisfy(\.passed))

        let referenceState = try await reference.exportCommittedState()
        let candidateState = try await candidate.exportCommittedState()
        XCTAssertEqual(
            RuntimeStateDigestBuilder.make(state: referenceState).combined,
            RuntimeStateDigestBuilder.make(state: state).combined
        )
        XCTAssertEqual(
            RuntimeStateDigestBuilder.make(state: candidateState).combined,
            RuntimeStateDigestBuilder.make(state: state).combined
        )
    }

    func testDifferentialRunnerExpandsDigestMismatchIntoSemanticDifference() async throws {
        let reference = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "reference")
        )
        let candidateBase = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "candidate-base")
        )
        let candidate = try FaultInjectingTissueBackend(
            wrapped: candidateBase,
            plan: RuntimeFaultPlan(rules: [
                RuntimeFaultRule(
                    identifier: "force-digest-expansion",
                    site: .afterDigestCapture,
                    transaction: 1,
                    action: .corruptDigest(
                        domain: .compartments,
                        lane: 0,
                        xorMask: 1
                    )
                ),
                RuntimeFaultRule(
                    identifier: "perturb-voltage-inspection",
                    site: .afterShadowInspection,
                    transaction: 1,
                    action: .perturbInspection(
                        .compartmentVoltage(index: 0, delta: 0.25)
                    )
                )
            ]),
            name: "perturbed-candidate"
        )
        let runner = DifferentialTissueRunner(
            reference: DifferentialBackendParticipant(
                identifier: "reference",
                backend: reference
            ),
            candidates: [
                DifferentialBackendParticipant(
                    identifier: "candidate",
                    backend: candidate
                )
            ],
            configuration: DifferentialExecutionConfiguration(
                contract: .scientific32,
                commitPolicy: .rollbackAfterComparison,
                stopAtFirstDivergence: true,
                inspectedPhases: [.ingestInputs]
            )
        )
        try await runner.load(
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )

        let report = await runner.step(randomSeed: 1)
        XCTAssertEqual(
            report.disposition.rawValue,
            DifferentialTransactionDisposition.diverged.rawValue
        )
        XCTAssertNotNil(report.firstDivergentPhaseOrdinal)
        let semantic = report.phaseReports.first?.candidates.first?.semanticComparison
        XCTAssertNotNil(semantic)
        XCTAssertFalse(semantic?.passed ?? true)
        XCTAssertTrue(semantic?.differences.contains(where: {
            $0.domain == .compartments &&
                $0.path == "voltageMillivolts"
        }) ?? false)
    }

    func testInjectedPhaseFailureRollsBackEveryParticipant() async throws {
        let reference = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "reference")
        )
        let candidateBase = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(name: "candidate-base")
        )
        let candidate = try FaultInjectingTissueBackend(
            wrapped: candidateBase,
            plan: RuntimeFaultPlan(rules: [
                RuntimeFaultRule(
                    identifier: "fail-after-first-channel-update",
                    site: .afterPhase,
                    transaction: 1,
                    phase: .updateChannels,
                    invocation: 1,
                    action: .fail(
                        code: "validation.injected.channel",
                        message: "exercise rollback after a completed mutating phase"
                    )
                )
            ])
        )
        let state = ValidationFixtures.passiveState()
        let initialDigest = RuntimeStateDigestBuilder.make(state: state).combined
        let runner = DifferentialTissueRunner(
            reference: DifferentialBackendParticipant(
                identifier: "reference",
                backend: reference
            ),
            candidates: [
                DifferentialBackendParticipant(
                    identifier: "candidate",
                    backend: candidate
                )
            ]
        )
        try await runner.load(
            model: ValidationFixtures.emptyModel(),
            initialState: state
        )

        let report = await runner.step(randomSeed: 3)
        XCTAssertEqual(
            report.disposition.rawValue,
            DifferentialTransactionDisposition.failed.rawValue
        )
        XCTAssertTrue(report.failureDescription?.contains("validation.injected.channel") ?? false)
        let referenceAfterFailure = try await reference.exportCommittedState()
        let candidateAfterFailure = try await candidateBase.exportCommittedState()
        XCTAssertEqual(
            RuntimeStateDigestBuilder.make(state: referenceAfterFailure).combined,
            initialDigest
        )
        XCTAssertEqual(
            RuntimeStateDigestBuilder.make(state: candidateAfterFailure).combined,
            initialDigest
        )
        let faults = await candidate.triggeredFaults()
        XCTAssertEqual(faults.map(\.ruleIdentifier), ["fail-after-first-channel-update"])
    }

    func testBenchmarkReportUsesMeasuredTransactionsOnly() async throws {
        let state = ValidationFixtures.passiveState()
        let runner = RuntimeBenchmarkRunner(
            backendFactory: {
                CPUReferenceTissueBackend(
                    capabilities: ValidationFixtures.capabilities(
                        name: "benchmark-reference"
                    )
                )
            },
            model: ValidationFixtures.emptyModel(),
            initialState: state,
            configuration: RuntimeBenchmarkConfiguration(
                warmupTransactions: 1,
                measuredTransactions: 3,
                randomSeed: 9,
                captureFinalDigest: true
            )
        )

        let report = try await runner.run(
            metadata: ["case": "phase2.cpu-benchmark"]
        )
        XCTAssertEqual(report.samples.count, 3)
        XCTAssertEqual(report.configuration.warmupTransactions, 1)
        XCTAssertEqual(report.configuration.measuredTransactions, 3)
        XCTAssertGreaterThan(report.simulatedMilliseconds, 0)
        XCTAssertGreaterThan(report.wallSeconds, 0)
        XCTAssertGreaterThan(report.simulatedMillisecondsPerWallSecond, 0)
        XCTAssertNotNil(report.finalStateDigest)
        XCTAssertEqual(report.metadata["case"], "phase2.cpu-benchmark")
        XCTAssertEqual(report.telemetry?.energyJoules, nil)
    }
}
