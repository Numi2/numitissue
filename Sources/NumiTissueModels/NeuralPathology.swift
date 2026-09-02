import Foundation

public enum NeuralPathologyKind: String, Sendable, Hashable, Codable, CaseIterable {
    case ischemia
    case traumaticAxonalInjury
    case excitotoxicity
    case neuroinflammation
    case demyelination
    case proteinAggregation
    case channelopathy
    case metabolicFailure
}

public struct NeuralPathologyDrivers: Sendable, Hashable, Codable {
    public var perfusionFraction: Double
    public var oxygenFraction: Double
    public var glucoseFraction: Double
    public var excitatoryDrive: Double
    public var extracellularGlutamateFraction: Double
    public var extracellularPotassiumFraction: Double
    public var mechanicalStrain: Double
    public var mechanicalStrainRatePerSecond: Double
    public var inflammatorySignal: Double
    public var proteostasisStress: Double
    public var temperatureCelsius: Double
    public var toxinSignal: Double

    public init(
        perfusionFraction: Double = 1,
        oxygenFraction: Double = 1,
        glucoseFraction: Double = 1,
        excitatoryDrive: Double = 0,
        extracellularGlutamateFraction: Double = 0,
        extracellularPotassiumFraction: Double = 0,
        mechanicalStrain: Double = 0,
        mechanicalStrainRatePerSecond: Double = 0,
        inflammatorySignal: Double = 0,
        proteostasisStress: Double = 0,
        temperatureCelsius: Double = 37,
        toxinSignal: Double = 0
    ) {
        self.perfusionFraction = perfusionFraction
        self.oxygenFraction = oxygenFraction
        self.glucoseFraction = glucoseFraction
        self.excitatoryDrive = excitatoryDrive
        self.extracellularGlutamateFraction = extracellularGlutamateFraction
        self.extracellularPotassiumFraction = extracellularPotassiumFraction
        self.mechanicalStrain = mechanicalStrain
        self.mechanicalStrainRatePerSecond = mechanicalStrainRatePerSecond
        self.inflammatorySignal = inflammatorySignal
        self.proteostasisStress = proteostasisStress
        self.temperatureCelsius = temperatureCelsius
        self.toxinSignal = toxinSignal
    }

    public func validated() throws -> Self {
        let finite = [
            perfusionFraction,
            oxygenFraction,
            glucoseFraction,
            excitatoryDrive,
            extracellularGlutamateFraction,
            extracellularPotassiumFraction,
            mechanicalStrain,
            mechanicalStrainRatePerSecond,
            inflammatorySignal,
            proteostasisStress,
            temperatureCelsius,
            toxinSignal
        ].allSatisfy(\.isFinite)
        guard finite,
              perfusionFraction >= 0,
              oxygenFraction >= 0,
              glucoseFraction >= 0,
              excitatoryDrive >= 0,
              extracellularGlutamateFraction >= 0,
              extracellularPotassiumFraction >= 0,
              mechanicalStrain >= 0,
              inflammatorySignal >= 0,
              proteostasisStress >= 0,
              toxinSignal >= 0 else {
            throw NeuralPathologyError.invalidDrivers
        }
        return self
    }
}

public struct NeuralPathologyParameters: Sendable, Hashable, Codable {
    public var basalEnergyDemandPerSecond: Double
    public var activityEnergyDemandPerSecond: Double
    public var atpRecoveryPerSecond: Double
    public var atpFailureThreshold: Double
    public var glutamateClearancePerSecond: Double
    public var glutamateReleasePerSecond: Double
    public var calciumRecoveryPerSecond: Double
    public var calciumInfluxPerSecond: Double
    public var oxidativeRecoveryPerSecond: Double
    public var oxidativeGenerationPerSecond: Double
    public var membraneRepairPerSecond: Double
    public var membraneDamagePerSecond: Double
    public var axonRepairPerSecond: Double
    public var axonDamagePerSecond: Double
    public var myelinRepairPerSecond: Double
    public var myelinDamagePerSecond: Double
    public var inflammationResolutionPerSecond: Double
    public var inflammationActivationPerSecond: Double
    public var aggregateClearancePerSecond: Double
    public var aggregateFormationPerSecond: Double
    public var viabilityRepairPerSecond: Double
    public var viabilityLossPerSecond: Double
    public var strainThreshold: Double
    public var strainRateThresholdPerSecond: Double
    public var hyperthermiaThresholdCelsius: Double
    public var hypothermiaThresholdCelsius: Double
    public var maximumSubstepSeconds: Double

