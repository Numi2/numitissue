import Foundation

/// Stable host/device ABI. All records use scalar or four-lane SIMD fields so Swift and MSL agree
/// on alignment across Apple GPU families. Variable-length biological state lives in flat arenas.
public enum NTMetalABI {
    public static let version: UInt32 = 1
    public static let invalidIndex: UInt32 = .max
    public static let maximumFieldSpecies: UInt32 = 12
    public static let maximumMechanismStatesPerCompartment: UInt32 = 16
    public static let threadExecutionWidthFallback: UInt32 = 32

    public static func validateHostLayouts() throws {
        let required: [(String, Int, Int)] = [
            ("NTMetalWorldConstants", MemoryLayout<NTMetalWorldConstants>.stride, 16),
            ("NTMetalTileHeader", MemoryLayout<NTMetalTileHeader>.stride, 16),
            ("NTMetalCompartment", MemoryLayout<NTMetalCompartment>.stride, 16),
            ("NTMetalSynapse", MemoryLayout<NTMetalSynapse>.stride, 16),
            ("NTMetalEvent", MemoryLayout<NTMetalEvent>.stride, 16),
            ("NTMetalRoute", MemoryLayout<NTMetalRoute>.stride, 16),
            ("NTMetalFieldSpecies", MemoryLayout<NTMetalFieldSpecies>.stride, 16),
            ("NTMetalMicrodomain", MemoryLayout<NTMetalMicrodomain>.stride, 16),
            ("NTMetalValidationCounters", MemoryLayout<NTMetalValidationCounters>.stride, 16)
        ]
        for (name, stride, alignment) in required where stride.isMultiple(of: alignment) == false {
            throw NTRuntimeError.internalInvariant("\(name) stride \(stride) is not a multiple of \(alignment).")
        }
    }
}

@frozen
public struct NTMetalWorldConstants: Sendable {
    public var abiAndFlags: SIMD4<UInt32>
    public var counts0: SIMD4<UInt32>
    public var counts1: SIMD4<UInt32>
    public var clock0: SIMD4<UInt32>
    public var clock1: SIMD4<UInt32>
    public var geometry: SIMD4<Float>
    public var voltageAndTolerance: SIMD4<Float>
    public var seed: SIMD4<UInt32>

    public init(
        configuration: NTWorldConfiguration,
        tileCount: Int,
        cellCount: Int,
        compartmentCount: Int,
        synapseCount: Int,
        routeCount: Int,
        microdomainCount: Int,
        eventCapacity: Int,
        time: TissueTime,
        transaction: TransactionID,
        flags: UInt32 = 0
    ) {
        abiAndFlags = SIMD4(NTMetalABI.version, flags, UInt32(configuration.fieldResolution), 0)
        counts0 = SIMD4(
            UInt32(clamping: tileCount),
            UInt32(clamping: cellCount),
            UInt32(clamping: compartmentCount),
            UInt32(clamping: synapseCount)
        )
        counts1 = SIMD4(
            UInt32(clamping: routeCount),
            UInt32(clamping: microdomainCount),
            UInt32(clamping: eventCapacity),
            NTMetalABI.maximumFieldSpecies
        )
        clock0 = SIMD4(
            UInt32(truncatingIfNeeded: time.tick),
            UInt32(truncatingIfNeeded: time.tick >> 32),
            UInt32(clamping: Int(configuration.fastQuantumTicks)),
            UInt32(clamping: Int(configuration.communicationBlockTicks))
        )
        clock1 = SIMD4(
            UInt32(truncatingIfNeeded: transaction.rawValue),
            UInt32(truncatingIfNeeded: transaction.rawValue >> 32),
            UInt32(clamping: Int(configuration.transactionTicks)),
            UInt32(TissueTime.quantumMicroseconds)
        )
        geometry = SIMD4(
            configuration.tileEdgeMicrometers,
            configuration.tileEdgeMicrometers / Float(configuration.fieldResolution),
            configuration.originMicrometers.x,
            configuration.originMicrometers.y
        )
        voltageAndTolerance = SIMD4(
            configuration.voltageMinimumMillivolts,
            configuration.voltageMaximumMillivolts,
            configuration.fieldMassRelativeTolerance,
            configuration.maximumCellOverlapFraction
        )
        seed = SIMD4(
            UInt32(truncatingIfNeeded: configuration.seed),
            UInt32(truncatingIfNeeded: configuration.seed >> 32),
            UInt32(bitPattern: configuration.originMicrometers.z.bitPattern),
            0
        )
    }
}

