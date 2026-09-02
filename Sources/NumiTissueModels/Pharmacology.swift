import Foundation
import NumiTissueCore

public enum PharmacologicalTargetKind: String, Sendable, Hashable, Codable {
    case ionChannel
    case receptor
    case transporter
    case enzyme
    case signalingPathway
    case geneProgram
    case metabolicProcess
    case synapticRelease
}

public enum PharmacologicalAction: String, Sendable, Hashable, Codable {
    case agonist
    case partialAgonist
    case antagonist
    case positiveAllostericModulator
    case negativeAllostericModulator
    case inhibitor
    case activator
    case blocker
    case substrate
}

public struct PharmacologicalTarget: Sendable, Hashable, Codable {
    public var identifier: String
    public var kind: PharmacologicalTargetKind
    public var action: PharmacologicalAction
    public var concentration50Molar: Double
    public var hillCoefficient: Double
    public var maximumEffect: Double
    public var associationRatePerMolarSecond: Double?
    public var dissociationRatePerSecond: Double?
    public var expressionSelector: String?
    public var parameterPath: String
    public var effectLatencySeconds: Double
    public var effectHalfLifeSeconds: Double?

    public init(
        identifier: String,
        kind: PharmacologicalTargetKind,
        action: PharmacologicalAction,
        concentration50Molar: Double,
        hillCoefficient: Double = 1,
        maximumEffect: Double,
        associationRatePerMolarSecond: Double? = nil,
        dissociationRatePerSecond: Double? = nil,
        expressionSelector: String? = nil,
        parameterPath: String,
        effectLatencySeconds: Double = 0,
        effectHalfLifeSeconds: Double? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.action = action
        self.concentration50Molar = concentration50Molar
        self.hillCoefficient = hillCoefficient
        self.maximumEffect = maximumEffect
        self.associationRatePerMolarSecond = associationRatePerMolarSecond
        self.dissociationRatePerSecond = dissociationRatePerSecond
        self.expressionSelector = expressionSelector
        self.parameterPath = parameterPath
        self.effectLatencySeconds = effectLatencySeconds
        self.effectHalfLifeSeconds = effectHalfLifeSeconds
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty, !parameterPath.isEmpty else { throw PharmacologyError.invalidTarget(identifier) }
        guard concentration50Molar.isFinite, concentration50Molar > 0 else { throw PharmacologyError.invalidTarget(identifier) }
        guard hillCoefficient.isFinite, hillCoefficient > 0 else { throw PharmacologyError.invalidTarget(identifier) }
        guard maximumEffect.isFinite else { throw PharmacologyError.invalidTarget(identifier) }
        guard effectLatencySeconds.isFinite, effectLatencySeconds >= 0 else { throw PharmacologyError.invalidTarget(identifier) }
        if let halfLife = effectHalfLifeSeconds, (!halfLife.isFinite || halfLife <= 0) { throw PharmacologyError.invalidTarget(identifier) }
        if let associationRatePerMolarSecond, (!associationRatePerMolarSecond.isFinite || associationRatePerMolarSecond < 0) { throw PharmacologyError.invalidTarget(identifier) }
        if let dissociationRatePerSecond, (!dissociationRatePerSecond.isFinite || dissociationRatePerSecond < 0) { throw PharmacologyError.invalidTarget(identifier) }
        return self
    }

    public func equilibriumEffect(at concentrationMolar: Double) -> Double {
        guard concentrationMolar > 0 else { return 0 }
        let numerator = pow(concentrationMolar, hillCoefficient)
        let denominator = pow(concentration50Molar, hillCoefficient) + numerator
        return maximumEffect * numerator / max(denominator, Double.leastNonzeroMagnitude)
    }
}

public struct BloodBrainBarrierModel: Sendable, Hashable, Codable {
    public var unboundPlasmaFraction: Double
    public var passivePermeabilityPerSecond: Double
    public var influxClearancePerSecond: Double
    public var effluxClearancePerSecond: Double
    public var brainBindingRatio: Double
    public var degradationPerSecond: Double

