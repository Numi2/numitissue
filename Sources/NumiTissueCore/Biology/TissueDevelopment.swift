import Foundation

@frozen
public struct NTCellMechanicsParameters: Codable, Hashable, Sendable {
    public var dragPiconewtonSecondsPerMicrometer: Float
    public var repulsionPiconewtonsPerMicrometer: Float
    public var adhesionPiconewtons: Float
    public var adhesionRangeMicrometers: Float
    public var motilityPiconewtons: Float
    public var persistenceSeconds: Float
    public var maximumSpeedMicrometersPerSecond: Float
    public var boundaryStiffnessPiconewtonsPerMicrometer: Float

    public init(
        dragPiconewtonSecondsPerMicrometer: Float = 20,
        repulsionPiconewtonsPerMicrometer: Float = 50,
        adhesionPiconewtons: Float = 2,
        adhesionRangeMicrometers: Float = 4,
        motilityPiconewtons: Float = 1,
        persistenceSeconds: Float = 60,
        maximumSpeedMicrometersPerSecond: Float = 2,
        boundaryStiffnessPiconewtonsPerMicrometer: Float = 100
    ) {
        self.dragPiconewtonSecondsPerMicrometer = dragPiconewtonSecondsPerMicrometer
        self.repulsionPiconewtonsPerMicrometer = repulsionPiconewtonsPerMicrometer
        self.adhesionPiconewtons = adhesionPiconewtons
        self.adhesionRangeMicrometers = adhesionRangeMicrometers
        self.motilityPiconewtons = motilityPiconewtons
        self.persistenceSeconds = persistenceSeconds
        self.maximumSpeedMicrometersPerSecond = maximumSpeedMicrometersPerSecond
        self.boundaryStiffnessPiconewtonsPerMicrometer = boundaryStiffnessPiconewtonsPerMicrometer
    }
}

@frozen
public struct NTFateProgram: Codable, Hashable, Sendable {
    public var cellKind: NTCellKind
    public var cycleDurationSeconds: Float
    public var divisionProbabilityPerCycle: Float
    public var asymmetricDivisionProbability: Float
    public var differentiationRatePerSecond: Float
    public var apoptosisBaseRatePerSecond: Float
    public var damageApoptosisGain: Float
    public var energyRequirement: Float
    public var daughterKind: NTCellKind
    public var asymmetricDaughterKind: NTCellKind
    public var motilityMultiplier: Float
    public var adhesionClass: UInt16

    public init(
        cellKind: NTCellKind,
        cycleDurationSeconds: Float,
        divisionProbabilityPerCycle: Float,
        asymmetricDivisionProbability: Float,
        differentiationRatePerSecond: Float,
        apoptosisBaseRatePerSecond: Float,
        damageApoptosisGain: Float,
        energyRequirement: Float,
        daughterKind: NTCellKind,
        asymmetricDaughterKind: NTCellKind,
        motilityMultiplier: Float,
        adhesionClass: UInt16
    ) {
        self.cellKind = cellKind
        self.cycleDurationSeconds = cycleDurationSeconds
        self.divisionProbabilityPerCycle = divisionProbabilityPerCycle
        self.asymmetricDivisionProbability = asymmetricDivisionProbability
        self.differentiationRatePerSecond = differentiationRatePerSecond
        self.apoptosisBaseRatePerSecond = apoptosisBaseRatePerSecond
        self.damageApoptosisGain = damageApoptosisGain
        self.energyRequirement = energyRequirement
        self.daughterKind = daughterKind
        self.asymmetricDaughterKind = asymmetricDaughterKind
        self.motilityMultiplier = motilityMultiplier
        self.adhesionClass = adhesionClass
    }
}

public struct NTDevelopmentProgram: Codable, Sendable {
    public var fates: [NTCellKind: NTFateProgram]
    public var regulatoryCoupling: [[Float]]
    public var regulatoryBias: [Float]

    public init(
        fates: [NTCellKind: NTFateProgram] = Self.corticalDefaults,
        regulatoryCoupling: [[Float]] = Self.defaultRegulatoryCoupling,
        regulatoryBias: [Float] = Array(repeating: 0, count: 32)
    ) {
        self.fates = fates
        self.regulatoryCoupling = regulatoryCoupling
        self.regulatoryBias = regulatoryBias
    }

    public func fate(for kind: NTCellKind) -> NTFateProgram {
        fates[kind] ?? NTFateProgram(
            cellKind: kind,
            cycleDurationSeconds: .greatestFiniteMagnitude,
            divisionProbabilityPerCycle: 0,
            asymmetricDivisionProbability: 0,
            differentiationRatePerSecond: 0,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.001,
            energyRequirement: 0.1,
            daughterKind: kind,
            asymmetricDaughterKind: kind,
            motilityMultiplier: 0,
            adhesionClass: 0
        )
    }

