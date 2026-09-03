import Foundation
import NumiTissueCore
import NumiTissueModels

public indirect enum TissueSelection: Sendable, Hashable, Codable {
    case all
    case tiles([TileCoordinate])
    case cells([CellID])
    case cellTypes([UInt16])
    case sphere(centerMicrometers: SIMD3<Float>, radiusMicrometers: Float)
    case box(minimumMicrometers: SIMD3<Float>, maximumMicrometers: SIMD3<Float>)
    case union([TissueSelection])
    case intersection([TissueSelection])
    case excluding(TissueSelection, TissueSelection)

    public func contains(cell: RuntimeCellState, state: TissueRuntimeState) -> Bool {
        switch self {
        case .all: return true
        case .tiles(let coordinates):
            guard Int(cell.tileIndex) < state.tiles.count else { return false }
            return Set(coordinates).contains(state.tiles[Int(cell.tileIndex)].coordinate)
        case .cells(let ids): return Set(ids).contains(cell.id)
        case .cellTypes(let types): return Set(types).contains(cell.typeIndex)
        case .sphere(let center, let radius):
            guard radius >= 0 else { return false }
            let delta = SIMD3(cell.position.x, cell.position.y, cell.position.z) - center
            return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z <= radius * radius
        case .box(let minimum, let maximum):
            let p = SIMD3(cell.position.x, cell.position.y, cell.position.z)
            return p.x >= minimum.x && p.y >= minimum.y && p.z >= minimum.z && p.x <= maximum.x && p.y <= maximum.y && p.z <= maximum.z
        case .union(let selectors): return selectors.contains { $0.contains(cell: cell, state: state) }
        case .intersection(let selectors): return selectors.allSatisfy { $0.contains(cell: cell, state: state) }
        case .excluding(let included, let excluded): return included.contains(cell: cell, state: state) && !excluded.contains(cell: cell, state: state)
        }
    }
}

public enum TissueMutationPersistence: String, Sendable, Hashable, Codable {
    case transaction
    case persistent
}

public enum TissueMutationOperation: String, Sendable, Hashable, Codable {
    case set
    case add
    case multiply
    case clampMaximum
    case clampMinimum
}

public struct RuntimeParameterMutation: Sendable, Hashable, Codable {
    public var path: String
    public var selector: TissueSelection
    public var operation: TissueMutationOperation
    public var persistence: TissueMutationPersistence
    public var value: Float
    public var source: String

    public init(path: String, selector: TissueSelection = .all, operation: TissueMutationOperation, value: Float, persistence: TissueMutationPersistence = .transaction, source: String = "user") {
        self.path = path
        self.selector = selector
        self.operation = operation
        self.persistence = persistence
        self.value = value
        self.source = source
    }
}

public struct ScheduledTissueIntervention: Sendable, Hashable, Codable {
    public enum Envelope: String, Sendable, Hashable, Codable { case step, linear, cosine, exponential }

    public var id: UUID
    public var name: String
    public var startTick: UInt64
    public var endTick: UInt64?
    public var riseTicks: UInt64
    public var fallTicks: UInt64
    public var envelope: Envelope
    public var mutations: [RuntimeParameterMutation]
    public var stimuli: [TissueStimulus]
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        startTick: UInt64,
        endTick: UInt64? = nil,
        riseTicks: UInt64 = 0,
        fallTicks: UInt64 = 0,
        envelope: Envelope = .step,
        mutations: [RuntimeParameterMutation] = [],
        stimuli: [TissueStimulus] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.startTick = startTick
        self.endTick = endTick
        self.riseTicks = riseTicks
        self.fallTicks = fallTicks
        self.envelope = envelope
        self.mutations = mutations
        self.stimuli = stimuli
        self.metadata = metadata
    }

    public func gain(at tick: UInt64) -> Float {
        guard tick >= startTick else { return 0 }
        if let endTick, tick >= endTick { return 0 }
        var gain: Double = 1
        if riseTicks > 0 && tick < startTick + riseTicks {
            gain = shape(Double(tick - startTick) / Double(riseTicks))
        }
        if let endTick, fallTicks > 0, tick > endTick - min(fallTicks, endTick - startTick) {
            gain = min(gain, shape(Double(endTick - tick) / Double(fallTicks)))
        }
        return Float(min(max(gain, 0), 1))
    }

    private func shape(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        switch envelope {
        case .step: return x > 0 ? 1 : 0
        case .linear: return x
        case .cosine: return 0.5 - 0.5 * cos(Double.pi * x)
        case .exponential: return (exp(5 * x) - 1) / (exp(5) - 1)
        }
    }
}

public struct TissueInterventionPlan: Sendable, Hashable, Codable {
    public var interventions: [ScheduledTissueIntervention]