    public init(
        basalEnergyDemandPerSecond: Double = 0.020,
        activityEnergyDemandPerSecond: Double = 0.060,
        atpRecoveryPerSecond: Double = 0.080,
        atpFailureThreshold: Double = 0.35,
        glutamateClearancePerSecond: Double = 0.50,
        glutamateReleasePerSecond: Double = 0.25,
        calciumRecoveryPerSecond: Double = 0.20,
        calciumInfluxPerSecond: Double = 0.30,
        oxidativeRecoveryPerSecond: Double = 0.030,
        oxidativeGenerationPerSecond: Double = 0.080,
        membraneRepairPerSecond: Double = 0.004,
        membraneDamagePerSecond: Double = 0.080,
        axonRepairPerSecond: Double = 0.0005,
        axonDamagePerSecond: Double = 0.060,
        myelinRepairPerSecond: Double = 0.0002,
        myelinDamagePerSecond: Double = 0.008,
        inflammationResolutionPerSecond: Double = 0.002,
        inflammationActivationPerSecond: Double = 0.020,
        aggregateClearancePerSecond: Double = 0.00005,
        aggregateFormationPerSecond: Double = 0.0002,
        viabilityRepairPerSecond: Double = 0.00001,
        viabilityLossPerSecond: Double = 0.010,
        strainThreshold: Double = 0.10,
        strainRateThresholdPerSecond: Double = 10,
        hyperthermiaThresholdCelsius: Double = 40,
        hypothermiaThresholdCelsius: Double = 30,
        maximumSubstepSeconds: Double = 0.050
    ) {
        self.basalEnergyDemandPerSecond = basalEnergyDemandPerSecond
        self.activityEnergyDemandPerSecond = activityEnergyDemandPerSecond
        self.atpRecoveryPerSecond = atpRecoveryPerSecond
        self.atpFailureThreshold = atpFailureThreshold
        self.glutamateClearancePerSecond = glutamateClearancePerSecond
        self.glutamateReleasePerSecond = glutamateReleasePerSecond
        self.calciumRecoveryPerSecond = calciumRecoveryPerSecond
        self.calciumInfluxPerSecond = calciumInfluxPerSecond
        self.oxidativeRecoveryPerSecond = oxidativeRecoveryPerSecond
        self.oxidativeGenerationPerSecond = oxidativeGenerationPerSecond
        self.membraneRepairPerSecond = membraneRepairPerSecond
        self.membraneDamagePerSecond = membraneDamagePerSecond
        self.axonRepairPerSecond = axonRepairPerSecond
        self.axonDamagePerSecond = axonDamagePerSecond
        self.myelinRepairPerSecond = myelinRepairPerSecond
        self.myelinDamagePerSecond = myelinDamagePerSecond
        self.inflammationResolutionPerSecond = inflammationResolutionPerSecond
        self.inflammationActivationPerSecond = inflammationActivationPerSecond
        self.aggregateClearancePerSecond = aggregateClearancePerSecond
        self.aggregateFormationPerSecond = aggregateFormationPerSecond
        self.viabilityRepairPerSecond = viabilityRepairPerSecond
        self.viabilityLossPerSecond = viabilityLossPerSecond
        self.strainThreshold = strainThreshold
        self.strainRateThresholdPerSecond = strainRateThresholdPerSecond
        self.hyperthermiaThresholdCelsius = hyperthermiaThresholdCelsius
        self.hypothermiaThresholdCelsius = hypothermiaThresholdCelsius
        self.maximumSubstepSeconds = maximumSubstepSeconds
    }

