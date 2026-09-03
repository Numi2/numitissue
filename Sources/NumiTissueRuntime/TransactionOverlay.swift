import Foundation
import NumiTissueCore
import NumiTissueModels

/// A stable domain identifier shared by the CPU compiler and Metal overlay ABI.
/// State domains mutate the transaction shadow. Model domains materialize into
/// transaction-local effective parameter tables; immutable compiled tables never change.
public enum RuntimeOverlayDomain: UInt16, Sendable, Hashable, Codable, CaseIterable {
    case cellState = 0
    case segmentState = 1
    case compartmentState = 2
    case synapseState = 3
    case fieldState = 4
    case mechanismState = 5
    case molecularSpecies = 6
    case regulatoryState = 7
    case channelParameter = 32
    case mechanismSetParameter = 33
    case synapseParameter = 34
    case fieldParameter = 35
    case cellProgramParameter = 36
    case regulatoryProgramParameter = 37
    case fateTransitionParameter = 38
    case growthProgramParameter = 39
    case glialProgramParameter = 40
    case molecularReactionParameter = 41

    public var isModelParameter: Bool { rawValue >= 32 }
}

/// Components are domain-local. Keeping them as fixed-width integers makes the overlay
/// representation forward-compatible without forcing a monolithic cross-domain enum.
public enum RuntimeOverlayComponent {
    public enum Cell {
        public static let energyReserve: UInt16 = 0
        public static let oxygenStress: UInt16 = 1
        public static let glucoseStress: UInt16 = 2
        public static let damage: UInt16 = 3
        public static let apoptosisHazard: UInt16 = 4
        public static let cycleProgress: UInt16 = 5
        public static let differentiationProgress: UInt16 = 6
        public static let ageSeconds: UInt16 = 7
        public static let fidelity: UInt16 = 8
    }

    public enum Segment {
        public static let radius: UInt16 = 0
        public static let myelinFraction: UInt16 = 1
        public static let growthRate: UInt16 = 2
        public static let structuralScore: UInt16 = 3
    }

    public enum Compartment {
        public static let voltage: UInt16 = 0
        public static let capacitance: UInt16 = 1
        public static let axialConductance: UInt16 = 2
        public static let injectedCurrent: UInt16 = 3
        public static let synapticCurrent: UInt16 = 4
        public static let calcium: UInt16 = 5
        public static let sodium: UInt16 = 6
        public static let potassium: UInt16 = 7
    }

    public enum Synapse {
        public static let weight: UInt16 = 0
        public static let conductance: UInt16 = 1
        public static let utilization: UInt16 = 2
        public static let resources: UInt16 = 3
        public static let preTrace: UInt16 = 4
        public static let postTrace: UInt16 = 5
        public static let eligibility: UInt16 = 6
        public static let consolidation: UInt16 = 7
        public static let structuralScore: UInt16 = 8
    }

    public enum Field {
        public static let concentration: UInt16 = 0
        public static let source: UInt16 = 1
        public static let sink: UInt16 = 2
        public static let diffusionScale: UInt16 = 3
    }

    public enum ChannelParameter {
        public static let maximumConductance: UInt16 = 0
        public static let reversalPotential: UInt16 = 1
        public static let activation0: UInt16 = 4
        public static let activation1: UInt16 = 5
        public static let activation2: UInt16 = 6
        public static let activation3: UInt16 = 7
        public static let inactivation0: UInt16 = 8
        public static let inactivation1: UInt16 = 9
        public static let inactivation2: UInt16 = 10
        public static let inactivation3: UInt16 = 11
    }

    public enum MechanismSetParameter {
        public static let temperatureCelsius: UInt16 = 0
        public static let q10: UInt16 = 1
        public static let thermalScale: UInt16 = 2
    }

    public enum SynapseParameter {
        public static let riseMilliseconds: UInt16 = 0
        public static let decayMilliseconds: UInt16 = 1
        public static let reversalPotential: UInt16 = 2
        public static let defaultWeight: UInt16 = 3
        public static let utilization: UInt16 = 4
        public static let recoveryDecay: UInt16 = 5
        public static let facilitationDecay: UInt16 = 6
        public static let positiveAmplitude: UInt16 = 8
        public static let negativeAmplitude: UInt16 = 9
        public static let preTraceDecay: UInt16 = 10
        public static let postTraceDecay: UInt16 = 11
        public static let eligibilityDecay: UInt16 = 12
        public static let learningRate: UInt16 = 13
        public static let minimumWeight: UInt16 = 14
        public static let maximumWeight: UInt16 = 15
    }

    public enum FieldParameter {
        public static let diffusionAlpha: UInt16 = 0
        public static let decay: UInt16 = 1
        public static let baseline: UInt16 = 2
        public static let minimum: UInt16 = 4
        public static let maximum: UInt16 = 5
    }

