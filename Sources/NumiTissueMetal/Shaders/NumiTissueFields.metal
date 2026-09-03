#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_FIELDS
#define NUMITISSUE_FIELDS

constant uint NT_FIELD_PARAMETER_STRIDE = 8u;
constant uint NT_CELL_PROGRAM_PARAMETER_STRIDE_FIELDS = 8u;
constant uint NT_GLIAL_PARAMETER_STRIDE = 16u;
constant uint NT_CELL_KIND_ASTROCYTE = 4u;
constant uint NT_CELL_KIND_OLIGODENDROCYTE_PRECURSOR = 5u;
constant uint NT_CELL_KIND_OLIGODENDROCYTE = 6u;
constant uint NT_CELL_KIND_MICROGLIA = 7u;
constant uint NT_CELL_KIND_ENDOTHELIAL = 8u;
constant uint NT_CELL_KIND_PERIVASCULAR = 9u;
constant uint NT_SEGMENT_KIND_AXON = 3u;
constant uint NT_SEGMENT_KIND_AXON_INITIAL = 4u;
constant uint NT_SEGMENT_KIND_MYELINATED_AXON = 8u;
constant uint NT_SYNAPSE_PRUNED_FLAG_FIELDS = 1u << 17u;

inline uint nt_voxel_index(uint x, uint y, uint z, uint width, uint height) {
    return x + width * (y + height * z);
}

inline float nt_field_concentration(
    constant NTResources& r,
    uint base,
    uint channel,
    uint voxel,
    uint voxelCount
) {
    const uint index = base + channel * voxelCount + voxel;
    if (index >= r.header->fieldValueCount) { return 0.0f; }
    return r.fields[index].concentrationSourceSinkDiffusion.x;
}

inline float nt_field_parameter(
    device const float* parameters,
    uint parameterCount,
    uint channel,
    uint component,
    float fallback
) {
    if (channel >= parameterCount || component >= NT_FIELD_PARAMETER_STRIDE) { return fallback; }
    const float value = parameters[channel * NT_FIELD_PARAMETER_STRIDE + component];
    return isfinite(value) ? value : fallback;
}

inline uint nt_cell_kind(
    const NTCellState cell,
    device const uint4* cellProgramIdentity,
    uint cellProgramCount
) {
    const uint program = cell.typeAndDevelopment & 0xFFFFu;
    return program < cellProgramCount ? cellProgramIdentity[program].x : 0xFFFFu;
}

inline uint nt_glial_program_index(
    const NTCellState cell,
    device const uint4* cellProgramMetadata,
    uint cellProgramCount
) {
    const uint program = cell.typeAndDevelopment & 0xFFFFu;
    return program < cellProgramCount ? cellProgramMetadata[program].z : NT_INVALID_INDEX;
}

inline float nt_glial_parameter(
    device const float* parameters,
    uint programCount,
    uint program,
    uint component,
    float fallback
) {
    if (program >= programCount || component >= NT_GLIAL_PARAMETER_STRIDE) { return fallback; }
    const float value = parameters[program * NT_GLIAL_PARAMETER_STRIDE + component];
    return isfinite(value) ? value : fallback;
}

inline uint nt_cell_voxel(
    const NTCellState cell,
    uint width,
    uint height,
    uint depth
) {
    const float3 local = clamp(cell.position.xyz, float3(0.0f), float3(199.999f)) / 200.0f;
    const uint x = min(uint(local.x * float(width)), width - 1u);
    const uint y = min(uint(local.y * float(height)), height - 1u);
    const uint z = min(uint(local.z * float(depth)), depth - 1u);
    return nt_voxel_index(x, y, z, width, height);
}

inline device NTFieldState* nt_cell_field(
    constant NTResources& r,
    const NTTileState tile,
    uint channel,
    uint voxel,
    uint voxelCount
) {
    const uint index = tile.fieldRange.lowerBound + channel * voxelCount + voxel;
    return index < r.header->fieldValueCount ? &r.fields[index] : nullptr;
}

