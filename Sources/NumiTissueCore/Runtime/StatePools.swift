import Foundation

// MARK: - Packed state pools

public enum NTCellKind: UInt16, Codable, CaseIterable, Sendable {
    case radialGlia
    case intermediateProgenitor
    case excitatoryNeuron
    case inhibitoryNeuron
    case astrocyte
    case oligodendrocytePrecursor
    case oligodendrocyte
    case microglia
    case endothelial
    case perivascular
    case custom = 65_535
}

public enum NTCellCyclePhase: UInt8, Codable, CaseIterable, Sendable {
    case quiescent
    case g1
    case s
    case g2
    case mitosis
    case differentiated
    case apoptotic
    case dead
}

@frozen
public struct NTCellRecord: Codable, Hashable, Sendable {
    public var id: CellID
    public var lineage: LineageID
    public var tile: TileID
    public var kind: NTCellKind
    public var phase: NTCellCyclePhase
    public var fidelity: NTFidelityLevel
    public var positionMicrometers: NTVector3
    public var velocityMicrometersPerSecond: NTVector3
    public var radiiMicrometers: NTVector3
    public var orientation: NTVector3
    public var ageSeconds: Float
    public var cycleProgress: Float
    public var differentiationProgress: Float
    public var energy: Float
    public var oxygenStress: Float
    public var glucoseStress: Float
    public var damage: Float
    public var regulatoryState: [Float]
    public var expressionProfile: UInt32
    public var flags: UInt32

    public init(
        id: CellID,
        lineage: LineageID,
        tile: TileID,
        kind: NTCellKind,
        phase: NTCellCyclePhase,
        fidelity: NTFidelityLevel,
        positionMicrometers: NTVector3,
        radiiMicrometers: NTVector3,
        velocityMicrometersPerSecond: NTVector3 = .zero,
        orientation: NTVector3 = .init(0, 1, 0),
        ageSeconds: Float = 0,
        cycleProgress: Float = 0,
        differentiationProgress: Float = 0,
        energy: Float = 1,
        oxygenStress: Float = 0,
        glucoseStress: Float = 0,
        damage: Float = 0,
        regulatoryState: [Float] = Array(repeating: 0, count: 32),
        expressionProfile: UInt32 = 0,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.lineage = lineage
        self.tile = tile
        self.kind = kind
        self.phase = phase
        self.fidelity = fidelity
        self.positionMicrometers = positionMicrometers
        self.velocityMicrometersPerSecond = velocityMicrometersPerSecond
        self.radiiMicrometers = radiiMicrometers
        self.orientation = orientation
        self.ageSeconds = ageSeconds
        self.cycleProgress = cycleProgress
        self.differentiationProgress = differentiationProgress
        self.energy = energy
        self.oxygenStress = oxygenStress
        self.glucoseStress = glucoseStress
        self.damage = damage
        self.regulatoryState = regulatoryState
        self.expressionProfile = expressionProfile
        self.flags = flags
    }
}

/// Structure-of-arrays storage used by both the CPU reference backend and Metal upload paths.
public struct NTCellPool: Codable, Sendable {
    public private(set) var ids: [CellID] = []
    public private(set) var lineages: [LineageID] = []
    public private(set) var tileIDs: [TileID] = []
    public private(set) var kinds: [UInt16] = []
    public private(set) var phases: [UInt8] = []
    public private(set) var fidelities: [UInt8] = []
    public private(set) var positions: [NTVector3] = []
    public private(set) var velocities: [NTVector3] = []
    public private(set) var radii: [NTVector3] = []
    public private(set) var orientations: [NTVector3] = []
    public private(set) var ages: [Float] = []
    public private(set) var cycleProgress: [Float] = []
    public private(set) var differentiationProgress: [Float] = []
    public private(set) var energy: [Float] = []
    public private(set) var oxygenStress: [Float] = []
    public private(set) var glucoseStress: [Float] = []
    public private(set) var damage: [Float] = []
    public private(set) var expressionProfiles: [UInt32] = []
    public private(set) var flags: [UInt32] = []
    public private(set) var regulatoryState: [Float] = []

