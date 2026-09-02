import Foundation

@frozen
public struct NTSynapseKinetics: Codable, Hashable, Sendable {
    public var riseMilliseconds: Float
    public var decayMilliseconds: Float
    public var reversalMillivolts: Float
    public var magnesiumMillimolar: Float
    public var utilization: Float
    public var facilitationMilliseconds: Float
    public var depressionMilliseconds: Float
    public var releaseProbability: Float

    public init(
        riseMilliseconds: Float,
        decayMilliseconds: Float,
        reversalMillivolts: Float,
        magnesiumMillimolar: Float = 1,
        utilization: Float = 0.2,
        facilitationMilliseconds: Float = 0,
        depressionMilliseconds: Float = 800,
        releaseProbability: Float = 1
    ) {
        self.riseMilliseconds = riseMilliseconds
        self.decayMilliseconds = decayMilliseconds
        self.reversalMillivolts = reversalMillivolts
        self.magnesiumMillimolar = magnesiumMillimolar
        self.utilization = utilization
        self.facilitationMilliseconds = facilitationMilliseconds
        self.depressionMilliseconds = depressionMilliseconds
        self.releaseProbability = releaseProbability
    }
}

public struct NTSynapseKineticsLibrary: Codable, Sendable {
    public var values: [NTSynapseReceptor: NTSynapseKinetics]

    public init(values: [NTSynapseReceptor: NTSynapseKinetics] = Self.biophysicalDefaults) {
        self.values = values
    }

    public func kinetics(for receptor: NTSynapseReceptor) -> NTSynapseKinetics {
        values[receptor] ?? Self.biophysicalDefaults[receptor]!
    }

    public static let biophysicalDefaults: [NTSynapseReceptor: NTSynapseKinetics] = [
        .ampa: .init(riseMilliseconds: 0.2, decayMilliseconds: 2.0, reversalMillivolts: 0, utilization: 0.25, depressionMilliseconds: 700),
        .nmda: .init(riseMilliseconds: 2.0, decayMilliseconds: 80, reversalMillivolts: 0, magnesiumMillimolar: 1, utilization: 0.2, depressionMilliseconds: 900),
        .gabaA: .init(riseMilliseconds: 0.5, decayMilliseconds: 8, reversalMillivolts: -75, utilization: 0.25, depressionMilliseconds: 500),
        .gabaB: .init(riseMilliseconds: 10, decayMilliseconds: 180, reversalMillivolts: -95, utilization: 0.15, depressionMilliseconds: 1_500),
        .electrical: .init(riseMilliseconds: 0.025, decayMilliseconds: 0.025, reversalMillivolts: 0),
        .modulatory: .init(riseMilliseconds: 50, decayMilliseconds: 1_000, reversalMillivolts: 0, utilization: 0.05, depressionMilliseconds: 2_000)
    ]
}

@frozen
public struct NTPlasticityParameters: Codable, Hashable, Sendable {
    public var preTraceMilliseconds: Float
    public var postTraceMilliseconds: Float
    public var eligibilityMilliseconds: Float
    public var potentiationAmplitude: Float
    public var depressionAmplitude: Float
    public var learningRatePerSecond: Float
    public var weightDecayPerSecond: Float
    public var minimumWeightMicrosiemens: Float
    public var maximumWeightMicrosiemens: Float
    public var consolidationRatePerSecond: Float
    public var consolidationThreshold: Float
    public var structuralDecayPerSecond: Float
    public var pruningThreshold: Float
    public var homeostaticRatePerSecond: Float

