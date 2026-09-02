import Foundation

public extension NTMetalKernelSource {
    static let fieldsAndMetabolism = #"""
struct NTFieldSpecies {
    float4 diffusionDecay;
    float4 boundsBoundary;
    uint4 identityAndFlags;
};

inline uint nt_field_linear(uint x, uint y, uint z, uint species, uint resolution, uint speciesCount) {
    return ((((z * resolution) + y) * resolution) + x) * speciesCount + species;
}

inline int nt_axis_neighbor_slot(int dx, int dy, int dz) {
    if (dx == -1 && dy == 0 && dz == 0) return 12;
    if (dx == 1 && dy == 0 && dz == 0) return 13;
    if (dx == 0 && dy == -1 && dz == 0) return 10;
    if (dx == 0 && dy == 1 && dz == 0) return 15;
    if (dx == 0 && dy == 0 && dz == -1) return 4;
    if (dx == 0 && dy == 0 && dz == 1) return 21;
    return -1;
}

inline float nt_boundary_value(float center, NTFieldSpecies parameter) {
    uint kind = parameter.identityAndFlags.y;
    if (kind == 1u || kind == 2u) return parameter.diffusionDecay.z;
    return center;
}

inline float nt_field_neighbor(
    device const float* fieldRead,
    device const NTTileHeader* tiles,
    device const int* tileNeighbors,
    uint tileIndex,
    uint fieldBrickIndex,
    int x,
    int y,
    int z,
    uint species,
    uint resolution,
    uint speciesCount,
    uint brickStride,
    NTFieldSpecies parameter) {
    if (x >= 0 && x < int(resolution) && y >= 0 && y < int(resolution) && z >= 0 && z < int(resolution)) {
        return fieldRead[fieldBrickIndex * brickStride + nt_field_linear(uint(x), uint(y), uint(z), species, resolution, speciesCount)];
    }
    int dx = x < 0 ? -1 : x >= int(resolution) ? 1 : 0;
    int dy = y < 0 ? -1 : y >= int(resolution) ? 1 : 0;
    int dz = z < 0 ? -1 : z >= int(resolution) ? 1 : 0;
    int slot = nt_axis_neighbor_slot(dx, dy, dz);
    float center = fieldRead[fieldBrickIndex * brickStride + nt_field_linear(
        uint(clamp(x, 0, int(resolution) - 1)),
        uint(clamp(y, 0, int(resolution) - 1)),
        uint(clamp(z, 0, int(resolution) - 1)),
        species,
        resolution,
        speciesCount
    )];
    if (slot < 0) return nt_boundary_value(center, parameter);
    int neighborTile = tileNeighbors[tileIndex * 26u + uint(slot)];
    if (neighborTile < 0) return nt_boundary_value(center, parameter);
    uint neighborField = tiles[uint(neighborTile)].fieldAndFlags.x;
    if (neighborField == NT_INVALID_INDEX) return nt_boundary_value(center, parameter);
    uint wrappedX = x < 0 ? resolution - 1u : x >= int(resolution) ? 0u : uint(x);
    uint wrappedY = y < 0 ? resolution - 1u : y >= int(resolution) ? 0u : uint(y);
    uint wrappedZ = z < 0 ? resolution - 1u : z >= int(resolution) ? 0u : uint(z);
    return fieldRead[neighborField * brickStride + nt_field_linear(wrappedX, wrappedY, wrappedZ, species, resolution, speciesCount)];
}

kernel void nt_apply_field_sources(
    device float* fieldRead [[buffer(0)]],
    device float* fieldSources [[buffer(1)]],
    constant NTFieldSpecies* parameters [[buffer(2)]],
    constant uint4& shape [[buffer(3)]],
    constant float4& step [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= shape.x) return;
    uint species = gid % shape.z;
    NTFieldSpecies parameter = parameters[species];
    float value = fieldRead[gid] + step.y * fieldSources[gid];
    fieldRead[gid] = clamp(value, parameter.boundsBoundary.x, parameter.boundsBoundary.y);
    fieldSources[gid] = 0.0f;
}

kernel void nt_diffuse_fields(
    device const float* fieldRead [[buffer(0)]],
    device float* fieldWrite [[buffer(1)]],
    device const NTTileHeader* tiles [[buffer(2)]],
    device const int* tileNeighbors [[buffer(3)]],
    device const uint* fieldTileIndices [[buffer(4)]],
    constant NTFieldSpecies* parameters [[buffer(5)]],
    constant uint4& shape [[buffer(6)]],
    constant float4& step [[buffer(7)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= shape.x) return;
    uint resolution = shape.y;
    uint speciesCount = shape.z;
    uint brickStride = resolution * resolution * resolution * speciesCount;
    uint fieldBrick = gid / brickStride;
    uint local = gid - fieldBrick * brickStride;
    uint species = local % speciesCount;
    uint voxel = local / speciesCount;
    uint x = voxel % resolution;
    uint y = (voxel / resolution) % resolution;
    uint z = voxel / (resolution * resolution);
    uint tileIndex = fieldTileIndices[fieldBrick];
    NTFieldSpecies parameter = parameters[species];
    float center = fieldRead[gid];
    float sum =
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x) - 1, int(y), int(z), species, resolution, speciesCount, brickStride, parameter) +
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x) + 1, int(y), int(z), species, resolution, speciesCount, brickStride, parameter) +
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x), int(y) - 1, int(z), species, resolution, speciesCount, brickStride, parameter) +
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x), int(y) + 1, int(z), species, resolution, speciesCount, brickStride, parameter) +
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x), int(y), int(z) - 1, species, resolution, speciesCount, brickStride, parameter) +
        nt_field_neighbor(fieldRead, tiles, tileNeighbors, tileIndex, fieldBrick, int(x), int(y), int(z) + 1, species, resolution, speciesCount, brickStride, parameter);
    float inverseDx2 = 1.0f / max(step.x * step.x, 1.0e-12f);
    float value = center + step.y * (
        parameter.diffusionDecay.x * (sum - 6.0f * center) * inverseDx2 -
        parameter.diffusionDecay.y * center
    );
    bool boundaryVoxel = x == 0u || y == 0u || z == 0u || x + 1u == resolution || y + 1u == resolution || z + 1u == resolution;
    uint boundaryKind = parameter.identityAndFlags.y;
    if (boundaryVoxel && boundaryKind == 1u) {
        value = parameter.diffusionDecay.z;
    } else if (boundaryVoxel && boundaryKind == 2u) {
        value += step.y * parameter.diffusionDecay.w * (parameter.diffusionDecay.z - value);
    }
    fieldWrite[gid] = clamp(value, parameter.boundsBoundary.x, parameter.boundsBoundary.y);
}

