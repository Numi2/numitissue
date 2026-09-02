import Foundation
import NumiTissueCore
import NumiTissueModels

extension ReferenceTissueRuntime {
    func assembleAndSolveNeuron(
        _ neuron: GPUCompiledNeuron,
        dtMilliseconds: Float,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        let start = Int(neuron.compartmentRange.x)
        let end = min(start + Int(neuron.compartmentRange.y), state.compartments.count)
        guard start < end else { return }

        for index in start..<end {
            var compartment = state.compartments[index]
            let capacitance = max(compartment.passive.x, 1e-9)
            let leak = max(compartment.passive.y, 0)
            var diagonal = capacitance / dtMilliseconds + leak
            var rhs = capacitance / dtMilliseconds * compartment.voltageAndCurrent.x +
                leak * compartment.passive.z + compartment.voltageAndCurrent.y

            let mechanismIndex = Int(compartment.mechanism.x)
            if mechanismIndex < model.mechanismSets.count {
                let mechanism = model.mechanismSets[mechanismIndex]
                let channelStart = Int(mechanism.channelRange.x)
                let channelEnd = min(channelStart + Int(mechanism.channelRange.y), model.channelParameters.count)
                for channelIndex in channelStart..<channelEnd {
                    let channel = model.channelParameters[channelIndex]
                    let kind = IonChannelKind(rawValue: UInt16(channel.kindAndPowers.x)) ?? .customOhmic
                    let activation = powi(
                        activationGate(for: kind, in: compartment),
                        Int(channel.kindAndPowers.y)
                    )
                    let inactivation = powi(
                        inactivationGate(for: kind, in: compartment),
                        Int(channel.kindAndPowers.z)
                    )
                    let conductance = max(channel.conductance.x, 0) * capacitance * activation * inactivation
                    diagonal += conductance
                    rhs += conductance * channel.conductance.y
                }
            }

            if index < state.dynamicIncomingSynapses.count {
                for synapseIndex in state.dynamicIncomingSynapses[index] {
                    guard let s = safeIndex(synapseIndex, count: state.synapses.count) else { continue }
                    let synapse = state.synapses[s]
                    let conductance = max(synapse.kinetics.x * synapse.plasticity1.w, 0)
                    diagonal += conductance
                    rhs += conductance * synapse.kinetics.z
                    compartment.voltageAndCurrent.z += conductance *
                        (synapse.kinetics.z - compartment.voltageAndCurrent.x)
                }
            }

            let parentConductance = max(compartment.passive.w, 0)
            if compartment.topology.x != UInt32.max { diagonal += parentConductance }
            let childOffset = Int(compartment.topology.y)
            let childCount = Int(compartment.topology.z)
            if childOffset >= 0, childOffset + childCount <= model.morphologyChildIndices.count {
                for child in model.morphologyChildIndices[childOffset..<(childOffset + childCount)] {
                    if let childIndex = safeIndex(child, count: state.compartments.count) {
                        diagonal += max(state.compartments[childIndex].passive.w, 0)
                    }
                }
            }
            compartment.linearSystem = Float4(diagonal, rhs, -parentConductance, 0)
            state.compartments[index] = compartment
        }

        var order = Array(start..<end)
        order.sort {
            let lhs = state.compartments[$0].topology.w
            let rhs = state.compartments[$1].topology.w
            return lhs == rhs ? $0 > $1 : lhs > rhs
        }
        for index in order {
            let parentRaw = state.compartments[index].topology.x
            guard parentRaw != UInt32.max,
                  let parent = safeIndex(parentRaw, count: state.compartments.count),
                  parent >= start, parent < end else { continue }
            let childDiagonal = max(state.compartments[index].linearSystem.x, 1e-12)
            let conductance = max(state.compartments[index].passive.w, 0)
            state.compartments[parent].linearSystem.x -= conductance * conductance / childDiagonal
            state.compartments[parent].linearSystem.y += conductance *
                state.compartments[index].linearSystem.y / childDiagonal
        }

        let root = order.last(where: { state.compartments[$0].topology.x == UInt32.max }) ?? start
        let rootDiagonal = max(state.compartments[root].linearSystem.x, 1e-12)
        state.compartments[root].linearSystem.w = state.compartments[root].linearSystem.y / rootDiagonal

        order.sort {
            let lhs = state.compartments[$0].topology.w
            let rhs = state.compartments[$1].topology.w
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        for index in order where index != root {
            let parentRaw = state.compartments[index].topology.x
            guard let parent = safeIndex(parentRaw, count: state.compartments.count) else { continue }
            let diagonal = max(state.compartments[index].linearSystem.x, 1e-12)
            let conductance = max(state.compartments[index].passive.w, 0)
            state.compartments[index].linearSystem.w =
                (state.compartments[index].linearSystem.y +
                    conductance * state.compartments[parent].linearSystem.w) / diagonal
        }
        for index in start..<end {
            state.compartments[index].voltageAndCurrent.x = state.compartments[index].linearSystem.w
            updateCalcium(index: index, dtMilliseconds: dtMilliseconds, state: &state)
        }
    }

    @inline(__always)
    func powi(_ value: Float, _ power: Int) -> Float {
        switch power {
        case ...0: return 1
        case 1: return value
        case 2: return value * value
        case 3: return value * value * value
        case 4: let square = value * value; return square * square
        default: return pow(value, Float(power))
        }
    }

    func updateCalcium(
        index: Int,
        dtMilliseconds: Float,
        state: inout ReferenceWorkingState
    ) {
        let voltage = state.compartments[index].voltageAndCurrent.x
        let calciumCurrent = max(voltage + 20, 0) * state.compartments[index].gates0.w * 1e-7
        let baseline: Float = 5e-5
        let tau: Float = 80
        let old = state.compartments[index].voltageAndCurrent.w
        state.compartments[index].voltageAndCurrent.w = max(
            0,
            old + dtMilliseconds * (calciumCurrent - (old - baseline) / tau)
        )
    }

}
