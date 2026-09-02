import Foundation

@frozen
public struct NTFidelityPolicy: Codable, Hashable, Sendable {
    public var promotionActivityThreshold: Float
    public var promotionUncertaintyThreshold: Float
    public var promotionInjuryThreshold: Float
    public var demotionActivityThreshold: Float
    public var demotionUncertaintyThreshold: Float
    public var promotionDwellSeconds: Float
    public var demotionDwellSeconds: Float
    public var interestRadiusMicrometers: Float
    public var molecularCalciumThresholdMicromolar: Float
    public var detailedSegmentLengthThresholdMicrometers: Float
    public var maximumPromotionsPerEpoch: Int
    public var maximumDemotionsPerEpoch: Int
    public var targetResidentFraction: Float

    public init(
        promotionActivityThreshold: Float = 0.2,
        promotionUncertaintyThreshold: Float = 0.35,
        promotionInjuryThreshold: Float = 0.1,
        demotionActivityThreshold: Float = 0.03,
        demotionUncertaintyThreshold: Float = 0.05,
        promotionDwellSeconds: Float = 0.1,
        demotionDwellSeconds: Float = 10,
        interestRadiusMicrometers: Float = 300,
        molecularCalciumThresholdMicromolar: Float = 0.5,
        detailedSegmentLengthThresholdMicrometers: Float = 10,
        maximumPromotionsPerEpoch: Int = 8,
        maximumDemotionsPerEpoch: Int = 16,
        targetResidentFraction: Float = 0.8
    ) {
        self.promotionActivityThreshold = promotionActivityThreshold
        self.promotionUncertaintyThreshold = promotionUncertaintyThreshold
        self.promotionInjuryThreshold = promotionInjuryThreshold
        self.demotionActivityThreshold = demotionActivityThreshold
        self.demotionUncertaintyThreshold = demotionUncertaintyThreshold
        self.promotionDwellSeconds = promotionDwellSeconds
        self.demotionDwellSeconds = demotionDwellSeconds
        self.interestRadiusMicrometers = interestRadiusMicrometers
        self.molecularCalciumThresholdMicromolar = molecularCalciumThresholdMicromolar
        self.detailedSegmentLengthThresholdMicrometers = detailedSegmentLengthThresholdMicrometers
        self.maximumPromotionsPerEpoch = maximumPromotionsPerEpoch
        self.maximumDemotionsPerEpoch = maximumDemotionsPerEpoch
        self.targetResidentFraction = targetResidentFraction
    }
}

@frozen
public struct NTInterestPoint: Codable, Hashable, Sendable {
    public enum Kind: UInt8, Codable, Sendable { case electrode, probe, lesion, behavioral, userPinned }
    public var kind: Kind
    public var positionMicrometers: NTVector3
    public var radiusMicrometers: Float
    public var requestedMinimumFidelity: NTFidelityLevel
    public var weight: Float

    public init(
        kind: Kind,
        positionMicrometers: NTVector3,
        radiusMicrometers: Float,
        requestedMinimumFidelity: NTFidelityLevel,
        weight: Float = 1
    ) {
        self.kind = kind
        self.positionMicrometers = positionMicrometers
        self.radiusMicrometers = radiusMicrometers
        self.requestedMinimumFidelity = requestedMinimumFidelity
        self.weight = weight
    }
}

@frozen
public struct NTReducedCellSummary: Codable, Hashable, Sendable {
    public var cell: CellID
    public var tile: TileID
    public var meanVoltageMillivolts: Float
    public var membraneChargeNanocoulombs: Float
    public var calciumMicromolar: Float
    public var firingRateHertz: Float
    public var totalExcitatoryConductance: Float
    public var totalInhibitoryConductance: Float
    public var synapticWeightMean: Float
    public var synapticWeightVariance: Float

    public init(
        cell: CellID,
        tile: TileID,
        meanVoltageMillivolts: Float,
        membraneChargeNanocoulombs: Float,
        calciumMicromolar: Float,
        firingRateHertz: Float,
        totalExcitatoryConductance: Float,
        totalInhibitoryConductance: Float,
        synapticWeightMean: Float,
        synapticWeightVariance: Float
    ) {
        self.cell = cell
        self.tile = tile
        self.meanVoltageMillivolts = meanVoltageMillivolts
        self.membraneChargeNanocoulombs = membraneChargeNanocoulombs
        self.calciumMicromolar = calciumMicromolar
        self.firingRateHertz = firingRateHertz
        self.totalExcitatoryConductance = totalExcitatoryConductance
        self.totalInhibitoryConductance = totalInhibitoryConductance
        self.synapticWeightMean = synapticWeightMean
        self.synapticWeightVariance = synapticWeightVariance
    }
}