    public func validated() throws -> Self {
        let rates = [
            basalEnergyDemandPerSecond,
            activityEnergyDemandPerSecond,
            atpRecoveryPerSecond,
            glutamateClearancePerSecond,
            glutamateReleasePerSecond,
            calciumRecoveryPerSecond,
            calciumInfluxPerSecond,
            oxidativeRecoveryPerSecond,
            oxidativeGenerationPerSecond,
            membraneRepairPerSecond,
            membraneDamagePerSecond,
            axonRepairPerSecond,
            axonDamagePerSecond,
            myelinRepairPerSecond,
            myelinDamagePerSecond,
            inflammationResolutionPerSecond,
            inflammationActivationPerSecond,
            aggregateClearancePerSecond,
            aggregateFormationPerSecond,
            viabilityRepairPerSecond,
            viabilityLossPerSecond
        ]
        guard rates.allSatisfy({ $0.isFinite && $0 >= 0 }),
              atpFailureThreshold.isFinite,
              (0...1).contains(atpFailureThreshold),
              strainThreshold.isFinite,
              strainThreshold >= 0,
              strainRateThresholdPerSecond.isFinite,
              strainRateThresholdPerSecond >= 0,
              hyperthermiaThresholdCelsius.isFinite,
              hypothermiaThresholdCelsius.isFinite,
              hyperthermiaThresholdCelsius > hypothermiaThresholdCelsius,
              maximumSubstepSeconds.isFinite,
              maximumSubstepSeconds > 0 else {
            throw NeuralPathologyError.invalidParameters
        }
        return self
    }
}

public struct NeuralPathologyState: Sendable, Hashable, Codable {
    public var atpFraction: Double
    public var extracellularGlutamateBurden: Double
    public var calciumOverload: Double
    public var oxidativeBurden: Double
    public var membraneIntegrity: Double
    public var axonIntegrity: Double
    public var myelinIntegrity: Double
    public var inflammatoryActivation: Double
    public var aggregateBurden: Double
    public var viability: Double
    public var cumulativeHazard: Double
    public var elapsedSeconds: Double

    public init(
        atpFraction: Double = 1,
        extracellularGlutamateBurden: Double = 0,
        calciumOverload: Double = 0,
        oxidativeBurden: Double = 0,
        membraneIntegrity: Double = 1,
        axonIntegrity: Double = 1,
        myelinIntegrity: Double = 1,
        inflammatoryActivation: Double = 0,
        aggregateBurden: Double = 0,
        viability: Double = 1,
        cumulativeHazard: Double = 0,
        elapsedSeconds: Double = 0
    ) {
        self.atpFraction = atpFraction
        self.extracellularGlutamateBurden = extracellularGlutamateBurden
        self.calciumOverload = calciumOverload
        self.oxidativeBurden = oxidativeBurden
        self.membraneIntegrity = membraneIntegrity
        self.axonIntegrity = axonIntegrity
        self.myelinIntegrity = myelinIntegrity
        self.inflammatoryActivation = inflammatoryActivation
        self.aggregateBurden = aggregateBurden
        self.viability = viability
        self.cumulativeHazard = cumulativeHazard
        self.elapsedSeconds = elapsedSeconds
    }

    public func validated() throws -> Self {
        let bounded = [
            atpFraction,
            membraneIntegrity,
            axonIntegrity,
            myelinIntegrity,
            viability
        ].allSatisfy({ $0.isFinite && (0...1).contains($0) })
        let nonnegative = [
            extracellularGlutamateBurden,
            calciumOverload,
            oxidativeBurden,
            inflammatoryActivation,
            aggregateBurden,
            cumulativeHazard,
            elapsedSeconds
        ].allSatisfy({ $0.isFinite && $0 >= 0 })
        guard bounded, nonnegative else { throw NeuralPathologyError.invalidState }
        return self
    }
}

public enum NeuralPathologyEffectChannel: String, Sendable, Hashable, Codable, CaseIterable {
    case energyReserve
    case membraneLeak
    case firingThresholdShift
    case sodiumConductance
    case potassiumConductance
    case calciumConductance
    case excitatorySynapticStrength
    case inhibitorySynapticStrength
    case synapticReleaseProbability
    case conductionVelocity
    case extracellularPotassium
    case extracellularGlutamate
    case oxygenDemand
    case glucoseDemand
    case inflammatorySignal
    case cellDamage
    case apoptosisHazard
    case aggregateBurden
}

public struct NeuralPathologyEffect: Sendable, Hashable, Codable {
    public var channel: NeuralPathologyEffectChannel
    public var value: Double
    public var isMultiplier: Bool
    public var sourceKinds: Set<NeuralPathologyKind>

