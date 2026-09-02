import Foundation
import NumiTissueCore

public struct TileActivityMask: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let electrophysiology = Self(rawValue: 1 << 0)
    public static let fastFields = Self(rawValue: 1 << 1)
    public static let molecular = Self(rawValue: 1 << 2)
    public static let glia = Self(rawValue: 1 << 3)
    public static let mechanics = Self(rawValue: 1 << 4)
    public static let development = Self(rawValue: 1 << 5)
    public static let structural = Self(rawValue: 1 << 6)
    public static let fidelity = Self(rawValue: 1 << 7)
    public static let output = Self(rawValue: 1 << 8)
}

@frozen
public struct RuntimeWorklists: Sendable, Codable {
    public var electricalTiles: [UInt32]
    public var fastFieldTiles: [UInt32]
    public var molecularTiles: [UInt32]
    public var glialTiles: [UInt32]
    public var mechanicsTiles: [UInt32]
    public var developmentalTiles: [UInt32]
    public var structuralTiles: [UInt32]
    public var fidelityTiles: [UInt32]
    public var outputTiles: [UInt32]

    public init() {
        electricalTiles = []
        fastFieldTiles = []
        molecularTiles = []
        glialTiles = []
        mechanicsTiles = []
        developmentalTiles = []
        structuralTiles = []
        fidelityTiles = []
        outputTiles = []
    }

    public mutating func reserve(tileCount: Int) {
        electricalTiles.reserveCapacity(tileCount)
        fastFieldTiles.reserveCapacity(tileCount)
        molecularTiles.reserveCapacity(tileCount / 4)
        glialTiles.reserveCapacity(tileCount)
        mechanicsTiles.reserveCapacity(tileCount / 2)
        developmentalTiles.reserveCapacity(tileCount / 2)
        structuralTiles.reserveCapacity(tileCount / 4)
        fidelityTiles.reserveCapacity(tileCount / 4)
        outputTiles.reserveCapacity(tileCount)
    }
}

public struct WorklistPolicy: Sendable, Hashable, Codable {
    public var electricalActivityThreshold: Float
    public var fieldActivityThreshold: Float
    public var molecularActivityThreshold: Float
    public var mechanicsActivityThreshold: Float
    public var developmentActivityThreshold: Float
    public var inactivityRetentionTicks: UInt64
    public var alwaysUpdateFields: Bool
    public var alwaysCollectOutputs: Bool

    public init(
        electricalActivityThreshold: Float = 1e-5,
        fieldActivityThreshold: Float = 1e-6,
        molecularActivityThreshold: Float = 1e-4,
        mechanicsActivityThreshold: Float = 1e-4,
        developmentActivityThreshold: Float = 1e-5,
        inactivityRetentionTicks: UInt64 = 40_000,
        alwaysUpdateFields: Bool = true,
        alwaysCollectOutputs: Bool = true
    ) {
        self.electricalActivityThreshold = electricalActivityThreshold
        self.fieldActivityThreshold = fieldActivityThreshold
        self.molecularActivityThreshold = molecularActivityThreshold
        self.mechanicsActivityThreshold = mechanicsActivityThreshold
        self.developmentActivityThreshold = developmentActivityThreshold
        self.inactivityRetentionTicks = inactivityRetentionTicks
        self.alwaysUpdateFields = alwaysUpdateFields
        self.alwaysCollectOutputs = alwaysCollectOutputs
    }
}

public struct RuntimeWorklistBuilder: Sendable {
    public var policy: WorklistPolicy

    public init(policy: WorklistPolicy = WorklistPolicy()) {
        self.policy = policy
    }