    public enum CellProgramParameter {
        public static let radius: UInt16 = 0
        public static let mechanicsX: UInt16 = 1
        public static let mechanicsY: UInt16 = 2
        public static let mechanicsZ: UInt16 = 3
        public static let capacitance: UInt16 = 4
        public static let leakConductance: UInt16 = 5
        public static let leakReversal: UInt16 = 6
        public static let spikeThreshold: UInt16 = 7
    }

    public enum RegulatoryProgramParameter {
        public static let timeConstant0: UInt16 = 0
        public static let timeConstant1: UInt16 = 1
        public static let timeConstant2: UInt16 = 2
        public static let timeConstant3: UInt16 = 3
        public static let timeConstant4: UInt16 = 4
        public static let timeConstant5: UInt16 = 5
        public static let timeConstant6: UInt16 = 6
        public static let timeConstant7: UInt16 = 7
        public static let divisionHazard: UInt16 = 8
        public static let apoptosisHazard: UInt16 = 9
    }

    public enum FateTransitionParameter {
        public static let baseHazard: UInt16 = 0
        public static let minimumAge: UInt16 = 1
        public static let regulatory0: UInt16 = 4
        public static let regulatory1: UInt16 = 5
        public static let regulatory2: UInt16 = 6
        public static let regulatory3: UInt16 = 7
        public static let field0: UInt16 = 8
        public static let field1: UInt16 = 9
        public static let field2: UInt16 = 10
        public static let field3: UInt16 = 11
    }

    public enum GrowthProgramParameter {
        public static let speed: UInt16 = 0
        public static let branchHazard: UInt16 = 1
        public static let retractionHazard: UInt16 = 2
        public static let segmentLength: UInt16 = 3
        public static let persistence: UInt16 = 4
        public static let attraction: UInt16 = 5
        public static let repulsion: UInt16 = 6
        public static let fasciculation: UInt16 = 7
        public static let activity: UInt16 = 8
        public static let noise: UInt16 = 9
    }

    public enum GlialProgramParameter {
        public static let uptake0: UInt16 = 0
        public static let uptake1: UInt16 = 1
        public static let uptake2: UInt16 = 2
        public static let uptake3: UInt16 = 3
        public static let release0: UInt16 = 4
        public static let release1: UInt16 = 5
        public static let release2: UInt16 = 6
        public static let release3: UInt16 = 7
        public static let threshold0: UInt16 = 8
        public static let threshold1: UInt16 = 9
        public static let threshold2: UInt16 = 10
        public static let threshold3: UInt16 = 11
        public static let spatialRadius: UInt16 = 12
    }

    public enum MolecularReactionParameter {
        public static let rateConstant: UInt16 = 0
        public static let reverseRateConstant: UInt16 = 1
    }
}

public struct RuntimeOverlayGroupKey: Sendable, Hashable, Codable, Comparable {
    public var domain: RuntimeOverlayDomain
    public var component: UInt16
    public var pathHash: UInt64

    public init(domain: RuntimeOverlayDomain, component: UInt16, pathHash: UInt64) {
        self.domain = domain
        self.component = component
        self.pathHash = pathHash
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.domain.rawValue != rhs.domain.rawValue { return lhs.domain.rawValue < rhs.domain.rawValue }
        if lhs.component != rhs.component { return lhs.component < rhs.component }
        return lhs.pathHash < rhs.pathHash
    }
}

public struct RuntimeOverlayGroup: Sendable, Hashable, Codable {
    public var key: RuntimeOverlayGroupKey
    public var recordRange: RuntimeRange

    public init(key: RuntimeOverlayGroupKey, recordRange: RuntimeRange) {
        self.key = key
        self.recordRange = recordRange
    }
}

public struct RuntimeOverlayRecord: Sendable, Hashable, Codable {
    public static let clampMinimumFlag: UInt16 = 1 << 0
    public static let clampMaximumFlag: UInt16 = 1 << 1

    public var lowerBound: UInt32
    public var count: UInt32
    public var operation: TissueMutationOperation
    public var flags: UInt16
    public var value: Float
    public var minimum: Float
    public var maximum: Float
    public var sequence: UInt32
    public var sourceHash: UInt64

    public init(
        lowerBound: UInt32,
        count: UInt32,
        operation: TissueMutationOperation,
        flags: UInt16,
        value: Float,
        minimum: Float,
        maximum: Float,
        sequence: UInt32,
        sourceHash: UInt64
    ) {
        self.lowerBound = lowerBound
        self.count = count
        self.operation = operation
        self.flags = flags
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.sequence = sequence
        self.sourceHash = sourceHash
    }