    public static let corticalDefaults: [NTCellKind: NTFateProgram] = [
        .radialGlia: .init(
            cellKind: .radialGlia,
            cycleDurationSeconds: 72_000,
            divisionProbabilityPerCycle: 0.95,
            asymmetricDivisionProbability: 0.55,
            differentiationRatePerSecond: 1.0e-7,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.005,
            energyRequirement: 0.45,
            daughterKind: .radialGlia,
            asymmetricDaughterKind: .intermediateProgenitor,
            motilityMultiplier: 0.1,
            adhesionClass: 1
        ),
        .intermediateProgenitor: .init(
            cellKind: .intermediateProgenitor,
            cycleDurationSeconds: 54_000,
            divisionProbabilityPerCycle: 0.8,
            asymmetricDivisionProbability: 0.35,
            differentiationRatePerSecond: 3.0e-7,
            apoptosisBaseRatePerSecond: 2.0e-8,
            damageApoptosisGain: 0.006,
            energyRequirement: 0.5,
            daughterKind: .intermediateProgenitor,
            asymmetricDaughterKind: .excitatoryNeuron,
            motilityMultiplier: 0.4,
            adhesionClass: 1
        ),
        .excitatoryNeuron: .init(
            cellKind: .excitatoryNeuron,
            cycleDurationSeconds: .greatestFiniteMagnitude,
            divisionProbabilityPerCycle: 0,
            asymmetricDivisionProbability: 0,
            differentiationRatePerSecond: 2.0e-7,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.01,
            energyRequirement: 0.25,
            daughterKind: .excitatoryNeuron,
            asymmetricDaughterKind: .excitatoryNeuron,
            motilityMultiplier: 0.25,
            adhesionClass: 2
        ),
        .inhibitoryNeuron: .init(
            cellKind: .inhibitoryNeuron,
            cycleDurationSeconds: .greatestFiniteMagnitude,
            divisionProbabilityPerCycle: 0,
            asymmetricDivisionProbability: 0,
            differentiationRatePerSecond: 2.0e-7,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.01,
            energyRequirement: 0.25,
            daughterKind: .inhibitoryNeuron,
            asymmetricDaughterKind: .inhibitoryNeuron,
            motilityMultiplier: 0.45,
            adhesionClass: 2
        ),
        .astrocyte: .init(
            cellKind: .astrocyte,
            cycleDurationSeconds: 172_800,
            divisionProbabilityPerCycle: 0.1,
            asymmetricDivisionProbability: 0,
            differentiationRatePerSecond: 1.0e-7,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.004,
            energyRequirement: 0.2,
            daughterKind: .astrocyte,
            asymmetricDaughterKind: .astrocyte,
            motilityMultiplier: 0.15,
            adhesionClass: 3
        ),
        .oligodendrocytePrecursor: .init(
            cellKind: .oligodendrocytePrecursor,
            cycleDurationSeconds: 129_600,
            divisionProbabilityPerCycle: 0.3,
            asymmetricDivisionProbability: 0.2,
            differentiationRatePerSecond: 2.0e-7,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.004,
            energyRequirement: 0.25,
            daughterKind: .oligodendrocytePrecursor,
            asymmetricDaughterKind: .oligodendrocyte,
            motilityMultiplier: 0.3,
            adhesionClass: 3
        ),
        .microglia: .init(
            cellKind: .microglia,
            cycleDurationSeconds: 259_200,
            divisionProbabilityPerCycle: 0.05,
            asymmetricDivisionProbability: 0,
            differentiationRatePerSecond: 0,
            apoptosisBaseRatePerSecond: 1.0e-8,
            damageApoptosisGain: 0.002,
            energyRequirement: 0.15,
            daughterKind: .microglia,
            asymmetricDaughterKind: .microglia,
            motilityMultiplier: 0.8,
            adhesionClass: 4
        )
    ]

    public static let defaultRegulatoryCoupling: [[Float]] = {
        var matrix = Array(repeating: Array(repeating: Float.zero, count: 32), count: 32)
        for i in 0..<32 { matrix[i][i] = -0.05 }
        matrix[1][0] = 0.2
        matrix[2][1] = 0.15
        matrix[3][2] = -0.1
        matrix[4][0] = -0.1
        matrix[5][4] = 0.2
        matrix[6][5] = 0.1
        matrix[7][6] = -0.05
        return matrix
    }()
}

@frozen
public struct NTGrowthConeState: Codable, Hashable, Sendable {
    public var id: SegmentID
    public var ownerCell: CellID
    public var parentCompartmentIndex: UInt32
    public var tile: TileID
    public var positionMicrometers: NTVector3
    public var direction: NTVector3
    public var radiusMicrometers: Float
    public var speedMicrometersPerSecond: Float
    public var accumulatedLengthMicrometers: Float
    public var branchHazard: Float
    public var collapseHazard: Float
    public var retractionMicrometers: Float
    public var ageSeconds: Float
    public var targetCellKinds: [NTCellKind]
    public var active: Bool
    public var flags: UInt32

