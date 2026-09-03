import Foundation
import NumiTissueCore
import NumiTissueRuntime

public enum TissueInjuryMechanism: UInt16, Sendable, Hashable, Codable, CaseIterable {
    case bluntImpact = 0
    case compression = 1
    case tension = 2
    case shear = 3
    case laceration = 4
    case thermal = 5
    case ischemia = 6
    case hypoxia = 7
    case excitotoxicity = 8
    case toxin = 9
    case infection = 10
    case autoimmune = 11
    case radiation = 12
    case userDefined = 65_535
}

public struct TissueInjurySite: Sendable, Hashable, Codable {
    public var siteID: UInt64
    public var destination: UInt64
    public var tileIndex: UInt32?
    public var cellID: CellID?
    public var mechanism: TissueInjuryMechanism
    public var severity: Float
    public var strainEnergyDensity: Float
    public var hydrostaticPressureKilopascals: Float
    public var shearStressKilopascals: Float
    public var temperatureKelvin: Float
    public var hypoxia: Float
    public var ischemia: Float
    public var membraneDisruption: Float
    public var hemorrhage: Float
    public var inflammation: Float
    public var nociception: Float
    public var repairDemand: Float
    public var flags: UInt32

    public init(
        siteID: UInt64,
        destination: UInt64,
        tileIndex: UInt32? = nil,
        cellID: CellID? = nil,
        mechanism: TissueInjuryMechanism,
        severity: Float,
        strainEnergyDensity: Float = 0,
        hydrostaticPressureKilopascals: Float = 0,
        shearStressKilopascals: Float = 0,
        temperatureKelvin: Float = 310.15,
        hypoxia: Float = 0,
        ischemia: Float = 0,
        membraneDisruption: Float = 0,
        hemorrhage: Float = 0,
        inflammation: Float = 0,
        nociception: Float = 0,
        repairDemand: Float = 0,
        flags: UInt32 = 0
    ) {
        self.siteID = siteID
        self.destination = destination
        self.tileIndex = tileIndex
        self.cellID = cellID
        self.mechanism = mechanism
        self.severity = severity
        self.strainEnergyDensity = strainEnergyDensity
        self.hydrostaticPressureKilopascals = hydrostaticPressureKilopascals
        self.shearStressKilopascals = shearStressKilopascals
        self.temperatureKelvin = temperatureKelvin
        self.hypoxia = hypoxia
        self.ischemia = ischemia
        self.membraneDisruption = membraneDisruption
        self.hemorrhage = hemorrhage
        self.inflammation = inflammation
        self.nociception = nociception
        self.repairDemand = repairDemand
        self.flags = flags
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(
            [
                severity,
                strainEnergyDensity,
                hydrostaticPressureKilopascals,
                shearStressKilopascals,
                temperatureKelvin,
                hypoxia,
                ischemia,
                membraneDisruption,
                hemorrhage,
                inflammation,
                nociception,
                repairDemand
            ],
            field: "injury site \(siteID)"
        )
        var result = self
        result.severity = PhysiologyNumerics.unit(severity)
        result.strainEnergyDensity = max(strainEnergyDensity, 0)
        result.hypoxia = PhysiologyNumerics.unit(hypoxia)
        result.ischemia = PhysiologyNumerics.unit(ischemia)
        result.membraneDisruption = PhysiologyNumerics.unit(membraneDisruption)
        result.hemorrhage = PhysiologyNumerics.unit(hemorrhage)
        result.inflammation = PhysiologyNumerics.unit(inflammation)
        result.nociception = PhysiologyNumerics.unit(nociception)
        result.repairDemand = PhysiologyNumerics.unit(repairDemand)
        guard result.temperatureKelvin > 0 else {
            throw PhysiologyCouplingError.invalidValue(field: "temperatureKelvin", value: result.temperatureKelvin)
        }
        return result
    }
}

