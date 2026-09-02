import Foundation
import NumiTissueCore

@frozen
public struct ShortTermPlasticity: Codable, Sendable, Hashable {
    public var utilization: Float
    public var recoveryMilliseconds: Float
    public var facilitationMilliseconds: Float

    public init(utilization: Float = 0.2, recoveryMilliseconds: Float = 800, facilitationMilliseconds: Float = 0) {
        self.utilization = utilization
        self.recoveryMilliseconds = recoveryMilliseconds
        self.facilitationMilliseconds = facilitationMilliseconds
    }
}

@frozen
public struct STDPParameters: Codable, Sendable, Hashable {
    public var positiveAmplitude: Float
    public var negativeAmplitude: Float
    public var positiveTimeConstantMilliseconds: Float
    public var negativeTimeConstantMilliseconds: Float
    public var eligibilityTimeConstantMilliseconds: Float
    public var learningRate: Float
    public var minimumWeight: Float
    public var maximumWeight: Float

    public init(
        positiveAmplitude: Float = 1,
        negativeAmplitude: Float = 1.05,
        positiveTimeConstantMilliseconds: Float = 20,
        negativeTimeConstantMilliseconds: Float = 20,
        eligibilityTimeConstantMilliseconds: Float = 1_000,
        learningRate: Float = 1e-4,
        minimumWeight: Float = 0,
        maximumWeight: Float = 4
    ) {
        self.positiveAmplitude = positiveAmplitude
        self.negativeAmplitude = negativeAmplitude
        self.positiveTimeConstantMilliseconds = positiveTimeConstantMilliseconds
        self.negativeTimeConstantMilliseconds = negativeTimeConstantMilliseconds
        self.eligibilityTimeConstantMilliseconds = eligibilityTimeConstantMilliseconds
        self.learningRate = learningRate
        self.minimumWeight = minimumWeight
        self.maximumWeight = maximumWeight
    }
}

@frozen
public struct SynapsePrototype: Codable, Sendable, Hashable {
    public var name: String
    public var receptor: ReceptorKind
    public var riseMilliseconds: Float
    public var decayMilliseconds: Float
    public var reversalPotentialMillivolts: Float
    public var defaultWeight: Float
    public var shortTermPlasticity: ShortTermPlasticity?
    public var stdp: STDPParameters?

    public init(
        name: String,
        receptor: ReceptorKind,
        riseMilliseconds: Float,
        decayMilliseconds: Float,
        reversalPotentialMillivolts: Float,
        defaultWeight: Float,
        shortTermPlasticity: ShortTermPlasticity? = nil,
        stdp: STDPParameters? = nil
    ) {
        self.name = name
        self.receptor = receptor
        self.riseMilliseconds = riseMilliseconds
        self.decayMilliseconds = decayMilliseconds
        self.reversalPotentialMillivolts = reversalPotentialMillivolts
        self.defaultWeight = defaultWeight
        self.shortTermPlasticity = shortTermPlasticity
        self.stdp = stdp
    }
}

@frozen
public struct SynapseConnection: Codable, Sendable, Hashable {
    public var id: SynapseID
    public var prototype: String
    public var presynapticCell: CellID
    public var postsynapticCell: CellID
    public var postsynapticMorphologyNode: UInt32?
    public var weight: Float?
    public var delayMilliseconds: Float

    public init(
        id: SynapseID,
        prototype: String,
        presynapticCell: CellID,
        postsynapticCell: CellID,
        postsynapticMorphologyNode: UInt32? = nil,
        weight: Float? = nil,
        delayMilliseconds: Float = 1
    ) {
        self.id = id
        self.prototype = prototype
        self.presynapticCell = presynapticCell
        self.postsynapticCell = postsynapticCell
        self.postsynapticMorphologyNode = postsynapticMorphologyNode
        self.weight = weight
        self.delayMilliseconds = delayMilliseconds
    }
}

@frozen
public struct FieldSpeciesDescriptor: Codable, Sendable, Hashable {
    public var channel: FieldChannel
    public var name: String
    public var diffusionMicrometersSquaredPerMillisecond: Float
    public var decayPerMillisecond: Float
    public var baseline: Float
    public var minimum: Float
    public var maximum: Float

    public init(
        channel: FieldChannel,
        name: String,
        diffusionMicrometersSquaredPerMillisecond: Float,
        decayPerMillisecond: Float = 0,
        baseline: Float,
        minimum: Float = 0,
        maximum: Float = .greatestFiniteMagnitude
    ) {
        self.channel = channel
        self.name = name
        self.diffusionMicrometersSquaredPerMillisecond = diffusionMicrometersSquaredPerMillisecond
        self.decayPerMillisecond = decayPerMillisecond
        self.baseline = baseline
        self.minimum = minimum
        self.maximum = maximum
    }
}
