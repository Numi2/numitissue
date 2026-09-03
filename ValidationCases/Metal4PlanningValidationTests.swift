#if canImport(Metal)
import Foundation
import Metal
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

        XCTAssertThrowsError(
            try Metal4DispatchPlanner.decide(
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
        ) { error in
            guard case Metal4ExecutionPolicyError.unsupportedIndirectKernels(
                [MetalKernel.updateChannels.rawValue]
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

    func testConfigurationRejectsAppleMetal4BufferBindingLimit() {
        XCTAssertThrowsError(
            try Metal4ExecutionConfiguration(
                maximumBufferBindingCount: 32
            ).validated()
        ) { error in
            guard case Metal4ContractError.invalidBindingCount(32) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @available(macOS 26.0, *)
    func testArgumentTableCacheRejectsAppleMetal4BufferBindingLimit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        XCTAssertThrowsError(
            try Metal4ArgumentTableCache(
                device: device,
                maximumBindingCount: 32
            )
        ) { error in
            guard case Metal4ArgumentTableError.invalidMaximumBindingCount(32) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
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

    @available(macOS 26.0, *)
    func testMetal4EmptyTransactionCommitsOnSupportedAppleSilicon() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let support = Metal4Support.probe(device: device)
        guard support.supported else {
            throw XCTSkip(support.reason ?? "Metal 4 is unavailable")
        }

        let capabilities = TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal 4 Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: true,
            recommendedWorkingSetBytes: UInt64(
                device.recommendedMaxWorkingSetSize
            ),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
        let backend = try Metal4TissueBackend(
            capabilities: capabilities,
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024,
                requestedNumericalProfile: .scientific32
            ),
            metal4Configuration: .phase3Scientific
        )
        let session = NumiTissueSession(backend: backend)
        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: ValidationFixtures.passiveState()
        )
        let before = try await backend.telemetrySnapshot()

        let report = await session.step(randomSeed: 0x4D34)
        XCTAssertEqual(report.status, .committed, report.errorDescription ?? "")
        XCTAssertNil(report.errorDescription)

        let state = try await session.exportState()
        XCTAssertEqual(state.time.tick, 200)
        XCTAssertEqual(state.epoch, 1)
        XCTAssertTrue(state.compartments.allSatisfy { compartment in
            [
                compartment.voltageMillivolts,
                compartment.previousVoltageMillivolts,
                compartment.capacitanceNanofarads,
                compartment.axialConductanceMicrosiemens,
                compartment.injectedCurrentNanoamps,
                compartment.synapticCurrentNanoamps,
                compartment.intracellularCalciumMicromolar,
                compartment.intracellularSodiumMillimolar,
                compartment.intracellularPotassiumMillimolar
            ].allSatisfy(\.isFinite)
        })

        let after = try await backend.telemetrySnapshot()
        let transaction = after.delta(from: before)
        XCTAssertGreaterThan(transaction.computeCommandBuffers, 0)
        XCTAssertGreaterThan(transaction.completedCommandBuffers, 0)
        XCTAssertEqual(transaction.failedCommandBuffers, 0)
        XCTAssertEqual(after.deviceRegistryID, device.registryID)
        XCTAssertEqual(
            after.numericalProfile,
            RuntimeNumericalProfile.scientific32
        )
    }

    @available(macOS 26.0, *)
    func testMetal4RichFixtureRoutesBiologyAndCommitsAtomically() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let support = Metal4Support.probe(device: device)
        guard support.supported else {
            throw XCTSkip(support.reason ?? "Metal 4 is unavailable")
        }

        let fixture = try MetalValidationFixture.make()
        let capabilities = TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal 4 Rich Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: true,
            recommendedWorkingSetBytes: UInt64(
                device.recommendedMaxWorkingSetSize
            ),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
        let backend = try Metal4TissueBackend(
            capabilities: capabilities,
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024,
                requestedNumericalProfile: .scientific32
            ),
            metal4Configuration: .phase3Scientific,
            molecularProgram: fixture.metalMolecularProgram
        )
        let session = NumiTissueSession(
            backend: backend,
            phasePlanner: RuntimePhasePlanner(
                fastQuantumTicks: 1,
                routingBlockTicks: 10,
                transactionTicks: 200,
                glialTicks: 40,
                mechanicsTicks: 4_000,
                developmentTicks: 40_000,
                structuralTicks: 40_000,
                fidelityTicks: 4_000
            )
        )
        try await session.load(model: fixture.model, state: fixture.state)

        let report = await session.step(
            input: RuntimeInputFrame(afferentEvents: [
                RoutedEvent(
                    arrivalTick: 1,
                    source: 900,
                    destination: 0,
                    amplitude: 1,
                    kind: .spike
                ),
                RoutedEvent(
                    arrivalTick: 5,
                    source: 901,
                    destination: 0,
                    amplitude: 1,
                    kind: .spike
                )
            ]),
            randomSeed: 0x1234_5678
        )
        XCTAssertEqual(report.status, .committed, report.errorDescription ?? "")
        XCTAssertNil(report.errorDescription)
        XCTAssertEqual(report.counters.deliveredEvents, 2)
        XCTAssertGreaterThan(report.counters.activeTiles, 0)
        XCTAssertGreaterThan(report.counters.activeCompartments, 0)

        let state = try await session.exportState()
        XCTAssertEqual(state.time.tick, 200)
        XCTAssertEqual(state.epoch, 1)
        XCTAssertEqual(state.synapses.count, 1)
        XCTAssertGreaterThan(state.synapses[0].conductance, 0)
        XCTAssertGreaterThan(state.synapses[0].preTrace, 0)
        XCTAssertGreaterThan(state.molecularSpecies[1], 0)
        XCTAssertLessThan(state.molecularSpecies[0], 10)
        XCTAssertTrue(state.fields.allSatisfy {
            $0.concentration.isFinite && $0.concentration >= 0
        })
        XCTAssertTrue(state.cells.allSatisfy { cell in
            [
                cell.position.x, cell.position.y, cell.position.z,
                cell.energyReserve, cell.oxygenStress, cell.glucoseStress,
                cell.damage
            ].allSatisfy(\.isFinite)
        })
    }

    @available(macOS 26.0, *)
    func testMetal4CheckpointRestoresPendingEventsAndContinuesIdentically() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let model = ValidationFixtures.emptyModel()
        let planner = RuntimePhasePlanner()
        let pending = RuntimeInputFrame(afferentEvents: [
            RoutedEvent(
                arrivalTick: 205,
                source: 900,
                destination: 0,
                amplitude: 1,
                kind: .spike
            )
        ])

        let sourceBackend = try makeMetal4Backend(device: device)
        let sourceSession = NumiTissueSession(
            backend: sourceBackend,
            phasePlanner: planner
        )
        try await sourceSession.load(
            model: model,
            state: ValidationFixtures.passiveState()
        )
        let first = await sourceSession.step(input: pending, randomSeed: 17)
        XCTAssertEqual(first.status, .committed, first.errorDescription ?? "")
        XCTAssertEqual(first.counters.deliveredEvents, 0)

        let checkpoint = try await sourceSession.makeCheckpoint(
            modelDigest: ValidationFixtures.modelDigest,
            randomSeed: 17,
            metadata: ["case": "metal4.pending-event-round-trip"]
        )
        let directory = try ValidationFixtures.temporaryDirectory(
            prefix: "numitissue-metal4-checkpoint"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.ntissue")
        try TissueCheckpointArchive.write(checkpoint, to: url, compression: .none)
        let restoredCheckpoint = try TissueCheckpointArchive.read(
            from: url,
            expectedModelDigest: ValidationFixtures.modelDigest
        )
        XCTAssertNotNil(restoredCheckpoint.opaqueModelState)

        let expectedReport = await sourceSession.step(randomSeed: 18)
        XCTAssertEqual(
            expectedReport.status,
            .committed,
            expectedReport.errorDescription ?? ""
        )
        XCTAssertEqual(expectedReport.counters.deliveredEvents, 1)
        let expectedState = try await sourceSession.exportState()

        let restoredBackend = try makeMetal4Backend(device: device)
        let restoredSession = NumiTissueSession(
            backend: restoredBackend,
            phasePlanner: planner
        )
        try await restoredSession.load(
            model: model,
            checkpoint: restoredCheckpoint,
            expectedModelDigest: ValidationFixtures.modelDigest
        )
        let restoredReport = await restoredSession.step(randomSeed: 18)
        XCTAssertEqual(
            restoredReport.status,
            .committed,
            restoredReport.errorDescription ?? ""
        )
        XCTAssertEqual(restoredReport.counters.deliveredEvents, 1)
        let restoredState = try await restoredSession.exportState()
        XCTAssertEqual(
            try TissueStateDigest.compute(restoredState),
            try TissueStateDigest.compute(expectedState)
        )
        XCTAssertEqual(restoredState.time, expectedState.time)
        XCTAssertEqual(restoredState.epoch, expectedState.epoch)
    }

    @available(macOS 26.0, *)
    func testMetal4RejectedTransactionPreservesCommittedState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let backend = try makeMetal4Backend(
            device: device,
            molecularProgram: fixture.metalMolecularProgram
        )
        let session = NumiTissueSession(backend: backend)
        let initial = fixture.state
        let initialDigest = try TissueStateDigest.compute(initial)
        try await session.load(
            model: fixture.model,
            state: initial
        )

        let rejected = await session.step(
            input: RuntimeInputFrame(afferentEvents: [
                RoutedEvent(
                    arrivalTick: 1,
                    source: 900,
                    destination: 0,
                    amplitude: 3.0e38,
                    kind: .spike
                )
            ]),
            randomSeed: 0xD1CE
        )
        XCTAssertEqual(rejected.status, .rejected, rejected.errorDescription ?? "")
        XCTAssertTrue(rejected.issues.contains { $0.severity == .reject })
        let rolledBack = try await session.exportState()
        XCTAssertEqual(try TissueStateDigest.compute(rolledBack), initialDigest)
        let rolledBackTime = await session.time()
        let rolledBackEpoch = await session.epoch()
        XCTAssertEqual(rolledBackTime.tick, 0)
        XCTAssertEqual(rolledBackEpoch, 0)
    }

    @available(macOS 26.0, *)
    func testMetal4FidelityMigrationPreservesStableIDsAndPendingEvents() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let planner = RuntimePhasePlanner()
        let backend = try makeMetal4Backend(
            device: device,
            molecularProgram: fixture.metalMolecularProgram
        )
        let session = NumiTissueSession(backend: backend, phasePlanner: planner)
        try await session.load(model: fixture.model, state: fixture.state)
        let context = planner.context(
            startTime: fixture.state.time,
            epoch: fixture.state.epoch,
            transaction: TransactionID(rawValue: 1),
            randomSeed: 19
        )
        try await backend.stageFidelityDecisions(
            [
                FidelityDecision(
                    cellIndex: 0,
                    from: .detailedNeuron,
                    to: .reducedNeuron,
                    kind: .demote,
                    score: 0.1,
                    reasonMask: 1
                )
            ],
            context: context
        )

        let first = await session.step(
            input: RuntimeInputFrame(afferentEvents: [
                RoutedEvent(
                    arrivalTick: 205,
                    source: 900,
                    destination: 0,
                    amplitude: 1,
                    kind: .spike
                )
            ]),
            randomSeed: 19
        )
        XCTAssertEqual(first.status, .committed, first.errorDescription ?? "")
        let migrated = try await session.exportState()
        XCTAssertEqual(migrated.cells[0].id, fixture.state.cells[0].id)
        XCTAssertEqual(migrated.cells[0].fidelity, .reducedNeuron)
        let plan = await backend.lastFidelityMigrationPlan()
        XCTAssertEqual(plan?.decisions.count, 1)
        XCTAssertEqual(plan?.decisions.first?.cellIndex, 0)

        let second = await session.step(randomSeed: 20)
        XCTAssertEqual(second.status, .committed, second.errorDescription ?? "")
        XCTAssertEqual(second.counters.deliveredEvents, 1)
    }

    @available(macOS 26.0, *)
    func testCPUAndMetal4AgreeOnDeterministicSmallFixture() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let cpu = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        let metal4 = try makeMetal4Backend(device: device)
        let runner = DifferentialTissueRunner(
            reference: DifferentialBackendParticipant(
                identifier: "cpu-scientific-reference",
                backend: cpu
            ),
            candidates: [
                DifferentialBackendParticipant(
                    identifier: "metal4-scientific32",
                    backend: metal4
                )
            ],
            configuration: DifferentialExecutionConfiguration(
                contract: .scientific32,
                commitPolicy: .rollbackAfterComparison,
                stopAtFirstDivergence: true,
                inspectedPhases: RuntimePhase.allCases
            )
        )
        try await runner.load(
            model: ValidationFixtures.emptyModel(),
            initialState: ValidationFixtures.passiveState()
        )
        let report = await runner.step(randomSeed: 0xC0FFEE)
        if !report.passed {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            XCTFail(String(decoding: data, as: UTF8.self))
        }
    }

    @available(macOS 26.0, *)
    private func makeMetal4Backend(
        device: MTLDevice,
        molecularProgram: MetalMolecularProgram = MetalMolecularProgram()
    ) throws -> Metal4TissueBackend {
        let support = Metal4Support.probe(device: device)
        guard support.supported else {
            throw XCTSkip(support.reason ?? "Metal 4 is unavailable")
        }
        let capabilities = TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal 4 Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: true,
            recommendedWorkingSetBytes: UInt64(
                device.recommendedMaxWorkingSetSize
            ),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
        return try Metal4TissueBackend(
            capabilities: capabilities,
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024,
                requestedNumericalProfile: .scientific32
            ),
            metal4Configuration: .phase3Scientific,
            molecularProgram: molecularProgram
        )
    }
}
#endif
