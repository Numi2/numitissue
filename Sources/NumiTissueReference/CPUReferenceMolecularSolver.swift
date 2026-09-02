import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct CPUReferenceStoichiometryTerm: Sendable, Hashable, Codable {
    public var species: UInt16
    public var coefficient: UInt8

    public init(species: UInt16, coefficient: UInt8 = 1) {
        self.species = species
        self.coefficient = coefficient
    }
}

public struct CPUReferenceMolecularReaction: Sendable, Hashable, Codable {
    public var reactants: [CPUReferenceStoichiometryTerm]
    public var products: [CPUReferenceStoichiometryTerm]
    public var rateConstant: Double
    public var flags: UInt32

    public init(
        reactants: [CPUReferenceStoichiometryTerm],
        products: [CPUReferenceStoichiometryTerm],
        rateConstant: Double,
        flags: UInt32 = 0
    ) {
        precondition(reactants.count <= 4 && products.count <= 4)
        self.reactants = reactants
        self.products = products
        self.rateConstant = rateConstant
        self.flags = flags
    }
}

public struct CPUReferenceMolecularNetwork: Sendable, Hashable, Codable {
    public var speciesCount: Int
    public var reactions: [CPUReferenceMolecularReaction]

    public init(speciesCount: Int, reactions: [CPUReferenceMolecularReaction]) {
        precondition(speciesCount >= 0 && speciesCount <= 64)
        self.speciesCount = speciesCount
        self.reactions = reactions
    }
}

public struct CPUReferenceMolecularProgram: Sendable, Hashable, Codable {
    public var networks: [CPUReferenceMolecularNetwork]

    public init(networks: [CPUReferenceMolecularNetwork] = []) {
        self.networks = networks
    }
}

public enum CPUReferenceMolecularSolver {
    @discardableResult
    public static func step(
        state: inout TissueRuntimeState,
        program: CPUReferenceMolecularProgram,
        tickRange: Range<UInt64>,
        transaction: TransactionID,
        seed: UInt64
    ) -> Int {
        guard !program.networks.isEmpty else { return 0 }
        let dt = Double(tickRange.count) * 0.000_025
        var totalFirings = 0
        for domainIndex in state.microdomains.indices {
            var domain = state.microdomains[domainIndex]
            let networkIndex = Int(domain.reactionNetworkIndex)
            guard networkIndex >= 0 && networkIndex < program.networks.count else { continue }
            let network = program.networks[networkIndex]
            let lower = Int(domain.speciesRange.lowerBound)
            let count = min(Int(domain.speciesRange.count), network.speciesCount)
            guard lower >= 0, count > 0, lower + count <= state.molecularSpecies.count else { continue }
            var species = state.molecularSpecies[lower..<(lower + count)].map(Double.init)
            var random = DeterministicMolecularRandom(
                seed: seed ^ transaction.rawValue ^ domain.id.rawValue ^ UInt64(domainIndex)
            )
            let firings: Int
            switch domain.solverKind {
            case 0:
                firings = exactSSA(species: &species, network: network, dt: dt, random: &random)
            case 1:
                firings = tauLeap(species: &species, network: network, dt: dt, random: &random)
            default:
                firings = deterministicEuler(species: &species, network: network, dt: dt)
            }
            for index in 0..<count { state.molecularSpecies[lower + index] = Float(max(species[index], 0)) }
            domain.propensitySum = Float(firings)
            state.microdomains[domainIndex] = domain
            totalFirings += firings
        }
        return totalFirings
    }

    private static func exactSSA(
        species: inout [Double],
        network: CPUReferenceMolecularNetwork,
        dt: Double,
        random: inout DeterministicMolecularRandom
    ) -> Int {
        var remaining = dt
        var firings = 0
        while remaining > 0 && firings < 32 {
            let propensities = network.reactions.map { propensity($0, species: species) }
            let sum = propensities.reduce(0, +)
            guard sum > 0 && sum.isFinite else { break }
            let waiting = -log(max(random.uniform(), 1e-15)) / sum
            guard waiting <= remaining else { break }
            remaining -= waiting
            let target = random.uniform() * sum
            var cumulative = 0.0
            var selected = network.reactions.count - 1
            for index in propensities.indices {
                cumulative += propensities[index]
                if cumulative >= target { selected = index; break }
            }
            let reaction = network.reactions[selected]
            if canFire(reaction, species: species, times: 1) {
                apply(reaction, species: &species, times: 1)
                firings += 1
            }
        }
        return firings
    }

    private static func tauLeap(
        species: inout [Double],
        network: CPUReferenceMolecularNetwork,
        dt: Double,
        random: inout DeterministicMolecularRandom
    ) -> Int {
        var total = 0
        for reaction in network.reactions {
            let lambda = propensity(reaction, species: species) * dt
            var count = min(random.poisson(lambda: lambda), 32)
            while count > 0 && !canFire(reaction, species: species, times: count) { count /= 2 }
            if count > 0 {
                apply(reaction, species: &species, times: count)
                total += count
            }
        }
        return total
    }

    private static func deterministicEuler(
        species: inout [Double],
        network: CPUReferenceMolecularNetwork,
        dt: Double
    ) -> Int {
        var derivative = Array(repeating: 0.0, count: species.count)
        for reaction in network.reactions {
            let rate = propensity(reaction, species: species)
            for term in reaction.reactants where Int(term.species) < derivative.count {
                derivative[Int(term.species)] -= rate * Double(term.coefficient)
            }
            for term in reaction.products where Int(term.species) < derivative.count {
                derivative[Int(term.species)] += rate * Double(term.coefficient)
            }
        }
        for index in species.indices { species[index] = max(species[index] + dt * derivative[index], 0) }
        return 0
    }

    private static func propensity(_ reaction: CPUReferenceMolecularReaction, species: [Double]) -> Double {
        var value = max(reaction.rateConstant, 0)
        for term in reaction.reactants {
            let index = Int(term.species)
            guard index < species.count else { return 0 }
            value *= fallingFactorial(species[index], order: Int(term.coefficient))
        }
        return max(value, 0)
    }

    private static func fallingFactorial(_ value: Double, order: Int) -> Double {
        guard order > 0 else { return 1 }
        var result = 1.0
        for offset in 0..<order { result *= max(value - Double(offset), 0) }
        if order == 2 { result *= 0.5 }
        return result
    }

    private static func canFire(_ reaction: CPUReferenceMolecularReaction, species: [Double], times: Int) -> Bool {
        for term in reaction.reactants {
            let index = Int(term.species)
            guard index < species.count else { return false }
            if species[index] + 1e-12 < Double(term.coefficient) * Double(times) { return false }
        }
        return true
    }

    private static func apply(_ reaction: CPUReferenceMolecularReaction, species: inout [Double], times: Int) {
        let scale = Double(times)
        for term in reaction.reactants where Int(term.species) < species.count {
            let index = Int(term.species)
            species[index] = max(0, species[index] - Double(term.coefficient) * scale)
        }
        for term in reaction.products where Int(term.species) < species.count {
            species[Int(term.species)] += Double(term.coefficient) * scale
        }
    }
}

private struct DeterministicMolecularRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func poisson(lambda: Double) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda < 16 {
            let limit = exp(-lambda)
            var product = 1.0
            var count = 0
            repeat {
                product *= max(uniform(), 1e-15)
                count += 1
            } while product > limit && count < 128
            return count - 1
        }
        let u1 = max(uniform(), 1e-15)
        let u2 = uniform()
        let normal = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return max(Int((lambda + sqrt(lambda) * normal).rounded()), 0)
    }
}
