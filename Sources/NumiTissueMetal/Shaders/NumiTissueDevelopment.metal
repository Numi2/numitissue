#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_DEVELOPMENT
#define NUMITISSUE_DEVELOPMENT

constant uint NT_CELL_REGULATORY_WIDTH = 32u;
constant uint NT_SEGMENT_GROWTH_CONE_FLAG = 1u << 0u;
constant uint NT_SYNAPSE_PRUNED_FLAG = 1u << 17u;
constant uint NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT = 16u;
constant uint NT_CELL_PROGRAM_PARAMETER_STRIDE_DEVELOPMENT = 8u;
constant uint NT_REGULATORY_PARAMETER_STRIDE = 12u;
constant uint NT_FATE_PARAMETER_STRIDE = 12u;
constant uint NT_GROWTH_PARAMETER_STRIDE = 12u;
constant uint NT_TOPOLOGY_EVENT_KIND = 6u;
constant uint NT_TOPOLOGY_CREATE_SYNAPSE = 1u;
constant uint NT_TOPOLOGY_DIVIDE_CELL = 2u;
constant uint NT_TOPOLOGY_BRANCH_SEGMENT = 3u;
constant uint NT_TOPOLOGY_RETRACT_SEGMENT = 4u;
constant uint NT_TOPOLOGY_DELETE_CELL = 5u;
constant uint NT_SEGMENT_BASAL_DENDRITE = 1u;
constant uint NT_SEGMENT_APICAL_DENDRITE = 2u;
constant uint NT_SEGMENT_AXON = 3u;
constant uint NT_SEGMENT_GROWTH_CONE = 5u;
constant uint NT_SEGMENT_SPINE_HEAD = 7u;

inline float3 nt_safe_normalize(float3 value, float3 fallback = float3(1.0f, 0.0f, 0.0f)) {
    const float norm2 = dot(value, value);
    return norm2 > 1.0e-12f ? value * rsqrt(norm2) : fallback;
}

inline float nt_development_parameter(
    device const float* table,
    uint elementCount,
    uint stride,
    uint element,
    uint component,
    float fallback
) {
    if (element >= elementCount || component >= stride) { return fallback; }
    const float value = table[element * stride + component];
    return isfinite(value) ? value : fallback;
}

inline bool nt_append_topology_event(
    constant NTResources& r,
    uint2 source,
    uint2 destination,
    uint subtype,
    float amplitude,
    float payload0,
    float payload1,
    float payload2,
    uint sequence
) {
    const uint slot = atomic_fetch_add_explicit(&r.counters->generatedSpikesLo, 1u, memory_order_relaxed);
    if (slot >= r.header->eventCapacity) {
        atomic_fetch_add_explicit(&r.counters->rejectedMutations, 1u, memory_order_relaxed);
        nt_append_validation(r, 2001u, 1u, source, float(slot), sequence);
        return false;
    }
    const ulong tick = nt_u64(r.header->phaseEndTickLo, r.header->phaseEndTickHi);
    const uint2 split = nt_split_u64(tick);
    r.outgoingEvents[slot] = NTEvent{
        split.x, split.y,
        source.x, source.y,
        destination.x, destination.y,
        NT_TOPOLOGY_EVENT_KIND | (subtype << 16u),
        sequence,
        amplitude,
        payload0,
        payload1,
        payload2
    };
    atomic_fetch_add_explicit(&r.counters->structuralMutations, 1u, memory_order_relaxed);
    return true;
}

inline float nt_development_sigmoid(float value) {
    return 1.0f / (1.0f + exp(-clamp(value, -20.0f, 20.0f)));
}

inline uint nt_cell_program(const NTCellState cell) {
    return cell.typeAndDevelopment & 0xFFFFu;
}

inline uint nt_developmental_state(const NTCellState cell) {
    return (cell.typeAndDevelopment >> 16u) & 0xFFFFu;
}

inline void nt_set_cell_program(device NTCellState& cell, uint program) {
    cell.typeAndDevelopment = (cell.typeAndDevelopment & 0xFFFF0000u) | (program & 0xFFFFu);
}

inline void nt_set_developmental_state(device NTCellState& cell, uint state) {
    cell.typeAndDevelopment = (cell.typeAndDevelopment & 0x0000FFFFu) | ((state & 0xFFFFu) << 16u);
}

