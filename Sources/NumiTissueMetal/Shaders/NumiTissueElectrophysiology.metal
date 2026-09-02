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

inline float nt_vtrap(float x, float y) {
    const float ratio = x / y;
    return fabs(ratio) < 1.0e-4f ? y * (1.0f - 0.5f * ratio) : x / expm1(ratio);
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

kernel void nt_update_channels(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    const uint base = gid * NT_MECHANISM_STRIDE;
    const float voltage = compartment.voltagePreviousCapacitanceAxial.x;
    const float dt = max(r.header->dtMilliseconds, 1.0e-6f);

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

    const float gNaMax = r.mechanismState[base + 4u] > 0.0f ? r.mechanismState[base + 4u] : NT_DEFAULT_GNA;
    const float gKMax = r.mechanismState[base + 5u] > 0.0f ? r.mechanismState[base + 5u] : NT_DEFAULT_GK;
    const float gLeak = r.mechanismState[base + 6u] > 0.0f ? r.mechanismState[base + 6u] : NT_DEFAULT_GLEAK;
    const float eNa = isfinite(r.mechanismState[base + 7u]) && r.mechanismState[base + 7u] != 0.0f ? r.mechanismState[base + 7u] : NT_DEFAULT_ENA;
    const float eK = isfinite(r.mechanismState[base + 8u]) && r.mechanismState[base + 8u] != 0.0f ? r.mechanismState[base + 8u] : NT_DEFAULT_EK;
    const float eLeak = isfinite(r.mechanismState[base + 9u]) && r.mechanismState[base + 9u] != 0.0f ? r.mechanismState[base + 9u] : NT_DEFAULT_ELEAK;

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
    const uint base = gid * NT_MECHANISM_STRIDE;
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
    atomic_fetch_add_explicit(&r.counters->activeCompartments, 1u, memory_order_relaxed);
}

/// Exact Hines elimination for all compartments whose encoded depth equals header.reserved2.x.
/// Siblings atomically accumulate independent Schur contributions into their parent.
kernel void nt_eliminate_cable_levels(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& child = r.compartments[gid];
    const uint depth = (child.flags >> 16u) & 0xFFu;
    if (depth != r.header->reserved2.x || child.parentIndex == NT_INVALID_INDEX || child.parentIndex >= r.header->compartmentCount) { return; }

    const uint childBase = gid * NT_MECHANISM_STRIDE;
    const uint parentBase = child.parentIndex * NT_MECHANISM_STRIDE;
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
    const uint base = gid * NT_MECHANISM_STRIDE;
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
    const uint base = gid * NT_MECHANISM_STRIDE;
    const uint parentBase = child.parentIndex * NT_MECHANISM_STRIDE;
    const float diagonal = max(r.mechanismState[base + 12u], 1.0e-12f);
    const float axial = max(child.voltagePreviousCapacitanceAxial.w, 0.0f);
    r.mechanismState[base + 14u] = (r.mechanismState[base + 13u] + axial * r.mechanismState[parentBase + 14u]) / diagonal;
}

kernel void nt_detect_spikes(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->compartmentCount) { return; }
    device NTCompartmentState& compartment = r.compartments[gid];
    const uint base = gid * NT_MECHANISM_STRIDE;
    const float previous = compartment.voltagePreviousCapacitanceAxial.x;
    const float voltage = r.mechanismState[base + 14u];
    compartment.voltagePreviousCapacitanceAxial.y = previous;
    compartment.voltagePreviousCapacitanceAxial.x = voltage;

    const ulong currentTick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
    const ulong refractoryUntil = nt_u64(compartment.refractoryTickLo, compartment.refractoryTickHi);
    const bool crossing = previous < NT_SPIKE_THRESHOLD && voltage >= NT_SPIKE_THRESHOLD;
    if (!crossing || currentTick < refractoryUntil) { return; }

    const float denominator = max(voltage - previous, 1.0e-6f);
    const float fraction = clamp((NT_SPIKE_THRESHOLD - previous) / denominator, 0.0f, 1.0f);
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
