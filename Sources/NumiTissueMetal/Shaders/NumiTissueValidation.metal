#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_VALIDATION
#define NUMITISSUE_VALIDATION

inline void nt_validate_compartment(constant NTResources& r, uint gid) {
    const NTCompartmentState compartment = r.compartments[gid];
    const float4 primary = compartment.voltagePreviousCapacitanceAxial;
    const float4 secondary = compartment.injectedSynapticCalciumSodium;
    if (!all(isfinite(primary)) || !all(isfinite(secondary)) || !isfinite(compartment.potassiumReserved.x)) {
        nt_append_validation(r, 1u, 1u, uint2(compartment.idLo, compartment.idHi), primary.x, gid);
        return;
    }
    if (primary.x < -200.0f || primary.x > 100.0f) {
        nt_append_validation(r, 1001u, 1u, uint2(compartment.idLo, compartment.idHi), primary.x, gid);
    }
    if (!(primary.z > 0.0f)) {
        nt_append_validation(r, 1000u, 1u, uint2(compartment.idLo, compartment.idHi), primary.z, gid);
    }
    if (compartment.parentIndex != NT_INVALID_INDEX && compartment.parentIndex >= r.header->compartmentCount) {
        nt_append_validation(r, 3u, 1u, uint2(compartment.idLo, compartment.idHi), float(compartment.parentIndex), gid);
    }
}

inline void nt_validate_cell(constant NTResources& r, uint gid) {
    const NTCellState cell = r.cells[gid];
    if (!nt_finite3(cell.position) || !nt_finite3(cell.semiAxes) || !all(isfinite(cell.ageCycleDifferentiationEnergy)) || !all(isfinite(cell.stressDamageHazard))) {
        nt_append_validation(r, 1u, 1u, uint2(cell.idLo, cell.idHi), 0.0f, gid);
        return;
    }
    const float minimumAxis = min(cell.semiAxes.x, min(cell.semiAxes.y, cell.semiAxes.z));
    const float maximumAxis = max(cell.semiAxes.x, max(cell.semiAxes.y, cell.semiAxes.z));
    if (minimumAxis < 0.05f || maximumAxis > 500.0f) {
        nt_append_validation(r, 1002u, 1u, uint2(cell.idLo, cell.idHi), minimumAxis, gid);
    }
    if (cell.tileIndex >= r.header->tileCount) {
        nt_append_validation(r, 3u, 1u, uint2(cell.idLo, cell.idHi), float(cell.tileIndex), gid);
    }
    if (cell.stressDamageHazard.z < 0.0f || cell.stressDamageHazard.z > 1.0f) {
        nt_append_validation(r, 1003u, 1u, uint2(cell.idLo, cell.idHi), cell.stressDamageHazard.z, gid);
    }
}

inline void nt_validate_synapse(constant NTResources& r, uint gid) {
    const NTSynapseState synapse = r.synapses[gid];
    if (!all(isfinite(synapse.weightConductanceUtilizationResources)) || !all(isfinite(synapse.prePostEligibilityConsolidation))) {
        nt_append_validation(r, 1u, 1u, uint2(synapse.idLo, synapse.idHi), 0.0f, gid);
        return;
    }
    const float weight = synapse.weightConductanceUtilizationResources.x;
    if (weight < 0.0f || weight > 1000.0f) {
        nt_append_validation(r, 1004u, 1u, uint2(synapse.idLo, synapse.idHi), weight, gid);
    }
    if (synapse.targetCompartmentIndex >= r.header->compartmentCount) {
        nt_append_validation(r, 3u, 1u, uint2(synapse.idLo, synapse.idHi), float(synapse.targetCompartmentIndex), gid);
    }
}

inline void nt_validate_field(constant NTResources& r, uint gid) {
    const float4 field = r.fields[gid].concentrationSourceSinkDiffusion;
    if (!all(isfinite(field))) {
        nt_append_validation(r, 1u, 1u, uint2(gid, 0u), field.x, gid);
    } else if (field.x < 0.0f) {
        nt_append_validation(r, 2u, 1u, uint2(gid, 0u), field.x, gid);
    }
}

inline void nt_validate_microdomain(constant NTResources& r, uint gid) {
    const NTMicrodomainState domain = r.microdomains[gid];
    if (domain.ownerCellIndex >= r.header->cellCount) {
        nt_append_validation(r, 3u, 1u, uint2(domain.idLo, domain.idHi), float(domain.ownerCellIndex), gid);
    }
    const float volume = domain.volumeTemperaturePropensityReserved.x;
    const float temperature = domain.volumeTemperaturePropensityReserved.y;
    if (!(volume > 0.0f) || !isfinite(volume) || temperature < 270.0f || temperature > 330.0f) {
        nt_append_validation(r, 1000u, 1u, uint2(domain.idLo, domain.idHi), volume, gid);
    }
    if (domain.speciesRange.lowerBound + domain.speciesRange.count > r.header->molecularSpeciesCount) {
        nt_append_validation(r, 3u, 1u, uint2(domain.idLo, domain.idHi), float(domain.speciesRange.count), gid);
    }
}

kernel void nt_validate_state(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (r.header->abiVersion != NT_ABI_VERSION) {
        if (gid == 0u) { nt_append_validation(r, 0xFFFFFFFDu, 1u, uint2(0u), float(r.header->abiVersion), 0u); }
        return;
    }
    if (gid < r.header->compartmentCount) { nt_validate_compartment(r, gid); }
    if (gid < r.header->cellCount) { nt_validate_cell(r, gid); }
    if (gid < r.header->synapseCount) { nt_validate_synapse(r, gid); }
    if (gid < r.header->fieldValueCount) { nt_validate_field(r, gid); }
    if (gid < r.header->microdomainCount) { nt_validate_microdomain(r, gid); }
    if (gid < r.header->molecularSpeciesCount) {
        const float value = r.molecularSpecies[gid];
        if (!isfinite(value) || value < 0.0f) {
            nt_append_validation(r, value < 0.0f ? 2u : 1u, 1u, uint2(gid, 0u), value, gid);
        }
    }
}

kernel void nt_collect_outputs(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    const uint generated = atomic_load_explicit(&r.counters->generatedSpikesLo, memory_order_relaxed);
    if (gid < min(generated, r.header->eventCapacity)) {
        r.outputEvents[gid] = r.outgoingEvents[gid];
    }
    if (gid >= r.header->tileCount) { return; }
    const NTTileState tile = r.tiles[gid];
    float voltageSum = 0.0f;
    float calciumSum = 0.0f;
    uint activeCount = 0u;
    const uint end = min(tile.compartmentRange.lowerBound + tile.compartmentRange.count, r.header->compartmentCount);
    for (uint index = tile.compartmentRange.lowerBound; index < end; ++index) {
        const NTCompartmentState compartment = r.compartments[index];
        voltageSum += compartment.voltagePreviousCapacitanceAxial.x;
        calciumSum += compartment.injectedSynapticCalciumSodium.z;
        activeCount++;
    }
    const float inverse = activeCount > 0u ? 1.0f / float(activeCount) : 0.0f;
    const uint base = 16u + gid * 4u;
    r.outputScalars[base + 0u] = voltageSum * inverse;
    r.outputScalars[base + 1u] = calciumSum * inverse;
    r.outputScalars[base + 2u] = tile.scores.x;
    r.outputScalars[base + 3u] = tile.scores.z;
}

#endif
