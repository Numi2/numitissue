#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

public struct MetalAdaptiveFidelityConfiguration: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var evaluationIntervalTicks: UInt64
    public var maximumRecordedMigrations: Int
    public var migrateAllTiles: Bool

    public init(
        enabled: Bool = true,
        evaluationIntervalTicks: UInt64 = RuntimeCadence.developmentalTicks,
        maximumRecordedMigrations: Int = 256,
        migrateAllTiles: Bool = true
    ) {
        precondition(evaluationIntervalTicks > 0)
        precondition(maximumRecordedMigrations >= 0)
        self.enabled = enabled
        self.evaluationIntervalTicks = evaluationIntervalTicks
        self.maximumRecordedMigrations = maximumRecordedMigrations
        self.migrateAllTiles = migrateAllTiles
    }
}

public enum MetalFidelityReconfigurationStatus: UInt8, Sendable, Hashable, Codable {
    case committed = 0
    case skipped = 1
    case rejected = 2
}

public struct MetalFidelityReconfigurationRecord: Sendable, Hashable, Codable {
    public var transaction: TransactionID
    public var simulationEpoch: UInt64
    public var tick: UInt64
    public var status: MetalFidelityReconfigurationStatus
    public var plan: FidelityMigrationPlan?
    public var oldCommittedBytes: UInt64
    public var newCommittedBytes: UInt64
    public var message: String

    public init(
        transaction: TransactionID,
        simulationEpoch: UInt64,
        tick: UInt64,
        status: MetalFidelityReconfigurationStatus,
        plan: FidelityMigrationPlan? = nil,
        oldCommittedBytes: UInt64 = 0,
        newCommittedBytes: UInt64 = 0,
        message: String = ""
    ) {
        self.transaction = transaction
        self.simulationEpoch = simulationEpoch
        self.tick = tick
        self.status = status
        self.plan = plan
        self.oldCommittedBytes = oldCommittedBytes
        self.newCommittedBytes = newCommittedBytes
        self.message = message
    }
}

