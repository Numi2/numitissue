import Foundation
import NumiTissueCore
import NumiTissueModels

public enum StructuralMutationKind: UInt16, Codable, Sendable, CaseIterable {
    case createSynapse = 1
    case divideCell = 2
    case branchSegment = 3
    case retractSegment = 4
    case deleteCell = 5
}

@frozen
public struct StructuralMutationProposal: Codable, Sendable, Hashable {
    public var kind: StructuralMutationKind
    public var source: UInt64
    public var destination: UInt64
    public var amplitude: Float
    public var payload: Float4
    public var sequence: UInt32

    public init(
        kind: StructuralMutationKind,
        source: UInt64,
        destination: UInt64 = 0,
        amplitude: Float = 0,
        payload: Float4 = .zero,
        sequence: UInt32 = 0
    ) {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.amplitude = amplitude
        self.payload = payload
        self.sequence = sequence
    }
}

@frozen
public struct StructuralIndexTransfer: Codable, Sendable, Hashable {
    public var cells: [UInt32]
    public var segments: [UInt32]
    public var compartments: [UInt32]
    public var synapses: [UInt32]
    public var microdomains: [UInt32]

    public init(
        cells: [UInt32],
        segments: [UInt32],
        compartments: [UInt32],
        synapses: [UInt32],
        microdomains: [UInt32]
    ) {
        self.cells = cells
        self.segments = segments
        self.compartments = compartments
        self.synapses = synapses
        self.microdomains = microdomains
    }
}

@frozen
public struct StructuralTopologyPlan: Codable, Sendable, Hashable {
    public var transaction: TransactionID
    public var requested: Int
    public var applied: Int
    public var ignored: Int
    public var createdCells: Int
    public var deletedCells: Int
    public var createdSegments: Int
    public var deletedSegments: Int
    public var createdSynapses: Int
    public var deletedSynapses: Int
    public var transfer: StructuralIndexTransfer
    public var requiresBufferReallocation: Bool

    public init(
        transaction: TransactionID,
        requested: Int,
        applied: Int,
        ignored: Int,
        createdCells: Int,
        deletedCells: Int,
        createdSegments: Int,
        deletedSegments: Int,
        createdSynapses: Int,
        deletedSynapses: Int,
        transfer: StructuralIndexTransfer,
        requiresBufferReallocation: Bool
    ) {
        self.transaction = transaction
        self.requested = requested
        self.applied = applied
        self.ignored = ignored
        self.createdCells = createdCells
        self.deletedCells = deletedCells
        self.createdSegments = createdSegments
        self.deletedSegments = deletedSegments
        self.createdSynapses = createdSynapses
        self.deletedSynapses = deletedSynapses
        self.transfer = transfer
        self.requiresBufferReallocation = requiresBufferReallocation
    }
}

public enum StructuralTopologyError: Error, Sendable, CustomStringConvertible {
    case missingSource(StructuralMutationKind, UInt64)
    case invalidTile(UInt32)
    case invalidCell(UInt32)
    case invalidCompartment(UInt32)
    case invalidSegment(UInt32)
    case capacity(String)
    case nonFinitePayload(UInt32)

    public var description: String {
        switch self {
        case .missingSource(let kind, let id):
            return "Structural mutation \(kind) references missing source \(id)"
        case .invalidTile(let index):
            return "Structural mutation references invalid tile \(index)"
        case .invalidCell(let index):
            return "Structural mutation references invalid cell \(index)"
        case .invalidCompartment(let index):
            return "Structural mutation references invalid compartment \(index)"
        case .invalidSegment(let index):
            return "Structural mutation references invalid segment \(index)"
        case .capacity(let pool):
            return "Structural mutation exceeded configured \(pool) capacity"
        case .nonFinitePayload(let sequence):
            return "Structural mutation \(sequence) contains non-finite payload"
        }
    }
}

/// Applies development and glial topology changes as one deterministic state transaction. The
/// engine never mutates a compiled model. It rebuilds every index-bearing runtime pool and emits
/// complete old-to-new transfer tables for GPU migration and downstream provenance.
public struct StructuralTopologyEngine: Sendable {
    public var compactPrunedSynapses: Bool
    public var minimumRetractedLengthMicrometers: Float
    public var defaultSynapticDelayTicks: UInt32

