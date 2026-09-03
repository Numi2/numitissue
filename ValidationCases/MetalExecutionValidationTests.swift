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
}
#endif
