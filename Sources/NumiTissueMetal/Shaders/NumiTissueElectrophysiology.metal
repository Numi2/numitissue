#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_ELECTROPHYSIOLOGY
#define NUMITISSUE_ELECTROPHYSIOLOGY

constant uint NT_MECHANISM_STRIDE = 16u;
constant float NT_DEFAULT_GNA = 0.120f;
constant float NT_DEFAULT_GK = 0.036f;
constant float NT_DEFAULT_GLEAK = 0.0003f;
constant float NT_DEFAULT_ENA = 50.0f;
constant float NT_DEFAULT_EK = -77.0f;
constant float NT_DEFAULT_ELEAK = -54.387f;
constant float NT_SPIKE_THRESHOLD = -20.0f;
constant uint NT_REFRACTORY_TICKS = 80u;
constant uint NT_CHANNEL_PARAMETER_STRIDE = 12u;
constant uint NT_MECHANISM_SET_PARAMETER_STRIDE = 4u;
constant uint NT_CELL_PROGRAM_PARAMETER_STRIDE = 8u;

inline uint nt_mechanism_base(const NTCompartmentState compartment, uint gid) {
    return compartment.mechanismRange.count >= NT_MECHANISM_STRIDE
        ? compartment.mechanismRange.lowerBound
        : gid * NT_MECHANISM_STRIDE;
}

inline float nt_vtrap(float x, float y) {
    const float ratio = x / y;
    const float ratioSquared = ratio * ratio;
    const float expMinusOne = fabs(ratio) < 1.0e-4f
        ? ratio + 0.5f * ratioSquared + ratio * ratioSquared / 6.0f
        : exp(ratio) - 1.0f;
    return fabs(ratio) < 1.0e-4f ? y * (1.0f - 0.5f * ratio) : x / expMinusOne;
}

inline float2 nt_hh_alpha_beta_m(float v) {
    const float alpha = 0.1f * nt_vtrap(-(v + 40.0f), 10.0f);
    const float beta = 4.0f * exp(-(v + 65.0f) / 18.0f);
    return float2(alpha, beta);
}

inline float2 nt_hh_alpha_beta_h(float v) {
    const float alpha = 0.07f * exp(-(v + 65.0f) / 20.0f);
    const float beta = 1.0f / (exp(-(v + 35.0f) / 10.0f) + 1.0f);
    return float2(alpha, beta);
}

inline float2 nt_hh_alpha_beta_n(float v) {
    const float alpha = 0.01f * nt_vtrap(-(v + 55.0f), 10.0f);
    const float beta = 0.125f * exp(-(v + 65.0f) / 80.0f);
    return float2(alpha, beta);
}

inline float nt_rush_larsen(float state, float alpha, float beta, float dt) {
    const float sum = max(alpha + beta, 1.0e-8f);
    const float infinity = alpha / sum;
    return infinity + (state - infinity) * exp(-sum * dt);
}

inline void nt_resolve_hh_parameters(
    const NTCompartmentState compartment,
    device const uint4* channelMetadata,
    device const uint4* mechanismSetMetadata,
    device const float* channelParameters,
    device const float* mechanismSetParameters,
    uint channelCount,
    uint mechanismSetCount,
    thread float& gNa,
    thread float& gK,
    thread float& gLeak,
    thread float& eNa,
    thread float& eK,
    thread float& eLeak,
    thread float& thermalScale
) {
    gNa = NT_DEFAULT_GNA;
    gK = NT_DEFAULT_GK;
    gLeak = NT_DEFAULT_GLEAK;
    eNa = NT_DEFAULT_ENA;
    eK = NT_DEFAULT_EK;
    eLeak = NT_DEFAULT_ELEAK;
    thermalScale = 1.0f;

    const uint mechanismSetIndex = compartment.flags & 0xFFFFu;
    if (mechanismSetIndex >= mechanismSetCount) { return; }
    const uint4 range = mechanismSetMetadata[mechanismSetIndex];
    const uint thermalBase = mechanismSetIndex * NT_MECHANISM_SET_PARAMETER_STRIDE;
    thermalScale = max(mechanismSetParameters[thermalBase + 2u], 1.0e-4f);
    const uint upper = min(range.x + range.y, channelCount);
    for (uint channelIndex = range.x; channelIndex < upper; ++channelIndex) {
        const uint kind = channelMetadata[channelIndex].x & 0xFFFFu;
        const uint base = channelIndex * NT_CHANNEL_PARAMETER_STRIDE;
        const float conductance = max(channelParameters[base], 0.0f);
        const float reversal = channelParameters[base + 1u];
        switch (kind) {
            case 0u: gLeak = conductance; eLeak = reversal; break;
            case 1u: gNa = conductance; eNa = reversal; break;
            case 2u: gK = conductance; eK = reversal; break;
            default: break;
        }
    }
}

