#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels

/// Immutable integer metadata is kept separate from overlayable FP32 tables. These buffers map
/// cell programs to regulatory, growth, fate and glial programs and map synapse/field prototypes
/// to their semantic kinds. They remain valid across all transaction-local parameter overlays.
public final class MetalBiologyMetadataBuffers: @unchecked Sendable {
    public let synapseTypeAndFlags: MTLBuffer
    public let fieldAddressing: MTLBuffer
    public let regulatoryStateAndMatrix: MTLBuffer
    public let regulatoryBiasAndTransition: MTLBuffer
    public let fateIdentity: MTLBuffer
    public let glialIdentity: MTLBuffer

    public let synapseParameterCount: Int
    public let fieldParameterCount: Int
    public let regulatoryProgramCount: Int
    public let fateTransitionCount: Int
    public let growthProgramCount: Int
    public let glialProgramCount: Int

    public init(context: MetalDeviceContext, model: CompiledTissueModel) async throws {
        synapseParameterCount = model.synapseParameters.count
        fieldParameterCount = model.fieldParameters.count
        regulatoryProgramCount = model.regulatoryPrograms.count
        fateTransitionCount = model.fateTransitions.count
        growthProgramCount = model.growthPrograms.count
        glialProgramCount = model.glialPrograms.count

        synapseTypeAndFlags = try context.makePrivateBuffer(
            length: max(1, model.synapseParameters.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.synapseTypeAndFlags"
        )
        fieldAddressing = try context.makePrivateBuffer(
            length: max(1, model.fieldParameters.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.fieldAddressing"
        )
        regulatoryStateAndMatrix = try context.makePrivateBuffer(
            length: max(1, model.regulatoryPrograms.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.regulatoryStateAndMatrix"
        )
        regulatoryBiasAndTransition = try context.makePrivateBuffer(
            length: max(1, model.regulatoryPrograms.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.regulatoryBiasAndTransition"
        )
        fateIdentity = try context.makePrivateBuffer(
            length: max(1, model.fateTransitions.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.fateIdentity"
        )
        glialIdentity = try context.makePrivateBuffer(
            length: max(1, model.glialPrograms.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.glialIdentity"
        )

        let command = try context.makeTransferCommandBuffer(label: "NumiTissue.biologyMetadataUpload")
        var retained: [MTLBuffer] = []
        try Self.stage(model.synapseParameters.map(\.typeAndFlags), to: synapseTypeAndFlags, context: context, command: command, retained: &retained, label: "synapseTypeAndFlags")
        try Self.stage(model.fieldParameters.map(\.addressing), to: fieldAddressing, context: context, command: command, retained: &retained, label: "fieldAddressing")
        try Self.stage(model.regulatoryPrograms.map(\.stateAndMatrixRange), to: regulatoryStateAndMatrix, context: context, command: command, retained: &retained, label: "regulatoryStateAndMatrix")
        try Self.stage(model.regulatoryPrograms.map(\.biasAndTransitionRange), to: regulatoryBiasAndTransition, context: context, command: command, retained: &retained, label: "regulatoryBiasAndTransition")
        try Self.stage(model.fateTransitions.map(\.identity), to: fateIdentity, context: context, command: command, retained: &retained, label: "fateIdentity")
        try Self.stage(model.glialPrograms.map(\.identity), to: glialIdentity, context: context, command: command, retained: &retained, label: "glialIdentity")
        try await context.awaitCompletion(command)
        _ = retained
    }

    public var all: [MTLBuffer] {
        [
            synapseTypeAndFlags,
            fieldAddressing,
            regulatoryStateAndMatrix,
            regulatoryBiasAndTransition,
            fateIdentity,
            glialIdentity
        ]
    }

    private static func stage<T>(
        _ values: [T],
        to destination: MTLBuffer,
        context: MetalDeviceContext,
        command: MTLCommandBuffer,
        retained: inout [MTLBuffer],
        label: String
    ) throws {
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("stage.\(label)")
        }
        defer { blit.endEncoding() }
        guard !values.isEmpty else {
            blit.fill(buffer: destination, range: 0..<destination.length, value: 0)
            return
        }
        let byteCount = values.count * MemoryLayout<T>.stride
        let staging = try context.makeSharedBuffer(
            length: byteCount,
            label: "NumiTissue.stage.\(label)",
            writeCombined: true
        )
        values.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                staging.contents().copyMemory(from: source, byteCount: bytes.count)
            }
        }
        blit.copy(from: staging, sourceOffset: 0, to: destination, destinationOffset: 0, size: byteCount)
        retained.append(staging)
    }
}
#endif