@frozen
public struct NTMetalTileHeader: Sendable {
    public var id: SIMD2<UInt32>
    public var coordinateAndFidelity: SIMD4<Int32>
    public var cellRange: SIMD2<UInt32>
    public var compartmentRange: SIMD2<UInt32>
    public var synapseRange: SIMD2<UInt32>
    public var microdomainRange: SIMD2<UInt32>
    public var fieldAndFlags: SIMD4<UInt32>
    public var scores: SIMD4<Float>

    public init(
        membership: NTTileMembership,
        cellStart: UInt32,
        compartmentStart: UInt32,
        synapseStart: UInt32,
        microdomainStart: UInt32,
        fieldBrickIndex: Int32
    ) {
        id = SIMD2(UInt32(truncatingIfNeeded: membership.id.rawValue), UInt32(truncatingIfNeeded: membership.id.rawValue >> 32))
        coordinateAndFidelity = SIMD4(
            membership.coordinate.x,
            membership.coordinate.y,
            membership.coordinate.z,
            Int32(membership.fidelity.rawValue)
        )
        cellRange = SIMD2(cellStart, UInt32(clamping: membership.cellIndices.count))
        compartmentRange = SIMD2(compartmentStart, UInt32(clamping: membership.compartmentIndices.count))
        synapseRange = SIMD2(synapseStart, UInt32(clamping: membership.synapseIndices.count))
        microdomainRange = SIMD2(microdomainStart, UInt32(clamping: membership.microdomainIndices.count))
        fieldAndFlags = SIMD4(UInt32(bitPattern: fieldBrickIndex), membership.flags, 0, 0)
        scores = SIMD4(membership.activityScore, membership.uncertaintyScore, membership.injuryScore, 0)
    }
}

@frozen
public struct NTMetalCell: Sendable {
    public var id: SIMD2<UInt32>
    public var lineage: SIMD2<UInt32>
    public var tileAndClass: SIMD4<UInt32>
    public var positionAndAge: SIMD4<Float>
    public var velocityAndCycle: SIMD4<Float>
    public var radiiAndDifferentiation: SIMD4<Float>
    public var orientationAndEnergy: SIMD4<Float>
    public var stressDamageFlags: SIMD4<Float>
    public var expressionAndFlags: SIMD4<UInt32>

    public init(_ source: NTProductionCell, tileIndex: UInt32) {
        let record = source.record
        id = SIMD2(UInt32(truncatingIfNeeded: record.id.rawValue), UInt32(truncatingIfNeeded: record.id.rawValue >> 32))
        lineage = SIMD2(UInt32(truncatingIfNeeded: record.lineage.rawValue), UInt32(truncatingIfNeeded: record.lineage.rawValue >> 32))
        tileAndClass = SIMD4(tileIndex, UInt32(record.kind.rawValue), UInt32(record.phase.rawValue), UInt32(record.fidelity.rawValue))
        positionAndAge = SIMD4(record.positionMicrometers.x, record.positionMicrometers.y, record.positionMicrometers.z, record.ageSeconds)
        velocityAndCycle = SIMD4(record.velocityMicrometersPerSecond.x, record.velocityMicrometersPerSecond.y, record.velocityMicrometersPerSecond.z, record.cycleProgress)
        radiiAndDifferentiation = SIMD4(record.radiiMicrometers.x, record.radiiMicrometers.y, record.radiiMicrometers.z, record.differentiationProgress)
        orientationAndEnergy = SIMD4(record.orientation.x, record.orientation.y, record.orientation.z, record.energy)
        stressDamageFlags = SIMD4(record.oxygenStress, record.glucoseStress, record.damage, Float(bitPattern: record.flags))
        expressionAndFlags = SIMD4(record.expressionProfile, source.lastStructuralUpdate.tick > UInt64(UInt32.max) ? UInt32.max : UInt32(source.lastStructuralUpdate.tick), 0, 0)
    }
}

