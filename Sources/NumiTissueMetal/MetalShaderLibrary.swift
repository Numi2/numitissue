#if canImport(Metal)
import Foundation
import Metal
import NumiTissueRuntime

public enum MetalKernel: String, Sendable, CaseIterable {
    case resetTransientState = "nt_reset_transient_state"
    case materializeStateOverlays = "nt_materialize_state_overlays"
    case materializeParameterOverlays = "nt_materialize_parameter_overlays"
    case buildWorklists = "nt_build_worklists"
    case encodeIndirectDispatch = "nt_encode_indirect_dispatch"
    case ingestInputEvents = "nt_ingest_input_events"
    case sortEventBucket = "nt_sort_event_bucket"
    case deliverEvents = "nt_deliver_events"
    case clearEventBucket = "nt_clear_event_bucket"
    case decaySynapses = "nt_decay_synapses"
    case updateChannels = "nt_update_channels"
    case assembleCableSystem = "nt_assemble_cable_system"
    case eliminateCableLevels = "nt_eliminate_cable_levels"
    case solveCableRoots = "nt_solve_cable_roots"
    case backSubstituteCableLevels = "nt_back_substitute_cable_levels"
    case detectSpikes = "nt_detect_spikes"
    case routeSpikes = "nt_route_spikes"
    case clearSpikeFlags = "nt_clear_spike_flags"
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
    case digestShadowState = "nt_digest_shadow_state"
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
    public let numericalProfile: RuntimeNumericalProfile
    public let pipelineArchive: MetalPipelineArchiveStore?

    private let lock = NSLock()
    private var pipelines: [MetalPipelineKey: MTLComputePipelineState] = [:]

    public init(
        context: MetalDeviceContext,
        additionalSource: String? = nil,
        pipelineArchiveURL: URL? = nil
    ) async throws {
        self.context = context
        numericalProfile = context.options.effectiveNumericalProfile
        if let pipelineArchiveURL {
            pipelineArchive = try MetalPipelineArchiveStore(
                device: context.device,
                url: pipelineArchiveURL
            )
        } else {
            pipelineArchive = nil
        }
        let source = try Self.loadBundledShaderSource(
            additionalSource: additionalSource
        )
        let options = MTLCompileOptions()
        // Scientific and balanced profiles preserve CPU/Metal agreement; the explicitly opted-in
        // performance profile is the only path that enables Metal fast math.
        options.mathMode = numericalProfile == .performance32 ? .fast : .safe
        options.languageVersion = .version3_2
        options.preserveInvariance = true
        do {
            self.library = try await context.device.makeLibrary(
                source: source,
                options: options
            )
            self.library.label =
                "NumiTissue.RuntimeKernels.\(numericalProfile.rawValue)"
        } catch {
            throw MetalRuntimeError.libraryCompilationFailed(
                String(describing: error)
            )
        }
    }

    public func pipeline(
        _ kernel: MetalKernel,
        constants: MTLFunctionConstantValues? = nil,
        constantsHash: UInt64 = 0
    ) throws -> MTLComputePipelineState {
        let key = MetalPipelineKey(
            kernel: kernel,
            constantsHash: constantsHash
        )
        lock.lock()
        if let cached = pipelines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let function: MTLFunction
        if let constants {
            do {
                function = try library.makeFunction(
                    name: kernel.rawValue,
                    constantValues: constants
                )
            } catch {
                throw MetalRuntimeError.pipelineCreationFailed(
                    function: kernel.rawValue,
                    reason: String(describing: error)
                )
            }
        } else {
            guard let value = library.makeFunction(
                name: kernel.rawValue
            ) else {
                throw MetalRuntimeError.functionMissing(kernel.rawValue)
            }
            function = value
        }

        let descriptor = MTLComputePipelineDescriptor()
        let stableLabel = [
            "NumiTissue",
            kernel.rawValue,
            numericalProfile.rawValue,
            String(constantsHash, radix: 16)
        ].joined(separator: ".")
        descriptor.label = stableLabel
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        descriptor.maxCallStackDepth = 1
        try pipelineArchive?.prepare(
            descriptor: descriptor,
            stableLabel: stableLabel
        )

        do {
            let pipeline = try context.device.makeComputePipelineState(
                descriptor: descriptor,
                options: [],
                reflection: nil
            )
            lock.lock()
            pipelines[key] = pipeline
            lock.unlock()
            return pipeline
        } catch {
            throw MetalRuntimeError.pipelineCreationFailed(
                function: kernel.rawValue,
                reason: String(describing: error)
            )
        }
    }

    public func prewarm(
        _ kernels: [MetalKernel] = MetalKernel.allCases
    ) throws {
        for kernel in kernels { _ = try pipeline(kernel) }
        try pipelineArchive?.serializeIfNeeded()
    }

    public func serializePipelineArchiveIfNeeded() throws {
        try pipelineArchive?.serializeIfNeeded()
    }

    public var cachedPipelineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipelines.count
    }

    private static func loadBundledShaderSource(
        additionalSource: String?
    ) throws -> String {
        let fileNames = [
            "NumiTissueABI",
            "NumiTissueOverlays",
            "NumiTissueWorklists",
            "NumiTissueElectrophysiology",
            "NumiTissueEvents",
            "NumiTissueFields",
            "NumiTissueMolecular",
            "NumiTissueDevelopment",
            "NumiTissueValidation",
            "NumiTissueDifferential"
        ]
        var source = ""
        for name in fileNames {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "metal",
                subdirectory: "Shaders"
            ) ?? Bundle.module.url(
                forResource: name,
                withExtension: "metal"
            ) else {
                throw MetalRuntimeError.libraryCompilationFailed(
                    "Missing bundled shader source \(name).metal"
                )
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
    func ntDispatch1D(
        count: Int,
        pipeline: MTLComputePipelineState
    ) {
        guard count > 0 else { return }
        let width = min(
            pipeline.maxTotalThreadsPerThreadgroup,
            max(pipeline.threadExecutionWidth, 64)
        )
        setComputePipelineState(pipeline)
        dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: width,
                height: 1,
                depth: 1
            )
        )
    }

    func ntDispatchIndirect(
        buffer: MTLBuffer,
        offset: Int,
        threadsPerThreadgroup: MTLSize,
        pipeline: MTLComputePipelineState
    ) {
        setComputePipelineState(pipeline)
        dispatchThreadgroups(
            indirectBuffer: buffer,
            indirectBufferOffset: offset,
            threadsPerThreadgroup: threadsPerThreadgroup
        )
    }
}
#endif