    public var upperBound: UInt32 { lowerBound &+ count }

    @inlinable
    public func contains(_ index: UInt32) -> Bool {
        index >= lowerBound && index < upperBound
    }

    @inlinable
    public func applying(to current: Float) -> Float {
        var result: Float
        switch operation {
        case .set: result = value
        case .add: result = current + value
        case .multiply: result = current * value
        case .clampMaximum: result = min(current, value)
        case .clampMinimum: result = max(current, value)
        }
        if flags & Self.clampMinimumFlag != 0 { result = max(result, minimum) }
        if flags & Self.clampMaximumFlag != 0 { result = min(result, maximum) }
        return result
    }
}

public struct CompiledTransactionOverlay: Sendable, Hashable, Codable {
    public var tick: UInt64
    public var activeInterventions: [UUID]
    public var groups: [RuntimeOverlayGroup]
    public var records: [RuntimeOverlayRecord]
    public var stimuli: [TissueStimulus]
    public var digest: UInt64

    public init(
        tick: UInt64,
        activeInterventions: [UUID],
        groups: [RuntimeOverlayGroup],
        records: [RuntimeOverlayRecord],
        stimuli: [TissueStimulus],
        digest: UInt64
    ) {
        self.tick = tick
        self.activeInterventions = activeInterventions
        self.groups = groups
        self.records = records
        self.stimuli = stimuli
        self.digest = digest
    }

    public static let empty = Self(
        tick: 0,
        activeInterventions: [],
        groups: [],
        records: [],
        stimuli: [],
        digest: RuntimeOverlayHash.offsetBasis
    )

    public var isEmpty: Bool { records.isEmpty && stimuli.isEmpty }
    public var stateGroups: [RuntimeOverlayGroup] { groups.filter { !$0.key.domain.isModelParameter } }
    public var parameterGroups: [RuntimeOverlayGroup] { groups.filter { $0.key.domain.isModelParameter } }

    public func records(for group: RuntimeOverlayGroup) -> ArraySlice<RuntimeOverlayRecord> {
        let lower = Int(group.recordRange.lowerBound)
        let upper = min(Int(group.recordRange.upperBound), records.count)
        guard lower >= 0, lower <= upper else { return [] }
        return records[lower..<upper]
    }

    public func effectiveValue(
        domain: RuntimeOverlayDomain,
        component: UInt16,
        logicalIndex: UInt32,
        baseline: Float
    ) -> Float {
        var value = baseline
        for group in groups where group.key.domain == domain && group.key.component == component {
            for record in records(for: group) where record.contains(logicalIndex) {
                value = record.applying(to: value)
            }
        }
        return value
    }
}

public struct RuntimeOverlayCompiler: Sendable {
    public init() {}

    public func compile(
        frame: TissueInterventionFrame,
        state: TissueRuntimeState,
        model: CompiledTissueModel
    ) throws -> CompiledTransactionOverlay {
        var grouped: [RuntimeOverlayGroupKey: [RuntimeOverlayRecord]] = [:]

        for (sequence, mutation) in frame.mutations.enumerated() {
            guard mutation.value.isFinite else {
                throw TissueInterventionError.nonFiniteValue(mutation.path)
            }
            let binding = try RuntimeOverlayPathRegistry.resolve(
                mutation.path,
                state: state,
                model: model
            )
            let ranges = try ranges(for: binding, selector: mutation.selector, state: state)
            let sourceHash = RuntimeOverlayHash.string(mutation.source)
            for range in ranges where range.count > 0 {
                let record = RuntimeOverlayRecord(
                    lowerBound: range.lowerBound,
                    count: range.count,
                    operation: mutation.operation,
                    flags: binding.flags,
                    value: mutation.value,
                    minimum: binding.minimum,
                    maximum: binding.maximum,
                    sequence: UInt32(clamping: sequence),
                    sourceHash: sourceHash
                )
                grouped[binding.key, default: []].append(record)
            }
        }

        var groups: [RuntimeOverlayGroup] = []
        var records: [RuntimeOverlayRecord] = []
        for key in grouped.keys.sorted() {
            let lower = UInt32(clamping: records.count)
            let ordered = grouped[key, default: []].sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                if $0.lowerBound != $1.lowerBound { return $0.lowerBound < $1.lowerBound }
                return $0.sourceHash < $1.sourceHash
            }
            records.append(contentsOf: ordered)
            groups.append(RuntimeOverlayGroup(
                key: key,
                recordRange: RuntimeRange(lowerBound: lower, count: UInt32(clamping: ordered.count))
            ))
        }

