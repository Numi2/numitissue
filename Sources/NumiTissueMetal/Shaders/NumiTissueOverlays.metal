#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_TRANSACTION_OVERLAYS
#define NUMITISSUE_TRANSACTION_OVERLAYS

struct NTOverlayGroup {
    uint4 addressing; // domain, component, record offset, record count
    uint4 metadata;   // path hash lo/hi, scalar stride, scalar count
};

struct NTOverlayRecord {
    uint4 addressing; // lower bound, count, operation, flags
    float4 values;    // value, minimum, maximum, reserved
    uint4 metadata;   // sequence, source hash lo/hi, reserved
};

struct NTOverlayMaterializationParameters {
    uint4 counts;      // groups, records, state groups, parameter groups
    uint4 transaction; // transaction lo/hi, overlay digest lo/hi
};

constant uint NT_OVERLAY_CELL = 0u;
constant uint NT_OVERLAY_SEGMENT = 1u;
constant uint NT_OVERLAY_COMPARTMENT = 2u;
constant uint NT_OVERLAY_SYNAPSE = 3u;
constant uint NT_OVERLAY_FIELD = 4u;
constant uint NT_OVERLAY_MECHANISM_STATE = 5u;
constant uint NT_OVERLAY_MOLECULAR_SPECIES = 6u;
constant uint NT_OVERLAY_REGULATORY_STATE = 7u;
constant uint NT_OVERLAY_CHANNEL_PARAMETER = 32u;
constant uint NT_OVERLAY_MECHANISM_SET_PARAMETER = 33u;
constant uint NT_OVERLAY_SYNAPSE_PARAMETER = 34u;
constant uint NT_OVERLAY_FIELD_PARAMETER = 35u;
constant uint NT_OVERLAY_CELL_PROGRAM_PARAMETER = 36u;
constant uint NT_OVERLAY_REGULATORY_PROGRAM_PARAMETER = 37u;
constant uint NT_OVERLAY_FATE_PARAMETER = 38u;
constant uint NT_OVERLAY_GROWTH_PARAMETER = 39u;
constant uint NT_OVERLAY_GLIAL_PARAMETER = 40u;
constant uint NT_OVERLAY_MOLECULAR_REACTION_PARAMETER = 41u;

inline float nt_apply_overlay_operation(float current, const NTOverlayRecord record) {
    float value = current;
    switch (record.addressing.z) {
        case 0u: value = record.values.x; break;
        case 1u: value += record.values.x; break;
        case 2u: value *= record.values.x; break;
        case 3u: value = min(value, record.values.x); break;
        case 4u: value = max(value, record.values.x); break;
        default: break;
    }
    if ((record.addressing.w & 1u) != 0u) { value = max(value, record.values.y); }
    if ((record.addressing.w & 2u) != 0u) { value = min(value, record.values.z); }
    return value;
}

inline bool nt_overlay_contains(const NTOverlayRecord record, uint logicalIndex) {
    const ulong upper = ulong(record.addressing.x) + ulong(record.addressing.y);
    return ulong(logicalIndex) >= ulong(record.addressing.x) && ulong(logicalIndex) < upper;
}

inline float nt_overlay_cell_read(const device NTCellState& cell, uint component) {
    switch (component) {
        case 0u: return cell.ageCycleDifferentiationEnergy.w;
        case 1u: return cell.stressDamageHazard.x;
        case 2u: return cell.stressDamageHazard.y;
        case 3u: return cell.stressDamageHazard.z;
        case 4u: return cell.stressDamageHazard.w;
        case 5u: return cell.ageCycleDifferentiationEnergy.y;
        case 6u: return cell.ageCycleDifferentiationEnergy.z;
        case 7u: return cell.ageCycleDifferentiationEnergy.x;
        case 8u: return float(cell.fidelityAndFlags & 0xFFu);
        default: return 0.0f;
    }
}

