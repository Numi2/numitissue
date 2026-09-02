import Foundation

/// Simulator-neutral molecular program produced by SBML and native model importers.
/// The executable backends translate this immutable representation into their packed ABI.
public struct MolecularProgramIR: Sendable, Hashable, Codable {
    public var species: [MolecularSpeciesIR]
    public var compartments: [MolecularCompartmentIR]
    public var parameters: [String: Double]
    public var reactions: [MolecularReactionIR]
    public var observables: [MolecularObservableIR]
    public var sourceMetadata: [String: String]

    public init(
        species: [MolecularSpeciesIR] = [],
        compartments: [MolecularCompartmentIR] = [],
        parameters: [String: Double] = [:],
        reactions: [MolecularReactionIR] = [],
        observables: [MolecularObservableIR] = [],
        sourceMetadata: [String: String] = [:]
    ) {
        self.species = species
        self.compartments = compartments
        self.parameters = parameters
        self.reactions = reactions
        self.observables = observables
        self.sourceMetadata = sourceMetadata
    }

    public func validated() throws -> Self {
        let compartmentIDs = Set(compartments.map(\.id))
        guard compartmentIDs.count == compartments.count else { throw MolecularIRError.duplicateIdentifier("compartment") }
        let speciesIDs = Set(species.map(\.id))
        guard speciesIDs.count == species.count else { throw MolecularIRError.duplicateIdentifier("species") }
        let reactionIDs = Set(reactions.map(\.id))
        guard reactionIDs.count == reactions.count else { throw MolecularIRError.duplicateIdentifier("reaction") }

        for item in species {
            guard compartmentIDs.contains(item.compartmentID) else { throw MolecularIRError.unknownCompartment(item.compartmentID) }
            guard item.initialAmount.isFinite, item.initialAmount >= 0 else { throw MolecularIRError.invalidInitialAmount(species: item.id) }
        }
        for reaction in reactions {
            guard reaction.rateConstant.isFinite, reaction.rateConstant >= 0 else { throw MolecularIRError.invalidRate(reaction: reaction.id) }
            guard reaction.reactants.count <= 4, reaction.products.count <= 4 else { throw MolecularIRError.reactionArity(reaction.id) }
            for term in reaction.reactants + reaction.products {
                guard speciesIDs.contains(term.speciesID) else { throw MolecularIRError.unknownSpecies(term.speciesID) }
                guard term.stoichiometry > 0 else { throw MolecularIRError.invalidStoichiometry(reaction: reaction.id, species: term.speciesID) }
            }
        }
        return self
    }

    public var speciesIndex: [String: UInt16] {
        Dictionary(uniqueKeysWithValues: species.enumerated().map { ($0.element.id, UInt16(clamping: $0.offset)) })
    }
}

public struct MolecularCompartmentIR: Sendable, Hashable, Codable {
    public var id: String
    public var volumeLiters: Double
    public var spatialDimensions: Double

    public init(id: String, volumeLiters: Double, spatialDimensions: Double = 3) {
        self.id = id
        self.volumeLiters = volumeLiters
        self.spatialDimensions = spatialDimensions
    }
}

public struct MolecularSpeciesIR: Sendable, Hashable, Codable {
    public var id: String
    public var compartmentID: String
    public var initialAmount: Double
    public var boundaryCondition: Bool
    public var constant: Bool
    public var units: String?

    public init(
        id: String,
        compartmentID: String,
        initialAmount: Double,
        boundaryCondition: Bool = false,
        constant: Bool = false,
        units: String? = nil
    ) {
        self.id = id
        self.compartmentID = compartmentID
        self.initialAmount = initialAmount
        self.boundaryCondition = boundaryCondition
        self.constant = constant
        self.units = units
    }
}

public struct MolecularStoichiometryIR: Sendable, Hashable, Codable {
    public var speciesID: String
    public var stoichiometry: UInt8

    public init(speciesID: String, stoichiometry: UInt8 = 1) {
        self.speciesID = speciesID
        self.stoichiometry = stoichiometry
    }
}

public enum MolecularRateLawIR: Sendable, Hashable, Codable {
    case massAction
    case expression(PortableExpressionIR)
}

public struct MolecularReactionIR: Sendable, Hashable, Codable {
    public var id: String
    public var reactants: [MolecularStoichiometryIR]
    public var products: [MolecularStoichiometryIR]
    public var modifiers: [String]
    public var rateConstant: Double
    public var reverseRateConstant: Double
    public var reversible: Bool
    public var rateLaw: MolecularRateLawIR
    public var flags: UInt32

    public init(
        id: String,
        reactants: [MolecularStoichiometryIR],
        products: [MolecularStoichiometryIR],
        modifiers: [String] = [],
        rateConstant: Double,
        reverseRateConstant: Double = 0,
        reversible: Bool = false,
        rateLaw: MolecularRateLawIR = .massAction,
        flags: UInt32 = 0
    ) {
        self.id = id
        self.reactants = reactants
        self.products = products
        self.modifiers = modifiers
        self.rateConstant = rateConstant
        self.reverseRateConstant = reverseRateConstant
        self.reversible = reversible
        self.rateLaw = rateLaw
        self.flags = flags
    }
}

public struct MolecularObservableIR: Sendable, Hashable, Codable {
    public var id: String
    public var expression: PortableExpressionIR

    public init(id: String, expression: PortableExpressionIR) {
        self.id = id
        self.expression = expression
    }
}

