import Foundation
import NumiTissueCore

public struct RuntimeValidationLimits: Sendable, Hashable, Codable {
    public var minimumVoltageMillivolts: Float
    public var maximumVoltageMillivolts: Float
    public var maximumCellDamage: Float
    public var minimumCellAxisMicrometers: Float
    public var maximumCellAxisMicrometers: Float
    public var maximumSynapticWeight: Float
    public var minimumTemperatureKelvin: Float
    public var maximumTemperatureKelvin: Float
    public var relativeMassTolerance: Float

    public init(
        minimumVoltageMillivolts: Float = -200,
        maximumVoltageMillivolts: Float = 100,
        maximumCellDamage: Float = 1,
        minimumCellAxisMicrometers: Float = 0.05,
        maximumCellAxisMicrometers: Float = 500,
        maximumSynapticWeight: Float = 1_000,
        minimumTemperatureKelvin: Float = 270,
        maximumTemperatureKelvin: Float = 330,
        relativeMassTolerance: Float = 1e-5
    ) {
        self.minimumVoltageMillivolts = minimumVoltageMillivolts
        self.maximumVoltageMillivolts = maximumVoltageMillivolts
        self.maximumCellDamage = maximumCellDamage
        self.minimumCellAxisMicrometers = minimumCellAxisMicrometers
        self.maximumCellAxisMicrometers = maximumCellAxisMicrometers
        self.maximumSynapticWeight = maximumSynapticWeight
        self.minimumTemperatureKelvin = minimumTemperatureKelvin
        self.maximumTemperatureKelvin = maximumTemperatureKelvin
        self.relativeMassTolerance = relativeMassTolerance
    }
}

public struct RuntimeStateValidator: Sendable {
    public var limits: RuntimeValidationLimits

    public init(limits: RuntimeValidationLimits = RuntimeValidationLimits()) {
        self.limits = limits
    }

    public func validate(_ state: TissueRuntimeState) -> [RuntimeValidationIssue] {
        var issues: [RuntimeValidationIssue] = []
        do {
            try state.validateCapacity()
        } catch {
            issues.append(RuntimeValidationIssue(
                severity: .reject,
                code: ValidationCode.capacityBase,
                message: String(describing: error)
            ))
        }

        validateTiles(state, into: &issues)
        validateCells(state, into: &issues)
        validateSegments(state, into: &issues)
        validateCompartments(state, into: &issues)
        validateSynapses(state, into: &issues)
        validateFields(state, into: &issues)
        validateMicrodomains(state, into: &issues)
        validateFloatPool(state.regulatoryState, name: "regulatoryState", into: &issues)
        validateFloatPool(state.mechanismState, name: "mechanismState", into: &issues)
        validateFloatPool(state.molecularSpecies, name: "molecularSpecies", nonnegative: true, into: &issues)
        return issues
    }

    private func validateTiles(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for (index, tile) in state.tiles.enumerated() {
            validate(range: tile.cellRange, count: state.cells.count, pool: "tile.cells", entity: tile.id.rawValue, into: &issues)
            validate(range: tile.segmentRange, count: state.segments.count, pool: "tile.segments", entity: tile.id.rawValue, into: &issues)
            validate(range: tile.compartmentRange, count: state.compartments.count, pool: "tile.compartments", entity: tile.id.rawValue, into: &issues)
            validate(range: tile.synapseRange, count: state.synapses.count, pool: "tile.synapses", entity: tile.id.rawValue, into: &issues)
            validate(range: tile.fieldRange, count: state.fields.count, pool: "tile.fields", entity: tile.id.rawValue, into: &issues)
            validate(range: tile.microdomainRange, count: state.microdomains.count, pool: "tile.microdomains", entity: tile.id.rawValue, into: &issues)
            let scores = [tile.activityScore, tile.uncertaintyScore, tile.damageScore, tile.metabolicStress]
            if scores.contains(where: { !$0.isFinite }) {
                issues.append(reject(ValidationCode.nonFinite, entity: tile.id.rawValue, message: "Non-finite tile score at tile index \(index)"))
            }
        }
    }