kernel void nt_update_channels(
    constant NTResources& r [[buffer(0)]],
    device const uint4* channelMetadata [[buffer(1)]],
    device const uint4* mechanismSetMetadata [[buffer(2)]],
    device const float* channelParameters [[buffer(3)]],
    device const float* mechanismSetParameters [[buffer(4)]],
    device const float* cellProgramParameters [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    (void)cellProgramParameters;
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    const uint base = nt_mechanism_base(compartment, gid);
    if (base + NT_MECHANISM_STRIDE > r.header->compartmentCount * NT_MECHANISM_STRIDE) { return; }
    const float voltage = compartment.voltagePreviousCapacitanceAxial.x;

    float modelGNa, modelGK, modelGLeak, modelENa, modelEK, modelELeak, thermalScale;
    nt_resolve_hh_parameters(
        compartment,
        channelMetadata,
        mechanismSetMetadata,
        channelParameters,
        mechanismSetParameters,
        r.header->reserved3.z,
        r.header->reserved3.w,
        modelGNa,
        modelGK,
        modelGLeak,
        modelENa,
        modelEK,
        modelELeak,
        thermalScale
    );
    const float dt = max(r.header->dtMilliseconds * thermalScale, 1.0e-6f);

    float m = r.mechanismState[base + 0u];
    float h = r.mechanismState[base + 1u];
    float n = r.mechanismState[base + 2u];
    if (!(m >= 0.0f && m <= 1.0f)) { m = 0.05f; }
    if (!(h >= 0.0f && h <= 1.0f)) { h = 0.60f; }
    if (!(n >= 0.0f && n <= 1.0f)) { n = 0.32f; }

    const float2 mRates = nt_hh_alpha_beta_m(voltage);
    const float2 hRates = nt_hh_alpha_beta_h(voltage);
    const float2 nRates = nt_hh_alpha_beta_n(voltage);
    m = nt_rush_larsen(m, mRates.x, mRates.y, dt);
    h = nt_rush_larsen(h, hRates.x, hRates.y, dt);
    n = nt_rush_larsen(n, nRates.x, nRates.y, dt);

    const float gNaMax = r.mechanismState[base + 4u] > 0.0f ? r.mechanismState[base + 4u] : modelGNa;
    const float gKMax = r.mechanismState[base + 5u] > 0.0f ? r.mechanismState[base + 5u] : modelGK;
    const float gLeak = r.mechanismState[base + 6u] > 0.0f ? r.mechanismState[base + 6u] : modelGLeak;
    const float eNa = isfinite(r.mechanismState[base + 7u]) && r.mechanismState[base + 7u] != 0.0f ? r.mechanismState[base + 7u] : modelENa;
    const float eK = isfinite(r.mechanismState[base + 8u]) && r.mechanismState[base + 8u] != 0.0f ? r.mechanismState[base + 8u] : modelEK;
    const float eLeak = isfinite(r.mechanismState[base + 9u]) && r.mechanismState[base + 9u] != 0.0f ? r.mechanismState[base + 9u] : modelELeak;

    const float gNa = gNaMax * m * m * m * h;
    const float gK = gKMax * n * n * n * n;
    const float totalConductance = gNa + gK + gLeak;
    const float reversalSource = gNa * eNa + gK * eK + gLeak * eLeak;

    r.mechanismState[base + 0u] = nt_clamp01(m);
    r.mechanismState[base + 1u] = nt_clamp01(h);
    r.mechanismState[base + 2u] = nt_clamp01(n);
    r.mechanismState[base + 10u] = totalConductance;
    r.mechanismState[base + 11u] = reversalSource;
}

kernel void nt_assemble_cable_system(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    const uint base = nt_mechanism_base(compartment, gid);
    const float dt = max(r.header->dtMilliseconds, 1.0e-6f);
    const float voltage = compartment.voltagePreviousCapacitanceAxial.x;
    const float capacitance = max(compartment.voltagePreviousCapacitanceAxial.z, 1.0e-8f);
    const float axial = compartment.parentIndex == NT_INVALID_INDEX ? 0.0f : max(compartment.voltagePreviousCapacitanceAxial.w, 0.0f);
    const float totalConductance = max(r.mechanismState[base + 10u], 0.0f);
    const float reversalSource = r.mechanismState[base + 11u];
    const float applied = compartment.injectedSynapticCalciumSodium.x - compartment.injectedSynapticCalciumSodium.y;

    r.mechanismState[base + 12u] = capacitance / dt + totalConductance + axial;
    r.mechanismState[base + 13u] = capacitance / dt * voltage + reversalSource + applied;
    r.mechanismState[base + 14u] = voltage;
    compartment.voltagePreviousCapacitanceAxial.y = voltage;
}

kernel void nt_eliminate_cable_levels(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& child = r.compartments[gid];
    const uint depth = (child.flags >> 16u) & 0xFFu;
    if (depth != r.header->reserved2.x || child.parentIndex == NT_INVALID_INDEX || child.parentIndex >= r.header->compartmentCount) { return; }

    const uint childBase = nt_mechanism_base(child, gid);
    const NTCompartmentState parent = r.compartments[child.parentIndex];
    const uint parentBase = nt_mechanism_base(parent, child.parentIndex);
    const float diagonal = max(r.mechanismState[childBase + 12u], 1.0e-12f);
    const float axial = max(child.voltagePreviousCapacitanceAxial.w, 0.0f);
    const float diagonalContribution = -(axial * axial) / diagonal;
    const float rhsContribution = axial * r.mechanismState[childBase + 13u] / diagonal;

    device atomic_float* parentDiagonal = reinterpret_cast<device atomic_float*>(&r.mechanismState[parentBase + 12u]);
    device atomic_float* parentRHS = reinterpret_cast<device atomic_float*>(&r.mechanismState[parentBase + 13u]);
    atomic_fetch_add_explicit(parentDiagonal, diagonalContribution, memory_order_relaxed);
    atomic_fetch_add_explicit(parentRHS, rhsContribution, memory_order_relaxed);
}

kernel void nt_solve_cable_roots(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    if (compartment.parentIndex != NT_INVALID_INDEX) { return; }
    const uint base = nt_mechanism_base(compartment, gid);
    const float diagonal = max(r.mechanismState[base + 12u], 1.0e-12f);
    r.mechanismState[base + 14u] = r.mechanismState[base + 13u] / diagonal;
}

kernel void nt_back_substitute_cable_levels(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& child = r.compartments[gid];
    const uint depth = (child.flags >> 16u) & 0xFFu;
    if (depth != r.header->reserved2.x || child.parentIndex == NT_INVALID_INDEX || child.parentIndex >= r.header->compartmentCount) { return; }
    const uint base = nt_mechanism_base(child, gid);
    const NTCompartmentState parent = r.compartments[child.parentIndex];
    const uint parentBase = nt_mechanism_base(parent, child.parentIndex);
    const float diagonal = max(r.mechanismState[base + 12u], 1.0e-12f);
    const float axial = max(child.voltagePreviousCapacitanceAxial.w, 0.0f);
    r.mechanismState[base + 14u] = (r.mechanismState[base + 13u] + axial * r.mechanismState[parentBase + 14u]) / diagonal;
}

kernel void nt_detect_spikes(
    constant NTResources& r [[buffer(0)]],
    device const float* cellProgramParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    const uint base = nt_mechanism_base(compartment, gid);
    const float previous = compartment.voltagePreviousCapacitanceAxial.x;
    const float voltage = r.mechanismState[base + 14u];
    compartment.voltagePreviousCapacitanceAxial.y = previous;
    compartment.voltagePreviousCapacitanceAxial.x = voltage;

    float threshold = NT_SPIKE_THRESHOLD;
    if (compartment.neuronIndex < r.header->cellCount) {
        const uint program = r.cells[compartment.neuronIndex].typeAndDevelopment & 0xFFFFu;
        const float candidate = cellProgramParameters[program * NT_CELL_PROGRAM_PARAMETER_STRIDE + 7u];
        if (isfinite(candidate) && candidate < 100.0f && candidate > -150.0f) { threshold = candidate; }
    }

    const ulong currentTick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
    const ulong refractoryUntil = nt_u64(compartment.refractoryTickLo, compartment.refractoryTickHi);
    const bool crossing = previous < threshold && voltage >= threshold;
    if (!crossing || currentTick < refractoryUntil) { return; }

    const float denominator = max(voltage - previous, 1.0e-6f);
    const float fraction = clamp((threshold - previous) / denominator, 0.0f, 1.0f);
    const ulong startTick = nt_u64(r.header->phaseStartTickLo, r.header->phaseStartTickHi);
    const ulong crossingTick = startTick + ulong(fraction * float(max(r.header->fastQuantumTicks, 1u)));
    const uint slot = atomic_fetch_add_explicit(&r.counters->generatedSpikesLo, 1u, memory_order_relaxed);
    if (slot < r.header->eventCapacity) {
        const uint2 tick = nt_split_u64(crossingTick);
        r.outgoingEvents[slot] = NTEvent{
            tick.x, tick.y,
            compartment.idLo, compartment.idHi,
            compartment.idLo, compartment.idHi,
            0u, slot,
            1.0f, 0.0f, 0.0f, 0.0f
        };
    }
    const uint2 refractory = nt_split_u64(crossingTick + ulong(NT_REFRACTORY_TICKS));
    compartment.refractoryTickLo = refractory.x;
    compartment.refractoryTickHi = refractory.y;
    r.mechanismState[base + 15u] = 1.0f;
}

#endif