public struct SystemicPhysiologyState: Sendable, Hashable, Codable {
    public var heartRateBeatsPerMinute: Float
    public var meanArterialPressureKilopascals: Float
    public var arterialOxygenFraction: Float
    public var glucoseMillimolar: Float
    public var lactateMillimolar: Float
    public var pH: Float
    public var temperatureKelvin: Float
    public var bloodVolumeFraction: Float
    public var ventilationFraction: Float
    public var perfusionFraction: Float
    public var sympatheticTone: Float
    public var parasympatheticTone: Float
    public var catecholamineLevel: Float
    public var cortisolLevel: Float
    public var cytokineLevel: Float
    public var coagulationActivation: Float

    public init(
        heartRateBeatsPerMinute: Float = 70,
        meanArterialPressureKilopascals: Float = 13.3,
        arterialOxygenFraction: Float = 0.2,
        glucoseMillimolar: Float = 5,
        lactateMillimolar: Float = 1,
        pH: Float = 7.4,
        temperatureKelvin: Float = 310.15,
        bloodVolumeFraction: Float = 1,
        ventilationFraction: Float = 1,
        perfusionFraction: Float = 1,
        sympatheticTone: Float = 0.2,
        parasympatheticTone: Float = 0.5,
        catecholamineLevel: Float = 0,
        cortisolLevel: Float = 0,
        cytokineLevel: Float = 0,
        coagulationActivation: Float = 0
    ) {
        self.heartRateBeatsPerMinute = heartRateBeatsPerMinute
        self.meanArterialPressureKilopascals = meanArterialPressureKilopascals
        self.arterialOxygenFraction = arterialOxygenFraction
        self.glucoseMillimolar = glucoseMillimolar
        self.lactateMillimolar = lactateMillimolar
        self.pH = pH
        self.temperatureKelvin = temperatureKelvin
        self.bloodVolumeFraction = bloodVolumeFraction
        self.ventilationFraction = ventilationFraction
        self.perfusionFraction = perfusionFraction
        self.sympatheticTone = sympatheticTone
        self.parasympatheticTone = parasympatheticTone
        self.catecholamineLevel = catecholamineLevel
        self.cortisolLevel = cortisolLevel
        self.cytokineLevel = cytokineLevel
        self.coagulationActivation = coagulationActivation
    }

    public func validated() throws -> Self {
        let values = vector
        try PhysiologyNumerics.requireFinite(values, field: "systemic physiology")
        guard heartRateBeatsPerMinute >= 0,
              meanArterialPressureKilopascals >= 0,
              arterialOxygenFraction >= 0,
              glucoseMillimolar >= 0,
              lactateMillimolar >= 0,
              temperatureKelvin > 0 else {
            throw PhysiologyCouplingError.invalidSystemicState
        }
        var result = self
        result.arterialOxygenFraction = PhysiologyNumerics.unit(arterialOxygenFraction)
        result.bloodVolumeFraction = PhysiologyNumerics.unit(bloodVolumeFraction)
        result.ventilationFraction = max(ventilationFraction, 0)
        result.perfusionFraction = max(perfusionFraction, 0)
        result.sympatheticTone = PhysiologyNumerics.unit(sympatheticTone)
        result.parasympatheticTone = PhysiologyNumerics.unit(parasympatheticTone)
        result.catecholamineLevel = max(catecholamineLevel, 0)
        result.cortisolLevel = max(cortisolLevel, 0)
        result.cytokineLevel = max(cytokineLevel, 0)
        result.coagulationActivation = PhysiologyNumerics.unit(coagulationActivation)
        return result
    }

    public var vector: [Float] {
        [
            heartRateBeatsPerMinute,
            meanArterialPressureKilopascals,
            arterialOxygenFraction,
            glucoseMillimolar,
            lactateMillimolar,
            pH,
            temperatureKelvin,
            bloodVolumeFraction,
            ventilationFraction,
            perfusionFraction,
            sympatheticTone,
            parasympatheticTone,
            catecholamineLevel,
            cortisolLevel,
            cytokineLevel,
            coagulationActivation
        ]
    }
}