@frozen
public struct NTFidelityAuxiliaryState: Codable, Sendable {
    public var reducedCells: [CellID: NTReducedCellSummary]
    public var compressedSynapses: [NTCompressedSynapsePopulation]
    public var activeCompartmentMask: [Bool]
    public var activeSynapseMask: [Bool]
    public var activeMicrodomainMask: [Bool]
    public var pinnedTiles: [TileID: NTFidelityLevel]

    public init(
        reducedCells: [CellID: NTReducedCellSummary] = [:],
        compressedSynapses: [NTCompressedSynapsePopulation] = [],
        activeCompartmentMask: [Bool] = [],
        activeSynapseMask: [Bool] = [],
        activeMicrodomainMask: [Bool] = [],
        pinnedTiles: [TileID: NTFidelityLevel] = [:]
    ) {
        self.reducedCells = reducedCells
        self.compressedSynapses = compressedSynapses
        self.activeCompartmentMask = activeCompartmentMask
        self.activeSynapseMask = activeSynapseMask
        self.activeMicrodomainMask = activeMicrodomainMask
        self.pinnedTiles = pinnedTiles
    }
}

@frozen
public struct NTFidelityTransition: Codable, Hashable, Sendable {
    public var tile: TileID
    public var from: NTFidelityLevel
    public var to: NTFidelityLevel
    public var priority: Float
    public var reasonMask: UInt32

    public init(tile: TileID, from: NTFidelityLevel, to: NTFidelityLevel, priority: Float, reasonMask: UInt32) {
        self.tile = tile
        self.from = from
        self.to = to
        self.priority = priority
        self.reasonMask = reasonMask
    }
}

@frozen
public struct NTFidelityStepResult: Sendable {
    public var promoted: [NTFidelityTransition]
    public var demoted: [NTFidelityTransition]
    public var deferred: [NTFidelityTransition]
    public var estimatedBytesBefore: UInt64
    public var estimatedBytesAfter: UInt64
    public var diagnostics: [NTDiagnostic]

    public init(estimatedBytesBefore: UInt64) {
        promoted = []
        demoted = []
        deferred = []
        self.estimatedBytesBefore = estimatedBytesBefore
        estimatedBytesAfter = estimatedBytesBefore
        diagnostics = []
    }
}

public struct NTAdaptiveFidelityController: Sendable {
    public var policy: NTFidelityPolicy

    public init(policy: NTFidelityPolicy = .init()) {
        self.policy = policy
    }