@frozen
public struct NTMetalCompartment: Sendable {
    public var id: SIMD2<UInt32>
    public var cell: SIMD2<UInt32>
    public var topology: SIMD4<UInt32>
    public var positionAndLength: SIMD4<Float>
    public var geometryAndVoltage: SIMD4<Float>
    public var ions0: SIMD4<Float>
    public var current0: SIMD4<Float>
    public var conductance0: SIMD4<Float>
    public var spikeState: SIMD4<UInt32>
    public var gates0: SIMD4<Float>
    public var gates1: SIMD4<Float>
    public var gates2: SIMD4<Float>

    public init(_ source: NTProductionCompartment, tileIndex: UInt32) {
        let record = source.record
        id = SIMD2(UInt32(truncatingIfNeeded: record.id.rawValue), UInt32(truncatingIfNeeded: record.id.rawValue >> 32))
        cell = SIMD2(UInt32(truncatingIfNeeded: record.cell.rawValue), UInt32(truncatingIfNeeded: record.cell.rawValue >> 32))
        topology = SIMD4(
            record.parentIndex < 0 ? NTMetalABI.invalidIndex : UInt32(record.parentIndex),
            UInt32(record.firstChildIndex),
            UInt32(record.childCount) | (UInt32(record.level) << 16),
            tileIndex | (UInt32(record.compartmentClass.rawValue) << 20) | (UInt32(record.mechanismSet) << 24)
        )
        positionAndLength = SIMD4(record.positionMicrometers.x, record.positionMicrometers.y, record.positionMicrometers.z, record.lengthMicrometers)
        geometryAndVoltage = SIMD4(record.diameterMicrometers, record.capacitanceNanofarads, record.axialConductanceMicrosiemens, record.membraneVoltageMillivolts)
        ions0 = SIMD4(record.calciumMicromolar, record.sodiumMillimolar, record.potassiumMillimolar, source.extracellularPotentialMillivolts)
        current0 = SIMD4(record.injectedCurrentNanoamps, source.synapticCurrentNanoamps, source.ionicCurrentNanoamps, source.calciumFluxMicromolarPerSecond)
        conductance0 = SIMD4(source.synapticConductanceExcitatory, source.synapticConductanceInhibitory, source.energyCostPicojoules, source.previousVoltageMillivolts)
        spikeState = SIMD4(
            UInt32(truncatingIfNeeded: record.refractoryUntil.tick),
            UInt32(truncatingIfNeeded: record.refractoryUntil.tick >> 32),
            source.spikeCountWindow,
            record.flags
        )
        gates0 = SIMD4(source.gates.sodiumActivation, source.gates.sodiumInactivation, source.gates.potassiumActivation, source.gates.calciumLActivation)
        gates1 = SIMD4(source.gates.calciumLInactivation, source.gates.calciumTActivation, source.gates.calciumTInactivation, source.gates.hcnActivation)
        gates2 = SIMD4(source.gates.mActivation, source.gates.calciumActivatedPotassium, source.gates.optogeneticOpen, source.gates.reserve0)
    }
}

@frozen
public struct NTMetalSynapse: Sendable {
    public var id: SIMD2<UInt32>
    public var topology: SIMD4<UInt32>
    public var kinetics0: SIMD4<Float>
    public var kinetics1: SIMD4<Float>
    public var plasticity0: SIMD4<Float>
    public var plasticity1: SIMD4<Float>
    public var lastEventAndFlags: SIMD4<UInt32>

    public init(_ source: NTProductionSynapse) {
        let record = source.record
        id = SIMD2(UInt32(truncatingIfNeeded: record.id.rawValue), UInt32(truncatingIfNeeded: record.id.rawValue >> 32))
        topology = SIMD4(
            record.preCompartmentIndex,
            record.postCompartmentIndex,
            record.delayTicks,
            UInt32(record.receptor.rawValue) | (record.flags << 8)
        )
        kinetics0 = SIMD4(record.weightMicrosiemens, record.conductanceMicrosiemens, source.riseState, source.decayState)
        kinetics1 = SIMD4(record.shortTermU, record.shortTermX, source.releaseProbability, source.vesiclePool)
        plasticity0 = SIMD4(record.preTrace, record.postTrace, record.eligibility, record.consolidation)
        plasticity1 = SIMD4(record.structuralScore, source.postTraceFast, source.postTraceSlow, source.homeostaticTargetHertz)
        lastEventAndFlags = SIMD4(
            UInt32(truncatingIfNeeded: record.lastEvent.tick),
            UInt32(truncatingIfNeeded: record.lastEvent.tick >> 32),
            source.pendingDeletion ? 1 : 0,
            0
        )
    }
}