inline void nt_atomic_field_source(device NTFieldState* field, float amount) {
    if (field == nullptr || amount == 0.0f) { return; }
    device atomic_float* source = reinterpret_cast<device atomic_float*>(&field->concentrationSourceSinkDiffusion.y);
    atomic_fetch_add_explicit(source, amount, memory_order_relaxed);
}

inline void nt_atomic_field_sink(device NTFieldState* field, float amount) {
    if (field == nullptr || amount == 0.0f) { return; }
    device atomic_float* sink = reinterpret_cast<device atomic_float*>(&field->concentrationSourceSinkDiffusion.z);
    atomic_fetch_add_explicit(sink, amount, memory_order_relaxed);
}

/// Red-black finite-volume diffusion/reaction update. Diffusion, decay, baseline and bounds are
/// read from transaction-local effective tables. State-local diffusionScale remains an optional
/// multiplicative heterogeneity field.
kernel void nt_update_fast_fields(
    constant NTResources& r [[buffer(0)]],
    device const float* fieldParameters [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    const uint width = max(r.header->fieldGridWidth, 1u);
    const uint height = max(r.header->fieldGridHeight, 1u);
    const uint depth = max(r.header->fieldGridDepth, 1u);
    const uint voxelCount = width * height * depth;
    const uint channels = max(r.header->fieldChannels, 1u);
    const uint valuesPerTile = voxelCount * channels;
    if (valuesPerTile == 0u || gid >= r.header->fieldValueCount) { return; }

    const uint local = gid % valuesPerTile;
    const uint channel = local / voxelCount;
    const uint voxel = local - channel * voxelCount;
    const uint tileOrdinal = gid / valuesPerTile;
    if (tileOrdinal >= r.header->tileCount) { return; }
    device NTTileState& tile = r.tiles[tileOrdinal];
    if (tile.fieldRange.count < valuesPerTile) { return; }

    const uint z = voxel / (width * height);
    const uint rem = voxel - z * width * height;
    const uint y = rem / width;
    const uint x = rem - y * width;
    const uint parity = (x + y + z) & 1u;
    if (parity != (r.header->reserved2.x & 1u)) { return; }

    const uint base = tile.fieldRange.lowerBound;
    const uint fieldIndex = base + channel * voxelCount + voxel;
    if (fieldIndex >= r.header->fieldValueCount) { return; }
    device NTFieldState& field = r.fields[fieldIndex];
    const float center = max(field.concentrationSourceSinkDiffusion.x, 0.0f);
    float sum = 0.0f;
    uint neighbors = 0u;

    if (x > 0u) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x - 1u, y, z, width, height), voxelCount); neighbors++; }
    if (x + 1u < width) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x + 1u, y, z, width, height), voxelCount); neighbors++; }
    if (y > 0u) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x, y - 1u, z, width, height), voxelCount); neighbors++; }
    if (y + 1u < height) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x, y + 1u, z, width, height), voxelCount); neighbors++; }
    if (z > 0u) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x, y, z - 1u, width, height), voxelCount); neighbors++; }
    if (z + 1u < depth) { sum += nt_field_concentration(r, base, channel, nt_voxel_index(x, y, z + 1u, width, height), voxelCount); neighbors++; }

    const float dt = max(r.header->dtMilliseconds, 1.0e-6f);
    const float baseQuantum = max(float(r.header->fastQuantumTicks) * NT_TICK_MILLISECONDS, NT_TICK_MILLISECONDS);
    const float stepScale = dt / baseQuantum;
    const uint parameterCount = r.header->reserved2.z;
    const float modelAlpha = max(nt_field_parameter(fieldParameters, parameterCount, channel, 0u, 0.0f), 0.0f);
    const float stateScale = max(field.concentrationSourceSinkDiffusion.w, 0.0f);
    const float alpha = modelAlpha > 0.0f ? modelAlpha * stateScale * stepScale : stateScale * dt;
    const float decayBase = clamp(nt_field_parameter(fieldParameters, parameterCount, channel, 1u, 1.0f), 0.0f, 1.0f);
    const float decay = pow(decayBase, stepScale);
    const float baseline = max(nt_field_parameter(fieldParameters, parameterCount, channel, 2u, center), 0.0f);
    const float minimum = nt_field_parameter(fieldParameters, parameterCount, channel, 4u, 0.0f);
    const float maximum = nt_field_parameter(fieldParameters, parameterCount, channel, 5u, FLT_MAX);
    const float source = field.concentrationSourceSinkDiffusion.y;
    const float sink = max(field.concentrationSourceSinkDiffusion.z, 0.0f);
    const float laplacian = sum - float(neighbors) * center;
    const float decayed = baseline + (center - baseline) * decay;
    const float updated = decayed + alpha * laplacian + dt * (source - sink * center);
    field.concentrationSourceSinkDiffusion.x = clamp(updated, minimum, max(maximum, minimum));
    field.concentrationSourceSinkDiffusion.y = 0.0f;
    field.concentrationSourceSinkDiffusion.z = 0.0f;
}