public struct MuscleAfferentState: Sendable, Hashable, Codable {
    public var muscleID: UInt64
    public var lengthFraction: Float
    public var velocityLengthsPerSecond: Float
    public var forceFraction: Float
    public var fatigue: Float
    public var spindlePrimary: Float
    public var spindleSecondary: Float
    public var tendonOrgan: Float
    public var nociception: Float

    public init(
        muscleID: UInt64,
        lengthFraction: Float = 1,
        velocityLengthsPerSecond: Float = 0,
        forceFraction: Float = 0,
        fatigue: Float = 0,
        spindlePrimary: Float = 0,
        spindleSecondary: Float = 0,
        tendonOrgan: Float = 0,
        nociception: Float = 0
    ) {
        self.muscleID = muscleID
        self.lengthFraction = lengthFraction
        self.velocityLengthsPerSecond = velocityLengthsPerSecond
        self.forceFraction = forceFraction
        self.fatigue = fatigue
        self.spindlePrimary = spindlePrimary
        self.spindleSecondary = spindleSecondary
        self.tendonOrgan = tendonOrgan
        self.nociception = nociception
    }

    public var vector: [Float] {
        [
            lengthFraction,
            velocityLengthsPerSecond,
            forceFraction,
            fatigue,
            spindlePrimary,
            spindleSecondary,
            tendonOrgan,
            nociception
        ]
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(vector, field: "muscle afferent \(muscleID)")
        var result = self
        result.lengthFraction = max(lengthFraction, 0)
        result.forceFraction = max(forceFraction, 0)
        result.fatigue = PhysiologyNumerics.unit(fatigue)
        result.spindlePrimary = max(spindlePrimary, 0)
        result.spindleSecondary = max(spindleSecondary, 0)
        result.tendonOrgan = max(tendonOrgan, 0)
        result.nociception = PhysiologyNumerics.unit(nociception)
        return result
    }
}

public struct NumanXPhysiologyObservation: Sendable, Hashable, Codable {
    public var time: TissueTime
    public var systemic: SystemicPhysiologyState
    public var muscles: [MuscleAfferentState]
    public var injuries: [TissueInjurySite]
    public var organSignals: [Float]
    public var flags: UInt32

    public init(
        time: TissueTime,
        systemic: SystemicPhysiologyState = SystemicPhysiologyState(),
        muscles: [MuscleAfferentState] = [],
        injuries: [TissueInjurySite] = [],
        organSignals: [Float] = [],
        flags: UInt32 = 0
    ) {
        self.time = time
        self.systemic = systemic
        self.muscles = muscles
        self.injuries = injuries
        self.organSignals = organSignals
        self.flags = flags
    }

    public func validated(expectedTime: TissueTime? = nil) throws -> Self {
        if let expectedTime, time != expectedTime {
            throw PhysiologyCouplingError.timeMismatch(expected: expectedTime.tick, actual: time.tick)
        }
        var result = self
        result.systemic = try systemic.validated()
        result.muscles = try muscles.map { try $0.validated() }
        result.injuries = try injuries.map { try $0.validated() }
        try PhysiologyNumerics.requireFinite(organSignals, field: "organ signals")
        return result
    }
}

public struct MotorUnitCommand: Sendable, Hashable, Codable {
    public var motorUnitID: UInt64
    public var muscleID: UInt64
    public var alphaDrive: Float
    public var gammaDrive: Float
    public var recruitment: Float
    public var firingRateHertz: Float
    public var coContraction: Float
    public var fatigueCompensation: Float
    public var maximumForceScale: Float
    public var flags: UInt32

