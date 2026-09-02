#include <metal_stdlib>
using namespace metal;

struct NTOverlayGroup {
    ushort domain;
    ushort component;
    uint recordOffset;
    uint recordCount;
    uint pathHashLow;
    uint pathHashHigh;
    uint reserved0;
    uint reserved1;
};

struct NTOverlayRecord {
    uint lowerBound;
    uint count;
    ushort operation;
    ushort flags;
    float value;
    float minimum;
    float maximum;
    float reserved;
    uint sourceHashLow;
    uint sourceHashHigh;
    uint reserved0;
    uint reserved1;
};

struct NTOverlayMaterializationParameters {
    uint elementCount;
    uint groupIndex;
    uint sourceOffset;
    uint destinationOffset;
    float baseline;
    uint flags;
    uint reserved0;
    uint reserved1;
};

inline float nt_apply_overlay_operation(float current, const NTOverlayRecord record) {
    float value = current;
    switch (record.operation) {
        case 0: value = record.value; break;
        case 1: value += record.value; break;
        case 2: value *= record.value; break;
        case 3: value = min(value, record.value); break;
        case 4: value = max(value, record.value); break;
        default: break;
    }
    if ((record.flags & 1u) != 0u) { value = max(value, record.minimum); }
    if ((record.flags & 2u) != 0u) { value = min(value, record.maximum); }
    return value;
}

kernel void nt_overlay_materialize_f32(
    const device float *source [[buffer(0)]],
    device float *destination [[buffer(1)]],
    const device NTOverlayGroup *groups [[buffer(2)]],
    const device NTOverlayRecord *records [[buffer(3)]],
    constant NTOverlayMaterializationParameters &parameters [[buffer(4)]],
    uint elementIndex [[thread_position_in_grid]]
) {
    if (elementIndex >= parameters.elementCount) { return; }
    const NTOverlayGroup group = groups[parameters.groupIndex];
    const uint logicalIndex = parameters.sourceOffset + elementIndex;
    float value = (parameters.flags & 1u) != 0u
        ? parameters.baseline
        : source[logicalIndex];

    for (uint recordIndex = 0u; recordIndex < group.recordCount; ++recordIndex) {
        const NTOverlayRecord record = records[group.recordOffset + recordIndex];
        const ulong upper = ulong(record.lowerBound) + ulong(record.count);
        if (ulong(logicalIndex) >= ulong(record.lowerBound)
            && ulong(logicalIndex) < upper) {
            value = nt_apply_overlay_operation(value, record);
        }
    }
    destination[parameters.destinationOffset + elementIndex] = value;
}