@frozen
public struct NTMetalEvent: Sendable {
    public var deliveryTick: SIMD2<UInt32>
    public var source: SIMD2<UInt32>
    public var destination: SIMD2<UInt32>
    public var route: SIMD2<UInt32>
    public var payload: SIMD4<Float>
    public var kindAndSequence: SIMD4<UInt32>

    public init(_ event: NTNeuralEvent) {
        deliveryTick = SIMD2(UInt32(truncatingIfNeeded: event.deliveryTime.tick), UInt32(truncatingIfNeeded: event.deliveryTime.tick >> 32))
        source = SIMD2(UInt32(truncatingIfNeeded: event.source), UInt32(truncatingIfNeeded: event.source >> 32))
        destination = SIMD2(UInt32(truncatingIfNeeded: event.destination), UInt32(truncatingIfNeeded: event.destination >> 32))
        route = SIMD2(UInt32(truncatingIfNeeded: event.route.rawValue), UInt32(truncatingIfNeeded: event.route.rawValue >> 32))
        payload = SIMD4(event.payload0, event.payload1, 0, 0)
        kindAndSequence = SIMD4(
            UInt32(event.kind.rawValue),
            UInt32(truncatingIfNeeded: event.sequence),
            UInt32(truncatingIfNeeded: event.sequence >> 32),
            0
        )
    }
}

@frozen
public struct NTMetalRoute: Sendable {
    public var id: SIMD2<UInt32>
    public var topology: SIMD4<UInt32>
    public var dynamics: SIMD4<Float>
    public var destinationTile: SIMD2<UInt32>
    public var reserved: SIMD2<UInt32>

    public init(_ route: NTRouteRecord) {
        id = SIMD2(UInt32(truncatingIfNeeded: route.id.rawValue), UInt32(truncatingIfNeeded: route.id.rawValue >> 32))
        topology = SIMD4(route.sourceCompartmentIndex, route.destinationSynapseStart, route.destinationSynapseCount, route.delayTicks)
        dynamics = SIMD4(route.failureProbability, route.amplitudeScale, Float(bitPattern: route.flags), 0)
        destinationTile = SIMD2(UInt32(truncatingIfNeeded: route.destinationTile.rawValue), UInt32(truncatingIfNeeded: route.destinationTile.rawValue >> 32))
        reserved = .zero
    }
}

@frozen
public struct NTMetalFieldSpecies: Sendable {
    public var diffusionDecay: SIMD4<Float>
    public var boundsBoundary: SIMD4<Float>
    public var identityAndFlags: SIMD4<UInt32>

    public init(_ parameter: NTFieldSpeciesParameters) {
        let boundaryKind: UInt32
        let boundaryTarget: Float
        let boundaryExchange: Float
        switch parameter.boundary {
        case .noFlux:
            boundaryKind = 0
            boundaryTarget = 0
            boundaryExchange = 0
        case let .fixed(value):
            boundaryKind = 1
            boundaryTarget = value
            boundaryExchange = 0
        case let .perfused(target, exchange):
            boundaryKind = 2
            boundaryTarget = target
            boundaryExchange = exchange
        }
        diffusionDecay = SIMD4(parameter.diffusionSquareMicrometersPerSecond, parameter.decayPerSecond, boundaryTarget, boundaryExchange)
        boundsBoundary = SIMD4(parameter.minimum, parameter.maximum, 0, 0)
        identityAndFlags = SIMD4(UInt32(parameter.species.rawValue), boundaryKind, 0, 0)
    }
}

@frozen
public struct NTMetalMicrodomain: Sendable {
    public var id: SIMD2<UInt32>
    public var ownerCell: SIMD2<UInt32>
    public var ownerCompartment: SIMD2<UInt32>
    public var tileAndNetwork: SIMD4<UInt32>
    public var ranges: SIMD4<UInt32>
    public var physical: SIMD4<Float>
    public var nextEvent: SIMD2<UInt32>
    public var reserved: SIMD2<UInt32>