    public init(
        motorUnitID: UInt64,
        muscleID: UInt64,
        alphaDrive: Float,
        gammaDrive: Float = 0,
        recruitment: Float = 1,
        firingRateHertz: Float = 0,
        coContraction: Float = 0,
        fatigueCompensation: Float = 0,
        maximumForceScale: Float = 1,
        flags: UInt32 = 0
    ) {
        self.motorUnitID = motorUnitID
        self.muscleID = muscleID
        self.alphaDrive = alphaDrive
        self.gammaDrive = gammaDrive
        self.recruitment = recruitment
        self.firingRateHertz = firingRateHertz
        self.coContraction = coContraction
        self.fatigueCompensation = fatigueCompensation
        self.maximumForceScale = maximumForceScale
        self.flags = flags
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(
            [
                alphaDrive,
                gammaDrive,
                recruitment,
                firingRateHertz,
                coContraction,
                fatigueCompensation,
                maximumForceScale
            ],
            field: "motor unit \(motorUnitID)"
        )
        var result = self
        result.alphaDrive = PhysiologyNumerics.unit(alphaDrive)
        result.gammaDrive = PhysiologyNumerics.unit(gammaDrive)
        result.recruitment = PhysiologyNumerics.unit(recruitment)
        result.firingRateHertz = max(firingRateHertz, 0)
        result.coContraction = PhysiologyNumerics.unit(coContraction)
        result.fatigueCompensation = PhysiologyNumerics.unit(fatigueCompensation)
        result.maximumForceScale = max(maximumForceScale, 0)
        return result
    }
}

public struct AutonomicControl: Sendable, Hashable, Codable {
    public var sympatheticDrive: Float
    public var parasympatheticDrive: Float
    public var cardiacChronotropy: Float
    public var cardiacInotropy: Float
    public var vascularTone: Float
    public var ventilationDrive: Float
    public var thermogenesis: Float
    public var gastrointestinalDrive: Float
    public var bladderDrive: Float
    public var pupillaryDrive: Float

    public init(
        sympatheticDrive: Float = 0,
        parasympatheticDrive: Float = 0,
        cardiacChronotropy: Float = 0,
        cardiacInotropy: Float = 0,
        vascularTone: Float = 0,
        ventilationDrive: Float = 0,
        thermogenesis: Float = 0,
        gastrointestinalDrive: Float = 0,
        bladderDrive: Float = 0,
        pupillaryDrive: Float = 0
    ) {
        self.sympatheticDrive = sympatheticDrive
        self.parasympatheticDrive = parasympatheticDrive
        self.cardiacChronotropy = cardiacChronotropy
        self.cardiacInotropy = cardiacInotropy
        self.vascularTone = vascularTone
        self.ventilationDrive = ventilationDrive
        self.thermogenesis = thermogenesis
        self.gastrointestinalDrive = gastrointestinalDrive
        self.bladderDrive = bladderDrive
        self.pupillaryDrive = pupillaryDrive
    }

    public var vector: [Float] {
        [
            sympatheticDrive,
            parasympatheticDrive,
            cardiacChronotropy,
            cardiacInotropy,
            vascularTone,
            ventilationDrive,
            thermogenesis,
            gastrointestinalDrive,
            bladderDrive,
            pupillaryDrive
        ]
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(vector, field: "autonomic control")
        var result = self
        result.sympatheticDrive = PhysiologyNumerics.signedUnit(sympatheticDrive)
        result.parasympatheticDrive = PhysiologyNumerics.signedUnit(parasympatheticDrive)
        result.cardiacChronotropy = PhysiologyNumerics.signedUnit(cardiacChronotropy)
        result.cardiacInotropy = PhysiologyNumerics.signedUnit(cardiacInotropy)
        result.vascularTone = PhysiologyNumerics.signedUnit(vascularTone)
        result.ventilationDrive = PhysiologyNumerics.signedUnit(ventilationDrive)
        result.thermogenesis = PhysiologyNumerics.signedUnit(thermogenesis)
        result.gastrointestinalDrive = PhysiologyNumerics.signedUnit(gastrointestinalDrive)
        result.bladderDrive = PhysiologyNumerics.signedUnit(bladderDrive)
        result.pupillaryDrive = PhysiologyNumerics.signedUnit(pupillaryDrive)
        return result
    }
}

