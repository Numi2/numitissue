import Foundation

@frozen
public struct NTMetabolicParameters: Codable, Hashable, Sendable {
    public var basalATPPerCellPerSecond: Float
    public var spikeATPEquivalent: Float
    public var oxygenPerATP: Float
    public var glucosePerATP: Float
    public var lactateYieldPerGlucose: Float
    public var energyRecoveryPerSecond: Float
    public var hypoxiaThresholdMillimolar: Float
    public var glucoseStressThresholdMillimolar: Float
    public var damageRateUnderHypoxia: Float
    public var recoveryRate: Float

    public init(
        basalATPPerCellPerSecond: Float = 0.001,
        spikeATPEquivalent: Float = 0.00002,
        oxygenPerATP: Float = 0.16,
        glucosePerATP: Float = 0.03,
        lactateYieldPerGlucose: Float = 0.2,
        energyRecoveryPerSecond: Float = 0.1,
        hypoxiaThresholdMillimolar: Float = 0.01,
        glucoseStressThresholdMillimolar: Float = 0.5,
        damageRateUnderHypoxia: Float = 0.002,
        recoveryRate: Float = 0.0001
    ) {
        self.basalATPPerCellPerSecond = basalATPPerCellPerSecond
        self.spikeATPEquivalent = spikeATPEquivalent
        self.oxygenPerATP = oxygenPerATP
        self.glucosePerATP = glucosePerATP
        self.lactateYieldPerGlucose = lactateYieldPerGlucose
        self.energyRecoveryPerSecond = energyRecoveryPerSecond
        self.hypoxiaThresholdMillimolar = hypoxiaThresholdMillimolar
        self.glucoseStressThresholdMillimolar = glucoseStressThresholdMillimolar
        self.damageRateUnderHypoxia = damageRateUnderHypoxia
        self.recoveryRate = recoveryRate
    }
}

@frozen
public struct NTGlialParameters: Codable, Hashable, Sendable {
    public var astrocytePotassiumUptakePerSecond: Float
    public var astrocyteGlutamateUptakePerSecond: Float
    public var astrocyteLactateSupplyPerSecond: Float
    public var astrocyteCalciumDecayPerSecond: Float
    public var astrocyteActivationThreshold: Float
    public var oligodendrocyteMyelinRatePerSecond: Float
    public var oligodendrocyteRepairRatePerSecond: Float
    public var microgliaActivationThreshold: Float
    public var microgliaPruningRatePerSecond: Float
    public var microgliaDebrisClearancePerSecond: Float
    public var inflammatoryReleasePerSecond: Float

    public init(
        astrocytePotassiumUptakePerSecond: Float = 0.5,
        astrocyteGlutamateUptakePerSecond: Float = 10,
        astrocyteLactateSupplyPerSecond: Float = 0.02,
        astrocyteCalciumDecayPerSecond: Float = 0.2,
        astrocyteActivationThreshold: Float = 0.1,
        oligodendrocyteMyelinRatePerSecond: Float = 0.0001,
        oligodendrocyteRepairRatePerSecond: Float = 0.00002,
        microgliaActivationThreshold: Float = 0.1,
        microgliaPruningRatePerSecond: Float = 0.0001,
        microgliaDebrisClearancePerSecond: Float = 0.001,
        inflammatoryReleasePerSecond: Float = 0.01
    ) {
        self.astrocytePotassiumUptakePerSecond = astrocytePotassiumUptakePerSecond
        self.astrocyteGlutamateUptakePerSecond = astrocyteGlutamateUptakePerSecond
        self.astrocyteLactateSupplyPerSecond = astrocyteLactateSupplyPerSecond
        self.astrocyteCalciumDecayPerSecond = astrocyteCalciumDecayPerSecond
        self.astrocyteActivationThreshold = astrocyteActivationThreshold
        self.oligodendrocyteMyelinRatePerSecond = oligodendrocyteMyelinRatePerSecond
        self.oligodendrocyteRepairRatePerSecond = oligodendrocyteRepairRatePerSecond
        self.microgliaActivationThreshold = microgliaActivationThreshold
        self.microgliaPruningRatePerSecond = microgliaPruningRatePerSecond
        self.microgliaDebrisClearancePerSecond = microgliaDebrisClearancePerSecond
        self.inflammatoryReleasePerSecond = inflammatoryReleasePerSecond
    }
}

