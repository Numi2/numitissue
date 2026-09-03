#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_EVENTS
#define NUMITISSUE_EVENTS

constant uint NT_EVENT_BUCKETS = 4096u;
constant uint NT_EVENT_OVERFLOW_CODE = 4u;
constant uint NT_EVENT_DELIVERED_FLAG = 0x80000000u;
constant uint NT_CURRENT_RESET_LOCK = 0x80000000u;
constant uint NT_SYNAPSE_PARAMETER_STRIDE = 16u;

inline uint nt_event_bucket(constant NTResources& r, ulong arrivalTick) {
    const ulong width = max(ulong(r.header->routingBlockTicks), 1ul);
    return uint((arrivalTick / width) % ulong(NT_EVENT_BUCKETS));
}

inline bool nt_schedule_local_event(constant NTResources& r, NTEvent event) {
    const ulong arrival = nt_u64(event.arrivalTickLo, event.arrivalTickHi);
    const uint bucket = nt_event_bucket(r, arrival);
    const uint bucketCapacity = max(r.header->eventCapacity / NT_EVENT_BUCKETS, 1u);
    const uint slot = atomic_fetch_add_explicit(&r.eventBucketCounts[bucket], 1u, memory_order_relaxed);
    if (slot >= bucketCapacity) {
        atomic_fetch_sub_explicit(&r.eventBucketCounts[bucket], 1u, memory_order_relaxed);
        nt_append_validation(r, NT_EVENT_OVERFLOW_CODE, 1u, uint2(0u), float(slot), bucket);
        return false;
    }
    r.localEvents[bucket * bucketCapacity + slot] = event;
    return true;
}

inline uint nt_synapse_parameter_index(const NTSynapseState synapse) {
    return synapse.parameterAndFlags & 0xFFFFu;
}

inline float nt_synapse_parameter(
    device const float* parameters,
    uint parameterCount,
    uint parameterIndex,
    uint component,
    float fallback
) {
    if (parameterIndex >= parameterCount || component >= NT_SYNAPSE_PARAMETER_STRIDE) { return fallback; }
    const float candidate = parameters[parameterIndex * NT_SYNAPSE_PARAMETER_STRIDE + component];
    return isfinite(candidate) ? candidate : fallback;
}

inline void nt_apply_event_to_synapse(
    constant NTResources& r,
    device const float* synapseParameters,
    uint parameterCount,
    NTEvent event
) {
    const ulong destination = nt_u64(event.destinationLo, event.destinationHi);
    const uint synapseIndex = uint(destination);
    if (synapseIndex >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[synapseIndex];
    const uint parameter = nt_synapse_parameter_index(synapse);
    float utilization = synapse.weightConductanceUtilizationResources.z;
    if (!(utilization > 0.0f && utilization <= 1.0f)) {
        utilization = clamp(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 4u, 0.2f), 0.0f, 1.0f);
    }
    const float resources = nt_clamp01(synapse.weightConductanceUtilizationResources.w);
    const float release = max(event.amplitude, 0.0f) * utilization * resources;
    float weight = synapse.weightConductanceUtilizationResources.x;
    if (!(weight > 0.0f)) {
        weight = max(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 3u, 0.0f), 0.0f);
        synapse.weightConductanceUtilizationResources.x = weight;
    }
    synapse.weightConductanceUtilizationResources.y += weight * release;
    synapse.weightConductanceUtilizationResources.w = max(0.0f, resources - utilization * resources);

    const float facilitationDecay = clamp(
        nt_synapse_parameter(synapseParameters, parameterCount, parameter, 6u, 0.0f),
        0.0f,
        1.0f
    );
    synapse.weightConductanceUtilizationResources.z = facilitationDecay > 0.0f
        ? nt_clamp01(utilization + (1.0f - utilization) * (1.0f - facilitationDecay))
        : utilization;

    const float positiveAmplitude = nt_synapse_parameter(synapseParameters, parameterCount, parameter, 8u, 1.0f);
    synapse.prePostEligibilityConsolidation.x += 1.0f;
    synapse.prePostEligibilityConsolidation.z += positiveAmplitude * max(synapse.prePostEligibilityConsolidation.y, 1.0f);
    synapse.lastEventTickLo = event.arrivalTickLo;
    synapse.lastEventTickHi = event.arrivalTickHi;
}