    public init(
        preTraceMilliseconds: Float = 20,
        postTraceMilliseconds: Float = 20,
        eligibilityMilliseconds: Float = 1_000,
        potentiationAmplitude: Float = 1,
        depressionAmplitude: Float = 1.05,
        learningRatePerSecond: Float = 0.001,
        weightDecayPerSecond: Float = 1.0e-6,
        minimumWeightMicrosiemens: Float = 0,
        maximumWeightMicrosiemens: Float = 10,
        consolidationRatePerSecond: Float = 0.0001,
        consolidationThreshold: Float = 0.6,
        structuralDecayPerSecond: Float = 1.0e-5,
        pruningThreshold: Float = 0.02,
        homeostaticRatePerSecond: Float = 1.0e-5
    ) {
        self.preTraceMilliseconds = preTraceMilliseconds
        self.postTraceMilliseconds = postTraceMilliseconds
        self.eligibilityMilliseconds = eligibilityMilliseconds
        self.potentiationAmplitude = potentiationAmplitude
        self.depressionAmplitude = depressionAmplitude
        self.learningRatePerSecond = learningRatePerSecond
        self.weightDecayPerSecond = weightDecayPerSecond
        self.minimumWeightMicrosiemens = minimumWeightMicrosiemens
        self.maximumWeightMicrosiemens = maximumWeightMicrosiemens
        self.consolidationRatePerSecond = consolidationRatePerSecond
        self.consolidationThreshold = consolidationThreshold
        self.structuralDecayPerSecond = structuralDecayPerSecond
        self.pruningThreshold = pruningThreshold
        self.homeostaticRatePerSecond = homeostaticRatePerSecond
    }
}

@frozen
public struct NTSynapseStepResult: Sendable {
    public var acceptedReleases: UInt64
    public var failedReleases: UInt64
    public var totalExcitatoryConductanceMicrosiemens: Float
    public var totalInhibitoryConductanceMicrosiemens: Float
    public var diagnostics: [NTDiagnostic]

    public init(
        acceptedReleases: UInt64 = 0,
        failedReleases: UInt64 = 0,
        totalExcitatoryConductanceMicrosiemens: Float = 0,
        totalInhibitoryConductanceMicrosiemens: Float = 0,
        diagnostics: [NTDiagnostic] = []
    ) {
        self.acceptedReleases = acceptedReleases
        self.failedReleases = failedReleases
        self.totalExcitatoryConductanceMicrosiemens = totalExcitatoryConductanceMicrosiemens
        self.totalInhibitoryConductanceMicrosiemens = totalInhibitoryConductanceMicrosiemens
        self.diagnostics = diagnostics
    }
}

public struct NTSynapseEngine: Sendable {
    public var kinetics: NTSynapseKineticsLibrary
    public var plasticity: NTPlasticityParameters

    public init(
        kinetics: NTSynapseKineticsLibrary = .init(),
        plasticity: NTPlasticityParameters = .init()
    ) {
        self.kinetics = kinetics
        self.plasticity = plasticity
    }

    public func prepareAndDeliver(
        state: inout NTProductionState,
        events: [NTNeuralEvent],
        currentTime: TissueTime,
        deltaTicks: UInt64,
        transaction: TransactionID
    ) -> NTSynapseStepResult {
        let dtMilliseconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 0.001
        var result = NTSynapseStepResult()

        for index in state.compartments.indices {
            state.compartments[index].synapticConductanceExcitatory = 0
            state.compartments[index].synapticConductanceInhibitory = 0
            state.compartments[index].synapticCurrentNanoamps = 0
        }

        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let model = kinetics.kinetics(for: synapse.record.receptor)
            synapse.riseState *= exp(-dtMilliseconds / max(model.riseMilliseconds, 1.0e-6))
            synapse.decayState *= exp(-dtMilliseconds / max(model.decayMilliseconds, 1.0e-6))
            synapse.record.preTrace *= exp(-dtMilliseconds / max(plasticity.preTraceMilliseconds, 1.0e-6))
            synapse.postTraceFast *= exp(-dtMilliseconds / max(plasticity.postTraceMilliseconds, 1.0e-6))
            synapse.record.eligibility *= exp(-dtMilliseconds / max(plasticity.eligibilityMilliseconds, 1.0e-6))

            if model.facilitationMilliseconds > 0 {
                synapse.record.shortTermU = model.utilization +
                    (synapse.record.shortTermU - model.utilization) *
                    exp(-dtMilliseconds / model.facilitationMilliseconds)
            } else {
                synapse.record.shortTermU = model.utilization
            }
            synapse.record.shortTermX = 1 + (synapse.record.shortTermX - 1) *
                exp(-dtMilliseconds / max(model.depressionMilliseconds, 1.0e-6))
            synapse.vesiclePool = 1 + (synapse.vesiclePool - 1) *
                exp(-dtMilliseconds / max(model.depressionMilliseconds, 1.0e-6))
            state.synapses[index] = synapse
        }

