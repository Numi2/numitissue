import Foundation
#if canImport(Metal)
import Metal
#endif

public enum NTMetalAuxiliaryBufferSlot: String, CaseIterable, Sendable {
    case mechanisms
    case synapseKinetics
    case plasticityParameters
    case reactionNetworks
    case reactions
    case reactantTerms
    case stoichiometryTerms
    case fatePrograms
    case regulatoryMatrix
    case regulatoryBias
    case growthCones
    case interestPoints
    case cellSpatialKeys
    case cellSpatialOffsets
    case cellSpatialIndices
    case tileNeighbors
    case fieldOffsets
    case fieldMass
    case molecularCouplings
    case molecularSpatialHeaders
    case molecularSpatialAmountsRead
    case molecularSpatialAmountsWrite
    case electrodeHeaders
    case electrodeContacts
    case electrodeWaveforms
    case electrodeRecordings
    case observationAccumulators
}

@frozen
public struct NTMetalMechanismSet: Sendable {
    public var conductance0: SIMD4<Float>
    public var conductance1: SIMD4<Float>
    public var conductance2: SIMD4<Float>
    public var reversal0: SIMD4<Float>
    public var extracellular0: SIMD4<Float>
    public var calcium0: SIMD4<Float>
    public var temperature0: SIMD4<Float>

    public init(_ source: NTMechanismSetParameters) {
        conductance0 = SIMD4(
            source.sodiumDensityMicrosiemensPerSquareMicrometer,
            source.potassiumDensityMicrosiemensPerSquareMicrometer,
            source.leakDensityMicrosiemensPerSquareMicrometer,
            source.calciumLDensityMicrosiemensPerSquareMicrometer
        )
        conductance1 = SIMD4(
            source.calciumTDensityMicrosiemensPerSquareMicrometer,
            source.calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer,
            source.hcnDensityMicrosiemensPerSquareMicrometer,
            source.mCurrentDensityMicrosiemensPerSquareMicrometer
        )
        conductance2 = SIMD4(source.optogeneticDensityMicrosiemensPerSquareMicrometer, 0, 0, 0)
        reversal0 = SIMD4(
            source.leakReversalMillivolts,
            source.hcnReversalMillivolts,
            source.chlorideReversalMillivolts,
            0
        )
        extracellular0 = SIMD4(
            source.extracellularSodiumMillimolar,
            source.extracellularPotassiumMillimolar,
            source.extracellularCalciumMillimolar,
            0
        )
        calcium0 = SIMD4(
            source.calciumRestMicromolar,
            source.calciumDecayMilliseconds,
            source.calciumCurrentToConcentration,
            0
        )
        temperature0 = SIMD4(source.temperatureQ10, source.referenceTemperatureCelsius, 0, 0)
    }
}

@frozen
public struct NTMetalSynapseKinetics: Sendable {
    public var timeAndReversal: SIMD4<Float>
    public var releaseAndResources: SIMD4<Float>

    public init(_ source: NTSynapseKinetics) {
        timeAndReversal = SIMD4(
            source.riseMilliseconds,
            source.decayMilliseconds,
            source.reversalMillivolts,
            source.magnesiumMillimolar
        )
        releaseAndResources = SIMD4(
            source.utilization,
            source.facilitationMilliseconds,
            source.depressionMilliseconds,
            source.releaseProbability
        )
    }
}

@frozen
public struct NTMetalPlasticityParameters: Sendable {
    public var traceTimes: SIMD4<Float>
    public var learning0: SIMD4<Float>
    public var weightBounds: SIMD4<Float>
    public var structural0: SIMD4<Float>
    public var homeostasis0: SIMD4<Float>

    public init(_ source: NTPlasticityParameters) {
        traceTimes = SIMD4(
            source.preTraceMilliseconds,
            source.postTraceMilliseconds,
            source.eligibilityMilliseconds,
            0
        )
        learning0 = SIMD4(
            source.potentiationAmplitude,
            source.depressionAmplitude,
            source.learningRatePerSecond,
            source.weightDecayPerSecond
        )
        weightBounds = SIMD4(
            source.minimumWeightMicrosiemens,
            source.maximumWeightMicrosiemens,
            source.consolidationRatePerSecond,
            source.consolidationThreshold
        )
        structural0 = SIMD4(
            source.structuralDecayPerSecond,
            source.pruningThreshold,
            source.homeostaticRatePerSecond,
            0
        )
        homeostasis0 = .zero
    }
}

public enum NTMetalReactionRateKind: UInt32, Sendable {
    case massAction = 0
    case reversibleMassAction = 1
    case michaelisMenten = 2
    case hill = 3
    case inhibited = 4
    case voltageDependent = 5
    case calciumDependent = 6
    case affine = 7
}

@frozen
public struct NTMetalReactionNetworkHeader: Sendable {
    public var identity: SIMD4<UInt32>
    public var ranges0: SIMD4<UInt32>
    public var checksum: SIMD2<UInt32>
    public var reserved: SIMD2<UInt32>