    public init(interventions: [ScheduledTissueIntervention]) {
        self.interventions = interventions.sorted { ($0.startTick, $0.name) < ($1.startTick, $1.name) }
    }

    public func frame(at tick: UInt64) -> TissueInterventionFrame {
        var mutations: [RuntimeParameterMutation] = []
        var stimuli: [TissueStimulus] = []
        var active: [UUID] = []
        for intervention in interventions {
            let gain = intervention.gain(at: tick)
            guard gain > 0 else { continue }
            active.append(intervention.id)
            mutations.append(contentsOf: intervention.mutations.map { mutation in
                var copy = mutation
                switch mutation.operation {
                case .set: copy.value = mutation.value
                case .add: copy.value = mutation.value * gain
                case .multiply: copy.value = 1 + (mutation.value - 1) * gain
                case .clampMaximum, .clampMinimum: copy.value = mutation.value
                }
                return copy
            })
            stimuli.append(contentsOf: intervention.stimuli.filter { $0.startTick <= tick && tick < $0.startTick + UInt64($0.durationTicks) })
        }
        return TissueInterventionFrame(tick: tick, activeInterventions: active, mutations: mutations, stimuli: stimuli)
    }
}

public struct TissueInterventionFrame: Sendable, Hashable, Codable {
    public var tick: UInt64
    public var activeInterventions: [UUID]
    public var mutations: [RuntimeParameterMutation]
    public var stimuli: [TissueStimulus]

    public init(tick: UInt64, activeInterventions: [UUID], mutations: [RuntimeParameterMutation], stimuli: [TissueStimulus]) {
        self.tick = tick
        self.activeInterventions = activeInterventions
        self.mutations = mutations
        self.stimuli = stimuli
    }
}

public protocol InterventionAwareTissueBackend: NumiTissueExecutionBackend {
    func stageInterventions(_ frame: TissueInterventionFrame, context: ExecutionContext) async throws
}

public enum TissueStateInterventionApplier {
    /// Applies a frame to a host state for initialization, checkpoint editing and the reference
    /// backend. Metal production backends should lower the same frame into tile-local GPU worklists.
    public static func apply(_ frame: TissueInterventionFrame, to state: inout TissueRuntimeState) throws {
        for mutation in frame.mutations { try apply(mutation, to: &state) }
        try state.validateCapacity()
    }

    public static func apply(_ mutation: RuntimeParameterMutation, to state: inout TissueRuntimeState) throws {
        guard mutation.value.isFinite else { throw TissueInterventionError.nonFiniteValue(mutation.path) }
        let selectedCells = state.cells.indices.filter { mutation.selector.contains(cell: state.cells[$0], state: state) }
        let selectedCellSet = Set(selectedCells.map(UInt32.init))

        switch mutation.path {
        case "cell.energy_reserve":
            for index in selectedCells { state.cells[index].energyReserve = operate(state.cells[index].energyReserve, mutation) }
        case "cell.damage":
            for index in selectedCells { state.cells[index].damage = min(max(operate(state.cells[index].damage, mutation), 0), 1) }
        case "cell.metabolic_stress":
            for index in selectedCells { state.cells[index].metabolicStress = max(operate(state.cells[index].metabolicStress, mutation), 0) }
        case "cell.fidelity":
            let rawLevel = mutation.value.rounded()
            guard mutation.operation == .set,
                  rawLevel == mutation.value,
                  rawLevel >= Float(FidelityLevel.fieldOnly.rawValue),
                  rawLevel <= Float(FidelityLevel.molecularDetail.rawValue),
                  let level = FidelityLevel(rawValue: UInt8(rawLevel)) else { throw TissueInterventionError.invalidFidelity }
            for index in selectedCells { state.cells[index].fidelity = level }
        case "synapse.weight":
            for index in state.synapses.indices {
                let target = Int(state.synapses[index].targetCompartmentIndex)
                guard target < state.compartments.count, selectedCellSet.contains(state.compartments[target].neuronIndex) else { continue }
                state.synapses[index].weight = max(operate(state.synapses[index].weight, mutation), 0)
            }
        case "synapse.eligibility":
            for index in state.synapses.indices {
                let target = Int(state.synapses[index].targetCompartmentIndex)
                guard target < state.compartments.count, selectedCellSet.contains(state.compartments[target].neuronIndex) else { continue }
                state.synapses[index].eligibility = operate(state.synapses[index].eligibility, mutation)
            }
        case "compartment.voltage_mv":
            for index in state.compartments.indices where selectedCellSet.contains(state.compartments[index].neuronIndex) {
                let value = operate(state.compartments[index].voltageMillivolts, mutation)
                guard value >= -200, value <= 150 else { throw TissueInterventionError.voltageOutOfBounds(value) }
                state.compartments[index].voltageMillivolts = value
            }
        default:
            if mutation.path.hasPrefix("mechanism.state.") {
                let suffix = mutation.path.dropFirst("mechanism.state.".count)
                guard let localOffset = Int(suffix), localOffset >= 0 else { throw TissueInterventionError.unknownPath(mutation.path) }
                for compartment in state.compartments where selectedCellSet.contains(compartment.neuronIndex) {
                    guard localOffset < Int(compartment.mechanismRange.count) else { continue }
                    let index = Int(compartment.mechanismRange.lowerBound) + localOffset
                    state.mechanismState[index] = operate(state.mechanismState[index], mutation)
                }
            } else if mutation.path.hasPrefix("field.channel.") {
                let suffix = mutation.path.dropFirst("field.channel.".count)
                guard let channel = Int(suffix), (0..<12).contains(channel) else { throw TissueInterventionError.unknownPath(mutation.path) }
                applyField(channel: channel, mutation: mutation, selectedCellSet: selectedCellSet, state: &state)
            } else if mutation.path.hasPrefix("microdomain.species.") {
                let suffix = mutation.path.dropFirst("microdomain.species.".count)
                guard let speciesOffset = Int(suffix), speciesOffset >= 0 else { throw TissueInterventionError.unknownPath(mutation.path) }
                for domain in state.microdomains where selectedCellSet.contains(domain.ownerCellIndex) {
                    guard speciesOffset < Int(domain.speciesRange.count) else { continue }
                    let index = Int(domain.speciesRange.lowerBound) + speciesOffset
                    state.molecularSpecies[index] = max(operate(state.molecularSpecies[index], mutation), 0)
                }
            } else {
                throw TissueInterventionError.unknownPath(mutation.path)
            }
        }
    }

