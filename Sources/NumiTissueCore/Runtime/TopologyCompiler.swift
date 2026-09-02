import Foundation

@frozen
public struct NTIndexRemap: Codable, Hashable, Sendable {
    public var oldToNew: [Int32]
    public var newToOld: [UInt32]

    public init(oldToNew: [Int32], newToOld: [UInt32]) {
        self.oldToNew = oldToNew
        self.newToOld = newToOld
    }

    public static func identity(count: Int) -> Self {
        Self(
            oldToNew: (0..<count).map { Int32($0) },
            newToOld: (0..<count).map { UInt32($0) }
        )
    }

    @inlinable
    public func newIndex(forOld old: Int) -> Int? {
        guard old >= 0, old < oldToNew.count else { return nil }
        let mapped = oldToNew[old]
        return mapped >= 0 ? Int(mapped) : nil
    }

    @inlinable
    public func oldIndex(forNew new: Int) -> Int? {
        guard new >= 0, new < newToOld.count else { return nil }
        return Int(newToOld[new])
    }
}

@frozen
public struct NTHinesLevel: Codable, Hashable, Sendable {
    public var level: UInt16
    public var compartmentIndices: [UInt32]

    public init(level: UInt16, compartmentIndices: [UInt32]) {
        self.level = level
        self.compartmentIndices = compartmentIndices
    }
}

@frozen
public struct NTHinesCellSchedule: Codable, Hashable, Sendable {
    public var cell: CellID
    public var rootIndices: [UInt32]
    public var eliminationLevels: [NTHinesLevel]
    public var substitutionLevels: [NTHinesLevel]
    public var compartmentCount: UInt32
    public var maximumDepth: UInt16
    public var mechanismSignature: UInt64

    public init(
        cell: CellID,
        rootIndices: [UInt32],
        eliminationLevels: [NTHinesLevel],
        substitutionLevels: [NTHinesLevel],
        compartmentCount: UInt32,
        maximumDepth: UInt16,
        mechanismSignature: UInt64
    ) {
        self.cell = cell
        self.rootIndices = rootIndices
        self.eliminationLevels = eliminationLevels
        self.substitutionLevels = substitutionLevels
        self.compartmentCount = compartmentCount
        self.maximumDepth = maximumDepth
        self.mechanismSignature = mechanismSignature
    }
}

public enum NTNeuronWorkClass: UInt8, Codable, CaseIterable, Sendable {
    case reduced2To8
    case simd16To32
    case multiSIMD33To128
    case threadgroup129To512
    case largeTree
}

@frozen
public struct NTNeuronCohort: Codable, Hashable, Sendable {
    public var workClass: NTNeuronWorkClass
    public var mechanismSignature: UInt64
    public var scheduleIndices: [UInt32]
    public var maximumCompartmentCount: UInt32
    public var maximumDepth: UInt16

    public init(
        workClass: NTNeuronWorkClass,
        mechanismSignature: UInt64,
        scheduleIndices: [UInt32],
        maximumCompartmentCount: UInt32,
        maximumDepth: UInt16
    ) {
        self.workClass = workClass
        self.mechanismSignature = mechanismSignature
        self.scheduleIndices = scheduleIndices
        self.maximumCompartmentCount = maximumCompartmentCount
        self.maximumDepth = maximumDepth
    }
}

@frozen
public struct NTTileWorklist: Codable, Hashable, Sendable {
    public var tile: TileID
    public var cellIndices: [UInt32]
    public var compartmentIndices: [UInt32]
    public var synapseIndices: [UInt32]
    public var microdomainIndices: [UInt32]
    public var neuronScheduleIndices: [UInt32]
    public var fieldBrickIndex: Int32
    public var flags: UInt32

    public init(
        tile: TileID,
        cellIndices: [UInt32],
        compartmentIndices: [UInt32],
        synapseIndices: [UInt32],
        microdomainIndices: [UInt32],
        neuronScheduleIndices: [UInt32],
        fieldBrickIndex: Int32,
        flags: UInt32 = 0
    ) {
        self.tile = tile
        self.cellIndices = cellIndices
        self.compartmentIndices = compartmentIndices
        self.synapseIndices = synapseIndices
        self.microdomainIndices = microdomainIndices
        self.neuronScheduleIndices = neuronScheduleIndices
        self.fieldBrickIndex = fieldBrickIndex
        self.flags = flags
    }
}

