import Foundation
import NumiTissueCore

public enum RuntimeDifferenceKind: String, Sendable, Codable {
    case count
    case exact
    case floatingPoint
    case eventOrdering
}

public struct RuntimeStateDifference: Sendable, Codable {
    public var domain: RuntimeComparisonDomain
    public var kind: RuntimeDifferenceKind
    public var path: String
    public var index: Int?
    public var referenceValue: String
    public var candidateValue: String
    public var absoluteError: Float?
    public var relativeError: Float?
    public var ulpDistance: UInt64?

    public init(
        domain: RuntimeComparisonDomain,
        kind: RuntimeDifferenceKind,
        path: String,
        index: Int? = nil,
        referenceValue: String,
        candidateValue: String,
        absoluteError: Float? = nil,
        relativeError: Float? = nil,
        ulpDistance: UInt64? = nil
    ) {
        self.domain = domain
        self.kind = kind
        self.path = path
        self.index = index
        self.referenceValue = referenceValue
        self.candidateValue = candidateValue
        self.absoluteError = absoluteError
        self.relativeError = relativeError
        self.ulpDistance = ulpDistance
    }
}

public struct RuntimeDomainComparisonSummary: Sendable, Codable {
    public var domain: RuntimeComparisonDomain
    public var comparedValues: Int
    public var exactMismatches: Int
    public var floatingPointMismatches: Int
    public var maximumAbsoluteError: Float
    public var maximumRelativeError: Float
    public var maximumULPDistance: UInt64

    public init(domain: RuntimeComparisonDomain) {
        self.domain = domain
        self.comparedValues = 0
        self.exactMismatches = 0
        self.floatingPointMismatches = 0
        self.maximumAbsoluteError = 0
        self.maximumRelativeError = 0
        self.maximumULPDistance = 0
    }

    public var passed: Bool {
        exactMismatches == 0 && floatingPointMismatches == 0
    }
}

public struct RuntimeStateComparisonReport: Sendable, Codable {
    public var contractIdentifier: String
    public var referenceBackend: String
    public var candidateBackend: String
    public var phase: RuntimePhase
    public var tickRange: Range<UInt64>
    public var referenceDigest: RuntimeComparisonDigest
    public var candidateDigest: RuntimeComparisonDigest
    public var digestMatched: Bool
    public var domainSummaries: [RuntimeDomainComparisonSummary]
    public var differences: [RuntimeStateDifference]
    public var omittedDifferenceCount: Int

    public init(
        contractIdentifier: String,
        referenceBackend: String,
        candidateBackend: String,
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        referenceDigest: RuntimeComparisonDigest,
        candidateDigest: RuntimeComparisonDigest,
        digestMatched: Bool,
        domainSummaries: [RuntimeDomainComparisonSummary],
        differences: [RuntimeStateDifference],
        omittedDifferenceCount: Int
    ) {
        self.contractIdentifier = contractIdentifier
        self.referenceBackend = referenceBackend
        self.candidateBackend = candidateBackend
        self.phase = phase
        self.tickRange = tickRange
        self.referenceDigest = referenceDigest
        self.candidateDigest = candidateDigest
        self.digestMatched = digestMatched
        self.domainSummaries = domainSummaries
        self.differences = differences
        self.omittedDifferenceCount = omittedDifferenceCount
    }

    public var passed: Bool {
        domainSummaries.allSatisfy(\.passed)
    }

    public var mismatchCount: Int {
        domainSummaries.reduce(0) {
            $0 + $1.exactMismatches + $1.floatingPointMismatches
        }
    }
}

public struct RuntimeOutputComparisonReport: Sendable, Codable {
    public var contractIdentifier: String
    public var referenceBackend: String
    public var candidateBackend: String
    public var summaries: [RuntimeDomainComparisonSummary]
    public var differences: [RuntimeStateDifference]
    public var omittedDifferenceCount: Int

