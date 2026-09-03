#if canImport(Metal)
import Foundation
import Metal
import NumiTissueRuntime

@frozen
struct MetalDigestCounts: Sendable {
    var regulatoryStateCount: UInt32
    var mechanismStateCount: UInt32
    var reserved0: UInt32
    var reserved1: UInt32

    init(state: TissueRuntimeState) {
        regulatoryStateCount = UInt32(clamping: state.regulatoryState.count)
        mechanismStateCount = UInt32(clamping: state.mechanismState.count)
        reserved0 = 0
        reserved1 = 0
    }
}

/// Small persistent buffers for diagnostic state hashing. Ten GPU threads each walk one canonical
/// state pool and return one four-lane digest. The CPU reads 320 bytes instead of the full arena.
final class MetalPhaseDigestBuffers: @unchecked Sendable {
    static let stateDomainCount = 10

    let context: MetalDeviceContext
    let output: MTLBuffer
    let counts: MTLBuffer

    init(context: MetalDeviceContext) throws {
        precondition(MemoryLayout<MetalDigestCounts>.stride == 16)
        precondition(MemoryLayout<SIMD4<UInt64>>.stride == 32)
        self.context = context
        output = try context.makeSharedBuffer(
            length: Self.stateDomainCount * MemoryLayout<SIMD4<UInt64>>.stride,
            label: "NumiTissue.differential.phaseDigests"
        )
        counts = try context.makeSharedBuffer(
            length: MemoryLayout<MetalDigestCounts>.stride,
            label: "NumiTissue.differential.digestCounts",
            writeCombined: true
        )
    }

    func encode(
        command: MTLCommandBuffer,
        library: MetalShaderLibrary,
        argumentTable: MetalArgumentTable,
        state: MetalStateBufferSet,
        transient: MetalTransientBuffers,
        stateTemplate: TissueRuntimeState
    ) throws {
        memset(output.contents(), 0, output.length)
        var value = MetalDigestCounts(state: stateTemplate)
        withUnsafeBytes(of: &value) { bytes in
            guard let base = bytes.baseAddress else { return }
            counts.contents().copyMemory(
                from: base,
                byteCount: bytes.count
            )
            context.telemetry.recordUpload(bytes: bytes.count)
        }

        guard let encoder = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed(
                MetalKernel.digestShadowState.rawValue
            )
        }
        encoder.label = "NumiTissue.\(MetalKernel.digestShadowState.rawValue)"
        encoder.setBuffer(argumentTable.buffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(counts, offset: 0, index: 2)
        encoder.useResource(output, usage: .write)
        encoder.useResource(counts, usage: .read)
        argumentTable.useResources(
            on: encoder,
            state: state,
            transient: transient
        )
        let pipeline = try library.pipeline(.digestShadowState)
        encoder.ntDispatch1D(
            count: Self.stateDomainCount,
            pipeline: pipeline
        )
        encoder.endEncoding()
        context.telemetry.recordComputeEncoder()
    }

    func read(
        metadata: RuntimeComparisonDigest,
        pendingEvents: RuntimeComparisonDigest
    ) -> RuntimePoolDigests {
        context.telemetry.recordReadback(bytes: output.length)
        let pointer = output.contents().bindMemory(
            to: SIMD4<UInt64>.self,
            capacity: Self.stateDomainCount
        )
        func digest(_ index: Int) -> RuntimeComparisonDigest {
            let value = pointer[index]
            return RuntimeComparisonDigest(
                lane0: value.x,
                lane1: value.y,
                lane2: value.z,
                lane3: value.w
            )
        }
        return RuntimePoolDigests(
            metadata: metadata,
            tiles: digest(0),
            cells: digest(1),
            regulatoryState: digest(2),
            segments: digest(3),
            compartments: digest(4),
            mechanismState: digest(5),
            synapses: digest(6),
            fields: digest(7),
            microdomains: digest(8),
            molecularSpecies: digest(9),
            pendingEvents: pendingEvents
        )
    }
}
#endif