inline uint nt_find_cell_program_for_kind(
    device const uint4* cellProgramIdentity,
    uint cellProgramCount,
    uint kind,
    uint fallback
) {
    for (uint program = 0u; program < cellProgramCount; ++program) {
        if (cellProgramIdentity[program].x == kind) { return program; }
    }
    return fallback;
}

inline uint4 nt_development_random(constant NTResources& r, uint2 entity, uint stream) {
    const ulong transaction = nt_u64(r.header->transactionLo, r.header->transactionHi);
    return nt_philox(
        uint4(uint(transaction), uint(transaction >> 32) ^ stream, entity.x, entity.y ^ stream),
        uint2(r.header->randomSeedLo, r.header->randomSeedHi)
    );
}

kernel void nt_apply_plasticity(
    constant NTResources& r [[buffer(0)]],
    device const float* synapseParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    if ((synapse.parameterAndFlags & NT_SYNAPSE_PRUNED_FLAG) != 0u) { return; }

    const uint parameter = synapse.parameterAndFlags & 0xFFFFu;
    const uint parameterCount = r.header->reserved2.y;
    const float positiveAmplitude = nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 8u, 1.0f);
    const float negativeAmplitude = nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 9u, -1.0f);
    const float eligibilityDecay = clamp(nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 12u, 0.999f), 0.0f, 1.0f);
    const float learningRate = max(nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 13u, 2.0e-4f), 0.0f);
    const float minimumWeight = nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 14u, 0.0f);
    const float maximumWeight = max(nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 15u, 1000.0f), minimumWeight);

    if (synapse.targetCompartmentIndex < r.header->compartmentCount) {
        const NTCompartmentState target = r.compartments[synapse.targetCompartmentIndex];
        const uint targetBase = nt_mechanism_base(target, synapse.targetCompartmentIndex);
        if (r.mechanismState[targetBase + 15u] > 0.0f) {
            synapse.prePostEligibilityConsolidation.y += 1.0f;
            synapse.prePostEligibilityConsolidation.z += negativeAmplitude * synapse.prePostEligibilityConsolidation.x;
        }
    }
    if (synapse.sourceRouteIndex < r.header->compartmentCount) {
        const NTCompartmentState source = r.compartments[synapse.sourceRouteIndex];
        const uint sourceBase = nt_mechanism_base(source, synapse.sourceRouteIndex);
        if (r.mechanismState[sourceBase + 15u] > 0.0f) {
            synapse.prePostEligibilityConsolidation.z += positiveAmplitude * synapse.prePostEligibilityConsolidation.y;
        }
    }

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
    const float effectiveLearningRate = mix(learningRate, 0.1f * learningRate, consolidated);
    float weight = synapse.weightConductanceUtilizationResources.x;
    const float baseline = max(synapse.structuralReserved.y, minimumWeight);
    weight += dtSeconds * (effectiveLearningRate * modulator * eligibility - 1.0e-5f * (weight - baseline));
    synapse.weightConductanceUtilizationResources.x = clamp(weight, minimumWeight, maximumWeight);
    const float baseQuantum = max(float(r.header->fastQuantumTicks) * NT_TICK_MILLISECONDS, NT_TICK_MILLISECONDS);
    synapse.prePostEligibilityConsolidation.z *= pow(eligibilityDecay, max(r.header->dtMilliseconds / baseQuantum, 1.0f));
    synapse.prePostEligibilityConsolidation.w = nt_clamp01(consolidated + dtSeconds * max(fabs(eligibility * modulator) - 0.01f, 0.0f) * 0.001f);
}

