#include <metal_stdlib>
using namespace metal;

// FP32 observation only. No atomic accumulation or mutation of tissue state.
// Matrix [source,electrode], current [frame,source], output/status [frame,electrode].
kernel void culture_leadfield_scientific32(
    device const float* resistance [[buffer(0)]],
    device const float* currents [[buffer(1)]],
    device float* volts [[buffer(2)]],
    device uint* status [[buffer(3)]],
    constant uint4& dimensions [[buffer(4)]],
    uint2 location [[thread_position_in_grid]]) {
    const uint sources = dimensions.x;
    const uint electrodes = dimensions.y;
    const uint frames = dimensions.z;
    const uint electrode = location.x;
    const uint frame = location.y;
    if (electrode >= electrodes || frame >= frames) return;
    float sum = 0.0f;
    uint flags = 0;
    for (uint source = 0; source < sources; ++source) {
        const float current = currents[frame * sources + source];
        if (!isfinite(current)) flags |= 1u;
        sum += resistance[source * electrodes + electrode] * current;
    }
    if (!isfinite(sum)) flags |= 2u;
    const uint index = frame * electrodes + electrode;
    volts[index] = sum;
    status[index] = flags;
}
