#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

/// Stable host/shader ABI. Every structure contains only fixed-width scalars and SIMD vectors.
/// Layout changes require a gpuABIVersion increment and an explicit snapshot migration.
public enum MetalTissueABI {
    public static let version: UInt32 = 1
    public static let alignment = 256
    public static let invalidIndex = UInt32.max

    public static func validateHostLayout() throws {
        let aligned16: [(String, Int)] = [
            ("MetalSimulationHeader", MemoryLayout<MetalSimulationHeader>.stride),
            ("MetalTileState", MemoryLayout<MetalTileState>.stride),
            ("MetalCellState", MemoryLayout<MetalCellState>.stride),
            ("MetalSegmentState", MemoryLayout<MetalSegmentState>.stride),
            ("MetalCompartmentState", MemoryLayout<MetalCompartmentState>.stride),
            ("MetalSynapseState", MemoryLayout<MetalSynapseState>.stride),
            ("MetalEvent", MemoryLayout<MetalEvent>.stride),
            ("MetalFieldState", MemoryLayout<MetalFieldState>.stride),
            ("MetalMicrodomainState", MemoryLayout<MetalMicrodomainState>.stride)
        ]
        for (name, stride) in aligned16 where stride % 16 != 0 {
            throw MetalRuntimeError.incompatibleGPU("Host ABI stride for \(name) is \(stride), expected a multiple of 16")
        }
    }
}

@frozen
public struct MetalSimulationHeader: Sendable {
    public var abiVersion: UInt32
    public var flags: UInt32
    public var transactionLo: UInt32
    public var transactionHi: UInt32
    public var startTickLo: UInt32
    public var startTickHi: UInt32
    public var endTickLo: UInt32
    public var endTickHi: UInt32
    public var epochLo: UInt32
    public var epochHi: UInt32
    public var randomSeedLo: UInt32
    public var randomSeedHi: UInt32
    public var tileCount: UInt32
    public var cellCount: UInt32
    public var segmentCount: UInt32
    public var compartmentCount: UInt32
    public var synapseCount: UInt32
    public var fieldValueCount: UInt32
    public var microdomainCount: UInt32
    public var molecularSpeciesCount: UInt32
    public var eventCapacity: UInt32
    public var fieldChannels: UInt32
    public var fieldGridWidth: UInt32
    public var fieldGridHeight: UInt32
    public var fieldGridDepth: UInt32
    public var fastQuantumTicks: UInt32
    public var routingBlockTicks: UInt32
    public var transactionTicks: UInt32
    public var phase: UInt32
    public var phaseStartTickLo: UInt32
    public var phaseStartTickHi: UInt32
    public var phaseEndTickLo: UInt32
    public var phaseEndTickHi: UInt32
    public var dtMilliseconds: Float
    public var inverseDtMilliseconds: Float
    public var temperatureKelvin: Float
    public var reservedFloat: Float
    public var reserved0: SIMD4<UInt32>
    public var reserved1: SIMD4<UInt32>
    public var reserved2: SIMD4<UInt32>
    public var reserved3: SIMD4<UInt32>