/// Overdamped ellipsoidal cell mechanics using tile-local neighbor loops. Mechanical coefficients
/// and nominal radius are read from the transaction-local effective cell-program table.
kernel void nt_update_cell_mechanics(
    constant NTResources& r [[buffer(0)]],
    device const float* cellProgramParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->cellCount) { return; }
    device NTCellState& cell = r.cells[gid];
    if (cell.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[cell.tileIndex];
    const uint program = nt_cell_program(cell);
    const uint programCount = r.header->reserved2.w;
    const float nominalRadius = max(nt_development_parameter(cellProgramParameters, programCount, NT_CELL_PROGRAM_PARAMETER_STRIDE_DEVELOPMENT, program, 0u, 5.0f), 0.05f);
    const float repulsionScale = max(nt_development_parameter(cellProgramParameters, programCount, NT_CELL_PROGRAM_PARAMETER_STRIDE_DEVELOPMENT, program, 1u, 1.0f), 0.0f);
    const float adhesionScale = max(nt_development_parameter(cellProgramParameters, programCount, NT_CELL_PROGRAM_PARAMETER_STRIDE_DEVELOPMENT, program, 2u, 1.0f), 0.0f);
    const float motilityScale = max(nt_development_parameter(cellProgramParameters, programCount, NT_CELL_PROGRAM_PARAMETER_STRIDE_DEVELOPMENT, program, 3u, 1.0f), 0.0f);
    float3 force = float3(0.0f);
    const float3 position = cell.position.xyz;
    const float ownRadius = max((cell.semiAxes.x + cell.semiAxes.y + cell.semiAxes.z) / 3.0f, nominalRadius * 0.1f);

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
            force += direction * repulsionScale * (0.5f * overlap + 0.02f * overlap * overlap);
        } else if (distance < contactDistance * 1.5f) {
            const float adhesion = (distance - contactDistance) / max(contactDistance * 0.5f, 1.0e-6f);
            force -= direction * adhesionScale * 0.015f * (1.0f - adhesion);
        }
    }

    const float energy = nt_clamp01(cell.ageCycleDifferentiationEnergy.w);
    const float damage = nt_clamp01(cell.stressDamageHazard.z);
    const uint4 random = nt_development_random(r, uint2(cell.idLo, cell.idHi), 0x4D454348u);
    const float3 motilityNoise = float3(nt_uniform01(random.x) - 0.5f, nt_uniform01(random.y) - 0.5f, nt_uniform01(random.z) - 0.5f);
    force += motilityNoise * 0.05f * motilityScale * energy * (1.0f - damage);

    const float drag = max(1.0f + 4.0f * ownRadius, 1.0e-4f);
    const float dt = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
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

inline float nt_field_at_cell(
    constant NTResources& r,
    NTCellState cell,
    uint channel
) {
    if (cell.tileIndex >= r.header->tileCount) { return 0.0f; }
    const NTTileState tile = r.tiles[cell.tileIndex];
    const uint width = max(r.header->fieldGridWidth, 1u);
    const uint height = max(r.header->fieldGridHeight, 1u);
    const uint depth = max(r.header->fieldGridDepth, 1u);
    const uint voxelCount = width * height * depth;
    if (tile.fieldRange.count < voxelCount * max(r.header->fieldChannels, 1u)) { return 0.0f; }
    const float3 local = clamp(cell.position.xyz, float3(0.0f), float3(199.999f)) / 200.0f;
    const uint x = min(uint(local.x * float(width)), width - 1u);
    const uint y = min(uint(local.y * float(height)), height - 1u);
    const uint z = min(uint(local.z * float(depth)), depth - 1u);
    const uint voxel = x + width * (y + height * z);
    const uint index = tile.fieldRange.lowerBound + channel * voxelCount + voxel;
    return index < r.header->fieldValueCount ? r.fields[index].concentrationSourceSinkDiffusion.x : 0.0f;
}

inline void nt_update_regulatory_program(
    constant NTResources& r,
    device NTCellState& cell,
    uint regulatoryProgram,
    device const uint4* regulatoryStateAndMatrix,
    device const uint4* regulatoryBiasAndTransition,
    device const float* regulatoryMatrix,
    device const float* regulatoryBias,
    device const float* regulatoryParameters,
    uint regulatoryProgramCount,
    float dtSeconds
) {
    if (regulatoryProgram >= regulatoryProgramCount) { return; }
    const uint4 topology = regulatoryStateAndMatrix[regulatoryProgram];
    const uint4 biasTopology = regulatoryBiasAndTransition[regulatoryProgram];
    const uint count = min(min(cell.regulatoryRange.count, topology.x), NT_CELL_REGULATORY_WIDTH);
    if (count == 0u || cell.regulatoryRange.lowerBound + count > r.header->cellCount * NT_CELL_REGULATORY_WIDTH) { return; }
    float current[NT_CELL_REGULATORY_WIDTH];
    float next[NT_CELL_REGULATORY_WIDTH];
    for (uint index = 0u; index < count; ++index) { current[index] = r.regulatoryState[cell.regulatoryRange.lowerBound + index]; }
    for (uint row = 0u; row < count; ++row) {
        float drive = regulatoryBias[biasTopology.x + row];
        const uint rowOffset = topology.y + row * count;
        for (uint column = 0u; column < count; ++column) {
            drive += regulatoryMatrix[rowOffset + column] * current[column];
        }
        drive += row == 0u ? 0.1f * cell.ageCycleDifferentiationEnergy.w : 0.0f;
        drive -= row == 1u ? 0.1f * max(cell.stressDamageHazard.x, cell.stressDamageHazard.y) : 0.0f;
        const uint timeConstantLane = min(row, 7u);
        const float tau = max(nt_development_parameter(regulatoryParameters, regulatoryProgramCount, NT_REGULATORY_PARAMETER_STRIDE, regulatoryProgram, timeConstantLane, 1.0f), 1.0e-4f);
        const float target = nt_development_sigmoid(drive);
        next[row] = nt_clamp01(current[row] + dtSeconds * (target - current[row]) / tau);
    }
    for (uint index = 0u; index < count; ++index) { r.regulatoryState[cell.regulatoryRange.lowerBound + index] = next[index]; }
}

