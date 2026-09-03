import Foundation
import NumiTissueCore
import NumiTissueModels

extension CPUReferenceTissueBackend {
    func detectAndRouteSpikes(
        at absoluteTick: UInt64,
        transactionStartTick: UInt64,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        let threshold: Float = -20
        for neuron in state.neurons {
            let cellIndex = Int(neuron.identity.x)
            if cellIndex < state.cells.count, state.cells[cellIndex].identity1.z < UInt32(FidelityLevel.reducedNeuron.rawValue) { continue }
            let source = Int(neuron.compartmentRange.x)
            guard source < state.compartments.count, source < state.previousVoltages.count else { continue }
            let previous = state.previousVoltages[source]
            let current = state.compartments[source].voltageAndCurrent.x
            state.previousVoltages[source] = current
            guard previous < threshold, current >= threshold else { continue }

            accumulator.metrics.emittedSpikes &+= 1
            state.transactionSpikeSources.append(UInt32(source))
            let population = UInt64(neuron.identity.y) | (UInt64(neuron.identity.z) << 32)
            state.populationSpikeCounts[population, default: 0] &+= 1
            let relativeTick = clampUInt32(absoluteTick - transactionStartTick)
            accumulator.efferentEvents.append(
                GPUEvent(
                    destination: UInt32(source),
                    source: UInt32(source),
                    tick: relativeTick,
                    type: TissueEventKind.emittedSpike.rawValue,
                    amplitude: 1
                )
            )

            applyPostsynapticPlasticity(
                neuron: neuron,
                model: model,
                state: &state
            )
            guard source < state.dynamicOutgoingSynapses.count else { continue }
            for synapseIndex in state.dynamicOutgoingSynapses[source] {
                guard let synapse = safeIndex(synapseIndex, count: state.synapses.count) else { continue }
                let routeIndex = Int(state.synapses[synapse].routing.y)
                let delay: UInt64
                if routeIndex >= 0, routeIndex < model.outgoingRoutes.count {
                    delay = UInt64(model.outgoingRoutes[routeIndex].addressing.w)
                } else {
                    delay = 1
                }
                let event = GPUEvent(
                    destination: synapseIndex,
                    source: UInt32(source),
                    tick: clampUInt32(delay),
                    type: TissueEventKind.synapticRelease.rawValue,
                    amplitude: 1
                )
                state.schedule(event, at: absoluteTick + max(delay, 1))
            }
        }
    }

    func applyPostsynapticPlasticity(
        neuron: GPUCompiledNeuron,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        let start = Int(neuron.compartmentRange.x)
        let end = min(start + Int(neuron.compartmentRange.y), state.dynamicIncomingSynapses.count)
        guard start < end else { return }
        for compartment in start..<end {
            for synapseIndex in state.dynamicIncomingSynapses[compartment] {
                guard let index = safeIndex(synapseIndex, count: state.synapses.count) else { continue }
                var synapse = state.synapses[index]
                let parameterIndex = Int(synapse.routing.w >> 16)
                guard parameterIndex < model.synapseParameters.count else { continue }
                let parameter = model.synapseParameters[parameterIndex]
                guard parameter.typeAndFlags.y & 2 != 0 else { continue }
                synapse.plasticity1.y += 1
                synapse.plasticity0.z += parameter.stdp0.x * synapse.plasticity1.x
                state.synapses[index] = synapse
            }
        }
    }

    func applyNeuromodulatedPlasticity(
        dtMilliseconds: Float,
        modulators: Float4,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        let signal = modulators.x + 0.25 * modulators.y + 0.1 * modulators.z - 0.25 * modulators.w
        guard signal != 0 else { return }
        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let parameterIndex = Int(synapse.routing.w >> 16)
            guard parameterIndex < model.synapseParameters.count else { continue }
            let parameter = model.synapseParameters[parameterIndex]
            guard parameter.typeAndFlags.y & 2 != 0 else { continue }
            let delta = parameter.stdp1.y * signal * synapse.plasticity0.z * dtMilliseconds
            synapse.kinetics.w = min(
                max(synapse.kinetics.w + delta, parameter.stdp1.z),
                parameter.stdp1.w
            )
            state.synapses[index] = synapse
        }
    }
}
