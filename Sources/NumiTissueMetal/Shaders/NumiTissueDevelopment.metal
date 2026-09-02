#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_DEVELOPMENT
#define NUMITISSUE_DEVELOPMENT

constant uint NT_CELL_REGULATORY_WIDTH = 32u;
constant uint NT_SEGMENT_GROWTH_CONE_FLAG = 1u << 0u;
constant uint NT_SYNAPSE_PRUNED_FLAG = 1u << 17u;

inline float3 nt_safe_normalize(float3 value, float3 fallback = float3(1.0f, 0.0f, 0.0f)) {
    const float norm2 = dot(value, value);
    return norm2 > 1.0e-12f ? value * rsqrt(norm2) : fallback;
}

kernel void nt_apply_plasticity(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    if ((synapse.parameterAndFlags & NT_SYNAPSE_PRUNED_FLAG) != 0u) { return; }

    const float dopamine = r.outputScalars[0u];
    const float acetylcholine = r.outputScalars[1u];
    const float norepinephrine = r.outputScalars[2u];
    const float serotonin = r.outputScalars[3u];
    const float threat = r.outputScalars[4u];
    const float novelty = r.outputScalars[5u];
    const float modulator = dopamine + 0.25f * acetylcholine + 0.15f * norepinephrine + 0.05f * serotonin - 0.25f * threat + 0.10f * novelty;
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    const float eligibility = synapse.prePostEligibilityConsolidation.z;
    const float consolidated = nt_clamp01(synapse.prePostEligibilityConsolidation.w);
    const float learningRate = mix(2.0e-4f, 2.0e-5f, consolidated);
    float weight = synapse.weightConductanceUtilizationResources.x;
    const float baseline = max(synapse.structuralReserved.y, 1.0e-6f);
    weight += dtSeconds * (learningRate * modulator * eligibility - 1.0e-5f * (weight - baseline));
    synapse.weightConductanceUtilizationResources.x = clamp(weight, 0.0f, 1000.0f);
    synapse.prePostEligibilityConsolidation.w = nt_clamp01(consolidated + dtSeconds * max(fabs(eligibility * modulator) - 0.01f, 0.0f) * 0.001f);
}

/// Overdamped ellipsoidal cell mechanics using tile-local neighbor loops. Every thread owns one
/// cell, so force accumulation is deterministic and requires no atomics.
kernel void nt_update_cell_mechanics(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->cellCount) { return; }
    device NTCellState& cell = r.cells[gid];
    if (cell.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[cell.tileIndex];
    float3 force = float3(0.0f);
    const float3 position = cell.position.xyz;
    const float ownRadius = max((cell.semiAxes.x + cell.semiAxes.y + cell.semiAxes.z) / 3.0f, 0.05f);

    const uint end = min(tile.cellRange.lowerBound + tile.cellRange.count, r.header->cellCount);
    for (uint otherIndex = tile.cellRange.lowerBound; otherIndex < end; ++otherIndex) {
        if (otherIndex == gid) { continue; }
        const NTCellState other = r.cells[otherIndex];
        const float3 displacement = position - other.position.xyz;
        const float distanceSquared = max(dot(displacement, displacement), 1.0e-8f);
        const float distance = sqrt(distanceSquared);
        const float otherRadius = max((other.semiAxes.x + other.semiAxes.y + other.semiAxes.z) / 3.0f, 0.05f);
        const float contactDistance = ownRadius + otherRadius;
        const float3 direction = displacement / distance;
        if (distance < contactDistance) {
            const float overlap = contactDistance - distance;
            force += direction * (0.5f * overlap + 0.02f * overlap * overlap);
        } else if (distance < contactDistance * 1.5f) {
            const float adhesion = (distance - contactDistance) / max(contactDistance * 0.5f, 1.0e-6f);
            force -= direction * 0.015f * (1.0f - adhesion);
        }
    }

    const float energy = nt_clamp01(cell.ageCycleDifferentiationEnergy.w);
    const float damage = nt_clamp01(cell.stressDamageHazard.z);
    const ulong transaction = nt_u64(r.header->transactionLo, r.header->transactionHi);
    const ulong cellID = nt_u64(cell.idLo, cell.idHi);
    uint4 random = nt_philox(uint4(uint(transaction), uint(transaction >> 32), uint(cellID), uint(cellID >> 32) ^ gid), uint2(r.header->randomSeedLo, r.header->randomSeedHi));
    const float3 motilityNoise = float3(nt_uniform01(random.x) - 0.5f, nt_uniform01(random.y) - 0.5f, nt_uniform01(random.z) - 0.5f);
    force += motilityNoise * 0.05f * energy * (1.0f - damage);

    const float drag = max(1.0f + 4.0f * ownRadius, 1.0e-4f);
    const float dt = 0.1f;
    const float3 velocity = force / drag;
    cell.velocity = float4(velocity, 0.0f);
    cell.position.xyz += velocity * dt;
}

