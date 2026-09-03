#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

struct StagedMetal4Overlay: Sendable {
    var transaction: TransactionID
    var overlay: CompiledTransactionOverlay
    var stateTemplate: TissueRuntimeState
}

/// A distinct Metal 4 execution authority. It shares the established model/state ABI and shader
/// library, but owns a separate command, synchronization, binding, residency, and qualification
/// path. The classic `MetalTissueBackend` remains available until this backend passes Phase 3.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public actor Metal4TissueBackend: InterventionAwareTissueBackend, AdaptiveFidelityExecutionBackend {
    nonisolated public let name = "NumiTissue Metal 4"
    nonisolated public let capabilities: TissueRuntimeCapabilities

    public let context: MetalDeviceContext
    public let options: MetalExecutionOptions
    public let metal4Configuration: Metal4ExecutionConfiguration
    public let metal4Context: Metal4RuntimeContext
    public let supportReport: Metal4SupportReport

    let molecularProgram: MetalMolecularProgram
    let overlayCompiler = RuntimeOverlayCompiler()
    let fidelityMigration = MetalFidelityMigrationCoordinator()
    let argumentTableCache: Metal4ArgumentTableCache
    let stableResidency: Metal4ResidencyController
    let transactionResidency: Metal4ResidencyController
    let qualificationReport: Metal4QualificationReport?

    var shaderLibrary: MetalShaderLibrary?
    var modelBuffers: MetalModelBuffers?
    var biologyMetadata: MetalBiologyMetadataBuffers?
    var arena: MetalStateArena?
    var argumentTables: [ObjectIdentifier: MetalArgumentTable] = [:]
    var phaseHeaderRing: Metal4PhaseHeaderRing?
    var cachedPipelines: [MTLComputePipelineState] = []
    var model: CompiledTissueModel?

    var currentContext: ExecutionContext?
    var currentInput: RuntimeInputFrame?
    var encodingSession: Metal4EncodingSession?
    var commandSubmitted = false
    var stagedOverlay: StagedMetal4Overlay?
    var activeOverlayBuffers: MetalTransactionOverlayBuffers?
    var explicitFidelityPlanStaged = false
    var fidelityPreparationAttempted = false
    var retainedCounters: (transaction: TransactionID, value: RuntimeCounters)?
    var checkpointRoutingBlockTicks: UInt64?
    var maxCableDepth: UInt32 = 0
    var currentEncodingStatistics = Metal4EncodingStatistics()
    var lastEncodingStatistics = Metal4EncodingStatistics()
    var lastStableResidencySnapshot: Metal4ResidencySnapshot?
    var lastTransactionResidencySnapshot: Metal4ResidencySnapshot?

    public init(
        capabilities: TissueRuntimeCapabilities,
        device: MTLDevice? = nil,
        options: MetalExecutionOptions = MetalExecutionOptions(
            requestedNumericalProfile: .scientific32
        ),
        metal4Configuration sourceConfiguration: Metal4ExecutionConfiguration = .scientific,
        molecularProgram: MetalMolecularProgram = MetalMolecularProgram(),
        qualificationReport: Metal4QualificationReport? = nil
    ) throws {
        let configuration = try sourceConfiguration.validated()
        guard configuration.requirement != .disabled else {
            throw Metal4BackendError.disabledByConfiguration
        }
        guard configuration.maximumDispatchesPerGroup >= 32 else {
            throw Metal4BackendError.commandGroupTooSmall(
                configuration.maximumDispatchesPerGroup
            )
        }
        guard configuration.attachStableResidencySetToQueue else {
            throw Metal4BackendError.queueResidencyRequired
        }
        guard capabilities.supportsMetal4 else {
            throw Metal4BackendError.capabilityContractMissingMetal4
        }

        let classicContext = try MetalDeviceContext(
            device: device,
            options: options
        )
        let support = try Metal4Support.require(device: classicContext.device)
        let runtime = try Metal4RuntimeContext(
            device: classicContext.device,
            configuration: configuration
        )
        let tableCache = try Metal4ArgumentTableCache(
            device: classicContext.device,
            maximumBufferBindingCount: configuration.maximumBufferBindingCount
        )
        let stable = Metal4ResidencyController(
            device: classicContext.device,
            queue: runtime.queue,
            attachToQueue: configuration.attachStableResidencySetToQueue,
            requestAhead: configuration.requestResidencyAheadOfExecution
        )
        let transaction = Metal4ResidencyController(
            device: classicContext.device,
            queue: runtime.queue,
            attachToQueue: true,
            requestAhead: configuration.requestResidencyAheadOfExecution
        )

        if options.effectiveNumericalProfile == .performance32,
           configuration.requireQualificationBeforePerformanceMode {
            guard qualificationReport?.promotionApproved == true else {
                throw Metal4BackendError.performanceModeNotQualified
            }
        }
        if let qualificationReport,
           !qualificationReport.promotionApproved {
            throw Metal4BackendError.rejectedQualificationReport
        }

        self.capabilities = capabilities
        self.context = classicContext
        self.options = options
        self.metal4Configuration = configuration
        self.metal4Context = runtime
        self.supportReport = support
        self.molecularProgram = molecularProgram
        self.argumentTableCache = tableCache
        self.stableResidency = stable
        self.transactionResidency = transaction
        self.qualificationReport = qualificationReport
    }

    public func load(
        model: CompiledTissueModel,
        initialState: TissueRuntimeState
    ) async throws {
        guard arena == nil else { throw RuntimeExecutionError.alreadyLoaded }
        var normalized = initialState
        normalized.reserveCapacity(normalized.capacity)
        try normalized.validateCapacity()
        try MetalMolecularProgramValidator.validate(
            model: model,
            initialState: normalized,
            program: molecularProgram
        )

        let archiveURL = metal4Configuration.pipelineArchivePath.map {
            URL(fileURLWithPath: $0)
        }
        let shaders = try await MetalShaderLibrary(
            context: context,
            pipelineArchiveURL: archiveURL
        )
        try shaders.prewarm()
        let pipelines = try MetalKernel.allCases.map {
            try shaders.pipeline($0)
        }
        let arena = try MetalStateArena(
            context: context,
            initialState: normalized
        )
        try await arena.uploadInitialState(normalized)
        let modelBuffers = try await MetalModelBuffers(
            context: context,
            model: model,
            program: molecularProgram
        )
        let biologyMetadata = try await MetalBiologyMetadataBuffers(
            context: context,
            model: model
        )
        let ring = try Metal4PhaseHeaderRing(
            context: context,
            capacity: metal4Configuration.maximumDispatchesPerGroup
        )
        let tables = try makeArgumentTables(
            arena: arena,
            shaders: shaders
        )

        shaderLibrary = shaders
        self.modelBuffers = modelBuffers
        self.biologyMetadata = biologyMetadata
        self.arena = arena
        phaseHeaderRing = ring
        self.model = model
        argumentTables = tables
        cachedPipelines = pipelines
        maxCableDepth = Self.cableDepth(in: normalized)

        try await clearPersistentTransientState(
            arena: arena,
            shaders: shaders,
            table: try shadowArgumentTable(in: tables, arena: arena)
        )
        lastStableResidencySnapshot = try stableResidency.install(
            allocations: Metal4ResidencyCatalog.allocations(
                context: context,
                arena: arena,
                argumentTables: Array(tables.values),
                phaseHeaderRing: ring,
                pipelines: pipelines
            ),
            label: "NumiTissue.Metal4.stable"
        )
    }

    public func stageInterventions(
        _ frame: TissueInterventionFrame,
        context executionContext: ExecutionContext
    ) async throws {
        guard let arena, let model else {
            throw MetalRuntimeError.stateNotLoaded
        }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        guard frame.tick == executionContext.startTime.tick else {
            throw RuntimeOverlayError.staleFrame(
                expected: executionContext.startTime.tick,
                received: frame.tick
            )
        }
        let currentState = try await arena.downloadCommittedState()
        let compiled = try overlayCompiler.compile(
            frame: frame,
            state: currentState,
            model: model
        )
        stagedOverlay = StagedMetal4Overlay(
            transaction: executionContext.transaction,
            overlay: compiled,
            stateTemplate: currentState
        )
    }

    public func stageFidelityDecisions(
        _ decisions: [FidelityDecision],
        context executionContext: ExecutionContext
    ) async throws {
        guard currentContext == nil else {
            throw AdaptiveFidelityBackendError.transactionInProgress
        }
        try fidelityMigration.stage(
            decisions,
            transaction: executionContext.transaction
        )
        explicitFidelityPlanStaged = true
    }

    public func lastFidelityMigrationPlan() async -> FidelityMigrationPlan? {
        fidelityMigration.lastPlan
    }

    public func beginShadowStep(
        context executionContext: ExecutionContext,
        input: RuntimeInputFrame
    ) async throws {
        guard let arena,
              let shaders = shaderLibrary,
              let modelBuffers,
              let ring = phaseHeaderRing else {
            throw MetalRuntimeError.stateNotLoaded
        }
        guard currentContext == nil else {
            throw MetalRuntimeError.transactionAlreadyOpen
        }
        if let checkpointRoutingBlockTicks,
           checkpointRoutingBlockTicks != executionContext.cadence.routingBlockTicks {
            throw MetalRuntimeError.unsupported(
                "checkpoint routing cadence \(checkpointRoutingBlockTicks) does not match execution cadence \(executionContext.cadence.routingBlockTicks)"
            )
        }
        checkpointRoutingBlockTicks = executionContext.cadence.routingBlockTicks
        if let stagedOverlay,
           stagedOverlay.transaction != executionContext.transaction {
            throw RuntimeExecutionError.staleTransaction
        }
        try fidelityMigration.assertStagedTransaction(
            executionContext.transaction
        )

        var effectiveInput = input
        if let stagedOverlay {
            effectiveInput.stimuli.append(
                contentsOf: stagedOverlay.overlay.stimuli
            )
            effectiveInput.stimuli.sort {
                if $0.startTick != $1.startTick {
                    return $0.startTick < $1.startTick
                }
                if $0.destination != $1.destination {
                    return $0.destination < $1.destination
                }
                return $0.kind < $1.kind
            }
        }
        _ = try effectiveInput.validated(
            startTime: executionContext.startTime,
            cadence: executionContext.cadence
        )

        arena.transient.resetCPUVisible()
        try arena.uploadInput(
            events: effectiveInput.afferentEvents,
            stimuli: effectiveInput.stimuli
        )
        writeControlInput(
            effectiveInput,
            to: arena.transient.outputScalars
        )

        ring.reset()
        currentContext = executionContext
        currentInput = effectiveInput
        commandSubmitted = false
        fidelityPreparationAttempted = false
        retainedCounters = nil
        currentEncodingStatistics = Metal4EncodingStatistics()

        let lease: Metal4CommandLease
        do {
            lease = try metal4Context.beginUnifiedComputePass()
        } catch {
            clearOpenTransaction()
            throw error
        }
        let session = Metal4EncodingSession(
            lease: lease,
            configuration: metal4Configuration,
            telemetry: metal4Context.telemetry
        )
        encodingSession = session

        do {
            try Metal4StateEncoder.copyCommittedToShadow(
                arena: arena,
                session: session
            )
            try Metal4StateEncoder.resetEffectiveParameters(
                model: modelBuffers,
                session: session
            )
            try Metal4StateEncoder.resetTransactionTransientState(
                arena: arena,
                session: session
            )

            if let stagedOverlay, !stagedOverlay.overlay.isEmpty {
                guard let root = argumentTables[
                    ObjectIdentifier(arena.shadow)
                ] else {
                    throw MetalRuntimeError.stateNotLoaded
                }
                let buffers = try MetalTransactionOverlayBuffers(
                    context: context,
                    overlay: stagedOverlay.overlay,
                    model: modelBuffers,
                    state: stagedOverlay.stateTemplate,
                    transactionID: executionContext.transaction.rawValue
                )
                lastTransactionResidencySnapshot = try transactionResidency.install(
                    allocations: [
                        buffers.groups as any MTLAllocation,
                        buffers.records as any MTLAllocation,
                        buffers.parameters as any MTLAllocation
                    ],
                    label: "NumiTissue.Metal4.transaction.\(executionContext.transaction.rawValue)"
                )
                try Metal4TransactionOverlayEncoder.encode(
                    buffers: buffers,
                    rootArgumentTable: root,
                    model: modelBuffers,
                    shaderLibrary: shaders,
                    argumentTables: argumentTableCache,
                    session: session
                )
                activeOverlayBuffers = buffers
            } else {
                transactionResidency.detach()
                lastTransactionResidencySnapshot = nil
            }
        } catch {
            metal4Context.abandon(lease)
            encodingSession = nil
            clearOpenTransaction()
            throw error
        }
    }

    func clearPersistentTransientState(
        arena: MetalStateArena,
        shaders: MetalShaderLibrary,
        table: MetalArgumentTable
    ) async throws {
        arena.transient.resetCPUVisible()
        let command = try context.makeCommandBuffer(
            label: "NumiTissue.Metal4.initial-reset"
        )
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("reset")
        }
        context.telemetry.recordComputeEncoder()
        encoder.setBuffer(table.buffer, offset: 0, index: 0)
        table.useResources(
            on: encoder,
            state: arena.shadow,
            transient: arena.transient
        )
        encoder.ntDispatch1D(
            count: 4_096,
            pipeline: try shaders.pipeline(.resetTransientState)
        )
        encoder.endEncoding()
        try await context.awaitCompletion(MetalCommandBufferHandle(command))
    }

    func writeControlInput(
        _ input: RuntimeInputFrame,
        to buffer: MTLBuffer
    ) {
        let values = buffer.contents().bindMemory(
            to: Float.self,
            capacity: 16
        )
        for index in 0..<16 { values[index] = 0 }
        for index in 0..<8 { values[index] = input.neuromodulators[index] }
        for index in 0..<8 { values[8 + index] = input.hormones[index] }
        context.telemetry.recordUpload(bytes: 16 * MemoryLayout<Float>.stride)
    }

    static func cableDepth(in state: TissueRuntimeState) -> UInt32 {
        state.compartments.reduce(0) {
            max($0, ($1.flags >> 16) & 0xFF)
        }
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4BackendError: Error, Sendable, CustomStringConvertible {
    case disabledByConfiguration
    case commandGroupTooSmall(Int)
    case queueResidencyRequired
    case capabilityContractMissingMetal4
    case performanceModeNotQualified
    case rejectedQualificationReport

    public var description: String {
        switch self {
        case .disabledByConfiguration:
            return "Metal 4 backend was explicitly disabled"
        case .commandGroupTooSmall(let count):
            return "Metal 4 backend requires at least 32 commands per group; received \(count)"
        case .queueResidencyRequired:
            return "Metal 4 tissue execution requires a queue-attached stable residency set"
        case .capabilityContractMissingMetal4:
            return "Runtime capabilities do not declare Metal 4 support"
        case .performanceModeNotQualified:
            return "Metal 4 performance32 mode requires an approved Phase 3 qualification report"
        case .rejectedQualificationReport:
            return "The supplied Phase 3 qualification report did not approve promotion"
        }
    }
}
#endif