    public init() {}

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public mutating func reserveCapacity(_ capacity: Int) {
        ids.reserveCapacity(capacity)
        lineages.reserveCapacity(capacity)
        tileIDs.reserveCapacity(capacity)
        kinds.reserveCapacity(capacity)
        phases.reserveCapacity(capacity)
        fidelities.reserveCapacity(capacity)
        positions.reserveCapacity(capacity)
        velocities.reserveCapacity(capacity)
        radii.reserveCapacity(capacity)
        orientations.reserveCapacity(capacity)
        ages.reserveCapacity(capacity)
        cycleProgress.reserveCapacity(capacity)
        differentiationProgress.reserveCapacity(capacity)
        energy.reserveCapacity(capacity)
        oxygenStress.reserveCapacity(capacity)
        glucoseStress.reserveCapacity(capacity)
        damage.reserveCapacity(capacity)
        expressionProfiles.reserveCapacity(capacity)
        flags.reserveCapacity(capacity)
        regulatoryState.reserveCapacity(capacity * 32)
    }

    @discardableResult
    public mutating func append(_ record: NTCellRecord) throws -> Int {
        guard record.regulatoryState.count == 32 else {
            throw NTRuntimeError.invalidModel("Cell regulatory state must contain exactly 32 values.")
        }
        let index = count
        ids.append(record.id)
        lineages.append(record.lineage)
        tileIDs.append(record.tile)
        kinds.append(record.kind.rawValue)
        phases.append(record.phase.rawValue)
        fidelities.append(record.fidelity.rawValue)
        positions.append(record.positionMicrometers)
        velocities.append(record.velocityMicrometersPerSecond)
        radii.append(record.radiiMicrometers)
        orientations.append(record.orientation)
        ages.append(record.ageSeconds)
        cycleProgress.append(record.cycleProgress)
        differentiationProgress.append(record.differentiationProgress)
        energy.append(record.energy)
        oxygenStress.append(record.oxygenStress)
        glucoseStress.append(record.glucoseStress)
        damage.append(record.damage)
        expressionProfiles.append(record.expressionProfile)
        flags.append(record.flags)
        regulatoryState.append(contentsOf: record.regulatoryState)
        return index
    }

    public func record(at index: Int) -> NTCellRecord? {
        guard indicesValid(index),
              let kind = NTCellKind(rawValue: kinds[index]),
              let phase = NTCellCyclePhase(rawValue: phases[index]),
              let fidelity = NTFidelityLevel(rawValue: fidelities[index]) else { return nil }
        let regulatoryStart = index * 32
        return NTCellRecord(
            id: ids[index],
            lineage: lineages[index],
            tile: tileIDs[index],
            kind: kind,
            phase: phase,
            fidelity: fidelity,
            positionMicrometers: positions[index],
            radiiMicrometers: radii[index],
            velocityMicrometersPerSecond: velocities[index],
            orientation: orientations[index],
            ageSeconds: ages[index],
            cycleProgress: cycleProgress[index],
            differentiationProgress: differentiationProgress[index],
            energy: energy[index],
            oxygenStress: oxygenStress[index],
            glucoseStress: glucoseStress[index],
            damage: damage[index],
            regulatoryState: Array(regulatoryState[regulatoryStart..<(regulatoryStart + 32)]),
            expressionProfile: expressionProfiles[index],
            flags: flags[index]
        )
    }

