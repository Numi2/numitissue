#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_METAL_ABI
#define NUMITISSUE_METAL_ABI

constant uint NT_ABI_VERSION = 1u;
constant uint NT_INVALID_INDEX = 0xFFFFFFFFu;
constant float NT_TICK_MILLISECONDS = 0.025f;
constant float NT_EPSILON = 1.0e-12f;

struct NTRange {
    uint lowerBound;
    uint count;
    uint reserved0;
    uint reserved1;
};

struct NTSimulationHeader {
    uint abiVersion;
    uint flags;
    uint transactionLo;
    uint transactionHi;
    uint startTickLo;
    uint startTickHi;
    uint endTickLo;
    uint endTickHi;
    uint epochLo;
    uint epochHi;
    uint randomSeedLo;
    uint randomSeedHi;
    uint tileCount;
    uint cellCount;
    uint segmentCount;
    uint compartmentCount;
    uint synapseCount;
    uint fieldValueCount;
    uint microdomainCount;
    uint molecularSpeciesCount;
    uint eventCapacity;
    uint fieldChannels;
    uint fieldGridWidth;
    uint fieldGridHeight;
    uint fieldGridDepth;
    uint fastQuantumTicks;
    uint routingBlockTicks;
    uint transactionTicks;
    uint phase;
    uint phaseStartTickLo;
    uint phaseStartTickHi;
    uint phaseEndTickLo;
    uint phaseEndTickHi;
    float dtMilliseconds;
    float inverseDtMilliseconds;
    float temperatureKelvin;
    float reservedFloat;
    uint4 reserved0; // input count, stimulus count, local event count, outgoing count
    uint4 reserved1; // output event count, validation capacity, field species stride, flags
    uint4 reserved2;
    uint4 reserved3;
};

struct NTTileState {
    uint idLo;
    uint idHi;
    uint flags;
    uint fidelityMask;
    int4 coordinate;
    NTRange cellRange;
    NTRange segmentRange;
    NTRange compartmentRange;
    NTRange synapseRange;
    NTRange fieldRange;
    NTRange microdomainRange;
    uint lastActiveTickLo;
    uint lastActiveTickHi;
    uint reservedTick0;
    uint reservedTick1;
    float4 scores;
};

struct NTCellState {
    uint idLo;
    uint idHi;
    uint lineageLo;
    uint lineageHi;
    uint tileIndex;
    uint typeAndDevelopment;
    uint fidelityAndFlags;
    uint reservedIndex;
    float4 position;
    float4 orientation;
    float4 semiAxes;
    float4 velocity;
    float4 ageCycleDifferentiationEnergy;
    float4 stressDamageHazard;
    NTRange regulatoryRange;
};

struct NTSegmentState {
    uint idLo;
    uint idHi;
    uint cellIndex;
    uint parentSegmentIndex;
    uint firstChildIndex;
    uint nextSiblingIndex;
    uint compartmentIndex;
    uint typeAndFlags;
    float4 start;
    float4 end;
    float4 radiusMyelinGrowthScore;
};

struct NTCompartmentState {
    uint idLo;
    uint idHi;
    uint neuronIndex;
    uint parentIndex;
    NTRange mechanismRange;
    NTRange synapseRange;
    float4 voltagePreviousCapacitanceAxial;
    float4 injectedSynapticCalciumSodium;
    float4 potassiumReserved;
    uint refractoryTickLo;
    uint refractoryTickHi;
    uint flags;
    uint reserved;
};

struct NTSynapseState {
    uint idLo;
    uint idHi;
    uint sourceRouteIndex;
    uint targetCompartmentIndex;
    uint parameterAndFlags;
    uint delayTicks;
    uint lastEventTickLo;
    uint lastEventTickHi;
    float4 weightConductanceUtilizationResources;
    float4 prePostEligibilityConsolidation;
    float4 structuralReserved;
};

struct NTEvent {
    uint arrivalTickLo;
    uint arrivalTickHi;
    uint sourceLo;
    uint sourceHi;
    uint destinationLo;
    uint destinationHi;
    uint kindAndFlags;
    uint sequence;
    float amplitude;
    float reserved0;
    float reserved1;
    float reserved2;
};

struct NTFieldState {
    float4 concentrationSourceSinkDiffusion;
};

struct NTMicrodomainState {
    uint idLo;
    uint idHi;
    uint ownerCellIndex;
    uint ownerCompartmentIndex;
    uint reactionSolverFlags;
    uint reservedIndex;
    NTRange speciesRange;
    float4 volumeTemperaturePropensityReserved;
    uint nextEventTickLo;
    uint nextEventTickHi;
    uint reserved0;
    uint reserved1;
};

struct NTValidationRecord {
    uint code;
    uint severity;
    uint entityLo;
    uint entityHi;
    float value;
    uint index;
    uint reserved0;
    uint reserved1;
};

