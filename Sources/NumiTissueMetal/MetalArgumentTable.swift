#if canImport(Metal)
import Foundation
import Metal
import NumiTissueRuntime

@frozen
public struct MetalMolecularNetworkABI: Sendable {
    public var reactionOffset: UInt32
    public var reactionCount: UInt32
    public var speciesCount: UInt32
    public var flags: UInt32

    public init(reactionOffset: UInt32, reactionCount: UInt32, speciesCount: UInt32, flags: UInt32 = 0) {
        self.reactionOffset = reactionOffset
        self.reactionCount = reactionCount
        self.speciesCount = speciesCount
        self.flags = flags
    }
}

@frozen
public struct MetalMolecularReactionABI: Sendable {
    public var reactants: SIMD4<UInt32>
    public var products: SIMD4<UInt32>
    public var reactantStoichiometry: SIMD4<Int8>
    public var productStoichiometry: SIMD4<Int8>
    public var rateConstant: Float
    public var reverseRateConstant: Float
    public var order: UInt32
    public var flags: UInt32

    public init(
        reactants: SIMD4<UInt32>,
        products: SIMD4<UInt32>,
        reactantStoichiometry: SIMD4<Int8>,
        productStoichiometry: SIMD4<Int8>,
        rateConstant: Float,
        reverseRateConstant: Float = 0,
        order: UInt32,
        flags: UInt32 = 0
    ) {
        self.reactants = reactants
        self.products = products
        self.reactantStoichiometry = reactantStoichiometry
        self.productStoichiometry = productStoichiometry
        self.rateConstant = rateConstant
        self.reverseRateConstant = reverseRateConstant
        self.order = order
        self.flags = flags
    }
}

public struct MetalMolecularProgram: Sendable {
    public var networks: [MetalMolecularNetworkABI]
    public var reactions: [MetalMolecularReactionABI]

    public init(networks: [MetalMolecularNetworkABI] = [], reactions: [MetalMolecularReactionABI] = []) {
        self.networks = networks
        self.reactions = reactions
    }
}

public final class MetalModelBuffers: @unchecked Sendable {
    public let molecularNetworks: MTLBuffer
    public let molecularReactions: MTLBuffer
    public let networkCount: Int
    public let reactionCount: Int

    public init(context: MetalDeviceContext, program: MetalMolecularProgram) async throws {
        networkCount = program.networks.count
        reactionCount = program.reactions.count
        molecularNetworks = try context.makePrivateBuffer(
            length: max(1, program.networks.count) * MemoryLayout<MetalMolecularNetworkABI>.stride,
            label: "NumiTissue.model.molecularNetworks"
        )
        molecularReactions = try context.makePrivateBuffer(
            length: max(1, program.reactions.count) * MemoryLayout<MetalMolecularReactionABI>.stride,
            label: "NumiTissue.model.molecularReactions"
        )

        let command = try context.makeTransferCommandBuffer(label: "NumiTissue.modelUpload")
        guard let blit = command.makeBlitCommandEncoder() else { throw MetalRuntimeError.encoderCreationFailed("modelUpload") }
        var retained: [MTLBuffer] = []
        try Self.stage(program.networks, to: molecularNetworks, context: context, blit: blit, retained: &retained, label: "molecularNetworks")
        try Self.stage(program.reactions, to: molecularReactions, context: context, blit: blit, retained: &retained, label: "molecularReactions")
        blit.endEncoding()
        try await context.awaitCompletion(command)
        _ = retained
    }

    private static func stage<T>(
        _ values: [T],
        to destination: MTLBuffer,
        context: MetalDeviceContext,
        blit: MTLBlitCommandEncoder,
        retained: inout [MTLBuffer],
        label: String
    ) throws {
        guard !values.isEmpty else { return }
        let length = values.count * MemoryLayout<T>.stride
        let staging = try context.makeSharedBuffer(length: length, label: "NumiTissue.stage.\(label)", writeCombined: true)
        values.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            staging.contents().copyMemory(from: source, byteCount: bytes.count)
        }
        blit.copy(from: staging, sourceOffset: 0, to: destination, destinationOffset: 0, size: length)
        retained.append(staging)
    }
}