/// Cell metabolism and explicit glial programs. Regulatory lanes 0...3 carry reduced glial
/// activation state: calcium/IP3/activity/debris for astrocytes and microglia, and maturation /
/// support state for oligodendrocyte-lineage cells.
kernel void nt_update_glia_metabolism(
    constant NTResources& r [[buffer(0)]],
    device const uint4* cellProgramIdentity [[buffer(1)]],
    device const uint4* cellProgramMetadata [[buffer(2)]],
    device const float* glialParameters [[buffer(3)]],
    device const float* fieldParameters [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    (void)fieldParameters;
    if (gid >= r.header->cellCount) { return; }
    device NTCellState& cell = r.cells[gid];
    if (cell.tileIndex >= r.header->tileCount) { return; }
    device NTTileState& tile = r.tiles[cell.tileIndex];
    const uint width = max(r.header->fieldGridWidth, 1u);
    const uint height = max(r.header->fieldGridHeight, 1u);
    const uint depth = max(r.header->fieldGridDepth, 1u);
    const uint voxelCount = width * height * depth;
    if (tile.fieldRange.count < voxelCount * max(r.header->fieldChannels, 1u)) { return; }

    const uint cellProgramCount = r.header->reserved2.w;
    const uint kind = nt_cell_kind(cell, cellProgramIdentity, cellProgramCount);
    const uint glialProgram = nt_glial_program_index(cell, cellProgramMetadata, cellProgramCount);
    const uint glialProgramCount = r.header->reserved1.z;
    const uint voxel = nt_cell_voxel(cell, width, height, depth);
    device NTFieldState* potassium = nt_cell_field(r, tile, 0u, voxel, voxelCount);
    device NTFieldState* calcium = nt_cell_field(r, tile, 1u, voxel, voxelCount);
    device NTFieldState* glutamate = nt_cell_field(r, tile, 2u, voxel, voxelCount);
    device NTFieldState* oxygen = nt_cell_field(r, tile, 3u, voxel, voxelCount);
    device NTFieldState* glucose = nt_cell_field(r, tile, 4u, voxel, voxelCount);
    device NTFieldState* lactate = nt_cell_field(r, tile, 5u, voxel, voxelCount);
    device NTFieldState* trophic = nt_cell_field(r, tile, 7u, voxel, voxelCount);
    device NTFieldState* inflammatory = nt_cell_field(r, tile, 10u, voxel, voxelCount);
    device NTFieldState* matrix = nt_cell_field(r, tile, 11u, voxel, voxelCount);

    const float oxygenConcentration = oxygen == nullptr ? 0.0f : max(oxygen->concentrationSourceSinkDiffusion.x, 0.0f);
    const float glucoseConcentration = glucose == nullptr ? 0.0f : max(glucose->concentrationSourceSinkDiffusion.x, 0.0f);
    const float potassiumConcentration = potassium == nullptr ? 0.0f : max(potassium->concentrationSourceSinkDiffusion.x, 0.0f);
    const float glutamateConcentration = glutamate == nullptr ? 0.0f : max(glutamate->concentrationSourceSinkDiffusion.x, 0.0f);
    const float inflammatoryConcentration = inflammatory == nullptr ? 0.0f : max(inflammatory->concentrationSourceSinkDiffusion.x, 0.0f);
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;

    float energy = max(cell.ageCycleDifferentiationEnergy.w, 0.0f);
    float oxygenStress = max(cell.stressDamageHazard.x, 0.0f);
    float glucoseStress = max(cell.stressDamageHazard.y, 0.0f);
    float damage = nt_clamp01(cell.stressDamageHazard.z);
    const float electricalDemand = nt_clamp01(tile.scores.x);
    const float structuralDemand = nt_clamp01(tile.scores.y);
    const float demand = (0.001f + 0.004f * electricalDemand + 0.002f * structuralDemand) * (1.0f + damage);

    oxygenStress = max(0.0f, oxygenStress + dtSeconds * (oxygenConcentration < 0.02f ? 0.5f : -0.1f * oxygenStress));
    glucoseStress = max(0.0f, glucoseStress + dtSeconds * (glucoseConcentration < 0.05f ? 0.5f : -0.1f * glucoseStress));
    const float supplied = min(oxygenConcentration * 0.2f, glucoseConcentration * 0.1f);
    energy = max(0.0f, energy + dtSeconds * (supplied - demand));
    damage = nt_clamp01(damage + dtSeconds * max(oxygenStress + glucoseStress - 0.5f, 0.0f) * 0.01f);
    nt_atomic_field_sink(oxygen, demand * 0.6f);
    nt_atomic_field_sink(glucose, demand * 0.4f);

    const NTRange regulatory = cell.regulatoryRange;
    const bool hasRegulatory = regulatory.count >= 4u && regulatory.lowerBound + 4u <= r.header->cellCount * 32u;
    float state0 = hasRegulatory ? r.regulatoryState[regulatory.lowerBound] : 0.0f;
    float state1 = hasRegulatory ? r.regulatoryState[regulatory.lowerBound + 1u] : 0.0f;
    float state2 = hasRegulatory ? r.regulatoryState[regulatory.lowerBound + 2u] : 0.0f;
    float state3 = hasRegulatory ? r.regulatoryState[regulatory.lowerBound + 3u] : 0.0f;

    const float uptake0 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 0u, 0.01f), 0.0f);
    const float uptake1 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 1u, 0.01f), 0.0f);
    const float uptake2 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 2u, 0.01f), 0.0f);
    const float uptake3 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 3u, 0.01f), 0.0f);
    const float release0 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 4u, 0.01f), 0.0f);
    const float release1 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 5u, 0.01f), 0.0f);
    const float release2 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 6u, 0.01f), 0.0f);
    const float release3 = max(nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 7u, 0.01f), 0.0f);
    const float threshold0 = nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 8u, 3.5f);
    const float threshold1 = nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 9u, 0.01f);
    const float threshold2 = nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 10u, 0.1f);
    const float threshold3 = nt_glial_parameter(glialParameters, glialProgramCount, glialProgram, 11u, 0.1f);

    if (kind == NT_CELL_KIND_ASTROCYTE) {
        const float ionicDrive = max(potassiumConcentration - threshold0, 0.0f);
        const float transmitterDrive = max(glutamateConcentration - threshold1, 0.0f);
        state1 = nt_clamp01(state1 + dtSeconds * (transmitterDrive + 0.25f * ionicDrive - 0.2f * state1));
        state0 = nt_clamp01(state0 + dtSeconds * (state1 + 0.1f * electricalDemand - 0.3f * state0));
        state2 = nt_clamp01(state2 + dtSeconds * (state0 - 0.1f * state2));
        nt_atomic_field_sink(potassium, uptake0 * state2 * ionicDrive);
        nt_atomic_field_sink(glutamate, uptake1 * state2 * glutamateConcentration);
        nt_atomic_field_source(lactate, release0 * state2 * max(glucoseConcentration, 0.0f));
        nt_atomic_field_source(trophic, release1 * state2 * (1.0f - damage));
        if (calcium != nullptr) { nt_atomic_field_source(calcium, 0.001f * state0); }
    } else if (kind == NT_CELL_KIND_OLIGODENDROCYTE_PRECURSOR || kind == NT_CELL_KIND_OLIGODENDROCYTE) {
        const float targetMaturity = kind == NT_CELL_KIND_OLIGODENDROCYTE ? 1.0f : nt_clamp01(trophic == nullptr ? 0.0f : trophic->concentrationSourceSinkDiffusion.x);
        state0 = nt_clamp01(state0 + dtSeconds * 0.02f * (targetMaturity - state0));
        state1 = nt_clamp01(state1 + dtSeconds * (electricalDemand - 0.1f * state1));
        state2 = nt_clamp01(state0 * state1 * energy);
        nt_atomic_field_sink(lactate, uptake0 * state2 * 0.1f);
        nt_atomic_field_source(trophic, release0 * state2);
    } else if (kind == NT_CELL_KIND_MICROGLIA) {
        const float damageDrive = max(max(tile.scores.z, damage) - threshold2, 0.0f);
        const float inflammationDrive = max(inflammatoryConcentration - threshold3, 0.0f);
        state0 = nt_clamp01(state0 + dtSeconds * (damageDrive + inflammationDrive - 0.05f * state0));
        state1 = nt_clamp01(state1 + dtSeconds * (state0 - 0.1f * state1));
        state2 = nt_clamp01(state2 + dtSeconds * (max(state0 - 0.4f, 0.0f) - 0.05f * state2));
        state3 = nt_clamp01(state3 + dtSeconds * (damageDrive - uptake3 * state3));
        const float inflammatoryRelease = release2 * state2 * (1.0f - 0.5f * state1);
        nt_atomic_field_source(inflammatory, inflammatoryRelease);
        nt_atomic_field_sink(inflammatory, uptake2 * state1 * inflammatoryConcentration);
        nt_atomic_field_source(trophic, release1 * state1 * (1.0f - state2));
        damage = nt_clamp01(damage - dtSeconds * uptake3 * state1 * damage);
    } else if (kind == NT_CELL_KIND_ENDOTHELIAL || kind == NT_CELL_KIND_PERIVASCULAR) {
        const float perfusionResponse = nt_clamp01(1.0f - oxygenStress - glucoseStress);
        state0 = nt_clamp01(state0 + dtSeconds * (electricalDemand - 0.05f * state0));
        nt_atomic_field_source(oxygen, release0 * perfusionResponse * (1.0f + state0));
        nt_atomic_field_source(glucose, release1 * perfusionResponse * (1.0f + state0));
        nt_atomic_field_sink(inflammatory, uptake2 * inflammatoryConcentration);
        nt_atomic_field_source(matrix, release3 * (1.0f - damage));
    }

    if (hasRegulatory) {
        r.regulatoryState[regulatory.lowerBound] = state0;
        r.regulatoryState[regulatory.lowerBound + 1u] = state1;
        r.regulatoryState[regulatory.lowerBound + 2u] = state2;
        r.regulatoryState[regulatory.lowerBound + 3u] = state3;
    }
    cell.ageCycleDifferentiationEnergy.w = energy;
    cell.stressDamageHazard.x = oxygenStress;
    cell.stressDamageHazard.y = glucoseStress;
    cell.stressDamageHazard.z = damage;
}