struct NTRuntimeCounters {
    atomic_uint activeTiles;
    atomic_uint activeCompartments;
    atomic_uint promotedEntities;
    atomic_uint demotedEntities;
    atomic_uint deliveredEventsLo;
    atomic_uint deliveredEventsHi;
    atomic_uint generatedSpikesLo;
    atomic_uint generatedSpikesHi;
    atomic_uint routedEventsLo;
    atomic_uint routedEventsHi;
    atomic_uint molecularFiringsLo;
    atomic_uint molecularFiringsHi;
    atomic_uint structuralMutations;
    atomic_uint rejectedMutations;
    atomic_uint numericalSubsteps;
    atomic_uint validationCount;
};

struct NTResources {
    device NTSimulationHeader* header [[id(0)]];
    device NTTileState* tiles [[id(1)]];
    device NTCellState* cells [[id(2)]];
    device float* regulatoryState [[id(3)]];
    device NTSegmentState* segments [[id(4)]];
    device NTCompartmentState* compartments [[id(5)]];
    device float* mechanismState [[id(6)]];
    device NTSynapseState* synapses [[id(7)]];
    device NTFieldState* fields [[id(8)]];
    device NTMicrodomainState* microdomains [[id(9)]];
    device float* molecularSpecies [[id(10)]];
    device NTEvent* inputEvents [[id(11)]];
    device NTEvent* stimuli [[id(12)]];
    device NTEvent* localEvents [[id(13)]];
    device NTEvent* outgoingEvents [[id(14)]];
    device NTEvent* outputEvents [[id(15)]];
    device atomic_uint* eventBucketCounts [[id(16)]];
    device atomic_uint* worklistCounts [[id(17)]];
    device uint* electricalWorklist [[id(18)]];
    device uint* fieldWorklist [[id(19)]];
    device uint* molecularWorklist [[id(20)]];
    device uint* mechanicsWorklist [[id(21)]];
    device uint* developmentWorklist [[id(22)]];
    device uint* fidelityWorklist [[id(23)]];
    device NTValidationRecord* validationRecords [[id(24)]];
    device NTRuntimeCounters* counters [[id(25)]];
    device float* outputScalars [[id(26)]];
    device uint* indirectDispatch [[id(27)]];
};

inline ulong nt_u64(uint lo, uint hi) {
    return (ulong(hi) << 32) | ulong(lo);
}

inline uint2 nt_split_u64(ulong value) {
    return uint2(uint(value), uint(value >> 32));
}

inline float nt_clamp01(float value) {
    return clamp(value, 0.0f, 1.0f);
}

inline bool nt_finite3(float4 value) {
    return isfinite(value.x) && isfinite(value.y) && isfinite(value.z);
}

inline uint4 nt_philox_round(uint4 counter, uint2 key) {
    const ulong p0 = ulong(0xD2511F53u) * ulong(counter.x);
    const ulong p1 = ulong(0xCD9E8D57u) * ulong(counter.z);
    return uint4(uint(p1 >> 32) ^ counter.y ^ key.x,
                 uint(p1),
                 uint(p0 >> 32) ^ counter.w ^ key.y,
                 uint(p0));
}

inline uint4 nt_philox(uint4 counter, uint2 key) {
    for (uint round = 0; round < 10; ++round) {
        counter = nt_philox_round(counter, key);
        key += uint2(0x9E3779B9u, 0xBB67AE85u);
    }
    return counter;
}

inline float nt_uniform01(uint bits) {
    const uint mantissa = (bits >> 8) | 1u;
    return float(mantissa) * (1.0f / 16777217.0f);
}

inline void nt_atomic_add_u64(device atomic_uint* lo, device atomic_uint* hi, uint value) {
    const uint old = atomic_fetch_add_explicit(lo, value, memory_order_relaxed);
    if (old > 0xFFFFFFFFu - value) {
        atomic_fetch_add_explicit(hi, 1u, memory_order_relaxed);
    }
}

inline uint nt_append_validation(
    constant NTResources& r,
    uint code,
    uint severity,
    uint2 entity,
    float value,
    uint index
) {
    const uint slot = atomic_fetch_add_explicit(&r.counters->validationCount, 1u, memory_order_relaxed);
    const uint capacity = r.header->reserved1.y;
    if (slot < capacity) {
        r.validationRecords[slot] = NTValidationRecord{code, severity, entity.x, entity.y, value, index, 0u, 0u};
    }
    return slot;
}

kernel void nt_reset_transient_state(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid < 4096u) {
        atomic_store_explicit(&r.eventBucketCounts[gid], 0u, memory_order_relaxed);
    }
    if (gid < 16u) {
        atomic_store_explicit(&r.worklistCounts[gid], 0u, memory_order_relaxed);
    }
    if (gid < 16u) {
        device atomic_uint* words = reinterpret_cast<device atomic_uint*>(r.counters);
        atomic_store_explicit(&words[gid], 0u, memory_order_relaxed);
    }
}

#endif