    public init(
        unboundPlasmaFraction: Double = 1,
        passivePermeabilityPerSecond: Double,
        influxClearancePerSecond: Double = 0,
        effluxClearancePerSecond: Double = 0,
        brainBindingRatio: Double = 1,
        degradationPerSecond: Double = 0
    ) {
        self.unboundPlasmaFraction = unboundPlasmaFraction
        self.passivePermeabilityPerSecond = passivePermeabilityPerSecond
        self.influxClearancePerSecond = influxClearancePerSecond
        self.effluxClearancePerSecond = effluxClearancePerSecond
        self.brainBindingRatio = brainBindingRatio
        self.degradationPerSecond = degradationPerSecond
    }

    public func validated() throws -> Self {
        guard unboundPlasmaFraction.isFinite, (0...1).contains(unboundPlasmaFraction) else { throw PharmacologyError.invalidBarrier }
        guard passivePermeabilityPerSecond.isFinite, passivePermeabilityPerSecond >= 0 else { throw PharmacologyError.invalidBarrier }
        guard influxClearancePerSecond.isFinite, influxClearancePerSecond >= 0 else { throw PharmacologyError.invalidBarrier }
        guard effluxClearancePerSecond.isFinite, effluxClearancePerSecond >= 0 else { throw PharmacologyError.invalidBarrier }
        guard brainBindingRatio.isFinite, brainBindingRatio > 0 else { throw PharmacologyError.invalidBarrier }
        guard degradationPerSecond.isFinite, degradationPerSecond >= 0 else { throw PharmacologyError.invalidBarrier }
        return self
    }
}

public struct TwoCompartmentPKModel: Sendable, Hashable, Codable {
    public var centralVolumeLiters: Double
    public var peripheralVolumeLiters: Double
    public var systemicClearanceLitersPerSecond: Double
    public var intercompartmentalClearanceLitersPerSecond: Double
    public var absorptionRatePerSecond: Double
    public var bioavailability: Double
    public var barrier: BloodBrainBarrierModel

    public init(
        centralVolumeLiters: Double,
        peripheralVolumeLiters: Double,
        systemicClearanceLitersPerSecond: Double,
        intercompartmentalClearanceLitersPerSecond: Double,
        absorptionRatePerSecond: Double = 0,
        bioavailability: Double = 1,
        barrier: BloodBrainBarrierModel
    ) {
        self.centralVolumeLiters = centralVolumeLiters
        self.peripheralVolumeLiters = peripheralVolumeLiters
        self.systemicClearanceLitersPerSecond = systemicClearanceLitersPerSecond
        self.intercompartmentalClearanceLitersPerSecond = intercompartmentalClearanceLitersPerSecond
        self.absorptionRatePerSecond = absorptionRatePerSecond
        self.bioavailability = bioavailability
        self.barrier = barrier
    }

    public func validated() throws -> Self {
        guard centralVolumeLiters.isFinite, centralVolumeLiters > 0 else { throw PharmacologyError.invalidPK }
        guard peripheralVolumeLiters.isFinite, peripheralVolumeLiters > 0 else { throw PharmacologyError.invalidPK }
        guard systemicClearanceLitersPerSecond.isFinite, systemicClearanceLitersPerSecond >= 0 else { throw PharmacologyError.invalidPK }
        guard intercompartmentalClearanceLitersPerSecond.isFinite, intercompartmentalClearanceLitersPerSecond >= 0 else { throw PharmacologyError.invalidPK }
        guard absorptionRatePerSecond.isFinite, absorptionRatePerSecond >= 0 else { throw PharmacologyError.invalidPK }
        guard bioavailability.isFinite, (0...1).contains(bioavailability) else { throw PharmacologyError.invalidPK }
        _ = try barrier.validated()
        return self
    }
}

public struct CompoundDefinition: Sendable, Hashable, Codable {
    public var identifier: String
    public var displayName: String
    public var molecularWeightGramsPerMole: Double
    public var pk: TwoCompartmentPKModel
    public var targets: [PharmacologicalTarget]
    public var metadata: [String: String]