        for event in events where event.kind == .synapticRelease {
            let index = Int(event.destination)
            guard state.synapses.indices.contains(index) else {
                result.diagnostics.append(.init(
                    severity: .error,
                    code: .invalidEventDestination,
                    message: "Synaptic release targets absent synapse index \(index).",
                    entity: event.source
                ))
                continue
            }
            var synapse = state.synapses[index]
            let model = kinetics.kinetics(for: synapse.record.receptor)
            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: synapse.record.id.rawValue,
                    stream: UInt32(truncatingIfNeeded: currentTime.tick),
                    sample: UInt32(truncatingIfNeeded: event.sequence)
                ).counter(),
                key: PhiloxKey(seed: state.configuration.seed)
            )
            let probability = max(0, min(1, model.releaseProbability * synapse.releaseProbability * synapse.vesiclePool))
            if CounterRandom.uniform01(random.y) > probability {
                result.failedReleases &+= 1
                continue
            }

            if model.facilitationMilliseconds > 0 {
                synapse.record.shortTermU += model.utilization * (1 - synapse.record.shortTermU)
            }
            let releasedFraction = max(0, min(1, synapse.record.shortTermU * synapse.record.shortTermX))
            synapse.record.shortTermX *= (1 - synapse.record.shortTermU)
            synapse.vesiclePool *= (1 - releasedFraction)
            let impulse = event.payload0 * synapse.record.weightMicrosiemens * releasedFraction
            synapse.riseState += impulse
            synapse.decayState += impulse
            synapse.record.preTrace += 1
            synapse.record.eligibility += plasticity.potentiationAmplitude * synapse.postTraceFast
            synapse.lastPreSpike = currentTime
            synapse.record.lastEvent = currentTime
            state.synapses[index] = synapse
            result.acceptedReleases &+= 1
        }

        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let model = kinetics.kinetics(for: synapse.record.receptor)
            var conductance = max(0, synapse.decayState - synapse.riseState)
            let post = Int(synapse.record.postCompartmentIndex)
            guard state.compartments.indices.contains(post) else {
                result.diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidReference,
                    message: "Synapse has an invalid postsynaptic compartment.",
                    entity: synapse.record.id.rawValue
                ))
                continue
            }

            if synapse.record.receptor == .nmda {
                let voltage = state.compartments[post].record.membraneVoltageMillivolts
                synapse.nmdaBlock = 1 / (1 + model.magnesiumMillimolar * exp(-0.062 * voltage) / 3.57)
                conductance *= synapse.nmdaBlock
            }
            synapse.record.conductanceMicrosiemens = conductance

            switch synapse.record.receptor {
            case .ampa, .nmda:
                state.compartments[post].synapticConductanceExcitatory += conductance
                result.totalExcitatoryConductanceMicrosiemens += conductance
            case .gabaA, .gabaB:
                state.compartments[post].synapticConductanceInhibitory += conductance
                result.totalInhibitoryConductanceMicrosiemens += conductance
            case .electrical:
                let pre = Int(synapse.record.preCompartmentIndex)
                if state.compartments.indices.contains(pre) {
                    let current = synapse.record.weightMicrosiemens *
                        (state.compartments[pre].record.membraneVoltageMillivolts -
                         state.compartments[post].record.membraneVoltageMillivolts)
                    state.compartments[post].synapticCurrentNanoamps += current
                    state.compartments[post].record.injectedCurrentNanoamps += current
                }
            case .modulatory:
                break
            }
            state.synapses[index] = synapse
        }
        return result
    }

    public func observePostsynapticSpikes(
        state: inout NTProductionState,
        spikes: [NTSpike],
        currentTime: TissueTime
    ) {
        guard !spikes.isEmpty else { return }
        var spikingCompartments = Set<UInt32>()
        for spike in spikes {
            if let index = state.compartmentIndex(id: spike.sourceCompartment) {
                spikingCompartments.insert(UInt32(index))
            }
        }
        guard !spikingCompartments.isEmpty else { return }

        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            if spikingCompartments.contains(synapse.record.postCompartmentIndex) {
                synapse.postTraceFast += 1
                synapse.postTraceSlow += 1
                synapse.record.postTrace += 1
                synapse.record.eligibility -= plasticity.depressionAmplitude * synapse.record.preTrace
                synapse.lastPostSpike = currentTime
                state.synapses[index] = synapse
            }
        }
    }

    public func applyPlasticity(
        state: inout NTProductionState,
        modulators: NTNeuromodulators,
        deltaTicks: UInt64,
        structuralEpoch: Bool
    ) {
        let dtSeconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        let modulator = modulators.plasticityGain
        var firingRateByCompartment: [UInt32: Float] = [:]
        for index in state.compartments.indices {
            let rate = Float(state.compartments[index].spikeCountWindow) / max(dtSeconds, 1.0e-6)
            firingRateByCompartment[UInt32(index)] = rate
            if structuralEpoch { state.compartments[index].spikeCountWindow = 0 }
        }

        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            guard synapse.record.receptor != .electrical else { continue }
            let protectedFraction = max(0, min(1, synapse.record.consolidation))
            let plasticFraction = 1 - 0.8 * protectedFraction
            let learned = plasticity.learningRatePerSecond * modulator * synapse.record.eligibility * dtSeconds * plasticFraction
            let decay = plasticity.weightDecayPerSecond *
                (synapse.record.weightMicrosiemens - protectedFraction * synapse.record.weightMicrosiemens) * dtSeconds
            let observedRate = firingRateByCompartment[synapse.record.postCompartmentIndex, default: 0]
            let homeostatic = plasticity.homeostaticRatePerSecond *
                (synapse.homeostaticTargetHertz - observedRate) * dtSeconds * synapse.record.weightMicrosiemens
            synapse.record.weightMicrosiemens = max(
                plasticity.minimumWeightMicrosiemens,
                min(plasticity.maximumWeightMicrosiemens, synapse.record.weightMicrosiemens + learned - decay + homeostatic)
            )

            if abs(synapse.record.eligibility) >= plasticity.consolidationThreshold && modulator > 0 {
                synapse.record.consolidation = min(
                    1,
                    synapse.record.consolidation + plasticity.consolidationRatePerSecond * modulator * dtSeconds
                )
            } else {
                synapse.record.consolidation = max(
                    0,
                    synapse.record.consolidation - 0.1 * plasticity.consolidationRatePerSecond * dtSeconds
                )
            }

            if structuralEpoch {
                let activitySupport = min(1, abs(synapse.record.eligibility) + 0.1 * synapse.postTraceSlow)
                synapse.record.structuralScore = max(
                    0,
                    min(1, synapse.record.structuralScore + activitySupport * 0.001 - plasticity.structuralDecayPerSecond * dtSeconds)
                )
                synapse.postTraceSlow *= exp(-dtSeconds / 10)
                if synapse.record.structuralScore < plasticity.pruningThreshold && synapse.record.consolidation < 0.1 {
                    synapse.pendingDeletion = true
                }
            }
            state.synapses[index] = synapse
        }
    }
}

