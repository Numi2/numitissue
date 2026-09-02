import Foundation
import NumiTissueCore

// MARK: - Immutable GPU parameter tables

@frozen
public struct GPUChannelParameter: Sendable {
    public var kindAndPowers: UInt4
    public var conductance: Float4
    public var activation: Float4
    public var inactivation: Float4

    public init(channel: IonChannelDescriptor) {
        self.kindAndPowers = UInt4(
            UInt32(channel.kind.rawValue),
            UInt32(channel.activationPower),
            UInt32(channel.inactivationPower),
            UInt32(channel.activationGate.kind.rawValue) |
                (UInt32(channel.inactivationGate.kind.rawValue) << 16)
        )
        self.conductance = Float4(
            channel.maximumConductance,
            channel.reversalPotentialMillivolts,
            0,
            0
        )
        self.activation = channel.activationGate.parameters
        self.inactivation = channel.inactivationGate.parameters
    }
}

@frozen
public struct GPUMechanismSet: Sendable {
    public var channelRange: UInt4
    public var thermal: Float4

    public init(
        channelOffset: UInt32,
        channelCount: UInt32,
        temperatureCelsius: Float,
        q10: Float
    ) {
        self.channelRange = UInt4(channelOffset, channelCount, 0, 0)
        self.thermal = Float4(
            temperatureCelsius,
            q10,
            pow(q10, (temperatureCelsius - 6.3) / 10),
            0
        )
    }
}

@frozen
public struct GPUSynapseParameter: Sendable {
    public var typeAndFlags: UInt4
    public var kinetics: Float4
    public var shortTerm: Float4
    public var stdp0: Float4
    public var stdp1: Float4

    public init(prototype: SynapsePrototype, fastQuantumMilliseconds: Float) {
        var flags: UInt32 = 0
        if prototype.shortTermPlasticity != nil { flags |= 1 << 0 }
        if prototype.stdp != nil { flags |= 1 << 1 }
        self.typeAndFlags = UInt4(UInt32(prototype.receptor.rawValue), flags, 0, 0)
        self.kinetics = Float4(
            prototype.riseMilliseconds,
            prototype.decayMilliseconds,
            prototype.reversalPotentialMillivolts,
            prototype.defaultWeight
        )
        if let shortTerm = prototype.shortTermPlasticity {
            self.shortTerm = Float4(
                shortTerm.utilization,
                exp(-fastQuantumMilliseconds / max(shortTerm.recoveryMilliseconds, 1e-6)),
                shortTerm.facilitationMilliseconds > 0
                    ? exp(-fastQuantumMilliseconds / shortTerm.facilitationMilliseconds)
                    : 0,
                0
            )
        } else {
            self.shortTerm = Float4(0, 1, 0, 0)
        }
        if let stdp = prototype.stdp {
            self.stdp0 = Float4(
                stdp.positiveAmplitude,
                stdp.negativeAmplitude,
                exp(-fastQuantumMilliseconds / max(stdp.positiveTimeConstantMilliseconds, 1e-6)),
                exp(-fastQuantumMilliseconds / max(stdp.negativeTimeConstantMilliseconds, 1e-6))
            )
            self.stdp1 = Float4(
                exp(-fastQuantumMilliseconds / max(stdp.eligibilityTimeConstantMilliseconds, 1e-6)),
                stdp.learningRate,
                stdp.minimumWeight,
                stdp.maximumWeight
            )
        } else {
            self.stdp0 = .zero
            self.stdp1 = Float4(1, 0, 0, .greatestFiniteMagnitude)
        }
    }
}

@frozen
public struct GPUFieldParameter: Sendable {
    public var addressing: UInt4
    public var dynamics: Float4
    public var bounds: Float4

    public init(
        species: FieldSpeciesDescriptor,
        dtMilliseconds: Float,
        voxelWidthMicrometers: Float
    ) {
        let widthSquared = max(voxelWidthMicrometers * voxelWidthMicrometers, 1e-9)
        let alpha = species.diffusionMicrometersSquaredPerMillisecond * dtMilliseconds / widthSquared
        self.addressing = UInt4(UInt32(species.channel.rawValue), 0, 0, 0)
        self.dynamics = Float4(
            alpha,
            exp(-species.decayPerMillisecond * dtMilliseconds),
            species.baseline,
            0
        )
        self.bounds = Float4(species.minimum, species.maximum, 0, 0)
    }
}