    public init(identifier: String, displayName: String, molecularWeightGramsPerMole: Double, pk: TwoCompartmentPKModel, targets: [PharmacologicalTarget], metadata: [String: String] = [:]) {
        self.identifier = identifier
        self.displayName = displayName
        self.molecularWeightGramsPerMole = molecularWeightGramsPerMole
        self.pk = pk
        self.targets = targets
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty, !displayName.isEmpty else { throw PharmacologyError.invalidCompound(identifier) }
        guard molecularWeightGramsPerMole.isFinite, molecularWeightGramsPerMole > 0 else { throw PharmacologyError.invalidCompound(identifier) }
        _ = try pk.validated()
        guard Set(targets.map(\.identifier)).count == targets.count else { throw PharmacologyError.duplicateTarget(identifier) }
        for target in targets { _ = try target.validated() }
        return self
    }
}

public enum AdministrationRoute: String, Sendable, Hashable, Codable {
    case intravenousBolus
    case intravenousInfusion
    case oral
    case intramuscular
    case subcutaneous
    case intracerebral
    case bathApplication
}

public struct CompoundDose: Sendable, Hashable, Codable {
    public var compoundID: String
    public var route: AdministrationRoute
    public var startSeconds: Double
    public var amountGrams: Double
    public var durationSeconds: Double

    public init(compoundID: String, route: AdministrationRoute, startSeconds: Double, amountGrams: Double, durationSeconds: Double = 0) {
        self.compoundID = compoundID
        self.route = route
        self.startSeconds = startSeconds
        self.amountGrams = amountGrams
        self.durationSeconds = durationSeconds
    }

    public func validated() throws -> Self {
        guard !compoundID.isEmpty, startSeconds.isFinite, startSeconds >= 0, amountGrams.isFinite, amountGrams >= 0, durationSeconds.isFinite, durationSeconds >= 0 else {
            throw PharmacologyError.invalidDose(compoundID)
        }
        if route == .intravenousInfusion && durationSeconds <= 0 { throw PharmacologyError.invalidDose(compoundID) }
        return self
    }
}

public struct PharmacokineticState: Sendable, Hashable, Codable {
    public var gutMoles: Double
    public var centralMoles: Double
    public var peripheralMoles: Double
    public var unboundBrainMoles: Double
    public var effectByTarget: [String: Double]

    public init(gutMoles: Double = 0, centralMoles: Double = 0, peripheralMoles: Double = 0, unboundBrainMoles: Double = 0, effectByTarget: [String: Double] = [:]) {
        self.gutMoles = gutMoles
        self.centralMoles = centralMoles
        self.peripheralMoles = peripheralMoles
        self.unboundBrainMoles = unboundBrainMoles
        self.effectByTarget = effectByTarget
    }
}

public struct PharmacodynamicEffect: Sendable, Hashable, Codable {
    public var compoundID: String
    public var targetID: String
    public var parameterPath: String
    public var action: PharmacologicalAction
    public var fractionalEffect: Double
    public var occupancy: Double
    public var brainConcentrationMolar: Double
    public var selector: String?

    public init(compoundID: String, targetID: String, parameterPath: String, action: PharmacologicalAction, fractionalEffect: Double, occupancy: Double, brainConcentrationMolar: Double, selector: String? = nil) {
        self.compoundID = compoundID
        self.targetID = targetID
        self.parameterPath = parameterPath
        self.action = action
        self.fractionalEffect = fractionalEffect
        self.occupancy = occupancy
        self.brainConcentrationMolar = brainConcentrationMolar
        self.selector = selector
    }
}

public struct PharmacologyStepResult: Sendable, Hashable, Codable {
    public var state: PharmacokineticState
    public var plasmaConcentrationMolar: Double
    public var brainConcentrationMolar: Double
    public var effects: [PharmacodynamicEffect]

    public init(state: PharmacokineticState, plasmaConcentrationMolar: Double, brainConcentrationMolar: Double, effects: [PharmacodynamicEffect]) {
        self.state = state
        self.plasmaConcentrationMolar = plasmaConcentrationMolar
        self.brainConcentrationMolar = brainConcentrationMolar
        self.effects = effects
    }
}