@frozen
public struct NTGlialStepResult: Sendable {
    public var astrocytesUpdated: UInt32
    public var oligodendrocytesUpdated: UInt32
    public var microgliaUpdated: UInt32
    public var synapsesMarkedForPruning: UInt32
    public var oxygenConsumed: Float
    public var glucoseConsumed: Float
    public var lactateProduced: Float
    public var energyJoules: Double
    public var diagnostics: [NTDiagnostic]

    public init() {
        astrocytesUpdated = 0
        oligodendrocytesUpdated = 0
        microgliaUpdated = 0
        synapsesMarkedForPruning = 0
        oxygenConsumed = 0
        glucoseConsumed = 0
        lactateProduced = 0
        energyJoules = 0
        diagnostics = []
    }
}

/// Glial and metabolic state is stored in the 32-float regulatory state carried by each cell.
/// The first eight lanes are interpreted per glial cell class; lineage and model import remain free
/// to use the remaining lanes for specialized regulatory programs.
public struct NTGliaAndMetabolismEngine: Sendable {
    public var metabolic: NTMetabolicParameters
    public var glial: NTGlialParameters
    public var fields: NTExtracellularFieldEngine

    public init(
        metabolic: NTMetabolicParameters = .init(),
        glial: NTGlialParameters = .init(),
        fields: NTExtracellularFieldEngine = .init()
    ) {
        self.metabolic = metabolic
        self.glial = glial
        self.fields = fields
    }

    public func step(state: inout NTProductionState, deltaTicks: UInt64) -> NTGlialStepResult {
        let dt = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        guard dt > 0 else { return .init() }
        var result = NTGlialStepResult()
        var ionicEnergyByCell: [CellID: Float] = [:]
        var spikesByCell: [CellID: UInt32] = [:]
        for compartment in state.compartments {
            ionicEnergyByCell[compartment.record.cell, default: 0] += compartment.energyCostPicojoules
            spikesByCell[compartment.record.cell, default: 0] &+= compartment.spikeCountWindow
        }

        for index in state.cells.indices {
            var cell = state.cells[index]
            ensureRegulatoryState(&cell.record.regulatoryState)
            let position = cell.record.positionMicrometers
            let tile = cell.record.tile
            let oxygen = fields.sample(state: state, tile: tile, positionMicrometers: position, species: .oxygen) ?? 0.04
            let glucose = fields.sample(state: state, tile: tile, positionMicrometers: position, species: .glucose) ?? 5
            let potassium = fields.sample(state: state, tile: tile, positionMicrometers: position, species: .potassium) ?? 3.5
            let glutamate = fields.sample(state: state, tile: tile, positionMicrometers: position, species: .glutamate) ?? 0
            let inflammation = fields.sample(state: state, tile: tile, positionMicrometers: position, species: .inflammatoryDamage) ?? 0

            let ionicPicojoules = ionicEnergyByCell[cell.record.id, default: 0]
            let spikeCount = Float(spikesByCell[cell.record.id, default: 0])
            let activityDemand = metabolic.spikeATPEquivalent * spikeCount + ionicPicojoules * 1.0e-9
            let atpDemand = metabolic.basalATPPerCellPerSecond + activityDemand / max(dt, 1.0e-9)
            let oxygenDemand = atpDemand * metabolic.oxygenPerATP
            let glucoseDemand = atpDemand * metabolic.glucosePerATP
            result.oxygenConsumed += oxygenDemand * dt
            result.glucoseConsumed += glucoseDemand * dt
            result.lactateProduced += glucoseDemand * metabolic.lactateYieldPerGlucose * dt

            fields.addSource(state: &state, tile: tile, positionMicrometers: position, species: .oxygen, amountPerSecond: -oxygenDemand)
            fields.addSource(state: &state, tile: tile, positionMicrometers: position, species: .glucose, amountPerSecond: -glucoseDemand)
            fields.addSource(state: &state, tile: tile, positionMicrometers: position, species: .lactate, amountPerSecond: glucoseDemand * metabolic.lactateYieldPerGlucose)

            cell.record.oxygenStress = smoothStress(value: oxygen, threshold: metabolic.hypoxiaThresholdMillimolar)
            cell.record.glucoseStress = smoothStress(value: glucose, threshold: metabolic.glucoseStressThresholdMillimolar)
            let metabolicSupport = max(0, min(1, oxygen / max(metabolic.hypoxiaThresholdMillimolar, 1.0e-9))) *
                max(0, min(1, glucose / max(metabolic.glucoseStressThresholdMillimolar, 1.0e-9)))
            cell.record.energy = max(0, min(1,
                cell.record.energy + dt * (metabolic.energyRecoveryPerSecond * metabolicSupport - atpDemand)
            ))
            let stress = max(cell.record.oxygenStress, cell.record.glucoseStress)
            if stress > 0.5 {
                cell.record.damage = min(1, cell.record.damage + metabolic.damageRateUnderHypoxia * stress * dt)
            } else {
                cell.record.damage = max(0, cell.record.damage - metabolic.recoveryRate * dt)
            }

            switch cell.record.kind {
            case .astrocyte:
                updateAstrocyte(
                    cell: &cell,
                    potassium: potassium,
                    glutamate: glutamate,
                    inflammation: inflammation,
                    state: &state,
                    dt: dt
                )
                result.astrocytesUpdated &+= 1
            case .oligodendrocyte, .oligodendrocytePrecursor:
                updateOligodendrocyte(cell: &cell, state: &state, activityByCell: spikesByCell, dt: dt)
                result.oligodendrocytesUpdated &+= 1
            case .microglia:
                let pruned = updateMicroglia(
                    cell: &cell,
                    inflammation: inflammation,
                    state: &state,
                    dt: dt
                )
                result.synapsesMarkedForPruning &+= pruned
                result.microgliaUpdated &+= 1
            default:
                break
            }
            result.energyJoules += Double(atpDemand * dt) * 5.0e-20
            state.cells[index] = cell
        }
        return result
    }