@frozen
public struct NTCompiledTopology: Codable, Sendable {
    public var generation: UInt64
    public var cellRemap: NTIndexRemap
    public var compartmentRemap: NTIndexRemap
    public var synapseRemap: NTIndexRemap
    public var neuronSchedules: [NTHinesCellSchedule]
    public var neuronCohorts: [NTNeuronCohort]
    public var tileWorklists: [NTTileWorklist]
    public var incomingSynapseOffsets: [UInt32]
    public var incomingSynapseIndices: [UInt32]
    public var outgoingSynapseOffsets: [UInt32]
    public var outgoingSynapseIndices: [UInt32]
    public var routeRecords: [NTRouteRecord]
    public var routeDestinationSynapseIndices: [UInt32]
    public var topologyFingerprint: UInt64

    public init(
        generation: UInt64,
        cellRemap: NTIndexRemap,
        compartmentRemap: NTIndexRemap,
        synapseRemap: NTIndexRemap,
        neuronSchedules: [NTHinesCellSchedule],
        neuronCohorts: [NTNeuronCohort],
        tileWorklists: [NTTileWorklist],
        incomingSynapseOffsets: [UInt32],
        incomingSynapseIndices: [UInt32],
        outgoingSynapseOffsets: [UInt32],
        outgoingSynapseIndices: [UInt32],
        routeRecords: [NTRouteRecord],
        routeDestinationSynapseIndices: [UInt32],
        topologyFingerprint: UInt64
    ) {
        self.generation = generation
        self.cellRemap = cellRemap
        self.compartmentRemap = compartmentRemap
        self.synapseRemap = synapseRemap
        self.neuronSchedules = neuronSchedules
        self.neuronCohorts = neuronCohorts
        self.tileWorklists = tileWorklists
        self.incomingSynapseOffsets = incomingSynapseOffsets
        self.incomingSynapseIndices = incomingSynapseIndices
        self.outgoingSynapseOffsets = outgoingSynapseOffsets
        self.outgoingSynapseIndices = outgoingSynapseIndices
        self.routeRecords = routeRecords
        self.routeDestinationSynapseIndices = routeDestinationSynapseIndices
        self.topologyFingerprint = topologyFingerprint
    }
}

@frozen
public struct NTTopologyCompileOptions: Codable, Hashable, Sendable {
    public var removeDeadCells: Bool
    public var removeOrphanCompartments: Bool
    public var removePrunedSynapses: Bool
    public var canonicalizeCells: Bool
    public var canonicalizeCompartments: Bool
    public var canonicalizeSynapses: Bool
    public var rebuildTileNeighbors: Bool
    public var preserveEmptyRoutes: Bool

    public init(
        removeDeadCells: Bool = true,
        removeOrphanCompartments: Bool = true,
        removePrunedSynapses: Bool = true,
        canonicalizeCells: Bool = true,
        canonicalizeCompartments: Bool = true,
        canonicalizeSynapses: Bool = true,
        rebuildTileNeighbors: Bool = true,
        preserveEmptyRoutes: Bool = false
    ) {
        self.removeDeadCells = removeDeadCells
        self.removeOrphanCompartments = removeOrphanCompartments
        self.removePrunedSynapses = removePrunedSynapses
        self.canonicalizeCells = canonicalizeCells
        self.canonicalizeCompartments = canonicalizeCompartments
        self.canonicalizeSynapses = canonicalizeSynapses
        self.rebuildTileNeighbors = rebuildTileNeighbors
        self.preserveEmptyRoutes = preserveEmptyRoutes
    }
}

@frozen
public struct NTTopologyCompileResult: Sendable {
    public var topology: NTCompiledTopology
    public var removedCellIDs: [CellID]
    public var removedCompartmentIDs: [CompartmentID]
    public var removedSynapseIDs: [SynapseID]
    public var diagnostics: [NTDiagnostic]