@frozen
public struct GPUCellProgram: Sendable {
    public var identity: UInt4
    public var mechanics: Float4
    public var membrane: Float4
    public var programIndices: UInt4

    public init(
        prototype: CellPrototype,
        mechanismIndex: UInt32,
        regulatoryIndex: UInt32,
        glialIndex: UInt32
    ) {
        self.identity = UInt4(
            UInt32(prototype.kind.rawValue),
            UInt32(prototype.defaultFidelity.rawValue),
            0,
            0
        )
        self.mechanics = Float4(prototype.radiusMicrometers, 1, 1, 1)
        self.membrane = Float4(
            prototype.membraneCapacitance,
            prototype.leakConductance,
            prototype.leakReversalMillivolts,
            150
        )
        self.programIndices = UInt4(mechanismIndex, regulatoryIndex, glialIndex, 0)
    }
}

@frozen
public struct GPURegulatoryProgram: Sendable {
    public var stateAndMatrixRange: UInt4
    public var biasAndTransitionRange: UInt4
    public var timeConstants0: Float4
    public var timeConstants1: Float4
    public var hazards: Float4

    public init(
        stateCount: UInt32,
        matrixOffset: UInt32,
        matrixCount: UInt32,
        biasOffset: UInt32,
        transitionOffset: UInt32,
        transitionCount: UInt32,
        timeConstants0: Float4,
        timeConstants1: Float4,
        divisionHazard: Float,
        apoptosisHazard: Float,
        growthProgramIndex: UInt32
    ) {
        self.stateAndMatrixRange = UInt4(stateCount, matrixOffset, matrixCount, growthProgramIndex)
        self.biasAndTransitionRange = UInt4(biasOffset, transitionOffset, transitionCount, 0)
        self.timeConstants0 = timeConstants0
        self.timeConstants1 = timeConstants1
        self.hazards = Float4(divisionHazard, apoptosisHazard, 0, 0)
    }
}

@frozen
public struct GPUFateTransition: Sendable {
    public var identity: UInt4
    public var hazard: Float4
    public var regulatoryWeights: Float4
    public var fieldWeights: Float4

    public init(_ transition: FateTransition) {
        self.identity = UInt4(UInt32(transition.targetKind.rawValue), 0, 0, 0)
        self.hazard = Float4(
            transition.baseHazardPerSecond,
            transition.minimumAgeSeconds,
            0,
            0
        )
        self.regulatoryWeights = transition.regulatoryWeights
        self.fieldWeights = transition.fieldWeights
    }
}

@frozen
public struct GPUGrowthProgram: Sendable {
    public var rates: Float4
    public var guidance0: Float4
    public var guidance1: Float4

    public init(_ program: GrowthConeProgram) {
        self.rates = Float4(
            program.speedMicrometersPerSecond,
            program.branchHazardPerSecond,
            program.retractionHazardPerSecond,
            program.segmentLengthMicrometers
        )
        self.guidance0 = Float4(
            program.persistenceWeight,
            program.attractionWeight,
            program.repulsionWeight,
            program.fasciculationWeight
        )
        self.guidance1 = Float4(program.activityWeight, program.noiseWeight, 0, 0)
    }
}

@frozen
public struct GPUGlialProgram: Sendable {
    public var identity: UInt4
    public var uptakeRates: Float4
    public var releaseRates: Float4
    public var activationThresholds: Float4
    public var spatial: Float4

    public init(_ program: GlialProgram) {
        self.identity = UInt4(UInt32(program.kind.rawValue), 0, 0, 0)
        self.uptakeRates = program.uptakeRates
        self.releaseRates = program.releaseRates
        self.activationThresholds = program.activationThresholds
        self.spatial = Float4(program.spatialRadiusMicrometers, 0, 0, 0)
    }
}

// MARK: - Compiled topology