    private func updateAstrocyte(
        cell: inout NTProductionCell,
        potassium: Float,
        glutamate: Float,
        inflammation: Float,
        state: inout NTProductionState,
        dt: Float
    ) {
        var r = cell.record.regulatoryState
        let activation = max(0, potassium - 3.5) + 0.2 * glutamate + inflammation
        r[0] = max(0, r[0] + dt * (activation - glial.astrocyteCalciumDecayPerSecond * r[0]))
        r[1] = max(0, r[1] + dt * (0.5 * r[0] - 0.1 * r[1]))
        r[2] = max(0, min(1, r[2] + dt * (cell.record.energy - 0.1 * activation)))
        r[3] = max(0, min(1, glial.astrocytePotassiumUptakePerSecond * sigmoid(r[0] - glial.astrocyteActivationThreshold)))
        r[4] = max(0, min(1, glial.astrocyteGlutamateUptakePerSecond * sigmoid(r[0] - glial.astrocyteActivationThreshold)))
        r[5] = max(0, min(1, r[5] + dt * (0.2 * cell.record.glucoseStress - 0.05 * r[5])))
        r[6] = max(0, min(1, 0.1 * max(0, potassium - 5) + 0.2 * inflammation))
        r[7] = max(0, min(1, activation))
        cell.record.regulatoryState = r

        let position = cell.record.positionMicrometers
        let tile = cell.record.tile
        fields.addSource(
            state: &state,
            tile: tile,
            positionMicrometers: position,
            species: .potassium,
            amountPerSecond: -r[3] * max(0, potassium - 3.5)
        )
        fields.addSource(
            state: &state,
            tile: tile,
            positionMicrometers: position,
            species: .glutamate,
            amountPerSecond: -r[4] * glutamate
        )
        fields.addSource(
            state: &state,
            tile: tile,
            positionMicrometers: position,
            species: .lactate,
            amountPerSecond: glial.astrocyteLactateSupplyPerSecond * r[2]
        )
        fields.addSource(
            state: &state,
            tile: tile,
            positionMicrometers: position,
            species: .trophicSupport,
            amountPerSecond: 0.001 * r[7]
        )
    }