    public init(
        contractIdentifier: String,
        referenceBackend: String,
        candidateBackend: String,
        summaries: [RuntimeDomainComparisonSummary],
        differences: [RuntimeStateDifference],
        omittedDifferenceCount: Int
    ) {
        self.contractIdentifier = contractIdentifier
        self.referenceBackend = referenceBackend
        self.candidateBackend = candidateBackend
        self.summaries = summaries
        self.differences = differences
        self.omittedDifferenceCount = omittedDifferenceCount
    }

    public var passed: Bool { summaries.allSatisfy(\.passed) }
}

public enum RuntimeStateComparator {
    public static func compare(
        reference lhs: RuntimeShadowInspection,
        candidate rhs: RuntimeShadowInspection,
        contract: RuntimeDeterminismContract
    ) -> RuntimeStateComparisonReport {
        var accumulator = RuntimeComparisonAccumulator(contract: contract)
        compareMetadata(lhs.state, rhs.state, accumulator: &accumulator)
        compareTiles(lhs.state.tiles, rhs.state.tiles, accumulator: &accumulator)
        compareCells(lhs.state.cells, rhs.state.cells, accumulator: &accumulator)
        compareFloatArray(
            lhs.state.regulatoryState,
            rhs.state.regulatoryState,
            domain: .regulatoryState,
            path: "regulatoryState",
            accumulator: &accumulator
        )
        compareSegments(lhs.state.segments, rhs.state.segments, accumulator: &accumulator)
        compareCompartments(lhs.state.compartments, rhs.state.compartments, accumulator: &accumulator)
        compareFloatArray(
            lhs.state.mechanismState,
            rhs.state.mechanismState,
            domain: .mechanismState,
            path: "mechanismState",
            accumulator: &accumulator
        )
        compareSynapses(lhs.state.synapses, rhs.state.synapses, accumulator: &accumulator)
        compareFields(lhs.state.fields, rhs.state.fields, accumulator: &accumulator)
        compareMicrodomains(lhs.state.microdomains, rhs.state.microdomains, accumulator: &accumulator)
        compareFloatArray(
            lhs.state.molecularSpecies,
            rhs.state.molecularSpecies,
            domain: .molecularSpecies,
            path: "molecularSpecies",
            accumulator: &accumulator
        )
        comparePendingEvents(
            lhs.pendingEvents,
            rhs.pendingEvents,
            accumulator: &accumulator
        )
        if contract.requireExactCounters {
            compareCounters(lhs.counters, rhs.counters, accumulator: &accumulator)
        }

        let referenceDigest = lhs.digestSnapshot.poolDigests.combined
        let candidateDigest = rhs.digestSnapshot.poolDigests.combined
        return RuntimeStateComparisonReport(
            contractIdentifier: contract.identifier,
            referenceBackend: lhs.backendName,
            candidateBackend: rhs.backendName,
            phase: lhs.phase,
            tickRange: lhs.tickRange,
            referenceDigest: referenceDigest,
            candidateDigest: candidateDigest,
            digestMatched: referenceDigest == candidateDigest,
            domainSummaries: accumulator.orderedSummaries,
            differences: accumulator.differences,
            omittedDifferenceCount: accumulator.omittedDifferenceCount
        )
    }

