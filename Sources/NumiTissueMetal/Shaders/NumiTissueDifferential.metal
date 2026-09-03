#ifndef NUMITISSUE_DIFFERENTIAL
#define NUMITISSUE_DIFFERENTIAL

struct NTDigestCounts {
    uint regulatoryStateCount;
    uint mechanismStateCount;
    uint reserved0;
    uint reserved1;
};

inline ulong nt_digest_rotate_left(ulong value, uint amount) {
    const uint shift = amount & 63u;
    return shift == 0u ? value : ((value << shift) | (value >> (64u - shift)));
}

inline ulong nt_digest_mix64(ulong source) {
    ulong value = source;
    value = (value ^ (value >> 30u)) * 0xBF58476D1CE4E5B9ull;
    value = (value ^ (value >> 27u)) * 0x94D049BB133111EBull;
    return value ^ (value >> 31u);
}

inline ulong4 nt_digest_initialize(ulong domain) {
    return ulong4(
        0x243F6A8885A308D3ull ^ domain,
        0x13198A2E03707344ull + domain,
        0xA4093822299F31D0ull ^ nt_digest_rotate_left(domain, 17u),
        0x082EFA98EC4E6C89ull + nt_digest_rotate_left(domain, 41u)
    );
}

inline void nt_digest_combine(thread ulong4& state, thread ulong& count, ulong value) {
    count += 1ull;
    const ulong keyed = nt_digest_mix64(
        value + count * 0x9E3779B97F4A7C15ull
    );
    state.x = nt_digest_rotate_left(state.x ^ keyed, 13u) * 0xBF58476D1CE4E5B9ull;
    state.y = nt_digest_rotate_left(state.y + keyed, 29u) * 0x94D049BB133111EBull;
    state.z ^= nt_digest_mix64(keyed + state.x);
    state.w += nt_digest_rotate_left(keyed ^ state.y, 37u);
}

inline void nt_digest_combine_u32(thread ulong4& state, thread ulong& count, uint value) {
    nt_digest_combine(state, count, ulong(value));
}

inline void nt_digest_combine_i32(thread ulong4& state, thread ulong& count, int value) {
    nt_digest_combine(state, count, ulong(long(value)));
}

inline void nt_digest_combine_float(thread ulong4& state, thread ulong& count, float value) {
    nt_digest_combine(state, count, ulong(as_type<uint>(value)));
}

inline void nt_digest_combine_float4(thread ulong4& state, thread ulong& count, float4 value) {
    nt_digest_combine_float(state, count, value.x);
    nt_digest_combine_float(state, count, value.y);
    nt_digest_combine_float(state, count, value.z);
    nt_digest_combine_float(state, count, value.w);
}

inline void nt_digest_combine_range(thread ulong4& state, thread ulong& count, NTRange value) {
    nt_digest_combine_u32(state, count, value.lowerBound);
    nt_digest_combine_u32(state, count, value.count);
}

inline ulong4 nt_digest_finalize(ulong4 state, ulong count) {
    return ulong4(
        nt_digest_mix64(state.x ^ count),
        nt_digest_mix64(state.y + count),
        nt_digest_mix64(state.z ^ nt_digest_rotate_left(count, 23u)),
        nt_digest_mix64(state.w + nt_digest_rotate_left(count, 47u))
    );
}