inline void nt_evaluate_cell_fate(
    constant NTResources& r,
    device NTCellState& cell,
    uint regulatoryProgram,
    device const uint4* cellProgramIdentity,
    device const uint4* regulatoryBiasAndTransition,
    device const uint4* fateIdentity,
    device const float* fateParameters,
    uint cellProgramCount,
    uint regulatoryProgramCount,
    uint fateTransitionCount,
    float dtSeconds
) {
    if (regulatoryProgram >= regulatoryProgramCount) { return; }
    const uint4 transitionRange = regulatoryBiasAndTransition[regulatoryProgram];
    const uint lower = transitionRange.y;
    const uint upper = min(lower + transitionRange.z, fateTransitionCount);
    if (lower >= upper) { return; }
    const uint4 random = nt_development_random(r, uint2(cell.idLo, cell.idHi), 0x46415445u);
    const float sample = nt_uniform01(random.x);
    float cumulative = 0.0f;
    for (uint transition = lower; transition < upper; ++transition) {
        const float minimumAge = max(nt_development_parameter(fateParameters, fateTransitionCount, NT_FATE_PARAMETER_STRIDE, transition, 1u, 0.0f), 0.0f);
        if (cell.ageCycleDifferentiationEnergy.x < minimumAge) { continue; }
        float logHazard = log(max(nt_development_parameter(fateParameters, fateTransitionCount, NT_FATE_PARAMETER_STRIDE, transition, 0u, 0.0f), 1.0e-30f));
        const uint stateCount = min(cell.regulatoryRange.count, 4u);
        for (uint lane = 0u; lane < stateCount; ++lane) {
            logHazard += nt_development_parameter(fateParameters, fateTransitionCount, NT_FATE_PARAMETER_STRIDE, transition, 4u + lane, 0.0f) * r.regulatoryState[cell.regulatoryRange.lowerBound + lane];
        }
        for (uint lane = 0u; lane < 4u; ++lane) {
            logHazard += nt_development_parameter(fateParameters, fateTransitionCount, NT_FATE_PARAMETER_STRIDE, transition, 8u + lane, 0.0f) * nt_field_at_cell(r, cell, lane);
        }
        const float probability = 1.0f - exp(-exp(clamp(logHazard, -40.0f, 20.0f)) * dtSeconds);
        cumulative += probability;
        if (sample < min(cumulative, 1.0f)) {
            const uint targetKind = fateIdentity[transition].x;
            const uint targetProgram = nt_find_cell_program_for_kind(cellProgramIdentity, cellProgramCount, targetKind, nt_cell_program(cell));
            nt_set_cell_program(cell, targetProgram);
            nt_set_developmental_state(cell, 5u);
            cell.ageCycleDifferentiationEnergy.z = 0.0f;
            return;
        }
    }
}