    public static func compareOutputs(
        reference lhs: RuntimeOutputFrame,
        candidate rhs: RuntimeOutputFrame,
        referenceBackend: String,
        candidateBackend: String,
        contract: RuntimeDeterminismContract
    ) -> RuntimeOutputComparisonReport {
        var accumulator = RuntimeComparisonAccumulator(contract: contract)
        accumulator.exact(lhs.startTime.tick, rhs.startTime.tick, domain: .output, path: "startTime.tick")
        accumulator.exact(lhs.endTime.tick, rhs.endTime.tick, domain: .output, path: "endTime.tick")
        compareRoutedEvents(
            lhs.efferentEvents,
            rhs.efferentEvents,
            path: "efferentEvents",
            accumulator: &accumulator
        )
        compareFloatArray(
            lhs.populationActivity,
            rhs.populationActivity,
            domain: .output,
            path: "populationActivity",
            accumulator: &accumulator
        )
        compareFloatArray(
            lhs.localFieldPotentials,
            rhs.localFieldPotentials,
            domain: .output,
            path: "localFieldPotentials",
            accumulator: &accumulator
        )
        compareFloatArray(
            lhs.metabolicDemand,
            rhs.metabolicDemand,
            domain: .output,
            path: "metabolicDemand",
            accumulator: &accumulator
        )
        compareRoutedEvents(
            lhs.damageEvents,
            rhs.damageEvents,
            path: "damageEvents",
            accumulator: &accumulator
        )
        accumulator.float(lhs.uncertainty, rhs.uncertainty, domain: .output, path: "uncertainty")
        accumulator.float(lhs.plasticityMagnitude, rhs.plasticityMagnitude, domain: .output, path: "plasticityMagnitude")

        return RuntimeOutputComparisonReport(
            contractIdentifier: contract.identifier,
            referenceBackend: referenceBackend,
            candidateBackend: candidateBackend,
            summaries: accumulator.orderedSummaries,
            differences: accumulator.differences,
            omittedDifferenceCount: accumulator.omittedDifferenceCount
        )
    }

    private static func compareMetadata(
        _ lhs: TissueRuntimeState,
        _ rhs: TissueRuntimeState,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.exact(lhs.time.tick, rhs.time.tick, domain: .metadata, path: "time.tick")
        accumulator.exact(lhs.epoch, rhs.epoch, domain: .metadata, path: "epoch")
        compareCapacity(lhs.capacity, rhs.capacity, prefix: "capacity", accumulator: &accumulator)
    }

    private static func compareCapacity(
        _ lhs: RuntimeCapacity,
        _ rhs: RuntimeCapacity,
        prefix: String,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.exact(lhs.tiles, rhs.tiles, domain: .metadata, path: "\(prefix).tiles")
        accumulator.exact(lhs.cells, rhs.cells, domain: .metadata, path: "\(prefix).cells")
        accumulator.exact(lhs.segments, rhs.segments, domain: .metadata, path: "\(prefix).segments")
        accumulator.exact(lhs.compartments, rhs.compartments, domain: .metadata, path: "\(prefix).compartments")
        accumulator.exact(lhs.synapses, rhs.synapses, domain: .metadata, path: "\(prefix).synapses")
        accumulator.exact(lhs.events, rhs.events, domain: .metadata, path: "\(prefix).events")
        accumulator.exact(lhs.fieldValues, rhs.fieldValues, domain: .metadata, path: "\(prefix).fieldValues")
        accumulator.exact(lhs.microdomains, rhs.microdomains, domain: .metadata, path: "\(prefix).microdomains")
        accumulator.exact(lhs.molecularSpecies, rhs.molecularSpecies, domain: .metadata, path: "\(prefix).molecularSpecies")
    }

    private static func compareRange(
        _ lhs: RuntimeRange,
        _ rhs: RuntimeRange,
        domain: RuntimeComparisonDomain,
        path: String,
        index: Int,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.exact(lhs.lowerBound, rhs.lowerBound, domain: domain, path: "\(path).lowerBound", index: index)
        accumulator.exact(lhs.count, rhs.count, domain: domain, path: "\(path).count", index: index)
    }

    private static func compareVector(
        _ lhs: Float4,
        _ rhs: Float4,
        domain: RuntimeComparisonDomain,
        path: String,
        index: Int,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.float(lhs.x, rhs.x, domain: domain, path: "\(path).x", index: index)
        accumulator.float(lhs.y, rhs.y, domain: domain, path: "\(path).y", index: index)
        accumulator.float(lhs.z, rhs.z, domain: domain, path: "\(path).z", index: index)
        accumulator.float(lhs.w, rhs.w, domain: domain, path: "\(path).w", index: index)
    }