    public init(state: TissueRuntimeState, context: ExecutionContext, phase: RuntimePhase = .ingestInputs, phaseRange: Range<UInt64>? = nil) {
        let range = phaseRange ?? context.startTime.tick..<context.endTime.tick
        abiVersion = MetalTissueABI.version
        flags = 0
        transactionLo = UInt32(truncatingIfNeeded: context.transaction.rawValue)
        transactionHi = UInt32(truncatingIfNeeded: context.transaction.rawValue >> 32)
        startTickLo = UInt32(truncatingIfNeeded: context.startTime.tick)
        startTickHi = UInt32(truncatingIfNeeded: context.startTime.tick >> 32)
        endTickLo = UInt32(truncatingIfNeeded: context.endTime.tick)
        endTickHi = UInt32(truncatingIfNeeded: context.endTime.tick >> 32)
        epochLo = UInt32(truncatingIfNeeded: context.epoch)
        epochHi = UInt32(truncatingIfNeeded: context.epoch >> 32)
        randomSeedLo = UInt32(truncatingIfNeeded: context.randomSeed)
        randomSeedHi = UInt32(truncatingIfNeeded: context.randomSeed >> 32)
        tileCount = UInt32(clamping: state.tiles.count)
        cellCount = UInt32(clamping: state.cells.count)
        segmentCount = UInt32(clamping: state.segments.count)
        compartmentCount = UInt32(clamping: state.compartments.count)
        synapseCount = UInt32(clamping: state.synapses.count)
        fieldValueCount = UInt32(clamping: state.fields.count)
        microdomainCount = UInt32(clamping: state.microdomains.count)
        molecularSpeciesCount = UInt32(clamping: state.molecularSpecies.count)
        eventCapacity = UInt32(clamping: state.capacity.events)
        fieldChannels = 12
        fieldGridWidth = 32
        fieldGridHeight = 32
        fieldGridDepth = 32
        fastQuantumTicks = UInt32(clamping: context.cadence.fastQuantumTicks)
        routingBlockTicks = UInt32(clamping: context.cadence.routingBlockTicks)
        transactionTicks = UInt32(clamping: context.cadence.transactionTicks)
        self.phase = UInt32(phase.rawValue)
        phaseStartTickLo = UInt32(truncatingIfNeeded: range.lowerBound)
        phaseStartTickHi = UInt32(truncatingIfNeeded: range.lowerBound >> 32)
        phaseEndTickLo = UInt32(truncatingIfNeeded: range.upperBound)
        phaseEndTickHi = UInt32(truncatingIfNeeded: range.upperBound >> 32)
        dtMilliseconds = Float(context.cadence.fastQuantumTicks) * 0.025
        inverseDtMilliseconds = dtMilliseconds > 0 ? 1 / dtMilliseconds : 0
        temperatureKelvin = 310.15
        reservedFloat = 0
        reserved0 = .zero
        reserved1 = .zero
        reserved2 = .zero
        reserved3 = .zero
    }
}

@frozen
public struct MetalRange: Sendable {
    public var lowerBound: UInt32
    public var count: UInt32
    public var reserved0: UInt32
    public var reserved1: UInt32

    public init(_ range: RuntimeRange) {
        lowerBound = range.lowerBound
        count = range.count
        reserved0 = 0
        reserved1 = 0
    }
}

@frozen
public struct MetalTileState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var flags: UInt32
    public var fidelityMask: UInt32
    public var coordinate: SIMD4<Int32>
    public var cellRange: MetalRange
    public var segmentRange: MetalRange
    public var compartmentRange: MetalRange
    public var synapseRange: MetalRange
    public var fieldRange: MetalRange
    public var microdomainRange: MetalRange
    public var lastActiveTickLo: UInt32
    public var lastActiveTickHi: UInt32
    public var reservedTick0: UInt32
    public var reservedTick1: UInt32
    public var scores: SIMD4<Float> // activity, uncertainty, damage, metabolic stress

    public init(_ state: TileRuntimeState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        flags = state.flags
        fidelityMask = state.fidelityMask
        coordinate = state.coordinate.packed
        cellRange = MetalRange(state.cellRange)
        segmentRange = MetalRange(state.segmentRange)
        compartmentRange = MetalRange(state.compartmentRange)
        synapseRange = MetalRange(state.synapseRange)
        fieldRange = MetalRange(state.fieldRange)
        microdomainRange = MetalRange(state.microdomainRange)
        lastActiveTickLo = UInt32(truncatingIfNeeded: state.lastActiveTick)
        lastActiveTickHi = UInt32(truncatingIfNeeded: state.lastActiveTick >> 32)
        reservedTick0 = 0
        reservedTick1 = 0
        scores = SIMD4(state.activityScore, state.uncertaintyScore, state.damageScore, state.metabolicStress)
    }
}