    public mutating func update(_ record: NTCellRecord, at index: Int) throws {
        guard indicesValid(index) else { throw NTRuntimeError.invalidModel("Cell index is out of range.") }
        guard record.regulatoryState.count == 32 else {
            throw NTRuntimeError.invalidModel("Cell regulatory state must contain exactly 32 values.")
        }
        ids[index] = record.id
        lineages[index] = record.lineage
        tileIDs[index] = record.tile
        kinds[index] = record.kind.rawValue
        phases[index] = record.phase.rawValue
        fidelities[index] = record.fidelity.rawValue
        positions[index] = record.positionMicrometers
        velocities[index] = record.velocityMicrometersPerSecond
        radii[index] = record.radiiMicrometers
        orientations[index] = record.orientation
        ages[index] = record.ageSeconds
        cycleProgress[index] = record.cycleProgress
        differentiationProgress[index] = record.differentiationProgress
        energy[index] = record.energy
        oxygenStress[index] = record.oxygenStress
        glucoseStress[index] = record.glucoseStress
        damage[index] = record.damage
        expressionProfiles[index] = record.expressionProfile
        flags[index] = record.flags
        regulatoryState.replaceSubrange((index * 32)..<(index * 32 + 32), with: record.regulatoryState)
    }

    public mutating func markDead(at index: Int) {
        guard indicesValid(index) else { return }
        phases[index] = NTCellCyclePhase.dead.rawValue
        flags[index] |= 1
    }

    public func validate() -> [NTDiagnostic] {
        let scalarCounts: [Int] = [
            lineages.count, tileIDs.count, kinds.count, phases.count, fidelities.count,
            positions.count, velocities.count, radii.count, orientations.count, ages.count,
            cycleProgress.count, differentiationProgress.count, energy.count,
            oxygenStress.count, glucoseStress.count, damage.count,
            expressionProfiles.count, flags.count
        ]
        var diagnostics: [NTDiagnostic] = []
        if scalarCounts.contains(where: { $0 != count }) || regulatoryState.count != count * 32 {
            diagnostics.append(.init(
                severity: .fatal,
                code: .invalidReference,
                message: "Cell structure-of-arrays lengths are inconsistent."
            ))
            return diagnostics
        }
        for index in ids.indices {
            let position = positions[index]
            let radius = radii[index]
            let scalars = [position.x, position.y, position.z, radius.x, radius.y, radius.z,
                           ages[index], energy[index], oxygenStress[index], glucoseStress[index], damage[index]]
            if scalars.contains(where: { !$0.isFinite }) {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .nonFiniteState,
                    message: "Cell contains a non-finite value.",
                    entity: ids[index].rawValue,
                    tile: tileIDs[index]
                ))
            }
            if min(radius.x, min(radius.y, radius.z)) <= 0 {
                diagnostics.append(.init(
                    severity: .error,
                    code: .invalidCellVolume,
                    message: "Cell radius must be positive.",
                    entity: ids[index].rawValue,
                    tile: tileIDs[index]
                ))
            }
        }
        return diagnostics
    }

    private func indicesValid(_ index: Int) -> Bool { index >= 0 && index < count }
}

public enum NTCompartmentClass: UInt8, Codable, CaseIterable, Sendable {
    case soma
    case basalDendrite
    case apicalDendrite
    case axon
    case axonInitialSegment
    case spineNeck
    case spineHead
    case myelinatedAxon
    case nodeOfRanvier
}

@frozen
public struct NTCompartmentRecord: Codable, Hashable, Sendable {
    public var id: CompartmentID
    public var cell: CellID
    public var tile: TileID
    public var parentIndex: Int32
    public var firstChildIndex: UInt32
    public var childCount: UInt16
    public var level: UInt16
    public var compartmentClass: NTCompartmentClass
    public var mechanismSet: UInt16
    public var positionMicrometers: NTVector3
    public var lengthMicrometers: Float
    public var diameterMicrometers: Float
    public var membraneVoltageMillivolts: Float
    public var capacitanceNanofarads: Float
    public var axialConductanceMicrosiemens: Float
    public var calciumMicromolar: Float
    public var sodiumMillimolar: Float
    public var potassiumMillimolar: Float
    public var injectedCurrentNanoamps: Float
    public var refractoryUntil: TissueTime
    public var flags: UInt32