inline void nt_overlay_cell_write(device NTCellState& cell, uint component, float value) {
    switch (component) {
        case 0u: cell.ageCycleDifferentiationEnergy.w = value; break;
        case 1u: cell.stressDamageHazard.x = value; break;
        case 2u: cell.stressDamageHazard.y = value; break;
        case 3u: cell.stressDamageHazard.z = value; break;
        case 4u: cell.stressDamageHazard.w = value; break;
        case 5u: cell.ageCycleDifferentiationEnergy.y = value; break;
        case 6u: cell.ageCycleDifferentiationEnergy.z = value; break;
        case 7u: cell.ageCycleDifferentiationEnergy.x = value; break;
        case 8u: {
            const uint fidelity = uint(clamp(round(value), 0.0f, 4.0f));
            cell.fidelityAndFlags = (cell.fidelityAndFlags & 0xFFFFFF00u) | fidelity;
            break;
        }
        default: break;
    }
}

inline float nt_overlay_segment_read(const device NTSegmentState& segment, uint component) {
    switch (component) {
        case 0u: return segment.radiusMyelinGrowthScore.x;
        case 1u: return segment.radiusMyelinGrowthScore.y;
        case 2u: return segment.radiusMyelinGrowthScore.z;
        case 3u: return segment.radiusMyelinGrowthScore.w;
        default: return 0.0f;
    }
}

inline void nt_overlay_segment_write(device NTSegmentState& segment, uint component, float value) {
    switch (component) {
        case 0u: segment.radiusMyelinGrowthScore.x = value; break;
        case 1u: segment.radiusMyelinGrowthScore.y = value; break;
        case 2u: segment.radiusMyelinGrowthScore.z = value; break;
        case 3u: segment.radiusMyelinGrowthScore.w = value; break;
        default: break;
    }
}

inline float nt_overlay_compartment_read(const device NTCompartmentState& compartment, uint component) {
    switch (component) {
        case 0u: return compartment.voltagePreviousCapacitanceAxial.x;
        case 1u: return compartment.voltagePreviousCapacitanceAxial.z;
        case 2u: return compartment.voltagePreviousCapacitanceAxial.w;
        case 3u: return compartment.injectedSynapticCalciumSodium.x;
        case 4u: return compartment.injectedSynapticCalciumSodium.y;
        case 5u: return compartment.injectedSynapticCalciumSodium.z;
        case 6u: return compartment.injectedSynapticCalciumSodium.w;
        case 7u: return compartment.potassiumReserved.x;
        default: return 0.0f;
    }
}

inline void nt_overlay_compartment_write(device NTCompartmentState& compartment, uint component, float value) {
    switch (component) {
        case 0u:
            compartment.voltagePreviousCapacitanceAxial.x = value;
            compartment.voltagePreviousCapacitanceAxial.y = value;
            break;
        case 1u: compartment.voltagePreviousCapacitanceAxial.z = value; break;
        case 2u: compartment.voltagePreviousCapacitanceAxial.w = value; break;
        case 3u: compartment.injectedSynapticCalciumSodium.x = value; break;
        case 4u: compartment.injectedSynapticCalciumSodium.y = value; break;
        case 5u: compartment.injectedSynapticCalciumSodium.z = value; break;
        case 6u: compartment.injectedSynapticCalciumSodium.w = value; break;
        case 7u: compartment.potassiumReserved.x = value; break;
        default: break;
    }
}

inline float nt_overlay_synapse_read(const device NTSynapseState& synapse, uint component) {
    switch (component) {
        case 0u: return synapse.weightConductanceUtilizationResources.x;
        case 1u: return synapse.weightConductanceUtilizationResources.y;
        case 2u: return synapse.weightConductanceUtilizationResources.z;
        case 3u: return synapse.weightConductanceUtilizationResources.w;
        case 4u: return synapse.prePostEligibilityConsolidation.x;
        case 5u: return synapse.prePostEligibilityConsolidation.y;
        case 6u: return synapse.prePostEligibilityConsolidation.z;
        case 7u: return synapse.prePostEligibilityConsolidation.w;
        case 8u: return synapse.structuralReserved.x;
        default: return 0.0f;
    }
}

