#if canImport(Metal)
import Foundation
import NumiTissueCore
import NumiTissueRuntime

struct PendingMetalFidelityMigration: Sendable {
    var state: TissueRuntimeState
    var plan: FidelityMigrationPlan
}

/// Host-side coordinator for the topology-changing portion of adaptive fidelity. The GPU policy
/// writes desired levels into the shadow cells; this coordinator reconciles those targets with an
/// explicitly staged plan, projects conserved state through `FidelityMigrationEngine`, and keeps
/// template/dormant-synapse history across arena replacements.
final class MetalFidelityMigrationCoordinator: @unchecked Sendable {
    private struct StagedPlan: Sendable {
        var transaction: TransactionID
        var decisions: [FidelityDecision]
    }

    private let engine: FidelityMigrationEngine
    private let validator: RuntimeStateValidator
    private var context: FidelityMigrationContext
    private var staged: StagedPlan?
    private(set) var pending: PendingMetalFidelityMigration?
    private(set) var lastPlan: FidelityMigrationPlan?

    init(
        configuration: FidelityMigrationConfiguration = FidelityMigrationConfiguration(
            templatePolicy: .boundedFallback
        ),
        validationLimits: RuntimeValidationLimits = RuntimeValidationLimits()
    ) {
        self.engine = FidelityMigrationEngine(configuration: configuration)
        self.validator = RuntimeStateValidator(limits: validationLimits)
        self.context = FidelityMigrationContext()
    }

    func stage(_ decisions: [FidelityDecision], transaction: TransactionID) throws {
        staged = StagedPlan(
            transaction: transaction,
            decisions: try decisions.validatedForStaging()
        )
    }

    func assertStagedTransaction(_ transaction: TransactionID) throws {
        guard let staged else { return }
        guard staged.transaction == transaction else {
            throw AdaptiveFidelityBackendError.staleTransaction(
                expected: transaction,
                received: staged.transaction
            )
        }
    }

    func prepare(
        committedTemplate: TissueRuntimeState,
        shadow: TissueRuntimeState,
        execution: ExecutionContext
    ) throws -> PendingMetalFidelityMigration? {
        if let pending { return pending }
        guard committedTemplate.cells.count == shadow.cells.count else {
            throw FidelityMigrationError.capacityExceeded(
                pool: .compartments,
                required: shadow.cells.count,
                limit: committedTemplate.cells.count
            )
        }

        let decisions: [FidelityDecision]
        if let staged {
            guard staged.transaction == execution.transaction else {
                throw AdaptiveFidelityBackendError.staleTransaction(
                    expected: execution.transaction,
                    received: staged.transaction
                )
            }
            decisions = staged.decisions
        } else {
            decisions = automaticDecisions(
                committed: committedTemplate,
                shadow: shadow
            )
        }
        guard !decisions.isEmpty else { return nil }

        // The device policy stores requested levels directly in the packed shadow. Restore every
        // cell to its actual source fidelity first. The migration engine then applies exactly the
        // reconciled decision set and no unrelated device-side request can leak into the commit.
        var source = shadow
        for index in source.cells.indices {
            source.cells[index].fidelity = committedTemplate.cells[index].fidelity
        }
        for decision in decisions {
            guard source.cells.indices.contains(Int(decision.cellIndex)) else {
                throw FidelityMigrationError.invalidCellIndex(decision.cellIndex)
            }
            let committedLevel = committedTemplate.cells[Int(decision.cellIndex)].fidelity
            guard committedLevel == decision.from else {
                throw FidelityMigrationError.staleDecision(
                    cellIndex: decision.cellIndex,
                    expected: decision.from,
                    actual: committedLevel
                )
            }
        }

        var nextContext = context
        let plan = try engine.migrate(
            decisions: decisions,
            state: &source,
            context: &nextContext
        )
        source.time = execution.endTime
        source.epoch = execution.epoch &+ 1
        let issues = validator.validate(source)
        let rejecting = issues.filter { $0.severity == .reject }
        guard rejecting.isEmpty else {
            throw AdaptiveFidelityBackendError.migrationValidationFailed(rejecting)
        }

        context = nextContext
        let value = PendingMetalFidelityMigration(state: source, plan: plan)
        pending = value
        return value
    }

    func commit() {
        if let pending { lastPlan = pending.plan }
        pending = nil
        staged = nil
    }

    func rollback() {
        pending = nil
        staged = nil
    }

    private func automaticDecisions(
        committed: TissueRuntimeState,
        shadow: TissueRuntimeState
    ) -> [FidelityDecision] {
        var result: [FidelityDecision] = []
        result.reserveCapacity(shadow.cells.count / 16)
        for index in shadow.cells.indices {
            let from = committed.cells[index].fidelity
            let to = shadow.cells[index].fidelity
            guard from != to else { continue }
            let cell = shadow.cells[index]
            let tile: RuntimeTileState
            if shadow.tiles.indices.contains(Int(cell.tileIndex)) {
                tile = shadow.tiles[Int(cell.tileIndex)]
            } else {
                tile = RuntimeTileState(
                    id: TileID(rawValue: 0),
                    coordinate: TileCoordinate(x: 0, y: 0, z: 0)
                )
            }
            let activity = max(tile.activityScore, 0)
            let uncertainty = max(tile.uncertaintyScore, 0)
            let damage = max(tile.damageScore, cell.damage)
            let metabolic = max(
                tile.metabolicStress,
                max(cell.oxygenStress, cell.glucoseStress)
            )
            let score = min(
                max(
                    0.30 * activity +
                    0.25 * uncertainty +
                    0.25 * damage +
                    0.20 * metabolic,
                    0
                ),
                1
            )
            var reasonMask: UInt32 = 0
            if activity > 0 { reasonMask |= 1 << 0 }
            if uncertainty > 0 { reasonMask |= 1 << 1 }
            if damage > 0 { reasonMask |= 1 << 2 }
            if metabolic > 0 { reasonMask |= 1 << 3 }
            result.append(
                FidelityDecision(
                    cellIndex: UInt32(index),
                    from: from,
                    to: to,
                    kind: to.rawValue > from.rawValue ? .promote : .demote,
                    score: score,
                    reasonMask: reasonMask
                )
            )
        }
        return result
    }
}
#endif