    public init(
        id: SegmentID,
        ownerCell: CellID,
        parentCompartmentIndex: UInt32,
        tile: TileID,
        positionMicrometers: NTVector3,
        direction: NTVector3,
        radiusMicrometers: Float = 0.4,
        speedMicrometersPerSecond: Float = 0.01,
        accumulatedLengthMicrometers: Float = 0,
        branchHazard: Float = 0,
        collapseHazard: Float = 0,
        retractionMicrometers: Float = 0,
        ageSeconds: Float = 0,
        targetCellKinds: [NTCellKind] = [.excitatoryNeuron, .inhibitoryNeuron],
        active: Bool = true,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.ownerCell = ownerCell
        self.parentCompartmentIndex = parentCompartmentIndex
        self.tile = tile
        self.positionMicrometers = positionMicrometers
        self.direction = direction.normalized()
        self.radiusMicrometers = radiusMicrometers
        self.speedMicrometersPerSecond = speedMicrometersPerSecond
        self.accumulatedLengthMicrometers = accumulatedLengthMicrometers
        self.branchHazard = branchHazard
        self.collapseHazard = collapseHazard
        self.retractionMicrometers = retractionMicrometers
        self.ageSeconds = ageSeconds
        self.targetCellKinds = targetCellKinds
        self.active = active
        self.flags = flags
    }
}

@frozen
public struct NTNeuriteGrowthParameters: Codable, Hashable, Sendable {
    public var segmentLengthMicrometers: Float
    public var captureRadiusMicrometers: Float
    public var persistenceWeight: Float
    public var attractiveWeight: Float
    public var repulsiveWeight: Float
    public var trophicWeight: Float
    public var fasciculationWeight: Float
    public var activityWeight: Float
    public var noiseWeight: Float
    public var branchRatePerMicrometer: Float
    public var collapseRatePerSecond: Float
    public var minimumEnergy: Float
    public var initialSynapticWeightMicrosiemens: Float

    public init(
        segmentLengthMicrometers: Float = 2,
        captureRadiusMicrometers: Float = 2,
        persistenceWeight: Float = 1,
        attractiveWeight: Float = 0.8,
        repulsiveWeight: Float = 1,
        trophicWeight: Float = 0.4,
        fasciculationWeight: Float = 0.2,
        activityWeight: Float = 0.2,
        noiseWeight: Float = 0.1,
        branchRatePerMicrometer: Float = 0.002,
        collapseRatePerSecond: Float = 1.0e-5,
        minimumEnergy: Float = 0.1,
        initialSynapticWeightMicrosiemens: Float = 0.001
    ) {
        self.segmentLengthMicrometers = segmentLengthMicrometers
        self.captureRadiusMicrometers = captureRadiusMicrometers
        self.persistenceWeight = persistenceWeight
        self.attractiveWeight = attractiveWeight
        self.repulsiveWeight = repulsiveWeight
        self.trophicWeight = trophicWeight
        self.fasciculationWeight = fasciculationWeight
        self.activityWeight = activityWeight
        self.noiseWeight = noiseWeight
        self.branchRatePerMicrometer = branchRatePerMicrometer
        self.collapseRatePerSecond = collapseRatePerSecond
        self.minimumEnergy = minimumEnergy
        self.initialSynapticWeightMicrosiemens = initialSynapticWeightMicrosiemens
    }
}

@frozen
public struct NTDevelopmentStepResult: Sendable {
    public var divisions: UInt32
    public var differentiations: UInt32
    public var apoptoticTransitions: UInt32
    public var migrations: UInt32
    public var newCompartments: UInt32
    public var newBranches: UInt32
    public var newSynapses: UInt32
    public var collapsedGrowthCones: UInt32
    public var maximumOverlapFraction: Float
    public var diagnostics: [NTDiagnostic]

    public init() {
        divisions = 0
        differentiations = 0
        apoptoticTransitions = 0
        migrations = 0
        newCompartments = 0
        newBranches = 0
        newSynapses = 0
        collapsedGrowthCones = 0
        maximumOverlapFraction = 0
        diagnostics = []
    }
}

private struct NTSpatialKey: Hashable {
    var x: Int32
    var y: Int32
    var z: Int32
}

public struct NTTissueDevelopmentEngine: Sendable {
    public var mechanics: NTCellMechanicsParameters
    public var program: NTDevelopmentProgram
    public var growth: NTNeuriteGrowthParameters
    public var fieldEngine: NTExtracellularFieldEngine

    public init(
        mechanics: NTCellMechanicsParameters = .init(),
        program: NTDevelopmentProgram = .init(),
        growth: NTNeuriteGrowthParameters = .init(),
        fieldEngine: NTExtracellularFieldEngine = .init()
    ) {
        self.mechanics = mechanics
        self.program = program
        self.growth = growth
        self.fieldEngine = fieldEngine
    }

