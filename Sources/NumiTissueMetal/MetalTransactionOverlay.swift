#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

@frozen
public struct MetalOverlayGroup: Sendable {
    public var addressing: SIMD4<UInt32>
    public var metadata: SIMD4<UInt32>

    public init(_ group: RuntimeOverlayGroup, scalarStride: UInt32, scalarCount: UInt32) {
        addressing = SIMD4(
            UInt32(group.key.domain.rawValue),
            UInt32(group.key.component),
            group.recordRange.lowerBound,
            group.recordRange.count
        )
        metadata = SIMD4(
            UInt32(truncatingIfNeeded: group.key.pathHash),
            UInt32(truncatingIfNeeded: group.key.pathHash >> 32),
            scalarStride,
            scalarCount
        )
    }
}

@frozen
public struct MetalOverlayRecord: Sendable {
    public var addressing: SIMD4<UInt32>
    public var values: SIMD4<Float>
    public var metadata: SIMD4<UInt32>

    public init(_ record: RuntimeOverlayRecord) {
        addressing = SIMD4(
            record.lowerBound,
            record.count,
            Self.operationCode(record.operation),
            UInt32(record.flags)
        )
        values = SIMD4(record.value, record.minimum, record.maximum, 0)
        metadata = SIMD4(
            record.sequence,
            UInt32(truncatingIfNeeded: record.sourceHash),
            UInt32(truncatingIfNeeded: record.sourceHash >> 32),
            0
        )
    }

    private static func operationCode(_ operation: TissueMutationOperation) -> UInt32 {
        switch operation {
        case .set: return 0
        case .add: return 1
        case .multiply: return 2
        case .clampMaximum: return 3
        case .clampMinimum: return 4
        }
    }
}

@frozen
public struct MetalOverlayMaterializationParameters: Sendable {
    public var counts: SIMD4<UInt32>
    public var transaction: SIMD4<UInt32>

    public init(overlay: CompiledTransactionOverlay, transactionID: UInt64) {
        counts = SIMD4(
            UInt32(clamping: overlay.groups.count),
            UInt32(clamping: overlay.records.count),
            UInt32(clamping: overlay.stateGroups.count),
            UInt32(clamping: overlay.parameterGroups.count)
        )
        transaction = SIMD4(
            UInt32(truncatingIfNeeded: transactionID),
            UInt32(truncatingIfNeeded: transactionID >> 32),
            UInt32(truncatingIfNeeded: overlay.digest),
            UInt32(truncatingIfNeeded: overlay.digest >> 32)
        )
    }
}

/// Shared upload buffers are deliberately transaction-scoped. They are retained by the backend
/// until command completion and can then be discarded without any cleanup or rollback work.
public final class MetalTransactionOverlayBuffers: @unchecked Sendable {
    public let overlay: CompiledTransactionOverlay
    public let groups: MTLBuffer
    public let records: MTLBuffer
    public let parameters: MTLBuffer

    public init(
        context: MetalDeviceContext,
        overlay: CompiledTransactionOverlay,
        model: MetalModelBuffers,
        state: TissueRuntimeState,
        transactionID: UInt64
    ) throws {
        try Self.validateLayouts()
        self.overlay = overlay
        let metalGroups = overlay.groups.map { group -> MetalOverlayGroup in
            let domain = group.key.domain
            if let table = model.table(for: domain) {
                return MetalOverlayGroup(
                    group,
                    scalarStride: UInt32(clamping: table.scalarStride),
                    scalarCount: UInt32(clamping: table.scalarCount)
                )
            }
            return MetalOverlayGroup(
                group,
                scalarStride: Self.stateStride(domain),
                scalarCount: Self.stateCount(domain, state: state)
            )
        }
        let metalRecords = overlay.records.map(MetalOverlayRecord.init)
        groups = try Self.makeShared(
            context: context,
            values: metalGroups,
            label: "NumiTissue.overlay.groups"
        )
        records = try Self.makeShared(
            context: context,
            values: metalRecords,
            label: "NumiTissue.overlay.records"
        )
        parameters = try context.makeSharedBuffer(
            length: MemoryLayout<MetalOverlayMaterializationParameters>.stride,
            label: "NumiTissue.overlay.parameters",
            writeCombined: true
        )
        var value = MetalOverlayMaterializationParameters(
            overlay: overlay,
            transactionID: transactionID
        )
        withUnsafeBytes(of: &value) { bytes in
            if let source = bytes.baseAddress {
                parameters.contents().copyMemory(from: source, byteCount: bytes.count)
            }
        }
    }