    public init(
        channel: NeuralPathologyEffectChannel,
        value: Double,
        isMultiplier: Bool,
        sourceKinds: Set<NeuralPathologyKind>
    ) {
        self.channel = channel
        self.value = value
        self.isMultiplier = isMultiplier
        self.sourceKinds = sourceKinds
    }
}

public struct NeuralPathologyStepResult: Sendable, Hashable, Codable {
    public var state: NeuralPathologyState
    public var activeKinds: Set<NeuralPathologyKind>
    public var effects: [NeuralPathologyEffect]
    public var instantaneousHazardPerSecond: Double

    public init(
        state: NeuralPathologyState,
        activeKinds: Set<NeuralPathologyKind>,
        effects: [NeuralPathologyEffect],
        instantaneousHazardPerSecond: Double
    ) {
        self.state = state
        self.activeKinds = activeKinds
        self.effects = effects
        self.instantaneousHazardPerSecond = instantaneousHazardPerSecond
    }
}

public enum NeuralPathologySolver {
    public static func advance(
        state initialState: NeuralPathologyState,
        drivers sourceDrivers: NeuralPathologyDrivers,
        parameters sourceParameters: NeuralPathologyParameters = NeuralPathologyParameters(),
        dtSeconds: Double
    ) throws -> NeuralPathologyStepResult {
        var state = try initialState.validated()
        let drivers = try sourceDrivers.validated()
        let parameters = try sourceParameters.validated()
        guard dtSeconds.isFinite, dtSeconds >= 0 else {
            throw NeuralPathologyError.invalidTimeStep
        }
        guard dtSeconds > 0 else {
            return result(state: state, drivers: drivers, parameters: parameters)
        }

        var remaining = dtSeconds
        while remaining > 0 {
            let dt = min(remaining, parameters.maximumSubstepSeconds)
            integrate(
                state: &state,
                drivers: drivers,
                parameters: parameters,
                dt: dt
            )
            remaining -= dt
        }
        return result(state: try state.validated(), drivers: drivers, parameters: parameters)
    }