    private static func compareTiles(
        _ lhs: [TileRuntimeState],
        _ rhs: [TileRuntimeState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .tiles, path: "tiles")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .tiles, path: "id", index: index)
                accumulator.exact(left.coordinate, right.coordinate, domain: .tiles, path: "coordinate", index: index)
                accumulator.exact(left.flags, right.flags, domain: .tiles, path: "flags", index: index)
                accumulator.exact(left.fidelityMask, right.fidelityMask, domain: .tiles, path: "fidelityMask", index: index)
                compareRange(left.cellRange, right.cellRange, domain: .tiles, path: "cellRange", index: index, accumulator: &accumulator)
                compareRange(left.segmentRange, right.segmentRange, domain: .tiles, path: "segmentRange", index: index, accumulator: &accumulator)
                compareRange(left.compartmentRange, right.compartmentRange, domain: .tiles, path: "compartmentRange", index: index, accumulator: &accumulator)
                compareRange(left.synapseRange, right.synapseRange, domain: .tiles, path: "synapseRange", index: index, accumulator: &accumulator)
                compareRange(left.fieldRange, right.fieldRange, domain: .tiles, path: "fieldRange", index: index, accumulator: &accumulator)
                compareRange(left.microdomainRange, right.microdomainRange, domain: .tiles, path: "microdomainRange", index: index, accumulator: &accumulator)
            }
            accumulator.exact(left.lastActiveTick, right.lastActiveTick, domain: .tiles, path: "lastActiveTick", index: index)
            accumulator.float(left.activityScore, right.activityScore, domain: .tiles, path: "activityScore", index: index)
            accumulator.float(left.uncertaintyScore, right.uncertaintyScore, domain: .tiles, path: "uncertaintyScore", index: index)
            accumulator.float(left.damageScore, right.damageScore, domain: .tiles, path: "damageScore", index: index)
            accumulator.float(left.metabolicStress, right.metabolicStress, domain: .tiles, path: "metabolicStress", index: index)
        }
    }

    private static func compareCells(
        _ lhs: [RuntimeCellState],
        _ rhs: [RuntimeCellState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .cells, path: "cells")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .cells, path: "id", index: index)
                accumulator.exact(left.lineage, right.lineage, domain: .cells, path: "lineage", index: index)
                accumulator.exact(left.tileIndex, right.tileIndex, domain: .cells, path: "tileIndex", index: index)
                accumulator.exact(left.typeIndex, right.typeIndex, domain: .cells, path: "typeIndex", index: index)
                accumulator.exact(left.developmentalState, right.developmentalState, domain: .cells, path: "developmentalState", index: index)
                accumulator.exact(left.fidelity.rawValue, right.fidelity.rawValue, domain: .cells, path: "fidelity", index: index)
                accumulator.exact(left.flags, right.flags, domain: .cells, path: "flags", index: index)
                compareRange(left.regulatoryRange, right.regulatoryRange, domain: .cells, path: "regulatoryRange", index: index, accumulator: &accumulator)
            }
            compareVector(left.position, right.position, domain: .cells, path: "position", index: index, accumulator: &accumulator)
            compareVector(left.orientation, right.orientation, domain: .cells, path: "orientation", index: index, accumulator: &accumulator)
            compareVector(left.semiAxes, right.semiAxes, domain: .cells, path: "semiAxes", index: index, accumulator: &accumulator)
            compareVector(left.velocity, right.velocity, domain: .cells, path: "velocity", index: index, accumulator: &accumulator)
            accumulator.float(left.ageSeconds, right.ageSeconds, domain: .cells, path: "ageSeconds", index: index)
            accumulator.float(left.cycleProgress, right.cycleProgress, domain: .cells, path: "cycleProgress", index: index)
            accumulator.float(left.differentiationProgress, right.differentiationProgress, domain: .cells, path: "differentiationProgress", index: index)
            accumulator.float(left.energyReserve, right.energyReserve, domain: .cells, path: "energyReserve", index: index)
            accumulator.float(left.oxygenStress, right.oxygenStress, domain: .cells, path: "oxygenStress", index: index)
            accumulator.float(left.glucoseStress, right.glucoseStress, domain: .cells, path: "glucoseStress", index: index)
            accumulator.float(left.damage, right.damage, domain: .cells, path: "damage", index: index)
            accumulator.float(left.apoptosisHazard, right.apoptosisHazard, domain: .cells, path: "apoptosisHazard", index: index)
        }
    }

    private static func compareSegments(
        _ lhs: [RuntimeSegmentState],
        _ rhs: [RuntimeSegmentState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .segments, path: "segments")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .segments, path: "id", index: index)
                accumulator.exact(left.cellIndex, right.cellIndex, domain: .segments, path: "cellIndex", index: index)
                accumulator.exact(left.parentSegmentIndex, right.parentSegmentIndex, domain: .segments, path: "parentSegmentIndex", index: index)
                accumulator.exact(left.firstChildIndex, right.firstChildIndex, domain: .segments, path: "firstChildIndex", index: index)
                accumulator.exact(left.nextSiblingIndex, right.nextSiblingIndex, domain: .segments, path: "nextSiblingIndex", index: index)
                accumulator.exact(left.compartmentIndex, right.compartmentIndex, domain: .segments, path: "compartmentIndex", index: index)
                accumulator.exact(left.type, right.type, domain: .segments, path: "type", index: index)
                accumulator.exact(left.flags, right.flags, domain: .segments, path: "flags", index: index)
            }
            compareVector(left.start, right.start, domain: .segments, path: "start", index: index, accumulator: &accumulator)
            compareVector(left.end, right.end, domain: .segments, path: "end", index: index, accumulator: &accumulator)
            accumulator.float(left.radiusMicrometers, right.radiusMicrometers, domain: .segments, path: "radiusMicrometers", index: index)
            accumulator.float(left.myelinFraction, right.myelinFraction, domain: .segments, path: "myelinFraction", index: index)
            accumulator.float(left.growthRateMicrometersPerSecond, right.growthRateMicrometersPerSecond, domain: .segments, path: "growthRateMicrometersPerSecond", index: index)
            accumulator.float(left.structuralScore, right.structuralScore, domain: .segments, path: "structuralScore", index: index)
        }
    }

    private static func compareCompartments(
        _ lhs: [RuntimeCompartmentState],
        _ rhs: [RuntimeCompartmentState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .compartments, path: "compartments")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .compartments, path: "id", index: index)
                accumulator.exact(left.neuronIndex, right.neuronIndex, domain: .compartments, path: "neuronIndex", index: index)
                accumulator.exact(left.parentIndex, right.parentIndex, domain: .compartments, path: "parentIndex", index: index)
                compareRange(left.mechanismRange, right.mechanismRange, domain: .compartments, path: "mechanismRange", index: index, accumulator: &accumulator)
                compareRange(left.synapseRange, right.synapseRange, domain: .compartments, path: "synapseRange", index: index, accumulator: &accumulator)
                accumulator.exact(left.refractoryUntilTick, right.refractoryUntilTick, domain: .compartments, path: "refractoryUntilTick", index: index)
                accumulator.exact(left.flags, right.flags, domain: .compartments, path: "flags", index: index)
            }
            accumulator.float(left.voltageMillivolts, right.voltageMillivolts, domain: .compartments, path: "voltageMillivolts", index: index)
            accumulator.float(left.previousVoltageMillivolts, right.previousVoltageMillivolts, domain: .compartments, path: "previousVoltageMillivolts", index: index)
            accumulator.float(left.capacitanceNanofarads, right.capacitanceNanofarads, domain: .compartments, path: "capacitanceNanofarads", index: index)
            accumulator.float(left.axialConductanceMicrosiemens, right.axialConductanceMicrosiemens, domain: .compartments, path: "axialConductanceMicrosiemens", index: index)
            accumulator.float(left.injectedCurrentNanoamps, right.injectedCurrentNanoamps, domain: .compartments, path: "injectedCurrentNanoamps", index: index)
            accumulator.float(left.synapticCurrentNanoamps, right.synapticCurrentNanoamps, domain: .compartments, path: "synapticCurrentNanoamps", index: index)
            accumulator.float(left.intracellularCalciumMicromolar, right.intracellularCalciumMicromolar, domain: .compartments, path: "intracellularCalciumMicromolar", index: index)
            accumulator.float(left.intracellularSodiumMillimolar, right.intracellularSodiumMillimolar, domain: .compartments, path: "intracellularSodiumMillimolar", index: index)
            accumulator.float(left.intracellularPotassiumMillimolar, right.intracellularPotassiumMillimolar, domain: .compartments, path: "intracellularPotassiumMillimolar", index: index)
        }
    }

    private static func compareSynapses(
        _ lhs: [RuntimeSynapseState],
        _ rhs: [RuntimeSynapseState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .synapses, path: "synapses")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .synapses, path: "id", index: index)
                accumulator.exact(left.sourceRouteIndex, right.sourceRouteIndex, domain: .synapses, path: "sourceRouteIndex", index: index)
                accumulator.exact(left.targetCompartmentIndex, right.targetCompartmentIndex, domain: .synapses, path: "targetCompartmentIndex", index: index)
                accumulator.exact(left.parameterIndex, right.parameterIndex, domain: .synapses, path: "parameterIndex", index: index)
                accumulator.exact(left.flags, right.flags, domain: .synapses, path: "flags", index: index)
                accumulator.exact(left.delayTicks, right.delayTicks, domain: .synapses, path: "delayTicks", index: index)
                accumulator.exact(left.lastEventTick, right.lastEventTick, domain: .synapses, path: "lastEventTick", index: index)
            }
            accumulator.float(left.weight, right.weight, domain: .synapses, path: "weight", index: index)
            accumulator.float(left.conductance, right.conductance, domain: .synapses, path: "conductance", index: index)
            accumulator.float(left.shortTermUtilization, right.shortTermUtilization, domain: .synapses, path: "shortTermUtilization", index: index)
            accumulator.float(left.shortTermResources, right.shortTermResources, domain: .synapses, path: "shortTermResources", index: index)
            accumulator.float(left.preTrace, right.preTrace, domain: .synapses, path: "preTrace", index: index)
            accumulator.float(left.postTrace, right.postTrace, domain: .synapses, path: "postTrace", index: index)
            accumulator.float(left.eligibility, right.eligibility, domain: .synapses, path: "eligibility", index: index)
            accumulator.float(left.consolidation, right.consolidation, domain: .synapses, path: "consolidation", index: index)
            accumulator.float(left.structuralScore, right.structuralScore, domain: .synapses, path: "structuralScore", index: index)
        }
    }

    private static func compareFields(
        _ lhs: [RuntimeFieldValue],
        _ rhs: [RuntimeFieldValue],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .fields, path: "fields")
        for index in 0..<min(lhs.count, rhs.count) {
            accumulator.float(lhs[index].concentration, rhs[index].concentration, domain: .fields, path: "concentration", index: index)
            accumulator.float(lhs[index].source, rhs[index].source, domain: .fields, path: "source", index: index)
            accumulator.float(lhs[index].sink, rhs[index].sink, domain: .fields, path: "sink", index: index)
            accumulator.float(lhs[index].diffusionScale, rhs[index].diffusionScale, domain: .fields, path: "diffusionScale", index: index)
        }
    }

    private static func compareMicrodomains(
        _ lhs: [RuntimeMicrodomainState],
        _ rhs: [RuntimeMicrodomainState],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .microdomains, path: "microdomains")
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            if accumulator.contract.requireExactTopology {
                accumulator.exact(left.id, right.id, domain: .microdomains, path: "id", index: index)
                accumulator.exact(left.ownerCellIndex, right.ownerCellIndex, domain: .microdomains, path: "ownerCellIndex", index: index)
                accumulator.exact(left.ownerCompartmentIndex, right.ownerCompartmentIndex, domain: .microdomains, path: "ownerCompartmentIndex", index: index)
                accumulator.exact(left.reactionNetworkIndex, right.reactionNetworkIndex, domain: .microdomains, path: "reactionNetworkIndex", index: index)
                accumulator.exact(left.solverKind, right.solverKind, domain: .microdomains, path: "solverKind", index: index)
                accumulator.exact(left.flags, right.flags, domain: .microdomains, path: "flags", index: index)
                compareRange(left.speciesRange, right.speciesRange, domain: .microdomains, path: "speciesRange", index: index, accumulator: &accumulator)
                accumulator.exact(left.nextEventTick, right.nextEventTick, domain: .microdomains, path: "nextEventTick", index: index)
            }
            accumulator.float(left.volumeFemtoliters, right.volumeFemtoliters, domain: .microdomains, path: "volumeFemtoliters", index: index)
            accumulator.float(left.temperatureKelvin, right.temperatureKelvin, domain: .microdomains, path: "temperatureKelvin", index: index)
            accumulator.float(left.propensitySum, right.propensitySum, domain: .microdomains, path: "propensitySum", index: index)
        }
    }

    private static func compareFloatArray(
        _ lhs: [Float],
        _ rhs: [Float],
        domain: RuntimeComparisonDomain,
        path: String,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: domain, path: path)
        for index in 0..<min(lhs.count, rhs.count) {
            accumulator.float(lhs[index], rhs[index], domain: domain, path: path, index: index)
        }
    }

    private static func comparePendingEvents(
        _ lhs: [RuntimePendingEvent],
        _ rhs: [RuntimePendingEvent],
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        let leftEvents = lhs.sorted()
        let rightEvents = rhs.sorted()
        accumulator.count(leftEvents.count, rightEvents.count, domain: .pendingEvents, path: "pendingEvents")
        for index in 0..<min(leftEvents.count, rightEvents.count) {
            let left = leftEvents[index]
            let right = rightEvents[index]
            accumulator.exact(left.arrivalTick, right.arrivalTick, domain: .pendingEvents, path: "arrivalTick", index: index)
            accumulator.exact(left.source, right.source, domain: .pendingEvents, path: "source", index: index)
            accumulator.exact(left.target, right.target, domain: .pendingEvents, path: "target", index: index)
            accumulator.exact(left.kind.rawValue, right.kind.rawValue, domain: .pendingEvents, path: "kind", index: index)
            accumulator.exact(left.flags, right.flags, domain: .pendingEvents, path: "flags", index: index)
            if accumulator.contract.requireExactEventOrdering {
                accumulator.exact(left.sequence, right.sequence, domain: .pendingEvents, path: "sequence", index: index, kind: .eventOrdering)
            }
            accumulator.float(left.amplitude, right.amplitude, domain: .pendingEvents, path: "amplitude", index: index)
        }
    }

    private static func compareRoutedEvents(
        _ lhs: [RoutedEvent],
        _ rhs: [RoutedEvent],
        path: String,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.count(lhs.count, rhs.count, domain: .output, path: path)
        for index in 0..<min(lhs.count, rhs.count) {
            let left = lhs[index]
            let right = rhs[index]
            accumulator.exact(left.arrivalTick, right.arrivalTick, domain: .output, path: "\(path).arrivalTick", index: index)
            accumulator.exact(left.source, right.source, domain: .output, path: "\(path).source", index: index)
            accumulator.exact(left.destination, right.destination, domain: .output, path: "\(path).destination", index: index)
            accumulator.exact(left.kind.rawValue, right.kind.rawValue, domain: .output, path: "\(path).kind", index: index)
            accumulator.exact(left.flags, right.flags, domain: .output, path: "\(path).flags", index: index)
            if accumulator.contract.requireExactEventOrdering {
                accumulator.exact(left.sequence, right.sequence, domain: .output, path: "\(path).sequence", index: index, kind: .eventOrdering)
            }
            accumulator.float(left.amplitude, right.amplitude, domain: .output, path: "\(path).amplitude", index: index)
        }
    }

    private static func compareCounters(
        _ lhs: RuntimeCounters,
        _ rhs: RuntimeCounters,
        accumulator: inout RuntimeComparisonAccumulator
    ) {
        accumulator.exact(lhs.activeTiles, rhs.activeTiles, domain: .counters, path: "activeTiles")
        accumulator.exact(lhs.activeCompartments, rhs.activeCompartments, domain: .counters, path: "activeCompartments")
        accumulator.exact(lhs.deliveredEvents, rhs.deliveredEvents, domain: .counters, path: "deliveredEvents")
        accumulator.exact(lhs.generatedSpikes, rhs.generatedSpikes, domain: .counters, path: "generatedSpikes")
        accumulator.exact(lhs.routedEvents, rhs.routedEvents, domain: .counters, path: "routedEvents")
        accumulator.exact(lhs.molecularFirings, rhs.molecularFirings, domain: .counters, path: "molecularFirings")
        accumulator.exact(lhs.promotedEntities, rhs.promotedEntities, domain: .counters, path: "promotedEntities")
        accumulator.exact(lhs.demotedEntities, rhs.demotedEntities, domain: .counters, path: "demotedEntities")
        accumulator.exact(lhs.structuralMutations, rhs.structuralMutations, domain: .counters, path: "structuralMutations")
        accumulator.exact(lhs.rejectedMutations, rhs.rejectedMutations, domain: .counters, path: "rejectedMutations")
        accumulator.exact(lhs.numericalSubsteps, rhs.numericalSubsteps, domain: .counters, path: "numericalSubsteps")
    }
}