inline void nt_update_cell_development(
    constant NTResources& r,
    device const uint4* cellProgramIdentity,
    device const uint4* cellProgramMetadata,
    device const uint4* regulatoryStateAndMatrix,
    device const uint4* regulatoryBiasAndTransition,
    device const float* regulatoryMatrix,
    device const float* regulatoryBias,
    device const uint4* fateIdentity,
    device const float* regulatoryParameters,
    device const float* fateParameters,
    uint gid,
    float dtSeconds
) {
    device NTCellState& cell = r.cells[gid];
    const uint cellProgramCount = r.header->reserved2.w;
    const uint regulatoryProgramCount = r.header->reserved0.z;
    const uint fateTransitionCount = r.header->reserved0.w;
    const uint program = nt_cell_program(cell);
    const uint regulatoryProgram = program < cellProgramCount ? cellProgramMetadata[program].y : NT_INVALID_INDEX;

    cell.ageCycleDifferentiationEnergy.x += dtSeconds;
    nt_update_regulatory_program(
        r,
        cell,
        regulatoryProgram,
        regulatoryStateAndMatrix,
        regulatoryBiasAndTransition,
        regulatoryMatrix,
        regulatoryBias,
        regulatoryParameters,
        regulatoryProgramCount,
        dtSeconds
    );

    const float energy = nt_clamp01(cell.ageCycleDifferentiationEnergy.w);
    const float damage = nt_clamp01(cell.stressDamageHazard.z);
    const float stress = nt_clamp01(max(cell.stressDamageHazard.x, cell.stressDamageHazard.y));
    const float divisionHazard = regulatoryProgram < regulatoryProgramCount
        ? max(nt_development_parameter(regulatoryParameters, regulatoryProgramCount, NT_REGULATORY_PARAMETER_STRIDE, regulatoryProgram, 8u, 0.001f), 0.0f)
        : 0.001f;
    const float apoptosisBase = regulatoryProgram < regulatoryProgramCount
        ? max(nt_development_parameter(regulatoryParameters, regulatoryProgramCount, NT_REGULATORY_PARAMETER_STRIDE, regulatoryProgram, 9u, 0.0f), 0.0f)
        : 0.0f;
    const float cycleRate = divisionHazard * energy * (1.0f - damage) * (1.0f - stress);
    cell.ageCycleDifferentiationEnergy.y += dtSeconds * cycleRate;
    cell.ageCycleDifferentiationEnergy.z = nt_clamp01(cell.ageCycleDifferentiationEnergy.z + dtSeconds * 0.01f * (energy - stress));
    cell.stressDamageHazard.w = max(0.0f, apoptosisBase + 0.01f * stress + 0.02f * damage - 0.005f * energy);

    nt_evaluate_cell_fate(
        r,
        cell,
        regulatoryProgram,
        cellProgramIdentity,
        regulatoryBiasAndTransition,
        fateIdentity,
        fateParameters,
        cellProgramCount,
        regulatoryProgramCount,
        fateTransitionCount,
        dtSeconds
    );

    if (cell.ageCycleDifferentiationEnergy.y >= 1.0f) {
        if (nt_append_topology_event(
            r,
            uint2(cell.idLo, cell.idHi),
            uint2(0u, 0u),
            NT_TOPOLOGY_DIVIDE_CELL,
            cell.ageCycleDifferentiationEnergy.y,
            float(gid),
            float(nt_cell_program(cell)),
            float(nt_developmental_state(cell)),
            gid
        )) {
            cell.ageCycleDifferentiationEnergy.y = 0.0f;
            nt_set_developmental_state(cell, 4u);
        }
    }

    const float apoptosisProbability = 1.0f - exp(-cell.stressDamageHazard.w * dtSeconds);
    const uint4 deathRandom = nt_development_random(r, uint2(cell.idLo, cell.idHi), 0x44454144u);
    if (nt_uniform01(deathRandom.x) < apoptosisProbability && nt_developmental_state(cell) < 10u) {
        nt_set_developmental_state(cell, 10u);
        nt_append_topology_event(
            r,
            uint2(cell.idLo, cell.idHi),
            uint2(0u, 0u),
            NT_TOPOLOGY_DELETE_CELL,
            apoptosisProbability,
            float(gid),
            0.0f,
            0.0f,
            gid
        );
    }
}

inline uint nt_growth_program_for_segment(
    constant NTResources& r,
    const NTSegmentState segment,
    device const uint4* cellProgramMetadata,
    device const uint4* regulatoryStateAndMatrix
) {
    if (segment.cellIndex >= r.header->cellCount) { return NT_INVALID_INDEX; }
    const NTCellState cell = r.cells[segment.cellIndex];
    const uint program = nt_cell_program(cell);
    if (program >= r.header->reserved2.w) { return NT_INVALID_INDEX; }
    const uint regulatoryProgram = cellProgramMetadata[program].y;
    if (regulatoryProgram >= r.header->reserved0.z) { return NT_INVALID_INDEX; }
    return regulatoryStateAndMatrix[regulatoryProgram].w;
}

