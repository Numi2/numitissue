import Foundation
import NumiTissueCore
import NumiTissueModels

extension CPUReferenceTissueBackend {
    func solveElectrophysiology(
        dtMilliseconds: Float,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        guard dtMilliseconds > 0 else { return }
        for index in state.compartments.indices {
            updateGates(
                compartmentIndex: index,
                dtMilliseconds: dtMilliseconds,
                model: model,
                state: &state
            )
        }
        for neuron in state.neurons {
            let cellIndex = Int(neuron.identity.x)
            if cellIndex < state.cells.count, state.cells[cellIndex].identity1.z < UInt32(FidelityLevel.reducedNeuron.rawValue) { continue }
            assembleAndSolveNeuron(
                neuron,
                dtMilliseconds: dtMilliseconds,
                model: model,
                state: &state
            )
        }
    }

    func updateGates(
        compartmentIndex: Int,
        dtMilliseconds: Float,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        var compartment = state.compartments[compartmentIndex]
        let mechanismIndex = Int(compartment.mechanism.x)
        guard mechanismIndex >= 0, mechanismIndex < model.mechanismSets.count else { return }
        let mechanism = model.mechanismSets[mechanismIndex]
        let channelStart = Int(mechanism.channelRange.x)
        let channelEnd = min(channelStart + Int(mechanism.channelRange.y), model.channelParameters.count)
        let voltage = compartment.voltageAndCurrent.x
        let thermalScale = max(mechanism.thermal.z, 1e-4)

        for channelIndex in channelStart..<channelEnd {
            let channel = model.channelParameters[channelIndex]
            let kind = IonChannelKind(rawValue: UInt16(channel.kindAndPowers.x)) ?? .customOhmic
            let activationKind = GateKineticsKind(
                rawValue: UInt16(channel.kindAndPowers.w & 0xffff)
            ) ?? .none
            let inactivationKind = GateKineticsKind(
                rawValue: UInt16(channel.kindAndPowers.w >> 16)
            ) ?? .none
            if channel.kindAndPowers.y > 0 {
                let current = activationGate(for: kind, in: compartment)
                let next = rushLarsenGate(
                    current: current,
                    voltage: voltage,
                    calcium: compartment.voltageAndCurrent.w,
                    kind: activationKind,
                    parameters: channel.activation,
                    dtMilliseconds: dtMilliseconds,
                    thermalScale: thermalScale
                )
                setActivationGate(next, for: kind, in: &compartment)
            }
            if channel.kindAndPowers.z > 0 {
                let current = inactivationGate(for: kind, in: compartment)
                let next = rushLarsenGate(
                    current: current,
                    voltage: voltage,
                    calcium: compartment.voltageAndCurrent.w,
                    kind: inactivationKind,
                    parameters: channel.inactivation,
                    dtMilliseconds: dtMilliseconds,
                    thermalScale: thermalScale
                )
                setInactivationGate(next, for: kind, in: &compartment)
            }
        }
        state.compartments[compartmentIndex] = compartment
    }

    func rushLarsenGate(
        current: Float,
        voltage: Float,
        calcium: Float,
        kind: GateKineticsKind,
        parameters: Float4,
        dtMilliseconds: Float,
        thermalScale: Float
    ) -> Float {
        let steady: Float
        let tau: Float
        let shifted = voltage + 65
        switch kind {
        case .none:
            return min(max(current, 0), 1)
        case .hodgkinHuxleyM:
            let alpha = 0.1 * vtrap(25 - shifted, 10)
            let beta = 4 * exp(-shifted / 18)
            steady = alpha / max(alpha + beta, 1e-12)
            tau = 1 / max(alpha + beta, 1e-12)
        case .hodgkinHuxleyH:
            let alpha = 0.07 * exp(-shifted / 20)
            let beta = 1 / (exp((30 - shifted) / 10) + 1)
            steady = alpha / max(alpha + beta, 1e-12)
            tau = 1 / max(alpha + beta, 1e-12)
        case .hodgkinHuxleyN:
            let alpha = 0.01 * vtrap(10 - shifted, 10)
            let beta = 0.125 * exp(-shifted / 80)
            steady = alpha / max(alpha + beta, 1e-12)
            tau = 1 / max(alpha + beta, 1e-12)
        case .sigmoidTau:
            let vHalf = parameters.x
            let slope = abs(parameters.y) > 1e-6 ? parameters.y : 6
            steady = 1 / (1 + exp(-(voltage - vHalf) / slope))
            tau = max(parameters.z + parameters.w * steady * (1 - steady), 1e-4)
        case .calciumHill:
            let half = max(parameters.x, 1e-8)
            let power = max(parameters.y, 1)
            let cp = pow(max(calcium, 0), power)
            steady = cp / max(cp + pow(half, power), 1e-12)
            tau = max(parameters.z, 0.1)
        }
        let decay = exp(-dtMilliseconds * thermalScale / max(tau, 1e-5))
        return min(max(steady + (current - steady) * decay, 0), 1)
    }

    @inline(__always)
    func vtrap(_ x: Float, _ y: Float) -> Float {
        let ratio = x / y
        if abs(ratio) < 1e-4 { return y * (1 - ratio / 2) }
        return x / (exp(ratio) - 1)
    }

    func activationGate(for kind: IonChannelKind, in c: GPUCompartmentState) -> Float {
        switch kind {
        case .fastSodium: return c.gates0.x
        case .delayedRectifierPotassium: return c.gates0.z
        case .highVoltageCalcium: return c.gates0.w
        case .calciumActivatedPotassium: return c.gates1.x
        case .hcn: return c.gates1.y
        case .mCurrent: return c.gates1.z
        case .leak, .customOhmic: return 1
        }
    }

    func inactivationGate(for kind: IonChannelKind, in c: GPUCompartmentState) -> Float {
        kind == .fastSodium ? c.gates0.y : c.gates1.w
    }

    func setActivationGate(_ value: Float, for kind: IonChannelKind, in c: inout GPUCompartmentState) {
        switch kind {
        case .fastSodium: c.gates0.x = value
        case .delayedRectifierPotassium: c.gates0.z = value
        case .highVoltageCalcium: c.gates0.w = value
        case .calciumActivatedPotassium: c.gates1.x = value
        case .hcn: c.gates1.y = value
        case .mCurrent: c.gates1.z = value
        case .leak, .customOhmic: break
        }
    }

    func setInactivationGate(_ value: Float, for kind: IonChannelKind, in c: inout GPUCompartmentState) {
        if kind == .fastSodium { c.gates0.y = value } else { c.gates1.w = value }
    }

}