inline float nt_field_gradient_component(
    constant NTResources& r,
    NTTileState tile,
    uint channel,
    uint voxel,
    int offset,
    uint voxelCount
) {
    const int candidate = int(voxel) + offset;
    if (candidate < 0 || candidate >= int(voxelCount)) { return 0.0f; }
    const uint index = tile.fieldRange.lowerBound + channel * voxelCount + uint(candidate);
    if (index >= r.header->fieldValueCount) { return 0.0f; }
    return r.fields[index].concentrationSourceSinkDiffusion.x;
}

kernel void nt_update_development(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    const float dtSeconds = 1.0f;
    if (gid < r.header->cellCount) {
        device NTCellState& cell = r.cells[gid];
        cell.ageCycleDifferentiationEnergy.x += dtSeconds;
        const float energy = nt_clamp01(cell.ageCycleDifferentiationEnergy.w);
        const float damage = nt_clamp01(cell.stressDamageHazard.z);
        const float stress = nt_clamp01(max(cell.stressDamageHazard.x, cell.stressDamageHazard.y));
        const NTRange range = cell.regulatoryRange;
        const uint count = min(range.count, NT_CELL_REGULATORY_WIDTH);
        if (range.lowerBound + count <= r.header->cellCount * NT_CELL_REGULATORY_WIDTH) {
            for (uint variable = 0u; variable < count; ++variable) {
                const uint index = range.lowerBound + variable;
                const float value = r.regulatoryState[index];
                const float upstream = variable > 0u ? r.regulatoryState[index - 1u] : energy;
                const float downstream = variable + 1u < count ? r.regulatoryState[index + 1u] : 0.0f;
                const float production = 0.05f * upstream + 0.01f * energy - 0.02f * stress;
                const float repression = 0.03f * downstream + 0.02f * value;
                r.regulatoryState[index] = nt_clamp01(value + dtSeconds * (production - repression));
            }
        }

        const float cycleRate = max(0.0f, 0.001f * energy * (1.0f - damage) * (1.0f - stress));
        cell.ageCycleDifferentiationEnergy.y += dtSeconds * cycleRate;
        const uint developmental = (cell.typeAndDevelopment >> 16u) & 0xFFFFu;
        if (developmental < 0xFFFFu && count > 0u) {
            const float fateDrive = r.regulatoryState[range.lowerBound + min(count - 1u, 7u)];
            cell.ageCycleDifferentiationEnergy.z = nt_clamp01(cell.ageCycleDifferentiationEnergy.z + dtSeconds * max(fateDrive - 0.5f, 0.0f) * 0.001f);
        }
        cell.stressDamageHazard.w = max(0.0f, 0.01f * stress + 0.02f * damage - 0.005f * energy);

        if (cell.ageCycleDifferentiationEnergy.y >= 1.0f) {
            const uint mutationSlot = atomic_fetch_add_explicit(&r.eventBucketCounts[4094u], 1u, memory_order_relaxed);
            const uint bucketCapacity = max(r.header->eventCapacity / 4096u, 1u);
            if (mutationSlot < bucketCapacity) {
                const ulong tick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
                const uint2 split = nt_split_u64(tick);
                r.localEvents[4094u * bucketCapacity + mutationSlot] = NTEvent{
                    split.x, split.y, cell.idLo, cell.idHi, gid, 0u,
                    6u, mutationSlot, 1.0f, 0.0f, 0.0f, 0.0f
                };
                cell.ageCycleDifferentiationEnergy.y = 0.0f;
            } else {
                nt_append_validation(r, 2001u, 1u, uint2(cell.idLo, cell.idHi), float(mutationSlot), gid);
            }
        }
    }

    if (gid < r.header->segmentCount) {
        device NTSegmentState& segment = r.segments[gid];
        const uint flags = segment.typeAndFlags >> 16u;
        if ((flags & NT_SEGMENT_GROWTH_CONE_FLAG) == 0u || segment.cellIndex >= r.header->cellCount) { return; }
        const NTCellState cell = r.cells[segment.cellIndex];
        if (cell.tileIndex >= r.header->tileCount) { return; }
        const NTTileState tile = r.tiles[cell.tileIndex];
        const uint width = max(r.header->fieldGridWidth, 1u);
        const uint height = max(r.header->fieldGridHeight, 1u);
        const uint depth = max(r.header->fieldGridDepth, 1u);
        const uint voxelCount = width * height * depth;
        float3 direction = nt_safe_normalize(segment.end.xyz - segment.start.xyz);
        if (tile.fieldRange.count >= voxelCount * max(r.header->fieldChannels, 1u)) {
            const float3 local = clamp(segment.end.xyz, float3(0.0f), float3(199.999f)) / 200.0f;
            const uint x = min(uint(local.x * float(width)), width - 1u);
            const uint y = min(uint(local.y * float(height)), height - 1u);
            const uint z = min(uint(local.z * float(depth)), depth - 1u);
            const uint voxel = x + width * (y + height * z);
            const uint attractive = 8u;
            const uint repulsive = 9u;
            const float gx = nt_field_gradient_component(r, tile, attractive, voxel, 1, voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -1, voxelCount);
            const float gy = nt_field_gradient_component(r, tile, attractive, voxel, int(width), voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -int(width), voxelCount);
            const float gz = nt_field_gradient_component(r, tile, attractive, voxel, int(width * height), voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -int(width * height), voxelCount);
            const float rx = nt_field_gradient_component(r, tile, repulsive, voxel, 1, voxelCount) - nt_field_gradient_component(r, tile, repulsive, voxel, -1, voxelCount);
            const float ry = nt_field_gradient_component(r, tile, repulsive, voxel, int(width), voxelCount) - nt_field_gradient_component(r, tile, repulsive, voxel, -int(width), voxelCount);
            const float rz = nt_field_gradient_component(r, tile, repulsive, voxel, int(width * height), voxelCount) - nt_field_gradient_component(r, tile, repulsive, voxel, -int(width * height), voxelCount);
            direction = nt_safe_normalize(0.75f * direction + 0.20f * float3(gx, gy, gz) - 0.25f * float3(rx, ry, rz));
        }
        const float growthRate = max(segment.radiusMyelinGrowthScore.z, 0.0f);
        segment.start = segment.end;
        segment.end.xyz += direction * growthRate * dtSeconds;
        segment.radiusMyelinGrowthScore.w = nt_clamp01(segment.radiusMyelinGrowthScore.w + 0.001f * growthRate);
    }
}