public struct EndocrineControl: Sendable, Hashable, Codable {
    public var insulin: Float
    public var glucagon: Float
    public var cortisol: Float
    public var adrenaline: Float
    public var vasopressin: Float
    public var thyroid: Float
    public var growthHormone: Float
    public var inflammatoryBrake: Float

    public init(
        insulin: Float = 0,
        glucagon: Float = 0,
        cortisol: Float = 0,
        adrenaline: Float = 0,
        vasopressin: Float = 0,
        thyroid: Float = 0,
        growthHormone: Float = 0,
        inflammatoryBrake: Float = 0
    ) {
        self.insulin = insulin
        self.glucagon = glucagon
        self.cortisol = cortisol
        self.adrenaline = adrenaline
        self.vasopressin = vasopressin
        self.thyroid = thyroid
        self.growthHormone = growthHormone
        self.inflammatoryBrake = inflammatoryBrake
    }

    public var vector: [Float] {
        [insulin, glucagon, cortisol, adrenaline, vasopressin, thyroid, growthHormone, inflammatoryBrake]
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(vector, field: "endocrine control")
        var result = self
        result.insulin = PhysiologyNumerics.signedUnit(insulin)
        result.glucagon = PhysiologyNumerics.signedUnit(glucagon)
        result.cortisol = PhysiologyNumerics.signedUnit(cortisol)
        result.adrenaline = PhysiologyNumerics.signedUnit(adrenaline)
        result.vasopressin = PhysiologyNumerics.signedUnit(vasopressin)
        result.thyroid = PhysiologyNumerics.signedUnit(thyroid)
        result.growthHormone = PhysiologyNumerics.signedUnit(growthHormone)
        result.inflammatoryBrake = PhysiologyNumerics.signedUnit(inflammatoryBrake)
        return result
    }
}

public struct NumiBrainPhysiologyControl: Sendable, Hashable, Codable {
    public var motorUnits: [MotorUnitCommand]
    public var autonomic: AutonomicControl
    public var endocrine: EndocrineControl
    public var nociceptiveGain: Float
    public var protectiveReflexGain: Float
    public var metabolicPriority: Float
    public var perfusionTargets: [Float]
    public var ventilationTarget: Float
    public var behaviorRiskBudget: Float
    public var flags: UInt32

    public init(
        motorUnits: [MotorUnitCommand] = [],
        autonomic: AutonomicControl = AutonomicControl(),
        endocrine: EndocrineControl = EndocrineControl(),
        nociceptiveGain: Float = 1,
        protectiveReflexGain: Float = 1,
        metabolicPriority: Float = 0,
        perfusionTargets: [Float] = [],
        ventilationTarget: Float = 1,
        behaviorRiskBudget: Float = 1,
        flags: UInt32 = 0
    ) {
        self.motorUnits = motorUnits
        self.autonomic = autonomic
        self.endocrine = endocrine
        self.nociceptiveGain = nociceptiveGain
        self.protectiveReflexGain = protectiveReflexGain
        self.metabolicPriority = metabolicPriority
        self.perfusionTargets = perfusionTargets
        self.ventilationTarget = ventilationTarget
        self.behaviorRiskBudget = behaviorRiskBudget
        self.flags = flags
    }

    public func validated() throws -> Self {
        try PhysiologyNumerics.requireFinite(
            [nociceptiveGain, protectiveReflexGain, metabolicPriority, ventilationTarget, behaviorRiskBudget] + perfusionTargets,
            field: "brain physiology control"
        )
        var result = self
        result.motorUnits = try motorUnits.map { try $0.validated() }
        result.autonomic = try autonomic.validated()
        result.endocrine = try endocrine.validated()
        result.nociceptiveGain = max(nociceptiveGain, 0)
        result.protectiveReflexGain = max(protectiveReflexGain, 0)
        result.metabolicPriority = PhysiologyNumerics.unit(metabolicPriority)
        result.perfusionTargets = perfusionTargets.map { max($0, 0) }
        result.ventilationTarget = max(ventilationTarget, 0)
        result.behaviorRiskBudget = PhysiologyNumerics.unit(behaviorRiskBudget)
        return result
    }
}