    private func updateOligodendrocyte(
        cell: inout NTProductionCell,
        state: inout NTProductionState,
        activityByCell: [CellID: UInt32],
        dt: Float
    ) {
        var r = cell.record.regulatoryState
        let maturation = cell.record.kind == .oligodendrocyte ? 1.0 as Float : cell.record.differentiationProgress
        r[0] = max(0, min(1, r[0] + glial.oligodendrocyteMyelinRatePerSecond * maturation * cell.record.energy * dt))
        r[1] = max(0, min(1, r[1] + glial.oligodendrocyteRepairRatePerSecond * (1 - cell.record.damage) * dt))
        r[2] = cell.record.energy
        r[3] = max(0, min(1, r[3] + 0.001 * dt))
        cell.record.regulatoryState = r

        let radiusSquared = max(cell.record.radiiMicrometers.x, 20)
        let radiusSquaredValue = radiusSquared * radiusSquared
        for index in state.compartments.indices {
            let compartment = state.compartments[index]
            guard compartment.record.compartmentClass == .axon || compartment.record.compartmentClass == .myelinatedAxon else { continue }
            guard (compartment.record.positionMicrometers - cell.record.positionMicrometers).squaredLength <= radiusSquaredValue else { continue }
            let activity = Float(activityByCell[compartment.record.cell, default: 0])
            let activitySupport = min(1, activity * 0.01)
            state.compartments[index].record.flags |= 1 << 3
            state.compartments[index].record.axialConductanceMicrosiemens *= 1 + glial.oligodendrocyteMyelinRatePerSecond * (0.2 + activitySupport) * dt
            state.compartments[index].record.capacitanceNanofarads *= max(0.999, 1 - 0.01 * glial.oligodendrocyteMyelinRatePerSecond * dt)
        }
    }

    private func updateMicroglia(
        cell: inout NTProductionCell,
        inflammation: Float,
        state: inout NTProductionState,
        dt: Float
    ) -> UInt32 {
        var r = cell.record.regulatoryState
        let nearbyDamage = nearbyCellDamage(center: cell.record.positionMicrometers, tile: cell.record.tile, state: state)
        let activationDrive = max(inflammation, nearbyDamage)
        r[0] = max(0, min(1, r[0] + dt * (activationDrive - 0.01 * r[0])))
        r[1] = max(0, min(1, r[1] + dt * (nearbyDamage - glial.microgliaDebrisClearancePerSecond * r[1])))
        r[2] = max(0, min(1, sigmoid((r[0] - glial.microgliaActivationThreshold) * 10)))
        r[3] = cell.record.energy
        cell.record.regulatoryState = r

        if r[0] > glial.microgliaActivationThreshold {
            fields.addSource(
                state: &state,
                tile: cell.record.tile,
                positionMicrometers: cell.record.positionMicrometers,
                species: .inflammatoryDamage,
                amountPerSecond: glial.inflammatoryReleasePerSecond * r[0]
            )
        }

        var marked: UInt32 = 0
        let radiusSquared: Float = 30 * 30
        for index in state.synapses.indices {
            let post = Int(state.synapses[index].record.postCompartmentIndex)
            guard state.compartments.indices.contains(post) else { continue }
            let position = state.compartments[post].record.positionMicrometers
            guard (position - cell.record.positionMicrometers).squaredLength <= radiusSquared else { continue }
            if state.synapses[index].record.structuralScore < 0.1,
               state.synapses[index].record.consolidation < 0.2,
               r[2] * glial.microgliaPruningRatePerSecond * dt > 1.0e-8 {
                state.synapses[index].record.structuralScore = max(
                    0,
                    state.synapses[index].record.structuralScore - r[2] * glial.microgliaPruningRatePerSecond * dt
                )
                if state.synapses[index].record.structuralScore <= 0.001 {
                    state.synapses[index].pendingDeletion = true
                    marked &+= 1
                }
            }
        }
        return marked
    }

    private func nearbyCellDamage(center: NTVector3, tile: TileID, state: NTProductionState) -> Float {
        var maximum: Float = 0
        let radiusSquared: Float = 40 * 40
        for candidate in state.cells where candidate.record.tile == tile {
            if (candidate.record.positionMicrometers - center).squaredLength <= radiusSquared {
                maximum = max(maximum, candidate.record.damage)
            }
        }
        return maximum
    }

    private func ensureRegulatoryState(_ values: inout [Float]) {
        if values.count < 32 { values.append(contentsOf: repeatElement(0, count: 32 - values.count)) }
        if values.count > 32 { values.removeLast(values.count - 32) }
    }

    @inline(__always)
    private func smoothStress(value: Float, threshold: Float) -> Float {
        guard threshold > 0 else { return 0 }
        return max(0, min(1, (threshold - value) / threshold))
    }

    @inline(__always)
    private func sigmoid(_ value: Float) -> Float { 1 / (1 + exp(-value)) }
}