kernel void nt_update_structural_plasticity(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    if ((synapse.parameterAndFlags & NT_SYNAPSE_PRUNED_FLAG) != 0u) { return; }
    const float weight = synapse.weightConductanceUtilizationResources.x;
    const float eligibility = fabs(synapse.prePostEligibilityConsolidation.z);
    const float consolidation = nt_clamp01(synapse.prePostEligibilityConsolidation.w);
    float score = synapse.structuralReserved.x;
    score += 0.01f * eligibility + 0.005f * consolidation - 0.002f * (weight < 1.0e-6f ? 1.0f : 0.0f);
    score = nt_clamp01(score);
    synapse.structuralReserved.x = score;
    if (score < 0.01f && consolidation < 0.05f) {
        synapse.parameterAndFlags |= NT_SYNAPSE_PRUNED_FLAG;
        synapse.weightConductanceUtilizationResources.x = 0.0f;
        synapse.weightConductanceUtilizationResources.y = 0.0f;
        atomic_fetch_add_explicit(&r.counters->structuralMutations, 1u, memory_order_relaxed);
    }
}

kernel void nt_update_adaptive_fidelity(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->cellCount) { return; }
    device NTCellState& cell = r.cells[gid];
    if (cell.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[cell.tileIndex];
    const float score = clamp(
        0.30f * nt_clamp01(tile.scores.x) +
        0.30f * nt_clamp01(tile.scores.y) +
        0.25f * nt_clamp01(max(tile.scores.z, cell.stressDamageHazard.z)) +
        0.15f * nt_clamp01(max(tile.scores.w, max(cell.stressDamageHazard.x, cell.stressDamageHazard.y))),
        0.0f, 1.0f
    );
    uint fidelity = cell.fidelityAndFlags & 0xFFu;
    if (score >= 0.65f && fidelity < 4u) {
        fidelity++;
        atomic_fetch_add_explicit(&r.counters->promotedEntities, 1u, memory_order_relaxed);
    } else if (score <= 0.20f && fidelity > 0u) {
        fidelity--;
        atomic_fetch_add_explicit(&r.counters->demotedEntities, 1u, memory_order_relaxed);
    }
    cell.fidelityAndFlags = (cell.fidelityAndFlags & 0xFFFFFF00u) | fidelity;
}

#endif