    public init(
        compactPrunedSynapses: Bool = true,
        minimumRetractedLengthMicrometers: Float = 0.1,
        defaultSynapticDelayTicks: UInt32 = 40
    ) {
        self.compactPrunedSynapses = compactPrunedSynapses
        self.minimumRetractedLengthMicrometers = minimumRetractedLengthMicrometers
        self.defaultSynapticDelayTicks = defaultSynapticDelayTicks
    }

    public func apply(
        proposals: [StructuralMutationProposal],
        to state: inout TissueRuntimeState,
        model: CompiledTissueModel,
        transaction: TransactionID
    ) throws -> StructuralTopologyPlan? {
        let ordered = try normalized(proposals)
        let originalCounts = PoolCounts(state)
        var cells = state.cells
        var segments = state.segments
        let cellByID = Dictionary(uniqueKeysWithValues: cells.indices.map { (cells[$0].id.rawValue, $0) })
        let segmentByID = Dictionary(uniqueKeysWithValues: segments.indices.map { (segments[$0].id.rawValue, $0) })

        var identifierFactory = StructuralIdentifierFactory(
            transaction: transaction.rawValue,
            existing: Set(
                cells.map(\.id.rawValue) +
                segments.map(\.id.rawValue) +
                state.synapses.map(\.id.rawValue) +
                state.microdomains.map(\.id.rawValue)
            )
        )
        var deletedCells = Set<Int>()
        var deletedSegments = Set<Int>()
        var pendingCells: [PendingCell] = []
        var pendingSegments: [PendingSegment] = []
        var pendingSynapses: [PendingSynapse] = []
        var applied = 0
        var ignored = 0

        for proposal in ordered {
            switch proposal.kind {
            case .divideCell:
                guard let parentIndex = resolveCell(proposal, byID: cellByID, count: cells.count) else {
                    ignored += 1
                    continue
                }
                guard !deletedCells.contains(parentIndex) else {
                    ignored += 1
                    continue
                }
                let parent = cells[parentIndex]
                guard state.tiles.indices.contains(Int(parent.tileIndex)) else {
                    throw StructuralTopologyError.invalidTile(parent.tileIndex)
                }
                let scale = pow(0.5 as Float, 1.0 / 3.0)
                let regulatory = slice(
                    state.regulatoryState,
                    range: parent.regulatoryRange
                )
                let direction = deterministicDirection(
                    seed: proposal.sequence,
                    source: proposal.source
                )
                var child = parent
                child.id = CellID(rawValue: identifierFactory.next(tag: 0x43454C4C, source: proposal.source, ordinal: proposal.sequence))
                child.position += direction * max(parent.semiAxes.x, 0.1)
                child.velocity = .zero
                child.semiAxes *= Float4(repeating: scale)
                child.ageSeconds = 0
                child.cycleProgress = 0
                child.differentiationProgress = max(parent.differentiationProgress * 0.5, 0)
                child.energyReserve = max(parent.energyReserve * 0.5, 0)
                child.damage = max(parent.damage * 0.5, 0)
                child.apoptosisHazard = 0
                child.fidelity = .cellAgent
                child.regulatoryRange = RuntimeRange(lowerBound: 0, count: UInt32(regulatory.count))

                cells[parentIndex].semiAxes *= Float4(repeating: scale)
                cells[parentIndex].energyReserve = max(parent.energyReserve - child.energyReserve, 0)
                cells[parentIndex].cycleProgress = 0
                pendingCells.append(PendingCell(cell: child, regulatory: regulatory, parentOldIndex: parentIndex))
                applied += 1

            case .deleteCell:
                guard let index = resolveCell(proposal, byID: cellByID, count: cells.count) else {
                    ignored += 1
                    continue
                }
                if deletedCells.insert(index).inserted { applied += 1 } else { ignored += 1 }

            case .branchSegment:
                guard let sourceIndex = resolveSegment(proposal, byID: segmentByID, count: segments.count) else {
                    ignored += 1
                    continue
                }
                let source = segments[sourceIndex]
                guard cells.indices.contains(Int(source.cellIndex)),
                      !deletedCells.contains(Int(source.cellIndex)) else {
                    ignored += 1
                    continue
                }
                var direction = Float4(proposal.payload.x, proposal.payload.y, proposal.payload.z, 0)
                direction = normalize3(direction, fallback: normalize3(source.end - source.start))
                let length = max(length3(source.end - source.start), 1)
                let start = source.end
                let end = start + direction * min(length, 2)
                let segment = RuntimeSegmentState(
                    id: SegmentID(rawValue: identifierFactory.next(tag: 0x5345474D, source: proposal.source, ordinal: proposal.sequence)),
                    cellIndex: source.cellIndex,
                    parentSegmentIndex: UInt32(sourceIndex),
                    compartmentIndex: UInt32.max,
                    type: SegmentKind.growthCone.rawValue,
                    flags: 1,
                    start: start,
                    end: end,
                    radiusMicrometers: max(source.radiusMicrometers * 0.8, 0.05),
                    myelinFraction: 0,
                    growthRateMicrometersPerSecond: max(source.growthRateMicrometersPerSecond, 0),
                    structuralScore: 0.5,
                )
                pendingSegments.append(PendingSegment(segment: segment, parentOldIndex: sourceIndex))
                applied += 1

            case .retractSegment:
                guard let sourceIndex = resolveSegment(proposal, byID: segmentByID, count: segments.count) else {
                    ignored += 1
                    continue
                }
                guard !deletedSegments.contains(sourceIndex) else {
                    ignored += 1
                    continue
                }
                let vector = segments[sourceIndex].end - segments[sourceIndex].start
                let length = length3(vector)
                let requested = max(proposal.payload.x, proposal.amplitude, 0)
                let remaining = max(length - requested, 0)
                if remaining <= minimumRetractedLengthMicrometers {
                    deletedSegments.insert(sourceIndex)
                } else {
                    segments[sourceIndex].end = segments[sourceIndex].start + normalize3(vector) * remaining
                    segments[sourceIndex].structuralScore *= 0.9
                }
                applied += 1

            case .createSynapse:
                guard let sourceSegment = segmentByID[proposal.source],
                      let targetSegment = segmentByID[proposal.destination] else {
                    ignored += 1
                    continue
                }
                pendingSynapses.append(
                    PendingSynapse(
                        sourceSegmentOldIndex: sourceSegment,
                        targetSegmentOldIndex: targetSegment,
                        parameterIndex: UInt16(clamping: Int(max(proposal.payload.z, 0))),
                        source: proposal.source,
                        sequence: proposal.sequence
                    )
                )
                applied += 1
            }
        }

        expandDeletedSegments(
            segments: segments,
            deletedCells: deletedCells,
            deletedSegments: &deletedSegments
        )
        let result = try repack(
            state: state,
            model: model,
            cells: cells,
            segments: segments,
            deletedCells: deletedCells,
            deletedSegments: deletedSegments,
            pendingCells: pendingCells,
            pendingSegments: pendingSegments,
            pendingSynapses: pendingSynapses,
            identifierFactory: &identifierFactory
        )

        guard applied > 0 || result.deletedPrunedSynapses > 0 else { return nil }
        state = result.state
        do {
            try state.validateCapacity()
        } catch {
            throw StructuralTopologyError.capacity(String(describing: error))
        }

        let finalCounts = PoolCounts(state)
        return StructuralTopologyPlan(
            transaction: transaction,
            requested: ordered.count,
            applied: applied,
            ignored: ignored,
            createdCells: finalCounts.cells - originalCounts.cells + deletedCells.count,
            deletedCells: deletedCells.count,
            createdSegments: finalCounts.segments - originalCounts.segments + result.deletedSegmentCount,
            deletedSegments: result.deletedSegmentCount,
            createdSynapses: result.createdSynapseCount,
            deletedSynapses: originalCounts.synapses + result.createdSynapseCount - finalCounts.synapses,
            transfer: result.transfer,
            requiresBufferReallocation: originalCounts != finalCounts
        )
    }

