import Foundation
import NumiTissueCore

public extension RuntimeSegmentState {
    init(
        id: SegmentID,
        cellIndex: UInt32,
        parentSegmentIndex: UInt32 = RuntimeSegmentState.invalidIndex,
        firstChildIndex: UInt32 = RuntimeSegmentState.invalidIndex,
        nextSiblingIndex: UInt32 = RuntimeSegmentState.invalidIndex,
        compartmentIndex: UInt32 = RuntimeCompartmentState.invalidIndex,
        type: UInt16,
        flags: UInt16 = 0,
        start: Float4,
        end: Float4,
        radiusMicrometers: Float,
        myelinFraction: Float = 0,
        growthRateMicrometersPerSecond: Float = 0,
        structuralScore: Float = 0
    ) {
        self.id = id
        self.cellIndex = cellIndex
        self.parentSegmentIndex = parentSegmentIndex
        self.firstChildIndex = firstChildIndex
        self.nextSiblingIndex = nextSiblingIndex
        self.compartmentIndex = compartmentIndex
        self.type = type
        self.flags = flags
        self.start = start
        self.end = end
        self.radiusMicrometers = radiusMicrometers
        self.myelinFraction = myelinFraction
        self.growthRateMicrometersPerSecond = growthRateMicrometersPerSecond
        self.structuralScore = structuralScore
    }
}

public extension RuntimeCompartmentState {
    init(
        id: CompartmentID,
        neuronIndex: UInt32,
        parentIndex: UInt32 = RuntimeCompartmentState.invalidIndex,
        mechanismRange: RuntimeRange = RuntimeRange(),
        synapseRange: RuntimeRange = RuntimeRange(),
        voltageMillivolts: Float = -65,
        previousVoltageMillivolts: Float = -65,
        capacitanceNanofarads: Float,
        axialConductanceMicrosiemens: Float = 0,
        injectedCurrentNanoamps: Float = 0,
        synapticCurrentNanoamps: Float = 0,
        intracellularCalciumMicromolar: Float = 0.05,
        intracellularSodiumMillimolar: Float = 12,
        intracellularPotassiumMillimolar: Float = 140,
        refractoryUntilTick: UInt64 = 0,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.neuronIndex = neuronIndex
        self.parentIndex = parentIndex
        self.mechanismRange = mechanismRange
        self.synapseRange = synapseRange
        self.voltageMillivolts = voltageMillivolts
        self.previousVoltageMillivolts = previousVoltageMillivolts
        self.capacitanceNanofarads = capacitanceNanofarads
        self.axialConductanceMicrosiemens = axialConductanceMicrosiemens
        self.injectedCurrentNanoamps = injectedCurrentNanoamps
        self.synapticCurrentNanoamps = synapticCurrentNanoamps
        self.intracellularCalciumMicromolar = intracellularCalciumMicromolar
        self.intracellularSodiumMillimolar = intracellularSodiumMillimolar
        self.intracellularPotassiumMillimolar = intracellularPotassiumMillimolar
        self.refractoryUntilTick = refractoryUntilTick
        self.flags = flags
    }
}

public extension RuntimeSynapseState {
    init(
        id: SynapseID,
        sourceRouteIndex: UInt32,
        targetCompartmentIndex: UInt32,
        parameterIndex: UInt16,
        flags: UInt16 = 0,
        delayTicks: UInt32,
        weight: Float,
        conductance: Float = 0,
        shortTermUtilization: Float = 0.2,
        shortTermResources: Float = 1,
        preTrace: Float = 0,
        postTrace: Float = 0,
        eligibility: Float = 0,
        consolidation: Float = 0,
        structuralScore: Float = 0.5,
        lastEventTick: UInt64 = 0
    ) {
        self.id = id
        self.sourceRouteIndex = sourceRouteIndex
        self.targetCompartmentIndex = targetCompartmentIndex
        self.parameterIndex = parameterIndex
        self.flags = flags
        self.delayTicks = delayTicks
        self.weight = weight
        self.conductance = conductance
        self.shortTermUtilization = shortTermUtilization
        self.shortTermResources = shortTermResources
        self.preTrace = preTrace
        self.postTrace = postTrace
        self.eligibility = eligibility
        self.consolidation = consolidation
        self.structuralScore = structuralScore
        self.lastEventTick = lastEventTick
    }
}

public extension RuntimeMicrodomainState {
    init(
        id: MicrodomainID,
        ownerCellIndex: UInt32,
        ownerCompartmentIndex: UInt32 = RuntimeMicrodomainState.invalidIndex,
        reactionNetworkIndex: UInt16,
        solverKind: UInt8,
        flags: UInt8 = 0,
        speciesRange: RuntimeRange,
        volumeFemtoliters: Float,
        temperatureKelvin: Float = 310.15,
        nextEventTick: UInt64 = 0,
        propensitySum: Float = 0
    ) {
        self.id = id
        self.ownerCellIndex = ownerCellIndex
        self.ownerCompartmentIndex = ownerCompartmentIndex
        self.reactionNetworkIndex = reactionNetworkIndex
        self.solverKind = solverKind
        self.flags = flags
        self.speciesRange = speciesRange
        self.volumeFemtoliters = volumeFemtoliters
        self.temperatureKelvin = temperatureKelvin
        self.nextEventTick = nextEventTick
        self.propensitySum = propensitySum
    }
}