kernel void nt_ingest_input_events(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    const uint inputCount = r.header->reserved0.x;
    const uint stimulusCount = r.header->reserved0.y;
    if (gid < inputCount) {
        nt_schedule_local_event(r, r.inputEvents[gid]);
    }
    if (gid < stimulusCount) {
        nt_schedule_local_event(r, r.stimuli[gid]);
    }
}

kernel void nt_deliver_events(
    constant NTResources& r [[buffer(0)]],
    device const float* synapseParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    const ulong startTick = nt_u64(r.header->phaseStartTickLo, r.header->phaseStartTickHi);
    const ulong endTick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
    const uint bucket = nt_event_bucket(r, startTick);
    const uint count = atomic_load_explicit(&r.eventBucketCounts[bucket], memory_order_acquire);
    const uint bucketCapacity = max(r.header->eventCapacity / NT_EVENT_BUCKETS, 1u);
    if (gid >= min(count, bucketCapacity)) { return; }

    device NTEvent& stored = r.localEvents[bucket * bucketCapacity + gid];
    const ulong arrival = nt_u64(stored.arrivalTickLo, stored.arrivalTickHi);
    if (arrival >= startTick && arrival < endTick && (stored.kindAndFlags & NT_EVENT_DELIVERED_FLAG) == 0u) {
        NTEvent event = stored;
        stored.kindAndFlags |= NT_EVENT_DELIVERED_FLAG;
        nt_apply_event_to_synapse(r, synapseParameters, r.header->reserved2.y, event);
        nt_atomic_add_u64(&r.counters->deliveredEventsLo, &r.counters->deliveredEventsHi, 1u);
    }

    threadgroup_barrier(mem_flags::mem_device);
    if (gid == 0u && endTick > startTick) {
        atomic_store_explicit(&r.eventBucketCounts[bucket], 0u, memory_order_release);
    }
}

inline void nt_prepare_synaptic_accumulator(device NTCompartmentState& compartment, uint tickToken) {
    device atomic_uint* stamp = reinterpret_cast<device atomic_uint*>(&compartment.reserved);
    while (true) {
        uint observed = atomic_load_explicit(stamp, memory_order_acquire);
        if ((observed & ~NT_CURRENT_RESET_LOCK) == tickToken && (observed & NT_CURRENT_RESET_LOCK) == 0u) { return; }
        if ((observed & NT_CURRENT_RESET_LOCK) != 0u) { continue; }
        uint expected = observed;
        if (atomic_compare_exchange_weak_explicit(stamp, &expected, tickToken | NT_CURRENT_RESET_LOCK, memory_order_acq_rel, memory_order_relaxed)) {
            compartment.injectedSynapticCalciumSodium.y = 0.0f;
            atomic_store_explicit(stamp, tickToken, memory_order_release);
            return;
        }
    }
}