@frozen
public struct NTCompressedSynapsePopulation: Codable, Hashable, Sendable {
    public var sourcePopulation: PopulationID
    public var targetPopulation: PopulationID
    public var targetCompartmentIndices: [UInt32]
    public var receptor: NTSynapseReceptor
    public var physicalContactCount: UInt32
    public var totalConductanceMicrosiemens: Float
    public var delayMeanTicks: Float
    public var delayStandardDeviationTicks: Float
    public var weightMean: Float
    public var weightVariance: Float
    public var utilizationMean: Float
    public var resourceMean: Float
    public var eligibilityMean: Float
    public var eligibilityVariance: Float
    public var pendingSpikeCount: UInt32

    public init(
        sourcePopulation: PopulationID,
        targetPopulation: PopulationID,
        targetCompartmentIndices: [UInt32],
        receptor: NTSynapseReceptor,
        physicalContactCount: UInt32,
        totalConductanceMicrosiemens: Float,
        delayMeanTicks: Float,
        delayStandardDeviationTicks: Float,
        weightMean: Float,
        weightVariance: Float = 0,
        utilizationMean: Float = 0.2,
        resourceMean: Float = 1,
        eligibilityMean: Float = 0,
        eligibilityVariance: Float = 0,
        pendingSpikeCount: UInt32 = 0
    ) {
        self.sourcePopulation = sourcePopulation
        self.targetPopulation = targetPopulation
        self.targetCompartmentIndices = targetCompartmentIndices
        self.receptor = receptor
        self.physicalContactCount = physicalContactCount
        self.totalConductanceMicrosiemens = totalConductanceMicrosiemens
        self.delayMeanTicks = delayMeanTicks
        self.delayStandardDeviationTicks = delayStandardDeviationTicks
        self.weightMean = weightMean
        self.weightVariance = weightVariance
        self.utilizationMean = utilizationMean
        self.resourceMean = resourceMean
        self.eligibilityMean = eligibilityMean
        self.eligibilityVariance = eligibilityVariance
        self.pendingSpikeCount = pendingSpikeCount
    }
}

