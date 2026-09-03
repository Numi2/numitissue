#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels
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

/// One immutable compiled table and its transaction-local effective copy. Values are flattened
/// as tightly packed FP32 scalars so a single generic overlay kernel can materialize every model
/// domain without mutating the authoritative compiled model.
public final class MetalFloatParameterTable: @unchecked Sendable {
    public let domain: RuntimeOverlayDomain
    public let scalarStride: Int
    public let elementCount: Int
    public let baseline: MTLBuffer
    public let effective: MTLBuffer

    init(
        domain: RuntimeOverlayDomain,
        scalarStride: Int,
        values: [Float],
        context: MetalDeviceContext,
        command: MTLCommandBuffer,
        retained: inout [MTLBuffer]
    ) throws {
        precondition(scalarStride > 0)
        precondition(values.count.isMultiple(of: scalarStride))
        self.domain = domain
        self.scalarStride = scalarStride
        self.elementCount = values.count / scalarStride
        let length = max(1, values.count) * MemoryLayout<Float>.stride
        baseline = try context.makePrivateBuffer(length: length, label: "NumiTissue.model.\(domain).baseline")
        effective = try context.makePrivateBuffer(length: length, label: "NumiTissue.model.\(domain).effective")
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("parameterTable.\(domain)")
        }
        if !values.isEmpty {
            let staging = try context.makeSharedBuffer(
                length: values.count * MemoryLayout<Float>.stride,
                label: "NumiTissue.stage.\(domain)",
                writeCombined: true
            )
            values.withUnsafeBytes { bytes in
                if let source = bytes.baseAddress {
                    staging.contents().copyMemory(from: source, byteCount: bytes.count)
                }
            }
            let byteCount = values.count * MemoryLayout<Float>.stride
            blit.copy(from: staging, sourceOffset: 0, to: baseline, destinationOffset: 0, size: byteCount)
            blit.copy(from: staging, sourceOffset: 0, to: effective, destinationOffset: 0, size: byteCount)
            retained.append(staging)
        } else {
            blit.fill(buffer: baseline, range: 0..<baseline.length, value: 0)
            blit.fill(buffer: effective, range: 0..<effective.length, value: 0)
        }
        blit.endEncoding()
    }

    public var scalarCount: Int { elementCount * scalarStride }

    public func encodeReset(on blit: MTLBlitCommandEncoder) {
        blit.copy(
            from: baseline,
            sourceOffset: 0,
            to: effective,
            destinationOffset: 0,
            size: min(baseline.length, effective.length)
        )
    }
}

public final class MetalModelBuffers: @unchecked Sendable {
    public let molecularNetworks: MTLBuffer
    public let molecularReactionsBaseline: MTLBuffer
    /// Effective reaction topology and rates. The topology is copied unchanged each transaction;
    /// rate fields may then be replaced from the molecular-reaction scalar table.
    public let molecularReactions: MTLBuffer
    public let channelMetadata: MTLBuffer
    public let mechanismSetMetadata: MTLBuffer
    public let cellProgramIdentity: MTLBuffer
    public let cellProgramMetadata: MTLBuffer
    public let parameterTables: [RuntimeOverlayDomain: MetalFloatParameterTable]
    public let networkCount: Int
    public let reactionCount: Int
    public let channelCount: Int
    public let mechanismSetCount: Int
    public let cellProgramCount: Int