public struct TissuePhysiologyFeedback: Sendable, Hashable, Codable {
    public var timeRange: Range<TissueTime>
    public var oxygenDemand: [Float]
    public var glucoseDemand: [Float]
    public var lactateProduction: [Float]
    public var heatProduction: [Float]
    public var edema: [Float]
    public var damageEvents: [RoutedEvent]
    public var uncertainty: Float
    public var plasticityMagnitude: Float

    public init(
        timeRange: Range<TissueTime>,
        oxygenDemand: [Float] = [],
        glucoseDemand: [Float] = [],
        lactateProduction: [Float] = [],
        heatProduction: [Float] = [],
        edema: [Float] = [],
        damageEvents: [RoutedEvent] = [],
        uncertainty: Float = 0,
        plasticityMagnitude: Float = 0
    ) {
        self.timeRange = timeRange
        self.oxygenDemand = oxygenDemand
        self.glucoseDemand = glucoseDemand
        self.lactateProduction = lactateProduction
        self.heatProduction = heatProduction
        self.edema = edema
        self.damageEvents = damageEvents
        self.uncertainty = uncertainty
        self.plasticityMagnitude = plasticityMagnitude
    }

    public init(output: RuntimeOutputFrame) {
        let demand = output.metabolicDemand.map { max($0, 0) }
        self.init(
            timeRange: output.startTime..<output.endTime,
            oxygenDemand: demand,
            glucoseDemand: demand,
            lactateProduction: demand.map { $0 * 0.25 },
            heatProduction: demand.map { $0 * 0.15 },
            edema: Array(repeating: 0, count: demand.count),
            damageEvents: output.damageEvents,
            uncertainty: output.uncertainty,
            plasticityMagnitude: output.plasticityMagnitude
        )
    }
}

public struct NumiPhysiologyCouplingConfiguration: Sendable, Hashable, Codable {
    public var injuryRouteNamespace: UInt64
    public var motorRouteNamespace: UInt64
    public var referenceGlucoseMillimolar: Float
    public var referenceLactateMillimolar: Float
    public var maximumAnalogMagnitude: Float
    public var emitZeroAnalogChannels: Bool

    public init(
        injuryRouteNamespace: UInt64 = 0x4E54_494E_0000_0000,
        motorRouteNamespace: UInt64 = 0x4E54_4D4F_0000_0000,
        referenceGlucoseMillimolar: Float = 5,
        referenceLactateMillimolar: Float = 1,
        maximumAnalogMagnitude: Float = 1_000,
        emitZeroAnalogChannels: Bool = true
    ) {
        precondition(referenceGlucoseMillimolar > 0)
        precondition(referenceLactateMillimolar > 0)
        precondition(maximumAnalogMagnitude > 0)
        self.injuryRouteNamespace = injuryRouteNamespace
        self.motorRouteNamespace = motorRouteNamespace
        self.referenceGlucoseMillimolar = referenceGlucoseMillimolar
        self.referenceLactateMillimolar = referenceLactateMillimolar
        self.maximumAnalogMagnitude = maximumAnalogMagnitude
        self.emitZeroAnalogChannels = emitZeroAnalogChannels
    }
}

public struct NumiPhysiologyCoupler: Sendable {
    public var configuration: NumiPhysiologyCouplingConfiguration

    public init(configuration: NumiPhysiologyCouplingConfiguration = NumiPhysiologyCouplingConfiguration()) {
        self.configuration = configuration
    }