    public func build(state: TissueRuntimeState, at tick: UInt64) -> RuntimeWorklists {
        var result = RuntimeWorklists()
        result.reserve(tileCount: state.tiles.count)

        for (index, tile) in state.tiles.enumerated() {
            let tileIndex = UInt32(index)
            let recentlyActive = tick >= tile.lastActiveTick && tick - tile.lastActiveTick <= policy.inactivityRetentionTicks
            let electrical = !tile.compartmentRange.isEmpty && (tile.activityScore >= policy.electricalActivityThreshold || recentlyActive)
            let fields = !tile.fieldRange.isEmpty && (policy.alwaysUpdateFields || tile.activityScore >= policy.fieldActivityThreshold || tile.damageScore > 0)
            let molecular = !tile.microdomainRange.isEmpty && (tile.activityScore >= policy.molecularActivityThreshold || tile.damageScore > 0 || tile.uncertaintyScore > 0)
            let mechanics = !tile.cellRange.isEmpty && (tile.activityScore >= policy.mechanicsActivityThreshold || tile.damageScore > 0)
            let development = !tile.cellRange.isEmpty && (tile.activityScore >= policy.developmentActivityThreshold || tile.uncertaintyScore > 0)
            let structural = !tile.synapseRange.isEmpty && (tile.activityScore > policy.developmentActivityThreshold || tile.damageScore > 0)
            let fidelity = tile.uncertaintyScore > 0 || tile.damageScore > 0 || tile.metabolicStress > 0

            if electrical { result.electricalTiles.append(tileIndex) }
            if fields { result.fastFieldTiles.append(tileIndex) }
            if molecular { result.molecularTiles.append(tileIndex) }
            if !tile.cellRange.isEmpty { result.glialTiles.append(tileIndex) }
            if mechanics { result.mechanicsTiles.append(tileIndex) }
            if development { result.developmentalTiles.append(tileIndex) }
            if structural { result.structuralTiles.append(tileIndex) }
            if fidelity { result.fidelityTiles.append(tileIndex) }
            if policy.alwaysCollectOutputs || electrical || fields { result.outputTiles.append(tileIndex) }
        }
        return result
    }
}

public struct FidelityPolicy: Sendable, Hashable, Codable {
    public var promotionThreshold: Float
    public var demotionThreshold: Float
    public var promotionHoldTicks: UInt64
    public var demotionHoldTicks: UInt64
    public var activityWeight: Float
    public var uncertaintyWeight: Float
    public var damageWeight: Float
    public var metabolicWeight: Float
    public var probeWeight: Float
    public var maximumDetailedCellsPerTile: UInt32
    public var maximumMolecularCellsPerTile: UInt32

    public init(
        promotionThreshold: Float = 0.65,
        demotionThreshold: Float = 0.20,
        promotionHoldTicks: UInt64 = 400,
        demotionHoldTicks: UInt64 = 400_000,
        activityWeight: Float = 0.30,
        uncertaintyWeight: Float = 0.30,
        damageWeight: Float = 0.25,
        metabolicWeight: Float = 0.10,
        probeWeight: Float = 0.50,
        maximumDetailedCellsPerTile: UInt32 = 128,
        maximumMolecularCellsPerTile: UInt32 = 16
    ) {
        precondition(demotionThreshold < promotionThreshold)
        self.promotionThreshold = promotionThreshold
        self.demotionThreshold = demotionThreshold
        self.promotionHoldTicks = promotionHoldTicks
        self.demotionHoldTicks = demotionHoldTicks
        self.activityWeight = activityWeight
        self.uncertaintyWeight = uncertaintyWeight
        self.damageWeight = damageWeight
        self.metabolicWeight = metabolicWeight
        self.probeWeight = probeWeight
        self.maximumDetailedCellsPerTile = maximumDetailedCellsPerTile
        self.maximumMolecularCellsPerTile = maximumMolecularCellsPerTile
    }
}

public enum FidelityDecisionKind: UInt8, Sendable, Codable {
    case retain
    case promote
    case demote
}

@frozen
public struct FidelityDecision: Sendable, Hashable, Codable {
    public var cellIndex: UInt32
    public var from: FidelityLevel
    public var to: FidelityLevel
    public var kind: FidelityDecisionKind
    public var score: Float
    public var reasonMask: UInt32

    public init(cellIndex: UInt32, from: FidelityLevel, to: FidelityLevel, kind: FidelityDecisionKind, score: Float, reasonMask: UInt32) {
        self.cellIndex = cellIndex
        self.from = from
        self.to = to
        self.kind = kind
        self.score = score
        self.reasonMask = reasonMask
    }
}