struct RuntimeComparisonAccumulator {
    let contract: RuntimeDeterminismContract
    private(set) var summaries: [RuntimeComparisonDomain: RuntimeDomainComparisonSummary] = [:]
    private(set) var differences: [RuntimeStateDifference] = []
    private(set) var omittedDifferenceCount = 0

    init(contract: RuntimeDeterminismContract) {
        self.contract = contract
    }

    var orderedSummaries: [RuntimeDomainComparisonSummary] {
        RuntimeComparisonDomain.allCases.compactMap { summaries[$0] }
    }

    mutating func count(
        _ lhs: Int,
        _ rhs: Int,
        domain: RuntimeComparisonDomain,
        path: String
    ) {
        exact(lhs, rhs, domain: domain, path: "\(path).count", kind: .count)
    }

    mutating func exact<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        domain: RuntimeComparisonDomain,
        path: String,
        index: Int? = nil,
        kind: RuntimeDifferenceKind = .exact
    ) {
        var summary = summaries[domain] ?? RuntimeDomainComparisonSummary(domain: domain)
        summary.comparedValues += 1
        if lhs != rhs {
            summary.exactMismatches += 1
            append(RuntimeStateDifference(
                domain: domain,
                kind: kind,
                path: path,
                index: index,
                referenceValue: String(describing: lhs),
                candidateValue: String(describing: rhs)
            ))
        }
        summaries[domain] = summary
    }

    mutating func float(
        _ lhs: Float,
        _ rhs: Float,
        domain: RuntimeComparisonDomain,
        path: String,
        index: Int? = nil
    ) {
        let tolerance = contract.tolerance(for: domain)
        let finite = lhs.isFinite && rhs.isFinite
        let absolute = finite ? abs(lhs - rhs) : .infinity
        let scale = finite ? max(abs(lhs), abs(rhs), Float.leastNormalMagnitude) : 1
        let relative = finite ? absolute / scale : .infinity
        let ulp = RuntimeFloatTolerance.ulpDistance(lhs, rhs)

        var summary = summaries[domain] ?? RuntimeDomainComparisonSummary(domain: domain)
        summary.comparedValues += 1
        if finite {
            summary.maximumAbsoluteError = max(summary.maximumAbsoluteError, absolute)
            summary.maximumRelativeError = max(summary.maximumRelativeError, relative)
            summary.maximumULPDistance = max(summary.maximumULPDistance, ulp)
        }
        if !tolerance.accepts(lhs, rhs) {
            summary.floatingPointMismatches += 1
            append(RuntimeStateDifference(
                domain: domain,
                kind: .floatingPoint,
                path: path,
                index: index,
                referenceValue: String(lhs),
                candidateValue: String(rhs),
                absoluteError: absolute,
                relativeError: relative,
                ulpDistance: ulp
            ))
        }
        summaries[domain] = summary
    }

    private mutating func append(_ difference: RuntimeStateDifference) {
        if differences.count < contract.maximumReportedDifferences {
            differences.append(difference)
        } else {
            omittedDifferenceCount += 1
        }
    }
}