    private func validateCells(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for (index, cell) in state.cells.enumerated() {
            guard Int(cell.tileIndex) < state.tiles.count else {
                issues.append(reject(ValidationCode.invalidTopology, entity: cell.id.rawValue, message: "Cell \(index) references tile \(cell.tileIndex)"))
                continue
            }
            let scalars = [
                cell.ageSeconds, cell.cycleProgress, cell.differentiationProgress,
                cell.energyReserve, cell.oxygenStress, cell.glucoseStress,
                cell.damage, cell.apoptosisHazard
            ]
            if scalars.contains(where: { !$0.isFinite }) || !finite3(cell.position) || !finite3(cell.semiAxes) {
                issues.append(reject(ValidationCode.nonFinite, entity: cell.id.rawValue, message: "Non-finite cell state at index \(index)"))
            }
            let axes = [cell.semiAxes.x, cell.semiAxes.y, cell.semiAxes.z]
            if axes.contains(where: { $0 < limits.minimumCellAxisMicrometers || $0 > limits.maximumCellAxisMicrometers }) {
                issues.append(reject(ValidationCode.positiveCellVolume, entity: cell.id.rawValue, value: min(cell.semiAxes.x, min(cell.semiAxes.y, cell.semiAxes.z)), message: "Cell axis outside configured biological bounds"))
            }
            if cell.damage < 0 || cell.damage > limits.maximumCellDamage {
                issues.append(reject(ValidationCode.metabolicBounds, entity: cell.id.rawValue, value: cell.damage, message: "Cell damage outside [0, maximum]"))
            }
            validate(range: cell.regulatoryRange, count: state.regulatoryState.count, pool: "cell.regulatory", entity: cell.id.rawValue, into: &issues)
        }
    }