kernel void nt_decay_synapses(
    constant NTResources& r [[buffer(0)]],
    device const float* synapseParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    const uint target = synapse.targetCompartmentIndex;
    if (target >= r.header->compartmentCount) { return; }

    const uint parameter = nt_synapse_parameter_index(synapse);
    const uint parameterCount = r.header->reserved2.y;
    const float decayMilliseconds = max(
        nt_synapse_parameter(synapseParameters, parameterCount, parameter, 1u, 5.0f),
        1.0e-6f
    );
    const float reversal = nt_synapse_parameter(synapseParameters, parameterCount, parameter, 2u, 0.0f);
    const float dt = max(r.header->dtMilliseconds, 1.0e-6f);
    synapse.weightConductanceUtilizationResources.y *= exp(-dt / decayMilliseconds);

    const float baseQuantumMilliseconds = max(float(r.header->fastQuantumTicks) * NT_TICK_MILLISECONDS, NT_TICK_MILLISECONDS);
    const float quantumRatio = dt / baseQuantumMilliseconds;
    const float recoveryDecay = clamp(
        nt_synapse_parameter(synapseParameters, parameterCount, parameter, 5u, exp(-baseQuantumMilliseconds / 800.0f)),
        0.0f,
        1.0f
    );
    const float facilitationDecay = clamp(
        nt_synapse_parameter(synapseParameters, parameterCount, parameter, 6u, 0.0f),
        0.0f,
        1.0f
    );
    const float preDecay = clamp(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 10u, exp(-baseQuantumMilliseconds / 20.0f)), 0.0f, 1.0f);
    const float postDecay = clamp(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 11u, exp(-baseQuantumMilliseconds / 20.0f)), 0.0f, 1.0f);
    const float eligibilityDecay = clamp(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 12u, exp(-baseQuantumMilliseconds / 1000.0f)), 0.0f, 1.0f);

    synapse.prePostEligibilityConsolidation.x *= pow(preDecay, quantumRatio);
    synapse.prePostEligibilityConsolidation.y *= pow(postDecay, quantumRatio);
    synapse.prePostEligibilityConsolidation.z *= pow(eligibilityDecay, quantumRatio);
    if (facilitationDecay > 0.0f) {
        const float baselineUtilization = clamp(nt_synapse_parameter(synapseParameters, parameterCount, parameter, 4u, 0.2f), 0.0f, 1.0f);
        const float uDecay = pow(facilitationDecay, quantumRatio);
        synapse.weightConductanceUtilizationResources.z = baselineUtilization +
            (synapse.weightConductanceUtilizationResources.z - baselineUtilization) * uDecay;
    }
    const float resources = nt_clamp01(synapse.weightConductanceUtilizationResources.w);
    const float recovered = 1.0f - (1.0f - resources) * pow(recoveryDecay, quantumRatio);
    synapse.weightConductanceUtilizationResources.w = nt_clamp01(recovered);

    device NTCompartmentState& compartment = r.compartments[target];
    const uint tickToken = r.header->phaseStartTickLo & ~NT_CURRENT_RESET_LOCK;
    nt_prepare_synaptic_accumulator(compartment, tickToken);
    const float voltage = compartment.voltagePreviousCapacitanceAxial.x;
    const float current = synapse.weightConductanceUtilizationResources.y * (voltage - reversal);
    device atomic_float* accumulator = reinterpret_cast<device atomic_float*>(&compartment.injectedSynapticCalciumSodium.y);
    atomic_fetch_add_explicit(accumulator, current, memory_order_relaxed);
}

/// SourceRouteIndex is the source compartment index in the packed runtime representation.
/// The compiler emits source-contiguous synapses so this kernel performs one coherent read per synapse.
kernel void nt_route_spikes(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    const uint source = synapse.sourceRouteIndex;
    if (source >= r.header->compartmentCount) { return; }
    const uint sourceBase = nt_mechanism_base(r.compartments[source], source);
    if (r.mechanismState[sourceBase + 15u] <= 0.0f) { return; }

    const ulong spikeTick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
    const ulong arrival = spikeTick + ulong(synapse.delayTicks);
    const uint2 split = nt_split_u64(arrival);
    NTEvent event;
    event.arrivalTickLo = split.x;
    event.arrivalTickHi = split.y;
    event.sourceLo = r.compartments[source].idLo;
    event.sourceHi = r.compartments[source].idHi;
    event.destinationLo = gid;
    event.destinationHi = 0u;
    event.kindAndFlags = 0u;
    event.sequence = gid;
    event.amplitude = 1.0f;
    event.reserved0 = 0.0f;
    event.reserved1 = 0.0f;
    event.reserved2 = 0.0f;
    if (nt_schedule_local_event(r, event)) {
        nt_atomic_add_u64(&r.counters->routedEventsLo, &r.counters->routedEventsHi, 1u);
    }
}

#endif