    public init(
        id: CompartmentID,
        cell: CellID,
        tile: TileID,
        parentIndex: Int32,
        firstChildIndex: UInt32 = 0,
        childCount: UInt16 = 0,
        level: UInt16 = 0,
        compartmentClass: NTCompartmentClass,
        mechanismSet: UInt16,
        positionMicrometers: NTVector3,
        lengthMicrometers: Float,
        diameterMicrometers: Float,
        membraneVoltageMillivolts: Float = -65,
        capacitanceNanofarads: Float,
        axialConductanceMicrosiemens: Float,
        calciumMicromolar: Float = 0.05,
        sodiumMillimolar: Float = 15,
        potassiumMillimolar: Float = 140,
        injectedCurrentNanoamps: Float = 0,
        refractoryUntil: TissueTime = .init(),
        flags: UInt32 = 0
    ) {
        self.id = id
        self.cell = cell
        self.tile = tile
        self.parentIndex = parentIndex
        self.firstChildIndex = firstChildIndex
        self.childCount = childCount
        self.level = level
        self.compartmentClass = compartmentClass
        self.mechanismSet = mechanismSet
        self.positionMicrometers = positionMicrometers
        self.lengthMicrometers = lengthMicrometers
        self.diameterMicrometers = diameterMicrometers
        self.membraneVoltageMillivolts = membraneVoltageMillivolts
        self.capacitanceNanofarads = capacitanceNanofarads
        self.axialConductanceMicrosiemens = axialConductanceMicrosiemens
        self.calciumMicromolar = calciumMicromolar
        self.sodiumMillimolar = sodiumMillimolar
        self.potassiumMillimolar = potassiumMillimolar
        self.injectedCurrentNanoamps = injectedCurrentNanoamps
        self.refractoryUntil = refractoryUntil
        self.flags = flags
    }
}

public struct NTCompartmentPool: Codable, Sendable {
    public private(set) var records: [NTCompartmentRecord] = []
    public private(set) var mechanismStateOffsets: [UInt32] = []
    public private(set) var mechanismStateCounts: [UInt16] = []
    public private(set) var mechanismState: [Float] = []

    public init() {}
    public var count: Int { records.count }

    @discardableResult
    public mutating func append(_ record: NTCompartmentRecord, mechanismState initialState: [Float]) -> Int {
        let index = records.count
        records.append(record)
        mechanismStateOffsets.append(UInt32(mechanismState.count))
        mechanismStateCounts.append(UInt16(clamping: initialState.count))
        mechanismState.append(contentsOf: initialState.prefix(Int(UInt16.max)))
        return index
    }

    public func stateRange(for index: Int) -> Range<Int>? {
        guard records.indices.contains(index) else { return nil }
        let start = Int(mechanismStateOffsets[index])
        let count = Int(mechanismStateCounts[index])
        guard start >= 0, start + count <= mechanismState.count else { return nil }
        return start..<(start + count)
    }

    public mutating func replaceMechanismState(at index: Int, with values: [Float]) throws {
        guard let range = stateRange(for: index), range.count == values.count else {
            throw NTRuntimeError.invalidModel("Mechanism-state width cannot change during a fast transaction.")
        }
        mechanismState.replaceSubrange(range, with: values)
    }