    public init(
        topology: NTCompiledTopology,
        removedCellIDs: [CellID],
        removedCompartmentIDs: [CompartmentID],
        removedSynapseIDs: [SynapseID],
        diagnostics: [NTDiagnostic]
    ) {
        self.topology = topology
        self.removedCellIDs = removedCellIDs
        self.removedCompartmentIDs = removedCompartmentIDs
        self.removedSynapseIDs = removedSynapseIDs
        self.diagnostics = diagnostics
    }
}

private struct NTNeuronCohortKey: Hashable {
    var workClass: NTNeuronWorkClass
    var mechanismSignature: UInt64
}

private struct NTRouteCompileKey: Hashable, Comparable {
    var route: RouteID
    var sourceCompartment: UInt32
    var delayTicks: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        if lhs.sourceCompartment != rhs.sourceCompartment { return lhs.sourceCompartment < rhs.sourceCompartment }
        return lhs.delayTicks < rhs.delayTicks
    }
}

/// Rebuilds every index-bearing structure at structural epoch boundaries. Stable entity IDs remain
/// unchanged; dense pool indices are allowed to move and are described by the returned remaps.
public struct NTTopologyCompiler: Sendable {
    public init() {}

    public func compile(
        state: inout NTProductionState,
        growthCones: inout [NTGrowthConeState],
        previousGeneration: UInt64 = 0,
        options: NTTopologyCompileOptions = .init()
    ) throws -> NTTopologyCompileResult {
        var diagnostics: [NTDiagnostic] = []
        let oldRoutes = Dictionary(uniqueKeysWithValues: state.routeTable.routes.map { ($0.id, $0) })

        let cellCompaction = compactCells(state: &state, options: options)
        let compartmentCompaction = try compactCompartments(
            state: &state,
            growthCones: &growthCones,
            liveCells: Set(state.cells.map { $0.record.id }),
            options: options,
            diagnostics: &diagnostics
        )
        let synapseCompaction = try compactSynapses(
            state: &state,
            compartmentRemap: compartmentCompaction.remap,
            options: options,
            diagnostics: &diagnostics
        )

        try state.rebuildIndices()
        let schedules = try compileHinesSchedules(state: &state, diagnostics: &diagnostics)
        let cohorts = compileCohorts(schedules: schedules)
        let adjacency = compileSynapseAdjacency(state: state)
        let routeCompilation = try compileRoutes(
            state: &state,
            oldRoutes: oldRoutes,
            preserveEmptyRoutes: options.preserveEmptyRoutes,
            diagnostics: &diagnostics
        )
        try state.routeTable.replace(
            routes: routeCompilation.records,
            compartmentCount: state.compartments.count
        )

        rebuildTileMemberships(state: &state, schedules: schedules)
        if options.rebuildTileNeighbors { rebuildTileNeighbors(state: &state) }
        let tileWorklists = compileTileWorklists(state: state, schedules: schedules)
        let topologyFingerprint = fingerprint(
            state: state,
            schedules: schedules,
            routes: routeCompilation.records,
            routeDestinations: routeCompilation.destinationIndices
        )
        let topology = NTCompiledTopology(
            generation: previousGeneration &+ 1,
            cellRemap: cellCompaction.remap,
            compartmentRemap: compartmentCompaction.remap,
            synapseRemap: synapseCompaction.remap,
            neuronSchedules: schedules,
            neuronCohorts: cohorts,
            tileWorklists: tileWorklists,
            incomingSynapseOffsets: adjacency.incomingOffsets,
            incomingSynapseIndices: adjacency.incomingIndices,
            outgoingSynapseOffsets: adjacency.outgoingOffsets,
            outgoingSynapseIndices: adjacency.outgoingIndices,
            routeRecords: routeCompilation.records,
            routeDestinationSynapseIndices: routeCompilation.destinationIndices,
            topologyFingerprint: topologyFingerprint
        )
        return NTTopologyCompileResult(
            topology: topology,
            removedCellIDs: cellCompaction.removed,
            removedCompartmentIDs: compartmentCompaction.removed,
            removedSynapseIDs: synapseCompaction.removed,
            diagnostics: diagnostics
        )
    }