inline void nt_overlay_synapse_write(device NTSynapseState& synapse, uint component, float value) {
    switch (component) {
        case 0u: synapse.weightConductanceUtilizationResources.x = value; break;
        case 1u: synapse.weightConductanceUtilizationResources.y = value; break;
        case 2u: synapse.weightConductanceUtilizationResources.z = value; break;
        case 3u: synapse.weightConductanceUtilizationResources.w = value; break;
        case 4u: synapse.prePostEligibilityConsolidation.x = value; break;
        case 5u: synapse.prePostEligibilityConsolidation.y = value; break;
        case 6u: synapse.prePostEligibilityConsolidation.z = value; break;
        case 7u: synapse.prePostEligibilityConsolidation.w = value; break;
        case 8u: synapse.structuralReserved.x = value; break;
        default: break;
    }
}

inline float nt_overlay_field_read(const device NTFieldState& field, uint component) {
    return component < 4u ? field.concentrationSourceSinkDiffusion[component] : 0.0f;
}

inline void nt_overlay_field_write(device NTFieldState& field, uint component, float value) {
    if (component < 4u) { field.concentrationSourceSinkDiffusion[component] = value; }
}

kernel void nt_materialize_state_overlays(
    constant NTResources& r [[buffer(0)]],
    const device NTOverlayGroup* groups [[buffer(1)]],
    const device NTOverlayRecord* records [[buffer(2)]],
    constant NTOverlayMaterializationParameters& parameters [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid != 0u) { return; }
    const uint groupCount = parameters.counts.x;
    const uint recordCount = parameters.counts.y;
    for (uint groupIndex = 0u; groupIndex < groupCount; ++groupIndex) {
        const NTOverlayGroup group = groups[groupIndex];
        const uint domain = group.addressing.x;
        if (domain >= NT_OVERLAY_CHANNEL_PARAMETER) { continue; }
        const uint component = group.addressing.y;
        const uint endRecord = min(group.addressing.z + group.addressing.w, recordCount);
        for (uint recordIndex = group.addressing.z; recordIndex < endRecord; ++recordIndex) {
            const NTOverlayRecord record = records[recordIndex];
            const uint upper = record.addressing.x + record.addressing.y;
            for (uint index = record.addressing.x; index < upper; ++index) {
                switch (domain) {
                    case NT_OVERLAY_CELL:
                        if (index < r.header->cellCount) {
                            float value = nt_overlay_cell_read(r.cells[index], component);
                            nt_overlay_cell_write(r.cells[index], component, nt_apply_overlay_operation(value, record));
                        }
                        break;
                    case NT_OVERLAY_SEGMENT:
                        if (index < r.header->segmentCount) {
                            float value = nt_overlay_segment_read(r.segments[index], component);
                            nt_overlay_segment_write(r.segments[index], component, nt_apply_overlay_operation(value, record));
                        }
                        break;
                    case NT_OVERLAY_COMPARTMENT:
                        if (index < r.header->compartmentCount) {
                            float value = nt_overlay_compartment_read(r.compartments[index], component);
                            nt_overlay_compartment_write(r.compartments[index], component, nt_apply_overlay_operation(value, record));
                        }
                        break;
                    case NT_OVERLAY_SYNAPSE:
                        if (index < r.header->synapseCount) {
                            float value = nt_overlay_synapse_read(r.synapses[index], component);
                            nt_overlay_synapse_write(r.synapses[index], component, nt_apply_overlay_operation(value, record));
                        }
                        break;
                    case NT_OVERLAY_FIELD:
                        if (index < r.header->fieldValueCount) {
                            float value = nt_overlay_field_read(r.fields[index], component);
                            nt_overlay_field_write(r.fields[index], component, nt_apply_overlay_operation(value, record));
                        }
                        break;
                    case NT_OVERLAY_MECHANISM_STATE:
                        if (index < group.metadata.w) { r.mechanismState[index] = nt_apply_overlay_operation(r.mechanismState[index], record); }
                        break;
                    case NT_OVERLAY_MOLECULAR_SPECIES:
                        if (index < r.header->molecularSpeciesCount) { r.molecularSpecies[index] = nt_apply_overlay_operation(r.molecularSpecies[index], record); }
                        break;
                    case NT_OVERLAY_REGULATORY_STATE:
                        if (index < group.metadata.w) { r.regulatoryState[index] = nt_apply_overlay_operation(r.regulatoryState[index], record); }
                        break;
                    default: break;
                }
            }
        }
    }
}