    private static func integrate(
        state: inout NeuralPathologyState,
        drivers: NeuralPathologyDrivers,
        parameters: NeuralPathologyParameters,
        dt: Double
    ) {
        let perfusion = saturate(drivers.perfusionFraction)
        let oxygen = saturate(drivers.oxygenFraction)
        let glucose = saturate(drivers.glucoseFraction)
        let energySupply = perfusion * min(oxygen, glucose)
        let energyDemand = parameters.basalEnergyDemandPerSecond
            + parameters.activityEnergyDemandPerSecond * saturate(drivers.excitatoryDrive)
        let thermalStress = thermalStressValue(
            temperature: drivers.temperatureCelsius,
            parameters: parameters
        )
        let desiredATP = saturate(energySupply / max(energySupply + energyDemand + thermalStress, 1e-12))
        state.atpFraction = relax(
            current: state.atpFraction,
            target: desiredATP,
            rate: parameters.atpRecoveryPerSecond + energyDemand,
            dt: dt
        )

        let atpFailure = saturate(
            (parameters.atpFailureThreshold - state.atpFraction)
                / max(parameters.atpFailureThreshold, 1e-9)
        )
        let glutamateTarget = max(
            drivers.extracellularGlutamateFraction
                + parameters.glutamateReleasePerSecond
                    * (atpFailure + saturate(drivers.excitatoryDrive)),
            0
        )
        state.extracellularGlutamateBurden = relax(
            current: state.extracellularGlutamateBurden,
            target: glutamateTarget,
            rate: parameters.glutamateClearancePerSecond,
            dt: dt
        )

        let excitotoxicDrive = saturate(
            state.extracellularGlutamateBurden
                + drivers.extracellularPotassiumFraction
                + drivers.excitatoryDrive
        )
        let calciumTarget = max(
            parameters.calciumInfluxPerSecond
                * (excitotoxicDrive + atpFailure + (1 - state.membraneIntegrity)),
            0
        )
        state.calciumOverload = relax(
            current: state.calciumOverload,
            target: calciumTarget,
            rate: parameters.calciumRecoveryPerSecond,
            dt: dt
        )

        let oxidativeTarget = max(
            parameters.oxidativeGenerationPerSecond
                * (state.calciumOverload + atpFailure + thermalStress + drivers.toxinSignal),
            0
        )
        state.oxidativeBurden = relax(
            current: state.oxidativeBurden,
            target: oxidativeTarget,
            rate: parameters.oxidativeRecoveryPerSecond,
            dt: dt
        )

        let strainExcess = saturate(
            (drivers.mechanicalStrain - parameters.strainThreshold)
                / max(parameters.strainThreshold, 1e-9)
        )
        let strainRateExcess = saturate(
            (abs(drivers.mechanicalStrainRatePerSecond) - parameters.strainRateThresholdPerSecond)
                / max(parameters.strainRateThresholdPerSecond, 1e-9)
        )
        let mechanicalInjury = max(strainExcess, strainRateExcess)
        let membraneDamageDrive = saturate(
            mechanicalInjury
                + state.calciumOverload
                + state.oxidativeBurden
                + drivers.toxinSignal
        )
        state.membraneIntegrity = boundedIntegrityStep(
            current: state.membraneIntegrity,
            damageDrive: membraneDamageDrive,
            damageRate: parameters.membraneDamagePerSecond,
            repairRate: parameters.membraneRepairPerSecond * energySupply,
            dt: dt
        )
        state.axonIntegrity = boundedIntegrityStep(
            current: state.axonIntegrity,
            damageDrive: saturate(mechanicalInjury + 0.5 * state.calciumOverload),
            damageRate: parameters.axonDamagePerSecond,
            repairRate: parameters.axonRepairPerSecond * energySupply,
            dt: dt
        )

        let inflammationTarget = max(
            drivers.inflammatorySignal
                + parameters.inflammationActivationPerSecond
                    * ((1 - state.membraneIntegrity) + (1 - state.axonIntegrity) + state.oxidativeBurden),
            0
        )
        state.inflammatoryActivation = relax(
            current: state.inflammatoryActivation,
            target: inflammationTarget,
            rate: parameters.inflammationResolutionPerSecond,
            dt: dt
        )
        state.myelinIntegrity = boundedIntegrityStep(
            current: state.myelinIntegrity,
            damageDrive: saturate(state.inflammatoryActivation + drivers.toxinSignal),
            damageRate: parameters.myelinDamagePerSecond,
            repairRate: parameters.myelinRepairPerSecond * energySupply,
            dt: dt
        )

        let aggregationTarget = max(
            drivers.proteostasisStress
                + parameters.aggregateFormationPerSecond
                    * (state.oxidativeBurden + atpFailure + drivers.toxinSignal),
            0
        )
        state.aggregateBurden = relax(
            current: state.aggregateBurden,
            target: aggregationTarget,
            rate: parameters.aggregateClearancePerSecond * max(state.atpFraction, 0.05),
            dt: dt
        )

        let hazard = hazardPerSecond(state: state, drivers: drivers)
        state.cumulativeHazard += hazard * dt
        let survival = exp(-hazard * dt)
        let repaired = (1 - state.viability)
            * parameters.viabilityRepairPerSecond
            * state.atpFraction
            * dt
        state.viability = saturate(state.viability * survival + repaired)
        state.elapsedSeconds += dt
    }