    private static func applyField(channel: Int, mutation: RuntimeParameterMutation, selectedCellSet: Set<UInt32>, state: inout TissueRuntimeState) {
        let selectedTiles = Set(selectedCellSet.compactMap { cellIndex -> UInt32? in
            guard Int(cellIndex) < state.cells.count else { return nil }
            return state.cells[Int(cellIndex)].tileIndex
        })
        for tileIndex in selectedTiles {
            guard Int(tileIndex) < state.tiles.count else { continue }
            let range = state.tiles[Int(tileIndex)].fieldRange
            let voxelCount = Int(range.count) / 12
            let lower = Int(range.lowerBound) + channel * voxelCount
            for index in lower..<(lower + voxelCount) {
                state.fields[index].concentration = max(operate(state.fields[index].concentration, mutation), 0)
            }
        }
    }

    private static func operate(_ current: Float, _ mutation: RuntimeParameterMutation) -> Float {
        switch mutation.operation {
        case .set: return mutation.value
        case .add: return current + mutation.value
        case .multiply: return current * mutation.value
        case .clampMaximum: return min(current, mutation.value)
        case .clampMinimum: return max(current, mutation.value)
        }
    }
}

public enum PharmacologyMutationCompiler {
    public static func compile(
        effects: [PharmacodynamicEffect],
        selector: TissueSelection = .all
    ) throws -> [RuntimeParameterMutation] {
        try effects.map { effect in
            guard effect.fractionalEffect.isFinite, effect.fractionalEffect >= -Double(Float.greatestFiniteMagnitude), effect.fractionalEffect <= Double(Float.greatestFiniteMagnitude) else {
                throw TissueInterventionError.nonFiniteValue(effect.parameterPath)
            }
            let value: Float
            let operation: TissueMutationOperation
            switch effect.action {
            case .agonist, .partialAgonist, .positiveAllostericModulator, .activator:
                value = Float(1 + effect.fractionalEffect); operation = .multiply
            case .antagonist, .negativeAllostericModulator, .inhibitor, .blocker:
                value = Float(max(1 - effect.fractionalEffect, 0)); operation = .multiply
            case .substrate:
                value = Float(effect.fractionalEffect); operation = .add
            }
            return RuntimeParameterMutation(
                path: effect.parameterPath,
                selector: selector,
                operation: operation,
                value: value,
                source: "compound.\(effect.compoundID).target.\(effect.targetID)"
            )
        }
    }
}

public enum TissueInterventionError: Error, Sendable, CustomStringConvertible {
    case nonFiniteValue(String)
    case unknownPath(String)
    case invalidFidelity
    case voltageOutOfBounds(Float)

    public var description: String {
        switch self {
        case .nonFiniteValue(let path): return "Intervention value for \(path) is non-finite"
        case .unknownPath(let path): return "Unknown runtime intervention path \(path)"
        case .invalidFidelity: return "Intervention fidelity value is invalid"
        case .voltageOutOfBounds(let value): return "Intervention voltage \(value) mV is outside safety bounds"
        }
    }
}