    private func compactCells(
        state: inout NTProductionState,
        options: NTTopologyCompileOptions
    ) -> (remap: NTIndexRemap, removed: [CellID]) {
        let old = state.cells
        var kept: [(oldIndex: Int, value: NTProductionCell)] = []
        var removed: [CellID] = []
        kept.reserveCapacity(old.count)
        for (index, cell) in old.enumerated() {
            if options.removeDeadCells && cell.record.phase == .dead {
                removed.append(cell.record.id)
            } else {
                kept.append((index, cell))
            }
        }
        if options.canonicalizeCells {
            kept.sort {
                if $0.value.record.tile != $1.value.record.tile { return $0.value.record.tile < $1.value.record.tile }
                return $0.value.record.id < $1.value.record.id
            }
        }
        var oldToNew = Array(repeating: Int32(-1), count: old.count)
        var newToOld: [UInt32] = []
        newToOld.reserveCapacity(kept.count)
        for (newIndex, item) in kept.enumerated() {
            oldToNew[item.oldIndex] = Int32(newIndex)
            newToOld.append(UInt32(item.oldIndex))
        }
        state.cells = kept.map(\.value)
        return (NTIndexRemap(oldToNew: oldToNew, newToOld: newToOld), removed.sorted())
    }

    private func compactCompartments(
        state: inout NTProductionState,
        growthCones: inout [NTGrowthConeState],
        liveCells: Set<CellID>,
        options: NTTopologyCompileOptions,
        diagnostics: inout [NTDiagnostic]
    ) throws -> (remap: NTIndexRemap, removed: [CompartmentID]) {
        let old = state.compartments
        var kept: [(oldIndex: Int, value: NTProductionCompartment)] = []
        var removed: [CompartmentID] = []
        kept.reserveCapacity(old.count)
        for (index, compartment) in old.enumerated() {
            if options.removeOrphanCompartments && !liveCells.contains(compartment.record.cell) {
                removed.append(compartment.record.id)
            } else {
                kept.append((index, compartment))
            }
        }
        if options.canonicalizeCompartments {
            kept.sort {
                if $0.value.record.cell != $1.value.record.cell { return $0.value.record.cell < $1.value.record.cell }
                if $0.value.record.level != $1.value.record.level { return $0.value.record.level < $1.value.record.level }
                return $0.value.record.id < $1.value.record.id
            }
        }

        var oldToNew = Array(repeating: Int32(-1), count: old.count)
        var newToOld: [UInt32] = []
        newToOld.reserveCapacity(kept.count)
        for (newIndex, item) in kept.enumerated() {
            oldToNew[item.oldIndex] = Int32(newIndex)
            newToOld.append(UInt32(item.oldIndex))
        }
        var compacted = kept.map(\.value)
        for newIndex in compacted.indices {
            let oldIndex = Int(newToOld[newIndex])
            let oldParent = Int(old[oldIndex].record.parentIndex)
            if oldParent < 0 {
                compacted[newIndex].record.parentIndex = -1
            } else if oldParent < oldToNew.count, oldToNew[oldParent] >= 0 {
                compacted[newIndex].record.parentIndex = oldToNew[oldParent]
            } else {
                compacted[newIndex].record.parentIndex = -1
                diagnostics.append(.init(
                    severity: .warning,
                    code: .invalidMorphology,
                    message: "A compartment whose parent was removed was promoted to a root.",
                    entity: compacted[newIndex].record.id.rawValue,
                    tile: compacted[newIndex].record.tile
                ))
            }
        }
        state.compartments = compacted

        for index in growthCones.indices {
            let oldParent = Int(growthCones[index].parentCompartmentIndex)
            if oldParent < oldToNew.count, oldToNew[oldParent] >= 0 {
                growthCones[index].parentCompartmentIndex = UInt32(oldToNew[oldParent])
            } else {
                growthCones[index].active = false
                diagnostics.append(.init(
                    severity: .warning,
                    code: .invalidMorphology,
                    message: "A growth cone was deactivated because its parent compartment was removed.",
                    entity: growthCones[index].id.rawValue,
                    tile: growthCones[index].tile
                ))
            }
        }
        return (NTIndexRemap(oldToNew: oldToNew, newToOld: newToOld), removed.sorted())
    }