    public func augment(
        observation: NumanXObservationFrame,
        physiology: NumanXPhysiologyObservation
    ) throws -> NumanXObservationFrame {
        let validated = try physiology.validated(expectedTime: observation.time)
        var result = observation
        result.interoception.append(contentsOf: validated.systemic.vector)

        for muscle in validated.muscles.sorted(by: { $0.muscleID < $1.muscleID }) {
            result.proprioception.append(contentsOf: muscle.vector.prefix(7))
            result.touch.append(muscle.nociception)
        }

        for value in validated.organSignals where configuration.emitZeroAnalogChannels || value != 0 {
            result.interoception.append(
                PhysiologyNumerics.clamp(
                    value,
                    lower: -configuration.maximumAnalogMagnitude,
                    upper: configuration.maximumAnalogMagnitude
                )
            )
        }

        for injury in validated.injuries {
            result.injuryEvents.append(
                RoutedEvent(
                    arrivalTick: observation.time.tick,
                    source: configuration.injuryRouteNamespace ^ injury.siteID,
                    destination: injury.destination,
                    amplitude: injury.severity,
                    kind: .damage,
                    flags: UInt16(truncatingIfNeeded: injury.mechanism.rawValue),
                    sequence: UInt32(truncatingIfNeeded: injury.siteID)
                )
            )
        }
        result.injuryEvents.sort()

        let systemic = validated.systemic
        result.chemicalBoundary.oxygen = systemic.arterialOxygenFraction
        result.chemicalBoundary.glucose = systemic.glucoseMillimolar / configuration.referenceGlucoseMillimolar
        result.chemicalBoundary.lactate = systemic.lactateMillimolar / configuration.referenceLactateMillimolar
        result.chemicalBoundary.temperatureKelvin = systemic.temperatureKelvin
        result.chemicalBoundary.pH = systemic.pH
        result.chemicalBoundary.perfusion = systemic.perfusionFraction * systemic.bloodVolumeFraction
        result.mechanicalBoundary.damage = max(
            result.mechanicalBoundary.damage,
            validated.injuries.map(\.severity).max() ?? 0
        )
        result.mechanicalBoundary.temperatureKelvin = systemic.temperatureKelvin
        return result
    }

    public func merge(
        physiology control: NumiBrainPhysiologyControl,
        into motor: NumiBrainMotorFrame,
        at tick: UInt64
    ) throws -> NumiBrainMotorFrame {
        let validated = try control.validated()
        var result = motor
        let ordered = validated.motorUnits.sorted {
            if $0.muscleID != $1.muscleID { return $0.muscleID < $1.muscleID }
            return $0.motorUnitID < $1.motorUnitID
        }
        result.muscleExcitation = ordered.map(\.alphaDrive)
        result.autonomicCommands = validated.autonomic.vector
        result.glandCommands = validated.endocrine.vector
        for unit in ordered {
            result.motorEvents.append(
                RoutedEvent(
                    arrivalTick: tick,
                    source: configuration.motorRouteNamespace ^ unit.motorUnitID,
                    destination: unit.muscleID,
                    amplitude: unit.alphaDrive * unit.recruitment,
                    kind: .userDefined,
                    flags: UInt16(truncatingIfNeeded: unit.flags),
                    sequence: UInt32(truncatingIfNeeded: unit.motorUnitID)
                )
            )
        }
        result.motorEvents.sort()
        return result
    }

    public func controlFrame(
        interval: Range<TissueTime>,
        motor: NumiBrainMotorFrame,
        physiology: NumiBrainPhysiologyControl?,
        feedback: TissuePhysiologyFeedback
    ) throws -> NumanXControlFrame {
        let validated = try physiology?.validated()
        return NumanXControlFrame(
            timeRange: interval,
            motor: motor,
            metabolicDemand: feedback.oxygenDemand,
            swelling: feedback.edema,
            perfusionTargets: validated?.perfusionTargets ?? [],
            ventilationTarget: validated?.ventilationTarget ?? 1,
            autonomic: validated?.autonomic,
            endocrine: validated?.endocrine,
            motorUnits: validated?.motorUnits ?? []
        )
    }
}