    public func encodeMaterialization(
        command: MTLCommandBuffer,
        library: MetalShaderLibrary,
        argumentTable: MetalArgumentTable,
        state: MetalStateBufferSet,
        transient: MetalTransientBuffers,
        model: MetalModelBuffers
    ) throws {
        guard !overlay.records.isEmpty else { return }
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("transactionOverlay")
        }
        encoder.label = "NumiTissue.transactionOverlay"
        argumentTable.useResources(on: encoder, state: state, transient: transient)
        encoder.useResources([groups, records, parameters], usage: .read)
        encoder.useResources(model.allParameterBuffers, usage: [.read, .write])
        encoder.setBuffer(argumentTable.buffer, offset: 0, index: 0)
        encoder.setBuffer(groups, offset: 0, index: 1)
        encoder.setBuffer(records, offset: 0, index: 2)
        encoder.setBuffer(parameters, offset: 0, index: 3)

        let statePipeline = try library.pipeline(.materializeStateOverlays)
        encoder.setComputePipelineState(statePipeline)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )

        if !overlay.parameterGroups.isEmpty {
            encoder.setBuffer(model.table(for: .channelParameter)?.effective, offset: 0, index: 4)
            encoder.setBuffer(model.table(for: .mechanismSetParameter)?.effective, offset: 0, index: 5)
            encoder.setBuffer(model.table(for: .synapseParameter)?.effective, offset: 0, index: 6)
            encoder.setBuffer(model.table(for: .fieldParameter)?.effective, offset: 0, index: 7)
            encoder.setBuffer(model.table(for: .cellProgramParameter)?.effective, offset: 0, index: 8)
            encoder.setBuffer(model.table(for: .regulatoryProgramParameter)?.effective, offset: 0, index: 9)
            encoder.setBuffer(model.table(for: .fateTransitionParameter)?.effective, offset: 0, index: 10)
            encoder.setBuffer(model.table(for: .growthProgramParameter)?.effective, offset: 0, index: 11)
            encoder.setBuffer(model.table(for: .glialProgramParameter)?.effective, offset: 0, index: 12)
            encoder.setBuffer(model.table(for: .molecularReactionParameter)?.effective, offset: 0, index: 13)
            let parameterPipeline = try library.pipeline(.materializeParameterOverlays)
            encoder.setComputePipelineState(parameterPipeline)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
        }
        encoder.endEncoding()
    }

    private static func makeShared<T>(
        context: MetalDeviceContext,
        values: [T],
        label: String
    ) throws -> MTLBuffer {
        let length = max(1, values.count) * MemoryLayout<T>.stride
        let buffer = try context.makeSharedBuffer(length: length, label: label, writeCombined: true)
        if !values.isEmpty {
            values.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress {
                    buffer.contents().copyMemory(from: source, byteCount: bytes.count)
                }
            }
        } else {
            memset(buffer.contents(), 0, buffer.length)
        }
        return buffer
    }

    private static func stateStride(_ domain: RuntimeOverlayDomain) -> UInt32 {
        switch domain {
        case .cellState: return 1
        case .segmentState: return 1
        case .compartmentState: return 1
        case .synapseState: return 1
        case .fieldState: return 1
        case .mechanismState, .molecularSpecies, .regulatoryState: return 1
        default: return 0
        }
    }

    private static func stateCount(_ domain: RuntimeOverlayDomain, state: TissueRuntimeState) -> UInt32 {
        switch domain {
        case .cellState: return UInt32(clamping: state.cells.count)
        case .segmentState: return UInt32(clamping: state.segments.count)
        case .compartmentState: return UInt32(clamping: state.compartments.count)
        case .synapseState: return UInt32(clamping: state.synapses.count)
        case .fieldState: return UInt32(clamping: state.fields.count)
        case .mechanismState: return UInt32(clamping: state.mechanismState.count)
        case .molecularSpecies: return UInt32(clamping: state.molecularSpecies.count)
        case .regulatoryState: return UInt32(clamping: state.regulatoryState.count)
        default: return 0
        }
    }

    private static func validateLayouts() throws {
        guard MemoryLayout<MetalOverlayGroup>.stride == 32 else {
            throw MetalRuntimeError.incompatibleGPU("MetalOverlayGroup ABI must be 32 bytes")
        }
        guard MemoryLayout<MetalOverlayRecord>.stride == 48 else {
            throw MetalRuntimeError.incompatibleGPU("MetalOverlayRecord ABI must be 48 bytes")
        }
        guard MemoryLayout<MetalOverlayMaterializationParameters>.stride == 32 else {
            throw MetalRuntimeError.incompatibleGPU("MetalOverlayMaterializationParameters ABI must be 32 bytes")
        }
    }
}
#endif
