import Foundation
import NumiTissueCore
import NumiTissueModels

public enum RuntimeFaultSite: String, Sendable, Hashable, Codable, CaseIterable {
    case beforeLoad
    case afterLoad
    case beforeBeginShadow
    case afterBeginShadow
    case beforePhase
    case afterPhase
    case afterDigestCapture
    case afterShadowInspection
    case afterOutputCollection
    case afterValidation
    case beforeCommit
    case beforeRollback
    case afterRollback
    case afterCommittedExport
}

public enum RuntimeInspectionPerturbation: Sendable, Hashable, Codable {
    case tileActivity(index: Int, delta: Float)
    case cellEnergy(index: Int, delta: Float)
    case compartmentVoltage(index: Int, delta: Float)
    case mechanismState(index: Int, delta: Float)
    case synapseWeight(index: Int, delta: Float)
    case fieldConcentration(index: Int, delta: Float)
    case molecularSpecies(index: Int, delta: Float)
    case pendingEventAmplitude(index: Int, delta: Float)
}

public enum RuntimeOutputPerturbation: Sendable, Hashable, Codable {
    case populationActivity(index: Int, delta: Float)
    case localFieldPotential(index: Int, delta: Float)
    case metabolicDemand(index: Int, delta: Float)
    case uncertainty(delta: Float)
    case plasticityMagnitude(delta: Float)
    case efferentAmplitude(index: Int, delta: Float)
}

public enum RuntimeFaultAction: Sendable, Hashable, Codable {
    case fail(code: String, message: String)
    case injectValidationIssue(RuntimeValidationIssue)
    case corruptDigest(domain: RuntimeComparisonDomain, lane: UInt8, xorMask: UInt64)
    case perturbInspection(RuntimeInspectionPerturbation)
    case perturbOutput(RuntimeOutputPerturbation)
}

public struct RuntimeFaultRule: Sendable, Hashable, Codable {
    public var identifier: String
    public var site: RuntimeFaultSite
    public var transaction: UInt64?
    public var phase: RuntimePhase?
    public var invocation: Int
    public var action: RuntimeFaultAction

    public init(
        identifier: String,
        site: RuntimeFaultSite,
        transaction: UInt64? = nil,
        phase: RuntimePhase? = nil,
        invocation: Int = 1,
        action: RuntimeFaultAction
    ) {
        self.identifier = identifier
        self.site = site
        self.transaction = transaction
        self.phase = phase
        self.invocation = invocation
        self.action = action
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty, invocation > 0 else {
            throw RuntimeFaultError.invalidRule(identifier)
        }
        switch site {
        case .beforePhase, .afterPhase:
            guard phase != nil else { throw RuntimeFaultError.phaseRequired(identifier) }
        default:
            guard phase == nil else { throw RuntimeFaultError.phaseNotAllowed(identifier) }
        }
        switch action {
        case .fail:
            break
        case .injectValidationIssue:
            guard site == .afterValidation else {
                throw RuntimeFaultError.actionNotAllowed(identifier)
            }
        case .corruptDigest:
            guard site == .afterDigestCapture else {
                throw RuntimeFaultError.actionNotAllowed(identifier)
            }
        case .perturbInspection:
            guard site == .afterShadowInspection || site == .afterCommittedExport else {
                throw RuntimeFaultError.actionNotAllowed(identifier)
            }
        case .perturbOutput:
            guard site == .afterOutputCollection else {
                throw RuntimeFaultError.actionNotAllowed(identifier)
            }
        }
        return self
    }
}

public struct RuntimeFaultPlan: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var seed: UInt64
    public var rules: [RuntimeFaultRule]

    public init(
        schemaVersion: UInt32 = 1,
        seed: UInt64 = 0x4641_554C_5453_0001,
        rules: [RuntimeFaultRule]
    ) {
        self.schemaVersion = schemaVersion
        self.seed = seed
        self.rules = rules
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              Set(rules.map(\.identifier)).count == rules.count else {
            throw RuntimeFaultError.invalidPlan
        }
        var result = self
        result.rules = try rules.map { try $0.validated() }.sorted {
            if $0.site.rawValue != $1.site.rawValue {
                return $0.site.rawValue < $1.site.rawValue
            }
            if $0.transaction != $1.transaction {
                return ($0.transaction ?? 0) < ($1.transaction ?? 0)
            }
            if $0.phase?.rawValue != $1.phase?.rawValue {
                return ($0.phase?.rawValue ?? 0) < ($1.phase?.rawValue ?? 0)
            }
            if $0.invocation != $1.invocation { return $0.invocation < $1.invocation }
            return $0.identifier < $1.identifier
        }
        return result
    }
}

