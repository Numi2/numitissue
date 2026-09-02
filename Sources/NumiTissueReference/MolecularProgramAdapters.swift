import Foundation
import NumiTissueIO

public struct CompiledReferenceMolecularProgram: Sendable {
    public var program: CPUReferenceMolecularProgram
    public var initialSpecies: [Float]
    public var speciesIndex: [String: UInt16]

    public init(program: CPUReferenceMolecularProgram, initialSpecies: [Float], speciesIndex: [String: UInt16]) {
        self.program = program
        self.initialSpecies = initialSpecies
        self.speciesIndex = speciesIndex
    }
}

public enum ReferenceMolecularProgramCompiler {
    /// Lowers a portable molecular program into the bounded reaction layout used by the reference
    /// and Metal stochastic solvers. Arbitrary expression rate laws remain available in the IR, but
    /// are rejected here because stochastic execution requires an explicit propensity law.
    public static func compile(_ source: MolecularProgramIR) throws -> CompiledReferenceMolecularProgram {
        let source = try source.validated()
        guard source.species.count <= 64 else {
            throw ReferenceMolecularCompileError.speciesCapacity(source.species.count)
        }
        let speciesIndex = source.speciesIndex
        var reactions: [CPUReferenceMolecularReaction] = []
        reactions.reserveCapacity(source.reactions.count * 2)

        for reaction in source.reactions {
            guard reaction.rateLaw == .massAction else {
                throw ReferenceMolecularCompileError.expressionRateLaw(reaction.id)
            }
            reactions.append(try lower(
                id: reaction.id,
                reactants: reaction.reactants,
                products: reaction.products,
                rate: reaction.rateConstant,
                flags: reaction.flags,
                speciesIndex: speciesIndex
            ))
            if reaction.reversible && reaction.reverseRateConstant > 0 {
                reactions.append(try lower(
                    id: "\(reaction.id).reverse",
                    reactants: reaction.products,
                    products: reaction.reactants,
                    rate: reaction.reverseRateConstant,
                    flags: reaction.flags | (1 << 1),
                    speciesIndex: speciesIndex
                ))
            }
        }

        let network = CPUReferenceMolecularNetwork(speciesCount: source.species.count, reactions: reactions)
        return CompiledReferenceMolecularProgram(
            program: CPUReferenceMolecularProgram(networks: [network]),
            initialSpecies: source.species.map { Float($0.initialAmount) },
            speciesIndex: speciesIndex
        )
    }

    private static func lower(
        id: String,
        reactants: [MolecularStoichiometryIR],
        products: [MolecularStoichiometryIR],
        rate: Double,
        flags: UInt32,
        speciesIndex: [String: UInt16]
    ) throws -> CPUReferenceMolecularReaction {
        guard rate.isFinite, rate >= 0 else { throw ReferenceMolecularCompileError.invalidRate(id) }
        guard reactants.count <= 4, products.count <= 4 else { throw ReferenceMolecularCompileError.reactionArity(id) }
        let loweredReactants = try reactants.map { term -> CPUReferenceStoichiometryTerm in
            guard let index = speciesIndex[term.speciesID] else { throw ReferenceMolecularCompileError.unknownSpecies(term.speciesID) }
            return CPUReferenceStoichiometryTerm(species: index, coefficient: term.stoichiometry)
        }
        let loweredProducts = try products.map { term -> CPUReferenceStoichiometryTerm in
            guard let index = speciesIndex[term.speciesID] else { throw ReferenceMolecularCompileError.unknownSpecies(term.speciesID) }
            return CPUReferenceStoichiometryTerm(species: index, coefficient: term.stoichiometry)
        }
        return CPUReferenceMolecularReaction(
            reactants: loweredReactants,
            products: loweredProducts,
            rateConstant: rate,
            flags: flags
        )
    }
}

public enum ReferenceMolecularCompileError: Error, Sendable, CustomStringConvertible {
    case speciesCapacity(Int)
    case expressionRateLaw(String)
    case reactionArity(String)
    case invalidRate(String)
    case unknownSpecies(String)

    public var description: String {
        switch self {
        case .speciesCapacity(let count): return "Molecular network contains \(count) species; the bounded microdomain ABI supports 64"
        case .expressionRateLaw(let reaction): return "Reaction \(reaction) requires an expression propensity and cannot use the bounded stochastic kernel"
        case .reactionArity(let reaction): return "Reaction \(reaction) exceeds four reactants or four products"
        case .invalidRate(let reaction): return "Reaction \(reaction) has an invalid rate"
        case .unknownSpecies(let species): return "Molecular reaction references unknown species \(species)"
        }
    }
}