    public func step(
        state: inout NTProductionState,
        growthCones: inout [NTGrowthConeState],
        deltaTicks: UInt64,
        transaction: TransactionID
    ) -> NTDevelopmentStepResult {
        let dt = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        guard dt > 0 else { return .init() }
        var result = NTDevelopmentStepResult()
        integrateRegulatoryPrograms(state: &state, dt: dt)
        applyCellMechanics(state: &state, dt: dt, transaction: transaction, result: &result)
        processCellFates(state: &state, dt: dt, transaction: transaction, result: &result)
        advanceGrowthCones(
            state: &state,
            growthCones: &growthCones,
            dt: dt,
            transaction: transaction,
            result: &result
        )
        return result
    }

    private func integrateRegulatoryPrograms(state: inout NTProductionState, dt: Float) {
        guard program.regulatoryCoupling.count >= 32 else { return }
        for index in state.cells.indices {
            guard state.cells[index].record.phase != .dead else { continue }
            var values = state.cells[index].record.regulatoryState
            if values.count < 32 { values.append(contentsOf: repeatElement(0, count: 32 - values.count)) }
            if values.count > 32 { values.removeLast(values.count - 32) }
            var derivative = Array(repeating: Float.zero, count: 32)
            for row in 0..<32 {
                var value = program.regulatoryBias[safe: row] ?? 0
                let weights = program.regulatoryCoupling[row]
                for column in 0..<min(32, weights.count) {
                    value += weights[column] * values[column]
                }
                derivative[row] = tanh(value)
            }
            let activity = meanActivity(cell: state.cells[index].record.id, state: state)
            derivative[0] += 0.05 * activity
            derivative[4] += 0.1 * state.cells[index].record.oxygenStress
            derivative[5] += 0.1 * state.cells[index].record.damage
            for lane in 0..<32 {
                values[lane] = max(-4, min(4, values[lane] + derivative[lane] * dt))
            }
            state.cells[index].record.regulatoryState = values
        }
    }