public struct RuntimeFaultObservation: Sendable, Hashable, Codable {
    public var ruleIdentifier: String
    public var site: RuntimeFaultSite
    public var transaction: UInt64?
    public var phase: RuntimePhase?
    public var invocation: Int
    public var actionDescription: String

    public init(
        ruleIdentifier: String,
        site: RuntimeFaultSite,
        transaction: UInt64?,
        phase: RuntimePhase?,
        invocation: Int,
        actionDescription: String
    ) {
        self.ruleIdentifier = ruleIdentifier
        self.site = site
        self.transaction = transaction
        self.phase = phase
        self.invocation = invocation
        self.actionDescription = actionDescription
    }
}

private struct RuntimeFaultInvocationKey: Sendable, Hashable {
    var site: RuntimeFaultSite
    var transaction: UInt64?
    var phase: RuntimePhase?
}

/// Transparent backend decorator used by deterministic rollback, failure-path and differential
/// tests. It never mutates a wrapped backend's committed state. Perturbation actions affect only
/// diagnostic snapshots or outputs; execution failures are injected at explicit transaction sites.
public actor FaultInjectingTissueBackend: RuntimePhaseInspectableBackend {
    nonisolated public let name: String
    nonisolated public let capabilities: TissueRuntimeCapabilities
    nonisolated public let numericalProfile: RuntimeNumericalProfile

    private let wrapped: any RuntimePhaseInspectableBackend
    private let plan: RuntimeFaultPlan
    private var invocationCounts: [RuntimeFaultInvocationKey: Int] = [:]
    private var observations: [RuntimeFaultObservation] = []

    public init(
        wrapped: any RuntimePhaseInspectableBackend,
        plan: RuntimeFaultPlan,
        name: String? = nil
    ) throws {
        self.wrapped = wrapped
        self.plan = try plan.validated()
        self.name = name ?? "\(wrapped.name) [fault-injected]"
        self.capabilities = wrapped.capabilities
        self.numericalProfile = wrapped.numericalProfile
    }

    public func load(
        model: CompiledTissueModel,
        initialState: TissueRuntimeState
    ) async throws {
        try trigger(site: .beforeLoad, context: nil, phase: nil)
        try await wrapped.load(model: model, initialState: initialState)
        try trigger(site: .afterLoad, context: nil, phase: nil)
    }

    public func beginShadowStep(
        context: ExecutionContext,
        input: RuntimeInputFrame
    ) async throws {
        try trigger(site: .beforeBeginShadow, context: context, phase: nil)
        try await wrapped.beginShadowStep(context: context, input: input)
        try trigger(site: .afterBeginShadow, context: context, phase: nil)
    }

    public func execute(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws {
        try trigger(site: .beforePhase, context: context, phase: phase)
        try await wrapped.execute(phase: phase, tickRange: tickRange, context: context)
        try trigger(site: .afterPhase, context: context, phase: phase)
    }

    public func captureShadowDigest(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimePhaseDigestSnapshot {
        var result = try await wrapped.captureShadowDigest(
            phase: phase,
            tickRange: tickRange,
            context: context
        )
        for action in actions(site: .afterDigestCapture, context: context, phase: nil) {
            switch action {
            case .corruptDigest(let domain, let lane, let mask):
                corrupt(&result.poolDigests, domain: domain, lane: lane, mask: mask)
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed("afterDigestCapture")
            }
        }
        return result
    }

    public func exportShadowInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimeShadowInspection {
        var result = try await wrapped.exportShadowInspection(
            phase: phase,
            tickRange: tickRange,
            context: context
        )
        for action in actions(site: .afterShadowInspection, context: context, phase: nil) {
            switch action {
            case .perturbInspection(let perturbation):
                try perturb(perturbation, inspection: &result)
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed("afterShadowInspection")
            }
        }
        return result
    }

    public func collectOutput(
        context: ExecutionContext
    ) async throws -> RuntimeOutputFrame {
        var result = try await wrapped.collectOutput(context: context)
        for action in actions(site: .afterOutputCollection, context: context, phase: nil) {
            switch action {
            case .perturbOutput(let perturbation):
                try perturb(perturbation, output: &result)
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed("afterOutputCollection")
            }
        }
        return result
    }

    public func validateShadow(
        context: ExecutionContext
    ) async throws -> [RuntimeValidationIssue] {
        var result = try await wrapped.validateShadow(context: context)
        for action in actions(site: .afterValidation, context: context, phase: nil) {
            switch action {
            case .injectValidationIssue(let issue):
                result.append(issue)
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed("afterValidation")
            }
        }
        return result
    }

    public func commitShadow(context: ExecutionContext) async throws {
        try trigger(site: .beforeCommit, context: context, phase: nil)
        try await wrapped.commitShadow(context: context)
    }

    public func rollbackShadow(context: ExecutionContext) async {
        do {
            try trigger(site: .beforeRollback, context: context, phase: nil)
        } catch {
            observations.append(RuntimeFaultObservation(
                ruleIdentifier: "rollback-precondition",
                site: .beforeRollback,
                transaction: context.transaction.rawValue,
                phase: nil,
                invocation: 0,
                actionDescription: String(describing: error)
            ))
        }
        await wrapped.rollbackShadow(context: context)
        do {
            try trigger(site: .afterRollback, context: context, phase: nil)
        } catch {
            observations.append(RuntimeFaultObservation(
                ruleIdentifier: "rollback-postcondition",
                site: .afterRollback,
                transaction: context.transaction.rawValue,
                phase: nil,
                invocation: 0,
                actionDescription: String(describing: error)
            ))
        }
    }

    public func counters(context: ExecutionContext) async -> RuntimeCounters {
        await wrapped.counters(context: context)
    }

    public func exportCommittedState() async throws -> TissueRuntimeState {
        var result = try await wrapped.exportCommittedState()
        for action in actions(site: .afterCommittedExport, context: nil, phase: nil) {
            switch action {
            case .perturbInspection(let perturbation):
                var inspection = RuntimeShadowInspection(
                    backendName: name,
                    numericalProfile: numericalProfile,
                    transaction: TransactionID(rawValue: 0),
                    phase: .validate,
                    tickRange: result.time.tick..<result.time.tick,
                    state: result,
                    pendingEvents: [],
                    counters: RuntimeCounters()
                )
                try perturb(perturbation, inspection: &inspection)
                result = inspection.state
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed("afterCommittedExport")
            }
        }
        return result
    }

    public func triggeredFaults() -> [RuntimeFaultObservation] { observations }

    public func resetFaultCounters() {
        invocationCounts.removeAll(keepingCapacity: true)
        observations.removeAll(keepingCapacity: true)
    }

    private func trigger(
        site: RuntimeFaultSite,
        context: ExecutionContext?,
        phase: RuntimePhase?
    ) throws {
        for action in actions(site: site, context: context, phase: phase) {
            switch action {
            case .fail(let code, let message):
                throw RuntimeFaultError.injectedFailure(code: code, message: message)
            default:
                throw RuntimeFaultError.actionNotAllowed(site.rawValue)
            }
        }
    }

    private func actions(
        site: RuntimeFaultSite,
        context: ExecutionContext?,
        phase: RuntimePhase?
    ) -> [RuntimeFaultAction] {
        let transaction = context?.transaction.rawValue
        let key = RuntimeFaultInvocationKey(
            site: site,
            transaction: transaction,
            phase: phase
        )
        let invocation = (invocationCounts[key] ?? 0) + 1
        invocationCounts[key] = invocation

        let matching = plan.rules.filter { rule in
            rule.site == site &&
                (rule.transaction == nil || rule.transaction == transaction) &&
                rule.phase == phase &&
                rule.invocation == invocation
        }
        for rule in matching {
            observations.append(RuntimeFaultObservation(
                ruleIdentifier: rule.identifier,
                site: site,
                transaction: transaction,
                phase: phase,
                invocation: invocation,
                actionDescription: String(describing: rule.action)
            ))
        }
        return matching.map(\.action)
    }

    private func corrupt(
        _ digests: inout RuntimePoolDigests,
        domain: RuntimeComparisonDomain,
        lane: UInt8,
        mask: UInt64
    ) {
        func apply(_ source: RuntimeComparisonDigest) -> RuntimeComparisonDigest {
            var value = source
            switch lane & 3 {
            case 0: value.lane0 ^= mask
            case 1: value.lane1 ^= mask
            case 2: value.lane2 ^= mask
            default: value.lane3 ^= mask
            }
            return value
        }
        switch domain {
        case .metadata: digests.metadata = apply(digests.metadata)
        case .tiles: digests.tiles = apply(digests.tiles)
        case .cells: digests.cells = apply(digests.cells)
        case .regulatoryState: digests.regulatoryState = apply(digests.regulatoryState)
        case .segments: digests.segments = apply(digests.segments)
        case .compartments: digests.compartments = apply(digests.compartments)
        case .mechanismState: digests.mechanismState = apply(digests.mechanismState)
        case .synapses: digests.synapses = apply(digests.synapses)
        case .fields: digests.fields = apply(digests.fields)
        case .microdomains: digests.microdomains = apply(digests.microdomains)
        case .molecularSpecies: digests.molecularSpecies = apply(digests.molecularSpecies)
        case .pendingEvents: digests.pendingEvents = apply(digests.pendingEvents)
        case .output, .counters: break
        }
    }

    private func perturb(
        _ perturbation: RuntimeInspectionPerturbation,
        inspection: inout RuntimeShadowInspection
    ) throws {
        switch perturbation {
        case .tileActivity(let index, let delta):
            guard inspection.state.tiles.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.tiles[index].activityScore += delta
        case .cellEnergy(let index, let delta):
            guard inspection.state.cells.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.cells[index].energyReserve += delta
        case .compartmentVoltage(let index, let delta):
            guard inspection.state.compartments.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.compartments[index].voltageMillivolts += delta
        case .mechanismState(let index, let delta):
            guard inspection.state.mechanismState.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.mechanismState[index] += delta
        case .synapseWeight(let index, let delta):
            guard inspection.state.synapses.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.synapses[index].weight += delta
        case .fieldConcentration(let index, let delta):
            guard inspection.state.fields.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.fields[index].concentration += delta
        case .molecularSpecies(let index, let delta):
            guard inspection.state.molecularSpecies.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.state.molecularSpecies[index] += delta
        case .pendingEventAmplitude(let index, let delta):
            guard inspection.pendingEvents.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            inspection.pendingEvents[index].amplitude += delta
        }
    }

    private func perturb(
        _ perturbation: RuntimeOutputPerturbation,
        output: inout RuntimeOutputFrame
    ) throws {
        switch perturbation {
        case .populationActivity(let index, let delta):
            guard output.populationActivity.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            output.populationActivity[index] += delta
        case .localFieldPotential(let index, let delta):
            guard output.localFieldPotentials.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            output.localFieldPotentials[index] += delta
        case .metabolicDemand(let index, let delta):
            guard output.metabolicDemand.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            output.metabolicDemand[index] += delta
        case .uncertainty(let delta):
            output.uncertainty += delta
        case .plasticityMagnitude(let delta):
            output.plasticityMagnitude += delta
        case .efferentAmplitude(let index, let delta):
            guard output.efferentEvents.indices.contains(index) else { throw RuntimeFaultError.invalidPerturbationIndex(index) }
            output.efferentEvents[index].amplitude += delta
        }
    }
}

extension FaultInjectingTissueBackend: InterventionAwareTissueBackend {
    public func stageInterventions(
        _ frame: TissueInterventionFrame,
        context: ExecutionContext
    ) async throws {
        guard let interventionBackend = wrapped as? any InterventionAwareTissueBackend else {
            throw RuntimeFaultError.unsupportedWrappedCapability("interventions")
        }
        try await interventionBackend.stageInterventions(frame, context: context)
    }
}

public enum RuntimeFaultError: Error, Sendable, CustomStringConvertible {
    case invalidPlan
    case invalidRule(String)
    case phaseRequired(String)
    case phaseNotAllowed(String)
    case actionNotAllowed(String)
    case invalidPerturbationIndex(Int)
    case unsupportedWrappedCapability(String)
    case injectedFailure(code: String, message: String)

    public var description: String {
        switch self {
        case .invalidPlan:
            return "Runtime fault plan is invalid"
        case .invalidRule(let identifier):
            return "Runtime fault rule \(identifier) is invalid"
        case .phaseRequired(let identifier):
            return "Runtime fault rule \(identifier) requires a phase"
        case .phaseNotAllowed(let identifier):
            return "Runtime fault rule \(identifier) cannot select a phase at this site"
        case .actionNotAllowed(let identifier):
            return "Runtime fault action is not allowed for \(identifier)"
        case .invalidPerturbationIndex(let index):
            return "Runtime fault perturbation index \(index) is outside the target pool"
        case .unsupportedWrappedCapability(let capability):
            return "Wrapped backend does not support \(capability)"
        case .injectedFailure(let code, let message):
            return "Injected runtime failure [\(code)]: \(message)"
        }
    }
}