kernel void nt_reduce_field_mass(
    device const float* fieldValues [[buffer(0)]],
    device atomic_uint* massBits [[buffer(1)]],
    constant uint4& shape [[buffer(2)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= shape.x) return;
    uint species = gid % shape.z;
    nt_atomic_add_float(massBits + species, fieldValues[gid]);
}

inline uint nt_cell_field_index(
    NTCell cell,
    device const NTTileHeader* tiles,
    uint resolution,
    uint speciesCount,
    uint species,
    float tileEdge,
    float3 origin) {
    uint tileIndex = cell.tileAndClass.x;
    NTTileHeader tile = tiles[tileIndex];
    uint fieldBrick = tile.fieldAndFlags.x;
    if (fieldBrick == NT_INVALID_INDEX) return NT_INVALID_INDEX;
    float3 tileOrigin = origin + float3(tile.coordinateAndFidelity.xyz) * tileEdge;
    float3 local = clamp((cell.positionAndAge.xyz - tileOrigin) / tileEdge, 0.0f, 0.999999f);
    uint3 voxel = uint3(floor(local * float(resolution)));
    uint brickStride = resolution * resolution * resolution * speciesCount;
    return fieldBrick * brickStride + nt_field_linear(voxel.x, voxel.y, voxel.z, species, resolution, speciesCount);
}

kernel void nt_update_metabolism(
    constant NTWorldConstants& world [[buffer(0)]],
    device NTCell* cells [[buffer(1)]],
    device const NTTileHeader* tiles [[buffer(2)]],
    device const float* fields [[buffer(3)]],
    device atomic_uint* fieldSourceBits [[buffer(4)]],
    device const NTCompartment* compartments [[buffer(5)]],
    device const uint* tileCompartments [[buffer(6)]],
    constant float4* metabolic [[buffer(7)]],
    constant float4& step [[buffer(8)]],
    device atomic_uint* observationBits [[buffer(9)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= world.counts0.y) return;
    NTCell cell = cells[gid];
    uint resolution = world.abiAndFlags.z;
    uint speciesCount = world.counts1.w;
    float3 origin = float3(world.geometry.z, world.geometry.w, as_type<float>(world.seed.z));
    uint oxygenIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 3u, world.geometry.x, origin);
    uint glucoseIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 4u, world.geometry.x, origin);
    uint lactateIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 5u, world.geometry.x, origin);
    float oxygen = oxygenIndex == NT_INVALID_INDEX ? 0.04f : fields[oxygenIndex];
    float glucose = glucoseIndex == NT_INVALID_INDEX ? 5.0f : fields[glucoseIndex];
    float dt = step.y;
    float4 p0 = metabolic[0];
    float4 p1 = metabolic[1];
    float4 p2 = metabolic[2];
    float basalATP = p0.x;
    float oxygenPerATP = p0.z;
    float glucosePerATP = p0.w;
    float energyRecovery = p1.y;
    float oxygenThreshold = p1.z;
    float glucoseThreshold = p1.w;
    float damageRate = p2.x;
    float recoveryRate = p2.y;
    float activityCost = 0.0f;
    NTTileHeader tile = tiles[cell.tileAndClass.x];
    for (uint local = 0u; local < tile.compartmentRange.y; ++local) {
        uint compartmentIndex = tileCompartments[tile.compartmentRange.x + local];
        if (all(compartments[compartmentIndex].cell == cell.id)) {
            activityCost += compartments[compartmentIndex].conductance0.z * 1.0e-9f;
        }
    }
    float atpDemand = basalATP + activityCost / max(dt, 1.0e-9f);
    float oxygenDemand = atpDemand * oxygenPerATP;
    float glucoseDemand = atpDemand * glucosePerATP;
    if (oxygenIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + oxygenIndex, -oxygenDemand);
    if (glucoseIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + glucoseIndex, -glucoseDemand);
    if (lactateIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + lactateIndex, glucoseDemand * p1.x);
    float oxygenStress = clamp((oxygenThreshold - oxygen) / max(oxygenThreshold, 1.0e-9f), 0.0f, 1.0f);
    float glucoseStress = clamp((glucoseThreshold - glucose) / max(glucoseThreshold, 1.0e-9f), 0.0f, 1.0f);
    float support = clamp(oxygen / max(oxygenThreshold, 1.0e-9f), 0.0f, 1.0f) *
        clamp(glucose / max(glucoseThreshold, 1.0e-9f), 0.0f, 1.0f);
    cell.orientationAndEnergy.w = clamp(cell.orientationAndEnergy.w + dt * (energyRecovery * support - atpDemand), 0.0f, 1.0f);
    cell.stressDamageFlags.x = oxygenStress;
    cell.stressDamageFlags.y = glucoseStress;
    float stress = max(oxygenStress, glucoseStress);
    if (stress > 0.5f) cell.stressDamageFlags.z = min(1.0f, cell.stressDamageFlags.z + damageRate * stress * dt);
    else cell.stressDamageFlags.z = max(0.0f, cell.stressDamageFlags.z - recoveryRate * dt);
    cells[gid] = cell;
    nt_atomic_add_float(observationBits + 0, atpDemand * dt * 5.0e-20f);
}

