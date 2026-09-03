#include <metal_stdlib>
using namespace metal;

struct NTMolecularReaction {
    uint reactant0;
    uint reactant1;
    uint reactant2;
    uint reactant3;
    uint product0;
    uint product1;
    uint product2;
    uint product3;
    uint reactantStoichiometry;
    uint productStoichiometry;
    uint reactantCount;
    uint productCount;
    uint flags;
    uint reserved;
    float rateConstant;
    float reservedFloat;
};

struct NTMolecularNetwork {
    uint reactionOffset;
    uint reactionCount;
    uint speciesCount;
    uint flags;
    float deterministicThreshold;
    float tauEpsilon;
    float maximumTau;
    float reserved;
};

struct NTMolecularDomain {
    uint networkIndex;
    uint speciesOffset;
    uint solverKind;
    uint flags;
    float volumeLiters;
    float temperatureKelvin;
    float timeSeconds;
    float reserved;
};

struct NTMolecularParameters {
    uint4 values;
    float4 timing;
};

struct NTMolecularStatus {
    uint faultCode;
    uint solverUsed;
    uint reactionFirings;
    uint rejectedLeaps;
    float advancedTimeSeconds;
    float minimumSpecies;
    float totalPropensity;
    float reserved;
};

enum NTMolecularFault : uint {
    NTMolecularFaultNone = 0,
    NTMolecularFaultNetwork = 1,
    NTMolecularFaultSpecies = 2,
    NTMolecularFaultReaction = 3,
    NTMolecularFaultNegativeSpecies = 4,
    NTMolecularFaultNonFinite = 5,
    NTMolecularFaultFiringBudget = 6,
    NTMolecularFaultTauFailure = 7
};

inline ulong nt_splitmix64(ulong value) {
    value += 0x9E3779B97F4A7C15ul;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ul;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBul;
    return value ^ (value >> 31);
}

inline float nt_uniform(thread ulong &counter) {
    counter = nt_splitmix64(counter);
    const ulong mantissa = counter >> 40;
    return max(float(mantissa) * (1.0f / 16777216.0f), 5.960464477539063e-8f);
}

inline float nt_gaussian(thread ulong &counter) {
    const float u1 = nt_uniform(counter);
    const float u2 = nt_uniform(counter);
    return sqrt(-2.0f * log(u1)) * cos(6.283185307179586f * u2);
}

inline uint nt_species_at(const thread NTMolecularReaction &reaction, bool product, uint index) {
    if (product) {
        switch (index) {
            case 0u: return reaction.product0;
            case 1u: return reaction.product1;
            case 2u: return reaction.product2;
            default: return reaction.product3;
        }
    }
    switch (index) {
        case 0u: return reaction.reactant0;
        case 1u: return reaction.reactant1;
        case 2u: return reaction.reactant2;
        default: return reaction.reactant3;
    }
}

inline uint nt_coefficient(uint packed, uint index) {
    return (packed >> (index * 8u)) & 0xffu;
}

inline float nt_falling_factorial(float amount, uint order) {
    if (order == 0u) { return 1.0f; }
    if (amount < float(order)) { return 0.0f; }
    float value = 1.0f;
    for (uint i = 0u; i < order; ++i) { value *= max(amount - float(i), 0.0f); }
    float factorial = 1.0f;
    for (uint i = 2u; i <= order; ++i) { factorial *= float(i); }
    return value / factorial;
}

inline float nt_stochastic_propensity(
    const NTMolecularReaction reaction,
    const thread float *species,
    uint speciesCount,
    float volumeLiters,
    uint domainFlags,
    thread uint &fault
) {
    float propensity = reaction.rateConstant;
    uint totalOrder = 0u;
    for (uint term = 0u; term < reaction.reactantCount; ++term) {
        const uint index = nt_species_at(reaction, false, term);
        const uint coefficient = nt_coefficient(reaction.reactantStoichiometry, term);
        if (index >= speciesCount || coefficient == 0u) { fault = NTMolecularFaultReaction; return 0.0f; }
        propensity *= nt_falling_factorial(species[index], coefficient);
        totalOrder += coefficient;
    }
    // Flag bit 0 identifies macroscopic concentration rate constants. Convert them into molecule-count
    // propensities using the reaction volume; otherwise the imported law is already amount based.
    if ((domainFlags & 1u) != 0u && totalOrder > 1u) {
        const float entitiesPerMolar = 6.02214076e23f * max(volumeLiters, 1.0e-24f);
        propensity /= pow(entitiesPerMolar, float(totalOrder - 1u));
    }
    if (!isfinite(propensity) || propensity < 0.0f) { fault = NTMolecularFaultNonFinite; return 0.0f; }
    return propensity;
}