    private func normalized(
        _ proposals: [StructuralMutationProposal]
    ) throws -> [StructuralMutationProposal] {
        for proposal in proposals {
            guard proposal.amplitude.isFinite,
                  proposal.payload.x.isFinite,
                  proposal.payload.y.isFinite,
                  proposal.payload.z.isFinite,
                  proposal.payload.w.isFinite else {
                throw StructuralTopologyError.nonFinitePayload(proposal.sequence)
            }
        }
        return proposals.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.destination < $1.destination
        }
    }

    private func resolveCell(
        _ proposal: StructuralMutationProposal,
        byID: [UInt64: Int],
        count: Int
    ) -> Int? {
        if let value = byID[proposal.source] { return value }
        let payload = Int(proposal.payload.x)
        return payload >= 0 && payload < count ? payload : nil
    }

    private func resolveSegment(
        _ proposal: StructuralMutationProposal,
        byID: [UInt64: Int],
        count: Int
    ) -> Int? {
        if let value = byID[proposal.source] { return value }
        let payload = Int(proposal.payload.x)
        return payload >= 0 && payload < count ? payload : nil
    }

    private func expandDeletedSegments(
        segments: [RuntimeSegmentState],
        deletedCells: Set<Int>,
        deletedSegments: inout Set<Int>
    ) {
        for index in segments.indices where deletedCells.contains(Int(segments[index].cellIndex)) {
            deletedSegments.insert(index)
        }
        var changed = true
        while changed {
            changed = false
            for index in segments.indices where !deletedSegments.contains(index) {
                let parent = segments[index].parentSegmentIndex
                if parent != UInt32.max,
                   deletedSegments.contains(Int(parent)) {
                    deletedSegments.insert(index)
                    changed = true
                }
            }
        }
    }

    private func repack(
        state: TissueRuntimeState,
        model: CompiledTissueModel,
        cells: [RuntimeCellState],
        segments: [RuntimeSegmentState],
        deletedCells: Set<Int>,
        deletedSegments: Set<Int>,
        pendingCells: [PendingCell],
        pendingSegments: [PendingSegment],
        pendingSynapses: [PendingSynapse],
        identifierFactory: inout StructuralIdentifierFactory
    ) throws -> RepackResult {
        var cellEntries: [CellEntry] = []
        for oldIndex in cells.indices where !deletedCells.contains(oldIndex) {
            cellEntries.append(
                CellEntry(
                    value: cells[oldIndex],
                    regulatory: slice(state.regulatoryState, range: cells[oldIndex].regulatoryRange),
                    oldIndex: oldIndex
                )
            )
        }
        cellEntries.append(contentsOf: pendingCells.map {
            CellEntry(value: $0.cell, regulatory: $0.regulatory, oldIndex: nil)
        })
        cellEntries.sort {
            if $0.value.tileIndex != $1.value.tileIndex { return $0.value.tileIndex < $1.value.tileIndex }
            return $0.value.id.rawValue < $1.value.id.rawValue
        }

        var oldCellToNew = Array(repeating: UInt32.max, count: state.cells.count)
        var newCells: [RuntimeCellState] = []
        var newRegulatory: [Float] = []
        newCells.reserveCapacity(cellEntries.count)
        for (newIndex, entry) in cellEntries.enumerated() {
            var cell = entry.value
            cell.regulatoryRange = RuntimeRange(
                lowerBound: UInt32(newRegulatory.count),
                count: UInt32(entry.regulatory.count)
            )
            if let oldIndex = entry.oldIndex { oldCellToNew[oldIndex] = UInt32(newIndex) }
            newRegulatory.append(contentsOf: entry.regulatory)
            newCells.append(cell)
        }

        var removedCompartments = Set<Int>()
        for index in state.compartments.indices where deletedCells.contains(Int(state.compartments[index].neuronIndex)) {
            removedCompartments.insert(index)
        }
        for index in deletedSegments {
            let compartment = segments[index].compartmentIndex
            if compartment != UInt32.max { removedCompartments.insert(Int(compartment)) }
        }
        var changed = true
        while changed {
            changed = false
            for index in state.compartments.indices where !removedCompartments.contains(index) {
                let parent = state.compartments[index].parentIndex
                if parent != UInt32.max && removedCompartments.contains(Int(parent)) {
                    removedCompartments.insert(index)
                    changed = true
                }
            }
        }

        var compartmentEntries: [CompartmentEntry] = []
        for oldIndex in state.compartments.indices where !removedCompartments.contains(oldIndex) {
            let old = state.compartments[oldIndex]
            guard oldCellToNew.indices.contains(Int(old.neuronIndex)),
                  oldCellToNew[Int(old.neuronIndex)] != UInt32.max else { continue }
            compartmentEntries.append(
                CompartmentEntry(
                    value: old,
                    mechanism: slice(state.mechanismState, range: old.mechanismRange),
                    oldIndex: oldIndex,
                    newCellIndex: oldCellToNew[Int(old.neuronIndex)]
                )
            )
        }
        compartmentEntries.sort {
            if $0.newCellIndex != $1.newCellIndex { return $0.newCellIndex < $1.newCellIndex }
            return $0.value.id.rawValue < $1.value.id.rawValue
        }

        var oldCompartmentToNew = Array(repeating: UInt32.max, count: state.compartments.count)
        var newCompartments: [RuntimeCompartmentState] = []
        var newMechanismState: [Float] = []
        for (newIndex, entry) in compartmentEntries.enumerated() {
            var compartment = entry.value
            oldCompartmentToNew[entry.oldIndex] = UInt32(newIndex)
            compartment.neuronIndex = entry.newCellIndex
            if compartment.parentIndex != UInt32.max {
                let parent = Int(compartment.parentIndex)
                compartment.parentIndex = oldCompartmentToNew.indices.contains(parent)
                    ? oldCompartmentToNew[parent]
                    : UInt32.max
            }
            compartment.mechanismRange = RuntimeRange(
                lowerBound: UInt32(newMechanismState.count),
                count: UInt32(entry.mechanism.count)
            )
            compartment.synapseRange = RuntimeRange(lowerBound: 0, count: 0)
            newMechanismState.append(contentsOf: entry.mechanism)
            newCompartments.append(compartment)
        }

        var segmentEntries: [SegmentEntry] = []
        for oldIndex in segments.indices where !deletedSegments.contains(oldIndex) {
            let old = segments[oldIndex]
            guard oldCellToNew.indices.contains(Int(old.cellIndex)),
                  oldCellToNew[Int(old.cellIndex)] != UInt32.max else { continue }
            segmentEntries.append(
                SegmentEntry(
                    value: old,
                    oldIndex: oldIndex,
                    newCellIndex: oldCellToNew[Int(old.cellIndex)],
                    parentOldIndex: old.parentSegmentIndex == UInt32.max ? nil : Int(old.parentSegmentIndex),
                    compartmentOldIndex: old.compartmentIndex == UInt32.max ? nil : Int(old.compartmentIndex)
                )
            )
        }
        for pending in pendingSegments {
            guard oldCellToNew.indices.contains(Int(pending.segment.cellIndex)),
                  oldCellToNew[Int(pending.segment.cellIndex)] != UInt32.max else { continue }
            segmentEntries.append(
                SegmentEntry(
                    value: pending.segment,
                    oldIndex: nil,
                    newCellIndex: oldCellToNew[Int(pending.segment.cellIndex)],
                    parentOldIndex: pending.parentOldIndex,
                    compartmentOldIndex: nil
                )
            )
        }
        segmentEntries.sort {
            if $0.newCellIndex != $1.newCellIndex { return $0.newCellIndex < $1.newCellIndex }
            switch ($0.oldIndex, $1.oldIndex) {
            case let (left?, right?) where left != right: return left < right
            case (nil, _?): return false
            case (_?, nil): return true
            default: return $0.value.id.rawValue < $1.value.id.rawValue
            }
        }

        var oldSegmentToNew = Array(repeating: UInt32.max, count: state.segments.count)
        for (newIndex, entry) in segmentEntries.enumerated() {
            if let oldIndex = entry.oldIndex { oldSegmentToNew[oldIndex] = UInt32(newIndex) }
        }
        var newSegments: [RuntimeSegmentState] = []
        newSegments.reserveCapacity(segmentEntries.count)
        for entry in segmentEntries {
            var segment = entry.value
            segment.cellIndex = entry.newCellIndex
            if let parent = entry.parentOldIndex,
               oldSegmentToNew.indices.contains(parent) {
                segment.parentSegmentIndex = oldSegmentToNew[parent]
            } else {
                segment.parentSegmentIndex = UInt32.max
            }
            if let compartment = entry.compartmentOldIndex,
               oldCompartmentToNew.indices.contains(compartment) {
                segment.compartmentIndex = oldCompartmentToNew[compartment]
            } else {
                segment.compartmentIndex = UInt32.max
            }
            newSegments.append(segment)
        }

        var synapseEntries: [SynapseEntry] = []
        var deletedPrunedSynapses = 0
        for oldIndex in state.synapses.indices {
            let old = state.synapses[oldIndex]
            if compactPrunedSynapses && (old.flags & (1 << 1)) != 0 {
                deletedPrunedSynapses += 1
                continue
            }
            let source = Int(old.sourceRouteIndex)
            let target = Int(old.targetCompartmentIndex)
            guard oldCompartmentToNew.indices.contains(source),
                  oldCompartmentToNew.indices.contains(target),
                  oldCompartmentToNew[source] != UInt32.max,
                  oldCompartmentToNew[target] != UInt32.max else { continue }
            var value = old
            value.sourceRouteIndex = oldCompartmentToNew[source]
            value.targetCompartmentIndex = oldCompartmentToNew[target]
            synapseEntries.append(SynapseEntry(value: value, oldIndex: oldIndex))
        }

        var existingConnections = Set<ConnectionKey>()
        for entry in synapseEntries {
            existingConnections.insert(
                ConnectionKey(
                    source: entry.value.sourceRouteIndex,
                    target: entry.value.targetCompartmentIndex,
                    parameter: entry.value.parameterIndex
                )
            )
        }
        var createdSynapses = 0
        for pending in pendingSynapses {
            guard oldSegmentToNew.indices.contains(pending.sourceSegmentOldIndex),
                  oldSegmentToNew.indices.contains(pending.targetSegmentOldIndex) else { continue }
            let sourceSegmentNew = oldSegmentToNew[pending.sourceSegmentOldIndex]
            let targetSegmentNew = oldSegmentToNew[pending.targetSegmentOldIndex]
            guard sourceSegmentNew != UInt32.max,
                  targetSegmentNew != UInt32.max else { continue }
            let sourceCompartment = newSegments[Int(sourceSegmentNew)].compartmentIndex
            let targetCompartment = newSegments[Int(targetSegmentNew)].compartmentIndex
            guard sourceCompartment != UInt32.max,
                  targetCompartment != UInt32.max else { continue }
            let parameter = model.synapseParameters.indices.contains(Int(pending.parameterIndex))
                ? pending.parameterIndex
                : 0
            let key = ConnectionKey(
                source: sourceCompartment,
                target: targetCompartment,
                parameter: parameter
            )
            guard existingConnections.insert(key).inserted else { continue }
            let compiled = model.synapseParameters.indices.contains(Int(parameter))
                ? model.synapseParameters[Int(parameter)]
                : nil
            let defaultWeight = compiled?.kinetics.w ?? 0.001
            let utilization = compiled?.shortTerm.x ?? 0.2
            let synapse = RuntimeSynapseState(
                id: SynapseID(rawValue: identifierFactory.next(tag: 0x53594E41, source: pending.source, ordinal: pending.sequence)),
                sourceRouteIndex: sourceCompartment,
                targetCompartmentIndex: targetCompartment,
                parameterIndex: parameter,
                flags: 0,
                delayTicks: defaultSynapticDelayTicks,
                weight: max(defaultWeight, 0),
                conductance: 0,
                shortTermUtilization: min(max(utilization, 0), 1),
                shortTermResources: 1,
                preTrace: 0,
                postTrace: 0,
                eligibility: 0,
                consolidation: 0,
                structuralScore: 0.5,
                lastEventTick: 0
            )
            synapseEntries.append(SynapseEntry(value: synapse, oldIndex: nil))
            createdSynapses += 1
        }
        synapseEntries.sort {
            if $0.value.targetCompartmentIndex != $1.value.targetCompartmentIndex {
                return $0.value.targetCompartmentIndex < $1.value.targetCompartmentIndex
            }
            if $0.value.sourceRouteIndex != $1.value.sourceRouteIndex {
                return $0.value.sourceRouteIndex < $1.value.sourceRouteIndex
            }
            return $0.value.id.rawValue < $1.value.id.rawValue
        }

        var oldSynapseToNew = Array(repeating: UInt32.max, count: state.synapses.count)
        var newSynapses: [RuntimeSynapseState] = []
        newSynapses.reserveCapacity(synapseEntries.count)
        for (newIndex, entry) in synapseEntries.enumerated() {
            if let oldIndex = entry.oldIndex { oldSynapseToNew[oldIndex] = UInt32(newIndex) }
            newSynapses.append(entry.value)
        }
        var synapseCursor = 0
        for compartmentIndex in newCompartments.indices {
            let lower = synapseCursor
            while synapseCursor < newSynapses.count,
                  newSynapses[synapseCursor].targetCompartmentIndex == UInt32(compartmentIndex) {
                synapseCursor += 1
            }
            newCompartments[compartmentIndex].synapseRange = RuntimeRange(
                lowerBound: UInt32(lower),
                count: UInt32(synapseCursor - lower)
            )
        }

        var microdomainEntries: [MicrodomainEntry] = []
        for oldIndex in state.microdomains.indices {
            let old = state.microdomains[oldIndex]
            guard oldCellToNew.indices.contains(Int(old.ownerCellIndex)),
                  oldCellToNew[Int(old.ownerCellIndex)] != UInt32.max else { continue }
            var value = old
            value.ownerCellIndex = oldCellToNew[Int(old.ownerCellIndex)]
            if old.ownerCompartmentIndex != UInt32.max {
                let owner = Int(old.ownerCompartmentIndex)
                guard oldCompartmentToNew.indices.contains(owner),
                      oldCompartmentToNew[owner] != UInt32.max else { continue }
                value.ownerCompartmentIndex = oldCompartmentToNew[owner]
            }
            microdomainEntries.append(
                MicrodomainEntry(
                    value: value,
                    species: slice(state.molecularSpecies, range: old.speciesRange),
                    oldIndex: oldIndex
                )
            )
        }
        microdomainEntries.sort {
            if $0.value.ownerCellIndex != $1.value.ownerCellIndex {
                return $0.value.ownerCellIndex < $1.value.ownerCellIndex
            }
            return $0.value.id.rawValue < $1.value.id.rawValue
        }
        var oldMicrodomainToNew = Array(repeating: UInt32.max, count: state.microdomains.count)
        var newMicrodomains: [RuntimeMicrodomainState] = []
        var newMolecularSpecies: [Float] = []
        for (newIndex, entry) in microdomainEntries.enumerated() {
            var value = entry.value
            oldMicrodomainToNew[entry.oldIndex] = UInt32(newIndex)
            value.speciesRange = RuntimeRange(
                lowerBound: UInt32(newMolecularSpecies.count),
                count: UInt32(entry.species.count)
            )
            newMolecularSpecies.append(contentsOf: entry.species)
            newMicrodomains.append(value)
        }

        var newTiles = state.tiles
        rebuildTileRanges(
            tiles: &newTiles,
            cells: newCells,
            segments: newSegments,
            compartments: newCompartments,
            synapses: newSynapses,
            microdomains: newMicrodomains
        )

        var rebuilt = state
        rebuilt.tiles = newTiles
        rebuilt.cells = newCells
        rebuilt.regulatoryState = newRegulatory
        rebuilt.segments = newSegments
        rebuilt.compartments = newCompartments
        rebuilt.mechanismState = newMechanismState
        rebuilt.synapses = newSynapses
        rebuilt.microdomains = newMicrodomains
        rebuilt.molecularSpecies = newMolecularSpecies

        return RepackResult(
            state: rebuilt,
            transfer: StructuralIndexTransfer(
                cells: oldCellToNew,
                segments: oldSegmentToNew,
                compartments: oldCompartmentToNew,
                synapses: oldSynapseToNew,
                microdomains: oldMicrodomainToNew
            ),
            deletedPrunedSynapses: deletedPrunedSynapses,
            deletedSegmentCount: state.segments.count - segmentEntries.filter { $0.oldIndex != nil }.count,
            createdSynapseCount: createdSynapses
        )
    }

    private func rebuildTileRanges(
        tiles: inout [TileRuntimeState],
        cells: [RuntimeCellState],
        segments: [RuntimeSegmentState],
        compartments: [RuntimeCompartmentState],
        synapses: [RuntimeSynapseState],
        microdomains: [RuntimeMicrodomainState]
    ) {
        let cellTiles = cells.map { Int($0.tileIndex) }
        let segmentTiles = segments.map {
            cells.indices.contains(Int($0.cellIndex)) ? Int(cells[Int($0.cellIndex)].tileIndex) : -1
        }
        let compartmentTiles = compartments.map {
            cells.indices.contains(Int($0.neuronIndex)) ? Int(cells[Int($0.neuronIndex)].tileIndex) : -1
        }
        let synapseTiles = synapses.map {
            let target = Int($0.targetCompartmentIndex)
            guard compartments.indices.contains(target) else { return -1 }
            let cell = Int(compartments[target].neuronIndex)
            return cells.indices.contains(cell) ? Int(cells[cell].tileIndex) : -1
        }
        let microdomainTiles = microdomains.map {
            cells.indices.contains(Int($0.ownerCellIndex)) ? Int(cells[Int($0.ownerCellIndex)].tileIndex) : -1
        }

        let cellRanges = ranges(for: cellTiles, tileCount: tiles.count)
        let segmentRanges = ranges(for: segmentTiles, tileCount: tiles.count)
        let compartmentRanges = ranges(for: compartmentTiles, tileCount: tiles.count)
        let synapseRanges = ranges(for: synapseTiles, tileCount: tiles.count)
        let microdomainRanges = ranges(for: microdomainTiles, tileCount: tiles.count)
        for index in tiles.indices {
            tiles[index].cellRange = cellRanges[index]
            tiles[index].segmentRange = segmentRanges[index]
            tiles[index].compartmentRange = compartmentRanges[index]
            tiles[index].synapseRange = synapseRanges[index]
            tiles[index].microdomainRange = microdomainRanges[index]
        }
    }

    private func ranges(for owners: [Int], tileCount: Int) -> [RuntimeRange] {
        var result = Array(
            repeating: RuntimeRange(lowerBound: 0, count: 0),
            count: tileCount
        )
        var cursor = 0
        for tile in 0..<tileCount {
            let lower = cursor
            while cursor < owners.count && owners[cursor] == tile { cursor += 1 }
            result[tile] = RuntimeRange(
                lowerBound: UInt32(lower),
                count: UInt32(cursor - lower)
            )
        }
        return result
    }

    private func slice(_ values: [Float], range: RuntimeRange) -> [Float] {
        let lower = Int(range.lowerBound)
        let upper = min(lower + Int(range.count), values.count)
        guard lower >= 0, lower <= upper, lower < values.count else { return [] }
        return Array(values[lower..<upper])
    }

    private func deterministicDirection(seed: UInt32, source: UInt64) -> Float4 {
        let random = CounterRandom.generate(
            counter: PhiloxCounter(
                seed,
                UInt32(truncatingIfNeeded: source),
                UInt32(truncatingIfNeeded: source >> 32),
                0x44495649
            ),
            key: PhiloxKey(seed: source)
        )
        let direction = Float4(
            CounterRandom.uniform01(random.x) - 0.5,
            CounterRandom.uniform01(random.y) - 0.5,
            CounterRandom.uniform01(random.z) - 0.5,
            0
        )
        return normalize3(direction)
    }
}

