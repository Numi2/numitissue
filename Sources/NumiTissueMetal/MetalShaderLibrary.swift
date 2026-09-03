#if canImport(Metal)
import Foundation
import Metal

public enum MetalKernel: String, Sendable, CaseIterable {
    case resetTransientState = "nt_reset_transient_state"
    case materializeStateOverlays = "nt_materialize_state_overlays"
    case materializeParameterOverlays = "nt_materialize_parameter_overlays"
    case buildWorklists = "nt_build_worklists"
    case encodeIndirectDispatch = "nt_encode_indirect_dispatch"
    case ingestInputEvents = "nt_ingest_input_events"
    case deliverEvents = "nt_deliver_events"
    case decaySynapses = "nt_decay_synapses"
    case updateChannels = "nt_update_channels"
    case assembleCableSystem = "nt_assemble_cable_system"
    case eliminateCableLevels = "nt_eliminate_cable_levels"
    case solveCableRoots = "nt_solve_cable_roots"
    case backSubstituteCableLevels = "nt_back_substitute_cable_levels"
    case detectSpikes = "nt_detect_spikes"
    case routeSpikes = "nt_route_spikes"
    case updateFastFields = "nt_update_fast_fields"
    case updateMolecularDomains = "nt_update_molecular_domains"
    case updateGliaAndMetabolism = "nt_update_glia_metabolism"
    case updateMyelination = "nt_update_myelination"
    case updateMicroglialPruning = "nt_update_microglial_pruning"
    case applyPlasticity = "nt_apply_plasticity"
    case updateCellMechanics = "nt_update_cell_mechanics"
    case updateDevelopment = "nt_update_development"
    case updateStructuralPlasticity = "nt_update_structural_plasticity"
    case updateAdaptiveFidelity = "nt_update_adaptive_fidelity"
    case collectOutputs = "nt_collect_outputs"
    case validateState = "nt_validate_state"
}

public struct MetalPipelineKey: Hashable, Sendable {
    public var kernel: MetalKernel
    public var constantsHash: UInt64

    public init(kernel: MetalKernel, constantsHash: UInt64 = 0) {
        self.kernel = kernel
        self.constantsHash = constantsHash
    }
}

public final class MetalShaderLibrary: @unchecked Sendable {
    public let context: MetalDeviceContext
    public let library: MTLLibrary

    private let lock = NSLock()
    private var pipelines: [MetalPipelineKey: MTLComputePipelineState] = [:]

    public init(context: MetalDeviceContext, additionalSource: String? = nil) async throws {
        self.context = context
        let source = try Self.loadBundledShaderSource(additionalSource: additionalSource)
        let options = MTLCompileOptions()
        options.mathMode = .fast
        options.languageVersion = .version3_2
        options.preserveInvariance = true
        do {
            self.library = try await context.device.makeLibrary(source: source, options: options)
            self.library.label = "NumiTissue.RuntimeKernels"
        } catch {
            throw MetalRuntimeError.libraryCompilationFailed(String(describing: error))
        }
    }

    public func pipeline(
        _ kernel: MetalKernel,
        constants: MTLFunctionConstantValues? = nil,
        constantsHash: UInt64 = 0
    ) throws -> MTLComputePipelineState {
        let key = MetalPipelineKey(kernel: kernel, constantsHash: constantsHash)
        lock.lock()
        if let cached = pipelines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let function: MTLFunction
        if let constants {
            do {
                function = try library.makeFunction(name: kernel.rawValue, constantValues: constants)
            } catch {
                throw MetalRuntimeError.pipelineCreationFailed(function: kernel.rawValue, reason: String(describing: error))
            }
        } else {
            guard let value = library.makeFunction(name: kernel.rawValue) else {
                throw MetalRuntimeError.functionMissing(kernel.rawValue)
            }
            function = value
        }

        let descriptor = MTLComputePipelineDescriptor()
        descriptor.label = "NumiTissue.\(kernel.rawValue)"
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        descriptor.maxCallStackDepth = 1
        do {
            let pipeline = try context.device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
            lock.lock()
            pipelines[key] = pipeline
            lock.unlock()
            return pipeline
        } catch {
            throw MetalRuntimeError.pipelineCreationFailed(function: kernel.rawValue, reason: String(describing: error))
        }
    }

    public func prewarm(_ kernels: [MetalKernel] = MetalKernel.allCases) throws {
        for kernel in kernels { _ = try pipeline(kernel) }
    }

    private static func loadBundledShaderSource(additionalSource: String?) throws -> String {
        let fileNames = [
            "NumiTissueABI",
            "NumiTissueOverlays",
            "NumiTissueWorklists",
            "NumiTissueElectrophysiology",
            "NumiTissueEvents",
            "NumiTissueFields",
            "NumiTissueMolecular",
            "NumiTissueDevelopment",
            "NumiTissueValidation"
        ]
        var source = ""
        for name in fileNames {
            guard let url = Bundle.module.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
                    ?? Bundle.module.url(forResource: name, withExtension: "metal") else {
                throw MetalRuntimeError.libraryCompilationFailed("Missing bundled shader source \(name).metal")
            }
            source += try String(contentsOf: url, encoding: .utf8)
            source += "\n"
        }
        if let additionalSource {
            source += "\n"
            source += additionalSource
        }
        return source
    }
}

public extension MTLComputeCommandEncoder {
    func ntDispatch1D(count: Int, pipeline: MTLComputePipelineState) {
        guard count > 0 else { return }
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, max(pipeline.threadExecutionWidth, 64))
        setComputePipelineState(pipeline)
        dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

    func ntDispatchIndirect(
        buffer: MTLBuffer,
        offset: Int,
        threadsPerThreadgroup: MTLSize,
        pipeline: MTLComputePipelineState
    ) {
        setComputePipelineState(pipeline)
        dispatchThreadgroups(indirectBuffer: buffer, indirectBufferOffset: offset, threadsPerThreadgroup: threadsPerThreadgroup)
    }
}
#endif