    public func evaluateAndApply(
        state: inout NTProductionState,
        auxiliary: inout NTFidelityAuxiliaryState,
        interestPoints: [NTInterestPoint],
        deltaTicks: UInt64
    ) -> NTFidelityStepResult {
        synchronizeMasks(state: state, auxiliary: &auxiliary)
        let dt = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        var result = NTFidelityStepResult(estimatedBytesBefore: state.estimatedResidentBytes)
        let targetBytes = UInt64(Float(state.configuration.resourceBudget.maximumResidentBytes) * policy.targetResidentFraction)
        var promotions: [NTFidelityTransition] = []
        var demotions: [NTFidelityTransition] = []

        for index in state.tiles.indices {
            var tile = state.tiles[index]
            let center = tileCenter(tile.membership.coordinate, configuration: state.configuration)
            let interest = interestScore(center: center, points: interestPoints)
            let pinned = auxiliary.pinnedTiles[tile.membership.id]
            let targetFromInterest = requiredFidelity(center: center, points: interestPoints)
            let promotionSignal = max(
                tile.membership.activityScore / max(policy.promotionActivityThreshold, 1.0e-6),
                max(
                    tile.membership.uncertaintyScore / max(policy.promotionUncertaintyThreshold, 1.0e-6),
                    tile.membership.injuryScore / max(policy.promotionInjuryThreshold, 1.0e-6)
                )
            ) + interest
            let demotionEligible = tile.membership.activityScore < policy.demotionActivityThreshold &&
                tile.membership.uncertaintyScore < policy.demotionUncertaintyThreshold &&
                tile.membership.injuryScore < 0.01 && interest <= 0

            if promotionSignal >= 1 || (targetFromInterest != nil && tile.membership.fidelity < targetFromInterest!) {
                tile.promotionAccumulator += dt
                tile.demotionAccumulator = 0
            } else if demotionEligible {
                tile.demotionAccumulator += dt
                tile.promotionAccumulator = 0
            } else {
                tile.promotionAccumulator = max(0, tile.promotionAccumulator - dt)
                tile.demotionAccumulator = max(0, tile.demotionAccumulator - dt)
            }

            let minimum = maxFidelity(pinned, targetFromInterest)
            if let minimum, tile.membership.fidelity < minimum {
                promotions.append(.init(
                    tile: tile.membership.id,
                    from: tile.membership.fidelity,
                    to: nextLevel(after: tile.membership.fidelity, cappedAt: minimum),
                    priority: 10_000 + interest,
                    reasonMask: 1 << 3
                ))
            } else if tile.promotionAccumulator >= policy.promotionDwellSeconds,
                      tile.membership.fidelity < .molecularDetailed {
                var reasons: UInt32 = 0
                if tile.membership.activityScore >= policy.promotionActivityThreshold { reasons |= 1 }
                if tile.membership.uncertaintyScore >= policy.promotionUncertaintyThreshold { reasons |= 1 << 1 }
                if tile.membership.injuryScore >= policy.promotionInjuryThreshold { reasons |= 1 << 2 }
                promotions.append(.init(
                    tile: tile.membership.id,
                    from: tile.membership.fidelity,
                    to: NTFidelityLevel(rawValue: tile.membership.fidelity.rawValue + 1)!,
                    priority: promotionSignal,
                    reasonMask: reasons
                ))
            } else if tile.demotionAccumulator >= policy.demotionDwellSeconds,
                      tile.membership.fidelity > .fieldOnly,
                      pinned == nil {
                demotions.append(.init(
                    tile: tile.membership.id,
                    from: tile.membership.fidelity,
                    to: NTFidelityLevel(rawValue: tile.membership.fidelity.rawValue - 1)!,
                    priority: -(tile.membership.activityScore + tile.membership.uncertaintyScore),
                    reasonMask: 1 << 4
                ))
            }
            state.tiles[index] = tile
        }

        promotions.sort { $0.priority > $1.priority }
        demotions.sort { $0.priority < $1.priority }
        var estimatedBytes = state.estimatedResidentBytes

        for transition in demotions.prefix(policy.maximumDemotionsPerEpoch) {
            do {
                try demote(transition: transition, state: &state, auxiliary: &auxiliary)
                result.demoted.append(transition)
                estimatedBytes = estimateAfter(transition: transition, current: estimatedBytes, state: state)
            } catch {
                result.deferred.append(transition)
                result.diagnostics.append(.init(
                    severity: .warning,
                    code: .incompleteShadowState,
                    message: "Fidelity demotion was deferred: \(error)",
                    tile: transition.tile
                ))
            }
        }

        for transition in promotions.prefix(policy.maximumPromotionsPerEpoch) {
            let projected = estimateAfter(transition: transition, current: estimatedBytes, state: state)
            guard projected <= targetBytes else {
                result.deferred.append(transition)
                continue
            }
            do {
                try promote(transition: transition, state: &state, auxiliary: &auxiliary)
                result.promoted.append(transition)
                estimatedBytes = projected
            } catch {
                result.deferred.append(transition)
                result.diagnostics.append(.init(
                    severity: .warning,
                    code: .resourceBudgetExceeded,
                    message: "Fidelity promotion was deferred: \(error)",
                    tile: transition.tile
                ))
            }
        }
        result.estimatedBytesAfter = estimatedBytes
        synchronizeMasks(state: state, auxiliary: &auxiliary)
        return result
    }