/// A production backend wrapper that turns host-side fidelity decisions into real Metal allocation
/// changes. Reconfiguration occurs only after the wrapped backend has committed and no command
/// encoder retains the old heaps. The old backend remains authoritative unless construction and
/// upload of the complete replacement backend succeeds.
public actor MetalAdaptiveTissueBackend: InterventionAwareTissueBackend {
    nonisolated public let name = "NumiTissue Metal Adaptive"
    nonisolated public let capabilities: TissueRuntimeCapabilities

    private let device: MTLDevice
    private let metalOptions: MetalExecutionOptions
    private let molecularProgram: MetalMolecularProgram
    private let fidelityConfiguration: MetalAdaptiveFidelityConfiguration

    private var backend: MetalTissueBackend
    private var compiledModel: CompiledTissueModel?
    private var fidelityController: AdaptiveFidelityRuntimeController
    private var probeWeights: [CellID: Float]
    private var selectedTiles: [UInt32]?
    private var cachedCounters: (transaction: TransactionID, counters: RuntimeCounters)?
    private var migrationRecords: [MetalFidelityReconfigurationRecord]
    private var loaded: Bool

    public init(
        capabilities: TissueRuntimeCapabilities,
        device: MTLDevice? = nil,
        metalOptions: MetalExecutionOptions = MetalExecutionOptions(),
        molecularProgram: MetalMolecularProgram = MetalMolecularProgram(),
        fidelityConfiguration: MetalAdaptiveFidelityConfiguration = MetalAdaptiveFidelityConfiguration(),
        fidelityController: AdaptiveFidelityRuntimeController = AdaptiveFidelityRuntimeController()
    ) throws {
        guard let selectedDevice = device ?? MTLCreateSystemDefaultDevice() else {
            throw MetalRuntimeError.noDevice
        }
        self.capabilities = capabilities
        self.device = selectedDevice
        self.metalOptions = metalOptions
        self.molecularProgram = molecularProgram
        self.fidelityConfiguration = fidelityConfiguration
        self.fidelityController = fidelityController
        self.probeWeights = [:]
        self.selectedTiles = nil
        self.cachedCounters = nil
        self.migrationRecords = []
        self.loaded = false
        self.backend = try MetalTissueBackend(
            capabilities: capabilities,
            device: selectedDevice,
            options: metalOptions,
            molecularProgram: molecularProgram
        )
    }

    public func load(model: CompiledTissueModel, initialState: TissueRuntimeState) async throws {
        guard !loaded else { throw RuntimeExecutionError.alreadyLoaded }
        var candidate = fidelityController
        for index in initialState.cells.indices {
            try candidate.context.templates.capture(
                cellIndex: UInt32(index),
                state: initialState,
                source: "initial-state"
            )
        }
        try await backend.load(model: model, initialState: initialState)
        compiledModel = model
        fidelityController = candidate
        loaded = true
    }

    public func stageInterventions(
        _ frame: TissueInterventionFrame,
        context: ExecutionContext
    ) async throws {
        try await backend.stageInterventions(frame, context: context)
    }

    public func beginShadowStep(
        context: ExecutionContext,
        input: RuntimeInputFrame
    ) async throws {
        cachedCounters = nil
        try await backend.beginShadowStep(context: context, input: input)
    }

    public func execute(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws {
        try await backend.execute(phase: phase, tickRange: tickRange, context: context)
    }

    public func collectOutput(context: ExecutionContext) async throws -> RuntimeOutputFrame {
        try await backend.collectOutput(context: context)
    }

    public func validateShadow(context: ExecutionContext) async throws -> [RuntimeValidationIssue] {
        try await backend.validateShadow(context: context)
    }

    public func commitShadow(context: ExecutionContext) async throws {
        try await backend.commitShadow(context: context)
        var counters = await backend.counters(context: context)
        cachedCounters = (context.transaction, counters)

        guard fidelityConfiguration.enabled,
              crossesBoundary(context.startTime.tick..<context.endTime.tick, cadence: fidelityConfiguration.evaluationIntervalTicks) else {
            return
        }

        guard let model = compiledModel else {
            record(.init(
                transaction: context.transaction,
                simulationEpoch: context.epoch &+ 1,
                tick: context.endTime.tick,
                status: .rejected,
                message: "Compiled model is unavailable at the fidelity boundary"
            ))
            return
        }

        do {
            var migratedState = try await backend.exportCommittedState()
            let authoritativeEpoch = migratedState.epoch
            let oldBytes = Self.estimatedCommittedBytes(migratedState)
            var candidate = fidelityController
            let tiles = migrationTiles(for: migratedState)
            guard var plan = try candidate.evaluateAndMigrate(
                state: &migratedState,
                tileIndices: tiles,
                probeWeights: probeWeights,
                at: context.endTime.tick
            ) else {
                fidelityController = candidate
                record(.init(
                    transaction: context.transaction,
                    simulationEpoch: authoritativeEpoch,
                    tick: context.endTime.tick,
                    status: .skipped,
                    oldCommittedBytes: oldBytes,
                    newCommittedBytes: oldBytes,
                    message: "No cell crossed an adaptive-fidelity hysteresis boundary"
                ))
                return
            }

            // Fidelity is a representation transition inside the already committed simulation
            // epoch. It must not advance the transaction sequence owned by NumiTissueRuntime.
            migratedState.epoch = authoritativeEpoch
            plan.targetEpoch = authoritativeEpoch

            let replacement = try MetalTissueBackend(
                capabilities: capabilities,
                device: device,
                options: metalOptions,
                molecularProgram: molecularProgram
            )
            try await replacement.load(model: model, initialState: migratedState)

            backend = replacement
            fidelityController = candidate
            for decision in plan.decisions {
                switch decision.kind {
                case .promote: counters.promotedEntities &+= 1
                case .demote: counters.demotedEntities &+= 1
                case .retain: break
                }
            }
            cachedCounters = (context.transaction, counters)
            record(.init(
                transaction: context.transaction,
                simulationEpoch: authoritativeEpoch,
                tick: context.endTime.tick,
                status: .committed,
                plan: plan,
                oldCommittedBytes: oldBytes,
                newCommittedBytes: Self.estimatedCommittedBytes(migratedState),
                message: plan.transfer.requiresBufferReallocation
                    ? "Rebuilt and atomically replaced Metal private heaps"
                    : "Repacked and atomically replaced Metal private heaps"
            ))
        } catch {
            // The transaction is already committed in the old backend. Reconfiguration is
            // auxiliary and therefore cannot invalidate or roll back that committed biology.
            record(.init(
                transaction: context.transaction,
                simulationEpoch: context.epoch &+ 1,
                tick: context.endTime.tick,
                status: .rejected,
                message: String(describing: error)
            ))
        }
    }

    public func rollbackShadow(context: ExecutionContext) async {
        cachedCounters = nil
        await backend.rollbackShadow(context: context)
    }

    public func counters(context: ExecutionContext) async -> RuntimeCounters {
        if let cachedCounters, cachedCounters.transaction == context.transaction {
            return cachedCounters.counters
        }
        return await backend.counters(context: context)
    }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        try await backend.exportCommittedState()
    }

    public func setProbeWeight(_ weight: Float, for cellID: CellID) {
        let bounded = min(max(weight, 0), 1)
        if bounded == 0 { probeWeights.removeValue(forKey: cellID) }
        else { probeWeights[cellID] = bounded }
    }

    public func setProbeWeights(_ weights: [CellID: Float]) {
        probeWeights = weights.reduce(into: [:]) { result, item in
            let bounded = min(max(item.value, 0), 1)
            if bounded > 0 { result[item.key] = bounded }
        }
    }

    public func selectMigrationTiles(_ tileIndices: [UInt32]?) {
        selectedTiles = tileIndices.map { Array(Set($0)).sorted() }
    }

    public func registerFidelityTemplate(_ template: FidelityTopologyTemplate) throws {
        var candidate = fidelityController
        try candidate.context.templates.register(template)
        fidelityController = candidate
    }

    public func registerFidelityTemplates(_ templates: [FidelityTopologyTemplate]) throws {
        var candidate = fidelityController
        for template in templates { try candidate.context.templates.register(template) }
        fidelityController = candidate
    }

    public func latestFidelityReconfiguration() -> MetalFidelityReconfigurationRecord? {
        migrationRecords.last
    }

    public func fidelityReconfigurationHistory() -> [MetalFidelityReconfigurationRecord] {
        migrationRecords
    }

    public func clearFidelityReconfigurationHistory() {
        migrationRecords.removeAll(keepingCapacity: true)
    }

    private func migrationTiles(for state: TissueRuntimeState) -> [UInt32] {
        if let selectedTiles {
            return selectedTiles.filter { Int($0) < state.tiles.count }
        }
        if fidelityConfiguration.migrateAllTiles {
            return state.tiles.indices.map(UInt32.init)
        }
        return state.tiles.indices.compactMap { index in
            let tile = state.tiles[index]
            return tile.uncertaintyScore > 0 || tile.damageScore > 0 || tile.metabolicStress > 0
                ? UInt32(index)
                : nil
        }
    }

    private func record(_ value: MetalFidelityReconfigurationRecord) {
        guard fidelityConfiguration.maximumRecordedMigrations > 0 else { return }
        migrationRecords.append(value)
        let overflow = migrationRecords.count - fidelityConfiguration.maximumRecordedMigrations
        if overflow > 0 { migrationRecords.removeFirst(overflow) }
    }

    private func crossesBoundary(_ range: Range<UInt64>, cadence: UInt64) -> Bool {
        guard cadence > 0, !range.isEmpty else { return false }
        return range.lowerBound / cadence != (range.upperBound - 1) / cadence
            || range.upperBound.isMultiple(of: cadence)
    }

    private static func estimatedCommittedBytes(_ state: TissueRuntimeState) -> UInt64 {
        let capacity = state.capacity
        var bytes: UInt64 = 0
        bytes &+= UInt64(max(capacity.tiles, 1) * MemoryLayout<MetalTileState>.stride)
        bytes &+= UInt64(max(capacity.cells, 1) * MemoryLayout<MetalCellState>.stride)
        bytes &+= UInt64(maximum(state.regulatoryState.count, capacity.cells * 32, 1) * MemoryLayout<Float>.stride)
        bytes &+= UInt64(max(capacity.segments, 1) * MemoryLayout<MetalSegmentState>.stride)
        bytes &+= UInt64(max(capacity.compartments, 1) * MemoryLayout<MetalCompartmentState>.stride)
        bytes &+= UInt64(maximum(state.mechanismState.count, capacity.compartments * 16, 1) * MemoryLayout<Float>.stride)
        bytes &+= UInt64(max(capacity.synapses, 1) * MemoryLayout<MetalSynapseState>.stride)
        bytes &+= UInt64(max(capacity.fieldValues, 1) * MemoryLayout<MetalFieldState>.stride)
        bytes &+= UInt64(max(capacity.microdomains, 1) * MemoryLayout<MetalMicrodomainState>.stride)
        bytes &+= UInt64(max(capacity.molecularSpecies, 1) * MemoryLayout<Float>.stride)
        return bytes
    }

    private static func maximum(_ values: Int...) -> Int {
        values.max() ?? 0
    }
}
#endif