    public init(
        context: MetalDeviceContext,
        model: CompiledTissueModel,
        program: MetalMolecularProgram
    ) async throws {
        networkCount = program.networks.count
        reactionCount = program.reactions.count
        channelCount = model.channelParameters.count
        mechanismSetCount = model.mechanismSets.count
        cellProgramCount = model.cellPrograms.count

        molecularNetworks = try context.makePrivateBuffer(
            length: max(1, program.networks.count) * MemoryLayout<MetalMolecularNetworkABI>.stride,
            label: "NumiTissue.model.molecularNetworks"
        )
        molecularReactionsBaseline = try context.makePrivateBuffer(
            length: max(1, program.reactions.count) * MemoryLayout<MetalMolecularReactionABI>.stride,
            label: "NumiTissue.model.molecularReactions.baseline"
        )
        molecularReactions = try context.makePrivateBuffer(
            length: max(1, program.reactions.count) * MemoryLayout<MetalMolecularReactionABI>.stride,
            label: "NumiTissue.model.molecularReactions.effective"
        )
        channelMetadata = try context.makePrivateBuffer(
            length: max(1, model.channelParameters.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.channelMetadata"
        )
        mechanismSetMetadata = try context.makePrivateBuffer(
            length: max(1, model.mechanismSets.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.mechanismSetMetadata"
        )
        cellProgramIdentity = try context.makePrivateBuffer(
            length: max(1, model.cellPrograms.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.cellProgramIdentity"
        )
        cellProgramMetadata = try context.makePrivateBuffer(
            length: max(1, model.cellPrograms.count) * MemoryLayout<UInt4>.stride,
            label: "NumiTissue.model.cellProgramMetadata"
        )

        let command = try context.makeTransferCommandBuffer(label: "NumiTissue.modelUpload")
        var retained: [MTLBuffer] = []
        try Self.stage(program.networks, to: molecularNetworks, context: context, command: command, retained: &retained, label: "molecularNetworks")
        try Self.stage(program.reactions, to: molecularReactionsBaseline, context: context, command: command, retained: &retained, label: "molecularReactions.baseline")
        try Self.stage(program.reactions, to: molecularReactions, context: context, command: command, retained: &retained, label: "molecularReactions.effective")
        try Self.stage(model.channelParameters.map(\.kindAndPowers), to: channelMetadata, context: context, command: command, retained: &retained, label: "channelMetadata")
        try Self.stage(model.mechanismSets.map(\.channelRange), to: mechanismSetMetadata, context: context, command: command, retained: &retained, label: "mechanismSetMetadata")
        try Self.stage(model.cellPrograms.map(\.identity), to: cellProgramIdentity, context: context, command: command, retained: &retained, label: "cellProgramIdentity")
        try Self.stage(model.cellPrograms.map(\.programIndices), to: cellProgramMetadata, context: context, command: command, retained: &retained, label: "cellProgramMetadata")

        var tables: [RuntimeOverlayDomain: MetalFloatParameterTable] = [:]
        func add(_ domain: RuntimeOverlayDomain, stride: Int, values: [Float]) throws {
            tables[domain] = try MetalFloatParameterTable(
                domain: domain,
                scalarStride: stride,
                values: values,
                context: context,
                command: command,
                retained: &retained
            )
        }
        try add(.channelParameter, stride: 12, values: Self.flattenChannels(model.channelParameters))
        try add(.mechanismSetParameter, stride: 4, values: model.mechanismSets.flatMap { Self.floatValues($0.thermal) })
        try add(.synapseParameter, stride: 16, values: model.synapseParameters.flatMap {
            Self.floatValues($0.kinetics) + Self.floatValues($0.shortTerm) + Self.floatValues($0.stdp0) + Self.floatValues($0.stdp1)
        })
        try add(.fieldParameter, stride: 8, values: model.fieldParameters.flatMap {
            Self.floatValues($0.dynamics) + Self.floatValues($0.bounds)
        })
        try add(.cellProgramParameter, stride: 8, values: model.cellPrograms.flatMap {
            Self.floatValues($0.mechanics) + Self.floatValues($0.membrane)
        })
        try add(.regulatoryProgramParameter, stride: 12, values: model.regulatoryPrograms.flatMap {
            Self.floatValues($0.timeConstants0) + Self.floatValues($0.timeConstants1) + Self.floatValues($0.hazards)
        })
        try add(.fateTransitionParameter, stride: 12, values: model.fateTransitions.flatMap {
            Self.floatValues($0.hazard) + Self.floatValues($0.regulatoryWeights) + Self.floatValues($0.fieldWeights)
        })
        try add(.growthProgramParameter, stride: 12, values: model.growthPrograms.flatMap {
            Self.floatValues($0.rates) + Self.floatValues($0.guidance0) + Self.floatValues($0.guidance1)
        })
        try add(.glialProgramParameter, stride: 16, values: model.glialPrograms.flatMap {
            Self.floatValues($0.uptakeRates) + Self.floatValues($0.releaseRates) + Self.floatValues($0.activationThresholds) + Self.floatValues($0.spatial)
        })
        try add(.molecularReactionParameter, stride: 2, values: program.reactions.flatMap {
            [$0.rateConstant, $0.reverseRateConstant]
        })
        parameterTables = tables

        try await context.awaitCompletion(command)
        _ = retained
    }

    public func table(for domain: RuntimeOverlayDomain) -> MetalFloatParameterTable? {
        parameterTables[domain]
    }

    public var allParameterBuffers: [MTLBuffer] {
        parameterTables.values.flatMap { [$0.baseline, $0.effective] }
    }

    public func encodeResetEffective(on command: MTLCommandBuffer) throws {
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("resetEffectiveParameters")
        }
        for domain in parameterTables.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            parameterTables[domain]?.encodeReset(on: blit)
        }
        blit.copy(
            from: molecularReactionsBaseline,
            sourceOffset: 0,
            to: molecularReactions,
            destinationOffset: 0,
            size: min(molecularReactionsBaseline.length, molecularReactions.length)
        )
        blit.endEncoding()
    }

    private static func flattenChannels(_ parameters: [GPUChannelParameter]) -> [Float] {
        parameters.flatMap {
            Self.floatValues($0.conductance) +
            Self.floatValues($0.activation) +
            Self.floatValues($0.inactivation)
        }
    }

    private static func floatValues(_ vector: Float4) -> [Float] {
        [vector.x, vector.y, vector.z, vector.w]
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

/// Encodes all frequently used state buffers once. Immutable and effective model parameter
/// tables are supplied explicitly to the kernels that consume them, keeping the core argument
/// buffer stable while still allowing transactional parameter materialization.
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