    private func compactSynapses(
        state: inout NTProductionState,
        compartmentRemap: NTIndexRemap,
        options: NTTopologyCompileOptions,
        diagnostics: inout [NTDiagnostic]
    ) throws -> (remap: NTIndexRemap, removed: [SynapseID]) {
        let old = state.synapses
        var kept: [(oldIndex: Int, value: NTProductionSynapse)] = []
        var removed: [SynapseID] = []
        kept.reserveCapacity(old.count)
        for (index, source) in old.enumerated() {
            var synapse = source
            let oldPre = Int(synapse.record.preCompartmentIndex)
            let oldPost = Int(synapse.record.postCompartmentIndex)
            guard let newPre = compartmentRemap.newIndex(forOld: oldPre),
                  let newPost = compartmentRemap.newIndex(forOld: oldPost) else {
                removed.append(synapse.record.id)
                diagnostics.append(.init(
                    severity: .information,
                    code: .invalidReference,
                    message: "A synapse was removed because one of its compartments no longer exists.",
                    entity: synapse.record.id.rawValue
                ))
                continue
            }
            if options.removePrunedSynapses && synapse.pendingDeletion {
                removed.append(synapse.record.id)
                continue
            }
            synapse.record.preCompartmentIndex = UInt32(newPre)
            synapse.record.postCompartmentIndex = UInt32(newPost)
            kept.append((index, synapse))
        }
        if options.canonicalizeSynapses {
            kept.sort {
                let left = $0.value.record
                let right = $1.value.record
                if left.route != right.route { return left.route < right.route }
                if left.preCompartmentIndex != right.preCompartmentIndex { return left.preCompartmentIndex < right.preCompartmentIndex }
                if left.delayTicks != right.delayTicks { return left.delayTicks < right.delayTicks }
                if left.postCompartmentIndex != right.postCompartmentIndex { return left.postCompartmentIndex < right.postCompartmentIndex }
                return left.id < right.id
            }
        }
        var oldToNew = Array(repeating: Int32(-1), count: old.count)
        var newToOld: [UInt32] = []
        newToOld.reserveCapacity(kept.count)
        for (newIndex, item) in kept.enumerated() {
            oldToNew[item.oldIndex] = Int32(newIndex)
            newToOld.append(UInt32(item.oldIndex))
        }
        state.synapses = kept.map(\.value)
        return (NTIndexRemap(oldToNew: oldToNew, newToOld: newToOld), removed.sorted())
    }

    private func compileHinesSchedules(
        state: inout NTProductionState,
        diagnostics: inout [NTDiagnostic]
    ) throws -> [NTHinesCellSchedule] {
        let grouped = Dictionary(grouping: state.compartments.indices) {
            state.compartments[$0].record.cell
        }
        var schedules: [NTHinesCellSchedule] = []
        schedules.reserveCapacity(grouped.count)
        for cell in grouped.keys.sorted() {
            guard let indices = grouped[cell] else { continue }
            let indexSet = Set(indices)
            var localDepth: [Int: UInt16] = [:]
            var roots: [UInt32] = []
            for index in indices {
                let parent = Int(state.compartments[index].record.parentIndex)
                if parent < 0 || !indexSet.contains(parent) { roots.append(UInt32(index)) }
            }
            if roots.isEmpty {
                throw NTRuntimeError.invalidModel("Compartment tree for cell \(cell) has no root.")
            }
            roots.sort()
            var visitState: [Int: UInt8] = [:]
            func depth(_ index: Int) throws -> UInt16 {
                if let existing = localDepth[index] { return existing }
                if visitState[index] == 1 {
                    throw NTRuntimeError.invalidModel("Compartment tree for cell \(cell) contains a cycle.")
                }
                visitState[index] = 1
                let parent = Int(state.compartments[index].record.parentIndex)
                let value: UInt16
                if parent < 0 || !indexSet.contains(parent) {
                    value = 0
                } else {
                    let parentDepth = try depth(parent)
                    guard parentDepth < UInt16.max else {
                        throw NTRuntimeError.invalidModel("Compartment tree depth exceeds UInt16 capacity.")
                    }
                    value = parentDepth &+ 1
                }
                visitState[index] = 2
                localDepth[index] = value
                return value
            }
            for index in indices {
                let value = try depth(index)
                state.compartments[index].record.level = value
            }
            let maximumDepth = localDepth.values.max() ?? 0
            var levels: [UInt16: [UInt32]] = [:]
            for index in indices {
                levels[localDepth[index, default: 0], default: []].append(UInt32(index))
            }
            let ascending = levels.keys.sorted().map {
                NTHinesLevel(level: $0, compartmentIndices: levels[$0, default: []].sorted())
            }
            let descending = ascending.reversed().map { $0 }
            var signature: UInt64 = 0xcbf2_9ce4_8422_2325
            for index in indices.sorted() {
                signature = fnv(signature, UInt64(state.compartments[index].record.mechanismSet))
                signature = fnv(signature, UInt64(state.compartments[index].record.compartmentClass.rawValue))
                signature = fnv(signature, UInt64(state.compartments[index].record.childCount))
            }
            schedules.append(.init(
                cell: cell,
                rootIndices: roots,
                eliminationLevels: descending,
                substitutionLevels: ascending,
                compartmentCount: UInt32(indices.count),
                maximumDepth: maximumDepth,
                mechanismSignature: signature
            ))
        }
        schedules.sort { $0.cell < $1.cell }
        return schedules
    }

