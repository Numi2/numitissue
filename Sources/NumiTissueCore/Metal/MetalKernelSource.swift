import Foundation

public enum NTMetalKernelSource {
    public static let common = #"""
#include <metal_stdlib>
using namespace metal;

constant uint NT_INVALID_INDEX = 0xffffffffu;
constant float NT_PI = 3.14159265358979323846f;
constant float NT_INV_UINT32 = 2.3283064365386963e-10f;

struct NTWorldConstants {
    uint4 abiAndFlags;
    uint4 counts0;
    uint4 counts1;
    uint4 clock0;
    uint4 clock1;
    float4 geometry;
    float4 voltageAndTolerance;
    uint4 seed;
};

struct NTTileHeader {
    uint2 id;
    int4 coordinateAndFidelity;
    uint2 cellRange;
    uint2 compartmentRange;
    uint2 synapseRange;
    uint2 microdomainRange;
    uint4 fieldAndFlags;
    float4 scores;
};

struct NTCell {
    uint2 id;
    uint2 lineage;
    uint4 tileAndClass;
    float4 positionAndAge;
    float4 velocityAndCycle;
    float4 radiiAndDifferentiation;
    float4 orientationAndEnergy;
    float4 stressDamageFlags;
    uint4 expressionAndFlags;
};

struct NTCompartment {
    uint2 id;
    uint2 cell;
    uint4 topology;
    float4 positionAndLength;
    float4 geometryAndVoltage;
    float4 ions0;
    float4 current0;
    float4 conductance0;
    uint4 spikeState;
    float4 gates0;
    float4 gates1;
    float4 gates2;
};

struct NTSynapse {
    uint2 id;
    uint4 topology;
    float4 kinetics0;
    float4 kinetics1;
    float4 plasticity0;
    float4 plasticity1;
    uint4 lastEventAndFlags;
};

struct NTEvent {
    uint2 deliveryTick;
    uint2 source;
    uint2 destination;
    uint2 route;
    float4 payload;
    uint4 kindAndSequence;
};

struct NTRoute {
    uint2 id;
    uint4 topology;
    float4 dynamics;
    uint2 destinationTile;
    uint2 reserved;
};

struct NTMechanismSet {
    float4 conductance0;
    float4 conductance1;
    float4 conductance2;
    float4 reversal0;
    float4 extracellular0;
    float4 calcium0;
    float4 temperature0;
};

struct NTSynapseKinetics {
    float4 timeAndReversal;
    float4 releaseAndResources;
};

struct NTPlasticityParameters {
    float4 traceTimes;
    float4 learning0;
    float4 weightBounds;
    float4 structural0;
    float4 homeostasis0;
};

struct NTValidationCounters {
    atomic_uint4 fatalAndErrorCounts;
    atomic_uint4 boundsCounts;
    atomic_uint4 eventCounts;
    atomic_uint4 floatingPointCounts;
    float4 extrema0;
    float4 extrema1;
};

struct NTDispatchArguments {
    uint3 threadgroupsPerGrid;
    uint padding;
};

inline ulong nt_u64(uint2 value) {
    return (ulong(value.y) << 32) | ulong(value.x);
}

inline uint2 nt_u32x2(ulong value) {
    return uint2(uint(value), uint(value >> 32));
}

inline float nt_uniform01(uint value) {
    return (float(value) + 0.5f) * NT_INV_UINT32;
}

inline uint4 nt_philox_round(uint4 counter, uint2 key) {
    constexpr uint M0 = 0xD2511F53u;
    constexpr uint M1 = 0xCD9E8D57u;
    uint hi0 = mulhi(M0, counter.x);
    uint lo0 = M0 * counter.x;
    uint hi1 = mulhi(M1, counter.z);
    uint lo1 = M1 * counter.z;
    return uint4(hi1 ^ counter.y ^ key.x, lo1, hi0 ^ counter.w ^ key.y, lo0);
}

inline uint4 nt_philox(uint4 counter, uint2 key) {
    constexpr uint W0 = 0x9E3779B9u;
    constexpr uint W1 = 0xBB67AE85u;
    for (uint round = 0; round < 10; ++round) {
        counter = nt_philox_round(counter, key);
        key += uint2(W0, W1);
    }
    return counter;
}

inline void nt_atomic_add_float(device atomic_uint* address, float value) {
    uint expected = atomic_load_explicit(address, memory_order_relaxed);
    while (true) {
        float updatedValue = as_type<float>(expected) + value;
        uint desired = as_type<uint>(updatedValue);
        if (atomic_compare_exchange_weak_explicit(
                address,
                &expected,
                desired,
                memory_order_relaxed,
                memory_order_relaxed)) {
            break;
        }
    }
}

inline float nt_sigmoid(float x) {
    return 1.0f / (1.0f + exp(-x));
}

inline float nt_vtrap(float x, float y) {
    float ratio = x / y;
    return fabs(ratio) < 1.0e-6f ? y * (1.0f - 0.5f * ratio) : x / (exp(ratio) - 1.0f);
}

inline float nt_relax(float value, float target, float tau, float dt) {
    return clamp(target + (value - target) * exp(-dt / max(tau, 1.0e-6f)), 0.0f, 1.0f);
}

inline float nt_rush_larsen(float value, float alpha, float beta, float dt, float scale) {
    float raw = max(alpha + beta, 1.0e-9f);
    float target = alpha / raw;
    return clamp(target + (value - target) * exp(-dt * raw * scale), 0.0f, 1.0f);
}

inline bool nt_isfinite4(float4 value) {
    return all(isfinite(value));
}

inline void nt_record_fatal(device NTValidationCounters* counters, uint lane = 0) {
    device atomic_uint* base = reinterpret_cast<device atomic_uint*>(&counters->fatalAndErrorCounts);
    atomic_fetch_add_explicit(base + min(lane, 3u), 1u, memory_order_relaxed);
}

inline void nt_record_error(device NTValidationCounters* counters, uint lane = 1) {
    device atomic_uint* base = reinterpret_cast<device atomic_uint*>(&counters->fatalAndErrorCounts);
    atomic_fetch_add_explicit(base + min(lane, 3u), 1u, memory_order_relaxed);
}
"""#

    public static let fastPath = #"""
kernel void nt_clear_transaction(
    device atomic_uint* eventCounters [[buffer(0)]],
    device atomic_uint* outputCounters [[buffer(1)]],
    device NTValidationCounters* validation [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid < 16u) {
        atomic_store_explicit(eventCounters + gid, 0u, memory_order_relaxed);
        atomic_store_explicit(outputCounters + gid, 0u, memory_order_relaxed);
    }
    if (gid < 16u) {
        device atomic_uint* words = reinterpret_cast<device atomic_uint*>(validation);
        atomic_store_explicit(words + gid, 0u, memory_order_relaxed);
    }
    if (gid == 0u) {
        validation->extrema0 = float4(INFINITY, -INFINITY, INFINITY, -INFINITY);
        validation->extrema1 = float4(0.0f);
    }
}

kernel void nt_build_active_worklists(
    constant NTWorldConstants& world [[buffer(0)]],
    device const NTTileHeader* tiles [[buffer(1)]],
    device uint* activeTiles [[buffer(2)]],
    device uint* activeCompartments [[buffer(3)]],
    device uint* activeSynapses [[buffer(4)]],
    device uint* activeMicrodomains [[buffer(5)]],
    device const uint* tileCompartments [[buffer(6)]],
    device const uint* tileSynapses [[buffer(7)]],
    device const uint* tileMicrodomains [[buffer(8)]],
    device atomic_uint* counters [[buffer(9)]],
    device NTDispatchArguments* dispatch [[buffer(10)]],
    constant uint4& policy [[buffer(11)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid != 0u) return;
    uint activeTileCount = 0u;
    uint activeCompartmentCount = 0u;
    uint activeSynapseCount = 0u;
    uint activeMicrodomainCount = 0u;
    uint minimumFidelity = policy.x;
    for (uint tileIndex = 0u; tileIndex < world.counts0.x; ++tileIndex) {
        NTTileHeader tile = tiles[tileIndex];
        uint fidelity = uint(max(tile.coordinateAndFidelity.w, 0));
        bool active = fidelity >= minimumFidelity || tile.scores.x > 0.0f || tile.scores.z > 0.0f;
        if (!active) continue;
        activeTiles[activeTileCount++] = tileIndex;
        if (fidelity >= 2u) {
            for (uint i = 0u; i < tile.compartmentRange.y; ++i) {
                activeCompartments[activeCompartmentCount++] = tileCompartments[tile.compartmentRange.x + i];
            }
            for (uint i = 0u; i < tile.synapseRange.y; ++i) {
                activeSynapses[activeSynapseCount++] = tileSynapses[tile.synapseRange.x + i];
            }
        }
        if (fidelity >= 4u) {
            for (uint i = 0u; i < tile.microdomainRange.y; ++i) {
                activeMicrodomains[activeMicrodomainCount++] = tileMicrodomains[tile.microdomainRange.x + i];
            }
        }
    }
    atomic_store_explicit(counters + 0, activeTileCount, memory_order_relaxed);
    atomic_store_explicit(counters + 1, activeCompartmentCount, memory_order_relaxed);
    atomic_store_explicit(counters + 2, activeSynapseCount, memory_order_relaxed);
    atomic_store_explicit(counters + 3, activeMicrodomainCount, memory_order_relaxed);
    uint width = max(policy.y, 1u);
    dispatch[0].threadgroupsPerGrid = uint3((activeTileCount + width - 1u) / width, 1u, 1u);
    dispatch[1].threadgroupsPerGrid = uint3((activeCompartmentCount + width - 1u) / width, 1u, 1u);
    dispatch[2].threadgroupsPerGrid = uint3((activeSynapseCount + width - 1u) / width, 1u, 1u);
    dispatch[3].threadgroupsPerGrid = uint3((activeMicrodomainCount + width - 1u) / width, 1u, 1u);
}

kernel void nt_decay_synapses(
    device NTSynapse* synapses [[buffer(0)]],
    device const uint* activeSynapses [[buffer(1)]],
    device const atomic_uint* activeCounters [[buffer(2)]],
    constant NTSynapseKinetics* receptorKinetics [[buffer(3)]],
    constant NTPlasticityParameters& plasticity [[buffer(4)]],
    constant float4& step [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(activeCounters + 2, memory_order_relaxed);
    if (gid >= count) return;
    uint index = activeSynapses[gid];
    NTSynapse synapse = synapses[index];
    uint receptor = synapse.topology.w & 0xffu;
    NTSynapseKinetics model = receptorKinetics[min(receptor, 5u)];
    float dtMilliseconds = step.x;
    synapse.kinetics0.z *= exp(-dtMilliseconds / max(model.timeAndReversal.x, 1.0e-6f));
    synapse.kinetics0.w *= exp(-dtMilliseconds / max(model.timeAndReversal.y, 1.0e-6f));
    synapse.plasticity0.x *= exp(-dtMilliseconds / max(plasticity.traceTimes.x, 1.0e-6f));
    synapse.plasticity1.y *= exp(-dtMilliseconds / max(plasticity.traceTimes.y, 1.0e-6f));
    synapse.plasticity0.z *= exp(-dtMilliseconds / max(plasticity.traceTimes.z, 1.0e-6f));
    float utilization = model.releaseAndResources.x;
    float facilitation = model.releaseAndResources.y;
    float depression = model.releaseAndResources.z;
    synapse.kinetics1.x = facilitation > 0.0f
        ? utilization + (synapse.kinetics1.x - utilization) * exp(-dtMilliseconds / facilitation)
        : utilization;
    synapse.kinetics1.y = 1.0f + (synapse.kinetics1.y - 1.0f) * exp(-dtMilliseconds / max(depression, 1.0e-6f));
    synapse.kinetics1.w = 1.0f + (synapse.kinetics1.w - 1.0f) * exp(-dtMilliseconds / max(depression, 1.0e-6f));
    synapse.kinetics0.y = max(0.0f, synapse.kinetics0.w - synapse.kinetics0.z);
    synapses[index] = synapse;
}

kernel void nt_deliver_events(
    constant NTWorldConstants& world [[buffer(0)]],
    device const NTEvent* events [[buffer(1)]],
    device const atomic_uint* eventCounters [[buffer(2)]],
    device NTSynapse* synapses [[buffer(3)]],
    constant NTSynapseKinetics* receptorKinetics [[buffer(4)]],
    constant NTPlasticityParameters& plasticity [[buffer(5)]],
    constant uint4& stepClock [[buffer(6)]],
    device NTValidationCounters* validation [[buffer(7)]],
    uint gid [[thread_position_in_grid]]) {
    uint eventCount = atomic_load_explicit(eventCounters + 0, memory_order_relaxed);
    if (gid >= eventCount) return;
    NTEvent event = events[gid];
    if (event.kindAndSequence.x != 1u) return;
    ulong now = (ulong(stepClock.y) << 32) | ulong(stepClock.x);
    if (nt_u64(event.deliveryTick) > now) return;
    uint synapseIndex = event.destination.x;
    if (synapseIndex >= world.counts0.w) {
        nt_record_error(validation, 2u);
        return;
    }
    device NTSynapse* synapse = synapses + synapseIndex;
    uint receptor = synapse->topology.w & 0xffu;
    NTSynapseKinetics model = receptorKinetics[min(receptor, 5u)];
    uint4 random = nt_philox(
        uint4(event.kindAndSequence.y, event.kindAndSequence.z, synapseIndex, stepClock.x),
        world.seed.xy
    );
    float releaseProbability = clamp(model.releaseAndResources.w * synapse->kinetics1.z * synapse->kinetics1.w, 0.0f, 1.0f);
    if (nt_uniform01(random.x) > releaseProbability) return;
    float utilization = synapse->kinetics1.x;
    if (model.releaseAndResources.y > 0.0f) {
        utilization += model.releaseAndResources.x * (1.0f - utilization);
    }
    float released = clamp(utilization * synapse->kinetics1.y, 0.0f, 1.0f);
    float impulse = event.payload.x * synapse->kinetics0.x * released;
    device atomic_uint* rise = reinterpret_cast<device atomic_uint*>(&synapse->kinetics0.z);
    device atomic_uint* decay = reinterpret_cast<device atomic_uint*>(&synapse->kinetics0.w);
    device atomic_uint* preTrace = reinterpret_cast<device atomic_uint*>(&synapse->plasticity0.x);
    device atomic_uint* eligibility = reinterpret_cast<device atomic_uint*>(&synapse->plasticity0.z);
    nt_atomic_add_float(rise, impulse);
    nt_atomic_add_float(decay, impulse);
    nt_atomic_add_float(preTrace, 1.0f);
    nt_atomic_add_float(eligibility, plasticity.learning0.x * synapse->plasticity1.y);
    synapse->kinetics1.x = utilization;
    synapse->kinetics1.y *= 1.0f - utilization;
    synapse->kinetics1.w *= 1.0f - released;
    synapse->lastEventAndFlags.xy = stepClock.xy;
}

kernel void nt_update_gates_and_assemble(
    constant NTWorldConstants& world [[buffer(0)]],
    device NTCompartment* compartments [[buffer(1)]],
    device const uint* activeCompartments [[buffer(2)]],
    device const atomic_uint* activeCounters [[buffer(3)]],
    constant NTMechanismSet* mechanisms [[buffer(4)]],
    device float* diagonal [[buffer(5)]],
    device float* rhs [[buffer(6)]],
    constant uint4& stepClock [[buffer(7)]],
    constant float4& step [[buffer(8)]],
    device NTValidationCounters* validation [[buffer(9)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(activeCounters + 1, memory_order_relaxed);
    if (gid >= count) return;
    uint index = activeCompartments[gid];
    if (index >= world.counts0.z) {
        nt_record_fatal(validation, 1u);
        return;
    }
    NTCompartment c = compartments[index];
    c.spikeState.w &= ~1u;
    float voltage = c.geometryAndVoltage.w;
    c.conductance0.w = voltage;
    uint mechanismIndex = (c.topology.w >> 24) & 0xffu;
    NTMechanismSet p = mechanisms[mechanismIndex];
    float dtMilliseconds = step.x;
    float temperatureCelsius = step.z;
    float rateScale = pow(p.temperature0.x, (temperatureCelsius - p.temperature0.y) / 10.0f);

    float alphaM = 0.1f * nt_vtrap(-(voltage + 40.0f), 10.0f);
    float betaM = 4.0f * exp(-(voltage + 65.0f) / 18.0f);
    float alphaH = 0.07f * exp(-(voltage + 65.0f) / 20.0f);
    float betaH = 1.0f / (1.0f + exp(-(voltage + 35.0f) / 10.0f));
    float alphaN = 0.01f * nt_vtrap(-(voltage + 55.0f), 10.0f);
    float betaN = 0.125f * exp(-(voltage + 65.0f) / 80.0f);
    c.gates0.x = nt_rush_larsen(c.gates0.x, alphaM, betaM, dtMilliseconds, rateScale);
    c.gates0.y = nt_rush_larsen(c.gates0.y, alphaH, betaH, dtMilliseconds, rateScale);
    c.gates0.z = nt_rush_larsen(c.gates0.z, alphaN, betaN, dtMilliseconds, rateScale);
    c.gates0.w = nt_relax(c.gates0.w, nt_sigmoid((voltage + 20.0f) / 6.5f), 1.5f / rateScale, dtMilliseconds);
    c.gates1.x = nt_relax(c.gates1.x, nt_sigmoid(-(voltage + 25.0f) / 12.0f), 30.0f / rateScale, dtMilliseconds);
    c.gates1.y = nt_relax(c.gates1.y, nt_sigmoid((voltage + 57.0f) / 6.2f), 3.0f / rateScale, dtMilliseconds);
    c.gates1.z = nt_relax(c.gates1.z, nt_sigmoid(-(voltage + 81.0f) / 4.0f), 20.0f / rateScale, dtMilliseconds);
    c.gates1.w = nt_relax(c.gates1.w, nt_sigmoid(-(voltage + 82.0f) / 8.0f), 80.0f / rateScale, dtMilliseconds);
    c.gates2.x = nt_relax(c.gates2.x, nt_sigmoid((voltage + 35.0f) / 10.0f), 40.0f / rateScale, dtMilliseconds);
    c.gates2.y = nt_relax(c.gates2.y, c.ions0.x / max(c.ions0.x + 0.3f, 1.0e-6f), 5.0f / rateScale, dtMilliseconds);

    float length = max(c.positionAndLength.w, 1.0e-4f);
    float diameter = max(c.geometryAndVoltage.x, 1.0e-4f);
    float area = NT_PI * diameter * length + 0.5f * NT_PI * diameter * diameter;
    float gNa = p.conductance0.x * area * c.gates0.x * c.gates0.x * c.gates0.x * c.gates0.y;
    float gK = p.conductance0.y * area * pow(c.gates0.z, 4.0f);
    float gLeak = p.conductance0.z * area;
    float gCaL = p.conductance0.w * area * c.gates0.w * c.gates0.w * c.gates1.x;
    float gCaT = p.conductance1.x * area * c.gates1.y * c.gates1.y * c.gates1.z;
    float gKCa = p.conductance1.y * area * c.gates2.y;
    float gHCN = p.conductance1.z * area * c.gates1.w;
    float gM = p.conductance1.w * area * c.gates2.x;
    float gOpto = p.conductance2.x * area * c.gates2.z;

    float kelvin = temperatureCelsius + 273.15f;
    float rtOverF = 8.3144626f * kelvin / 96485.33f * 1000.0f;
    float eNa = rtOverF * log(max(p.extracellular0.x, 1.0e-8f) / max(c.ions0.y, 1.0e-8f));
    float eK = rtOverF * log(max(p.extracellular0.y, 1.0e-8f) / max(c.ions0.z, 1.0e-8f));
    float eCa = 0.5f * rtOverF * log(max(p.extracellular0.z, 1.0e-8f) / max(c.ions0.x * 0.001f, 1.0e-12f));
    float gExc = max(c.conductance0.x, 0.0f);
    float gInh = max(c.conductance0.y, 0.0f);
    float channelTotal = gNa + gK + gLeak + gCaL + gCaT + gKCa + gHCN + gM + gOpto;
    float reversalWeighted = gNa * eNa + (gK + gKCa + gM) * eK + gLeak * p.reversal0.x +
        (gCaL + gCaT) * eCa + gHCN * p.reversal0.y;
    float capacitanceOverDt = max(c.geometryAndVoltage.y, 1.0e-9f) / max(dtMilliseconds, 1.0e-9f);
    float parentCoupling = c.topology.x == NT_INVALID_INDEX ? 0.0f : max(c.geometryAndVoltage.z, 0.0f);
    diagonal[index] = capacitanceOverDt + channelTotal + gExc + gInh + parentCoupling;
    rhs[index] = capacitanceOverDt * voltage + reversalWeighted + gInh * p.reversal0.z + c.current0.x + c.current0.y;

    float iNa = gNa * (voltage - eNa);
    float iK = (gK + gKCa + gM) * (voltage - eK);
    float iCa = (gCaL + gCaT) * (voltage - eCa);
    c.current0.z = iNa + iK + iCa + gLeak * (voltage - p.reversal0.x) + gHCN * (voltage - p.reversal0.y) + gOpto * voltage;
    c.current0.w = -p.calcium0.z * iCa * 1000.0f;
    c.conductance0.z = (fabs(iNa) + fabs(iK) + fabs(iCa)) * fabs(voltage) * dtMilliseconds;
    float calciumDelta = c.current0.w * step.y - (c.ions0.x - p.calcium0.x) * dtMilliseconds / max(p.calcium0.y, 1.0e-3f);
    c.ions0.x = max(0.0f, c.ions0.x + calciumDelta);
    if (!nt_isfinite4(c.geometryAndVoltage) || !nt_isfinite4(c.ions0) || !isfinite(diagonal[index]) || !isfinite(rhs[index])) {
        nt_record_fatal(validation, 0u);
    }
    compartments[index] = c;
}

kernel void nt_accumulate_axial_diagonal(
    device const NTCompartment* compartments [[buffer(0)]],
    device const uint* activeCompartments [[buffer(1)]],
    device const atomic_uint* activeCounters [[buffer(2)]],
    device atomic_uint* diagonalBits [[buffer(3)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(activeCounters + 1, memory_order_relaxed);
    if (gid >= count) return;
    uint child = activeCompartments[gid];
    NTCompartment c = compartments[child];
    if (c.topology.x == NT_INVALID_INDEX) return;
    nt_atomic_add_float(diagonalBits + c.topology.x, max(c.geometryAndVoltage.z, 0.0f));
}

kernel void nt_hines_eliminate(
    device const NTCompartment* compartments [[buffer(0)]],
    device const uint* levelIndices [[buffer(1)]],
    constant uint4& level [[buffer(2)]],
    device atomic_uint* diagonalBits [[buffer(3)]],
    device atomic_uint* rhsBits [[buffer(4)]],
    device NTValidationCounters* validation [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= level.w) return;
    uint child = levelIndices[level.z + gid];
    uint parent = compartments[child].topology.x;
    if (parent == NT_INVALID_INDEX) return;
    float pivot = as_type<float>(atomic_load_explicit(diagonalBits + child, memory_order_relaxed));
    float childRHS = as_type<float>(atomic_load_explicit(rhsBits + child, memory_order_relaxed));
    float coupling = max(compartments[child].geometryAndVoltage.z, 0.0f);
    if (!isfinite(pivot) || pivot <= 1.0e-12f) {
        nt_record_fatal(validation, 0u);
        return;
    }
    nt_atomic_add_float(diagonalBits + parent, -(coupling * coupling / pivot));
    nt_atomic_add_float(rhsBits + parent, coupling * childRHS / pivot);
}

kernel void nt_hines_substitute(
    device NTCompartment* compartments [[buffer(0)]],
    device const uint* levelIndices [[buffer(1)]],
    constant uint4& level [[buffer(2)]],
    device const float* diagonal [[buffer(3)]],
    device const float* rhs [[buffer(4)]],
    device NTValidationCounters* validation [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= level.w) return;
    uint index = levelIndices[level.z + gid];
    uint parent = compartments[index].topology.x;
    float numerator = rhs[index];
    if (parent != NT_INVALID_INDEX) {
        numerator += max(compartments[index].geometryAndVoltage.z, 0.0f) * compartments[parent].geometryAndVoltage.w;
    }
    float pivot = diagonal[index];
    if (!isfinite(pivot) || pivot <= 1.0e-12f) {
        nt_record_fatal(validation, 0u);
        return;
    }
    compartments[index].geometryAndVoltage.w = numerator / pivot;
}

kernel void nt_detect_spikes(
    constant NTWorldConstants& world [[buffer(0)]],
    device NTCompartment* compartments [[buffer(1)]],
    device const uint* activeCompartments [[buffer(2)]],
    device const atomic_uint* activeCounters [[buffer(3)]],
    device NTEvent* outputSpikes [[buffer(4)]],
    device atomic_uint* outputCounters [[buffer(5)]],
    constant uint4& stepClock [[buffer(6)]],
    constant float4& detection [[buffer(7)]],
    device NTValidationCounters* validation [[buffer(8)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(activeCounters + 1, memory_order_relaxed);
    if (gid >= count) return;
    uint index = activeCompartments[gid];
    NTCompartment c = compartments[index];
    float previous = c.conductance0.w;
    float current = c.geometryAndVoltage.w;
    ulong now = (ulong(stepClock.y) << 32) | ulong(stepClock.x);
    ulong refractoryUntil = (ulong(c.spikeState.y) << 32) | ulong(c.spikeState.x);
    if (now >= refractoryUntil && previous < detection.x && current >= detection.x) {
        float fraction = clamp((detection.x - previous) / max(current - previous, 1.0e-9f), 0.0f, 1.0f);
        ulong spikeTick = now + ulong(rint(fraction * float(stepClock.z)));
        ulong refractory = spikeTick + ulong(detection.y);
        c.spikeState.xy = nt_u32x2(refractory);
        c.spikeState.z += 1u;
        c.spikeState.w |= 1u;
        uint outputIndex = atomic_fetch_add_explicit(outputCounters + 0, 1u, memory_order_relaxed);
        if (outputIndex < world.counts1.z) {
            NTEvent event;
            event.deliveryTick = nt_u32x2(spikeTick);
            event.source = c.id;
            event.destination = uint2(index, 0u);
            event.route = uint2(0u);
            event.payload = float4(1.0f, current, 0.0f, 0.0f);
            event.kindAndSequence = uint4(0u, outputIndex, stepClock.w, 0u);
            outputSpikes[outputIndex] = event;
        } else {
            atomic_fetch_add_explicit(outputCounters + 1, 1u, memory_order_relaxed);
            nt_record_fatal(validation, 2u);
        }
    }
    if (!isfinite(current) || current < world.voltageAndTolerance.x || current > world.voltageAndTolerance.y) {
        nt_record_error(validation, 0u);
    }
    compartments[index] = c;
}

kernel void nt_route_spikes(
    constant NTWorldConstants& world [[buffer(0)]],
    device const NTCompartment* compartments [[buffer(1)]],
    device const NTRoute* routes [[buffer(2)]],
    device const uint* routeDestinations [[buffer(3)]],
    device NTEvent* events [[buffer(4)]],
    device atomic_uint* eventCounters [[buffer(5)]],
    constant uint4& stepClock [[buffer(6)]],
    device NTValidationCounters* validation [[buffer(7)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= world.counts1.x) return;
    NTRoute route = routes[gid];
    uint source = route.topology.x;
    if (source >= world.counts0.z || (compartments[source].spikeState.w & 1u) == 0u) return;
    uint4 random = nt_philox(uint4(stepClock.x, stepClock.y, route.id.x, route.id.y), world.seed.xy);
    if (nt_uniform01(random.x) < route.dynamics.x) return;
    ulong now = (ulong(stepClock.y) << 32) | ulong(stepClock.x);
    ulong delivery = now + ulong(route.topology.w);
    for (uint local = 0u; local < route.topology.z; ++local) {
        uint destinationSlot = route.topology.y + local;
        uint synapseIndex = routeDestinations[destinationSlot];
        uint output = atomic_fetch_add_explicit(eventCounters + 0, 1u, memory_order_relaxed);
        if (output >= world.counts1.z) {
            atomic_fetch_add_explicit(eventCounters + 1, 1u, memory_order_relaxed);
            nt_record_fatal(validation, 2u);
            return;
        }
        NTEvent event;
        event.deliveryTick = nt_u32x2(delivery);
        event.source = compartments[source].id;
        event.destination = uint2(synapseIndex, 0u);
        event.route = route.id;
        event.payload = float4(route.dynamics.y, 0.0f, 0.0f, 0.0f);
        event.kindAndSequence = uint4(1u, output, stepClock.w, 0u);
        events[output] = event;
    }
}

kernel void nt_update_plasticity(
    device NTSynapse* synapses [[buffer(0)]],
    device const uint* activeSynapses [[buffer(1)]],
    device const atomic_uint* activeCounters [[buffer(2)]],
    constant NTPlasticityParameters& p [[buffer(3)]],
    constant float4& stepAndModulators [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    uint count = atomic_load_explicit(activeCounters + 2, memory_order_relaxed);
    if (gid >= count) return;
    uint index = activeSynapses[gid];
    NTSynapse synapse = synapses[index];
    uint receptor = synapse.topology.w & 0xffu;
    if (receptor == 4u) return;
    float dtSeconds = stepAndModulators.x;
    float modulator = stepAndModulators.y;
    float protectedFraction = clamp(synapse.plasticity0.w, 0.0f, 1.0f);
    float learned = p.learning0.z * modulator * synapse.plasticity0.z * dtSeconds * (1.0f - 0.8f * protectedFraction);
    float decay = p.learning0.w * synapse.kinetics0.x * (1.0f - protectedFraction) * dtSeconds;
    float homeostatic = p.structural0.z * (synapse.plasticity1.w - stepAndModulators.z) * dtSeconds * synapse.kinetics0.x;
    synapse.kinetics0.x = clamp(synapse.kinetics0.x + learned - decay + homeostatic, p.weightBounds.x, p.weightBounds.y);
    if (fabs(synapse.plasticity0.z) >= p.weightBounds.w && modulator > 0.0f) {
        synapse.plasticity0.w = min(1.0f, synapse.plasticity0.w + p.weightBounds.z * modulator * dtSeconds);
    } else {
        synapse.plasticity0.w = max(0.0f, synapse.plasticity0.w - 0.1f * p.weightBounds.z * dtSeconds);
    }
    if (stepAndModulators.w > 0.5f) {
        float support = min(1.0f, fabs(synapse.plasticity0.z) + 0.1f * synapse.plasticity1.z);
        synapse.plasticity1.x = clamp(synapse.plasticity1.x + support * 0.001f - p.structural0.x * dtSeconds, 0.0f, 1.0f);
        synapse.plasticity1.z *= exp(-dtSeconds / 10.0f);
        if (synapse.plasticity1.x < p.structural0.y && synapse.plasticity0.w < 0.1f) {
            synapse.lastEventAndFlags.z = 1u;
        }
    }
    synapses[index] = synapse;
}

kernel void nt_validate_state(
    constant NTWorldConstants& world [[buffer(0)]],
    device const NTCompartment* compartments [[buffer(1)]],
    device const NTSynapse* synapses [[buffer(2)]],
    device const float* fieldValues [[buffer(3)]],
    constant uint4& fieldShape [[buffer(4)]],
    device NTValidationCounters* validation [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid < world.counts0.z) {
        NTCompartment c = compartments[gid];
        if (!nt_isfinite4(c.geometryAndVoltage) || !nt_isfinite4(c.ions0) || !nt_isfinite4(c.current0)) {
            nt_record_fatal(validation, 0u);
        }
        if (c.geometryAndVoltage.w < world.voltageAndTolerance.x || c.geometryAndVoltage.w > world.voltageAndTolerance.y) {
            nt_record_error(validation, 0u);
        }
        if (c.ions0.x < 0.0f || c.ions0.y < 0.0f || c.ions0.z < 0.0f) {
            nt_record_error(validation, 1u);
        }
        if (c.topology.x != NT_INVALID_INDEX && c.topology.x >= world.counts0.z) {
            nt_record_fatal(validation, 1u);
        }
    }
    if (gid < world.counts0.w) {
        NTSynapse s = synapses[gid];
        if (!nt_isfinite4(s.kinetics0) || !nt_isfinite4(s.plasticity0) || s.kinetics0.x < 0.0f) {
            nt_record_error(validation, 3u);
        }
        if (s.topology.x >= world.counts0.z || s.topology.y >= world.counts0.z) {
            nt_record_fatal(validation, 1u);
        }
    }
    if (gid < fieldShape.x) {
        float value = fieldValues[gid];
        if (!isfinite(value)) nt_record_fatal(validation, 0u);
        if (value < 0.0f) nt_record_error(validation, 1u);
    }
}
"""#

    public static var completeCore: String { common + "\n" + fastPath }
}