@frozen
public struct MetalCellState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var lineageLo: UInt32
    public var lineageHi: UInt32
    public var tileIndex: UInt32
    public var typeAndDevelopment: UInt32
    public var fidelityAndFlags: UInt32
    public var reservedIndex: UInt32
    public var position: SIMD4<Float>
    public var orientation: SIMD4<Float>
    public var semiAxes: SIMD4<Float>
    public var velocity: SIMD4<Float>
    public var ageCycleDifferentiationEnergy: SIMD4<Float>
    public var stressDamageHazard: SIMD4<Float>
    public var regulatoryRange: MetalRange

    public init(_ state: RuntimeCellState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        lineageLo = UInt32(truncatingIfNeeded: state.lineage.rawValue)
        lineageHi = UInt32(truncatingIfNeeded: state.lineage.rawValue >> 32)
        tileIndex = state.tileIndex
        typeAndDevelopment = UInt32(state.typeIndex) | (UInt32(state.developmentalState) << 16)
        fidelityAndFlags = UInt32(state.fidelity.rawValue) | (UInt32(state.flags) << 8)
        reservedIndex = 0
        position = state.position
        orientation = state.orientation
        semiAxes = state.semiAxes
        velocity = state.velocity
        ageCycleDifferentiationEnergy = SIMD4(state.ageSeconds, state.cycleProgress, state.differentiationProgress, state.energyReserve)
        stressDamageHazard = SIMD4(state.oxygenStress, state.glucoseStress, state.damage, state.apoptosisHazard)
        regulatoryRange = MetalRange(state.regulatoryRange)
    }
}

@frozen
public struct MetalSegmentState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var cellIndex: UInt32
    public var parentSegmentIndex: UInt32
    public var firstChildIndex: UInt32
    public var nextSiblingIndex: UInt32
    public var compartmentIndex: UInt32
    public var typeAndFlags: UInt32
    public var start: SIMD4<Float>
    public var end: SIMD4<Float>
    public var radiusMyelinGrowthScore: SIMD4<Float>

    public init(_ state: RuntimeSegmentState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        cellIndex = state.cellIndex
        parentSegmentIndex = state.parentSegmentIndex
        firstChildIndex = state.firstChildIndex
        nextSiblingIndex = state.nextSiblingIndex
        compartmentIndex = state.compartmentIndex
        typeAndFlags = UInt32(state.type) | (UInt32(state.flags) << 16)
        start = state.start
        end = state.end
        radiusMyelinGrowthScore = SIMD4(state.radiusMicrometers, state.myelinFraction, state.growthRateMicrometersPerSecond, state.structuralScore)
    }
}

@frozen
public struct MetalCompartmentState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var neuronIndex: UInt32
    public var parentIndex: UInt32
    public var mechanismRange: MetalRange
    public var synapseRange: MetalRange
    public var voltagePreviousCapacitanceAxial: SIMD4<Float>
    public var injectedSynapticCalciumSodium: SIMD4<Float>
    public var potassiumReserved: SIMD4<Float>
    public var refractoryTickLo: UInt32
    public var refractoryTickHi: UInt32
    public var flags: UInt32
    public var reserved: UInt32

    public init(_ state: RuntimeCompartmentState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        neuronIndex = state.neuronIndex
        parentIndex = state.parentIndex
        mechanismRange = MetalRange(state.mechanismRange)
        synapseRange = MetalRange(state.synapseRange)
        voltagePreviousCapacitanceAxial = SIMD4(state.voltageMillivolts, state.previousVoltageMillivolts, state.capacitanceNanofarads, state.axialConductanceMicrosiemens)
        injectedSynapticCalciumSodium = SIMD4(state.injectedCurrentNanoamps, state.synapticCurrentNanoamps, state.intracellularCalciumMicromolar, state.intracellularSodiumMillimolar)
        potassiumReserved = SIMD4(state.intracellularPotassiumMillimolar, 0, 0, 0)
        refractoryTickLo = UInt32(truncatingIfNeeded: state.refractoryUntilTick)
        refractoryTickHi = UInt32(truncatingIfNeeded: state.refractoryUntilTick >> 32)
        flags = state.flags
        reserved = 0
    }
}

