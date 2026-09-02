#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_WORKLISTS
#define NUMITISSUE_WORKLISTS

constant uint NT_WORKLIST_ELECTRICAL = 0u;
constant uint NT_WORKLIST_FIELDS = 1u;
constant uint NT_WORKLIST_MOLECULAR = 2u;
constant uint NT_WORKLIST_MECHANICS = 3u;
constant uint NT_WORKLIST_DEVELOPMENT = 4u;
constant uint NT_WORKLIST_FIDELITY = 5u;
constant uint NT_WORKLIST_OUTPUT = 6u;

inline bool nt_range_nonempty(NTRange range) { return range.count != 0u; }

kernel void nt_build_worklists(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->tileCount) { return; }
    device NTTileState& tile = r.tiles[gid];
    const float activity = max(tile.scores.x, 0.0f);
    const float uncertainty = max(tile.scores.y, 0.0f);
    const float damage = max(tile.scores.z, 0.0f);
    const float metabolic = max(tile.scores.w, 0.0f);
    const ulong currentTick = nt_u64(r.header->phaseStartTickLo, r.header->phaseStartTickHi);
    const ulong lastActive = nt_u64(tile.lastActiveTickLo, tile.lastActiveTickHi);
    const bool recentlyActive = currentTick >= lastActive && (currentTick - lastActive) <= 40000ul;

    if (nt_range_nonempty(tile.compartmentRange) && (activity >= 1.0e-5f || recentlyActive)) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_ELECTRICAL], 1u, memory_order_relaxed);
        r.electricalWorklist[slot] = gid;
    }
    if (nt_range_nonempty(tile.fieldRange)) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_FIELDS], 1u, memory_order_relaxed);
        r.fieldWorklist[slot] = gid;
    }
    if (nt_range_nonempty(tile.microdomainRange) && (activity >= 1.0e-4f || uncertainty > 0.0f || damage > 0.0f)) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_MOLECULAR], 1u, memory_order_relaxed);
        r.molecularWorklist[slot] = gid;
    }
    if (nt_range_nonempty(tile.cellRange) && (activity >= 1.0e-4f || damage > 0.0f)) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_MECHANICS], 1u, memory_order_relaxed);
        r.mechanicsWorklist[slot] = gid;
    }
    if (nt_range_nonempty(tile.cellRange) && (activity >= 1.0e-5f || uncertainty > 0.0f)) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_DEVELOPMENT], 1u, memory_order_relaxed);
        r.developmentWorklist[slot] = gid;
    }
    if (uncertainty > 0.0f || damage > 0.0f || metabolic > 0.0f) {
        const uint slot = atomic_fetch_add_explicit(&r.worklistCounts[NT_WORKLIST_FIDELITY], 1u, memory_order_relaxed);
        r.fidelityWorklist[slot] = gid;
    }
    atomic_fetch_add_explicit(&r.counters->activeTiles, 1u, memory_order_relaxed);
}

kernel void nt_encode_indirect_dispatch(
    constant NTResources& r [[buffer(0)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= 7u) { return; }
    const uint count = atomic_load_explicit(&r.worklistCounts[gid], memory_order_relaxed);
    const uint threadsPerGroup = 64u;
    const uint groups = (count + threadsPerGroup - 1u) / threadsPerGroup;
    const uint base = gid * 3u;
    r.indirectDispatch[base + 0u] = max(groups, 1u);
    r.indirectDispatch[base + 1u] = 1u;
    r.indirectDispatch[base + 2u] = 1u;
}

#endif