    public init(_ source: NTMicrodomainState, speciesStart: UInt32, tileIndex: UInt32) {
        id = SIMD2(UInt32(truncatingIfNeeded: source.id.rawValue), UInt32(truncatingIfNeeded: source.id.rawValue >> 32))
        ownerCell = SIMD2(UInt32(truncatingIfNeeded: source.ownerCell.rawValue), UInt32(truncatingIfNeeded: source.ownerCell.rawValue >> 32))
        let compartment = source.ownerCompartment?.rawValue ?? UInt64.max
        ownerCompartment = SIMD2(UInt32(truncatingIfNeeded: compartment), UInt32(truncatingIfNeeded: compartment >> 32))
        tileAndNetwork = SIMD4(tileIndex, source.networkIndex, UInt32(source.solver.rawValue), source.flags)
        ranges = SIMD4(speciesStart, UInt32(clamping: source.speciesAmounts.count), 0, 0)
        physical = SIMD4(source.volumeFemtoliters, source.temperatureKelvin, source.accumulatedPropensity, 0)
        nextEvent = SIMD2(UInt32(truncatingIfNeeded: source.nextEvent.tick), UInt32(truncatingIfNeeded: source.nextEvent.tick >> 32))
        reserved = .zero
    }
}

@frozen
public struct NTMetalDispatchArguments: Sendable {
    public var threadgroupsPerGrid: SIMD3<UInt32>
    public var padding: UInt32

    public init(x: UInt32 = 0, y: UInt32 = 1, z: UInt32 = 1) {
        threadgroupsPerGrid = SIMD3(x, y, z)
        padding = 0
    }
}

@frozen
public struct NTMetalValidationCounters: Sendable {
    public var fatalAndErrorCounts: SIMD4<UInt32>
    public var boundsCounts: SIMD4<UInt32>
    public var eventCounts: SIMD4<UInt32>
    public var floatingPointCounts: SIMD4<UInt32>
    public var extrema0: SIMD4<Float>
    public var extrema1: SIMD4<Float>

    public init() {
        fatalAndErrorCounts = .zero
        boundsCounts = .zero
        eventCounts = .zero
        floatingPointCounts = .zero
        extrema0 = SIMD4(.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        extrema1 = .zero
    }
}

public enum NTMetalBufferSlot: Int, CaseIterable, Sendable {
    case constants = 0
    case tileHeaders = 1
    case tileCells = 2
    case tileCompartments = 3
    case tileSynapses = 4
    case tileMicrodomains = 5
    case cells = 6
    case regulatoryState = 7
    case compartments = 8
    case synapses = 9
    case routes = 10
    case routeDestinations = 11
    case events = 12
    case eventCounters = 13
    case fieldRead = 14
    case fieldWrite = 15
    case fieldSources = 16
    case fieldSpecies = 17
    case microdomains = 18
    case molecularSpecies = 19
    case activeTiles = 20
    case activeCompartments = 21
    case activeSynapses = 22
    case activeMicrodomains = 23
    case hinesLevels = 24
    case hinesIndices = 25
    case matrixDiagonal = 26
    case matrixRHS = 27
    case dispatchArguments = 28
    case validation = 29
    case outputSpikes = 30
    case outputCounters = 31
}

public enum NTMetalKernel: String, CaseIterable, Sendable {
    case clearTransaction = "nt_clear_transaction"
    case buildActiveWorklists = "nt_build_active_worklists"
    case decaySynapses = "nt_decay_synapses"
    case deliverEvents = "nt_deliver_events"
    case updateGatesAndAssemble = "nt_update_gates_and_assemble"
    case hinesEliminate = "nt_hines_eliminate"
    case hinesSubstitute = "nt_hines_substitute"
    case detectSpikes = "nt_detect_spikes"
    case routeSpikes = "nt_route_spikes"
    case updatePlasticity = "nt_update_plasticity"
    case diffuseFields = "nt_diffuse_fields"
    case applyFieldSources = "nt_apply_field_sources"
    case updateMetabolism = "nt_update_metabolism"
    case molecularPropensities = "nt_molecular_propensities"
    case molecularTauLeap = "nt_molecular_tau_leap"
    case molecularODE = "nt_molecular_ode"
    case cellForces = "nt_cell_forces"
    case integrateCells = "nt_integrate_cells"
    case scoreFidelity = "nt_score_fidelity"
    case validateState = "nt_validate_state"
    case summarize = "nt_summarize"
}
