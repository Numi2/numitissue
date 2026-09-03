#if canImport(Metal)
import Foundation
import Metal
import XCTest
import NumiTissue

final class MetalExecutionValidationTests: XCTestCase {
    func testMetalShaderLibraryPrewarmsEveryRuntimePipeline() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let context = try MetalDeviceContext(
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024
            )
        )
        let shaders = try await MetalShaderLibrary(context: context)
        try shaders.prewarm()
        XCTAssertEqual(
            Set(MetalKernel.allCases.map(\.rawValue)),
            Set(shaders.library.functionNames)
        )
        for kernel in MetalKernel.allCases {
            let pipeline = try shaders.pipeline(kernel)
            XCTAssertGreaterThan(pipeline.maxTotalThreadsPerThreadgroup, 0, kernel.rawValue)
        }
    }

    func testEmptyTissueCompletesMetalTransactionAndExportsFiniteState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let capabilities = TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: device.supportsFamily(.apple7),
            recommendedWorkingSetBytes: UInt64(device.recommendedMaxWorkingSetSize),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
        let backend = try MetalTissueBackend(
            capabilities: capabilities,
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024
            )
        )
        let session = NumiTissueSession(backend: backend)
        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: ValidationFixtures.passiveState()
        )

        let report = await session.step(randomSeed: 7)
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
    }

    func testMolecularRuntimeRejectsMissingProgramInsteadOfNoOp() async throws {
        let fixture = try MetalValidationFixture.make()
        let cpu = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities()
        )
        do {
            try await cpu.load(model: fixture.model, initialState: fixture.state)
            XCTFail("A molecular model without a CPU program must be rejected")
        } catch let error as CPUReferenceBackendError {
            guard case .molecularProgramMissing = error else {
                return XCTFail("Unexpected CPU error: \(error)")
            }
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let metal = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions()
        )
        do {
            try await metal.load(model: fixture.model, initialState: fixture.state)
            XCTFail("A molecular model without a Metal program must be rejected")
        } catch let error as MetalRuntimeError {
            XCTAssertTrue(String(describing: error).contains("no Metal molecular program"))
        }
    }

    func testMetalRichFixtureRunsElectrophysiologyEventsFieldsGliaAndMolecularState() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let backend = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
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
        XCTAssertEqual(state.cells.count, 3)
        XCTAssertEqual(state.compartments.count, 2)
        XCTAssertEqual(state.synapses.count, 1)
        XCTAssertEqual(state.microdomains.count, 1)
        XCTAssertGreaterThan(state.synapses[0].conductance, 0)
        XCTAssertGreaterThan(state.synapses[0].preTrace, 0)
        XCTAssertGreaterThan(state.molecularSpecies[1], 0)
        XCTAssertLessThan(state.molecularSpecies[0], 10)
        XCTAssertTrue(state.fields.allSatisfy { $0.concentration.isFinite && $0.concentration >= 0 })
        let astroRegulatoryBase = Int(state.cells[2].regulatoryRange.lowerBound)
        XCTAssertGreaterThan(state.regulatoryState[astroRegulatoryBase], 0)
        XCTAssertGreaterThan(state.regulatoryState[astroRegulatoryBase + 1], 0)
        XCTAssertTrue(state.cells.allSatisfy { cell in
            [
                cell.position.x, cell.position.y, cell.position.z,
                cell.energyReserve, cell.oxygenStress, cell.glucoseStress,
                cell.damage
            ].allSatisfy(\.isFinite)
        })
        XCTAssertTrue(state.compartments.allSatisfy { compartment in
            [
                compartment.voltageMillivolts,
                compartment.previousVoltageMillivolts,
                compartment.capacitanceNanofarads,
                compartment.synapticCurrentNanoamps
            ].allSatisfy(\.isFinite)
        })
    }

    func testMetalRejectedTransactionRollsBackBiologyAndEventWheel() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let backend = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
            molecularProgram: fixture.metalMolecularProgram
        )
        let session = NumiTissueSession(backend: backend)
        try await session.load(model: fixture.model, state: fixture.state)
        let initialDigest = try TissueStateDigest.compute(fixture.state)

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

        let checkpointState = try await backend.exportBackendCheckpointState()
        let wheel = try RuntimeBackendCheckpointArchive.decode(
            MetalEventWheelSnapshot.self,
            from: checkpointState,
            expectedBackendIdentifier: MetalTissueBackend.checkpointBackendID,
            expectedPayloadVersion: 1
        )
        XCTAssertTrue(wheel.events.isEmpty)

        let recovered = await session.step(
            input: RuntimeInputFrame(afferentEvents: [
                RoutedEvent(
                    arrivalTick: 1,
                    source: 900,
                    destination: 0,
                    amplitude: 1,
                    kind: .spike
                )
            ]),
            randomSeed: 0xD1CF
        )
        XCTAssertEqual(recovered.status, .committed, recovered.errorDescription ?? "")
        XCTAssertEqual(recovered.counters.deliveredEvents, 1)
    }

    func testMetalCheckpointRestoresPendingEventsAndContinuesIdentically() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
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

        let sourceBackend = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
            molecularProgram: fixture.metalMolecularProgram
        )
        let sourceSession = NumiTissueSession(
            backend: sourceBackend,
            phasePlanner: planner
        )
        try await sourceSession.load(model: fixture.model, state: fixture.state)
        let first = await sourceSession.step(input: pending, randomSeed: 17)
        XCTAssertEqual(first.status, .committed, first.errorDescription ?? "")
        XCTAssertEqual(first.counters.deliveredEvents, 0)
        let checkpoint = try await sourceSession.makeCheckpoint(
            modelDigest: ValidationFixtures.modelDigest,
            randomSeed: 17,
            metadata: ["case": "metal.pending-event-round-trip"]
        )

        let directory = try ValidationFixtures.temporaryDirectory(
            prefix: "numitissue-metal-checkpoint"
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
        XCTAssertEqual(expectedReport.status, .committed, expectedReport.errorDescription ?? "")
        XCTAssertEqual(expectedReport.counters.deliveredEvents, 1)
        let expectedState = try await sourceSession.exportState()

        let restoredBackend = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
            molecularProgram: fixture.metalMolecularProgram
        )
        let restoredSession = NumiTissueSession(
            backend: restoredBackend,
            phasePlanner: planner
        )
        try await restoredSession.load(
            model: fixture.model,
            checkpoint: restoredCheckpoint,
            expectedModelDigest: ValidationFixtures.modelDigest
        )
        let restoredReport = await restoredSession.step(randomSeed: 18)
        XCTAssertEqual(restoredReport.status, .committed, restoredReport.errorDescription ?? "")
        XCTAssertEqual(restoredReport.counters.deliveredEvents, 1)
        let restoredState = try await restoredSession.exportState()
        XCTAssertEqual(
            try TissueStateDigest.compute(restoredState),
            try TissueStateDigest.compute(expectedState)
        )
        XCTAssertEqual(restoredState.time, expectedState.time)
        XCTAssertEqual(restoredState.epoch, expectedState.epoch)
    }

    func testMetalFidelityMigrationPreservesStableIDsAndPendingEvents() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let planner = RuntimePhasePlanner()
        let backend = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
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

    func testCPUAndMetalAgreeOnDeterministicRichFixture() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let fixture = try MetalValidationFixture.make()
        let planner = RuntimePhasePlanner()
        let input = RuntimeInputFrame(afferentEvents: [
            RoutedEvent(arrivalTick: 1, source: 900, destination: 0, amplitude: 0.25),
            RoutedEvent(arrivalTick: 1, source: 900, destination: 0, amplitude: 0.75)
        ])

        let cpu = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(),
            molecularProgram: fixture.cpuMolecularProgram
        )
        let cpuSession = NumiTissueSession(backend: cpu, phasePlanner: planner)
        try await cpuSession.load(model: fixture.model, state: fixture.state)
        let cpuReport = await cpuSession.step(input: input, randomSeed: 0x1234_5678)
        XCTAssertEqual(cpuReport.status, .committed, cpuReport.errorDescription ?? "")
        let cpuState = try await cpuSession.exportState()

        let metal = try MetalTissueBackend(
            capabilities: metalCapabilities(device: device),
            device: device,
            options: metalOptions(),
            molecularProgram: fixture.metalMolecularProgram
        )
        let metalSession = NumiTissueSession(backend: metal, phasePlanner: planner)
        try await metalSession.load(model: fixture.model, state: fixture.state)
        let metalReport = await metalSession.step(input: input, randomSeed: 0x1234_5678)
        XCTAssertEqual(metalReport.status, .committed, metalReport.errorDescription ?? "")
        let metalState = try await metalSession.exportState()

        XCTAssertEqual(cpuState.time, metalState.time)
        XCTAssertEqual(cpuState.epoch, metalState.epoch)
        XCTAssertEqual(cpuState.cells.count, metalState.cells.count)
        XCTAssertEqual(cpuState.compartments.count, metalState.compartments.count)
        XCTAssertEqual(cpuState.synapses.count, metalState.synapses.count)
        XCTAssertEqual(cpuState.molecularSpecies.count, metalState.molecularSpecies.count)

        let voltageError = maxAbsoluteDifference(
            cpuState.compartments.map(\.voltageMillivolts),
            metalState.compartments.map(\.voltageMillivolts)
        )
        let gateValuesCPU = stride(from: 0, to: cpuState.mechanismState.count, by: 16).flatMap { base in
            cpuState.mechanismState[base..<min(base + 3, cpuState.mechanismState.count)]
        }
        let gateValuesMetal = stride(from: 0, to: metalState.mechanismState.count, by: 16).flatMap { base in
            metalState.mechanismState[base..<min(base + 3, metalState.mechanismState.count)]
        }
        let gateValueError = maxAbsoluteDifference(gateValuesCPU, gateValuesMetal)
        let mechanismDiagnosticCPU = cpuState.mechanismState.enumerated()
            .filter { $0.offset % 16 != 14 }
            .map(\.element)
        let mechanismDiagnosticMetal = metalState.mechanismState.enumerated()
            .filter { $0.offset % 16 != 14 }
            .map(\.element)
        let mechanismRelativeError = maxRelativeDifference(mechanismDiagnosticCPU, mechanismDiagnosticMetal)
        let synapseError = maxAbsoluteDifference(
            cpuState.synapses.flatMap { [$0.weight, $0.conductance, $0.shortTermResources, $0.eligibility] },
            metalState.synapses.flatMap { [$0.weight, $0.conductance, $0.shortTermResources, $0.eligibility] }
        )
        let fieldError = maxAbsoluteDifference(
            cpuState.fields.map(\.concentration),
            metalState.fields.map(\.concentration)
        )
        let regulatoryError = maxAbsoluteDifference(cpuState.regulatoryState, metalState.regulatoryState)
        let molecularError = maxAbsoluteDifference(cpuState.molecularSpecies, metalState.molecularSpecies)
        XCTAssertLessThan(voltageError, 2e-3)
        XCTAssertLessThan(gateValueError, 2e-5)
        // The cable reference uses Double intermediates while Metal is FP32. Compare the
        // diagnostic RHS/diagonal lanes by scale, while keeping the gate lanes absolute.
        XCTAssertLessThan(mechanismRelativeError, 1e-5)
        XCTAssertLessThan(synapseError, 2e-3)
        XCTAssertLessThan(fieldError, 2e-3)
        XCTAssertLessThan(regulatoryError, 2e-5)
        XCTAssertLessThan(molecularError, 2e-4)
    }

    private func metalCapabilities(device: MTLDevice) -> TissueRuntimeCapabilities {
        TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: device.supportsFamily(.apple7),
            recommendedWorkingSetBytes: UInt64(device.recommendedMaxWorkingSetSize),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
    }

    private func metalOptions() -> MetalExecutionOptions {
        MetalExecutionOptions(
            privateHeapBytes: 128 * 1_024 * 1_024,
            stagingBytes: 8 * 1_024 * 1_024
        )
    }

    private func maxAbsoluteDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .greatestFiniteMagnitude }
        return zip(lhs, rhs).reduce(0) { result, pair in
            max(result, abs(pair.0 - pair.1))
        }
    }

    private func maxRelativeDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .greatestFiniteMagnitude }
        return zip(lhs, rhs).reduce(0) { result, pair in
            let scale = max(1, max(abs(pair.0), abs(pair.1)))
            return max(result, abs(pair.0 - pair.1) / scale)
        }
    }
}
#endif