public enum PharmacologySolver {
    /// Positivity-preserving RK2 with internal substeps. Amounts are represented in moles and all
    /// clearances are converted to first-order transfer rates by the relevant compartment volume.
    public static func advance(
        compound: CompoundDefinition,
        state initial: PharmacokineticState,
        doses: [CompoundDose],
        from startSeconds: Double,
        through endSeconds: Double,
        brainExtracellularVolumeLiters: Double,
        maximumStepSeconds: Double = 0.1
    ) throws -> PharmacologyStepResult {
        let compound = try compound.validated()
        guard startSeconds.isFinite, endSeconds.isFinite, endSeconds >= startSeconds, brainExtracellularVolumeLiters.isFinite, brainExtracellularVolumeLiters > 0, maximumStepSeconds > 0 else {
            throw PharmacologyError.invalidIntegrationRange
        }
        let relevantDoses = try doses.filter { $0.compoundID == compound.identifier }.map { try $0.validated() }
        var state = initial
        var time = startSeconds
        while time < endSeconds {
            let dt = min(maximumStepSeconds, endSeconds - time)
            applyBoluses(doses: relevantDoses, compound: compound, previousTime: time, nextTime: time + dt, state: &state)
            let k1 = derivative(compound: compound, state: state, doses: relevantDoses, time: time, brainVolumeLiters: brainExtracellularVolumeLiters)
            let midpoint = clipped(add(state, k1, scale: 0.5 * dt))
            let k2 = derivative(compound: compound, state: midpoint, doses: relevantDoses, time: time + 0.5 * dt, brainVolumeLiters: brainExtracellularVolumeLiters)
            state = clipped(add(state, k2, scale: dt))
            time += dt
        }

        let centralConcentration = state.centralMoles / compound.pk.centralVolumeLiters
        let brainConcentration = state.unboundBrainMoles / brainExtracellularVolumeLiters
        var effects: [PharmacodynamicEffect] = []
        for target in compound.targets {
            let equilibrium = target.equilibriumEffect(at: brainConcentration)
            let occupancy = target.maximumEffect == 0 ? 0 : min(max(equilibrium / target.maximumEffect, 0), 1)
            let previous = state.effectByTarget[target.identifier] ?? 0
            let targetEffect: Double
            if let halfLife = target.effectHalfLifeSeconds {
                let alpha = 1 - exp(-log(2) * max(endSeconds - startSeconds, 0) / halfLife)
                targetEffect = previous + alpha * (equilibrium - previous)
            } else { targetEffect = equilibrium }
            state.effectByTarget[target.identifier] = targetEffect
            effects.append(PharmacodynamicEffect(
                compoundID: compound.identifier,
                targetID: target.identifier,
                parameterPath: target.parameterPath,
                action: target.action,
                fractionalEffect: targetEffect,
                occupancy: occupancy,
                brainConcentrationMolar: brainConcentration,
                selector: target.expressionSelector
            ))
        }
        return PharmacologyStepResult(state: state, plasmaConcentrationMolar: centralConcentration, brainConcentrationMolar: brainConcentration, effects: effects)
    }

    private struct Derivative {
        var gut: Double
        var central: Double
        var peripheral: Double
        var brain: Double
    }

    private static func derivative(compound: CompoundDefinition, state: PharmacokineticState, doses: [CompoundDose], time: Double, brainVolumeLiters: Double) -> Derivative {
        let pk = compound.pk
        let centralConcentration = state.centralMoles / pk.centralVolumeLiters
        let peripheralConcentration = state.peripheralMoles / pk.peripheralVolumeLiters
        let brainConcentration = state.unboundBrainMoles / brainVolumeLiters
        let absorption = pk.absorptionRatePerSecond * state.gutMoles
        let systemicElimination = pk.systemicClearanceLitersPerSecond * centralConcentration
        let exchange = pk.intercompartmentalClearanceLitersPerSecond * (centralConcentration - peripheralConcentration)
        let unboundPlasma = centralConcentration * pk.barrier.unboundPlasmaFraction
        let brainInflux = (pk.barrier.passivePermeabilityPerSecond + pk.barrier.influxClearancePerSecond) * unboundPlasma * brainVolumeLiters
        let brainEfflux = pk.barrier.effluxClearancePerSecond * brainConcentration * brainVolumeLiters
        let brainDegradation = pk.barrier.degradationPerSecond * state.unboundBrainMoles
        let infusion = infusionMolesPerSecond(doses: doses, compound: compound, time: time)
        return Derivative(
            gut: -absorption,
            central: pk.bioavailability * absorption + infusion - systemicElimination - exchange - brainInflux + brainEfflux,
            peripheral: exchange,
            brain: brainInflux - brainEfflux - brainDegradation
        )
    }