    private func promote(
        transition: NTFidelityTransition,
        state: inout NTProductionState,
        auxiliary: inout NTFidelityAuxiliaryState
    ) throws {
        guard let tileIndex = state.tileIndex(id: transition.tile) else {
            throw NTRuntimeError.invalidModel("Promotion tile is absent.")
        }
        switch (transition.from, transition.to) {
        case (.fieldOnly, .cellAgent):
            for cellIndex in state.tiles[tileIndex].membership.cellIndices where state.cells.indices.contains(Int(cellIndex)) {
                state.cells[Int(cellIndex)].record.fidelity = .cellAgent
            }
        case (.cellAgent, .reducedElectrical):
            try materializeReducedNeurons(tileIndex: tileIndex, state: &state, auxiliary: &auxiliary)
        case (.reducedElectrical, .detailedElectrical):
            try refineElectricalMorphology(tileIndex: tileIndex, state: &state)
        case (.detailedElectrical, .molecularDetailed):
            try materializeMolecularDomains(tileIndex: tileIndex, state: &state)
        default:
            break
        }
        state.tiles[tileIndex].membership.fidelity = transition.to
        state.tiles[tileIndex].membership.lastFidelityChange = state.time
        state.tiles[tileIndex].promotionAccumulator = 0
    }

    private func demote(
        transition: NTFidelityTransition,
        state: inout NTProductionState,
        auxiliary: inout NTFidelityAuxiliaryState
    ) throws {
        guard let tileIndex = state.tileIndex(id: transition.tile) else {
            throw NTRuntimeError.invalidModel("Demotion tile is absent.")
        }
        switch (transition.from, transition.to) {
        case (.molecularDetailed, .detailedElectrical):
            for domainIndex in state.tiles[tileIndex].membership.microdomainIndices where state.microdomains.indices.contains(Int(domainIndex)) {
                auxiliary.activeMicrodomainMask[Int(domainIndex)] = false
            }
        case (.detailedElectrical, .reducedElectrical):
            summarizeCells(tileIndex: tileIndex, state: state, auxiliary: &auxiliary)
            let active = Set(representativeCompartments(tileIndex: tileIndex, state: state))
            for compartmentIndex in state.tiles[tileIndex].membership.compartmentIndices where auxiliary.activeCompartmentMask.indices.contains(Int(compartmentIndex)) {
                auxiliary.activeCompartmentMask[Int(compartmentIndex)] = active.contains(Int(compartmentIndex))
            }
        case (.reducedElectrical, .cellAgent):
            summarizeCells(tileIndex: tileIndex, state: state, auxiliary: &auxiliary)
            for compartmentIndex in state.tiles[tileIndex].membership.compartmentIndices where auxiliary.activeCompartmentMask.indices.contains(Int(compartmentIndex)) {
                auxiliary.activeCompartmentMask[Int(compartmentIndex)] = false
            }
            compressSynapses(tileIndex: tileIndex, state: state, auxiliary: &auxiliary)
        case (.cellAgent, .fieldOnly):
            for cellIndex in state.tiles[tileIndex].membership.cellIndices where state.cells.indices.contains(Int(cellIndex)) {
                state.cells[Int(cellIndex)].record.fidelity = .fieldOnly
            }
        default:
            break
        }
        state.tiles[tileIndex].membership.fidelity = transition.to
        state.tiles[tileIndex].membership.lastFidelityChange = state.time
        state.tiles[tileIndex].demotionAccumulator = 0
    }

    private func materializeReducedNeurons(
        tileIndex: Int,
        state: inout NTProductionState,
        auxiliary: inout NTFidelityAuxiliaryState
    ) throws {
        var nextID = (state.compartments.map { $0.record.id.rawValue }.max() ?? 0) &+ 1
        let cellIndices = state.tiles[tileIndex].membership.cellIndices
        for encoded in cellIndices {
            let cellIndex = Int(encoded)
            guard state.cells.indices.contains(cellIndex) else { continue }
            let cell = state.cells[cellIndex]
            guard cell.record.kind == .excitatoryNeuron || cell.record.kind == .inhibitoryNeuron else { continue }
            let existing = state.compartments.indices.filter { state.compartments[$0].record.cell == cell.record.id }
            if !existing.isEmpty {
                for index in existing where auxiliary.activeCompartmentMask.indices.contains(index) {
                    auxiliary.activeCompartmentMask[index] = true
                }
                continue
            }
            let summary = auxiliary.reducedCells[cell.record.id]
            let voltage = summary?.meanVoltageMillivolts ?? -65
            let soma = NTCompartmentRecord(
                id: CompartmentID(rawValue: nextID),
                cell: cell.record.id,
                tile: cell.record.tile,
                parentIndex: -1,
                level: 0,
                compartmentClass: .soma,
                mechanismSet: cell.record.kind == .inhibitoryNeuron ? 3 : 2,
                positionMicrometers: cell.record.positionMicrometers,
                lengthMicrometers: max(5, cell.record.radiiMicrometers.y * 2),
                diameterMicrometers: max(5, cell.record.radiiMicrometers.x * 2),
                membraneVoltageMillivolts: voltage,
                capacitanceNanofarads: 0.2,
                axialConductanceMicrosiemens: 0
            )
            let somaIndex = try state.appendCompartment(.init(record: soma))
            nextID &+= 1
            let dendrite = NTCompartmentRecord(
                id: CompartmentID(rawValue: nextID),
                cell: cell.record.id,
                tile: cell.record.tile,
                parentIndex: Int32(somaIndex),
                level: 1,
                compartmentClass: .basalDendrite,
                mechanismSet: 0,
                positionMicrometers: cell.record.positionMicrometers + .init(0, 10, 0),
                lengthMicrometers: 20,
                diameterMicrometers: 2,
                membraneVoltageMillivolts: voltage,
                capacitanceNanofarads: 0.08,
                axialConductanceMicrosiemens: 0.02
            )
            _ = try state.appendCompartment(.init(record: dendrite))
            nextID &+= 1
        }
    }