inline void nt_propose_synapse_for_growth_cone(
    constant NTResources& r,
    const NTSegmentState source,
    uint sourceIndex,
    const NTTileState tile,
    uint4 random,
    float dtSeconds
) {
    const uint sourceKind = source.typeAndFlags & 0xFFFFu;
    if (sourceKind != NT_SEGMENT_AXON && sourceKind != NT_SEGMENT_GROWTH_CONE) { return; }
    if (source.compartmentIndex == NT_INVALID_INDEX || source.compartmentIndex >= r.header->compartmentCount) { return; }
    const uint end = min(tile.segmentRange.lowerBound + tile.segmentRange.count, r.header->segmentCount);
    uint bestIndex = NT_INVALID_INDEX;
    float bestDistance = 2.5f;
    for (uint targetIndex = tile.segmentRange.lowerBound; targetIndex < end; ++targetIndex) {
        if (targetIndex == sourceIndex) { continue; }
        const NTSegmentState target = r.segments[targetIndex];
        if (target.cellIndex == source.cellIndex || target.compartmentIndex == NT_INVALID_INDEX || target.compartmentIndex >= r.header->compartmentCount) { continue; }
        const uint kind = target.typeAndFlags & 0xFFFFu;
        if (kind != NT_SEGMENT_BASAL_DENDRITE && kind != NT_SEGMENT_APICAL_DENDRITE && kind != NT_SEGMENT_SPINE_HEAD) { continue; }
        const float distance = length(source.end.xyz - target.end.xyz);
        if (distance < bestDistance) { bestDistance = distance; bestIndex = targetIndex; }
    }
    if (bestIndex == NT_INVALID_INDEX) { return; }
    const NTSegmentState target = r.segments[bestIndex];
    const float proximity = nt_clamp01(1.0f - bestDistance / 2.5f);
    const float activity = nt_clamp01(tile.scores.x);
    const float hazard = 0.02f * proximity * (0.25f + 0.75f * activity);
    const float probability = 1.0f - exp(-hazard * dtSeconds);
    if (nt_uniform01(random.w) < probability) {
        nt_append_topology_event(
            r,
            uint2(source.idLo, source.idHi),
            uint2(target.idLo, target.idHi),
            NT_TOPOLOGY_CREATE_SYNAPSE,
            proximity,
            float(source.compartmentIndex),
            float(target.compartmentIndex),
            0.0f,
            sourceIndex
        );
    }
}