private struct PoolCounts: Equatable {
    var cells: Int
    var segments: Int
    var compartments: Int
    var synapses: Int
    var microdomains: Int

    init(_ state: TissueRuntimeState) {
        cells = state.cells.count
        segments = state.segments.count
        compartments = state.compartments.count
        synapses = state.synapses.count
        microdomains = state.microdomains.count
    }
}

private struct PendingCell {
    var cell: RuntimeCellState
    var regulatory: [Float]
    var parentOldIndex: Int
}

private struct PendingSegment {
    var segment: RuntimeSegmentState
    var parentOldIndex: Int
}

private struct PendingSynapse {
    var sourceSegmentOldIndex: Int
    var targetSegmentOldIndex: Int
    var parameterIndex: UInt16
    var source: UInt64
    var sequence: UInt32
}

private struct CellEntry {
    var value: RuntimeCellState
    var regulatory: [Float]
    var oldIndex: Int?
}

private struct SegmentEntry {
    var value: RuntimeSegmentState
    var oldIndex: Int?
    var newCellIndex: UInt32
    var parentOldIndex: Int?
    var compartmentOldIndex: Int?
}

private struct CompartmentEntry {
    var value: RuntimeCompartmentState
    var mechanism: [Float]
    var oldIndex: Int
    var newCellIndex: UInt32
}

private struct SynapseEntry {
    var value: RuntimeSynapseState
    var oldIndex: Int?
}

private struct MicrodomainEntry {
    var value: RuntimeMicrodomainState
    var species: [Float]
    var oldIndex: Int
}

private struct ConnectionKey: Hashable {
    var source: UInt32
    var target: UInt32
    var parameter: UInt16
}

private struct RepackResult {
    var state: TissueRuntimeState
    var transfer: StructuralIndexTransfer
    var deletedPrunedSynapses: Int
    var deletedSegmentCount: Int
    var createdSynapseCount: Int
}

private struct StructuralIdentifierFactory {
    var transaction: UInt64
    var used: Set<UInt64>

    init(transaction: UInt64, existing: Set<UInt64>) {
        self.transaction = transaction
        used = existing
    }

    mutating func next(tag: UInt64, source: UInt64, ordinal: UInt32) -> UInt64 {
        var value = mix(transaction ^ tag ^ source ^ UInt64(ordinal)) | (1 << 63)
        while value == 0 || used.contains(value) { value = mix(value &+ 0x9E37_79B9_7F4A_7C15) | (1 << 63) }
        used.insert(value)
        return value
    }

    private func mix(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