    private func refineElectricalMorphology(tileIndex: Int, state: inout NTProductionState) throws {
        let sourceIndices = state.tiles[tileIndex].membership.compartmentIndices.map(Int.init)
        var additions: [NTProductionCompartment] = []
        var nextID = (state.compartments.map { $0.record.id.rawValue }.max() ?? 0) &+ 1
        for index in sourceIndices where state.compartments.indices.contains(index) {
            let source = state.compartments[index]
            guard source.record.lengthMicrometers >= policy.detailedSegmentLengthThresholdMicrometers,
                  source.record.compartmentClass != .soma else { continue }
            var branch = source.record
            branch.id = CompartmentID(rawValue: nextID)
            branch.parentIndex = Int32(index)
            branch.level = source.record.level &+ 1
            branch.lengthMicrometers *= 0.5
            branch.capacitanceNanofarads *= 0.5
            branch.positionMicrometers = source.record.positionMicrometers + .init(0, branch.lengthMicrometers * 0.5, 0)
            additions.append(.init(record: branch, gates: source.gates))
            nextID &+= 1
        }
        for addition in additions { _ = try state.appendCompartment(addition) }
    }

    private func materializeMolecularDomains(tileIndex: Int, state: inout NTProductionState) throws {
        var nextID = (state.microdomains.map { $0.id.rawValue }.max() ?? 0) &+ 1
        let compartmentIndices = state.tiles[tileIndex].membership.compartmentIndices.map(Int.init)
        for index in compartmentIndices where state.compartments.indices.contains(index) {
            let compartment = state.compartments[index]
            guard compartment.record.calciumMicromolar >= policy.molecularCalciumThresholdMicromolar ||
                    compartment.record.compartmentClass == .spineHead else { continue }
            guard !state.microdomains.contains(where: { $0.ownerCompartment == compartment.record.id }) else { continue }
            let domain = NTMicrodomainState(
                id: MicrodomainID(rawValue: nextID),
                ownerCell: compartment.record.cell,
                ownerCompartment: compartment.record.id,
                tile: compartment.record.tile,
                networkIndex: 0,
                solver: .deterministicODE,
                speciesAmounts: [compartment.record.calciumMicromolar],
                volumeFemtoliters: 0.1
            )
            state.microdomains.append(domain)
            state.tiles[tileIndex].membership.microdomainIndices.append(UInt32(state.microdomains.count - 1))
            nextID &+= 1
        }
        try state.rebuildIndices()
    }