    public init(
        network: NTCompiledReactionNetwork,
        reactionStart: UInt32,
        speciesParameterStart: UInt32 = 0
    ) {
        identity = SIMD4(network.id, UInt32(clamping: network.species.count), UInt32(clamping: network.reactions.count), 0)
        ranges0 = SIMD4(reactionStart, UInt32(clamping: network.reactions.count), speciesParameterStart, UInt32(clamping: network.species.count))
        checksum = SIMD2(UInt32(truncatingIfNeeded: network.checksum), UInt32(truncatingIfNeeded: network.checksum >> 32))
        reserved = .zero
    }
}

@frozen
public struct NTMetalReactionRecord: Sendable {
    public var identityAndRanges: SIMD4<UInt32>
    public var termRanges: SIMD4<UInt32>
    public var parameter0: SIMD4<Float>
    public var parameter1: SIMD4<Float>
    public var indices0: SIMD4<UInt32>

    public init(
        reaction: NTCompiledReaction,
        reactantStart: UInt32,
        stoichiometryStart: UInt32
    ) {
        let compiled = Self.compileRateLaw(reaction.rateLaw)
        identityAndRanges = SIMD4(UInt32(reaction.id), compiled.kind.rawValue, reactantStart, UInt32(clamping: reaction.reactantSpecies.count))
        termRanges = SIMD4(stoichiometryStart, UInt32(clamping: reaction.netSpecies.count), 0, 0)
        parameter0 = compiled.parameters0
        parameter1 = compiled.parameters1
        indices0 = compiled.indices
    }

    private static func compileRateLaw(
        _ law: NTReactionRateLaw
    ) -> (kind: NTMetalReactionRateKind, parameters0: SIMD4<Float>, parameters1: SIMD4<Float>, indices: SIMD4<UInt32>) {
        switch law {
        case let .massAction(rate):
            return (.massAction, SIMD4(rate, 0, 0, 0), .zero, .zero)
        case let .reversibleMassAction(forward, reverse):
            return (.reversibleMassAction, SIMD4(forward, reverse, 0, 0), .zero, .zero)
        case let .michaelisMenten(maximum, half, substrate):
            return (.michaelisMenten, SIMD4(maximum, half, 0, 0), .zero, SIMD4(UInt32(substrate), 0, 0, 0))
        case let .hill(maximum, half, exponent, regulator):
            return (.hill, SIMD4(maximum, half, exponent, 0), .zero, SIMD4(UInt32(regulator), 0, 0, 0))
        case let .inhibited(maximum, half, inhibitorConstant, substrate, inhibitor):
            return (
                .inhibited,
                SIMD4(maximum, half, inhibitorConstant, 0),
                .zero,
                SIMD4(UInt32(substrate), UInt32(inhibitor), 0, 0)
            )
        case let .voltageDependent(base, halfActivationMillivolts, slopeMillivolts):
            return (.voltageDependent, SIMD4(base, halfActivationMillivolts, slopeMillivolts, 0), .zero, .zero)
        case let .calciumDependent(maximum, halfActivationMicromolar, exponent):
            return (.calciumDependent, SIMD4(maximum, halfActivationMicromolar, exponent, 0), .zero, .zero)
        case let .affine(constant, coefficients):
            let sorted = coefficients.keys.sorted()
            let indices = SIMD4(
                sorted.indices.contains(0) ? UInt32(sorted[0]) : .max,
                sorted.indices.contains(1) ? UInt32(sorted[1]) : .max,
                sorted.indices.contains(2) ? UInt32(sorted[2]) : .max,
                sorted.indices.contains(3) ? UInt32(sorted[3]) : .max
            )
            let values = SIMD4(
                sorted.indices.contains(0) ? coefficients[sorted[0], default: 0] : 0,
                sorted.indices.contains(1) ? coefficients[sorted[1], default: 0] : 0,
                sorted.indices.contains(2) ? coefficients[sorted[2], default: 0] : 0,
                sorted.indices.contains(3) ? coefficients[sorted[3], default: 0] : 0
            )
            return (.affine, SIMD4(constant, 0, 0, 0), values, indices)
        }
    }
}

@frozen
public struct NTMetalReactantTerm: Sendable {
    public var speciesAndOrder: SIMD2<UInt32>

    public init(species: UInt16, order: UInt16) {
        speciesAndOrder = SIMD2(UInt32(species), UInt32(order))
    }
}

@frozen
public struct NTMetalStoichiometryTerm: Sendable {
    public var speciesAndCoefficient: SIMD2<Int32>

    public init(species: UInt16, coefficient: Int16) {
        speciesAndCoefficient = SIMD2(Int32(species), Int32(coefficient))
    }
}

@frozen
public struct NTMetalMolecularSpeciesParameters: Sendable {
    public var boundsAndDiffusion: SIMD4<Float>
    public var identityAndFlags: SIMD4<UInt32>

