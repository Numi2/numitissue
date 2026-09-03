#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

struct PendingMetalStructuralMigration: Sendable {
    var state: TissueRuntimeState
    var plan: StructuralTopologyPlan
}

final class MetalStructuralTopologyCoordinator: @unchecked Sendable {
    private let engine: StructuralTopologyEngine
    private let validator: RuntimeStateValidator
    private(set) var pending: PendingMetalStructuralMigration?
    private(set) var lastPlan: StructuralTopologyPlan?

    init(
        engine: StructuralTopologyEngine = StructuralTopologyEngine(),
        validationLimits: RuntimeValidationLimits = RuntimeValidationLimits()
    ) {
        self.engine = engine
        validator = RuntimeStateValidator(limits: validationLimits)
    }

    func prepare(
        source: TissueRuntimeState,
        proposals: [StructuralMutationProposal],
        model: CompiledTissueModel,
        execution: ExecutionContext
    ) throws -> PendingMetalStructuralMigration? {
        if let pending { return pending }
        var state = source
        guard let plan = try engine.apply(
            proposals: proposals,
            to: &state,
            model: model,
            transaction: execution.transaction
        ) else {
            return nil
        }
        state.time = execution.endTime
        state.epoch = execution.epoch &+ 1
        let rejecting = validator.validate(state).filter { $0.severity == .reject }
        guard rejecting.isEmpty else {
            throw AdaptiveFidelityBackendError.migrationValidationFailed(rejecting)
        }
        let value = PendingMetalStructuralMigration(state: state, plan: plan)
        pending = value
        return value
    }

    func commit() {
        if let pending { lastPlan = pending.plan }
        pending = nil
    }

    func rollback() {
        pending = nil
    }
}

extension MetalTransientBuffers {
    func structuralMutationProposals() -> [StructuralMutationProposal] {
        let counters = self.counters.contents().load(as: MetalRuntimeCounters.self)
        let count = min(Int(counters.generatedSpikesLo), eventCapacity)
        guard count > 0 else { return [] }
        let events = outgoingEvents.contents().bindMemory(
            to: MetalEvent.self,
            capacity: count
        )
        var proposals: [StructuralMutationProposal] = []
        proposals.reserveCapacity(min(Int(counters.structuralMutations), count))
        for index in 0..<count {
            let event = events[index]
            let eventKind = UInt16(truncatingIfNeeded: event.kindAndFlags)
            guard eventKind == RoutedEventKind.topologyMutation.rawValue else { continue }
            let subtype = UInt16(truncatingIfNeeded: event.kindAndFlags >> 16)
            guard let kind = StructuralMutationKind(rawValue: subtype) else { continue }
            proposals.append(
                StructuralMutationProposal(
                    kind: kind,
                    source: UInt64(event.sourceLo) | (UInt64(event.sourceHi) << 32),
                    destination: UInt64(event.destinationLo) | (UInt64(event.destinationHi) << 32),
                    amplitude: event.amplitude,
                    payload: Float4(event.reserved0, event.reserved1, event.reserved2, 0),
                    sequence: event.sequence
                )
            )
        }
        return proposals
    }
}
#endif