    private func summarizeCells(tileIndex: Int, state: NTProductionState, auxiliary: inout NTFidelityAuxiliaryState) {
        for encoded in state.tiles[tileIndex].membership.cellIndices {
            let cellIndex = Int(encoded)
            guard state.cells.indices.contains(cellIndex) else { continue }
            let cell = state.cells[cellIndex]
            let compartments = state.compartments.filter { $0.record.cell == cell.record.id }
            guard !compartments.isEmpty else { continue }
            let capacitance = compartments.reduce(Float.zero) { $0 + $1.record.capacitanceNanofarads }
            let charge = compartments.reduce(Float.zero) { $0 + $1.record.capacitanceNanofarads * $1.record.membraneVoltageMillivolts }
            let calcium = compartments.reduce(Float.zero) { $0 + $1.record.calciumMicromolar } / Float(compartments.count)
            let spikes = compartments.reduce(UInt32.zero) { $0 &+ $1.spikeCountWindow }
            let cellCompartmentIDs = Set(compartments.map { $0.record.id })
            let cellCompartmentIndices = Set(state.compartments.indices.filter { cellCompartmentIDs.contains(state.compartments[$0].record.id) }.map(UInt32.init))
            let synapses = state.synapses.filter { cellCompartmentIndices.contains($0.record.postCompartmentIndex) }
            let weights = synapses.map { $0.record.weightMicrosiemens }
            let mean = weights.isEmpty ? 0 : weights.reduce(0, +) / Float(weights.count)
            let variance = weights.isEmpty ? 0 : weights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(weights.count)
            auxiliary.reducedCells[cell.record.id] = .init(
                cell: cell.record.id,
                tile: cell.record.tile,
                meanVoltageMillivolts: capacitance > 0 ? charge / capacitance : -65,
                membraneChargeNanocoulombs: charge,
                calciumMicromolar: calcium,
                firingRateHertz: Float(spikes),
                totalExcitatoryConductance: compartments.reduce(0) { $0 + $1.synapticConductanceExcitatory },
                totalInhibitoryConductance: compartments.reduce(0) { $0 + $1.synapticConductanceInhibitory },
                synapticWeightMean: mean,
                synapticWeightVariance: variance
            )
        }
    }

    private func compressSynapses(tileIndex: Int, state: NTProductionState, auxiliary: inout NTFidelityAuxiliaryState) {
        let indices = state.tiles[tileIndex].membership.synapseIndices.map(Int.init).filter(state.synapses.indices.contains)
        let grouped = Dictionary(grouping: indices) { state.synapses[$0].record.receptor }
        for (receptor, group) in grouped where !group.isEmpty {
            let total = group.reduce(Float.zero) { $0 + state.synapses[$1].record.conductanceMicrosiemens }
            let weights = group.map { state.synapses[$0].record.weightMicrosiemens }
            let mean = weights.reduce(0, +) / Float(weights.count)
            let variance = weights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(weights.count)
            let targets = Array(Set(group.map { state.synapses[$0].record.postCompartmentIndex })).sorted()
            auxiliary.compressedSynapses.append(.init(
                sourcePopulation: PopulationID(rawValue: transitionPopulationID(tile: state.tiles[tileIndex].membership.id, receptor: receptor, source: true)),
                targetPopulation: PopulationID(rawValue: transitionPopulationID(tile: state.tiles[tileIndex].membership.id, receptor: receptor, source: false)),
                targetCompartmentIndices: targets,
                receptor: receptor,
                physicalContactCount: UInt32(clamping: group.count),
                totalConductanceMicrosiemens: total,
                delayMeanTicks: Float(group.reduce(0) { $0 + Int(state.synapses[$1].record.delayTicks) }) / Float(group.count),
                delayStandardDeviationTicks: 0,
                weightMean: mean,
                weightVariance: variance
            ))
            for index in group where auxiliary.activeSynapseMask.indices.contains(index) {
                auxiliary.activeSynapseMask[index] = false
            }
        }
    }

    private func representativeCompartments(tileIndex: Int, state: NTProductionState) -> [Int] {
        var selected: [Int] = []
        let indices = state.tiles[tileIndex].membership.compartmentIndices.map(Int.init).filter(state.compartments.indices.contains)
        let groups = Dictionary(grouping: indices) { state.compartments[$0].record.cell }
        for group in groups.values {
            if let soma = group.first(where: { state.compartments[$0].record.compartmentClass == .soma }) { selected.append(soma) }
            if let dendrite = group.first(where: { state.compartments[$0].record.compartmentClass == .basalDendrite || state.compartments[$0].record.compartmentClass == .apicalDendrite }) { selected.append(dendrite) }
            if let axon = group.first(where: { state.compartments[$0].record.compartmentClass == .axonInitialSegment || state.compartments[$0].record.compartmentClass == .axon }) { selected.append(axon) }
        }
        return selected
    }