        var digest = RuntimeOverlayHash.offsetBasis
        digest = RuntimeOverlayHash.combine(digest, frame.tick)
        for id in frame.activeInterventions.sorted(by: { $0.uuidString < $1.uuidString }) {
            digest = RuntimeOverlayHash.combine(digest, RuntimeOverlayHash.string(id.uuidString))
        }
        for group in groups {
            digest = RuntimeOverlayHash.combine(digest, UInt64(group.key.domain.rawValue))
            digest = RuntimeOverlayHash.combine(digest, UInt64(group.key.component))
            digest = RuntimeOverlayHash.combine(digest, group.key.pathHash)
        }
        for record in records {
            digest = RuntimeOverlayHash.combine(digest, UInt64(record.lowerBound))
            digest = RuntimeOverlayHash.combine(digest, UInt64(record.count))
            digest = RuntimeOverlayHash.combine(digest, UInt64(record.sequence))
            digest = RuntimeOverlayHash.combine(digest, UInt64(record.value.bitPattern))
            digest = RuntimeOverlayHash.combine(digest, record.sourceHash)
        }
        return CompiledTransactionOverlay(
            tick: frame.tick,
            activeInterventions: frame.activeInterventions.sorted(by: { $0.uuidString < $1.uuidString }),
            groups: groups,
            records: records,
            stimuli: frame.stimuli.sorted {
                if $0.startTick != $1.startTick { return $0.startTick < $1.startTick }
                if $0.destination != $1.destination { return $0.destination < $1.destination }
                return $0.kind < $1.kind
            },
            digest: digest
        )
    }

    private func ranges(
        for binding: RuntimeOverlayBinding,
        selector: TissueSelection,
        state: TissueRuntimeState
    ) throws -> [RuntimeRange] {
        if binding.key.domain.isModelParameter {
            guard selector == .all else {
                throw RuntimeOverlayError.localizedSharedParameter(binding.canonicalPath)
            }
            return [RuntimeRange(lowerBound: binding.tableIndex, count: 1)]
        }

        let selectedCells = state.cells.indices.filter {
            selector.contains(cell: state.cells[$0], state: state)
        }
        let selectedCellSet = Set(selectedCells.map(UInt32.init))
        let indices: [UInt32]

        switch binding.key.domain {
        case .cellState:
            indices = selectedCells.map(UInt32.init)
        case .segmentState:
            indices = state.segments.indices.compactMap { index in
                selectedCellSet.contains(state.segments[index].cellIndex) ? UInt32(index) : nil
            }
        case .compartmentState:
            indices = state.compartments.indices.compactMap { index in
                selectedCellSet.contains(state.compartments[index].neuronIndex) ? UInt32(index) : nil
            }
        case .synapseState:
            indices = state.synapses.indices.compactMap { index in
                let target = Int(state.synapses[index].targetCompartmentIndex)
                guard state.compartments.indices.contains(target),
                      selectedCellSet.contains(state.compartments[target].neuronIndex) else { return nil }
                return UInt32(index)
            }
        case .fieldState:
            let selectedTiles: Set<UInt32>
            if selector == .all {
                selectedTiles = Set(state.tiles.indices.map(UInt32.init))
            } else {
                selectedTiles = Set(selectedCells.map { state.cells[$0].tileIndex })
            }
            var fieldIndices: [UInt32] = []
            let channel = Int(binding.localOffset)
            for tileIndex in selectedTiles.sorted() {
                guard state.tiles.indices.contains(Int(tileIndex)) else { continue }
                let range = state.tiles[Int(tileIndex)].fieldRange
                guard range.count > 0, range.count.isMultiple(of: 12) else { continue }
                let voxelCount = range.count / 12
                let lower = range.lowerBound &+ UInt32(channel) &* voxelCount
                fieldIndices.append(contentsOf: lower..<(lower &+ voxelCount))
            }
            indices = fieldIndices
        case .mechanismState:
            indices = state.compartments.compactMap { compartment in
                guard selectedCellSet.contains(compartment.neuronIndex),
                      binding.localOffset < compartment.mechanismRange.count else { return nil }
                return compartment.mechanismRange.lowerBound &+ binding.localOffset
            }
        case .molecularSpecies:
            indices = state.microdomains.compactMap { domain in
                guard selectedCellSet.contains(domain.ownerCellIndex),
                      binding.localOffset < domain.speciesRange.count else { return nil }
                return domain.speciesRange.lowerBound &+ binding.localOffset
            }
        case .regulatoryState:
            indices = selectedCells.compactMap { index in
                let range = state.cells[index].regulatoryRange
                guard binding.localOffset < range.count else { return nil }
                return range.lowerBound &+ binding.localOffset
            }
        default:
            indices = []
        }
        return Self.compress(indices.sorted())
    }

    private static func compress(_ sortedIndices: [UInt32]) -> [RuntimeRange] {
        guard let first = sortedIndices.first else { return [] }
        var result: [RuntimeRange] = []
        var lower = first
        var previous = first
        for index in sortedIndices.dropFirst() {
            if index == previous { continue }
            if index == previous &+ 1 {
                previous = index
                continue
            }
            result.append(RuntimeRange(lowerBound: lower, count: previous &- lower &+ 1))
            lower = index
            previous = index
        }
        result.append(RuntimeRange(lowerBound: lower, count: previous &- lower &+ 1))
        return result
    }
}

