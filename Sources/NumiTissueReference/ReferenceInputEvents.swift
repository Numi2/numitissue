import Foundation
import NumiTissueCore
import NumiTissueModels

extension CPUReferenceTissueBackend {
    func ingestInput(
        _ input: TissueInput,
        context: TransactionContext,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        let transactionTicks = context.targetTime.tick - context.startTime.tick
        for sourceEvent in input.afferentEvents {
            var event = sourceEvent
            let relative = min(UInt64(event.address.z), transactionTicks - 1)
            event.address.z = clampUInt32(relative)
            state.schedule(event, at: context.startTime.tick + relative)
        }
        accumulator.directNeuromodulator += input.neuromodulators
    }

    func runFastQuantum(
        at absoluteTick: UInt64,
        transactionStartTick: UInt64,
        input: TissueInput,
        model: CompiledTissueModel,
        topology: ReferenceStaticTopology,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        let dtMilliseconds = Float(model.configuration.scheduler.fastQuantumMicroseconds) / 1_000
        resetAndApplyInjectedCurrents(input.analogCurrents, state: &state)
        decaySynapticState(model: model, state: &state)
        deliverEvents(
            through: absoluteTick,
            model: model,
            state: &state,
            accumulator: &accumulator
        )
        solveElectrophysiology(
            dtMilliseconds: dtMilliseconds,
            model: model,
            state: &state
        )
        detectAndRouteSpikes(
            at: absoluteTick,
            transactionStartTick: transactionStartTick,
            model: model,
            state: &state,
            accumulator: &accumulator
        )
        applyNeuromodulatedPlasticity(
            dtMilliseconds: dtMilliseconds,
            modulators: input.neuromodulators + accumulator.directNeuromodulator,
            model: model,
            state: &state
        )
        accumulator.metrics.activeCompartments += UInt64(state.compartments.count)
    }

    func resetAndApplyInjectedCurrents(
        _ currents: [AnalogCurrentInput],
        state: inout ReferenceWorkingState
    ) {
        for index in state.compartments.indices {
            state.compartments[index].voltageAndCurrent.y = 0
            state.compartments[index].voltageAndCurrent.z = 0
        }
        for current in currents {
            guard let index = safeIndex(current.compartment, count: state.compartments.count) else { continue }
            state.compartments[index].voltageAndCurrent.y += current.currentNanoamps
        }
    }

    func decaySynapticState(
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let parameterIndex = Int(synapse.routing.w >> 16)
            guard parameterIndex < model.synapseParameters.count else { continue }
            let parameter = model.synapseParameters[parameterIndex]
            let flags = parameter.typeAndFlags.y

            synapse.kinetics.x *= synapse.kinetics.y
            if flags & 1 != 0 {
                let baselineU = parameter.shortTerm.x
                let recoveryDecay = parameter.shortTerm.y
                let facilitationDecay = parameter.shortTerm.z
                synapse.plasticity0.x = facilitationDecay > 0
                    ? baselineU + (synapse.plasticity0.x - baselineU) * facilitationDecay
                    : baselineU
                synapse.plasticity0.y = 1 - (1 - synapse.plasticity0.y) * recoveryDecay
            }
            if flags & 2 != 0 {
                synapse.plasticity1.x *= parameter.stdp0.z
                synapse.plasticity1.y *= parameter.stdp0.w
                synapse.plasticity0.z *= parameter.stdp1.x
            }
            state.synapses[index] = synapse
        }
    }

    func deliverEvents(
        through absoluteTick: UInt64,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        while let next = state.events.nextTick, next <= absoluteTick {
            guard let scheduled = state.events.removeFirst() else { break }
            accumulator.metrics.deliveredEvents &+= 1
            let rawKind = UInt16(truncatingIfNeeded: scheduled.event.address.w)
            let kind = TissueEventKind(rawValue: rawKind) ?? .synapticRelease
            switch kind {
            case .synapticRelease, .emittedSpike:
                deliverPresynapticRelease(
                    scheduled.event,
                    absoluteTick: absoluteTick,
                    model: model,
                    state: &state
                )
            case .injectedCurrentPulse, .extracellularStimulus:
                if let index = safeIndex(
                    scheduled.event.address.x,
                    count: state.compartments.count
                ) {
                    state.compartments[index].voltageAndCurrent.y += scheduled.event.payload.x
                }
            case .neuromodulatorPulse:
                accumulator.directNeuromodulator += scheduled.event.payload
            }
        }
    }

    func deliverPresynapticRelease(
        _ event: GPUEvent,
        absoluteTick: UInt64,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState
    ) {
        guard let index = safeIndex(event.address.x, count: state.synapses.count) else { return }
        var synapse = state.synapses[index]
        let parameterIndex = Int(synapse.routing.w >> 16)
        guard parameterIndex < model.synapseParameters.count else { return }
        let parameter = model.synapseParameters[parameterIndex]
        let flags = parameter.typeAndFlags.y
        var release: Float = 1
        if flags & 1 != 0 {
            let baselineU = parameter.shortTerm.x
            var u = synapse.plasticity0.x
            var x = synapse.plasticity0.y
            u += baselineU * (1 - u)
            release = max(0, u * x)
            x = max(0, x * (1 - u))
            synapse.plasticity0.x = min(max(u, 0), 1)
            synapse.plasticity0.y = min(max(x, 0), 1)
        }
        synapse.kinetics.x += max(event.payload.x, 0) * synapse.kinetics.w * release
        if flags & 2 != 0 {
            synapse.plasticity1.x += 1
            synapse.plasticity0.z -= parameter.stdp0.y * synapse.plasticity1.y
        }
        synapse.routing.z = UInt32(truncatingIfNeeded: absoluteTick)
        state.synapses[index] = synapse
    }

}