@frozen
public struct MetalSynapseState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var sourceRouteIndex: UInt32
    public var targetCompartmentIndex: UInt32
    public var parameterAndFlags: UInt32
    public var delayTicks: UInt32
    public var lastEventTickLo: UInt32
    public var lastEventTickHi: UInt32
    public var weightConductanceUtilizationResources: SIMD4<Float>
    public var prePostEligibilityConsolidation: SIMD4<Float>
    public var structuralReserved: SIMD4<Float>

    public init(_ state: RuntimeSynapseState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        sourceRouteIndex = state.sourceRouteIndex
        targetCompartmentIndex = state.targetCompartmentIndex
        parameterAndFlags = UInt32(state.parameterIndex) | (UInt32(state.flags) << 16)
        delayTicks = state.delayTicks
        lastEventTickLo = UInt32(truncatingIfNeeded: state.lastEventTick)
        lastEventTickHi = UInt32(truncatingIfNeeded: state.lastEventTick >> 32)
        weightConductanceUtilizationResources = SIMD4(state.weight, state.conductance, state.shortTermUtilization, state.shortTermResources)
        prePostEligibilityConsolidation = SIMD4(state.preTrace, state.postTrace, state.eligibility, state.consolidation)
        structuralReserved = SIMD4(state.structuralScore, 0, 0, 0)
    }
}

@frozen
public struct MetalEvent: Sendable {
    public var arrivalTickLo: UInt32
    public var arrivalTickHi: UInt32
    public var sourceLo: UInt32
    public var sourceHi: UInt32
    public var destinationLo: UInt32
    public var destinationHi: UInt32
    public var kindAndFlags: UInt32
    public var sequence: UInt32
    public var amplitude: Float
    public var reserved0: Float
    public var reserved1: Float
    public var reserved2: Float

    public init(
        arrivalTickLo: UInt32,
        arrivalTickHi: UInt32,
        sourceLo: UInt32,
        sourceHi: UInt32,
        destinationLo: UInt32,
        destinationHi: UInt32,
        kindAndFlags: UInt32,
        sequence: UInt32,
        amplitude: Float,
        payload0: Float = 0,
        payload1: Float = 0,
        payload2: Float = 0
    ) {
        self.arrivalTickLo = arrivalTickLo
        self.arrivalTickHi = arrivalTickHi
        self.sourceLo = sourceLo
        self.sourceHi = sourceHi
        self.destinationLo = destinationLo
        self.destinationHi = destinationHi
        self.kindAndFlags = kindAndFlags
        self.sequence = sequence
        self.amplitude = amplitude
        self.reserved0 = payload0
        self.reserved1 = payload1
        self.reserved2 = payload2
    }

    public var payload0: Float {
        get { reserved0 }
        set { reserved0 = newValue }
    }

    public var payload1: Float {
        get { reserved1 }
        set { reserved1 = newValue }
    }

    public var payload2: Float {
        get { reserved2 }
        set { reserved2 = newValue }
    }

    public init(_ event: RoutedEvent) {
        arrivalTickLo = UInt32(truncatingIfNeeded: event.arrivalTick)
        arrivalTickHi = UInt32(truncatingIfNeeded: event.arrivalTick >> 32)
        sourceLo = UInt32(truncatingIfNeeded: event.source)
        sourceHi = UInt32(truncatingIfNeeded: event.source >> 32)
        destinationLo = UInt32(truncatingIfNeeded: event.destination)
        destinationHi = UInt32(truncatingIfNeeded: event.destination >> 32)
        kindAndFlags = UInt32(event.kind.rawValue) | (UInt32(event.flags) << 16)
        sequence = event.sequence
        amplitude = event.amplitude
        reserved0 = 0
        reserved1 = 0
        reserved2 = 0
    }
}

@frozen
public struct MetalFieldState: Sendable {
    public var concentrationSourceSinkDiffusion: SIMD4<Float>
    public init(_ value: RuntimeFieldValue) {
        concentrationSourceSinkDiffusion = SIMD4(value.concentration, value.source, value.sink, value.diffusionScale)
    }
}

@frozen
public struct MetalMicrodomainState: Sendable {
    public var idLo: UInt32
    public var idHi: UInt32
    public var ownerCellIndex: UInt32
    public var ownerCompartmentIndex: UInt32
    public var reactionSolverFlags: UInt32
    public var reservedIndex: UInt32
    public var speciesRange: MetalRange
    public var volumeTemperaturePropensityReserved: SIMD4<Float>
    public var nextEventTickLo: UInt32
    public var nextEventTickHi: UInt32
    public var reserved0: UInt32
    public var reserved1: UInt32