inline void nt_update_growth_cone(
    constant NTResources& r,
    device const uint4* cellProgramMetadata,
    device const uint4* regulatoryStateAndMatrix,
    device const float* growthParameters,
    uint gid,
    float dtSeconds
) {
    device NTSegmentState& segment = r.segments[gid];
    const uint flags = segment.typeAndFlags >> 16u;
    const uint segmentKind = segment.typeAndFlags & 0xFFFFu;
    if ((flags & NT_SEGMENT_GROWTH_CONE_FLAG) == 0u && segmentKind != NT_SEGMENT_GROWTH_CONE) { return; }
    if (segment.cellIndex >= r.header->cellCount) { return; }
    const NTCellState cell = r.cells[segment.cellIndex];
    if (cell.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[cell.tileIndex];
    const uint growthProgram = nt_growth_program_for_segment(r, segment, cellProgramMetadata, regulatoryStateAndMatrix);
    const uint growthProgramCount = r.header->reserved1.w;
    if (growthProgram >= growthProgramCount) { return; }

    const float speed = max(nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 0u, segment.radiusMyelinGrowthScore.z), 0.0f);
    const float branchHazard = max(nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 1u, 0.0f), 0.0f);
    const float retractionHazard = max(nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 2u, 0.0f), 0.0f);
    const float segmentLength = max(nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 3u, 2.0f), 0.1f);
    const float persistence = nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 4u, 0.75f);
    const float attraction = nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 5u, 0.2f);
    const float repulsion = nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 6u, 0.25f);
    const float fasciculation = nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 7u, 0.0f);
    const float activityWeight = nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 8u, 0.1f);
    const float noiseWeight = max(nt_development_parameter(growthParameters, growthProgramCount, NT_GROWTH_PARAMETER_STRIDE, growthProgram, 9u, 0.05f), 0.0f);
    uint4 random = nt_development_random(r, uint2(segment.idLo, segment.idHi), 0x47524F57u);
    float3 direction = nt_safe_normalize(segment.end.xyz - segment.start.xyz);

    const uint width = max(r.header->fieldGridWidth, 1u);
    const uint height = max(r.header->fieldGridHeight, 1u);
    const uint depth = max(r.header->fieldGridDepth, 1u);
    const uint voxelCount = width * height * depth;
    float3 guidance = float3(0.0f);
    if (tile.fieldRange.count >= voxelCount * max(r.header->fieldChannels, 1u)) {
        const float3 local = clamp(segment.end.xyz, float3(0.0f), float3(199.999f)) / 200.0f;
        const uint x = min(uint(local.x * float(width)), width - 1u);
        const uint y = min(uint(local.y * float(height)), height - 1u);
        const uint z = min(uint(local.z * float(depth)), depth - 1u);
        const uint voxel = x + width * (y + height * z);
        const uint attractive = 8u;
        const uint repulsiveChannel = 9u;
        const float3 attractiveGradient = float3(
            nt_field_gradient_component(r, tile, attractive, voxel, 1, voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -1, voxelCount),
            nt_field_gradient_component(r, tile, attractive, voxel, int(width), voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -int(width), voxelCount),
            nt_field_gradient_component(r, tile, attractive, voxel, int(width * height), voxelCount) - nt_field_gradient_component(r, tile, attractive, voxel, -int(width * height), voxelCount)
        );
        const float3 repulsiveGradient = float3(
            nt_field_gradient_component(r, tile, repulsiveChannel, voxel, 1, voxelCount) - nt_field_gradient_component(r, tile, repulsiveChannel, voxel, -1, voxelCount),
            nt_field_gradient_component(r, tile, repulsiveChannel, voxel, int(width), voxelCount) - nt_field_gradient_component(r, tile, repulsiveChannel, voxel, -int(width), voxelCount),
            nt_field_gradient_component(r, tile, repulsiveChannel, voxel, int(width * height), voxelCount) - nt_field_gradient_component(r, tile, repulsiveChannel, voxel, -int(width * height), voxelCount)
        );
        guidance = attraction * attractiveGradient - repulsion * repulsiveGradient;
    }

    float3 fascicle = float3(0.0f);
    if (fasciculation != 0.0f) {
        const uint end = min(tile.segmentRange.lowerBound + tile.segmentRange.count, r.header->segmentCount);
        uint count = 0u;
        for (uint index = tile.segmentRange.lowerBound; index < end && count < 16u; ++index) {
            if (index == gid) { continue; }
            const NTSegmentState other = r.segments[index];
            const uint kind = other.typeAndFlags & 0xFFFFu;
            if (kind != NT_SEGMENT_AXON && kind != NT_SEGMENT_GROWTH_CONE) { continue; }
            const float distance = length(other.end.xyz - segment.end.xyz);
            if (distance < 10.0f) {
                fascicle += nt_safe_normalize(other.end.xyz - other.start.xyz);
                count++;
            }
        }
        if (count > 0u) { fascicle = nt_safe_normalize(fascicle); }
    }
    const float3 noise = float3(nt_uniform01(random.x) - 0.5f, nt_uniform01(random.y) - 0.5f, nt_uniform01(random.z) - 0.5f);
    const float3 activityDirection = direction * nt_clamp01(tile.scores.x);
    direction = nt_safe_normalize(persistence * direction + guidance + fasciculation * fascicle + activityWeight * activityDirection + noiseWeight * noise);

    const float advance = min(speed * dtSeconds, segmentLength);
    segment.start = segment.end;
    segment.end.xyz += direction * advance;
    segment.radiusMyelinGrowthScore.z = speed;
    segment.radiusMyelinGrowthScore.w = nt_clamp01(segment.radiusMyelinGrowthScore.w + 0.001f * advance);

    const float branchProbability = 1.0f - exp(-branchHazard * dtSeconds);
    const float retractProbability = 1.0f - exp(-retractionHazard * dtSeconds);
    if (nt_uniform01(random.x) < branchProbability) {
        nt_append_topology_event(r, uint2(segment.idLo, segment.idHi), uint2(0u, 0u), NT_TOPOLOGY_BRANCH_SEGMENT, branchProbability, direction.x, direction.y, direction.z, gid);
    } else if (nt_uniform01(random.y) < retractProbability) {
        nt_append_topology_event(r, uint2(segment.idLo, segment.idHi), uint2(0u, 0u), NT_TOPOLOGY_RETRACT_SEGMENT, retractProbability, advance, 0.0f, 0.0f, gid);
    }
    nt_propose_synapse_for_growth_cone(r, segment, gid, tile, random, dtSeconds);
}