/// Tracks hysteresis without attaching counters to the permanent cell ABI.
public struct FidelityHistory: Sendable, Codable {
    public var aboveThresholdSince: [CellID: UInt64]
    public var belowThresholdSince: [CellID: UInt64]

    public init() {
        aboveThresholdSince = [:]
        belowThresholdSince = [:]
    }
}

public struct AdaptiveFidelityManager: Sendable {
    public var policy: FidelityPolicy
    public private(set) var history: FidelityHistory

    public init(policy: FidelityPolicy = FidelityPolicy()) {
        self.policy = policy
        self.history = FidelityHistory()
    }

    public mutating func decide(
        state: TissueRuntimeState,
        tileIndices: [UInt32],
        probeWeights: [CellID: Float] = [:],
        at tick: UInt64
    ) -> [FidelityDecision] {
        var decisions: [FidelityDecision] = []
        for tileIndex in tileIndices {
            guard Int(tileIndex) < state.tiles.count else { continue }
            let tile = state.tiles[Int(tileIndex)]
            var detailedCount: UInt32 = 0
            var molecularCount: UInt32 = 0
            for cellIndex in tile.cellRange.lowerBound..<tile.cellRange.upperBound where Int(cellIndex) < state.cells.count {
                switch state.cells[Int(cellIndex)].fidelity {
                case .detailedNeuron: detailedCount &+= 1
                case .molecularDetail: molecularCount &+= 1
                default: break
                }
            }

            for cellIndex in tile.cellRange.lowerBound..<tile.cellRange.upperBound {
                guard Int(cellIndex) < state.cells.count else { continue }
                let cell = state.cells[Int(cellIndex)]
                let probe = min(max(probeWeights[cell.id] ?? 0, 0), 1)
                let score = min(max(
                    policy.activityWeight * clamp01(tile.activityScore) +
                    policy.uncertaintyWeight * clamp01(tile.uncertaintyScore) +
                    policy.damageWeight * clamp01(max(tile.damageScore, cell.damage)) +
                    policy.metabolicWeight * clamp01(max(tile.metabolicStress, max(cell.oxygenStress, cell.glucoseStress))) +
                    policy.probeWeight * probe,
                    0
                ), 1)
                var reasonMask: UInt32 = 0
                if tile.activityScore > 0 { reasonMask |= 1 << 0 }
                if tile.uncertaintyScore > 0 { reasonMask |= 1 << 1 }
                if tile.damageScore > 0 || cell.damage > 0 { reasonMask |= 1 << 2 }
                if tile.metabolicStress > 0 || cell.oxygenStress > 0 || cell.glucoseStress > 0 { reasonMask |= 1 << 3 }
                if probe > 0 { reasonMask |= 1 << 4 }

                if score >= policy.promotionThreshold {
                    history.belowThresholdSince.removeValue(forKey: cell.id)
                    let since = history.aboveThresholdSince[cell.id] ?? tick
                    history.aboveThresholdSince[cell.id] = since
                    guard tick >= since && tick - since >= policy.promotionHoldTicks else { continue }
                    guard let target = promoted(cell.fidelity, detailedCount: detailedCount, molecularCount: molecularCount) else { continue }
                    if target == .detailedNeuron { detailedCount &+= 1 }
                    if target == .molecularDetail { molecularCount &+= 1 }
                    decisions.append(FidelityDecision(cellIndex: cellIndex, from: cell.fidelity, to: target, kind: .promote, score: score, reasonMask: reasonMask))
                    history.aboveThresholdSince[cell.id] = tick
                } else if score <= policy.demotionThreshold {
                    history.aboveThresholdSince.removeValue(forKey: cell.id)
                    let since = history.belowThresholdSince[cell.id] ?? tick
                    history.belowThresholdSince[cell.id] = since
                    guard tick >= since && tick - since >= policy.demotionHoldTicks else { continue }
                    guard let target = demoted(cell.fidelity) else { continue }
                    decisions.append(FidelityDecision(cellIndex: cellIndex, from: cell.fidelity, to: target, kind: .demote, score: score, reasonMask: reasonMask))
                    history.belowThresholdSince[cell.id] = tick
                } else {
                    history.aboveThresholdSince.removeValue(forKey: cell.id)
                    history.belowThresholdSince.removeValue(forKey: cell.id)
                }
            }
        }
        return decisions
    }

