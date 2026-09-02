#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_FIELDS
#define NUMITISSUE_FIELDS

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

/// Red-black finite-volume diffusion/reaction update. The host dispatches parity 0 then 1,
/// placing the parity in header.reserved2.x. This avoids a second full field buffer.
kernel void nt_update_fast_fields(
    constant NTResources& r [[buffer(0)]],
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
    const float diffusion = max(field.concentrationSourceSinkDiffusion.w, 0.0f);
    const float source = field.concentrationSourceSinkDiffusion.y;
    const float sink = max(field.concentrationSourceSinkDiffusion.z, 0.0f);
    const float laplacian = sum - float(neighbors) * center;
    const float updated = center + dt * (diffusion * laplacian + source - sink * center);
    field.concentrationSourceSinkDiffusion.x = max(updated, 0.0f);
    field.concentrationSourceSinkDiffusion.y = 0.0f;
}

/// Reduced astrocyte/metabolic exchange. Cell type bits designate glial programs through the
/// compiled type table; the default mapping uses type 5 for astrocytes and 6 for oligodendrocytes.
kernel void nt_update_glia_metabolism(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->cellCount) { return; }
    device NTCellState& cell = r.cells[gid];
    const uint type = cell.typeAndDevelopment & 0xFFFFu;
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    float energy = max(cell.ageCycleDifferentiationEnergy.w, 0.0f);
    float oxygenStress = max(cell.stressDamageHazard.x, 0.0f);
    float glucoseStress = max(cell.stressDamageHazard.y, 0.0f);
    float damage = max(cell.stressDamageHazard.z, 0.0f);

    const uint tileIndex = cell.tileIndex;
    if (tileIndex >= r.header->tileCount) { return; }
    device NTTileState& tile = r.tiles[tileIndex];
    const uint width = max(r.header->fieldGridWidth, 1u);
    const uint height = max(r.header->fieldGridHeight, 1u);
    const uint depth = max(r.header->fieldGridDepth, 1u);
    const uint voxelCount = width * height * depth;
    if (tile.fieldRange.count < voxelCount * max(r.header->fieldChannels, 1u)) { return; }

    const float3 local = clamp(cell.position.xyz, float3(0.0f), float3(199.999f)) / 200.0f;
    const uint x = min(uint(local.x * float(width)), width - 1u);
    const uint y = min(uint(local.y * float(height)), height - 1u);
    const uint z = min(uint(local.z * float(depth)), depth - 1u);
    const uint voxel = nt_voxel_index(x, y, z, width, height);
    const uint oxygenIndex = tile.fieldRange.lowerBound + 3u * voxelCount + voxel;
    const uint glucoseIndex = tile.fieldRange.lowerBound + 4u * voxelCount + voxel;
    const uint lactateIndex = tile.fieldRange.lowerBound + 5u * voxelCount + voxel;
    const uint potassiumIndex = tile.fieldRange.lowerBound + 0u * voxelCount + voxel;
    if (lactateIndex >= r.header->fieldValueCount) { return; }

    device NTFieldState& oxygenField = r.fields[oxygenIndex];
    device NTFieldState& glucoseField = r.fields[glucoseIndex];
    device NTFieldState& lactateField = r.fields[lactateIndex];
    const float oxygen = max(oxygenField.concentrationSourceSinkDiffusion.x, 0.0f);
    const float glucose = max(glucoseField.concentrationSourceSinkDiffusion.x, 0.0f);
    const float demand = 0.001f + 0.004f * nt_clamp01(tile.scores.x);

    oxygenStress += dtSeconds * (oxygen < 0.02f ? 0.5f : -0.1f * oxygenStress);
    glucoseStress += dtSeconds * (glucose < 0.05f ? 0.5f : -0.1f * glucoseStress);
    const float supplied = min(oxygen * 0.2f, glucose * 0.1f);
    energy = max(0.0f, energy + dtSeconds * (supplied - demand));
    damage = nt_clamp01(damage + dtSeconds * max(oxygenStress + glucoseStress - 0.5f, 0.0f) * 0.01f);

    device atomic_float* oxygenSink = reinterpret_cast<device atomic_float*>(&oxygenField.concentrationSourceSinkDiffusion.z);
    device atomic_float* glucoseSink = reinterpret_cast<device atomic_float*>(&glucoseField.concentrationSourceSinkDiffusion.z);
    atomic_fetch_add_explicit(oxygenSink, demand * 0.6f, memory_order_relaxed);
    atomic_fetch_add_explicit(glucoseSink, demand * 0.4f, memory_order_relaxed);

    if (type == 5u) {
        device atomic_float* lactateSource = reinterpret_cast<device atomic_float*>(&lactateField.concentrationSourceSinkDiffusion.y);
        atomic_fetch_add_explicit(lactateSource, demand * 0.15f, memory_order_relaxed);
        if (potassiumIndex < r.header->fieldValueCount) {
            device NTFieldState& potassium = r.fields[potassiumIndex];
            potassium.concentrationSourceSinkDiffusion.z += 0.01f * max(potassium.concentrationSourceSinkDiffusion.x - 3.5f, 0.0f);
        }
    }

    cell.ageCycleDifferentiationEnergy.w = energy;
    cell.stressDamageHazard.x = max(oxygenStress, 0.0f);
    cell.stressDamageHazard.y = max(glucoseStress, 0.0f);
    cell.stressDamageHazard.z = damage;
}

#endif