kernel void nt_update_development(
    constant NTResources& r [[buffer(0)]],
    device const uint4* cellProgramIdentity [[buffer(1)]],
    device const uint4* cellProgramMetadata [[buffer(2)]],
    device const uint4* regulatoryStateAndMatrix [[buffer(3)]],
    device const uint4* regulatoryBiasAndTransition [[buffer(4)]],
    device const float* regulatoryMatrix [[buffer(5)]],
    device const float* regulatoryBias [[buffer(6)]],
    device const uint4* fateIdentity [[buffer(7)]],
    device const float* regulatoryParameters [[buffer(8)]],
    device const float* fateParameters [[buffer(9)]],
    device const float* growthParameters [[buffer(10)]],
    device const float* cellProgramParameters [[buffer(11)]],
    uint gid [[thread_position_in_grid]]
) {
    (void)cellProgramParameters;
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    if (gid < r.header->cellCount) {
        nt_update_cell_development(
            r,
            cellProgramIdentity,
            cellProgramMetadata,
            regulatoryStateAndMatrix,
            regulatoryBiasAndTransition,
            regulatoryMatrix,
            regulatoryBias,
            fateIdentity,
            regulatoryParameters,
            fateParameters,
            gid,
            dtSeconds
        );
    }
    if (gid < r.header->segmentCount) {
        nt_update_growth_cone(r, cellProgramMetadata, regulatoryStateAndMatrix, growthParameters, gid, dtSeconds);
    }
}

kernel void nt_update_structural_plasticity(
    constant NTResources& r [[buffer(0)]],
    device const float* synapseParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    if ((synapse.parameterAndFlags & NT_SYNAPSE_PRUNED_FLAG) != 0u) { return; }
    const uint parameter = synapse.parameterAndFlags & 0xFFFFu;
    const uint parameterCount = r.header->reserved2.y;
    const float minimumWeight = nt_development_parameter(synapseParameters, parameterCount, NT_SYNAPSE_PARAMETER_STRIDE_DEVELOPMENT, parameter, 14u, 0.0f);
    const float weight = synapse.weightConductanceUtilizationResources.x;
    const float eligibility = fabs(synapse.prePostEligibilityConsolidation.z);
    const float consolidation = nt_clamp01(synapse.prePostEligibilityConsolidation.w);
    const float activityEvidence = nt_clamp01(synapse.prePostEligibilityConsolidation.x + synapse.prePostEligibilityConsolidation.y);
    float score = synapse.structuralReserved.x;
    score += 0.01f * eligibility + 0.005f * consolidation + 0.002f * activityEvidence - 0.002f * (weight <= minimumWeight ? 1.0f : 0.0f);
    score = nt_clamp01(score);
    synapse.structuralReserved.x = score;
    if (score < 0.01f && consolidation < 0.05f) {
        synapse.parameterAndFlags |= NT_SYNAPSE_PRUNED_FLAG;
        synapse.weightConductanceUtilizationResources.x = 0.0f;
        synapse.weightConductanceUtilizationResources.y = 0.0f;
        atomic_fetch_add_explicit(&r.counters->structuralMutations, 1u, memory_order_relaxed);
    }
}

/// GPU policy pass selects target fidelity. The host-side topology migrator performs pool
/// reconstruction and GPU arena replacement after validation and before transaction commit.
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
        0.25f * nt_clamp01(tile.scores.y) +
        0.25f * nt_clamp01(max(tile.scores.z, cell.stressDamageHazard.z)) +
        0.20f * nt_clamp01(max(tile.scores.w, max(cell.stressDamageHazard.x, cell.stressDamageHazard.y))),
        0.0f, 1.0f
    );
    uint fidelity = cell.fidelityAndFlags & 0xFFu;
    uint residence = (cell.fidelityAndFlags >> 8u) & 0xFFu;
    residence = min(residence + 1u, 255u);
    if (residence >= 4u && score >= 0.70f && fidelity < 4u) {
        fidelity++;
        residence = 0u;
        atomic_fetch_add_explicit(&r.counters->promotedEntities, 1u, memory_order_relaxed);
    } else if (residence >= 16u && score <= 0.15f && fidelity > 0u) {
        fidelity--;
        residence = 0u;
        atomic_fetch_add_explicit(&r.counters->demotedEntities, 1u, memory_order_relaxed);
    }
    cell.fidelityAndFlags = (cell.fidelityAndFlags & 0xFFFF0000u) | (residence << 8u) | fidelity;
}

#endif