    public func validate(configuration: NTWorldConfiguration) -> [NTDiagnostic] {
        var diagnostics: [NTDiagnostic] = []
        guard records.count == mechanismStateOffsets.count,
              records.count == mechanismStateCounts.count else {
            return [.init(severity: .fatal, code: .invalidReference, message: "Compartment pool metadata lengths differ.")]
        }
        for index in records.indices {
            let record = records[index]
            if stateRange(for: index) == nil {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidReference,
                    message: "Compartment mechanism-state range is invalid.",
                    entity: record.id.rawValue,
                    tile: record.tile
                ))
            }
            let finite = [record.lengthMicrometers, record.diameterMicrometers,
                          record.membraneVoltageMillivolts, record.capacitanceNanofarads,
                          record.axialConductanceMicrosiemens, record.calciumMicromolar,
                          record.sodiumMillimolar, record.potassiumMillimolar].allSatisfy(\.isFinite)
            if !finite {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .nonFiniteState,
                    message: "Compartment contains a non-finite value.",
                    entity: record.id.rawValue,
                    tile: record.tile
                ))
            }
            if record.membraneVoltageMillivolts < configuration.voltageMinimumMillivolts ||
                record.membraneVoltageMillivolts > configuration.voltageMaximumMillivolts {
                diagnostics.append(.init(
                    severity: .error,
                    code: .voltageOutsideBounds,
                    message: "Compartment voltage is outside configured safety bounds.",
                    entity: record.id.rawValue,
                    tile: record.tile
                ))
            }
            if record.parentIndex >= Int32(records.count) || record.parentIndex == Int32(index) {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidMorphology,
                    message: "Compartment parent reference is invalid.",
                    entity: record.id.rawValue,
                    tile: record.tile
                ))
            }
        }
        return diagnostics
    }
}

public enum NTSynapseReceptor: UInt8, Codable, CaseIterable, Sendable {
    case ampa
    case nmda
    case gabaA
    case gabaB
    case electrical
    case modulatory
}

@frozen
public struct NTSynapseRecord: Codable, Hashable, Sendable {
    public var id: SynapseID
    public var preCompartmentIndex: UInt32
    public var postCompartmentIndex: UInt32
    public var route: RouteID
    public var receptor: NTSynapseReceptor
    public var delayTicks: UInt32
    public var weightMicrosiemens: Float
    public var conductanceMicrosiemens: Float
    public var shortTermU: Float
    public var shortTermX: Float
    public var preTrace: Float
    public var postTrace: Float
    public var eligibility: Float
    public var consolidation: Float
    public var structuralScore: Float
    public var lastEvent: TissueTime
    public var flags: UInt32

    public init(
        id: SynapseID,
        preCompartmentIndex: UInt32,
        postCompartmentIndex: UInt32,
        route: RouteID,
        receptor: NTSynapseReceptor,
        delayTicks: UInt32,
        weightMicrosiemens: Float,
        conductanceMicrosiemens: Float = 0,
        shortTermU: Float = 0.2,
        shortTermX: Float = 1,
        preTrace: Float = 0,
        postTrace: Float = 0,
        eligibility: Float = 0,
        consolidation: Float = 0,
        structuralScore: Float = 1,
        lastEvent: TissueTime = .init(),
        flags: UInt32 = 0
    ) {
        self.id = id
        self.preCompartmentIndex = preCompartmentIndex
        self.postCompartmentIndex = postCompartmentIndex
        self.route = route
        self.receptor = receptor
        self.delayTicks = delayTicks
        self.weightMicrosiemens = weightMicrosiemens
        self.conductanceMicrosiemens = conductanceMicrosiemens
        self.shortTermU = shortTermU
        self.shortTermX = shortTermX
        self.preTrace = preTrace
        self.postTrace = postTrace
        self.eligibility = eligibility
        self.consolidation = consolidation
        self.structuralScore = structuralScore
        self.lastEvent = lastEvent
        self.flags = flags
    }
}

public struct NTSynapsePool: Codable, Sendable {
    public private(set) var records: [NTSynapseRecord] = []
    public private(set) var incomingOffsets: [UInt32] = []
    public private(set) var incomingIndices: [UInt32] = []
    public private(set) var outgoingOffsets: [UInt32] = []
    public private(set) var outgoingIndices: [UInt32] = []

    public init() {}
    public var count: Int { records.count }

    @discardableResult
    public mutating func append(_ record: NTSynapseRecord) -> Int {
        records.append(record)
        return records.count - 1
    }