kernel void nt_update_glia(
    constant NTWorldConstants& world [[buffer(0)]],
    device NTCell* cells [[buffer(1)]],
    device float* regulatory [[buffer(2)]],
    device const NTTileHeader* tiles [[buffer(3)]],
    device const float* fields [[buffer(4)]],
    device atomic_uint* fieldSourceBits [[buffer(5)]],
    constant float4* glial [[buffer(6)]],
    constant float4& step [[buffer(7)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= world.counts0.y) return;
    NTCell cell = cells[gid];
    uint kind = cell.tileAndClass.y;
    if (kind != 4u && kind != 5u && kind != 6u && kind != 7u) return;
    uint resolution = world.abiAndFlags.z;
    uint speciesCount = world.counts1.w;
    float3 origin = float3(world.geometry.z, world.geometry.w, as_type<float>(world.seed.z));
    uint potassiumIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 0u, world.geometry.x, origin);
    uint glutamateIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 2u, world.geometry.x, origin);
    uint lactateIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 5u, world.geometry.x, origin);
    uint trophicIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 7u, world.geometry.x, origin);
    uint inflammationIndex = nt_cell_field_index(cell, tiles, resolution, speciesCount, 10u, world.geometry.x, origin);
    float potassium = potassiumIndex == NT_INVALID_INDEX ? 3.5f : fields[potassiumIndex];
    float glutamate = glutamateIndex == NT_INVALID_INDEX ? 0.0f : fields[glutamateIndex];
    float inflammation = inflammationIndex == NT_INVALID_INDEX ? 0.0f : fields[inflammationIndex];
    float dt = step.y;
    device float* r = regulatory + gid * 32u;
    if (kind == 4u) {
        float activation = max(0.0f, potassium - 3.5f) + 0.2f * glutamate + inflammation;
        r[0] = max(0.0f, r[0] + dt * (activation - glial[0].w * r[0]));
        r[1] = max(0.0f, r[1] + dt * (0.5f * r[0] - 0.1f * r[1]));
        r[2] = clamp(r[2] + dt * (cell.orientationAndEnergy.w - 0.1f * activation), 0.0f, 1.0f);
        r[3] = clamp(glial[0].x * nt_sigmoid(r[0] - glial[1].x), 0.0f, 1.0f);
        r[4] = clamp(glial[0].y * nt_sigmoid(r[0] - glial[1].x), 0.0f, 1.0f);
        if (potassiumIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + potassiumIndex, -r[3] * max(0.0f, potassium - 3.5f));
        if (glutamateIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + glutamateIndex, -r[4] * glutamate);
        if (lactateIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + lactateIndex, glial[0].z * r[2]);
        if (trophicIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + trophicIndex, 0.001f * clamp(activation, 0.0f, 1.0f));
    } else if (kind == 5u || kind == 6u) {
        float maturity = kind == 6u ? 1.0f : cell.radiiAndDifferentiation.w;
        r[0] = clamp(r[0] + glial[1].y * maturity * cell.orientationAndEnergy.w * dt, 0.0f, 1.0f);
        r[1] = clamp(r[1] + glial[1].z * (1.0f - cell.stressDamageFlags.z) * dt, 0.0f, 1.0f);
    } else if (kind == 7u) {
        float activation = max(inflammation, cell.stressDamageFlags.z);
        r[0] = clamp(r[0] + dt * (activation - 0.01f * r[0]), 0.0f, 1.0f);
        r[2] = clamp(nt_sigmoid((r[0] - glial[1].w) * 10.0f), 0.0f, 1.0f);
        if (inflammationIndex != NT_INVALID_INDEX) nt_atomic_add_float(fieldSourceBits + inflammationIndex, glial[2].w * r[0]);
    }
}
"""#

    static var completeWithFields: String { completeCore + "\n" + fieldsAndMetabolism }
}