    public init(_ state: RuntimeMicrodomainState) {
        idLo = UInt32(truncatingIfNeeded: state.id.rawValue)
        idHi = UInt32(truncatingIfNeeded: state.id.rawValue >> 32)
        ownerCellIndex = state.ownerCellIndex
        ownerCompartmentIndex = state.ownerCompartmentIndex
        reactionSolverFlags = UInt32(state.reactionNetworkIndex) | (UInt32(state.solverKind) << 16) | (UInt32(state.flags) << 24)
        reservedIndex = 0
        speciesRange = MetalRange(state.speciesRange)
        volumeTemperaturePropensityReserved = SIMD4(state.volumeFemtoliters, state.temperatureKelvin, state.propensitySum, 0)
        nextEventTickLo = UInt32(truncatingIfNeeded: state.nextEventTick)
        nextEventTickHi = UInt32(truncatingIfNeeded: state.nextEventTick >> 32)
        reserved0 = 0
        reserved1 = 0
    }
}

@frozen
public struct MetalValidationRecord: Sendable {
    public var code: UInt32
    public var severity: UInt32
    public var entityLo: UInt32
    public var entityHi: UInt32
    public var value: Float
    public var index: UInt32
    public var reserved0: UInt32
    public var reserved1: UInt32

    public init() {
        code = 0
        severity = 0
        entityLo = 0
        entityHi = 0
        value = 0
        index = 0
        reserved0 = 0
        reserved1 = 0
    }
}

@frozen
public struct MetalRuntimeCounters: Sendable {
    public var activeTiles: UInt32
    public var activeCompartments: UInt32
    public var promotedEntities: UInt32
    public var demotedEntities: UInt32
    public var deliveredEventsLo: UInt32
    public var deliveredEventsHi: UInt32
    public var generatedSpikesLo: UInt32
    public var generatedSpikesHi: UInt32
    public var routedEventsLo: UInt32
    public var routedEventsHi: UInt32
    public var molecularFiringsLo: UInt32
    public var molecularFiringsHi: UInt32
    public var structuralMutations: UInt32
    public var rejectedMutations: UInt32
    public var numericalSubsteps: UInt32
    public var validationCount: UInt32

    public init() {
        activeTiles = 0
        activeCompartments = 0
        promotedEntities = 0
        demotedEntities = 0
        deliveredEventsLo = 0
        deliveredEventsHi = 0
        generatedSpikesLo = 0
        generatedSpikesHi = 0
        routedEventsLo = 0
        routedEventsHi = 0
        molecularFiringsLo = 0
        molecularFiringsHi = 0
        structuralMutations = 0
        rejectedMutations = 0
        numericalSubsteps = 0
        validationCount = 0
    }

    public func runtimeCounters() -> RuntimeCounters {
        var result = RuntimeCounters()
        result.activeTiles = activeTiles
        result.activeCompartments = activeCompartments
        result.promotedEntities = promotedEntities
        result.demotedEntities = demotedEntities
        result.deliveredEvents = UInt64(deliveredEventsLo) | (UInt64(deliveredEventsHi) << 32)
        result.generatedSpikes = UInt64(generatedSpikesLo) | (UInt64(generatedSpikesHi) << 32)
        result.routedEvents = UInt64(routedEventsLo) | (UInt64(routedEventsHi) << 32)
        result.molecularFirings = UInt64(molecularFiringsLo) | (UInt64(molecularFiringsHi) << 32)
        result.structuralMutations = structuralMutations
        result.rejectedMutations = rejectedMutations
        result.numericalSubsteps = numericalSubsteps
        return result
    }
}

public enum MetalBufferKind: String, Sendable, CaseIterable {
    case header
    case tiles
    case cells
    case regulatoryState
    case segments
    case compartments
    case mechanismState
    case synapses
    case fields
    case microdomains
    case molecularSpecies
    case incomingEvents
    case localEvents
    case outgoingEvents
    case eventBucketCounts
    case worklistCounts
    case electricalWorklist
    case fieldWorklist
    case molecularWorklist
    case mechanicsWorklist
    case developmentWorklist
    case fidelityWorklist
    case validationRecords
    case runtimeCounters
    case outputEvents
    case outputScalars
    case indirectDispatch
}
#endif