    public init(_ source: NTMolecularSpeciesDefinition) {
        boundsAndDiffusion = SIMD4(
            source.minimumAmount,
            source.maximumAmount,
            source.diffusionSquareMicrometersPerSecond,
            source.initialAmount
        )
        identityAndFlags = SIMD4(UInt32(source.id), source.isDiscrete ? 1 : 0, 0, 0)
    }
}

@frozen
public struct NTMetalMolecularCoupling: Sendable {
    public var identities: SIMD4<UInt32>
    public var compartment: SIMD2<UInt32>
    public var dynamics: SIMD4<Float>
    public var flags: SIMD4<UInt32>

    public init(_ source: NTMicrodomainCoupling) {
        identities = SIMD4(
            UInt32(truncatingIfNeeded: source.microdomain.rawValue),
            UInt32(truncatingIfNeeded: source.microdomain.rawValue >> 32),
            UInt32(source.species),
            source.extracellularSpecies.map { UInt32($0.rawValue) } ?? .max
        )
        let rawCompartment = source.compartment?.rawValue ?? UInt64.max
        compartment = SIMD2(UInt32(truncatingIfNeeded: rawCompartment), UInt32(truncatingIfNeeded: rawCompartment >> 32))
        dynamics = SIMD4(source.membraneFluxScale, source.extracellularFluxScale, 0, 0)
        flags = SIMD4(source.clampToCompartmentCalcium ? 1 : 0, source.voltageSensitive ? 1 : 0, 0, 0)
    }
}

@frozen
public struct NTMetalFateProgram: Sendable {
    public var identity: SIMD4<UInt32>
    public var timing0: SIMD4<Float>
    public var hazard0: SIMD4<Float>
    public var behavior0: SIMD4<Float>

    public init(_ source: NTFateProgram) {
        identity = SIMD4(
            UInt32(source.cellKind.rawValue),
            UInt32(source.daughterKind.rawValue),
            UInt32(source.asymmetricDaughterKind.rawValue),
            UInt32(source.adhesionClass)
        )
        timing0 = SIMD4(
            source.cycleDurationSeconds,
            source.divisionProbabilityPerCycle,
            source.asymmetricDivisionProbability,
            source.differentiationRatePerSecond
        )
        hazard0 = SIMD4(
            source.apoptosisBaseRatePerSecond,
            source.damageApoptosisGain,
            source.energyRequirement,
            0
        )
        behavior0 = SIMD4(source.motilityMultiplier, 0, 0, 0)
    }
}

@frozen
public struct NTMetalGrowthCone: Sendable {
    public var id: SIMD2<UInt32>
    public var owner: SIMD2<UInt32>
    public var topology: SIMD4<UInt32>
    public var positionAndRadius: SIMD4<Float>
    public var directionAndSpeed: SIMD4<Float>
    public var growthState: SIMD4<Float>
    public var flags: SIMD4<UInt32>

    public init(_ source: NTGrowthConeState, tileIndex: UInt32) {
        id = SIMD2(UInt32(truncatingIfNeeded: source.id.rawValue), UInt32(truncatingIfNeeded: source.id.rawValue >> 32))
        owner = SIMD2(UInt32(truncatingIfNeeded: source.ownerCell.rawValue), UInt32(truncatingIfNeeded: source.ownerCell.rawValue >> 32))
        topology = SIMD4(source.parentCompartmentIndex, tileIndex, UInt32(clamping: source.targetCellKinds.count), 0)
        positionAndRadius = SIMD4(source.positionMicrometers.x, source.positionMicrometers.y, source.positionMicrometers.z, source.radiusMicrometers)
        directionAndSpeed = SIMD4(source.direction.x, source.direction.y, source.direction.z, source.speedMicrometersPerSecond)
        growthState = SIMD4(source.accumulatedLengthMicrometers, source.branchHazard, source.collapseHazard, source.ageSeconds)
        flags = SIMD4(source.active ? 1 : 0, source.flags, 0, 0)
    }
}

@frozen
public struct NTMetalInterestPoint: Sendable {
    public var positionAndRadius: SIMD4<Float>
    public var policy: SIMD4<UInt32>
    public var weightAndPadding: SIMD4<Float>

    public init(_ source: NTInterestPoint) {
        positionAndRadius = SIMD4(
            source.positionMicrometers.x,
            source.positionMicrometers.y,
            source.positionMicrometers.z,
            source.radiusMicrometers
        )
        policy = SIMD4(UInt32(source.kind.rawValue), UInt32(source.requestedMinimumFidelity.rawValue), 0, 0)
        weightAndPadding = SIMD4(source.weight, 0, 0, 0)
    }
}

public final class NTMetalAuxiliaryResourceSet: @unchecked Sendable {
    #if canImport(Metal)
    public var buffers: [NTMetalAuxiliaryBufferSlot: any MTLBuffer]

    public init(buffers: [NTMetalAuxiliaryBufferSlot: any MTLBuffer] = [:]) {
        self.buffers = buffers
    }

    public subscript(_ slot: NTMetalAuxiliaryBufferSlot) -> (any MTLBuffer)? {
        buffers[slot]
    }
    #else
    public init() {}
    #endif
}