public struct NTCompressedSynapseEngine: Sendable {
    public init() {}

    public func apply(
        populations: inout [NTCompressedSynapsePopulation],
        state: inout NTProductionState,
        deltaTicks: UInt64,
        seed: UInt64,
        transaction: TransactionID
    ) {
        let dtSeconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        for index in populations.indices {
            var population = populations[index]
            guard population.pendingSpikeCount > 0, !population.targetCompartmentIndices.isEmpty else {
                population.resourceMean = 1 + (population.resourceMean - 1) * exp(-dtSeconds / 0.8)
                populations[index] = population
                continue
            }
            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: population.sourcePopulation.rawValue ^ population.targetPopulation.rawValue,
                    stream: UInt32(index),
                    sample: population.pendingSpikeCount
                ).counter(),
                key: PhiloxKey(seed: seed)
            )
            let normal = CounterRandom.normalPair(random.x, random.y).x
            let contactScale = Float(population.physicalContactCount) * population.resourceMean * population.utilizationMean
            let conductance = max(0, population.totalConductanceMicrosiemens *
                (Float(population.pendingSpikeCount) + sqrt(Float(population.pendingSpikeCount)) * normal) *
                contactScale / max(Float(population.physicalContactCount), 1))
            let perTarget = conductance / Float(population.targetCompartmentIndices.count)
            for target in population.targetCompartmentIndices where state.compartments.indices.contains(Int(target)) {
                switch population.receptor {
                case .ampa, .nmda:
                    state.compartments[Int(target)].synapticConductanceExcitatory += perTarget
                case .gabaA, .gabaB:
                    state.compartments[Int(target)].synapticConductanceInhibitory += perTarget
                default:
                    break
                }
            }
            population.resourceMean = max(0, population.resourceMean * (1 - population.utilizationMean))
            population.pendingSpikeCount = 0
            populations[index] = population
        }
    }
}
