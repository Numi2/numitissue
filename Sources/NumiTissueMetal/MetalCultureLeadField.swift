import Foundation
import NumiTissueIO
#if canImport(Metal)
@preconcurrency import Metal

/// Scientific32 observation operator, separate from the tissue integrator.
/// It encodes work into a caller-owned command buffer: no commit, wait or CPU readback.
/// Not a performance32 authorization and not an automatically enabled production kernel.
public final class MetalCultureLeadField {
    public let geometrySHA256: ScientificSHA256Digest
    public let sourceIDs: [UInt64]
    public let electrodeIDs: [UInt32]
    private let coefficients: any MTLBuffer
    private let pipeline: any MTLComputePipelineState
    private let device: any MTLDevice

    public init(device: any MTLDevice, geometrySHA256: ScientificSHA256Digest,
                sourceIDs: [UInt64], electrodeIDs: [UInt32], resistanceOhmsRowMajor: [Float],
                maximumCoefficientBytes: Int = 128 * 1024 * 1024) throws {
        let count = sourceIDs.count.multipliedReportingOverflow(by: electrodeIDs.count)
        guard device.hasUnifiedMemory, device.supportsFamily(.apple4) else {
            throw MetalCultureObservationError.unsupportedDevice
        }
        guard !sourceIDs.isEmpty, !electrodeIDs.isEmpty, !count.overflow,
              count.partialValue <= Int(UInt32.max), maximumCoefficientBytes > 0,
              count.partialValue <= maximumCoefficientBytes / MemoryLayout<Float>.stride,
              count.partialValue <= device.maxBufferLength / MemoryLayout<Float>.stride,
              Set(sourceIDs).count == sourceIDs.count, Set(electrodeIDs).count == electrodeIDs.count,
              resistanceOhmsRowMajor.count == count.partialValue,
              resistanceOhmsRowMajor.allSatisfy(\.isFinite) else {
            throw MetalCultureObservationError.invalidDimensions
        }
        self.device = device; self.geometrySHA256 = geometrySHA256
        self.sourceIDs = sourceIDs; self.electrodeIDs = electrodeIDs
        // Adjacent electrode lanes load adjacent coefficients at each source iteration.
        var packed = [Float](repeating: 0, count: count.partialValue)
        for source in sourceIDs.indices {
            for electrode in electrodeIDs.indices {
                packed[source * electrodeIDs.count + electrode] = resistanceOhmsRowMajor[electrode * sourceIDs.count + source]
            }
        }
        guard let buffer = packed.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: [.storageModeShared])
        }) else { throw MetalCultureObservationError.allocationFailed }
        coefficients = buffer
        coefficients.label = "Culture lead field (source-major ohms)"
        guard let url = Bundle.module.url(forResource: "CultureLeadField", withExtension: "metal", subdirectory: "Shaders")
                ?? Bundle.module.url(forResource: "CultureLeadField", withExtension: "metal") else {
            throw MetalCultureObservationError.missingShader
        }
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: options)
        guard let function = library.makeFunction(name: "culture_leadfield_scientific32") else {
            throw MetalCultureObservationError.missingShader
        }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// Currents are [frame,source] Float amperes; output is [frame,electrode] Float volts.
    /// Status is [frame,electrode] UInt32: 0 valid, bit 0 nonfinite input, bit 1 nonfinite result.
    /// Source order MUST be the same as the geometry operator. Inputs/outputs must not alias.
    /// Tracked resources and normal retained-reference command buffers are required.
    public func encode(currents: any MTLBuffer, output: any MTLBuffer, status: any MTLBuffer,
                       frameCount: Int, currentSourceIDs: [UInt64],
                       expectedGeometrySHA256: ScientificSHA256Digest,
                       into commandBuffer: any MTLCommandBuffer) throws {
        guard frameCount > 0, frameCount <= 65_536, currentSourceIDs == sourceIDs,
              expectedGeometrySHA256 == geometrySHA256 else { throw MetalCultureObservationError.invalidDimensions }
        let inputCount = frameCount.multipliedReportingOverflow(by: sourceIDs.count)
        let outputCount = frameCount.multipliedReportingOverflow(by: electrodeIDs.count)
        guard !inputCount.overflow, !outputCount.overflow,
              inputCount.partialValue <= Int(UInt32.max), outputCount.partialValue <= Int(UInt32.max),
              inputCount.partialValue <= currents.length / MemoryLayout<Float>.stride,
              outputCount.partialValue <= output.length / MemoryLayout<Float>.stride,
              outputCount.partialValue <= status.length / MemoryLayout<UInt32>.stride,
              commandBuffer.commandQueue.device.registryID == device.registryID,
              currents.device.registryID == device.registryID, output.device.registryID == device.registryID,
              status.device.registryID == device.registryID,
              currents.hazardTrackingMode == .tracked, output.hazardTrackingMode == .tracked,
              status.hazardTrackingMode == .tracked,
              (currents as AnyObject) !== (output as AnyObject),
              (currents as AnyObject) !== (status as AnyObject),
              (output as AnyObject) !== (status as AnyObject),
              commandBuffer.retainedReferences else { throw MetalCultureObservationError.invalidBuffers }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalCultureObservationError.encoderUnavailable
        }
        encoder.label = "Culture lead-field projection scientific32"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(coefficients, offset: 0, index: 0)
        encoder.setBuffer(currents, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBuffer(status, offset: 0, index: 3)
        var dimensions = SIMD4<UInt32>(UInt32(sourceIDs.count), UInt32(electrodeIDs.count), UInt32(frameCount), 0)
        encoder.setBytes(&dimensions, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
        let width = min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: electrodeIDs.count, height: frameCount, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
    }
}

public enum MetalCultureObservationError: Error, Sendable {
    case unsupportedDevice, invalidDimensions, allocationFailed, missingShader, invalidBuffers, encoderUnavailable
}
#endif