    public func apply(_ decisions: [FidelityDecision], to state: inout TissueRuntimeState) {
        for decision in decisions where Int(decision.cellIndex) < state.cells.count {
            guard state.cells[Int(decision.cellIndex)].fidelity == decision.from else { continue }
            state.cells[Int(decision.cellIndex)].fidelity = decision.to
        }
    }

    private func promoted(_ current: FidelityLevel, detailedCount: UInt32, molecularCount: UInt32) -> FidelityLevel? {
        switch current {
        case .fieldOnly: return .cellAgent
        case .cellAgent: return .reducedNeuron
        case .reducedNeuron:
            return detailedCount < policy.maximumDetailedCellsPerTile ? .detailedNeuron : nil
        case .detailedNeuron:
            return molecularCount < policy.maximumMolecularCellsPerTile ? .molecularDetail : nil
        case .molecularDetail: return nil
        }
    }

    private func demoted(_ current: FidelityLevel) -> FidelityLevel? {
        switch current {
        case .fieldOnly: return nil
        case .cellAgent: return .fieldOnly
        case .reducedNeuron: return .cellAgent
        case .detailedNeuron: return .reducedNeuron
        case .molecularDetail: return .detailedNeuron
        }
    }

    @inline(__always)
    private func clamp01(_ value: Float) -> Float { min(max(value, 0), 1) }
}

/// Conserved summaries used when changing electrical resolution. Higher-fidelity reconstruction
/// may distribute these values over a morphology, but must preserve the totals here.
@frozen
public struct FidelityProjectionState: Sendable, Hashable, Codable {
    public var membraneChargeNanocoulombs: Float
    public var intracellularCalciumAmount: Float
    public var intracellularSodiumAmount: Float
    public var intracellularPotassiumAmount: Float
    public var totalSynapticConductance: Float
    public var meanEligibility: Float
    public var meanConsolidation: Float
    public var recentSpikeRateHertz: Float

    public init() {
        membraneChargeNanocoulombs = 0
        intracellularCalciumAmount = 0
        intracellularSodiumAmount = 0
        intracellularPotassiumAmount = 0
        totalSynapticConductance = 0
        meanEligibility = 0
        meanConsolidation = 0
        recentSpikeRateHertz = 0
    }
}

public enum FidelityProjector {
    public static func summarize(
        compartmentRange: RuntimeRange,
        synapseRange: RuntimeRange,
        state: TissueRuntimeState
    ) -> FidelityProjectionState {
        var result = FidelityProjectionState()
        var compartmentCount: Float = 0
        for index in compartmentRange.lowerBound..<compartmentRange.upperBound where Int(index) < state.compartments.count {
            let compartment = state.compartments[Int(index)]
            result.membraneChargeNanocoulombs += compartment.capacitanceNanofarads * compartment.voltageMillivolts * 1e-3
            result.intracellularCalciumAmount += compartment.intracellularCalciumMicromolar
            result.intracellularSodiumAmount += compartment.intracellularSodiumMillimolar
            result.intracellularPotassiumAmount += compartment.intracellularPotassiumMillimolar
            compartmentCount += 1
        }
        var synapseCount: Float = 0
        for index in synapseRange.lowerBound..<synapseRange.upperBound where Int(index) < state.synapses.count {
            let synapse = state.synapses[Int(index)]
            result.totalSynapticConductance += synapse.conductance
            result.meanEligibility += synapse.eligibility
            result.meanConsolidation += synapse.consolidation
            synapseCount += 1
        }
        if compartmentCount > 0 {
            result.intracellularCalciumAmount /= compartmentCount
            result.intracellularSodiumAmount /= compartmentCount
            result.intracellularPotassiumAmount /= compartmentCount
        }
        if synapseCount > 0 {
            result.meanEligibility /= synapseCount
            result.meanConsolidation /= synapseCount
        }
        return result
    }
}