/// Encodes all frequently used buffers once. Each compute phase binds one argument buffer instead
/// of rebinding dozens of resources, which keeps CPU encoding overhead independent of tile count.
public final class MetalArgumentTable: @unchecked Sendable {
    public let buffer: MTLBuffer
    public let encoder: MTLArgumentEncoder

    public init(
        context: MetalDeviceContext,
        shaderLibrary: MetalShaderLibrary,
        state: MetalStateBufferSet,
        transient: MetalTransientBuffers,
        label: String
    ) throws {
        guard let function = shaderLibrary.library.makeFunction(name: MetalKernel.buildWorklists.rawValue) else {
            throw MetalRuntimeError.functionMissing(MetalKernel.buildWorklists.rawValue)
        }
        encoder = function.makeArgumentEncoder(bufferIndex: 0)
        guard let buffer = context.device.makeBuffer(length: encoder.encodedLength, options: .storageModeShared) else {
            throw MetalRuntimeError.bufferAllocationFailed(label: label, bytes: encoder.encodedLength)
        }
        self.buffer = buffer
        buffer.label = label
        encoder.label = "\(label).encoder"
        encoder.setArgumentBuffer(buffer, offset: 0)
        encoder.setBuffer(transient.header, offset: 0, index: 0)
        encoder.setBuffer(state.tiles, offset: 0, index: 1)
        encoder.setBuffer(state.cells, offset: 0, index: 2)
        encoder.setBuffer(state.regulatoryState, offset: 0, index: 3)
        encoder.setBuffer(state.segments, offset: 0, index: 4)
        encoder.setBuffer(state.compartments, offset: 0, index: 5)
        encoder.setBuffer(state.mechanismState, offset: 0, index: 6)
        encoder.setBuffer(state.synapses, offset: 0, index: 7)
        encoder.setBuffer(state.fields, offset: 0, index: 8)
        encoder.setBuffer(state.microdomains, offset: 0, index: 9)
        encoder.setBuffer(state.molecularSpecies, offset: 0, index: 10)
        encoder.setBuffer(transient.inputEvents, offset: 0, index: 11)
        encoder.setBuffer(transient.stimuli, offset: 0, index: 12)
        encoder.setBuffer(transient.localEvents, offset: 0, index: 13)
        encoder.setBuffer(transient.outgoingEvents, offset: 0, index: 14)
        encoder.setBuffer(transient.outputEvents, offset: 0, index: 15)
        encoder.setBuffer(transient.eventBucketCounts, offset: 0, index: 16)
        encoder.setBuffer(transient.worklistCounts, offset: 0, index: 17)
        encoder.setBuffer(transient.electricalWorklist, offset: 0, index: 18)
        encoder.setBuffer(transient.fieldWorklist, offset: 0, index: 19)
        encoder.setBuffer(transient.molecularWorklist, offset: 0, index: 20)
        encoder.setBuffer(transient.mechanicsWorklist, offset: 0, index: 21)
        encoder.setBuffer(transient.developmentWorklist, offset: 0, index: 22)
        encoder.setBuffer(transient.fidelityWorklist, offset: 0, index: 23)
        encoder.setBuffer(transient.validationRecords, offset: 0, index: 24)
        encoder.setBuffer(transient.counters, offset: 0, index: 25)
        encoder.setBuffer(transient.outputScalars, offset: 0, index: 26)
        encoder.setBuffer(transient.indirectDispatch, offset: 0, index: 27)
    }

    public func useResources(on encoder: MTLComputeCommandEncoder, state: MetalStateBufferSet, transient: MetalTransientBuffers) {
        encoder.useResources(state.all, usage: [.read, .write])
        encoder.useResources([
            transient.header, transient.inputEvents, transient.stimuli, transient.localEvents,
            transient.outgoingEvents, transient.outputEvents, transient.eventBucketCounts,
            transient.worklistCounts, transient.electricalWorklist, transient.fieldWorklist,
            transient.molecularWorklist, transient.mechanicsWorklist, transient.developmentWorklist,
            transient.fidelityWorklist, transient.validationRecords, transient.counters,
            transient.outputScalars, transient.indirectDispatch
        ], usage: [.read, .write])
    }
}
#endif
