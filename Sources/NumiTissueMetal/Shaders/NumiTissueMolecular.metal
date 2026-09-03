#include <metal_stdlib>
using namespace metal;

#ifndef NUMITISSUE_MOLECULAR
#define NUMITISSUE_MOLECULAR

constant uint NT_MAX_DOMAIN_SPECIES = 64u;
constant uint NT_MAX_REACTION_FIRINGS_PER_QUANTUM = 32u;
constant uint NT_MOLECULAR_REACTION_PARAMETER_STRIDE = 2u;

struct NTMolecularNetwork {
    uint reactionOffset;
    uint reactionCount;
    uint speciesCount;
    uint flags;
};

struct NTMolecularReaction {
    uint4 reactants;
    uint4 products;
    char4 reactantStoichiometry;
    char4 productStoichiometry;
    float rateConstant;
    float reverseRateConstant;
    uint order;
    uint flags;
};

inline float nt_falling_factorial(float amount, uint order) {
    if (order == 0u) { return 1.0f; }
    if (order == 1u) { return max(amount, 0.0f); }
    if (order == 2u) { return max(amount * max(amount - 1.0f, 0.0f), 0.0f) * 0.5f; }
    float result = 1.0f;
    for (uint i = 0u; i < order; ++i) { result *= max(amount - float(i), 0.0f); }
    return result;
}

inline float nt_effective_reaction_rate(
    device const float* parameters,
    uint reactionIndex,
    uint component,
    float fallback
) {
    const float value = parameters[reactionIndex * NT_MOLECULAR_REACTION_PARAMETER_STRIDE + component];
    return isfinite(value) ? max(value, 0.0f) : max(fallback, 0.0f);
}

inline float nt_direction_propensity(
    device const float* species,
    uint speciesCount,
    NTMolecularReaction reaction,
    float rate,
    bool reverse
) {
    float propensity = max(rate, 0.0f);
    const uint4 participants = reverse ? reaction.products : reaction.reactants;
    const char4 stoichiometry = reverse ? reaction.productStoichiometry : reaction.reactantStoichiometry;
    for (uint slot = 0u; slot < 4u; ++slot) {
        const uint index = participants[slot];
        if (index == NT_INVALID_INDEX) { continue; }
        if (index >= speciesCount) { return 0.0f; }
        const uint order = uint(max(int(stoichiometry[slot]), 0));
        propensity *= nt_falling_factorial(species[index], order);
    }
    return isfinite(propensity) ? max(propensity, 0.0f) : 0.0f;
}

inline bool nt_can_fire_direction(
    device const float* species,
    uint speciesCount,
    NTMolecularReaction reaction,
    uint firings,
    bool reverse
) {
    const uint4 participants = reverse ? reaction.products : reaction.reactants;
    const char4 stoichiometry = reverse ? reaction.productStoichiometry : reaction.reactantStoichiometry;
    for (uint slot = 0u; slot < 4u; ++slot) {
        const uint index = participants[slot];
        if (index == NT_INVALID_INDEX) { continue; }
        if (index >= speciesCount) { return false; }
        const float required = float(max(int(stoichiometry[slot]), 0)) * float(firings);
        if (species[index] + 1.0e-6f < required) { return false; }
    }
    return true;
}

inline void nt_apply_reaction_direction(
    device float* species,
    uint speciesCount,
    NTMolecularReaction reaction,
    uint firings,
    bool reverse
) {
    const float scale = float(firings);
    const uint4 inputs = reverse ? reaction.products : reaction.reactants;
    const uint4 outputs = reverse ? reaction.reactants : reaction.products;
    const char4 inputStoichiometry = reverse ? reaction.productStoichiometry : reaction.reactantStoichiometry;
    const char4 outputStoichiometry = reverse ? reaction.reactantStoichiometry : reaction.productStoichiometry;
    for (uint slot = 0u; slot < 4u; ++slot) {
        const uint input = inputs[slot];
        if (input != NT_INVALID_INDEX && input < speciesCount) {
            species[input] = max(0.0f, species[input] - scale * float(max(int(inputStoichiometry[slot]), 0)));
        }
        const uint output = outputs[slot];
        if (output != NT_INVALID_INDEX && output < speciesCount) {
            species[output] += scale * float(max(int(outputStoichiometry[slot]), 0));
        }
    }
}