    private func synchronizeMasks(state: NTProductionState, auxiliary: inout NTFidelityAuxiliaryState) {
        if auxiliary.activeCompartmentMask.count < state.compartments.count {
            auxiliary.activeCompartmentMask.append(contentsOf: repeatElement(true, count: state.compartments.count - auxiliary.activeCompartmentMask.count))
        } else if auxiliary.activeCompartmentMask.count > state.compartments.count {
            auxiliary.activeCompartmentMask.removeLast(auxiliary.activeCompartmentMask.count - state.compartments.count)
        }
        if auxiliary.activeSynapseMask.count < state.synapses.count {
            auxiliary.activeSynapseMask.append(contentsOf: repeatElement(true, count: state.synapses.count - auxiliary.activeSynapseMask.count))
        } else if auxiliary.activeSynapseMask.count > state.synapses.count {
            auxiliary.activeSynapseMask.removeLast(auxiliary.activeSynapseMask.count - state.synapses.count)
        }
        if auxiliary.activeMicrodomainMask.count < state.microdomains.count {
            auxiliary.activeMicrodomainMask.append(contentsOf: repeatElement(true, count: state.microdomains.count - auxiliary.activeMicrodomainMask.count))
        } else if auxiliary.activeMicrodomainMask.count > state.microdomains.count {
            auxiliary.activeMicrodomainMask.removeLast(auxiliary.activeMicrodomainMask.count - state.microdomains.count)
        }
    }

    private func estimateAfter(transition: NTFidelityTransition, current: UInt64, state: NTProductionState) -> UInt64 {
        let tile = state.tileIndex(id: transition.tile).map { state.tiles[$0] }
        let cells = UInt64(tile?.membership.cellIndices.count ?? 0)
        let compartments = UInt64(tile?.membership.compartmentIndices.count ?? 0)
        let synapses = UInt64(tile?.membership.synapseIndices.count ?? 0)
        let domains = UInt64(tile?.membership.microdomainIndices.count ?? 0)
        let delta: UInt64
        switch transition.to {
        case .fieldOnly: delta = cells * 32
        case .cellAgent: delta = cells * 320
        case .reducedElectrical: delta = max(compartments, cells * 3) * 192 + synapses * 32
        case .detailedElectrical: delta = max(compartments * 2, cells * 24) * 224 + synapses * 128
        case .molecularDetailed: delta = domains * 4_096 + synapses * 160
        }
        if transition.to > transition.from { return current &+ delta }
        return current > delta ? current - delta : 0
    }

    private func interestScore(center: NTVector3, points: [NTInterestPoint]) -> Float {
        var score: Float = 0
        for point in points {
            let radius = max(point.radiusMicrometers, policy.interestRadiusMicrometers)
            let distance = (center - point.positionMicrometers).length
            if distance < radius { score = max(score, point.weight * (1 - distance / radius)) }
        }
        return score
    }

    private func requiredFidelity(center: NTVector3, points: [NTInterestPoint]) -> NTFidelityLevel? {
        var required: NTFidelityLevel?
        for point in points where (center - point.positionMicrometers).length <= point.radiusMicrometers {
            required = maxFidelity(required, point.requestedMinimumFidelity)
        }
        return required
    }

    private func maxFidelity(_ a: NTFidelityLevel?, _ b: NTFidelityLevel?) -> NTFidelityLevel? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (value?, nil), let (nil, value?): return value
        case let (left?, right?): return max(left, right)
        }
    }

    private func nextLevel(after current: NTFidelityLevel, cappedAt target: NTFidelityLevel) -> NTFidelityLevel {
        NTFidelityLevel(rawValue: min(target.rawValue, current.rawValue &+ 1)) ?? target
    }

    private func tileCenter(_ coordinate: TileCoordinate, configuration: NTWorldConfiguration) -> NTVector3 {
        let edge = configuration.tileEdgeMicrometers
        return NTVector3(
            configuration.originMicrometers.x + (Float(coordinate.x) + 0.5) * edge,
            configuration.originMicrometers.y + (Float(coordinate.y) + 0.5) * edge,
            configuration.originMicrometers.z + (Float(coordinate.z) + 0.5) * edge
        )
    }

    private func transitionPopulationID(tile: TileID, receptor: NTSynapseReceptor, source: Bool) -> UInt64 {
        tile.rawValue ^ (UInt64(receptor.rawValue) << 48) ^ (source ? 0x8000_0000_0000_0000 : 0)
    }
}