inline float nt_deterministic_rate(
    const thread NTMolecularReaction &reaction,
    const thread float *species,
    uint speciesCount,
    thread uint &fault
) {
    float rate = reaction.rateConstant;
    for (uint term = 0u; term < reaction.reactantCount; ++term) {
        const uint index = nt_species_at(reaction, false, term);
        const uint coefficient = nt_coefficient(reaction.reactantStoichiometry, term);
        if (index >= speciesCount || coefficient == 0u) { fault = NTMolecularFaultReaction; return 0.0f; }
        rate *= pow(max(species[index], 0.0f), float(coefficient));
    }
    if (!isfinite(rate) || rate < 0.0f) { fault = NTMolecularFaultNonFinite; return 0.0f; }
    return rate;
}

inline void nt_apply_firing(
    const NTMolecularReaction reaction,
    thread float *species,
    uint speciesCount,
    float firingCount,
    thread uint &fault
) {
    for (uint term = 0u; term < reaction.reactantCount; ++term) {
        const uint index = nt_species_at(reaction, false, term);
        const uint coefficient = nt_coefficient(reaction.reactantStoichiometry, term);
        if (index >= speciesCount) { fault = NTMolecularFaultReaction; return; }
        species[index] -= firingCount * float(coefficient);
        if (species[index] < -1.0e-4f) { fault = NTMolecularFaultNegativeSpecies; return; }
        species[index] = max(species[index], 0.0f);
    }
    for (uint term = 0u; term < reaction.productCount; ++term) {
        const uint index = nt_species_at(reaction, true, term);
        const uint coefficient = nt_coefficient(reaction.productStoichiometry, term);
        if (index >= speciesCount) { fault = NTMolecularFaultReaction; return; }
        species[index] += firingCount * float(coefficient);
    }
}

inline uint nt_poisson(float lambda, thread ulong &counter) {
    if (lambda <= 0.0f) { return 0u; }
    if (lambda < 24.0f) {
        const float limit = exp(-lambda);
        float product = 1.0f;
        uint count = 0u;
        do { ++count; product *= nt_uniform(counter); } while (product > limit && count < 4096u);
        return count - 1u;
    }
    const float sample = lambda + sqrt(lambda) * nt_gaussian(counter) + 0.5f;
    return uint(max(sample, 0.0f));
}

inline void nt_derivative(
    const thread float *species,
    thread float *derivative,
    const device NTMolecularReaction *reactions,
    const thread NTMolecularNetwork &network,
    thread uint &fault
) {
    for (uint speciesIndex = 0u; speciesIndex < network.speciesCount; ++speciesIndex) { derivative[speciesIndex] = 0.0f; }
    for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
        const NTMolecularReaction reaction = reactions[network.reactionOffset + localReaction];
        const float rate = nt_deterministic_rate(reaction, species, network.speciesCount, fault);
        if (fault != NTMolecularFaultNone) { return; }
        for (uint term = 0u; term < reaction.reactantCount; ++term) {
            const uint index = nt_species_at(reaction, false, term);
            derivative[index] -= rate * float(nt_coefficient(reaction.reactantStoichiometry, term));
        }
        for (uint term = 0u; term < reaction.productCount; ++term) {
            const uint index = nt_species_at(reaction, true, term);
            derivative[index] += rate * float(nt_coefficient(reaction.productStoichiometry, term));
        }
    }
}

inline uint nt_deterministic_rk2(
    thread float *species,
    const device NTMolecularReaction *reactions,
    const thread NTMolecularNetwork &network,
    float dt,
    thread float &totalPropensity
) {
    float k1[64];
    float midpoint[64];
    float k2[64];
    uint fault = NTMolecularFaultNone;
    nt_derivative(species, k1, reactions, network, fault);
    if (fault != NTMolecularFaultNone) { return fault; }
    for (uint i = 0u; i < network.speciesCount; ++i) { midpoint[i] = max(species[i] + 0.5f * dt * k1[i], 0.0f); }
    nt_derivative(midpoint, k2, reactions, network, fault);
    if (fault != NTMolecularFaultNone) { return fault; }
    totalPropensity = 0.0f;
    for (uint i = 0u; i < network.speciesCount; ++i) {
        species[i] += dt * k2[i];
        if (!isfinite(species[i])) { return NTMolecularFaultNonFinite; }
        if (species[i] < -1.0e-4f) { return NTMolecularFaultNegativeSpecies; }
        species[i] = max(species[i], 0.0f);
    }
    return NTMolecularFaultNone;
}