public struct RuntimeOverlayBinding: Sendable, Hashable {
    public var canonicalPath: String
    public var key: RuntimeOverlayGroupKey
    public var tableIndex: UInt32
    public var localOffset: UInt32
    public var flags: UInt16
    public var minimum: Float
    public var maximum: Float

    public init(
        canonicalPath: String,
        domain: RuntimeOverlayDomain,
        component: UInt16,
        tableIndex: UInt32 = 0,
        localOffset: UInt32 = 0,
        minimum: Float? = nil,
        maximum: Float? = nil
    ) {
        self.canonicalPath = canonicalPath
        self.key = RuntimeOverlayGroupKey(
            domain: domain,
            component: component,
            pathHash: RuntimeOverlayHash.string(canonicalPath)
        )
        self.tableIndex = tableIndex
        self.localOffset = localOffset
        var flags: UInt16 = 0
        if minimum != nil { flags |= RuntimeOverlayRecord.clampMinimumFlag }
        if maximum != nil { flags |= RuntimeOverlayRecord.clampMaximumFlag }
        self.flags = flags
        self.minimum = minimum ?? -.greatestFiniteMagnitude
        self.maximum = maximum ?? .greatestFiniteMagnitude
    }
}

public enum RuntimeOverlayPathRegistry {
    public static func resolve(
        _ sourcePath: String,
        state: TissueRuntimeState,
        model: CompiledTissueModel
    ) throws -> RuntimeOverlayBinding {
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch path {
        case "cell.energy_reserve": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.energyReserve, minimum: 0, maximum: 1)
        case "cell.oxygen_stress": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.oxygenStress, minimum: 0)
        case "cell.glucose_stress": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.glucoseStress, minimum: 0)
        case "cell.metabolic_stress": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.oxygenStress, minimum: 0)
        case "cell.damage": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.damage, minimum: 0, maximum: 1)
        case "cell.apoptosis_hazard": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.apoptosisHazard, minimum: 0)
        case "cell.cycle_progress": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.cycleProgress, minimum: 0, maximum: 1)
        case "cell.differentiation_progress": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.differentiationProgress, minimum: 0, maximum: 1)
        case "cell.age_seconds": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.ageSeconds, minimum: 0)
        case "cell.fidelity": return .init(canonicalPath: path, domain: .cellState, component: RuntimeOverlayComponent.Cell.fidelity, minimum: 0, maximum: 4)
        case "segment.radius_um": return .init(canonicalPath: path, domain: .segmentState, component: RuntimeOverlayComponent.Segment.radius, minimum: 0.01)
        case "segment.myelin_fraction": return .init(canonicalPath: path, domain: .segmentState, component: RuntimeOverlayComponent.Segment.myelinFraction, minimum: 0, maximum: 1)
        case "segment.growth_rate_um_s": return .init(canonicalPath: path, domain: .segmentState, component: RuntimeOverlayComponent.Segment.growthRate)
        case "segment.structural_score": return .init(canonicalPath: path, domain: .segmentState, component: RuntimeOverlayComponent.Segment.structuralScore)
        case "compartment.voltage_mv": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.voltage, minimum: -200, maximum: 150)
        case "compartment.capacitance_nf": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.capacitance, minimum: 1e-9)
        case "compartment.axial_conductance_us": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.axialConductance, minimum: 0)
        case "compartment.injected_current_na": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.injectedCurrent)
        case "compartment.synaptic_current_na": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.synapticCurrent)
        case "compartment.calcium_um": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.calcium, minimum: 0)
        case "compartment.sodium_mm": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.sodium, minimum: 0)
        case "compartment.potassium_mm": return .init(canonicalPath: path, domain: .compartmentState, component: RuntimeOverlayComponent.Compartment.potassium, minimum: 0)
        case "synapse.weight": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.weight, minimum: 0)
        case "synapse.conductance": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.conductance, minimum: 0)
        case "synapse.utilization": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.utilization, minimum: 0, maximum: 1)
        case "synapse.resources": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.resources, minimum: 0, maximum: 1)
        case "synapse.pre_trace": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.preTrace)
        case "synapse.post_trace": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.postTrace)
        case "synapse.eligibility": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.eligibility)
        case "synapse.consolidation": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.consolidation)
        case "synapse.structural_score": return .init(canonicalPath: path, domain: .synapseState, component: RuntimeOverlayComponent.Synapse.structuralScore)
        default: break
        }

        if let offset = suffixIndex(path, prefix: "mechanism.state.") {
            return .init(canonicalPath: path, domain: .mechanismState, component: 0, localOffset: offset)
        }
        if let offset = suffixIndex(path, prefix: "microdomain.species.") {
            return .init(canonicalPath: path, domain: .molecularSpecies, component: 0, localOffset: offset, minimum: 0)
        }
        if let offset = suffixIndex(path, prefix: "regulatory.state.") {
            return .init(canonicalPath: path, domain: .regulatoryState, component: 0, localOffset: offset)
        }
        if path.hasPrefix("field.channel.") {
            return try resolveFieldState(path)
        }
        if path.hasPrefix("model.") {
            return try resolveModelPath(path, model: model)
        }
        throw TissueInterventionError.unknownPath(sourcePath)
    }

    private static func resolveFieldState(_ path: String) throws -> RuntimeOverlayBinding {
        let pieces = path.split(separator: ".")
        guard pieces.count == 4 || pieces.count == 3,
              let channel = UInt32(pieces[2]), channel < 12 else {
            throw TissueInterventionError.unknownPath(path)
        }
        let componentName = pieces.count == 4 ? String(pieces[3]) : "concentration"
        let component: UInt16
        let minimum: Float?
        switch componentName {
        case "concentration": component = RuntimeOverlayComponent.Field.concentration; minimum = 0
        case "source": component = RuntimeOverlayComponent.Field.source; minimum = nil
        case "sink": component = RuntimeOverlayComponent.Field.sink; minimum = nil
        case "diffusion_scale": component = RuntimeOverlayComponent.Field.diffusionScale; minimum = 0
        default: throw TissueInterventionError.unknownPath(path)
        }
        return .init(canonicalPath: path, domain: .fieldState, component: component, localOffset: channel, minimum: minimum)
    }

    private static func resolveModelPath(_ path: String, model: CompiledTissueModel) throws -> RuntimeOverlayBinding {
        let pieces = path.split(separator: ".").map(String.init)
        guard pieces.count >= 4, let tableIndex = UInt32(pieces[2]) else {
            throw TissueInterventionError.unknownPath(path)
        }
        let table = pieces[1]
        let member = pieces.dropFirst(3).joined(separator: ".")
        let domain: RuntimeOverlayDomain
        let component: UInt16
        let count: Int
        var minimum: Float? = nil
        var maximum: Float? = nil

        switch table {
        case "channel":
            domain = .channelParameter; count = model.channelParameters.count
            switch member {
            case "maximum_conductance": component = RuntimeOverlayComponent.ChannelParameter.maximumConductance; minimum = 0
            case "reversal_potential_mv": component = RuntimeOverlayComponent.ChannelParameter.reversalPotential
            case "activation.0": component = RuntimeOverlayComponent.ChannelParameter.activation0
            case "activation.1": component = RuntimeOverlayComponent.ChannelParameter.activation1
            case "activation.2": component = RuntimeOverlayComponent.ChannelParameter.activation2
            case "activation.3": component = RuntimeOverlayComponent.ChannelParameter.activation3
            case "inactivation.0": component = RuntimeOverlayComponent.ChannelParameter.inactivation0
            case "inactivation.1": component = RuntimeOverlayComponent.ChannelParameter.inactivation1
            case "inactivation.2": component = RuntimeOverlayComponent.ChannelParameter.inactivation2
            case "inactivation.3": component = RuntimeOverlayComponent.ChannelParameter.inactivation3
            default: throw TissueInterventionError.unknownPath(path)
            }
        case "mechanism_set":
            domain = .mechanismSetParameter; count = model.mechanismSets.count
            switch member {
            case "temperature_c": component = RuntimeOverlayComponent.MechanismSetParameter.temperatureCelsius
            case "q10": component = RuntimeOverlayComponent.MechanismSetParameter.q10; minimum = 0
            case "thermal_scale": component = RuntimeOverlayComponent.MechanismSetParameter.thermalScale; minimum = 0
            default: throw TissueInterventionError.unknownPath(path)
            }
        case "synapse":
            domain = .synapseParameter; count = model.synapseParameters.count
            let map: [String: UInt16] = [
                "rise_ms": RuntimeOverlayComponent.SynapseParameter.riseMilliseconds,
                "decay_ms": RuntimeOverlayComponent.SynapseParameter.decayMilliseconds,
                "reversal_potential_mv": RuntimeOverlayComponent.SynapseParameter.reversalPotential,
                "default_weight": RuntimeOverlayComponent.SynapseParameter.defaultWeight,
                "utilization": RuntimeOverlayComponent.SynapseParameter.utilization,
                "recovery_decay": RuntimeOverlayComponent.SynapseParameter.recoveryDecay,
                "facilitation_decay": RuntimeOverlayComponent.SynapseParameter.facilitationDecay,
                "positive_amplitude": RuntimeOverlayComponent.SynapseParameter.positiveAmplitude,
                "negative_amplitude": RuntimeOverlayComponent.SynapseParameter.negativeAmplitude,
                "pre_trace_decay": RuntimeOverlayComponent.SynapseParameter.preTraceDecay,
                "post_trace_decay": RuntimeOverlayComponent.SynapseParameter.postTraceDecay,
                "eligibility_decay": RuntimeOverlayComponent.SynapseParameter.eligibilityDecay,
                "learning_rate": RuntimeOverlayComponent.SynapseParameter.learningRate,
                "minimum_weight": RuntimeOverlayComponent.SynapseParameter.minimumWeight,
                "maximum_weight": RuntimeOverlayComponent.SynapseParameter.maximumWeight
            ]
            guard let mapped = map[member] else { throw TissueInterventionError.unknownPath(path) }
            component = mapped
            if member != "reversal_potential_mv" && member != "negative_amplitude" { minimum = 0 }
            if member == "utilization" || member.hasSuffix("decay") { maximum = 1 }
        case "field":
            domain = .fieldParameter; count = model.fieldParameters.count
            switch member {
            case "diffusion_alpha": component = RuntimeOverlayComponent.FieldParameter.diffusionAlpha; minimum = 0
            case "decay": component = RuntimeOverlayComponent.FieldParameter.decay; minimum = 0; maximum = 1
            case "baseline": component = RuntimeOverlayComponent.FieldParameter.baseline; minimum = 0
            case "minimum": component = RuntimeOverlayComponent.FieldParameter.minimum
            case "maximum": component = RuntimeOverlayComponent.FieldParameter.maximum
            default: throw TissueInterventionError.unknownPath(path)
            }
        case "cell_program":
            domain = .cellProgramParameter; count = model.cellPrograms.count
            let map: [String: UInt16] = [
                "radius_um": RuntimeOverlayComponent.CellProgramParameter.radius,
                "mechanics.x": RuntimeOverlayComponent.CellProgramParameter.mechanicsX,
                "mechanics.y": RuntimeOverlayComponent.CellProgramParameter.mechanicsY,
                "mechanics.z": RuntimeOverlayComponent.CellProgramParameter.mechanicsZ,
                "capacitance": RuntimeOverlayComponent.CellProgramParameter.capacitance,
                "leak_conductance": RuntimeOverlayComponent.CellProgramParameter.leakConductance,
                "leak_reversal_mv": RuntimeOverlayComponent.CellProgramParameter.leakReversal,
                "spike_threshold_mv": RuntimeOverlayComponent.CellProgramParameter.spikeThreshold
            ]
            guard let mapped = map[member] else { throw TissueInterventionError.unknownPath(path) }
            component = mapped
            if member != "leak_reversal_mv" && member != "spike_threshold_mv" { minimum = 0 }
        case "regulatory":
            domain = .regulatoryProgramParameter; count = model.regulatoryPrograms.count
            if member.hasPrefix("time_constant."), let lane = UInt16(member.dropFirst("time_constant.".count)), lane < 8 {
                component = lane; minimum = 1e-9
            } else if member == "division_hazard" {
                component = RuntimeOverlayComponent.RegulatoryProgramParameter.divisionHazard; minimum = 0
            } else if member == "apoptosis_hazard" {
                component = RuntimeOverlayComponent.RegulatoryProgramParameter.apoptosisHazard; minimum = 0
            } else { throw TissueInterventionError.unknownPath(path) }
        case "fate":
            domain = .fateTransitionParameter; count = model.fateTransitions.count
            if member == "base_hazard" { component = RuntimeOverlayComponent.FateTransitionParameter.baseHazard; minimum = 0 }
            else if member == "minimum_age_seconds" { component = RuntimeOverlayComponent.FateTransitionParameter.minimumAge; minimum = 0 }
            else if member.hasPrefix("regulatory."), let lane = UInt16(member.dropFirst("regulatory.".count)), lane < 4 { component = 4 + lane }
            else if member.hasPrefix("field."), let lane = UInt16(member.dropFirst("field.".count)), lane < 4 { component = 8 + lane }
            else { throw TissueInterventionError.unknownPath(path) }
        case "growth":
            domain = .growthProgramParameter; count = model.growthPrograms.count
            let map: [String: UInt16] = [
                "speed_um_s": RuntimeOverlayComponent.GrowthProgramParameter.speed,
                "branch_hazard": RuntimeOverlayComponent.GrowthProgramParameter.branchHazard,
                "retraction_hazard": RuntimeOverlayComponent.GrowthProgramParameter.retractionHazard,
                "segment_length_um": RuntimeOverlayComponent.GrowthProgramParameter.segmentLength,
                "persistence": RuntimeOverlayComponent.GrowthProgramParameter.persistence,
                "attraction": RuntimeOverlayComponent.GrowthProgramParameter.attraction,
                "repulsion": RuntimeOverlayComponent.GrowthProgramParameter.repulsion,
                "fasciculation": RuntimeOverlayComponent.GrowthProgramParameter.fasciculation,
                "activity": RuntimeOverlayComponent.GrowthProgramParameter.activity,
                "noise": RuntimeOverlayComponent.GrowthProgramParameter.noise
            ]
            guard let mapped = map[member] else { throw TissueInterventionError.unknownPath(path) }
            component = mapped
            if member.contains("hazard") || member.contains("speed") || member.contains("length") || member == "noise" { minimum = 0 }
        case "glia":
            domain = .glialProgramParameter; count = model.glialPrograms.count
            if member.hasPrefix("uptake."), let lane = UInt16(member.dropFirst("uptake.".count)), lane < 4 { component = lane; minimum = 0 }
            else if member.hasPrefix("release."), let lane = UInt16(member.dropFirst("release.".count)), lane < 4 { component = 4 + lane; minimum = 0 }
            else if member.hasPrefix("threshold."), let lane = UInt16(member.dropFirst("threshold.".count)), lane < 4 { component = 8 + lane }
            else if member == "spatial_radius_um" { component = RuntimeOverlayComponent.GlialProgramParameter.spatialRadius; minimum = 0 }
            else { throw TissueInterventionError.unknownPath(path) }
        case "molecular_reaction":
            domain = .molecularReactionParameter; count = model.molecularReactions.count
            switch member {
            case "rate_constant": component = RuntimeOverlayComponent.MolecularReactionParameter.rateConstant; minimum = 0
            case "reverse_rate_constant": component = RuntimeOverlayComponent.MolecularReactionParameter.reverseRateConstant; minimum = 0
            default: throw TissueInterventionError.unknownPath(path)
            }
        default:
            throw TissueInterventionError.unknownPath(path)
        }
        guard Int(tableIndex) < count else { throw RuntimeOverlayError.modelParameterIndex(path, Int(tableIndex), count) }
        return .init(
            canonicalPath: path,
            domain: domain,
            component: component,
            tableIndex: tableIndex,
            minimum: minimum,
            maximum: maximum
        )
    }

    private static func suffixIndex(_ path: String, prefix: String) -> UInt32? {
        guard path.hasPrefix(prefix) else { return nil }
        return UInt32(path.dropFirst(prefix.count))
    }
}