    private func validateSegments(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for (index, segment) in state.segments.enumerated() {
            if Int(segment.cellIndex) >= state.cells.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: segment.id.rawValue, message: "Segment \(index) references invalid cell"))
            }
            if segment.parentSegmentIndex != RuntimeSegmentState.invalidIndex && Int(segment.parentSegmentIndex) >= state.segments.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: segment.id.rawValue, message: "Segment has invalid parent"))
            }
            if segment.compartmentIndex != RuntimeCompartmentState.invalidIndex && Int(segment.compartmentIndex) >= state.compartments.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: segment.id.rawValue, message: "Segment has invalid compartment"))
            }
            if !finite3(segment.start) || !finite3(segment.end) || !segment.radiusMicrometers.isFinite || segment.radiusMicrometers <= 0 {
                issues.append(reject(ValidationCode.nonFinite, entity: segment.id.rawValue, message: "Invalid segment geometry"))
            }
        }
        detectSegmentCycles(state, into: &issues)
    }

    private func detectSegmentCycles(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        var marks = Array(repeating: UInt8(0), count: state.segments.count)
        for root in state.segments.indices where marks[root] == 0 {
            var path: [Int] = []
            var current = root
            while current >= 0 && current < state.segments.count {
                if marks[current] == 2 { break }
                if marks[current] == 1 {
                    issues.append(reject(ValidationCode.invalidTopology, entity: state.segments[current].id.rawValue, message: "Cycle detected in neurite tree"))
                    break
                }
                marks[current] = 1
                path.append(current)
                let parent = state.segments[current].parentSegmentIndex
                if parent == RuntimeSegmentState.invalidIndex { break }
                current = Int(parent)
            }
            for index in path { marks[index] = 2 }
        }
    }

    private func validateCompartments(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for (index, compartment) in state.compartments.enumerated() {
            if compartment.parentIndex != RuntimeCompartmentState.invalidIndex && Int(compartment.parentIndex) >= state.compartments.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: compartment.id.rawValue, message: "Compartment \(index) has invalid parent"))
            }
            validate(range: compartment.mechanismRange, count: state.mechanismState.count, pool: "compartment.mechanisms", entity: compartment.id.rawValue, into: &issues)
            validate(range: compartment.synapseRange, count: state.synapses.count, pool: "compartment.synapses", entity: compartment.id.rawValue, into: &issues)
            let values = [
                compartment.voltageMillivolts, compartment.previousVoltageMillivolts,
                compartment.capacitanceNanofarads, compartment.axialConductanceMicrosiemens,
                compartment.injectedCurrentNanoamps, compartment.synapticCurrentNanoamps,
                compartment.intracellularCalciumMicromolar,
                compartment.intracellularSodiumMillimolar,
                compartment.intracellularPotassiumMillimolar
            ]
            if values.contains(where: { !$0.isFinite }) {
                issues.append(reject(ValidationCode.nonFinite, entity: compartment.id.rawValue, message: "Non-finite compartment state"))
            }
            if compartment.voltageMillivolts < limits.minimumVoltageMillivolts || compartment.voltageMillivolts > limits.maximumVoltageMillivolts {
                issues.append(reject(ValidationCode.voltageBounds, entity: compartment.id.rawValue, value: compartment.voltageMillivolts, message: "Membrane voltage outside configured bounds"))
            }
            if compartment.capacitanceNanofarads <= 0 {
                issues.append(reject(ValidationCode.biologicalBase, entity: compartment.id.rawValue, value: compartment.capacitanceNanofarads, message: "Compartment capacitance must be positive"))
            }
        }
    }

    private func validateSynapses(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for synapse in state.synapses {
            if Int(synapse.targetCompartmentIndex) >= state.compartments.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: synapse.id.rawValue, message: "Synapse target compartment is invalid"))
            }
            let values = [synapse.weight, synapse.conductance, synapse.shortTermUtilization, synapse.shortTermResources, synapse.preTrace, synapse.postTrace, synapse.eligibility, synapse.consolidation, synapse.structuralScore]
            if values.contains(where: { !$0.isFinite }) {
                issues.append(reject(ValidationCode.nonFinite, entity: synapse.id.rawValue, message: "Non-finite synaptic state"))
            }
            if synapse.weight < 0 || synapse.weight > limits.maximumSynapticWeight {
                issues.append(reject(ValidationCode.weightBounds, entity: synapse.id.rawValue, value: synapse.weight, message: "Synaptic weight outside configured bounds"))
            }
            if synapse.shortTermResources < 0 || synapse.shortTermResources > 1.001 {
                issues.append(reject(ValidationCode.biologicalBase, entity: synapse.id.rawValue, value: synapse.shortTermResources, message: "Short-term resource fraction outside [0, 1]"))
            }
        }
    }

    private func validateFields(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for (index, value) in state.fields.enumerated() {
            if !value.concentration.isFinite || !value.source.isFinite || !value.sink.isFinite || !value.diffusionScale.isFinite {
                issues.append(reject(ValidationCode.nonFinite, entity: UInt64(index), message: "Non-finite extracellular field state"))
            } else if value.concentration < 0 {
                issues.append(reject(ValidationCode.negativeConcentration, entity: UInt64(index), value: value.concentration, message: "Extracellular concentration is negative"))
            }
        }
    }

    private func validateMicrodomains(_ state: TissueRuntimeState, into issues: inout [RuntimeValidationIssue]) {
        for domain in state.microdomains {
            if Int(domain.ownerCellIndex) >= state.cells.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: domain.id.rawValue, message: "Microdomain owner cell is invalid"))
            }
            if domain.ownerCompartmentIndex != RuntimeMicrodomainState.invalidIndex && Int(domain.ownerCompartmentIndex) >= state.compartments.count {
                issues.append(reject(ValidationCode.invalidTopology, entity: domain.id.rawValue, message: "Microdomain owner compartment is invalid"))
            }
            validate(range: domain.speciesRange, count: state.molecularSpecies.count, pool: "microdomain.species", entity: domain.id.rawValue, into: &issues)
            if !domain.volumeFemtoliters.isFinite || domain.volumeFemtoliters <= 0 {
                issues.append(reject(ValidationCode.biologicalBase, entity: domain.id.rawValue, value: domain.volumeFemtoliters, message: "Microdomain volume must be positive"))
            }
            if domain.temperatureKelvin < limits.minimumTemperatureKelvin || domain.temperatureKelvin > limits.maximumTemperatureKelvin {
                issues.append(reject(ValidationCode.biologicalBase, entity: domain.id.rawValue, value: domain.temperatureKelvin, message: "Microdomain temperature is outside bounds"))
            }
        }
    }

    private func validateFloatPool(_ values: [Float], name: String, nonnegative: Bool = false, into issues: inout [RuntimeValidationIssue]) {
        for (index, value) in values.enumerated() {
            if !value.isFinite {
                issues.append(reject(ValidationCode.nonFinite, entity: UInt64(index), message: "Non-finite value in \(name)"))
            } else if nonnegative && value < 0 {
                issues.append(reject(ValidationCode.negativeConcentration, entity: UInt64(index), value: value, message: "Negative value in \(name)"))
            }
        }
    }

    private func validate(range: RuntimeRange, count: Int, pool: String, entity: UInt64, into issues: inout [RuntimeValidationIssue]) {
        if Int(range.upperBound) > count {
            issues.append(reject(ValidationCode.invalidTopology, entity: entity, message: "\(pool) range \(range.lowerBound)..<\(range.upperBound) exceeds count \(count)"))
        }
    }

    private func finite3(_ value: Float4) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private func reject(_ code: UInt32, entity: UInt64, value: Float = 0, message: String) -> RuntimeValidationIssue {
        RuntimeValidationIssue(severity: .reject, code: code, entity: entity, value: value, message: message)
    }
}