/// Codable expression form shared by SBML, LEMS and restricted NMODL imports.
public indirect enum PortableExpressionIR: Sendable, Hashable, Codable {
    case constant(Double)
    case symbol(String)
    case time
    case add([PortableExpressionIR])
    case multiply([PortableExpressionIR])
    case subtract(PortableExpressionIR, PortableExpressionIR)
    case divide(PortableExpressionIR, PortableExpressionIR)
    case power(PortableExpressionIR, PortableExpressionIR)
    case exponential(PortableExpressionIR)
    case logarithm(PortableExpressionIR)
    case absolute(PortableExpressionIR)
    case minimum([PortableExpressionIR])
    case maximum([PortableExpressionIR])
    case conditional(condition: PortableExpressionIR, then: PortableExpressionIR, otherwise: PortableExpressionIR)
    case less(PortableExpressionIR, PortableExpressionIR)
    case lessOrEqual(PortableExpressionIR, PortableExpressionIR)
    case greater(PortableExpressionIR, PortableExpressionIR)
    case greaterOrEqual(PortableExpressionIR, PortableExpressionIR)
    case equal(PortableExpressionIR, PortableExpressionIR)
    case logicalAnd([PortableExpressionIR])
    case logicalOr([PortableExpressionIR])
    case logicalNot(PortableExpressionIR)

    public func evaluate(symbols: [String: Double], time: Double = 0) throws -> Double {
        switch self {
        case .constant(let value): return value
        case .symbol(let name):
            guard let value = symbols[name] else { throw MolecularIRError.unknownSymbol(name) }
            return value
        case .time: return time
        case .add(let values): return try values.reduce(0) { try $0 + $1.evaluate(symbols: symbols, time: time) }
        case .multiply(let values): return try values.reduce(1) { try $0 * $1.evaluate(symbols: symbols, time: time) }
        case .subtract(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) - rhs.evaluate(symbols: symbols, time: time)
        case .divide(let lhs, let rhs):
            let denominator = try rhs.evaluate(symbols: symbols, time: time)
            guard denominator != 0 else { throw MolecularIRError.expressionDomain("division by zero") }
            return try lhs.evaluate(symbols: symbols, time: time) / denominator
        case .power(let lhs, let rhs): return Foundation.pow(try lhs.evaluate(symbols: symbols, time: time), try rhs.evaluate(symbols: symbols, time: time))
        case .exponential(let value): return Foundation.exp(try value.evaluate(symbols: symbols, time: time))
        case .logarithm(let value):
            let evaluated = try value.evaluate(symbols: symbols, time: time)
            guard evaluated > 0 else { throw MolecularIRError.expressionDomain("logarithm of nonpositive value") }
            return Foundation.log(evaluated)
        case .absolute(let value): return abs(try value.evaluate(symbols: symbols, time: time))
        case .minimum(let values): return try values.map { try $0.evaluate(symbols: symbols, time: time) }.min() ?? .infinity
        case .maximum(let values): return try values.map { try $0.evaluate(symbols: symbols, time: time) }.max() ?? -.infinity
        case .conditional(let condition, let thenValue, let otherwiseValue):
            return try condition.evaluate(symbols: symbols, time: time) != 0
                ? thenValue.evaluate(symbols: symbols, time: time)
                : otherwiseValue.evaluate(symbols: symbols, time: time)
        case .less(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) < rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .lessOrEqual(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) <= rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .greater(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) > rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .greaterOrEqual(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) >= rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .equal(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) == rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .logicalAnd(let values):
            for value in values where try value.evaluate(symbols: symbols, time: time) == 0 { return 0 }
            return 1
        case .logicalOr(let values):
            for value in values where try value.evaluate(symbols: symbols, time: time) != 0 { return 1 }
            return 0
        case .logicalNot(let value): return try value.evaluate(symbols: symbols, time: time) == 0 ? 1 : 0
        }
    }
}

public enum MolecularIRError: Error, Sendable, CustomStringConvertible {
    case duplicateIdentifier(String)
    case unknownCompartment(String)
    case unknownSpecies(String)
    case unknownSymbol(String)
    case invalidInitialAmount(species: String)
    case invalidRate(reaction: String)
    case invalidStoichiometry(reaction: String, species: String)
    case reactionArity(String)
    case unsupportedRateLaw(String)
    case expressionDomain(String)

    public var description: String {
        switch self {
        case .duplicateIdentifier(let kind): return "Duplicate molecular \(kind) identifier"
        case .unknownCompartment(let id): return "Unknown molecular compartment \(id)"
        case .unknownSpecies(let id): return "Unknown molecular species \(id)"
        case .unknownSymbol(let id): return "Unknown expression symbol \(id)"
        case .invalidInitialAmount(let species): return "Invalid initial amount for species \(species)"
        case .invalidRate(let reaction): return "Invalid rate constant for reaction \(reaction)"
        case .invalidStoichiometry(let reaction, let species): return "Invalid stoichiometry for \(species) in reaction \(reaction)"
        case .reactionArity(let reaction): return "Reaction \(reaction) exceeds the four-reactant/product GPU ABI"
        case .unsupportedRateLaw(let reaction): return "Reaction \(reaction) has a rate law that cannot be compiled for the selected backend"
        case .expressionDomain(let reason): return "Expression domain error: \(reason)"
        }
    }
}