    private func compileCohorts(schedules: [NTHinesCellSchedule]) -> [NTNeuronCohort] {
        var grouped: [NTNeuronCohortKey: [UInt32]] = [:]
        for (index, schedule) in schedules.enumerated() {
            let key = NTNeuronCohortKey(
                workClass: workClass(compartmentCount: Int(schedule.compartmentCount)),
                mechanismSignature: schedule.mechanismSignature
            )
            grouped[key, default: []].append(UInt32(index))
        }
        return grouped.keys.sorted {
            if $0.workClass.rawValue != $1.workClass.rawValue { return $0.workClass.rawValue < $1.workClass.rawValue }
            return $0.mechanismSignature < $1.mechanismSignature
        }.map { key in
            let indices = grouped[key, default: []].sorted()
            let selected = indices.map { schedules[Int($0)] }
            return NTNeuronCohort(
                workClass: key.workClass,
                mechanismSignature: key.mechanismSignature,
                scheduleIndices: indices,
                maximumCompartmentCount: selected.map(\.compartmentCount).max() ?? 0,
                maximumDepth: selected.map(\.maximumDepth).max() ?? 0
            )
        }
    }

    private func compileSynapseAdjacency(
        state: NTProductionState
    ) -> (incomingOffsets: [UInt32], incomingIndices: [UInt32], outgoingOffsets: [UInt32], outgoingIndices: [UInt32]) {
        var incoming = Array(repeating: [UInt32](), count: state.compartments.count)
        var outgoing = Array(repeating: [UInt32](), count: state.compartments.count)
        for (index, synapse) in state.synapses.enumerated() {
            let pre = Int(synapse.record.preCompartmentIndex)
            let post = Int(synapse.record.postCompartmentIndex)
            if outgoing.indices.contains(pre) { outgoing[pre].append(UInt32(index)) }
            if incoming.indices.contains(post) { incoming[post].append(UInt32(index)) }
        }
        var incomingOffsets: [UInt32] = [0]
        var outgoingOffsets: [UInt32] = [0]
        var incomingIndices: [UInt32] = []
        var outgoingIndices: [UInt32] = []
        for values in incoming {
            incomingIndices.append(contentsOf: values.sorted())
            incomingOffsets.append(UInt32(incomingIndices.count))
        }
        for values in outgoing {
            outgoingIndices.append(contentsOf: values.sorted())
            outgoingOffsets.append(UInt32(outgoingIndices.count))
        }
        return (incomingOffsets, incomingIndices, outgoingOffsets, outgoingIndices)
    }