    private static func result(
        state: NeuralPathologyState,
        drivers: NeuralPathologyDrivers,
        parameters: NeuralPathologyParameters
    ) -> NeuralPathologyStepResult {
        let atpFailure = 1 - state.atpFraction
        let membraneFailure = 1 - state.membraneIntegrity
        let axonFailure = 1 - state.axonIntegrity
        let myelinFailure = 1 - state.myelinIntegrity
        let hazard = hazardPerSecond(state: state, drivers: drivers)
        var active = Set<NeuralPathologyKind>()
        if drivers.perfusionFraction < 0.8 || drivers.oxygenFraction < 0.8 || drivers.glucoseFraction < 0.8 {
            active.insert(.ischemia)
        }
        if drivers.mechanicalStrain > parameters.strainThreshold
            || abs(drivers.mechanicalStrainRatePerSecond) > parameters.strainRateThresholdPerSecond {
            active.insert(.traumaticAxonalInjury)
        }
        if state.extracellularGlutamateBurden > 0.1 || state.calciumOverload > 0.1 {
            active.insert(.excitotoxicity)
        }
        if state.inflammatoryActivation > 0.1 { active.insert(.neuroinflammation) }
        if state.myelinIntegrity < 0.9 { active.insert(.demyelination) }
        if state.aggregateBurden > 0.1 { active.insert(.proteinAggregation) }
        if state.atpFraction < parameters.atpFailureThreshold { active.insert(.metabolicFailure) }

        let effects = [
            NeuralPathologyEffect(
                channel: .energyReserve,
                value: state.atpFraction,
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .membraneLeak,
                value: 1 + 8 * membraneFailure,
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .firingThresholdShift,
                value: -12 * saturate(state.extracellularGlutamateBurden + drivers.extracellularPotassiumFraction),
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .sodiumConductance,
                value: max(0, 1 - 0.7 * membraneFailure - 0.4 * state.oxidativeBurden),
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .calciumConductance,
                value: 1 + 2 * state.calciumOverload,
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .excitatorySynapticStrength,
                value: max(0, 1 - 0.8 * axonFailure - 0.6 * state.aggregateBurden),
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .synapticReleaseProbability,
                value: max(0, 1 - axonFailure - 0.5 * atpFailure),
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .conductionVelocity,
                value: max(0.01, state.axonIntegrity * (0.1 + 0.9 * state.myelinIntegrity)),
                isMultiplier: true,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .extracellularGlutamate,
                value: state.extracellularGlutamateBurden,
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .inflammatorySignal,
                value: state.inflammatoryActivation,
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .cellDamage,
                value: saturate(1 - state.viability + 0.25 * membraneFailure + 0.25 * axonFailure + 0.1 * myelinFailure),
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .apoptosisHazard,
                value: hazard,
                isMultiplier: false,
                sourceKinds: active
            ),
            NeuralPathologyEffect(
                channel: .aggregateBurden,
                value: state.aggregateBurden,
                isMultiplier: false,
                sourceKinds: active
            )
        ]
        return NeuralPathologyStepResult(
            state: state,
            activeKinds: active,
            effects: effects,
            instantaneousHazardPerSecond: hazard
        )
    }

    private static func hazardPerSecond(
        state: NeuralPathologyState,
        drivers: NeuralPathologyDrivers
    ) -> Double {
        let injury =
            1.5 * pow(1 - state.atpFraction, 2)
            + 0.8 * pow(state.calciumOverload, 2)
            + 0.6 * pow(state.oxidativeBurden, 2)
            + 0.5 * pow(state.inflammatoryActivation, 2)
            + 0.4 * pow(state.aggregateBurden, 2)
            + 1.0 * pow(1 - state.membraneIntegrity, 2)
            + 0.8 * pow(1 - state.axonIntegrity, 2)
            + 0.3 * drivers.toxinSignal
        return max(injury, 0)
    }

    private static func boundedIntegrityStep(
        current: Double,
        damageDrive: Double,
        damageRate: Double,
        repairRate: Double,
        dt: Double
    ) -> Double {
        let damaged = current * exp(-max(damageDrive, 0) * damageRate * dt)
        let repaired = 1 - (1 - damaged) * exp(-max(repairRate, 0) * dt)
        return saturate(repaired)
    }

    private static func relax(
        current: Double,
        target: Double,
        rate: Double,
        dt: Double
    ) -> Double {
        guard rate > 0 else { return max(current, 0) }
        return max(target + (current - target) * exp(-rate * dt), 0)
    }

    private static func thermalStressValue(
        temperature: Double,
        parameters: NeuralPathologyParameters
    ) -> Double {
        if temperature > parameters.hyperthermiaThresholdCelsius {
            return (temperature - parameters.hyperthermiaThresholdCelsius) / 5
        }
        if temperature < parameters.hypothermiaThresholdCelsius {
            return (parameters.hypothermiaThresholdCelsius - temperature) / 10
        }
        return 0
    }

    private static func saturate(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

public enum NeuralPathologyError: Error, Sendable, CustomStringConvertible {
    case invalidDrivers
    case invalidParameters
    case invalidState
    case invalidTimeStep

    public var description: String {
        switch self {
        case .invalidDrivers: return "Neural pathology drivers are invalid"
        case .invalidParameters: return "Neural pathology parameters are invalid"
        case .invalidState: return "Neural pathology state is invalid"
        case .invalidTimeStep: return "Neural pathology time step is invalid"
        }
    }
}