    public mutating func rebuildAdjacency(compartmentCount: Int) throws {
        var incoming = Array(repeating: [UInt32](), count: compartmentCount)
        var outgoing = Array(repeating: [UInt32](), count: compartmentCount)
        for (index, record) in records.enumerated() {
            guard Int(record.preCompartmentIndex) < compartmentCount,
                  Int(record.postCompartmentIndex) < compartmentCount else {
                throw NTRuntimeError.invalidModel("Synapse references an absent compartment.")
            }
            incoming[Int(record.postCompartmentIndex)].append(UInt32(index))
            outgoing[Int(record.preCompartmentIndex)].append(UInt32(index))
        }
        incomingOffsets = [0]
        outgoingOffsets = [0]
        incomingIndices.removeAll(keepingCapacity: true)
        outgoingIndices.removeAll(keepingCapacity: true)
        for list in incoming {
            incomingIndices.append(contentsOf: list.sorted())
            incomingOffsets.append(UInt32(incomingIndices.count))
        }
        for list in outgoing {
            outgoingIndices.append(contentsOf: list.sorted())
            outgoingOffsets.append(UInt32(outgoingIndices.count))
        }
    }

    public func incomingRange(compartmentIndex: Int) -> Range<Int>? {
        guard compartmentIndex >= 0, compartmentIndex + 1 < incomingOffsets.count else { return nil }
        return Int(incomingOffsets[compartmentIndex])..<Int(incomingOffsets[compartmentIndex + 1])
    }

    public func outgoingRange(compartmentIndex: Int) -> Range<Int>? {
        guard compartmentIndex >= 0, compartmentIndex + 1 < outgoingOffsets.count else { return nil }
        return Int(outgoingOffsets[compartmentIndex])..<Int(outgoingOffsets[compartmentIndex + 1])
    }
}

@frozen
public struct NTTileMembership: Codable, Hashable, Sendable {
    public var id: TileID
    public var coordinate: TileCoordinate
    public var fidelity: NTFidelityLevel
    public var cellIndices: [UInt32]
    public var compartmentIndices: [UInt32]
    public var synapseIndices: [UInt32]
    public var microdomainIndices: [UInt32]
    public var neighborTileIndices: [Int32]
    public var activityScore: Float
    public var uncertaintyScore: Float
    public var injuryScore: Float
    public var lastFidelityChange: TissueTime
    public var flags: UInt32

    public init(
        id: TileID,
        coordinate: TileCoordinate,
        fidelity: NTFidelityLevel = .cellAgent,
        cellIndices: [UInt32] = [],
        compartmentIndices: [UInt32] = [],
        synapseIndices: [UInt32] = [],
        microdomainIndices: [UInt32] = [],
        neighborTileIndices: [Int32] = Array(repeating: -1, count: 26),
        activityScore: Float = 0,
        uncertaintyScore: Float = 0,
        injuryScore: Float = 0,
        lastFidelityChange: TissueTime = .init(),
        flags: UInt32 = 0
    ) {
        self.id = id
        self.coordinate = coordinate
        self.fidelity = fidelity
        self.cellIndices = cellIndices
        self.compartmentIndices = compartmentIndices
        self.synapseIndices = synapseIndices
        self.microdomainIndices = microdomainIndices
        self.neighborTileIndices = neighborTileIndices
        self.activityScore = activityScore
        self.uncertaintyScore = uncertaintyScore
        self.injuryScore = injuryScore
        self.lastFidelityChange = lastFidelityChange
        self.flags = flags
    }
}

@frozen
public struct NTFieldBrickState: Codable, Hashable, Sendable {
    public var tile: TileID
    public var resolution: UInt16
    public var speciesCount: UInt16
    public var concentrations: [Float]
    public var sources: [Float]

    public init(tile: TileID, resolution: Int, speciesCount: Int, initialConcentrations: [Float]) throws {
        guard resolution > 1, speciesCount > 0, initialConcentrations.count == speciesCount else {
            throw NTRuntimeError.invalidModel("Invalid field brick dimensions or initial concentration vector.")
        }
        let voxelCount = resolution * resolution * resolution
        self.tile = tile
        self.resolution = UInt16(clamping: resolution)
        self.speciesCount = UInt16(clamping: speciesCount)
        self.concentrations = []
        self.concentrations.reserveCapacity(voxelCount * speciesCount)
        for _ in 0..<voxelCount { self.concentrations.append(contentsOf: initialConcentrations) }
        self.sources = Array(repeating: 0, count: voxelCount * speciesCount)
    }