inline uint nt_exact_ssa(
    thread float *species,
    const device NTMolecularReaction *reactions,
    const thread NTMolecularNetwork &network,
    float volumeLiters,
    uint domainFlags,
    float dt,
    uint maximumFirings,
    thread ulong &counter,
    thread uint &firings,
    thread float &totalPropensity,
    thread float &advanced
) {
    uint fault = NTMolecularFaultNone;
    float elapsed = 0.0f;
    while (elapsed < dt) {
        totalPropensity = 0.0f;
        for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
            totalPropensity += nt_stochastic_propensity(reactions[network.reactionOffset + localReaction], species, network.speciesCount, volumeLiters, domainFlags, fault);
            if (fault != NTMolecularFaultNone) { return fault; }
        }
        if (totalPropensity <= 0.0f) { elapsed = dt; break; }
        const float waiting = -log(nt_uniform(counter)) / totalPropensity;
        if (elapsed + waiting > dt) { elapsed = dt; break; }
        const float threshold = nt_uniform(counter) * totalPropensity;
        float cumulative = 0.0f;
        uint selected = network.reactionCount;
        for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
            cumulative += nt_stochastic_propensity(reactions[network.reactionOffset + localReaction], species, network.speciesCount, volumeLiters, domainFlags, fault);
            if (threshold <= cumulative) { selected = localReaction; break; }
        }
        if (fault != NTMolecularFaultNone || selected >= network.reactionCount) { return fault == NTMolecularFaultNone ? NTMolecularFaultReaction : fault; }
        nt_apply_firing(reactions[network.reactionOffset + selected], species, network.speciesCount, 1.0f, fault);
        if (fault != NTMolecularFaultNone) { return fault; }
        elapsed += waiting;
        ++firings;
        if (firings >= maximumFirings) { advanced = elapsed; return NTMolecularFaultFiringBudget; }
    }
    advanced = elapsed;
    return NTMolecularFaultNone;
}

inline uint nt_tau_leap(
    thread float *species,
    const device NTMolecularReaction *reactions,
    const thread NTMolecularNetwork &network,
    float volumeLiters,
    uint domainFlags,
    float dt,
    float minimumTau,
    float maximumTau,
    uint maximumFirings,
    thread ulong &counter,
    thread uint &firings,
    thread uint &rejected,
    thread float &totalPropensity,
    thread float &advanced
) {
    uint fault = NTMolecularFaultNone;
    float elapsed = 0.0f;
    float propensities[128];
    float trial[64];
    while (elapsed < dt) {
        totalPropensity = 0.0f;
        float tau = min(min(network.maximumTau, maximumTau), dt - elapsed);
        for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
            propensities[localReaction] = nt_stochastic_propensity(reactions[network.reactionOffset + localReaction], species, network.speciesCount, volumeLiters, domainFlags, fault);
            totalPropensity += propensities[localReaction];
            if (fault != NTMolecularFaultNone) { return fault; }
        }
        if (totalPropensity <= 0.0f) { elapsed = dt; break; }

        float minimumPositive = INFINITY;
        for (uint i = 0u; i < network.speciesCount; ++i) { if (species[i] > 0.0f) { minimumPositive = min(minimumPositive, species[i]); } }
        if (isfinite(minimumPositive)) {
            tau = min(tau, max(minimumTau, network.tauEpsilon * minimumPositive / max(totalPropensity, 1.0e-20f)));
        }
        bool accepted = false;
        for (uint attempt = 0u; attempt < 10u && !accepted; ++attempt) {
            for (uint i = 0u; i < network.speciesCount; ++i) { trial[i] = species[i]; }
            uint leapFirings = 0u;
            ulong trialCounter = counter;
            uint trialFault = NTMolecularFaultNone;
            for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
                const uint count = nt_poisson(propensities[localReaction] * tau, trialCounter);
                leapFirings += count;
                if (count > 0u) {
                    nt_apply_firing(reactions[network.reactionOffset + localReaction], trial, network.speciesCount, float(count), trialFault);
                    if (trialFault != NTMolecularFaultNone) { break; }
                }
            }
            if (trialFault == NTMolecularFaultNone) {
                for (uint i = 0u; i < network.speciesCount; ++i) { species[i] = trial[i]; }
                counter = trialCounter;
                firings += leapFirings;
                accepted = true;
            } else {
                tau *= 0.5f;
                ++rejected;
                if (tau < minimumTau) { return NTMolecularFaultTauFailure; }
            }
        }
        if (!accepted) { return NTMolecularFaultTauFailure; }
        elapsed += tau;
        if (firings >= maximumFirings) { advanced = elapsed; return NTMolecularFaultFiringBudget; }
    }
    advanced = elapsed;
    return NTMolecularFaultNone;
}

