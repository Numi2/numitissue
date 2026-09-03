#if canImport(Metal)
import XCTest
import NumiTissue

final class Metal4PlanningValidationTests: XCTestCase {
    func testBarrierPlannerDetectsBlitToDispatchHazard() throws {
        let commands: [Metal4CommandAccess] = [
            .copyCommittedToShadow,
            .dispatch(.updateChannels)
        ]
        let decisions = Metal4HazardPlanner.plan(commands)
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions[0].kind, .none)
        XCTAssertEqual(decisions[1].kind, .blitToDispatch)
        XCTAssertTrue(decisions[1].hazards.contains(.shadowState))
        try Metal4HazardPlanner.validate(
            commands: commands,
            decisions: decisions
        )
    }

    func testReadAfterReadDoesNotCreateBarrier() {
        let first = Metal4CommandAccess(
            label: "first",
            stage: .dispatch,
            accesses: [.init(.modelMetadata, .read)]
        )
        let second = Metal4CommandAccess(
            label: "second",
            stage: .dispatch,
            accesses: [.init(.modelMetadata, .read)]
        )
        let decision = Metal4HazardPlanner.barrier(
            after: first,
            before: second
        )
        XCTAssertEqual(decision.kind, .none)
        XCTAssertTrue(decision.hazards.isEmpty)
    }

    func testHeaderCopyRequiresDispatchToBlitBarrier() {
        let decision = Metal4HazardPlanner.barrier(
            after: .dispatch(.updateChannels),
            before: .copyPhaseHeader
        )
        XCTAssertEqual(decision.kind, .dispatchToBlit)
        XCTAssertTrue(decision.hazards.contains(.phaseHeader))
    }

    func testEveryKernelHasAnAccessDeclaration() {
        for kernel in MetalKernel.allCases {
            let command = Metal4KernelAccessCatalog.command(for: kernel)
            XCTAssertEqual(command.label, kernel.rawValue)
            XCTAssertEqual(command.stage, .dispatch)
            XCTAssertFalse(command.accesses.isEmpty, kernel.rawValue)
            XCTAssertEqual(
                Set(command.accesses.map(\.resource)).count,
                command.accesses.count,
                "Duplicate resource declaration for \(kernel.rawValue)"
            )
        }
    }

    func testAutomaticIndirectDispatchRequiresMeasuredQualification() throws {
        let unqualified = try Metal4DispatchPlanner.decide(
            kernel: .updateChannels,
            threadCount: 100_000,
            configuration: Metal4ExecutionConfiguration(
                indirectDispatchMode: .qualifiedAutomatic,
                indirectDispatchMinimumThreadCount: 4_096,
                qualifiedIndirectKernelNames: []
            )
        )
        XCTAssertEqual(unqualified.mode, .direct)

        let qualified = try Metal4DispatchPlanner.decide(
            kernel: .updateChannels,
            threadCount: 100_000,
            configuration: Metal4ExecutionConfiguration(
                indirectDispatchMode: .qualifiedAutomatic,
                indirectDispatchMinimumThreadCount: 4_096,
                qualifiedIndirectKernelNames: [
                    MetalKernel.updateChannels.rawValue
                ]
            )
        )
        XCTAssertEqual(qualified.mode, .indirect)
    }

    func testRequiredIndirectDispatchRejectsUnqualifiedKernel() {
        XCTAssertThrowsError(
            try Metal4DispatchPlanner.decide(
                kernel: .updateFastFields,
                threadCount: 100_000,
                configuration: Metal4ExecutionConfiguration(
                    indirectDispatchMode: .requireQualified,
                    qualifiedIndirectKernelNames: []
                )
            )
        ) { error in
            guard case Metal4ContractError.indirectKernelNotQualified = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testConfigurationCanonicalizesQualifiedKernelNames() throws {
        let configuration = try Metal4ExecutionConfiguration(
            qualifiedIndirectKernelNames: [
                MetalKernel.updateMolecularDomains.rawValue,
                MetalKernel.updateChannels.rawValue
            ]
        ).validated()
        XCTAssertEqual(
            configuration.qualifiedIndirectKernelNames,
            [
                MetalKernel.updateChannels.rawValue,
                MetalKernel.updateMolecularDomains.rawValue
            ]
        )
    }

    func testSpecializationHashIsStableAndSensitive() {
        let baseline = Metal4KernelSpecialization(
            topologyDepth: 7,
            channelFamily: 11,
            synapseModel: 2,
            fieldStencil: 6,
            molecularSolver: 3,
            fidelityLevel: 4,
            precisionClass: 32
        )
        XCTAssertEqual(baseline.stableHash, baseline.stableHash)
        var changed = baseline
        changed.topologyDepth += 1
        XCTAssertNotEqual(baseline.stableHash, changed.stableHash)
    }
}
#endif