    private static func infusionMolesPerSecond(doses: [CompoundDose], compound: CompoundDefinition, time: Double) -> Double {
        doses.reduce(0) { total, dose in
            guard dose.route == .intravenousInfusion, time >= dose.startSeconds, time < dose.startSeconds + dose.durationSeconds else { return total }
            return total + dose.amountGrams / compound.molecularWeightGramsPerMole / dose.durationSeconds
        }
    }

    private static func applyBoluses(doses: [CompoundDose], compound: CompoundDefinition, previousTime: Double, nextTime: Double, state: inout PharmacokineticState) {
        for dose in doses where dose.startSeconds >= previousTime && dose.startSeconds < nextTime && dose.route != .intravenousInfusion {
            let moles = dose.amountGrams / compound.molecularWeightGramsPerMole
            switch dose.route {
            case .intravenousBolus: state.centralMoles += moles
            case .oral, .intramuscular, .subcutaneous: state.gutMoles += moles
            case .intracerebral, .bathApplication: state.unboundBrainMoles += moles
            case .intravenousInfusion: break
            }
        }
    }

    private static func add(_ state: PharmacokineticState, _ derivative: Derivative, scale: Double) -> PharmacokineticState {
        var result = state
        result.gutMoles += scale * derivative.gut
        result.centralMoles += scale * derivative.central
        result.peripheralMoles += scale * derivative.peripheral
        result.unboundBrainMoles += scale * derivative.brain
        return result
    }

    private static func clipped(_ state: PharmacokineticState) -> PharmacokineticState {
        var result = state
        result.gutMoles = max(result.gutMoles, 0)
        result.centralMoles = max(result.centralMoles, 0)
        result.peripheralMoles = max(result.peripheralMoles, 0)
        result.unboundBrainMoles = max(result.unboundBrainMoles, 0)
        return result
    }
}

public struct ToxicityEndpoint: Sendable, Hashable, Codable {
    public var identifier: String
    public var signalPath: String
    public var threshold: Double
    public var slope: Double
    public var exposureHalfLifeSeconds: Double
    public var weight: Double

    public init(identifier: String, signalPath: String, threshold: Double, slope: Double, exposureHalfLifeSeconds: Double, weight: Double = 1) {
        self.identifier = identifier
        self.signalPath = signalPath
        self.threshold = threshold
        self.slope = slope
        self.exposureHalfLifeSeconds = exposureHalfLifeSeconds
        self.weight = weight
    }

    public func instantaneousHazard(signal: Double) -> Double {
        let z = slope * (signal - threshold)
        return 1 / (1 + exp(-min(max(z, -60), 60)))
    }
}

public enum PharmacologyError: Error, Sendable, CustomStringConvertible {
    case invalidTarget(String)
    case invalidBarrier
    case invalidPK
    case invalidCompound(String)
    case duplicateTarget(String)
    case invalidDose(String)
    case invalidIntegrationRange

    public var description: String {
        switch self {
        case .invalidTarget(let value): return "Invalid pharmacological target \(value)"
        case .invalidBarrier: return "Invalid blood-brain barrier model"
        case .invalidPK: return "Invalid pharmacokinetic model"
        case .invalidCompound(let value): return "Invalid compound \(value)"
        case .duplicateTarget(let value): return "Compound \(value) contains duplicate targets"
        case .invalidDose(let value): return "Invalid dose for compound \(value)"
        case .invalidIntegrationRange: return "Invalid pharmacology integration range"
        }
    }
}