kernel void nt_molecular_execute(
    const device NTMolecularNetwork *networks [[buffer(0)]],
    const device NTMolecularReaction *reactions [[buffer(1)]],
    device NTMolecularDomain *domains [[buffer(2)]],
    device float *globalSpecies [[buffer(3)]],
    device NTMolecularStatus *statuses [[buffer(4)]],
    constant NTMolecularParameters &parameters [[buffer(5)]],
    uint domainIndex [[thread_position_in_grid]]
) {
    if (domainIndex >= parameters.values.x) { return; }
    NTMolecularDomain domain = domains[domainIndex];
    const NTMolecularNetwork network = networks[domain.networkIndex];
    if (network.speciesCount == 0u || network.speciesCount > 64u || network.reactionCount > 128u) {
        statuses[domainIndex].faultCode = NTMolecularFaultNetwork;
        return;
    }
    thread float species[64];
    float minimumSpecies = INFINITY;
    for (uint i = 0u; i < network.speciesCount; ++i) {
        species[i] = globalSpecies[domain.speciesOffset + i];
        if (!isfinite(species[i]) || species[i] < 0.0f) { statuses[domainIndex].faultCode = NTMolecularFaultSpecies; return; }
        minimumSpecies = min(minimumSpecies, species[i]);
    }

    uint solver = domain.solverKind;
    float totalPropensity = 0.0f;
    uint probeFault = NTMolecularFaultNone;
    if (solver == 3u) {
        for (uint localReaction = 0u; localReaction < network.reactionCount; ++localReaction) {
            totalPropensity += nt_stochastic_propensity(reactions[network.reactionOffset + localReaction], species, network.speciesCount, domain.volumeLiters, domain.flags, probeFault);
        }
        if (probeFault != NTMolecularFaultNone) { statuses[domainIndex].faultCode = probeFault; return; }
        if (minimumSpecies >= network.deterministicThreshold) { solver = 0u; }
        else if (totalPropensity * parameters.timing.x < 16.0f) { solver = 1u; }
        else { solver = 2u; }
    }

    const ulong seed = (ulong(parameters.values.w) << 32) | ulong(parameters.values.z);
    ulong counter = seed ^ (ulong(domainIndex) * 0xD2B74407B1CE6E93ul) ^ as_type<uint>(domain.timeSeconds);
    uint firings = 0u;
    uint rejected = 0u;
    float advanced = 0.0f;
    uint fault = NTMolecularFaultNone;
    if (solver == 0u) {
        fault = nt_deterministic_rk2(species, reactions, network, parameters.timing.x, totalPropensity);
        advanced = fault == NTMolecularFaultNone ? parameters.timing.x : 0.0f;
    } else if (solver == 1u) {
        fault = nt_exact_ssa(species, reactions, network, domain.volumeLiters, domain.flags, parameters.timing.x, parameters.values.y, counter, firings, totalPropensity, advanced);
    } else {
        fault = nt_tau_leap(species, reactions, network, domain.volumeLiters, domain.flags, parameters.timing.x, parameters.timing.y, parameters.timing.z, parameters.values.y, counter, firings, rejected, totalPropensity, advanced);
    }

    minimumSpecies = INFINITY;
    for (uint i = 0u; i < network.speciesCount; ++i) {
        if (!isfinite(species[i]) || species[i] < -1.0e-4f) { fault = NTMolecularFaultNonFinite; break; }
        species[i] = max(species[i], 0.0f);
        globalSpecies[domain.speciesOffset + i] = species[i];
        minimumSpecies = min(minimumSpecies, species[i]);
    }
    domain.timeSeconds += advanced;
    domains[domainIndex] = domain;
    statuses[domainIndex].faultCode = fault;
    statuses[domainIndex].solverUsed = solver;
    statuses[domainIndex].reactionFirings = firings;
    statuses[domainIndex].rejectedLeaps = rejected;
    statuses[domainIndex].advancedTimeSeconds = advanced;
    statuses[domainIndex].minimumSpecies = minimumSpecies;
    statuses[domainIndex].totalPropensity = totalPropensity;
    statuses[domainIndex].reserved = 0.0f;
}
