#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

private final class MetalPhaseHeaderRing: @unchecked Sendable {
    let buffer: MTLBuffer
    let stride: Int
    let capacity: Int
    private(set) var count: Int = 0

    init(context: MetalDeviceContext, capacity: Int = 2_048) throws {
        self.stride = MetalTissueABI.alignment
        self.capacity = capacity
        self.buffer = try context.makeSharedBuffer(
            length: capacity * stride,
            label: "NumiTissue.phaseHeaders",
            writeCombined: true
        )
    }

    func reset() { count = 0 }

    func append(_ header: MetalSimulationHeader) throws -> Int {
        guard count < capacity else { throw MetalRuntimeError.capacityExceeded("phase header ring") }
        let offset = count * stride
        memset(buffer.contents().advanced(by: offset), 0, stride)
        withUnsafeBytes(of: header) { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().advanced(by: offset).copyMemory(from: base, byteCount: bytes.count)
        }
        count += 1
        return offset
    }
}

private struct StagedMetalOverlay: Sendable {
    var transaction: TransactionID
    var overlay: CompiledTransactionOverlay
    var stateTemplate: TissueRuntimeState
}

/// Production Apple-Silicon backend. It records one complete 5 ms transaction into one Metal
/// command buffer. Immutable model tables are reset into transaction-local effective tables,
/// overlays are materialized once, and all kernels consume the resulting effective values.
public actor MetalTissueBackend: InterventionAwareTissueBackend {
    nonisolated public let name = "NumiTissue Metal"
    nonisolated public let capabilities: TissueRuntimeCapabilities

    public let context: MetalDeviceContext
    public let options: MetalExecutionOptions

    private let molecularProgram: MetalMolecularProgram
    private let overlayCompiler = RuntimeOverlayCompiler()
    private var shaderLibrary: MetalShaderLibrary?
    private var modelBuffers: MetalModelBuffers?
    private var biologyMetadata: MetalBiologyMetadataBuffers?
    private var arena: MetalStateArena?
    private var argumentTables: [ObjectIdentifier: MetalArgumentTable] = [:]
    private var phaseHeaderRing: MetalPhaseHeaderRing?
    private var model: CompiledTissueModel?
    private var currentContext: ExecutionContext?
    private var currentInput: RuntimeInputFrame?
    private var commandBuffer: MTLCommandBuffer?
    private var maxCableDepth: UInt32 = 0
    private var commandSubmitted = false
    private var stagedOverlay: StagedMetalOverlay?
    private var activeOverlayBuffers: MetalTransactionOverlayBuffers?

    public init(
        capabilities: TissueRuntimeCapabilities,
        device: MTLDevice? = nil,
        options: MetalExecutionOptions = MetalExecutionOptions(),
        molecularProgram: MetalMolecularProgram = MetalMolecularProgram()
    ) throws {
        self.capabilities = capabilities
        self.options = options
        self.molecularProgram = molecularProgram
        self.context = try MetalDeviceContext(device: device, options: options)
    }

    public func load(model: CompiledTissueModel, initialState: TissueRuntimeState) async throws {
        guard arena == nil else { throw RuntimeExecutionError.alreadyLoaded }
        var normalized = initialState
        normalized.reserveCapacity(normalized.capacity)
        try normalized.validateCapacity()

        let shaders = try await MetalShaderLibrary(context: context)
        try shaders.prewarm()
        let arena = try MetalStateArena(context: context, initialState: normalized)
        try await arena.uploadInitialState(normalized)
        let modelBuffers = try await MetalModelBuffers(
            context: context,
            model: model,
            program: molecularProgram
        )
        let biologyMetadata = try await MetalBiologyMetadataBuffers(context: context, model: model)
        let ring = try MetalPhaseHeaderRing(context: context)
        let committedTable = try MetalArgumentTable(
            context: context,
            shaderLibrary: shaders,
            state: arena.committed,
            transient: arena.transient,
            label: "NumiTissue.arguments.committed"
        )
        let shadowTable = try MetalArgumentTable(
            context: context,
            shaderLibrary: shaders,
            state: arena.shadow,
            transient: arena.transient,
            label: "NumiTissue.arguments.shadow"
        )

        self.shaderLibrary = shaders
        self.modelBuffers = modelBuffers
        self.biologyMetadata = biologyMetadata
        self.arena = arena
        self.phaseHeaderRing = ring
        self.model = model
        argumentTables[ObjectIdentifier(arena.committed)] = committedTable
        argumentTables[ObjectIdentifier(arena.shadow)] = shadowTable
        maxCableDepth = normalized.compartments.reduce(0) { max($0, ($1.flags >> 16) & 0xFF) }
        try await clearPersistentTransientState(arena: arena, shaders: shaders, table: shadowTable)
    }

    public func stageInterventions(
        _ frame: TissueInterventionFrame,
        context executionContext: ExecutionContext
    ) async throws {
        guard let arena, let model else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext == nil else { throw RuntimeExecutionError.transactionInProgress }
        guard frame.tick == executionContext.startTime.tick else {
            throw RuntimeOverlayError.staleFrame(
                expected: executionContext.startTime.tick,
                received: frame.tick
            )
        }
        let currentState = try await arena.downloadCommittedState()
        let compiled = try overlayCompiler.compile(frame: frame, state: currentState, model: model)
        stagedOverlay = StagedMetalOverlay(
            transaction: executionContext.transaction,
            overlay: compiled,
            stateTemplate: currentState
        )
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
        guard currentContext == nil else { throw MetalRuntimeError.transactionAlreadyOpen }
        if let stagedOverlay, stagedOverlay.transaction != executionContext.transaction {
            throw RuntimeExecutionError.staleTransaction
        }

        try await arena.copyCommittedToShadow()
        arena.transient.resetCPUVisible()
        var effectiveInput = input
        if let stagedOverlay {
            effectiveInput.stimuli.append(contentsOf: stagedOverlay.overlay.stimuli)
            effectiveInput.stimuli.sort {
                if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
                if $0.destination != $1.destination { return $0.destination < $1.destination }
                return $0.kind < $1.kind
            }
        }
        try arena.uploadInput(
            events: effectiveInput.afferentEvents,
            stimuli: effectiveInput.stimuli
        )
        writeControlInput(effectiveInput, to: arena.transient.outputScalars)

        ring.reset()
        currentContext = executionContext
        currentInput = effectiveInput
        commandSubmitted = false
        guard let command = context.commandQueue.makeCommandBuffer() else {
            clearOpenTransaction()
            throw MetalRuntimeError.commandBufferCreationFailed
        }
        command.label = "NumiTissue.transaction.\(executionContext.transaction.rawValue)"
        commandBuffer = command

        try modelBuffers.encodeResetEffective(on: command)
        if let stagedOverlay, !stagedOverlay.overlay.isEmpty {
            guard let table = argumentTables[ObjectIdentifier(arena.shadow)] else {
                clearOpenTransaction()
                throw MetalRuntimeError.stateNotLoaded
            }
            let buffers = try MetalTransactionOverlayBuffers(
                context: context,
                overlay: stagedOverlay.overlay,
                model: modelBuffers,
                state: stagedOverlay.stateTemplate,
                transactionID: executionContext.transaction.rawValue
            )
            try buffers.encodeMaterialization(
                command: command,
                library: shaders,
                argumentTable: table,
                state: arena.shadow,
                transient: arena.transient,
                model: modelBuffers
            )
            activeOverlayBuffers = buffers
        }
    }

    public func execute(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context executionContext: ExecutionContext
    ) async throws {
        guard let arena,
              let modelBuffers,
              let biologyMetadata,
              let ring = phaseHeaderRing,
              let command = commandBuffer else {
            throw MetalRuntimeError.noOpenTransaction
        }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        guard let table = argumentTables[ObjectIdentifier(arena.shadow)] else {
            throw MetalRuntimeError.stateNotLoaded
        }

        var header = MetalSimulationHeader(
            state: arena.committedCPUState,
            context: executionContext,
            phase: phase,
            phaseRange: tickRange
        )
        header.reserved0.x = UInt32(clamping: currentInput?.afferentEvents.count ?? 0)
        header.reserved0.y = UInt32(clamping: currentInput?.stimuli.count ?? 0)
        header.reserved0.z = UInt32(clamping: biologyMetadata.regulatoryProgramCount)
        header.reserved0.w = UInt32(clamping: biologyMetadata.fateTransitionCount)
        header.reserved1.y = UInt32(clamping: arena.transient.validationCapacity)
        header.reserved1.z = UInt32(clamping: biologyMetadata.glialProgramCount)
        header.reserved1.w = UInt32(clamping: biologyMetadata.growthProgramCount)
        header.reserved2.y = UInt32(clamping: biologyMetadata.synapseParameterCount)
        header.reserved2.z = UInt32(clamping: biologyMetadata.fieldParameterCount)
        header.reserved2.w = UInt32(clamping: modelBuffers.cellProgramCount)
        header.reserved3.x = UInt32(clamping: modelBuffers.networkCount)
        header.reserved3.y = UInt32(clamping: modelBuffers.reactionCount)
        header.reserved3.z = UInt32(clamping: modelBuffers.channelCount)
        header.reserved3.w = UInt32(clamping: modelBuffers.mechanismSetCount)

        switch phase {
        case .ingestInputs:
            try encode(
                kernel: .ingestInputEvents,
                count: max(Int(header.reserved0.x), Int(header.reserved0.y)),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )

        case .buildWorklists:
            try encode(
                kernel: .buildWorklists,
                count: Int(header.tileCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )
            try encode(
                kernel: .encodeIndirectDispatch,
                count: 7,
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )

        case .deliverEvents:
            let bucketCapacity = max(Int(header.eventCapacity) / 4_096, 1)
            try encode(
                kernel: .deliverEvents,
                count: bucketCapacity,
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.synapseParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .decaySynapses:
            try encode(
                kernel: .decaySynapses,
                count: Int(header.synapseCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.synapseParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .updateChannels:
            var buffers: [(MTLBuffer, Int)] = [
                (modelBuffers.channelMetadata, 1),
                (modelBuffers.mechanismSetMetadata, 2)
            ]
            buffers += parameterBuffers(
                [.channelParameter, .mechanismSetParameter, .cellProgramParameter],
                model: modelBuffers,
                startingAt: 3
            )
            try encode(
                kernel: .updateChannels,
                count: Int(header.compartmentCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: buffers
            )

        case .solveCableTrees:
            try encodeCableSolve(
                header: header,
                command: command,
                ring: ring,
                table: table,
                arena: arena
            )

        case .detectSpikes:
            try encode(
                kernel: .detectSpikes,
                count: Int(header.compartmentCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.cellProgramParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .routeSpikes:
            try encode(
                kernel: .routeSpikes,
                count: Int(header.synapseCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )

        case .updateFastFields:
            let buffers = parameterBuffers(
                [.fieldParameter],
                model: modelBuffers,
                startingAt: 1
            )
            var parity0 = header
            parity0.reserved2.x = 0
            try encode(
                kernel: .updateFastFields,
                count: Int(header.fieldValueCount),
                header: parity0,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: buffers
            )
            var parity1 = header
            parity1.reserved2.x = 1
            try encode(
                kernel: .updateFastFields,
                count: Int(header.fieldValueCount),
                header: parity1,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: buffers
            )

        case .updateMolecularDomains:
            var buffers: [(MTLBuffer, Int)] = [
                (modelBuffers.molecularNetworks, 1),
                (modelBuffers.molecularReactions, 2)
            ]
            buffers += parameterBuffers(
                [.molecularReactionParameter],
                model: modelBuffers,
                startingAt: 3
            )
            try encode(
                kernel: .updateMolecularDomains,
                count: Int(header.microdomainCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: buffers
            )

        case .updateGliaAndMetabolism:
            let common: [(MTLBuffer, Int)] = [
                (modelBuffers.cellProgramIdentity, 1),
                (modelBuffers.cellProgramMetadata, 2)
            ] + parameterBuffers(
                [.glialProgramParameter, .fieldParameter],
                model: modelBuffers,
                startingAt: 3
            )
            try encode(
                kernel: .updateGliaAndMetabolism,
                count: Int(header.cellCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: common
            )
            try encode(
                kernel: .updateMyelination,
                count: Int(header.segmentCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: Array(common.prefix(3))
            )
            try encode(
                kernel: .updateMicroglialPruning,
                count: Int(header.synapseCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: Array(common.prefix(3))
            )

        case .applyPlasticity:
            try encode(
                kernel: .applyPlasticity,
                count: Int(header.synapseCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.synapseParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .updateCellMechanics:
            try encode(
                kernel: .updateCellMechanics,
                count: Int(header.cellCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.cellProgramParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .updateDevelopment:
            var buffers: [(MTLBuffer, Int)] = [
                (modelBuffers.cellProgramIdentity, 1),
                (modelBuffers.cellProgramMetadata, 2),
                (biologyMetadata.regulatoryStateAndMatrix, 3),
                (biologyMetadata.regulatoryBiasAndTransition, 4),
                (biologyMetadata.regulatoryMatrix, 5),
                (biologyMetadata.regulatoryBias, 6),
                (biologyMetadata.fateIdentity, 7)
            ]
            buffers += parameterBuffers(
                [
                    .regulatoryProgramParameter,
                    .fateTransitionParameter,
                    .growthProgramParameter,
                    .cellProgramParameter
                ],
                model: modelBuffers,
                startingAt: 8
            )
            try encode(
                kernel: .updateDevelopment,
                count: max(Int(header.cellCount), Int(header.segmentCount)),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: buffers
            )

        case .updateStructuralPlasticity:
            try encode(
                kernel: .updateStructuralPlasticity,
                count: Int(header.synapseCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient,
                additionalBuffers: parameterBuffers(
                    [.synapseParameter],
                    model: modelBuffers,
                    startingAt: 1
                )
            )

        case .updateAdaptiveFidelity:
            try encode(
                kernel: .updateAdaptiveFidelity,
                count: Int(header.cellCount),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )

        case .collectOutputs:
            try encode(
                kernel: .collectOutputs,
                count: max(Int(header.tileCount), Int(header.eventCapacity)),
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )

        case .validate:
            let count = max(
                Int(header.cellCount),
                Int(header.compartmentCount),
                Int(header.synapseCount),
                Int(header.fieldValueCount),
                Int(header.microdomainCount),
                Int(header.molecularSpeciesCount)
            )
            try encode(
                kernel: .validateState,
                count: count,
                header: header,
                command: command,
                ring: ring,
                table: table,
                state: arena.shadow,
                transient: arena.transient
            )
        }
    }

    public func collectOutput(context executionContext: ExecutionContext) async throws -> RuntimeOutputFrame {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        try await ensureSubmitted()
        let counter = arena.transient.counters.contents().load(as: MetalRuntimeCounters.self)
        let generated = min(Int(counter.generatedSpikesLo), arena.transient.eventCapacity)
        let pointer = arena.transient.outputEvents.contents().bindMemory(
            to: MetalEvent.self,
            capacity: max(generated, 1)
        )
        var output = RuntimeOutputFrame(
            startTime: executionContext.startTime,
            endTime: executionContext.endTime
        )
        output.efferentEvents.reserveCapacity(generated)
        for index in 0..<generated {
            output.efferentEvents.append(pointer[index].routedEvent)
        }

        let tileCount = arena.committedCPUState.tiles.count
        let scalars = arena.transient.outputScalars.contents().bindMemory(
            to: Float.self,
            capacity: max(16 + tileCount * 4, 1)
        )
        output.populationActivity.reserveCapacity(tileCount)
        output.localFieldPotentials.reserveCapacity(tileCount)
        output.metabolicDemand.reserveCapacity(tileCount)
        var damage: Float = 0
        for tile in 0..<tileCount {
            let base = 16 + tile * 4
            output.localFieldPotentials.append(scalars[base])
            output.populationActivity.append(scalars[base + 2])
            output.metabolicDemand.append(max(scalars[base + 3], 0))
            damage = max(damage, scalars[base + 3])
        }
        output.uncertainty = arena.committedCPUState.tiles.map(\.uncertaintyScore).max() ?? 0
        output.plasticityMagnitude = abs(scalars[0])
        if damage > 0.5 {
            output.damageEvents.append(
                RoutedEvent(
                    arrivalTick: executionContext.endTime.tick,
                    source: 0,
                    destination: 0,
                    amplitude: damage,
                    kind: .damage
                )
            )
        }
        return output
    }

    public func validateShadow(context: ExecutionContext) async throws -> [RuntimeValidationIssue] {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        try await ensureSubmitted()
        let counters = arena.transient.counters.contents().load(as: MetalRuntimeCounters.self)
        let count = min(Int(counters.validationCount), arena.transient.validationCapacity)
        let records = arena.transient.validationRecords.contents().bindMemory(
            to: MetalValidationRecord.self,
            capacity: max(count, 1)
        )
        var issues: [RuntimeValidationIssue] = []
        issues.reserveCapacity(count)
        for index in 0..<count {
            let record = records[index]
            issues.append(
                RuntimeValidationIssue(
                    severity: record.severity == 0 ? .warning : .reject,
                    code: record.code,
                    entity: UInt64(record.entityLo) | (UInt64(record.entityHi) << 32),
                    value: record.value,
                    message: Self.validationMessage(code: record.code, index: record.index)
                )
            )
        }
        return issues
    }

    public func commitShadow(context executionContext: ExecutionContext) async throws {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }
        try await ensureSubmitted()
        arena.commit(time: executionContext.endTime, epoch: executionContext.epoch &+ 1)
        clearOpenTransaction()
    }

    public func rollbackShadow(context: ExecutionContext) async {
        commandBuffer = nil
        arena?.rollback()
        clearOpenTransaction()
    }

    public func counters(context: ExecutionContext) async -> RuntimeCounters {
        guard let arena else { return RuntimeCounters() }
        return arena.transient.counters.contents().load(as: MetalRuntimeCounters.self).runtimeCounters()
    }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext == nil else { throw RuntimeExecutionError.transactionInProgress }
        return try await arena.downloadCommittedState()
    }

    private func encodeCableSolve(
        header: MetalSimulationHeader,
        command: MTLCommandBuffer,
        ring: MetalPhaseHeaderRing,
        table: MetalArgumentTable,
        arena: MetalStateArena
    ) throws {
        try encode(
            kernel: .assembleCableSystem,
            count: Int(header.compartmentCount),
            header: header,
            command: command,
            ring: ring,
            table: table,
            state: arena.shadow,
            transient: arena.transient
        )
        if maxCableDepth > 0 {
            for depth in stride(from: maxCableDepth, through: 1, by: -1) {
                var levelHeader = header
                levelHeader.reserved2.x = depth
                try encode(
                    kernel: .eliminateCableLevels,
                    count: Int(header.compartmentCount),
                    header: levelHeader,
                    command: command,
                    ring: ring,
                    table: table,
                    state: arena.shadow,
                    transient: arena.transient
                )
            }
        }
        try encode(
            kernel: .solveCableRoots,
            count: Int(header.compartmentCount),
            header: header,
            command: command,
            ring: ring,
            table: table,
            state: arena.shadow,
            transient: arena.transient
        )
        if maxCableDepth > 0 {
            for depth in 1...maxCableDepth {
                var levelHeader = header
                levelHeader.reserved2.x = depth
                try encode(
                    kernel: .backSubstituteCableLevels,
                    count: Int(header.compartmentCount),
                    header: levelHeader,
                    command: command,
                    ring: ring,
                    table: table,
                    state: arena.shadow,
                    transient: arena.transient
                )
            }
        }
    }

    private func parameterBuffers(
        _ domains: [RuntimeOverlayDomain],
        model: MetalModelBuffers,
        startingAt firstIndex: Int
    ) -> [(MTLBuffer, Int)] {
        domains.enumerated().compactMap { offset, domain in
            model.table(for: domain).map { ($0.effective, firstIndex + offset) }
        }
    }

    private func encode(
        kernel: MetalKernel,
        count: Int,
        header: MetalSimulationHeader,
        command: MTLCommandBuffer,
        ring: MetalPhaseHeaderRing,
        table: MetalArgumentTable,
        state: MetalStateBufferSet,
        transient: MetalTransientBuffers,
        additionalBuffers: [(MTLBuffer, Int)] = []
    ) throws {
        guard count > 0 else { return }
        let offset = try ring.append(header)
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("phaseHeader")
        }
        blit.label = "NumiTissue.header.\(kernel.rawValue)"
        blit.copy(
            from: ring.buffer,
            sourceOffset: offset,
            to: transient.header,
            destinationOffset: 0,
            size: MemoryLayout<MetalSimulationHeader>.stride
        )
        blit.endEncoding()

        guard let compute = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed(kernel.rawValue)
        }
        compute.label = "NumiTissue.\(kernel.rawValue)"
        compute.setBuffer(table.buffer, offset: 0, index: 0)
        for (buffer, index) in additionalBuffers {
            compute.setBuffer(buffer, offset: 0, index: index)
            compute.useResource(buffer, usage: .read)
        }
        table.useResources(on: compute, state: state, transient: transient)
        guard let library = shaderLibrary else {
            compute.endEncoding()
            throw MetalRuntimeError.stateNotLoaded
        }
        let pipeline = try library.pipeline(kernel)
        compute.ntDispatch1D(count: count, pipeline: pipeline)
        compute.endEncoding()
    }

    private func ensureSubmitted() async throws {
        guard let command = commandBuffer else {
            if commandSubmitted { return }
            throw MetalRuntimeError.noOpenTransaction
        }
        if !commandSubmitted {
            commandSubmitted = true
            try await context.awaitCompletion(command)
            commandBuffer = nil
        }
    }

    private func clearOpenTransaction() {
        currentContext = nil
        currentInput = nil
        commandBuffer = nil
        commandSubmitted = false
        stagedOverlay = nil
        activeOverlayBuffers = nil
    }

    private func clearPersistentTransientState(
        arena: MetalStateArena,
        shaders: MetalShaderLibrary,
        table: MetalArgumentTable
    ) async throws {
        arena.transient.resetCPUVisible()
        let command = try context.makeCommandBuffer(label: "NumiTissue.reset")
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed("reset")
        }
        encoder.setBuffer(table.buffer, offset: 0, index: 0)
        table.useResources(on: encoder, state: arena.shadow, transient: arena.transient)
        let pipeline = try shaders.pipeline(.resetTransientState)
        encoder.ntDispatch1D(count: 4_096, pipeline: pipeline)
        encoder.endEncoding()
        try await context.awaitCompletion(command)
    }

    private func writeControlInput(_ input: RuntimeInputFrame, to buffer: MTLBuffer) {
        let values = buffer.contents().bindMemory(to: Float.self, capacity: 16)
        for index in 0..<16 { values[index] = 0 }
        for index in 0..<8 { values[index] = input.neuromodulators[index] }
        for index in 0..<8 { values[8 + index] = input.hormones[index] }
    }

    private static func validationMessage(code: UInt32, index: UInt32) -> String {
        switch code {
        case ValidationCode.nonFinite:
            return "Non-finite GPU state at index \(index)"
        case ValidationCode.negativeConcentration:
            return "Negative concentration at index \(index)"
        case ValidationCode.invalidTopology:
            return "Invalid packed topology at index \(index)"
        case ValidationCode.eventOverflow:
            return "GPU event bucket overflow"
        case ValidationCode.voltageBounds:
            return "Membrane voltage outside configured bounds"
        case ValidationCode.positiveCellVolume:
            return "Cell geometry outside configured bounds"
        case ValidationCode.metabolicBounds:
            return "Metabolic or damage state outside configured bounds"
        case ValidationCode.weightBounds:
            return "Synaptic weight outside configured bounds"
        default:
            return "NumiTissue GPU validation code \(code) at index \(index)"
        }
    }
}

private extension MetalEvent {
    var routedEvent: RoutedEvent {
        RoutedEvent(
            arrivalTick: UInt64(arrivalTickLo) | (UInt64(arrivalTickHi) << 32),
            source: UInt64(sourceLo) | (UInt64(sourceHi) << 32),
            destination: UInt64(destinationLo) | (UInt64(destinationHi) << 32),
            amplitude: amplitude,
            kind: RoutedEventKind(rawValue: UInt16(truncatingIfNeeded: kindAndFlags)) ?? .userDefined,
            flags: UInt16(truncatingIfNeeded: kindAndFlags >> 16),
            sequence: sequence
        )
    }
}

private func max(_ values: Int...) -> Int {
    values.max() ?? 0
}
#endif