    public var voxelCount: Int {
        let value = Int(resolution)
        return value * value * value
    }

    @inlinable
    public func linearIndex(x: Int, y: Int, z: Int, species: Int) -> Int {
        ((((z * Int(resolution)) + y) * Int(resolution)) + x) * Int(speciesCount) + species
    }

    public func validate() -> [NTDiagnostic] {
        let expected = voxelCount * Int(speciesCount)
        guard concentrations.count == expected, sources.count == expected else {
            return [.init(
                severity: .fatal,
                code: .invalidReference,
                message: "Field brick storage length is inconsistent.",
                tile: tile
            )]
        }
        if concentrations.contains(where: { !$0.isFinite }) || sources.contains(where: { !$0.isFinite }) {
            return [.init(
                severity: .fatal,
                code: .nonFiniteState,
                message: "Field brick contains a non-finite value.",
                tile: tile
            )]
        }
        if concentrations.contains(where: { $0 < 0 }) {
            return [.init(
                severity: .error,
                code: .concentrationBelowZero,
                message: "Field brick contains a negative concentration.",
                tile: tile
            )]
        }
        return []
    }
}

public enum NTMicrodomainSolverKind: UInt8, Codable, CaseIterable, Sendable {
    case exactSSA
    case tauLeaping
    case deterministicODE
    case reactionDiffusion
}

@frozen
public struct NTMicrodomainState: Codable, Hashable, Sendable {
    public var id: MicrodomainID
    public var ownerCell: CellID
    public var ownerCompartment: CompartmentID?
    public var tile: TileID
    public var networkIndex: UInt32
    public var solver: NTMicrodomainSolverKind
    public var speciesAmounts: [Float]
    public var volumeFemtoliters: Float
    public var temperatureKelvin: Float
    public var accumulatedPropensity: Float
    public var nextEvent: TissueTime
    public var flags: UInt32

    public init(
        id: MicrodomainID,
        ownerCell: CellID,
        ownerCompartment: CompartmentID? = nil,
        tile: TileID,
        networkIndex: UInt32,
        solver: NTMicrodomainSolverKind,
        speciesAmounts: [Float],
        volumeFemtoliters: Float,
        temperatureKelvin: Float = 310.15,
        accumulatedPropensity: Float = 0,
        nextEvent: TissueTime = .init(),
        flags: UInt32 = 0
    ) {
        self.id = id
        self.ownerCell = ownerCell
        self.ownerCompartment = ownerCompartment
        self.tile = tile
        self.networkIndex = networkIndex
        self.solver = solver
        self.speciesAmounts = speciesAmounts
        self.volumeFemtoliters = volumeFemtoliters
        self.temperatureKelvin = temperatureKelvin
        self.accumulatedPropensity = accumulatedPropensity
        self.nextEvent = nextEvent
        self.flags = flags
    }
}

@frozen
public struct NTLineageEvent: Codable, Hashable, Sendable {
    public enum Kind: UInt8, Codable, Sendable { case created, divided, differentiated, migrated, apoptotic, removed }
    public var time: TissueTime
    public var kind: Kind
    public var cell: CellID
    public var parent: CellID?
    public var fromTile: TileID?
    public var toTile: TileID?
    public var stateCode: UInt32

    public init(time: TissueTime, kind: Kind, cell: CellID, parent: CellID? = nil, fromTile: TileID? = nil, toTile: TileID? = nil, stateCode: UInt32 = 0) {
        self.time = time
        self.kind = kind
        self.cell = cell
        self.parent = parent
        self.fromTile = fromTile
        self.toTile = toTile
        self.stateCode = stateCode
    }
}

// MARK: - Complete authoritative snapshot

