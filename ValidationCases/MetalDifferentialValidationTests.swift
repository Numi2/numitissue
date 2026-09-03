#if canImport(Metal)
import Foundation
import Metal
import XCTest
import NumiTissue
import NumiTissueRuntime

final class MetalDifferentialValidationTests: XCTestCase {
    func testScientificMetalProfileIsExplicit() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let options = MetalExecutionOptions(
            privateHeapBytes: 128 * 1_024 * 1_024,
            stagingBytes: 8 * 1_024 * 1_024,
            requestedNumericalProfile: .scientific32
        )
        let context = try MetalDeviceContext(device: device, options: options)
        let library = try await MetalShaderLibrary(context: context)
        XCTAssertEqual(
            library.numericalProfile.rawValue,
            RuntimeNumericalProfile.scientific32.rawValue
        )
        XCTAssertEqual(
            context.options.effectiveNumericalProfile.rawValue,
            RuntimeNumericalProfile.scientific32.rawValue
        )
    }

    func testMetalTelemetryReportsMeasuredExecutionWithoutInventedEnergy() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let backend = try MetalTissueBackend(
            capabilities: Self.capabilities(device: device),
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024,
                requestedNumericalProfile: .scientific32
            )
        )
        let session = NumiTissueSession(backend: backend)
        try await session.load(
            model: ValidationFixtures.emptyModel(),
            state: ValidationFixtures.passiveState()
        )
        let before = try await backend.telemetrySnapshot()
        let report = await session.step(randomSeed: 4)
        XCTAssertEqual(report.status, .committed, report.errorDescription ?? "")
        let after = try await backend.telemetrySnapshot()
        let transaction = after.delta(from: before)

        XCTAssertGreaterThan(after.allocatedPrivateBytes, 0)
        XCTAssertGreaterThan(after.allocatedSharedBytes, 0)
        XCTAssertGreaterThan(transaction.computeCommandBuffers, 0)
        XCTAssertGreaterThan(transaction.completedCommandBuffers, 0)
        XCTAssertGreaterThan(after.blitEncoders, 0)
        XCTAssertEqual(after.energyJoules, nil)
        XCTAssertEqual(after.deviceRegistryID, device.registryID)
        XCTAssertEqual(
            after.numericalProfile.rawValue,
            RuntimeNumericalProfile.scientific32.rawValue
        )
    }

    func testFullScientificCPUMetalDifferentialWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment[
            "NUMITISSUE_RUN_METAL_DIFFERENTIAL"
        ] == "1" else {
            throw XCTSkip(
                "Set NUMITISSUE_RUN_METAL_DIFFERENTIAL=1 for full phase-by-phase Apple GPU validation"
            )
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device is available")
        }
        let cpu = CPUReferenceTissueBackend(
            capabilities: ValidationFixtures.capabilities(
                name: "NumiTissue CPU Differential Reference"
            )
        )
        let metal = try MetalTissueBackend(
            capabilities: Self.capabilities(device: device),
            device: device,
            options: MetalExecutionOptions(
                privateHeapBytes: 128 * 1_024 * 1_024,
                stagingBytes: 8 * 1_024 * 1_024,
                enableCounterSampling: true,
                requestedNumericalProfile: .scientific32
            )
        )
        let runner = DifferentialTissueRunner(
            reference: DifferentialBackendParticipant(
                identifier: "cpu-scientific-reference",
                backend: cpu
            ),
            candidates: [
                DifferentialBackendParticipant(
                    identifier: "metal-scientific32",
                    backend: metal
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

    private static func capabilities(device: MTLDevice) -> TissueRuntimeCapabilities {
        TissueRuntimeCapabilities(
            backendName: "NumiTissue Metal Scientific Validation",
            gpuResident: true,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: true,
            supportsMetal4: device.supportsFamily(.apple7),
            recommendedWorkingSetBytes: UInt64(
                device.recommendedMaxWorkingSetSize
            ),
            maximumThreadgroupMemoryBytes: 32 * 1_024
        )
    }
}
#endif