public protocol NumiBrainPhysiologyEndpoint: Sendable {
    func integratePhysiologyObservation(
        _ observation: NumanXPhysiologyObservation,
        context: SuiteTransactionContext
    ) async throws
    func integrateTissuePhysiology(
        _ feedback: TissuePhysiologyFeedback,
        context: SuiteTransactionContext
    ) async throws
    func physiologyControl(context: SuiteTransactionContext) async throws -> NumiBrainPhysiologyControl
    func validatePhysiologyShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue]
}

public extension NumiBrainPhysiologyEndpoint {
    func validatePhysiologyShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue] {
        []
    }
}

public protocol NumanXPhysiologyEndpoint: Sendable {
    func committedPhysiology(at time: TissueTime) async throws -> NumanXPhysiologyObservation
    func integratePhysiologyControl(
        _ control: NumiBrainPhysiologyControl,
        feedback: TissuePhysiologyFeedback,
        context: SuiteTransactionContext
    ) async throws
    func shadowPhysiology(context: SuiteTransactionContext) async throws -> NumanXPhysiologyObservation
    func validatePhysiologyShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue]
}

public extension NumanXPhysiologyEndpoint {
    func validatePhysiologyShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue] {
        []
    }
}

public extension NumanXControlFrame {
    init(
        timeRange: Range<TissueTime>,
        motor: NumiBrainMotorFrame,
        tissueStress: [SIMD6<Float>] = [],
        tissueGrowth: [SIMD6<Float>] = [],
        metabolicDemand: [Float] = [],
        swelling: [Float] = [],
        perfusionTargets: [Float],
        ventilationTarget: Float,
        autonomic: AutonomicControl?,
        endocrine: EndocrineControl?,
        motorUnits: [MotorUnitCommand]
    ) {
        var encodedStress = tissueStress
        if let autonomic {
            encodedStress.append(
                SIMD6<Float>(
                    autonomic.sympatheticDrive,
                    autonomic.parasympatheticDrive,
                    autonomic.cardiacChronotropy,
                    autonomic.cardiacInotropy,
                    autonomic.vascularTone,
                    autonomic.ventilationDrive
                )
            )
        }
        var encodedGrowth = tissueGrowth
        if let endocrine {
            encodedGrowth.append(
                SIMD6<Float>(
                    endocrine.insulin,
                    endocrine.glucagon,
                    endocrine.cortisol,
                    endocrine.adrenaline,
                    endocrine.vasopressin,
                    endocrine.growthHormone
                )
            )
        }
        encodedGrowth.append(
            SIMD6<Float>(
                ventilationTarget,
                perfusionTargets.first ?? 0,
                Float(motorUnits.count),
                0,
                0,
                0
            )
        )
        self.init(
            timeRange: timeRange,
            motor: motor,
            tissueStress: encodedStress,
            tissueGrowth: encodedGrowth,
            metabolicDemand: metabolicDemand,
            swelling: swelling
        )
    }
}

public enum PhysiologyCouplingError: Error, Sendable, CustomStringConvertible {
    case nonFinite(field: String)
    case invalidValue(field: String, value: Float)
    case invalidSystemicState
    case timeMismatch(expected: UInt64, actual: UInt64)

    public var description: String {
        switch self {
        case .nonFinite(let field):
            return "Non-finite value in \(field)"
        case .invalidValue(let field, let value):
            return "Invalid physiological value \(value) for \(field)"
        case .invalidSystemicState:
            return "Systemic physiology contains values outside its admissible domain"
        case .timeMismatch(let expected, let actual):
            return "Physiology time mismatch: expected \(expected), received \(actual)"
        }
    }
}

private enum PhysiologyNumerics {
    static func requireFinite(_ values: [Float], field: String) throws {
        guard values.allSatisfy(\.isFinite) else {
            throw PhysiologyCouplingError.nonFinite(field: field)
        }
    }

    static func unit(_ value: Float) -> Float {
        clamp(value, lower: 0, upper: 1)
    }

    static func signedUnit(_ value: Float) -> Float {
        clamp(value, lower: -1, upper: 1)
    }

    static func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}