kernel void nt_digest_shadow_state(
    constant NTResources& r [[buffer(0)]],
    device ulong4* output [[buffer(1)]],
    constant NTDigestCounts& counts [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= 10u) { return; }

    ulong4 digest;
    ulong combinedCount = 0ull;

    switch (gid) {
    case 0u: {
        digest = nt_digest_initialize(0x54494C4553000001ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->tileCount);
        for (uint index = 0u; index < r.header->tileCount; ++index) {
            const NTTileState value = r.tiles[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine_i32(digest, combinedCount, value.coordinate.x);
            nt_digest_combine_i32(digest, combinedCount, value.coordinate.y);
            nt_digest_combine_i32(digest, combinedCount, value.coordinate.z);
            nt_digest_combine_u32(digest, combinedCount, value.flags);
            nt_digest_combine_u32(digest, combinedCount, value.fidelityMask);
            nt_digest_combine_range(digest, combinedCount, value.cellRange);
            nt_digest_combine_range(digest, combinedCount, value.segmentRange);
            nt_digest_combine_range(digest, combinedCount, value.compartmentRange);
            nt_digest_combine_range(digest, combinedCount, value.synapseRange);
            nt_digest_combine_range(digest, combinedCount, value.fieldRange);
            nt_digest_combine_range(digest, combinedCount, value.microdomainRange);
            nt_digest_combine(digest, combinedCount, nt_u64(value.lastActiveTickLo, value.lastActiveTickHi));
            nt_digest_combine_float4(digest, combinedCount, value.scores);
        }
        break;
    }
    case 1u: {
        digest = nt_digest_initialize(0x43454C4C53000001ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->cellCount);
        for (uint index = 0u; index < r.header->cellCount; ++index) {
            const NTCellState value = r.cells[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine(digest, combinedCount, nt_u64(value.lineageLo, value.lineageHi));
            nt_digest_combine_u32(digest, combinedCount, value.tileIndex);
            nt_digest_combine_u32(digest, combinedCount, value.typeAndDevelopment & 0xFFFFu);
            nt_digest_combine_u32(digest, combinedCount, value.typeAndDevelopment >> 16u);
            nt_digest_combine_u32(digest, combinedCount, value.fidelityAndFlags & 0xFFu);
            nt_digest_combine_u32(digest, combinedCount, (value.fidelityAndFlags >> 8u) & 0xFFu);
            nt_digest_combine_float4(digest, combinedCount, value.position);
            nt_digest_combine_float4(digest, combinedCount, value.orientation);
            nt_digest_combine_float4(digest, combinedCount, value.semiAxes);
            nt_digest_combine_float4(digest, combinedCount, value.velocity);
            nt_digest_combine_float4(digest, combinedCount, value.ageCycleDifferentiationEnergy);
            nt_digest_combine_float4(digest, combinedCount, value.stressDamageHazard);
            nt_digest_combine_range(digest, combinedCount, value.regulatoryRange);
        }
        break;
    }
    case 2u: {
        digest = nt_digest_initialize(0x524547554C41544Full);
        nt_digest_combine_u32(digest, combinedCount, counts.regulatoryStateCount);
        for (uint index = 0u; index < counts.regulatoryStateCount; ++index) {
            nt_digest_combine_float(digest, combinedCount, r.regulatoryState[index]);
        }
        break;
    }
    case 3u: {
        digest = nt_digest_initialize(0x5345474D454E5453ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->segmentCount);
        for (uint index = 0u; index < r.header->segmentCount; ++index) {
            const NTSegmentState value = r.segments[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine_u32(digest, combinedCount, value.cellIndex);
            nt_digest_combine_u32(digest, combinedCount, value.parentSegmentIndex);
            nt_digest_combine_u32(digest, combinedCount, value.firstChildIndex);
            nt_digest_combine_u32(digest, combinedCount, value.nextSiblingIndex);
            nt_digest_combine_u32(digest, combinedCount, value.compartmentIndex);
            nt_digest_combine_u32(digest, combinedCount, value.typeAndFlags & 0xFFFFu);
            nt_digest_combine_u32(digest, combinedCount, value.typeAndFlags >> 16u);
            nt_digest_combine_float4(digest, combinedCount, value.start);
            nt_digest_combine_float4(digest, combinedCount, value.end);
            nt_digest_combine_float(digest, combinedCount, value.radiusMyelinGrowthScore.x);
            nt_digest_combine_float(digest, combinedCount, value.radiusMyelinGrowthScore.y);
            nt_digest_combine_float(digest, combinedCount, value.radiusMyelinGrowthScore.z);
            nt_digest_combine_float(digest, combinedCount, value.radiusMyelinGrowthScore.w);
        }
        break;
    }
    case 4u: {
        digest = nt_digest_initialize(0x434F4D5041525453ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->compartmentCount);
        for (uint index = 0u; index < r.header->compartmentCount; ++index) {
            const NTCompartmentState value = r.compartments[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine_u32(digest, combinedCount, value.neuronIndex);
            nt_digest_combine_u32(digest, combinedCount, value.parentIndex);
            nt_digest_combine_range(digest, combinedCount, value.mechanismRange);
            nt_digest_combine_range(digest, combinedCount, value.synapseRange);
            nt_digest_combine_float4(digest, combinedCount, value.voltagePreviousCapacitanceAxial);
            nt_digest_combine_float4(digest, combinedCount, value.injectedSynapticCalciumSodium);
            nt_digest_combine_float(digest, combinedCount, value.potassiumReserved.x);
            nt_digest_combine(digest, combinedCount, nt_u64(value.refractoryTickLo, value.refractoryTickHi));
            nt_digest_combine_u32(digest, combinedCount, value.flags);
        }
        break;
    }
    case 5u: {
        digest = nt_digest_initialize(0x4D454348414E4953ull);
        nt_digest_combine_u32(digest, combinedCount, counts.mechanismStateCount);
        for (uint index = 0u; index < counts.mechanismStateCount; ++index) {
            nt_digest_combine_float(digest, combinedCount, r.mechanismState[index]);
        }
        break;
    }
    case 6u: {
        digest = nt_digest_initialize(0x53594E4150534553ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->synapseCount);
        for (uint index = 0u; index < r.header->synapseCount; ++index) {
            const NTSynapseState value = r.synapses[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine_u32(digest, combinedCount, value.sourceRouteIndex);
            nt_digest_combine_u32(digest, combinedCount, value.targetCompartmentIndex);
            nt_digest_combine_u32(digest, combinedCount, value.parameterAndFlags & 0xFFFFu);
            nt_digest_combine_u32(digest, combinedCount, value.parameterAndFlags >> 16u);
            nt_digest_combine_u32(digest, combinedCount, value.delayTicks);
            nt_digest_combine_float4(digest, combinedCount, value.weightConductanceUtilizationResources);
            nt_digest_combine_float4(digest, combinedCount, value.prePostEligibilityConsolidation);
            nt_digest_combine_float(digest, combinedCount, value.structuralReserved.x);
            nt_digest_combine(digest, combinedCount, nt_u64(value.lastEventTickLo, value.lastEventTickHi));
        }
        break;
    }
    case 7u: {
        digest = nt_digest_initialize(0x4649454C44530001ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->fieldValueCount);
        for (uint index = 0u; index < r.header->fieldValueCount; ++index) {
            nt_digest_combine_float4(
                digest,
                combinedCount,
                r.fields[index].concentrationSourceSinkDiffusion
            );
        }
        break;
    }
    case 8u: {
        digest = nt_digest_initialize(0x4D4943524F444F4Dull);
        nt_digest_combine_u32(digest, combinedCount, r.header->microdomainCount);
        for (uint index = 0u; index < r.header->microdomainCount; ++index) {
            const NTMicrodomainState value = r.microdomains[index];
            nt_digest_combine(digest, combinedCount, nt_u64(value.idLo, value.idHi));
            nt_digest_combine_u32(digest, combinedCount, value.ownerCellIndex);
            nt_digest_combine_u32(digest, combinedCount, value.ownerCompartmentIndex);
            nt_digest_combine_u32(digest, combinedCount, value.reactionSolverFlags & 0xFFFFu);
            nt_digest_combine_u32(digest, combinedCount, (value.reactionSolverFlags >> 16u) & 0xFFu);
            nt_digest_combine_u32(digest, combinedCount, value.reactionSolverFlags >> 24u);
            nt_digest_combine_range(digest, combinedCount, value.speciesRange);
            nt_digest_combine_float(digest, combinedCount, value.volumeTemperaturePropensityReserved.x);
            nt_digest_combine_float(digest, combinedCount, value.volumeTemperaturePropensityReserved.y);
            nt_digest_combine(digest, combinedCount, nt_u64(value.nextEventTickLo, value.nextEventTickHi));
            nt_digest_combine_float(digest, combinedCount, value.volumeTemperaturePropensityReserved.z);
        }
        break;
    }
    default: {
        digest = nt_digest_initialize(0x4D4F4C4543554C41ull);
        nt_digest_combine_u32(digest, combinedCount, r.header->molecularSpeciesCount);
        for (uint index = 0u; index < r.header->molecularSpeciesCount; ++index) {
            nt_digest_combine_float(digest, combinedCount, r.molecularSpecies[index]);
        }
        break;
    }
    }

    output[gid] = nt_digest_finalize(digest, combinedCount);
}

#endif