@frozen
public struct NTWorldSnapshot: Codable, Sendable {
    public var schemaVersion: UInt32
    public var gpuABIVersion: UInt32
    public var configuration: NTWorldConfiguration
    public var time: TissueTime
    public var nextTransactionRawValue: UInt64
    public var cells: NTCellPool
    public var compartments: NTCompartmentPool
    public var synapses: NTSynapsePool
    public var tiles: [NTTileMembership]
    public var fields: [NTFieldBrickState]
    public var microdomains: [NTMicrodomainState]
    public var lineage: [NTLineageEvent]
    public var modelFingerprint: String
    public var metadata: [String: String]

    public init(
        configuration: NTWorldConfiguration,
        time: TissueTime = .init(),
        nextTransactionRawValue: UInt64 = 1,
        cells: NTCellPool = .init(),
        compartments: NTCompartmentPool = .init(),
        synapses: NTSynapsePool = .init(),
        tiles: [NTTileMembership] = [],
        fields: [NTFieldBrickState] = [],
        microdomains: [NTMicrodomainState] = [],
        lineage: [NTLineageEvent] = [],
        modelFingerprint: String = "",
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = NumiTissueBuild.snapshotSchemaVersion
        self.gpuABIVersion = NumiTissueBuild.gpuABIVersion
        self.configuration = configuration
        self.time = time
        self.nextTransactionRawValue = nextTransactionRawValue
        self.cells = cells
        self.compartments = compartments
        self.synapses = synapses
        self.tiles = tiles
        self.fields = fields
        self.microdomains = microdomains
        self.lineage = lineage
        self.modelFingerprint = modelFingerprint
        self.metadata = metadata
    }

    public func validate() -> [NTDiagnostic] {
        var diagnostics: [NTDiagnostic] = []
        if schemaVersion != NumiTissueBuild.snapshotSchemaVersion {
            diagnostics.append(.init(
                severity: .fatal,
                code: .unsupportedFeature,
                message: "Snapshot schema \(schemaVersion) is incompatible with runtime schema \(NumiTissueBuild.snapshotSchemaVersion)."
            ))
        }
        if gpuABIVersion != NumiTissueBuild.gpuABIVersion {
            diagnostics.append(.init(
                severity: .fatal,
                code: .unsupportedFeature,
                message: "Snapshot GPU ABI \(gpuABIVersion) is incompatible with runtime ABI \(NumiTissueBuild.gpuABIVersion)."
            ))
        }
        diagnostics.append(contentsOf: cells.validate())
        diagnostics.append(contentsOf: compartments.validate(configuration: configuration))
        for field in fields { diagnostics.append(contentsOf: field.validate()) }

        let tileIDs = Set(tiles.map(\.id))
        if tileIDs.count != tiles.count {
            diagnostics.append(.init(severity: .fatal, code: .invalidReference, message: "Duplicate tile identifiers exist."))
        }
        if tiles.count > configuration.resourceBudget.maximumTiles {
            diagnostics.append(.init(severity: .fatal, code: .resourceBudgetExceeded, message: "Tile count exceeds the configured budget."))
        }
        for tile in tiles {
            if tile.cellIndices.count > configuration.resourceBudget.maximumCellsPerTile ||
                tile.compartmentIndices.count > configuration.resourceBudget.maximumCompartmentsPerTile ||
                tile.synapseIndices.count > configuration.resourceBudget.maximumExplicitSynapsesPerTile ||
                tile.microdomainIndices.count > configuration.resourceBudget.maximumMicrodomainsPerTile {
                diagnostics.append(.init(
                    severity: .error,
                    code: .resourceBudgetExceeded,
                    message: "Tile membership exceeds one or more per-tile capacities.",
                    tile: tile.id
                ))
            }
        }
        return diagnostics
    }
}

public extension UInt16 {
    init(clamping value: Int) {
        self = value < 0 ? 0 : value > Int(UInt16.max) ? UInt16.max : UInt16(value)
    }
}