/// Activity-dependent myelination. One thread owns one axonal segment and scans only the owning
/// tile's oligodendrocyte lineage, avoiding atomic updates to segment or compartment state.
kernel void nt_update_myelination(
    constant NTResources& r [[buffer(0)]],
    device const uint4* cellProgramIdentity [[buffer(1)]],
    device const uint4* cellProgramMetadata [[buffer(2)]],
    device const float* glialParameters [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->segmentCount) { return; }
    device NTSegmentState& segment = r.segments[gid];
    const uint kind = segment.typeAndFlags & 0xFFFFu;
    if (kind != NT_SEGMENT_KIND_AXON && kind != NT_SEGMENT_KIND_AXON_INITIAL && kind != NT_SEGMENT_KIND_MYELINATED_AXON) { return; }
    if (segment.cellIndex >= r.header->cellCount) { return; }
    const NTCellState owner = r.cells[segment.cellIndex];
    if (owner.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[owner.tileIndex];
    const float3 midpoint = 0.5f * (segment.start.xyz + segment.end.xyz);
    const uint cellProgramCount = r.header->reserved2.w;
    const uint glialProgramCount = r.header->reserved1.z;
    float support = 0.0f;

    const uint end = min(tile.cellRange.lowerBound + tile.cellRange.count, r.header->cellCount);
    for (uint cellIndex = tile.cellRange.lowerBound; cellIndex < end; ++cellIndex) {
        const NTCellState glia = r.cells[cellIndex];
        const uint glialKind = nt_cell_kind(glia, cellProgramIdentity, cellProgramCount);
        if (glialKind != NT_CELL_KIND_OLIGODENDROCYTE && glialKind != NT_CELL_KIND_OLIGODENDROCYTE_PRECURSOR) { continue; }
        const uint program = nt_glial_program_index(glia, cellProgramMetadata, cellProgramCount);
        const float radius = max(nt_glial_parameter(glialParameters, glialProgramCount, program, 12u, 30.0f), 1.0f);
        const float distance = length(glia.position.xyz - midpoint);
        if (distance > radius) { continue; }
        const float maturity = glia.regulatoryRange.count > 0u
            ? nt_clamp01(r.regulatoryState[glia.regulatoryRange.lowerBound])
            : (glialKind == NT_CELL_KIND_OLIGODENDROCYTE ? 1.0f : 0.25f);
        const float activitySupport = glia.regulatoryRange.count > 2u
            ? nt_clamp01(r.regulatoryState[glia.regulatoryRange.lowerBound + 2u])
            : nt_clamp01(tile.scores.x);
        support = max(support, (1.0f - distance / radius) * maturity * (0.25f + 0.75f * activitySupport));
    }

    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    const float damage = nt_clamp01(owner.stressDamageHazard.z);
    const float previous = nt_clamp01(segment.radiusMyelinGrowthScore.y);
    const float formation = 0.005f * support * (1.0f - damage);
    const float loss = 0.002f * damage + 0.0001f * (support <= 0.0f ? 1.0f : 0.0f);
    const float updated = nt_clamp01(previous + dtSeconds * (formation * (1.0f - previous) - loss * previous));
    segment.radiusMyelinGrowthScore.y = updated;
    if (updated > 0.5f) { segment.typeAndFlags = (segment.typeAndFlags & 0xFFFF0000u) | NT_SEGMENT_KIND_MYELINATED_AXON; }

    if (segment.compartmentIndex < r.header->compartmentCount && fabs(updated - previous) > 1.0e-8f) {
        device NTCompartmentState& compartment = r.compartments[segment.compartmentIndex];
        const float oldCapacitanceScale = max(1.0f - 0.75f * previous, 0.1f);
        const float newCapacitanceScale = max(1.0f - 0.75f * updated, 0.1f);
        const float oldAxialScale = 1.0f + 4.0f * previous;
        const float newAxialScale = 1.0f + 4.0f * updated;
        compartment.voltagePreviousCapacitanceAxial.z = max(
            compartment.voltagePreviousCapacitanceAxial.z * newCapacitanceScale / oldCapacitanceScale,
            1.0e-8f
        );
        compartment.voltagePreviousCapacitanceAxial.w = max(
            compartment.voltagePreviousCapacitanceAxial.w * newAxialScale / oldAxialScale,
            0.0f
        );
    }
}

/// Microglia evaluate each synapse independently using nearby microglial activation, target-cell
/// injury and synaptic evidence. Marking is idempotent and leaves physical compaction to the
/// transactional topology rebuilder.
kernel void nt_update_microglial_pruning(
    constant NTResources& r [[buffer(0)]],
    device const uint4* cellProgramIdentity [[buffer(1)]],
    device const uint4* cellProgramMetadata [[buffer(2)]],
    device const float* glialParameters [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->synapseCount) { return; }
    device NTSynapseState& synapse = r.synapses[gid];
    if ((synapse.parameterAndFlags & NT_SYNAPSE_PRUNED_FLAG_FIELDS) != 0u) { return; }
    if (synapse.targetCompartmentIndex >= r.header->compartmentCount) { return; }
    const NTCompartmentState targetCompartment = r.compartments[synapse.targetCompartmentIndex];
    if (targetCompartment.neuronIndex >= r.header->cellCount) { return; }
    const NTCellState target = r.cells[targetCompartment.neuronIndex];
    if (target.tileIndex >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[target.tileIndex];
    const uint cellProgramCount = r.header->reserved2.w;
    const uint glialProgramCount = r.header->reserved1.z;
    float pruningDrive = 0.0f;

    const uint end = min(tile.cellRange.lowerBound + tile.cellRange.count, r.header->cellCount);
    for (uint cellIndex = tile.cellRange.lowerBound; cellIndex < end; ++cellIndex) {
        const NTCellState microglia = r.cells[cellIndex];
        if (nt_cell_kind(microglia, cellProgramIdentity, cellProgramCount) != NT_CELL_KIND_MICROGLIA) { continue; }
        const uint program = nt_glial_program_index(microglia, cellProgramMetadata, cellProgramCount);
        const float radius = max(nt_glial_parameter(glialParameters, glialProgramCount, program, 12u, 25.0f), 1.0f);
        const float distance = length(microglia.position.xyz - target.position.xyz);
        if (distance > radius) { continue; }
        const float activation = microglia.regulatoryRange.count > 0u
            ? nt_clamp01(r.regulatoryState[microglia.regulatoryRange.lowerBound])
            : nt_clamp01(tile.scores.z);
        pruningDrive = max(pruningDrive, activation * (1.0f - distance / radius));
    }

    const float evidence = nt_clamp01(
        0.45f * (1.0f - nt_clamp01(synapse.structuralReserved.x)) +
        0.20f * (synapse.weightConductanceUtilizationResources.x <= 1.0e-6f ? 1.0f : 0.0f) +
        0.20f * (1.0f - nt_clamp01(synapse.prePostEligibilityConsolidation.w)) +
        0.15f * nt_clamp01(target.stressDamageHazard.z)
    );
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    const float removal = pruningDrive * evidence * 0.02f * dtSeconds;
    synapse.structuralReserved.x = nt_clamp01(synapse.structuralReserved.x - removal);
    if (pruningDrive > 0.5f && evidence > 0.7f && synapse.structuralReserved.x < 0.01f) {
        synapse.parameterAndFlags |= NT_SYNAPSE_PRUNED_FLAG_FIELDS;
        synapse.weightConductanceUtilizationResources.x = 0.0f;
        synapse.weightConductanceUtilizationResources.y = 0.0f;
        atomic_fetch_add_explicit(&r.counters->structuralMutations, 1u, memory_order_relaxed);
    }
}

#endif