public enum RuntimeOverlayHash {
    public static let offsetBasis: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3

    public static func string(_ value: String) -> UInt64 {
        var hash = offsetBasis
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    public static func combine(_ current: UInt64, _ value: UInt64) -> UInt64 {
        var hash = current
        var word = value.littleEndian
        withUnsafeBytes(of: &word) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash &*= prime
            }
        }
        return hash
    }
}

public enum RuntimeOverlayError: Error, Sendable, CustomStringConvertible {
    case localizedSharedParameter(String)
    case modelParameterIndex(String, Int, Int)
    case staleFrame(expected: UInt64, received: UInt64)
    case unsupportedComponent(RuntimeOverlayDomain, UInt16)

    public var description: String {
        switch self {
        case .localizedSharedParameter(let path):
            return "Shared compiled parameter \(path) requires selector .all; use a state path for a localized intervention"
        case .modelParameterIndex(let path, let index, let count):
            return "Model parameter path \(path) selects index \(index), but the table contains \(count) entries"
        case .staleFrame(let expected, let received):
            return "Intervention frame tick \(received) does not match transaction tick \(expected)"
        case .unsupportedComponent(let domain, let component):
            return "Overlay component \(component) is unsupported for domain \(domain)"
        }
    }
}

public extension RuntimeCellState {
    /// Compatibility view used by pharmacology/pathology plans that address one aggregate
    /// metabolic stress value. Setting it conservatively raises both limiting-substrate stresses.
    var metabolicStress: Float {
        get { max(oxygenStress, glucoseStress) }
        set {
            let value = max(newValue, 0)
            oxygenStress = value
            glucoseStress = value
        }
    }
}