    private func compileRoutes(
        state: inout NTProductionState,
        oldRoutes: [RouteID: NTRouteRecord],
        preserveEmptyRoutes: Bool,
        diagnostics: inout [NTDiagnostic]
    ) throws -> (records: [NTRouteRecord], destinationIndices: [UInt32]) {
        var groups: [NTRouteCompileKey: [UInt32]] = [:]
        for (index, synapse) in state.synapses.enumerated() {
            let key = NTRouteCompileKey(
                route: synapse.record.route,
                sourceCompartment: synapse.record.preCompartmentIndex,
                delayTicks: synapse.record.delayTicks
            )
            groups[key, default: []].append(UInt32(index))
        }
        var records: [NTRouteRecord] = []
        var destinations: [UInt32] = []
        var usedIDs: Set<RouteID> = []
        var nextSynthetic = max(
            state.routeTable.routes.map { $0.id.rawValue }.max() ?? 0,
            state.synapses.map { $0.record.route.rawValue }.max() ?? 0
        ) &+ 1

        for key in groups.keys.sorted() {
            let indices = groups[key, default: []].sorted()
            guard !indices.isEmpty else { continue }
            var routeID = key.route
            if usedIDs.contains(routeID) {
                routeID = RouteID(rawValue: nextSynthetic)
                nextSynthetic &+= 1
                diagnostics.append(.init(
                    severity: .information,
                    code: .topologyMutationConflict,
                    message: "A route with heterogeneous source or delay was split into a deterministic synthetic route.",
                    entity: key.route.rawValue
                ))
                for index in indices { state.synapses[Int(index)].record.route = routeID }
            }
            usedIDs.insert(routeID)
            let start = UInt32(destinations.count)
            destinations.append(contentsOf: indices)
            let old = oldRoutes[key.route]
            let firstSynapse = state.synapses[Int(indices[0])].record
            let post = Int(firstSynapse.postCompartmentIndex)
            guard state.compartments.indices.contains(post) else {
                throw NTRuntimeError.invalidModel("Compiled route references an absent postsynaptic compartment.")
            }
            records.append(.init(
                id: routeID,
                sourceCompartmentIndex: key.sourceCompartment,
                destinationSynapseStart: start,
                destinationSynapseCount: UInt32(indices.count),
                delayTicks: key.delayTicks,
                failureProbability: old?.failureProbability ?? 0,
                amplitudeScale: old?.amplitudeScale ?? 1,
                destinationTile: state.compartments[post].record.tile,
                flags: old?.flags ?? 0
            ))
        }

        if preserveEmptyRoutes {
            for old in oldRoutes.values.sorted(by: { $0.id < $1.id }) where !usedIDs.contains(old.id) {
                var empty = old
                empty.destinationSynapseStart = UInt32(destinations.count)
                empty.destinationSynapseCount = 0
                records.append(empty)
            }
        }
        records.sort { $0.id < $1.id }
        return (records, destinations)
    }

    private func rebuildTileMemberships(
        state: inout NTProductionState,
        schedules: [NTHinesCellSchedule]
    ) {
        var tileIndex: [TileID: Int] = [:]
        for index in state.tiles.indices {
            tileIndex[state.tiles[index].membership.id] = index
            state.tiles[index].membership.cellIndices.removeAll(keepingCapacity: true)
            state.tiles[index].membership.compartmentIndices.removeAll(keepingCapacity: true)
            state.tiles[index].membership.synapseIndices.removeAll(keepingCapacity: true)
            state.tiles[index].membership.microdomainIndices.removeAll(keepingCapacity: true)
        }
        for (index, cell) in state.cells.enumerated() {
            if let tile = tileIndex[cell.record.tile] { state.tiles[tile].membership.cellIndices.append(UInt32(index)) }
        }
        for (index, compartment) in state.compartments.enumerated() {
            if let tile = tileIndex[compartment.record.tile] { state.tiles[tile].membership.compartmentIndices.append(UInt32(index)) }
        }
        for (index, synapse) in state.synapses.enumerated() {
            let post = Int(synapse.record.postCompartmentIndex)
            if state.compartments.indices.contains(post),
               let tile = tileIndex[state.compartments[post].record.tile] {
                state.tiles[tile].membership.synapseIndices.append(UInt32(index))
            }
        }
        for (index, domain) in state.microdomains.enumerated() {
            if let tile = tileIndex[domain.tile] { state.tiles[tile].membership.microdomainIndices.append(UInt32(index)) }
        }
        for index in state.tiles.indices {
            state.tiles[index].membership.cellIndices.sort()
            state.tiles[index].membership.compartmentIndices.sort()
            state.tiles[index].membership.synapseIndices.sort()
            state.tiles[index].membership.microdomainIndices.sort()
        }
    }