inline device float* nt_parameter_table(
    uint domain,
    device float* channelParameters,
    device float* mechanismSetParameters,
    device float* synapseParameters,
    device float* fieldParameters,
    device float* cellProgramParameters,
    device float* regulatoryProgramParameters,
    device float* fateParameters,
    device float* growthParameters,
    device float* glialParameters,
    device float* molecularReactionParameters
) {
    switch (domain) {
        case NT_OVERLAY_CHANNEL_PARAMETER: return channelParameters;
        case NT_OVERLAY_MECHANISM_SET_PARAMETER: return mechanismSetParameters;
        case NT_OVERLAY_SYNAPSE_PARAMETER: return synapseParameters;
        case NT_OVERLAY_FIELD_PARAMETER: return fieldParameters;
        case NT_OVERLAY_CELL_PROGRAM_PARAMETER: return cellProgramParameters;
        case NT_OVERLAY_REGULATORY_PROGRAM_PARAMETER: return regulatoryProgramParameters;
        case NT_OVERLAY_FATE_PARAMETER: return fateParameters;
        case NT_OVERLAY_GROWTH_PARAMETER: return growthParameters;
        case NT_OVERLAY_GLIAL_PARAMETER: return glialParameters;
        case NT_OVERLAY_MOLECULAR_REACTION_PARAMETER: return molecularReactionParameters;
        default: return nullptr;
    }
}

kernel void nt_materialize_parameter_overlays(
    constant NTResources& r [[buffer(0)]],
    const device NTOverlayGroup* groups [[buffer(1)]],
    const device NTOverlayRecord* records [[buffer(2)]],
    constant NTOverlayMaterializationParameters& parameters [[buffer(3)]],
    device float* channelParameters [[buffer(4)]],
    device float* mechanismSetParameters [[buffer(5)]],
    device float* synapseParameters [[buffer(6)]],
    device float* fieldParameters [[buffer(7)]],
    device float* cellProgramParameters [[buffer(8)]],
    device float* regulatoryProgramParameters [[buffer(9)]],
    device float* fateParameters [[buffer(10)]],
    device float* growthParameters [[buffer(11)]],
    device float* glialParameters [[buffer(12)]],
    device float* molecularReactionParameters [[buffer(13)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid != 0u) { return; }
    const uint groupCount = parameters.counts.x;
    const uint recordCount = parameters.counts.y;
    for (uint groupIndex = 0u; groupIndex < groupCount; ++groupIndex) {
        const NTOverlayGroup group = groups[groupIndex];
        const uint domain = group.addressing.x;
        if (domain < NT_OVERLAY_CHANNEL_PARAMETER) { continue; }
        device float* table = nt_parameter_table(
            domain,
            channelParameters,
            mechanismSetParameters,
            synapseParameters,
            fieldParameters,
            cellProgramParameters,
            regulatoryProgramParameters,
            fateParameters,
            growthParameters,
            glialParameters,
            molecularReactionParameters
        );
        if (table == nullptr || group.metadata.z == 0u) { continue; }
        const uint component = group.addressing.y;
        if (component >= group.metadata.z) { continue; }
        const uint endRecord = min(group.addressing.z + group.addressing.w, recordCount);
        for (uint recordIndex = group.addressing.z; recordIndex < endRecord; ++recordIndex) {
            const NTOverlayRecord record = records[recordIndex];
            const uint upper = record.addressing.x + record.addressing.y;
            for (uint element = record.addressing.x; element < upper; ++element) {
                const uint scalarIndex = element * group.metadata.z + component;
                if (scalarIndex >= group.metadata.w) { continue; }
                table[scalarIndex] = nt_apply_overlay_operation(table[scalarIndex], record);
            }
        }
    }
}

#endif