inline uint nt_poisson(float lambda, thread uint4& randomState, uint2 key) {
    if (!(lambda > 0.0f)) { return 0u; }
    if (lambda < 16.0f) {
        const float limit = exp(-lambda);
        float product = 1.0f;
        uint value = 0u;
        do {
            randomState = nt_philox(randomState, key);
            product *= nt_uniform01(randomState.x);
            value++;
        } while (product > limit && value < 128u);
        return value - 1u;
    }
    randomState = nt_philox(randomState, key);
    const float u1 = max(nt_uniform01(randomState.x), 1.0e-7f);
    const float u2 = nt_uniform01(randomState.y);
    const float normal = sqrt(-2.0f * log(u1)) * cos(2.0f * M_PI_F * u2);
    return uint(max(round(lambda + sqrt(lambda) * normal), 0.0f));
}

kernel void nt_update_molecular_domains(
    constant NTResources& r [[buffer(0)]],
    device const NTMolecularNetwork* networks [[buffer(1)]],
    device const NTMolecularReaction* reactions [[buffer(2)]],
    device const float* reactionParameters [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= r.header->microdomainCount) { return; }
    device NTMicrodomainState& domain = r.microdomains[gid];
    const uint networkIndex = domain.reactionSolverFlags & 0xFFFFu;
    const uint solverKind = (domain.reactionSolverFlags >> 16u) & 0xFFu;
    const uint networkCount = r.header->reserved3.x;
    const uint reactionCountTotal = r.header->reserved3.y;
    if (networkIndex >= networkCount) { return; }
    const NTMolecularNetwork network = networks[networkIndex];
    const uint speciesCount = min(min(domain.speciesRange.count, network.speciesCount), NT_MAX_DOMAIN_SPECIES);
    if (speciesCount == 0u || domain.speciesRange.lowerBound + speciesCount > r.header->molecularSpeciesCount) { return; }
    if (network.reactionOffset + network.reactionCount > reactionCountTotal) { return; }

    device float* species = &r.molecularSpecies[domain.speciesRange.lowerBound];
    const float dtSeconds = max(r.header->dtMilliseconds, 1.0e-6f) * 0.001f;
    const ulong transaction = nt_u64(r.header->transactionLo, r.header->transactionHi);
    const ulong domainID = nt_u64(domain.idLo, domain.idHi);
    uint4 randomState = uint4(uint(transaction), uint(transaction >> 32), uint(domainID), uint(domainID >> 32) ^ gid);
    const uint2 key = uint2(r.header->randomSeedLo, r.header->randomSeedHi);
    uint firingsTotal = 0u;

    if (solverKind == 0u) {
        float remaining = dtSeconds;
        for (uint event = 0u; event < NT_MAX_REACTION_FIRINGS_PER_QUANTUM && remaining > 0.0f; ++event) {
            float propensitySum = 0.0f;
            for (uint ri = 0u; ri < network.reactionCount; ++ri) {
                const uint globalIndex = network.reactionOffset + ri;
                const NTMolecularReaction reaction = reactions[globalIndex];
                const float forwardRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 0u, reaction.rateConstant);
                const float reverseRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 1u, reaction.reverseRateConstant);
                propensitySum += nt_direction_propensity(species, speciesCount, reaction, forwardRate, false);
                propensitySum += nt_direction_propensity(species, speciesCount, reaction, reverseRate, true);
            }
            if (!(propensitySum > 0.0f) || !isfinite(propensitySum)) { break; }
            randomState = nt_philox(randomState, key);
            const float waiting = -log(max(nt_uniform01(randomState.x), 1.0e-7f)) / propensitySum;
            if (waiting > remaining) { break; }
            remaining -= waiting;
            const float target = nt_uniform01(randomState.y) * propensitySum;
            float cumulative = 0.0f;
            bool selected = false;
            for (uint ri = 0u; ri < network.reactionCount && !selected; ++ri) {
                const uint globalIndex = network.reactionOffset + ri;
                const NTMolecularReaction reaction = reactions[globalIndex];
                const float forwardRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 0u, reaction.rateConstant);
                const float reverseRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 1u, reaction.reverseRateConstant);
                const float forward = nt_direction_propensity(species, speciesCount, reaction, forwardRate, false);
                cumulative += forward;
                if (cumulative >= target) {
                    if (nt_can_fire_direction(species, speciesCount, reaction, 1u, false)) {
                        nt_apply_reaction_direction(species, speciesCount, reaction, 1u, false);
                        firingsTotal++;
                    }
                    selected = true;
                    break;
                }
                const float reverse = nt_direction_propensity(species, speciesCount, reaction, reverseRate, true);
                cumulative += reverse;
                if (cumulative >= target) {
                    if (nt_can_fire_direction(species, speciesCount, reaction, 1u, true)) {
                        nt_apply_reaction_direction(species, speciesCount, reaction, 1u, true);
                        firingsTotal++;
                    }
                    selected = true;
                }
            }
        }
    } else if (solverKind == 1u) {
        for (uint ri = 0u; ri < network.reactionCount; ++ri) {
            const uint globalIndex = network.reactionOffset + ri;
            const NTMolecularReaction reaction = reactions[globalIndex];
            const float forwardRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 0u, reaction.rateConstant);
            const float reverseRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 1u, reaction.reverseRateConstant);
            for (uint direction = 0u; direction < 2u; ++direction) {
                const bool reverse = direction == 1u;
                const float rate = reverse ? reverseRate : forwardRate;
                const float lambda = nt_direction_propensity(species, speciesCount, reaction, rate, reverse) * dtSeconds;
                uint firings = min(nt_poisson(lambda, randomState, key), NT_MAX_REACTION_FIRINGS_PER_QUANTUM);
                while (firings > 0u && !nt_can_fire_direction(species, speciesCount, reaction, firings, reverse)) { firings >>= 1u; }
                if (firings > 0u) {
                    nt_apply_reaction_direction(species, speciesCount, reaction, firings, reverse);
                    firingsTotal += firings;
                }
            }
        }
    } else {
        float derivatives[NT_MAX_DOMAIN_SPECIES];
        for (uint i = 0u; i < speciesCount; ++i) { derivatives[i] = 0.0f; }
        for (uint ri = 0u; ri < network.reactionCount; ++ri) {
            const uint globalIndex = network.reactionOffset + ri;
            const NTMolecularReaction reaction = reactions[globalIndex];
            const float forwardRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 0u, reaction.rateConstant);
            const float reverseRate = nt_effective_reaction_rate(reactionParameters, globalIndex, 1u, reaction.reverseRateConstant);
            const float forward = nt_direction_propensity(species, speciesCount, reaction, forwardRate, false);
            const float reverse = nt_direction_propensity(species, speciesCount, reaction, reverseRate, true);
            const float netRate = forward - reverse;
            for (uint slot = 0u; slot < 4u; ++slot) {
                const uint reactant = reaction.reactants[slot];
                if (reactant != NT_INVALID_INDEX && reactant < speciesCount) {
                    derivatives[reactant] -= netRate * float(max(int(reaction.reactantStoichiometry[slot]), 0));
                }
                const uint product = reaction.products[slot];
                if (product != NT_INVALID_INDEX && product < speciesCount) {
                    derivatives[product] += netRate * float(max(int(reaction.productStoichiometry[slot]), 0));
                }
            }
        }
        for (uint i = 0u; i < speciesCount; ++i) {
            species[i] = max(species[i] + dtSeconds * derivatives[i], 0.0f);
        }
    }

    domain.volumeTemperaturePropensityReserved.z = float(firingsTotal);
    nt_atomic_add_u64(&r.counters->molecularFiringsLo, &r.counters->molecularFiringsHi, firingsTotal);
}

#endif