    private func rebuildTileNeighbors(state: inout NTProductionState) {
        let offsets: [(Int32, Int32, Int32)] = (-1...1).flatMap { z in
            (-1...1).flatMap { y in
                (-1...1).compactMap { x in
                    (x == 0 && y == 0 && z == 0) ? nil : (Int32(x), Int32(y), Int32(z))
                }
            }
        }
        let byCoordinate = Dictionary(uniqueKeysWithValues: state.tiles.enumerated().map { ($0.element.membership.coordinate, Int32($0.offset)) })
        for index in state.tiles.indices {
            let coordinate = state.tiles[index].membership.coordinate
            state.tiles[index].membership.neighborTileIndices = offsets.map {
                byCoordinate[coordinate.neighbor(dx: $0.0, dy: $0.1, dz: $0.2)] ?? -1
            }
        }
    }

    private func compileTileWorklists(
        state: NTProductionState,
        schedules: [NTHinesCellSchedule]
    ) -> [NTTileWorklist] {
        var schedulesByTile: [TileID: [UInt32]] = [:]
        for (scheduleIndex, schedule) in schedules.enumerated() {
            guard let first = schedule.rootIndices.first,
                  state.compartments.indices.contains(Int(first)) else { continue }
            let tile = state.compartments[Int(first)].record.tile
            schedulesByTile[tile, default: []].append(UInt32(scheduleIndex))
        }
        let fieldIndex = Dictionary(uniqueKeysWithValues: state.fields.enumerated().map { ($0.element.tile, Int32($0.offset)) })
        return state.tiles.map { tile in
            NTTileWorklist(
                tile: tile.membership.id,
                cellIndices: tile.membership.cellIndices,
                compartmentIndices: tile.membership.compartmentIndices,
                synapseIndices: tile.membership.synapseIndices,
                microdomainIndices: tile.membership.microdomainIndices,
                neuronScheduleIndices: schedulesByTile[tile.membership.id, default: []].sorted(),
                fieldBrickIndex: fieldIndex[tile.membership.id] ?? -1,
                flags: tile.membership.flags
            )
        }.sorted { $0.tile < $1.tile }
    }

    private func workClass(compartmentCount: Int) -> NTNeuronWorkClass {
        switch compartmentCount {
        case 0...8: return .reduced2To8
        case 9...32: return .simd16To32
        case 33...128: return .multiSIMD33To128
        case 129...512: return .threadgroup129To512
        default: return .largeTree
        }
    }

    private func fingerprint(
        state: NTProductionState,
        schedules: [NTHinesCellSchedule],
        routes: [NTRouteRecord],
        routeDestinations: [UInt32]
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        hash = fnv(hash, UInt64(state.cells.count))
        hash = fnv(hash, UInt64(state.compartments.count))
        hash = fnv(hash, UInt64(state.synapses.count))
        hash = fnv(hash, UInt64(state.tiles.count))
        for cell in state.cells { hash = fnv(hash, cell.record.id.rawValue) }
        for compartment in state.compartments {
            hash = fnv(hash, compartment.record.id.rawValue)
            hash = fnv(hash, UInt64(bitPattern: Int64(compartment.record.parentIndex)))
            hash = fnv(hash, UInt64(compartment.record.mechanismSet))
        }
        for synapse in state.synapses {
            hash = fnv(hash, synapse.record.id.rawValue)
            hash = fnv(hash, synapse.record.route.rawValue)
            hash = fnv(hash, UInt64(synapse.record.preCompartmentIndex))
            hash = fnv(hash, UInt64(synapse.record.postCompartmentIndex))
        }
        for schedule in schedules { hash = fnv(hash, schedule.mechanismSignature) }
        for route in routes {
            hash = fnv(hash, route.id.rawValue)
            hash = fnv(hash, UInt64(route.destinationSynapseCount))
        }
        for destination in routeDestinations { hash = fnv(hash, UInt64(destination)) }
        return hash
    }

    @inline(__always)
    private func fnv(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var result = hash
        var remaining = value
        for _ in 0..<8 {
            result = (result ^ (remaining & 0xff)) &* 0x1000_0000_01b3
            remaining >>= 8
        }
        return result
    }
}