    private func applyCellMechanics(
        state: inout NTProductionState,
        dt: Float,
        transaction: TransactionID,
        result: inout NTDevelopmentStepResult
    ) {
        guard !state.cells.isEmpty else { return }
        let interactionRadius = max(
            mechanics.adhesionRangeMicrometers + state.cells.map { max($0.record.radiiMicrometers.x, max($0.record.radiiMicrometers.y, $0.record.radiiMicrometers.z)) }.max()!,
            5
        )
        var buckets: [NTSpatialKey: [Int]] = [:]
        for index in state.cells.indices where state.cells[index].record.phase != .dead {
            let p = state.cells[index].record.positionMicrometers
            let key = NTSpatialKey(
                x: Int32(floor(p.x / interactionRadius)),
                y: Int32(floor(p.y / interactionRadius)),
                z: Int32(floor(p.z / interactionRadius))
            )
            buckets[key, default: []].append(index)
            state.cells[index].forcePiconewtons = .zero
        }

        for (key, indices) in buckets {
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let neighbor = NTSpatialKey(x: key.x + Int32(dx), y: key.y + Int32(dy), z: key.z + Int32(dz))
                        guard let candidates = buckets[neighbor] else { continue }
                        for i in indices {
                            for j in candidates where j > i {
                                applyPairForce(i: i, j: j, state: &state, result: &result)
                            }
                        }
                    }
                }
            }
        }

        for index in state.cells.indices where state.cells[index].record.phase != .dead {
            var cell = state.cells[index]
            let fate = program.fate(for: cell.record.kind)
            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: cell.record.id.rawValue,
                    stream: 0x4D4F5449,
                    sample: UInt32(truncatingIfNeeded: state.time.tick)
                ).counter(),
                key: PhiloxKey(seed: state.configuration.seed)
            )
            let noise = CounterRandom.normalPair(random.x, random.y)
            let noiseZ = CounterRandom.normalPair(random.z, random.w).x
            let stochasticDirection = NTVector3(noise.x, noise.y, noiseZ).normalized()
            let persistence = exp(-dt / max(mechanics.persistenceSeconds, 1.0e-6))
            cell.record.orientation = (cell.record.orientation * persistence + stochasticDirection * (1 - persistence)).normalized()
            let motility = cell.record.orientation * mechanics.motilityPiconewtons * fate.motilityMultiplier * cell.record.energy
            let totalForce = cell.forcePiconewtons + motility
            var velocity = totalForce / max(mechanics.dragPiconewtonSecondsPerMicrometer, 1.0e-6)
            let speed = velocity.length
            if speed > mechanics.maximumSpeedMicrometersPerSecond {
                velocity = velocity * (mechanics.maximumSpeedMicrometersPerSecond / speed)
            }
            let previousTile = cell.record.tile
            cell.record.velocityMicrometersPerSecond = velocity
            cell.record.positionMicrometers = cell.record.positionMicrometers + velocity * dt
            enforceWorldBounds(cell: &cell, state: state)
            if let tile = tileContaining(position: cell.record.positionMicrometers, state: state), tile != previousTile {
                do {
                    state.cells[index] = cell
                    try state.migrateCell(at: index, to: tile, at: state.time)
                    cell = state.cells[index]
                    result.migrations &+= 1
                } catch {
                    cell.record.positionMicrometers = state.cells[index].record.positionMicrometers
                    cell.record.velocityMicrometersPerSecond = .zero
                    result.diagnostics.append(.init(
                        severity: .warning,
                        code: .resourceBudgetExceeded,
                        message: "Cell migration was deferred because the destination tile is full.",
                        entity: cell.record.id.rawValue,
                        tile: previousTile
                    ))
                }
            }
            state.cells[index] = cell
        }
    }

    private func applyPairForce(
        i: Int,
        j: Int,
        state: inout NTProductionState,
        result: inout NTDevelopmentStepResult
    ) {
        let left = state.cells[i]
        let right = state.cells[j]
        let delta = right.record.positionMicrometers - left.record.positionMicrometers
        let distance = max(delta.length, 1.0e-6)
        let leftRadius = geometricMeanRadius(left.record.radiiMicrometers)
        let rightRadius = geometricMeanRadius(right.record.radiiMicrometers)
        let contactDistance = leftRadius + rightRadius
        let direction = delta / distance
        var force: Float = 0
        if distance < contactDistance {
            let overlap = contactDistance - distance
            force = -mechanics.repulsionPiconewtonsPerMicrometer * overlap
            result.maximumOverlapFraction = max(result.maximumOverlapFraction, overlap / max(contactDistance, 1.0e-6))
        } else if distance < contactDistance + mechanics.adhesionRangeMicrometers {
            let separation = (distance - contactDistance) / mechanics.adhesionRangeMicrometers
            let adhesionCompatibility = adhesion(left: left.record.kind, right: right.record.kind)
            force = mechanics.adhesionPiconewtons * adhesionCompatibility * (1 - separation)
        }
        let vector = direction * force
        state.cells[i].forcePiconewtons = state.cells[i].forcePiconewtons + vector
        state.cells[j].forcePiconewtons = state.cells[j].forcePiconewtons - vector
    }

    private func processCellFates(
        state: inout NTProductionState,
        dt: Float,
        transaction: TransactionID,
        result: inout NTDevelopmentStepResult
    ) {
        var daughters: [NTProductionCell] = []
        daughters.reserveCapacity(max(1, state.cells.count / 100))
        var nextCellRaw = (state.cells.map { $0.record.id.rawValue }.max() ?? 0) &+ 1
        var nextLineageRaw = (state.cells.map { $0.record.lineage.rawValue }.max() ?? 0) &+ 1

        let originalCount = state.cells.count
        for index in 0..<originalCount {
            var cell = state.cells[index]
            guard cell.record.phase != .dead, cell.record.phase != .apoptotic else {
                if cell.record.phase == .apoptotic {
                    cell.record.radiiMicrometers = cell.record.radiiMicrometers * max(0, 1 - 0.01 * dt)
                    if cell.record.radiiMicrometers.length < 0.1 { cell.record.phase = .dead }
                    state.cells[index] = cell
                }
                continue
            }
            let fate = program.fate(for: cell.record.kind)
            cell.record.ageSeconds += dt
            let cycleRate = fate.cycleDurationSeconds.isFinite && fate.cycleDurationSeconds > 0 ? dt / fate.cycleDurationSeconds : 0
            cell.record.cycleProgress += cycleRate * max(0, min(1, cell.record.energy / max(fate.energyRequirement, 1.0e-6)))
            cell.divisionHazardIntegral += cycleRate * fate.divisionProbabilityPerCycle
            cell.differentiationHazardIntegral += fate.differentiationRatePerSecond * dt * (1 + 0.1 * max(0, cell.record.regulatoryState[safe: 2] ?? 0))
            cell.apoptosisHazardIntegral += (fate.apoptosisBaseRatePerSecond + fate.damageApoptosisGain * cell.record.damage) * dt

            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: cell.record.id.rawValue,
                    stream: 0x46415445,
                    sample: UInt32(index)
                ).counter(),
                key: PhiloxKey(seed: state.configuration.seed)
            )
            let divisionDraw = CounterRandom.uniform01(random.x)
            let differentiationDraw = CounterRandom.uniform01(random.y)
            let apoptosisDraw = CounterRandom.uniform01(random.z)
            let asymmetryDraw = CounterRandom.uniform01(random.w)

            if apoptosisDraw < hazardProbability(cell.apoptosisHazardIntegral) {
                cell.record.phase = .apoptotic
                cell.apoptosisHazardIntegral = 0
                state.lineage.append(.init(time: state.time, kind: .apoptotic, cell: cell.record.id))
                result.apoptoticTransitions &+= 1
            } else if cell.record.cycleProgress >= 1,
                      cell.record.energy >= fate.energyRequirement,
                      divisionDraw < hazardProbability(cell.divisionHazardIntegral) {
                let axisNoise = CounterRandom.normalPair(random.x ^ random.z, random.y ^ random.w)
                let axis = NTVector3(axisNoise.x, axisNoise.y, Float(Int32(bitPattern: random.w)) / Float(Int32.max)).normalized()
                let displacement = axis * geometricMeanRadius(cell.record.radiiMicrometers) * 0.55
                let asymmetric = asymmetryDraw < fate.asymmetricDivisionProbability
                let daughterKind = asymmetric ? fate.asymmetricDaughterKind : fate.daughterKind
                var daughterRecord = cell.record
                daughterRecord.id = CellID(rawValue: nextCellRaw)
                daughterRecord.lineage = LineageID(rawValue: nextLineageRaw)
                daughterRecord.kind = daughterKind
                daughterRecord.positionMicrometers = daughterRecord.positionMicrometers + displacement
                daughterRecord.ageSeconds = 0
                daughterRecord.cycleProgress = 0
                daughterRecord.differentiationProgress = 0
                daughterRecord.energy *= 0.5
                daughterRecord.damage *= 0.5
                daughterRecord.regulatoryState = partitionRegulatoryState(cell.record.regulatoryState, bias: asymmetric ? 0.1 : 0)
                cell.record.positionMicrometers = cell.record.positionMicrometers - displacement
                cell.record.cycleProgress = 0
                cell.record.energy *= 0.5
                cell.divisionHazardIntegral = 0
                daughters.append(NTProductionCell(record: daughterRecord))
                state.lineage.append(.init(time: state.time, kind: .divided, cell: daughterRecord.id, parent: cell.record.id))
                nextCellRaw &+= 1
                nextLineageRaw &+= 1
                result.divisions &+= 1
            } else if differentiationDraw < hazardProbability(cell.differentiationHazardIntegral),
                      fate.asymmetricDaughterKind != cell.record.kind {
                cell.record.kind = fate.asymmetricDaughterKind
                cell.record.phase = .differentiated
                cell.record.differentiationProgress = 1
                cell.differentiationHazardIntegral = 0
                state.lineage.append(.init(
                    time: state.time,
                    kind: .differentiated,
                    cell: cell.record.id,
                    stateCode: UInt32(cell.record.kind.rawValue)
                ))
                result.differentiations &+= 1
            }
            state.cells[index] = cell
        }

        for daughter in daughters {
            do {
                _ = try state.appendCell(daughter)
            } catch {
                result.diagnostics.append(.init(
                    severity: .warning,
                    code: .resourceBudgetExceeded,
                    message: "A cell division was staged but could not commit: \(error)",
                    entity: daughter.record.id.rawValue,
                    tile: daughter.record.tile
                ))
            }
        }
    }

    private func advanceGrowthCones(
        state: inout NTProductionState,
        growthCones: inout [NTGrowthConeState],
        dt: Float,
        transaction: TransactionID,
        result: inout NTDevelopmentStepResult
    ) {
        guard !growthCones.isEmpty else { return }
        var newCones: [NTGrowthConeState] = []
        var nextCompartmentRaw = (state.compartments.map { $0.record.id.rawValue }.max() ?? 0) &+ 1
        var nextSegmentRaw = (growthCones.map { $0.id.rawValue }.max() ?? 0) &+ 1
        var nextSynapseRaw = (state.synapses.map { $0.record.id.rawValue }.max() ?? 0) &+ 1
        var nextRouteRaw = (state.routeTable.routes.map { $0.id.rawValue }.max() ?? 0) &+ 1

        for coneIndex in growthCones.indices {
            var cone = growthCones[coneIndex]
            guard cone.active,
                  let ownerIndex = state.cellIndex(id: cone.ownerCell),
                  state.cells[ownerIndex].record.energy >= growth.minimumEnergy else { continue }
            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: cone.id.rawValue,
                    stream: 0x47524F57,
                    sample: UInt32(coneIndex)
                ).counter(),
                key: PhiloxKey(seed: state.configuration.seed)
            )
            let noise2 = CounterRandom.normalPair(random.x, random.y)
            let noiseZ = CounterRandom.normalPair(random.z, random.w).x
            let noise = NTVector3(noise2.x, noise2.y, noiseZ).normalized()
            let attractive = fieldGradient(state: state, cone: cone, species: .attractiveGuidance)
            let repulsive = fieldGradient(state: state, cone: cone, species: .repulsiveGuidance)
            let trophic = fieldGradient(state: state, cone: cone, species: .trophicSupport)
            let direction = (
                cone.direction * growth.persistenceWeight +
                attractive * growth.attractiveWeight -
                repulsive * growth.repulsiveWeight +
                trophic * growth.trophicWeight +
                noise * growth.noiseWeight
            ).normalized(or: cone.direction)
            let advance = cone.speedMicrometersPerSecond * state.cells[ownerIndex].record.energy * dt
            cone.direction = direction
            cone.positionMicrometers = cone.positionMicrometers + direction * advance
            cone.accumulatedLengthMicrometers += advance
            cone.ageSeconds += dt
            cone.branchHazard += growth.branchRatePerMicrometer * advance
            cone.collapseHazard += growth.collapseRatePerSecond * dt * (1 + state.cells[ownerIndex].record.damage)

            if CounterRandom.uniform01(random.z) < hazardProbability(cone.collapseHazard) {
                cone.active = false
                cone.collapseHazard = 0
                result.collapsedGrowthCones &+= 1
                growthCones[coneIndex] = cone
                continue
            }

            while cone.accumulatedLengthMicrometers >= growth.segmentLengthMicrometers {
                guard state.compartments.indices.contains(Int(cone.parentCompartmentIndex)) else {
                    cone.active = false
                    result.diagnostics.append(.init(
                        severity: .error,
                        code: .invalidMorphology,
                        message: "Growth cone parent compartment is absent.",
                        entity: cone.id.rawValue,
                        tile: cone.tile
                    ))
                    break
                }
                let parent = state.compartments[Int(cone.parentCompartmentIndex)]
                let compartmentClass: NTCompartmentClass = parent.record.compartmentClass == .axon || parent.record.compartmentClass == .axonInitialSegment
                    ? .axon : .basalDendrite
                let newRecord = NTCompartmentRecord(
                    id: CompartmentID(rawValue: nextCompartmentRaw),
                    cell: cone.ownerCell,
                    tile: cone.tile,
                    parentIndex: Int32(cone.parentCompartmentIndex),
                    level: parent.record.level &+ 1,
                    compartmentClass: compartmentClass,
                    mechanismSet: parent.record.mechanismSet,
                    positionMicrometers: cone.positionMicrometers,
                    lengthMicrometers: growth.segmentLengthMicrometers,
                    diameterMicrometers: max(0.1, cone.radiusMicrometers * 2),
                    membraneVoltageMillivolts: parent.record.membraneVoltageMillivolts,
                    capacitanceNanofarads: max(1.0e-6, parent.record.capacitanceNanofarads * 0.25),
                    axialConductanceMicrosiemens: max(1.0e-6, parent.record.axialConductanceMicrosiemens)
                )
                do {
                    let newIndex = try state.appendCompartment(.init(record: newRecord, gates: parent.gates))
                    cone.parentCompartmentIndex = UInt32(newIndex)
                    cone.accumulatedLengthMicrometers -= growth.segmentLengthMicrometers
                    nextCompartmentRaw &+= 1
                    result.newCompartments &+= 1
                    if let target = synapticTarget(for: cone, ownerCell: cone.ownerCell, state: state) {
                        let receptor: NTSynapseReceptor = state.cells[ownerIndex].record.kind == .inhibitoryNeuron ? .gabaA : .ampa
                        let routeID = RouteID(rawValue: nextRouteRaw)
                        let synapse = NTSynapseRecord(
                            id: SynapseID(rawValue: nextSynapseRaw),
                            preCompartmentIndex: UInt32(newIndex),
                            postCompartmentIndex: UInt32(target),
                            route: routeID,
                            receptor: receptor,
                            delayTicks: 40,
                            weightMicrosiemens: growth.initialSynapticWeightMicrosiemens,
                            structuralScore: 0.1
                        )
                        _ = try state.appendSynapse(.init(record: synapse))
                        nextSynapseRaw &+= 1
                        nextRouteRaw &+= 1
                        result.newSynapses &+= 1
                    }
                } catch {
                    cone.active = false
                    result.diagnostics.append(.init(
                        severity: .warning,
                        code: .resourceBudgetExceeded,
                        message: "Neurite extension stopped because topology capacity was exhausted: \(error)",
                        entity: cone.id.rawValue,
                        tile: cone.tile
                    ))
                    break
                }
            }

            if cone.active, CounterRandom.uniform01(random.w) < hazardProbability(cone.branchHazard) {
                let branchNoise = CounterRandom.normalPair(random.x ^ random.w, random.y ^ random.z)
                let branchAxis = NTVector3(branchNoise.x, branchNoise.y, noiseZ).normalized()
                let branchDirection = (cone.direction * 0.7 + branchAxis * 0.3).normalized()
                newCones.append(NTGrowthConeState(
                    id: SegmentID(rawValue: nextSegmentRaw),
                    ownerCell: cone.ownerCell,
                    parentCompartmentIndex: cone.parentCompartmentIndex,
                    tile: cone.tile,
                    positionMicrometers: cone.positionMicrometers,
                    direction: branchDirection,
                    radiusMicrometers: cone.radiusMicrometers * 0.8,
                    speedMicrometersPerSecond: cone.speedMicrometersPerSecond * 0.9,
                    targetCellKinds: cone.targetCellKinds
                ))
                nextSegmentRaw &+= 1
                cone.branchHazard = 0
                result.newBranches &+= 1
            }
            growthCones[coneIndex] = cone
        }
        growthCones.append(contentsOf: newCones)
    }

    private func fieldGradient(
        state: NTProductionState,
        cone: NTGrowthConeState,
        species: NTExtracellularSpecies
    ) -> NTVector3 {
        let h = state.configuration.tileEdgeMicrometers / Float(state.configuration.fieldResolution)
        let center = cone.positionMicrometers
        func value(_ offset: NTVector3) -> Float {
            fieldEngine.sample(
                state: state,
                tile: cone.tile,
                positionMicrometers: center + offset,
                species: species
            ) ?? 0
        }
        return NTVector3(
            (value(.init(h, 0, 0)) - value(.init(-h, 0, 0))) / (2 * h),
            (value(.init(0, h, 0)) - value(.init(0, -h, 0))) / (2 * h),
            (value(.init(0, 0, h)) - value(.init(0, 0, -h))) / (2 * h)
        )
    }

    private func synapticTarget(for cone: NTGrowthConeState, ownerCell: CellID, state: NTProductionState) -> Int? {
        let captureSquared = growth.captureRadiusMicrometers * growth.captureRadiusMicrometers
        var best: (index: Int, distance: Float)?
        for index in state.compartments.indices {
            let candidate = state.compartments[index]
            guard candidate.record.cell != ownerCell,
                  candidate.record.compartmentClass == .basalDendrite ||
                  candidate.record.compartmentClass == .apicalDendrite ||
                  candidate.record.compartmentClass == .spineHead ||
                  candidate.record.compartmentClass == .soma,
                  let cellIndex = state.cellIndex(id: candidate.record.cell),
                  cone.targetCellKinds.contains(state.cells[cellIndex].record.kind) else { continue }
            let distance = (candidate.record.positionMicrometers - cone.positionMicrometers).squaredLength
            if distance <= captureSquared, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func meanActivity(cell: CellID, state: NTProductionState) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for compartment in state.compartments where compartment.record.cell == cell {
            sum += Float(compartment.spikeCountWindow)
            count += 1
        }
        return count > 0 ? sum / count : 0
    }

    private func enforceWorldBounds(cell: inout NTProductionCell, state: NTProductionState) {
        guard !state.tiles.isEmpty else { return }
        let coordinates = state.tiles.map(\.membership.coordinate)
        guard let minX = coordinates.map(\.x).min(), let maxX = coordinates.map(\.x).max(),
              let minY = coordinates.map(\.y).min(), let maxY = coordinates.map(\.y).max(),
              let minZ = coordinates.map(\.z).min(), let maxZ = coordinates.map(\.z).max() else { return }
        let edge = state.configuration.tileEdgeMicrometers
        let minimum = NTVector3(
            state.configuration.originMicrometers.x + Float(minX) * edge,
            state.configuration.originMicrometers.y + Float(minY) * edge,
            state.configuration.originMicrometers.z + Float(minZ) * edge
        )
        let maximum = NTVector3(
            state.configuration.originMicrometers.x + Float(maxX + 1) * edge,
            state.configuration.originMicrometers.y + Float(maxY + 1) * edge,
            state.configuration.originMicrometers.z + Float(maxZ + 1) * edge
        )
        cell.record.positionMicrometers.x = min(maximum.x, max(minimum.x, cell.record.positionMicrometers.x))
        cell.record.positionMicrometers.y = min(maximum.y, max(minimum.y, cell.record.positionMicrometers.y))
        cell.record.positionMicrometers.z = min(maximum.z, max(minimum.z, cell.record.positionMicrometers.z))
    }

    private func tileContaining(position: NTVector3, state: NTProductionState) -> TileID? {
        let edge = state.configuration.tileEdgeMicrometers
        let coordinate = TileCoordinate(
            x: Int32(floor((position.x - state.configuration.originMicrometers.x) / edge)),
            y: Int32(floor((position.y - state.configuration.originMicrometers.y) / edge)),
            z: Int32(floor((position.z - state.configuration.originMicrometers.z) / edge))
        )
        return state.tiles.first(where: { $0.membership.coordinate == coordinate })?.membership.id
    }

    @inline(__always)
    private func geometricMeanRadius(_ radii: NTVector3) -> Float {
        pow(max(radii.x * radii.y * radii.z, 1.0e-12), 1.0 / 3.0)
    }

    private func adhesion(left: NTCellKind, right: NTCellKind) -> Float {
        let a = program.fate(for: left).adhesionClass
        let b = program.fate(for: right).adhesionClass
        if a == b { return 1 }
        if a == 0 || b == 0 { return 0.1 }
        return 0.35
    }

    private func partitionRegulatoryState(_ values: [Float], bias: Float) -> [Float] {
        var result = Array(values.prefix(32))
        if result.count < 32 { result.append(contentsOf: repeatElement(0, count: 32 - result.count)) }
        for index in result.indices {
            result[index] = max(-4, min(4, result[index] + (index.isMultiple(of: 2) ? bias : -bias)))
        }
        return result
    }

    @inline(__always)
    private func hazardProbability(_ integratedHazard: Float) -> Float {
        1 - exp(-max(0, integratedHazard))
    }
}
