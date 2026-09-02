import Foundation

public extension NTMetalKernelSource {
    static let molecular = #"""
struct NTMicrodomain {
    uint2 id;
    uint2 ownerCell;
    uint2 ownerCompartment;
    uint4 tileAndNetwork;
    uint4 ranges;
    float4 physical;
    uint2 nextEvent;
    uint2 reserved;
};

struct NTReactionNetworkHeader {
    uint4 identity;
    uint4 ranges0;
    uint2 checksum;
    uint2 reserved;
};

struct NTReactionRecord {
    uint4 identityAndRanges;
    uint4 termRanges;
    float4 parameter0;
    float4 parameter1;
    uint4 indices0;
};

struct NTReactantTerm {
    uint2 speciesAndOrder;
};

struct NTStoichiometryTerm {
    int2 speciesAndCoefficient;
};

struct NTMolecularSpeciesParameters {
    float4 boundsAndDiffusion;
    uint4 identityAndFlags;
};

struct NTMolecularCoupling {
    uint4 identities;
    uint2 compartment;
    float4 dynamics;
    uint4 flags;
};

struct NTSpatialMicrodomainHeader {
    uint4 identityAndShape;
    uint4 ranges;
    float4 geometryAndBoundary;
};

inline int nt_find_network(
    uint networkID,
    constant NTReactionNetworkHeader* networks,
    uint networkCount) {
    for (uint index = 0u; index < networkCount; ++index) {
        if (networks[index].identity.x == networkID) return int(index);
    }
    return -1;
}

inline float nt_mass_action(
    NTReactionRecord reaction,
    float rate,
    thread const float* amounts,
    constant NTReactantTerm* reactants,
    bool discrete) {
    float value = rate;
    uint start = reaction.identityAndRanges.z;
    uint count = reaction.identityAndRanges.w;
    for (uint local = 0u; local < count; ++local) {
        NTReactantTerm term = reactants[start + local];
        uint species = term.speciesAndOrder.x;
        uint order = term.speciesAndOrder.y;
        float amount = max(amounts[species], 0.0f);
        if (discrete) {
            float falling = 1.0f;
            for (uint factor = 0u; factor < order; ++factor) falling *= max(0.0f, amount - float(factor));
            value *= falling;
        } else {
            value *= pow(amount, float(order));
        }
    }
    return max(value, 0.0f);
}

inline float nt_reaction_propensity(
    NTReactionRecord reaction,
    thread const float* amounts,
    constant NTReactantTerm* reactants,
    float voltage,
    float calcium,
    bool discrete) {
    uint kind = reaction.identityAndRanges.y;
    if (kind == 0u) return nt_mass_action(reaction, reaction.parameter0.x, amounts, reactants, discrete);
    if (kind == 1u) return max(0.0f, nt_mass_action(reaction, reaction.parameter0.x, amounts, reactants, discrete) - reaction.parameter0.y);
    if (kind == 2u) {
        float substrate = max(0.0f, amounts[reaction.indices0.x]);
        return reaction.parameter0.x * substrate / max(reaction.parameter0.y + substrate, 1.0e-12f);
    }
    if (kind == 3u) {
        float value = pow(max(0.0f, amounts[reaction.indices0.x]), reaction.parameter0.z);
        return reaction.parameter0.x * value / max(pow(reaction.parameter0.y, reaction.parameter0.z) + value, 1.0e-12f);
    }
    if (kind == 4u) {
        float substrate = max(0.0f, amounts[reaction.indices0.x]);
        float inhibitor = max(0.0f, amounts[reaction.indices0.y]);
        return reaction.parameter0.x * substrate /
            max(reaction.parameter0.y * (1.0f + inhibitor / max(reaction.parameter0.z, 1.0e-12f)) + substrate, 1.0e-12f);
    }
    if (kind == 5u) {
        return reaction.parameter0.x /
            (1.0f + exp(-(voltage - reaction.parameter0.y) / max(fabs(reaction.parameter0.z), 1.0e-6f)));
    }
    if (kind == 6u) {
        float value = pow(max(calcium, 0.0f), reaction.parameter0.z);
        return reaction.parameter0.x * value /
            max(pow(reaction.parameter0.y, reaction.parameter0.z) + value, 1.0e-12f);
    }
    float affine = reaction.parameter0.x;
    for (uint lane = 0u; lane < 4u; ++lane) {
        uint species = reaction.indices0[lane];
        if (species != NT_INVALID_INDEX) affine += reaction.parameter1[lane] * amounts[species];
    }
    return max(affine, 0.0f);
}

inline int nt_feasible_count(
    NTReactionRecord reaction,
    int requested,
    thread const float* amounts,
    constant NTReactantTerm* reactants) {
    int feasible = requested;
    uint start = reaction.identityAndRanges.z;
    uint count = reaction.identityAndRanges.w;
    for (uint local = 0u; local < count; ++local) {
        NTReactantTerm term = reactants[start + local];
        uint order = max(term.speciesAndOrder.y, 1u);
        feasible = min(feasible, int(floor(max(amounts[term.speciesAndOrder.x], 0.0f) / float(order))));
    }
    return max(feasible, 0);
}

inline void nt_apply_reaction(
    NTReactionRecord reaction,
    int count,
    thread float* amounts,
    constant NTStoichiometryTerm* stoichiometry) {
    uint start = reaction.termRanges.x;
    uint termCount = reaction.termRanges.y;
    for (uint local = 0u; local < termCount; ++local) {
        NTStoichiometryTerm term = stoichiometry[start + local];
        amounts[uint(term.speciesAndCoefficient.x)] += float(term.speciesAndCoefficient.y * count);
    }
}

inline float nt_normal(uint a, uint b) {
    float u1 = max(nt_uniform01(a), 1.0e-12f);
    float u2 = nt_uniform01(b);
    return sqrt(-2.0f * log(u1)) * cos(2.0f * NT_PI * u2);
}

inline int nt_poisson(float lambda, uint4 random) {
    if (lambda <= 0.0f) return 0;
    if (lambda < 30.0f) {
        float limit = exp(-lambda);
        float product = 1.0f;
        int count = 0;
        uint4 current = random;
        while (product > limit && count < 128) {
            product *= nt_uniform01(current[uint(count) & 3u]);
            ++count;
            if ((count & 3) == 0) current = nt_philox(current, uint2(uint(count), 0x9e3779b9u));
        }
        return max(count - 1, 0);
    }
    return max(0, int(rint(lambda + sqrt(lambda) * nt_normal(random.x, random.y))));
}

kernel void nt_molecular_select_solver(
    device NTMicrodomain* domains [[buffer(0)]],
    device const float* speciesAmounts [[buffer(1)]],
    constant NTReactionNetworkHeader* networks [[buffer(2)]],
    constant NTMolecularSpeciesParameters* speciesParameters [[buffer(3)]],
    constant uint4& counts [[buffer(4)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= counts.x) return;
    NTMicrodomain domain = domains[gid];
    int networkIndex = nt_find_network(domain.tileAndNetwork.y, networks, counts.y);
    if (networkIndex < 0) return;
    NTReactionNetworkHeader network = networks[uint(networkIndex)];
    float minimum = INFINITY;
    float mean = 0.0f;
    bool hasDiscreteLowCopy = false;
    bool spatial = false;
    for (uint local = 0u; local < domain.ranges.y; ++local) {
        float amount = speciesAmounts[domain.ranges.x + local];
        minimum = min(minimum, amount);
        mean += amount;
        NTMolecularSpeciesParameters parameter = speciesParameters[network.ranges0.z + local];
        hasDiscreteLowCopy = hasDiscreteLowCopy || (parameter.identityAndFlags.y != 0u && amount < 1000.0f);
        spatial = spatial || parameter.boundsAndDiffusion.z > 0.0f;
    }
    mean /= max(float(domain.ranges.y), 1.0f);
    uint solver = spatial && domain.ranges.y <= 64u ? 3u :
        (minimum < 100.0f || hasDiscreteLowCopy) ? 0u :
        mean < 100000.0f ? 1u : 2u;
    domain.tileAndNetwork.z = solver;
    domains[gid] = domain;
}

kernel void nt_molecular_step_serial(
    constant NTWorldConstants& world [[buffer(0)]],
    device NTMicrodomain* domains [[buffer(1)]],
    device float* speciesAmounts [[buffer(2)]],
    constant NTReactionNetworkHeader* networks [[buffer(3)]],
    constant NTReactionRecord* reactions [[buffer(4)]],
    constant NTReactantTerm* reactants [[buffer(5)]],
    constant NTStoichiometryTerm* stoichiometry [[buffer(6)]],
    constant NTMolecularSpeciesParameters* speciesParameters [[buffer(7)]],
    device const NTCompartment* compartments [[buffer(8)]],
    constant uint4& counts [[buffer(9)]],
    constant float4& step [[buffer(10)]],
    device atomic_uint* statistics [[buffer(11)]],
    device NTValidationCounters* validation [[buffer(12)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= counts.x) return;
    NTMicrodomain domain = domains[gid];
    int networkIndexValue = nt_find_network(domain.tileAndNetwork.y, networks, counts.y);
    if (networkIndexValue < 0 || domain.ranges.y > 64u) {
        nt_record_fatal(validation, 1u);
        return;
    }
    NTReactionNetworkHeader network = networks[uint(networkIndexValue)];
    thread float amounts[64];
    thread float derivative0[64];
    thread float derivative1[64];
    for (uint species = 0u; species < domain.ranges.y; ++species) {
        amounts[species] = speciesAmounts[domain.ranges.x + species];
    }
    float voltage = -65.0f;
    float calcium = 0.05f;
    if (domain.ownerCompartment.x != NT_INVALID_INDEX || domain.ownerCompartment.y != NT_INVALID_INDEX) {
        for (uint compartmentIndex = 0u; compartmentIndex < world.counts0.z; ++compartmentIndex) {
            if (all(compartments[compartmentIndex].id == domain.ownerCompartment)) {
                voltage = compartments[compartmentIndex].geometryAndVoltage.w;
                calcium = compartments[compartmentIndex].ions0.x;
                break;
            }
        }
    }
    float duration = step.x;
    uint solver = domain.tileAndNetwork.z;
    uint reactionStart = network.ranges0.x;
    uint reactionCount = network.ranges0.y;
    if (solver == 0u) {
        float elapsed = 0.0f;
        uint event = 0u;
        while (elapsed < duration && event < counts.z) {
            float total = 0.0f;
            for (uint local = 0u; local < reactionCount; ++local) {
                total += nt_reaction_propensity(reactions[reactionStart + local], amounts, reactants, voltage, calcium, true);
            }
            if (!isfinite(total) || total <= 0.0f) break;
            uint4 random = nt_philox(uint4(event, gid, world.clock1.x, world.clock1.y), world.seed.xy);
            float waiting = -log(max(nt_uniform01(random.x), 1.0e-12f)) / total;
            if (elapsed + waiting > duration) break;
            float threshold = nt_uniform01(random.y) * total;
            float cumulative = 0.0f;
            uint selected = reactionCount - 1u;
            for (uint local = 0u; local < reactionCount; ++local) {
                cumulative += nt_reaction_propensity(reactions[reactionStart + local], amounts, reactants, voltage, calcium, true);
                if (cumulative >= threshold) { selected = local; break; }
            }
            NTReactionRecord reaction = reactions[reactionStart + selected];
            if (nt_feasible_count(reaction, 1, amounts, reactants) > 0) nt_apply_reaction(reaction, 1, amounts, stoichiometry);
            elapsed += waiting;
            ++event;
        }
        atomic_fetch_add_explicit(statistics + 0, event, memory_order_relaxed);
        if (event == counts.z) domain.tileAndNetwork.z = 1u;
    } else if (solver == 1u) {
        float elapsed = 0.0f;
        uint leap = 0u;
        while (elapsed < duration && leap < counts.w) {
            float maximumPropensity = 0.0f;
            float minimumPositive = INFINITY;
            for (uint species = 0u; species < domain.ranges.y; ++species) {
                if (amounts[species] > 0.0f) minimumPositive = min(minimumPositive, amounts[species]);
            }
            for (uint local = 0u; local < reactionCount; ++local) {
                maximumPropensity = max(maximumPropensity,
                    nt_reaction_propensity(reactions[reactionStart + local], amounts, reactants, voltage, calcium, false));
            }
            if (maximumPropensity <= 0.0f || !isfinite(maximumPropensity)) break;
            float tau = min(duration - elapsed, max(1.0e-7f, 0.03f * max(minimumPositive, 1.0f) / maximumPropensity));
            for (uint local = 0u; local < reactionCount; ++local) {
                NTReactionRecord reaction = reactions[reactionStart + local];
                float propensity = nt_reaction_propensity(reaction, amounts, reactants, voltage, calcium, false);
                uint4 random = nt_philox(uint4(leap, local, gid, world.clock1.x), world.seed.xy);
                int requested = min(int(counts.z), nt_poisson(min(float(counts.z), max(0.0f, propensity * tau)), random));
                int feasible = nt_feasible_count(reaction, requested, amounts, reactants);
                if (feasible > 0) {
                    nt_apply_reaction(reaction, feasible, amounts, stoichiometry);
                    atomic_fetch_add_explicit(statistics + 1, uint(feasible), memory_order_relaxed);
                }
            }
            elapsed += tau;
            ++leap;
        }
    } else {
        float elapsed = 0.0f;
        float h = min(duration, 0.001f);
        uint evaluations = 0u;
        while (elapsed < duration && evaluations < counts.w * 2u) {
            h = min(h, duration - elapsed);
            for (uint species = 0u; species < domain.ranges.y; ++species) derivative0[species] = 0.0f;
            for (uint local = 0u; local < reactionCount; ++local) {
                NTReactionRecord reaction = reactions[reactionStart + local];
                float rate = nt_reaction_propensity(reaction, amounts, reactants, voltage, calcium, false);
                for (uint term = 0u; term < reaction.termRanges.y; ++term) {
                    NTStoichiometryTerm value = stoichiometry[reaction.termRanges.x + term];
                    derivative0[uint(value.speciesAndCoefficient.x)] += float(value.speciesAndCoefficient.y) * rate;
                }
            }
            thread float trial[64];
            for (uint species = 0u; species < domain.ranges.y; ++species) trial[species] = max(0.0f, amounts[species] + h * derivative0[species]);
            for (uint species = 0u; species < domain.ranges.y; ++species) derivative1[species] = 0.0f;
            for (uint local = 0u; local < reactionCount; ++local) {
                NTReactionRecord reaction = reactions[reactionStart + local];
                float rate = nt_reaction_propensity(reaction, trial, reactants, voltage, calcium, false);
                for (uint term = 0u; term < reaction.termRanges.y; ++term) {
                    NTStoichiometryTerm value = stoichiometry[reaction.termRanges.x + term];
                    derivative1[uint(value.speciesAndCoefficient.x)] += float(value.speciesAndCoefficient.y) * rate;
                }
            }
            float error = 0.0f;
            for (uint species = 0u; species < domain.ranges.y; ++species) {
                float corrected = max(0.0f, amounts[species] + 0.5f * h * (derivative0[species] + derivative1[species]));
                float scale = step.y + step.z * max(fabs(amounts[species]), fabs(corrected));
                error = max(error, fabs(corrected - trial[species]) / max(scale, 1.0e-12f));
                derivative1[species] = corrected;
            }
            if (error <= 1.0f || h <= 1.0e-9f) {
                for (uint species = 0u; species < domain.ranges.y; ++species) amounts[species] = derivative1[species];
                elapsed += h;
            }
            float factor = error > 0.0f ? 0.9f * pow(error, -0.5f) : 2.0f;
            h *= clamp(factor, 0.2f, 2.0f);
            evaluations += 2u;
        }
        atomic_fetch_add_explicit(statistics + 2, evaluations, memory_order_relaxed);
    }
    for (uint species = 0u; species < domain.ranges.y; ++species) {
        NTMolecularSpeciesParameters parameter = speciesParameters[network.ranges0.z + species];
        float value = amounts[species];
        if (!isfinite(value)) {
            nt_record_fatal(validation, 0u);
            value = parameter.boundsAndDiffusion.x;
        }
        if (value < parameter.boundsAndDiffusion.x) nt_record_error(validation, 1u);
        speciesAmounts[domain.ranges.x + species] = clamp(value, parameter.boundsAndDiffusion.x, parameter.boundsAndDiffusion.y);
    }
    domains[gid] = domain;
}

kernel void nt_molecular_apply_couplings(
    device NTMicrodomain* domains [[buffer(0)]],
    device float* speciesAmounts [[buffer(1)]],
    device NTCompartment* compartments [[buffer(2)]],
    device atomic_uint* fieldSourceBits [[buffer(3)]],
    constant NTMolecularCoupling* couplings [[buffer(4)]],
    constant uint4& counts [[buffer(5)]],
    constant float4& step [[buffer(6)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= counts.x) return;
    NTMolecularCoupling coupling = couplings[gid];
    uint domainIndex = NT_INVALID_INDEX;
    for (uint index = 0u; index < counts.y; ++index) {
        if (all(domains[index].id == coupling.identities.xy)) { domainIndex = index; break; }
    }
    if (domainIndex == NT_INVALID_INDEX) return;
    NTMicrodomain domain = domains[domainIndex];
    uint speciesIndex = coupling.identities.z;
    if (speciesIndex >= domain.ranges.y) return;
    uint amountIndex = domain.ranges.x + speciesIndex;
    uint compartmentIndex = NT_INVALID_INDEX;
    if (coupling.compartment.x != NT_INVALID_INDEX || coupling.compartment.y != NT_INVALID_INDEX) {
        for (uint index = 0u; index < counts.z; ++index) {
            if (all(compartments[index].id == coupling.compartment)) { compartmentIndex = index; break; }
        }
    }
    float dt = step.x;
    if (compartmentIndex != NT_INVALID_INDEX && coupling.flags.x != 0u) {
        speciesAmounts[amountIndex] = compartments[compartmentIndex].ions0.x;
    }
    if (compartmentIndex != NT_INVALID_INDEX && coupling.dynamics.x != 0.0f) {
        float amount = speciesAmounts[amountIndex];
        float calcium = compartments[compartmentIndex].ions0.x;
        compartments[compartmentIndex].ions0.x = max(0.0f, calcium + coupling.dynamics.x * (amount - calcium) * dt);
    }
    uint fieldIndex = coupling.identities.w;
    if (fieldIndex != NT_INVALID_INDEX && fieldIndex < counts.w && coupling.dynamics.y != 0.0f) {
        nt_atomic_add_float(fieldSourceBits + fieldIndex, coupling.dynamics.y * speciesAmounts[amountIndex]);
    }
}

kernel void nt_molecular_spatial_diffuse(
    device const float* amountsRead [[buffer(0)]],
    device float* amountsWrite [[buffer(1)]],
    constant NTSpatialMicrodomainHeader* headers [[buffer(2)]],
    constant NTMolecularSpeciesParameters* speciesParameters [[buffer(3)]],
    constant uint4& counts [[buffer(4)]],
    constant float4& step [[buffer(5)]],
    uint gid [[thread_position_in_grid]]) {
    if (gid >= counts.x) return;
    uint domainIndex = 0u;
    while (domainIndex + 1u < counts.y && gid >= headers[domainIndex].ranges.x + headers[domainIndex].ranges.y) ++domainIndex;
    NTSpatialMicrodomainHeader header = headers[domainIndex];
    uint local = gid - header.ranges.x;
    uint speciesCount = header.identityAndShape.w;
    uint species = local % speciesCount;
    uint voxel = local / speciesCount;
    uint nx = header.identityAndShape.y;
    uint ny = header.identityAndShape.z;
    uint nz = header.ranges.z;
    uint x = voxel % nx;
    uint y = (voxel / nx) % ny;
    uint z = voxel / (nx * ny);
    float center = amountsRead[gid];
    auto value = [&](int px, int py, int pz) -> float {
        if (px < 0 || px >= int(nx) || py < 0 || py >= int(ny) || pz < 0 || pz >= int(nz)) {
            return center * max(0.0f, 1.0f - header.geometryAndBoundary.y * step.y);
        }
        uint neighborVoxel = (uint(pz) * ny * nx) + (uint(py) * nx) + uint(px);
        return amountsRead[header.ranges.x + neighborVoxel * speciesCount + species];
    };
    float sum = value(int(x) - 1, int(y), int(z)) + value(int(x) + 1, int(y), int(z)) +
        value(int(x), int(y) - 1, int(z)) + value(int(x), int(y) + 1, int(z)) +
        value(int(x), int(y), int(z) - 1) + value(int(x), int(y), int(z) + 1);
    float diffusion = speciesParameters[header.ranges.w + species].boundsAndDiffusion.z;
    float inverseDx2 = 1.0f / max(header.geometryAndBoundary.x * header.geometryAndBoundary.x, 1.0e-12f);
    amountsWrite[gid] = max(0.0f, center + step.y * diffusion * (sum - 6.0f * center) * inverseDx2);
}
"""#

    static var completeWithMolecular: String { completeWithFields + "\n" + molecular }
}
