import Foundation

public struct SBMLCompartment: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var size: Double
    public var spatialDimensions: Double
    public var constant: Bool

    public init(id: String, name: String? = nil, size: Double = 1, spatialDimensions: Double = 3, constant: Bool = true) {
        self.id = id
        self.name = name
        self.size = size
        self.spatialDimensions = spatialDimensions
        self.constant = constant
    }
}

public struct SBMLSpecies: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var compartment: String
    public var initialAmount: Double?
    public var initialConcentration: Double?
    public var substanceUnits: String?
    public var boundaryCondition: Bool
    public var constant: Bool
    public var hasOnlySubstanceUnits: Bool

    public init(
        id: String,
        name: String? = nil,
        compartment: String,
        initialAmount: Double? = nil,
        initialConcentration: Double? = nil,
        substanceUnits: String? = nil,
        boundaryCondition: Bool = false,
        constant: Bool = false,
        hasOnlySubstanceUnits: Bool = false
    ) {
        self.id = id
        self.name = name
        self.compartment = compartment
        self.initialAmount = initialAmount
        self.initialConcentration = initialConcentration
        self.substanceUnits = substanceUnits
        self.boundaryCondition = boundaryCondition
        self.constant = constant
        self.hasOnlySubstanceUnits = hasOnlySubstanceUnits
    }
}

public struct SBMLParameter: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var value: Double
    public var units: String?
    public var constant: Bool

    public init(id: String, name: String? = nil, value: Double, units: String? = nil, constant: Bool = true) {
        self.id = id
        self.name = name
        self.value = value
        self.units = units
        self.constant = constant
    }
}

public struct SBMLSpeciesReference: Sendable, Hashable, Codable {
    public var species: String
    public var stoichiometry: Double
    public var constant: Bool

    public init(species: String, stoichiometry: Double = 1, constant: Bool = true) {
        self.species = species
        self.stoichiometry = stoichiometry
        self.constant = constant
    }
}

public indirect enum MathExpression: Sendable, Hashable, Codable {
    case number(Double)
    case symbol(String)
    case time
    case add([MathExpression])
    case multiply([MathExpression])
    case subtract(MathExpression, MathExpression)
    case divide(MathExpression, MathExpression)
    case power(MathExpression, MathExpression)
    case root(degree: MathExpression?, value: MathExpression)
    case exp(MathExpression)
    case logarithm(base: MathExpression?, value: MathExpression)
    case absolute(MathExpression)
    case floor(MathExpression)
    case ceiling(MathExpression)
    case minimum([MathExpression])
    case maximum([MathExpression])
    case piecewise([(value: MathExpression, condition: MathExpression)], otherwise: MathExpression?)
    case less(MathExpression, MathExpression)
    case lessOrEqual(MathExpression, MathExpression)
    case greater(MathExpression, MathExpression)
    case greaterOrEqual(MathExpression, MathExpression)
    case equal(MathExpression, MathExpression)
    case notEqual(MathExpression, MathExpression)
    case and([MathExpression])
    case or([MathExpression])
    case not(MathExpression)

    public func evaluate(symbols: [String: Double], time: Double = 0) throws -> Double {
        switch self {
        case .number(let value): return value
        case .symbol(let name):
            guard let value = symbols[name] else { throw SBMLError.unknownSymbol(name) }
            return value
        case .time: return time
        case .add(let values): return try values.reduce(0) { try $0 + $1.evaluate(symbols: symbols, time: time) }
        case .multiply(let values): return try values.reduce(1) { try $0 * $1.evaluate(symbols: symbols, time: time) }
        case .subtract(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) - rhs.evaluate(symbols: symbols, time: time)
        case .divide(let lhs, let rhs):
            let divisor = try rhs.evaluate(symbols: symbols, time: time)
            guard divisor != 0 else { throw SBMLError.domainError("Division by zero") }
            return try lhs.evaluate(symbols: symbols, time: time) / divisor
        case .power(let lhs, let rhs): return Foundation.pow(try lhs.evaluate(symbols: symbols, time: time), try rhs.evaluate(symbols: symbols, time: time))
        case .root(let degree, let value):
            let d = try degree?.evaluate(symbols: symbols, time: time) ?? 2
            guard d != 0 else { throw SBMLError.domainError("Zeroth root") }
            return Foundation.pow(try value.evaluate(symbols: symbols, time: time), 1 / d)
        case .exp(let value): return Foundation.exp(try value.evaluate(symbols: symbols, time: time))
        case .logarithm(let base, let value):
            let v = try value.evaluate(symbols: symbols, time: time)
            let b = try base?.evaluate(symbols: symbols, time: time) ?? Foundation.exp(1)
            guard v > 0, b > 0, b != 1 else { throw SBMLError.domainError("Invalid logarithm") }
            return Foundation.log(v) / Foundation.log(b)
        case .absolute(let value): return abs(try value.evaluate(symbols: symbols, time: time))
        case .floor(let value): return Foundation.floor(try value.evaluate(symbols: symbols, time: time))
        case .ceiling(let value): return Foundation.ceil(try value.evaluate(symbols: symbols, time: time))
        case .minimum(let values): return try values.map { try $0.evaluate(symbols: symbols, time: time) }.min() ?? .infinity
        case .maximum(let values): return try values.map { try $0.evaluate(symbols: symbols, time: time) }.max() ?? -.infinity
        case .piecewise(let pieces, let otherwise):
            for piece in pieces where try piece.condition.evaluate(symbols: symbols, time: time) != 0 {
                return try piece.value.evaluate(symbols: symbols, time: time)
            }
            return try otherwise?.evaluate(symbols: symbols, time: time) ?? 0
        case .less(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) < rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .lessOrEqual(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) <= rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .greater(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) > rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .greaterOrEqual(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) >= rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .equal(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) == rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .notEqual(let lhs, let rhs): return try lhs.evaluate(symbols: symbols, time: time) != rhs.evaluate(symbols: symbols, time: time) ? 1 : 0
        case .and(let values): return try values.allSatisfy { try $0.evaluate(symbols: symbols, time: time) != 0 } ? 1 : 0
        case .or(let values): return try values.contains { try $0.evaluate(symbols: symbols, time: time) != 0 } ? 1 : 0
        case .not(let value): return try value.evaluate(symbols: symbols, time: time) == 0 ? 1 : 0
        }
    }
}

public struct SBMLKineticLaw: Sendable, Hashable, Codable {
    public var expression: MathExpression
    public var localParameters: [SBMLParameter]

    public init(expression: MathExpression, localParameters: [SBMLParameter] = []) {
        self.expression = expression
        self.localParameters = localParameters
    }
}

public struct SBMLReaction: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var reversible: Bool
    public var fast: Bool
    public var reactants: [SBMLSpeciesReference]
    public var products: [SBMLSpeciesReference]
    public var modifiers: [String]
    public var kineticLaw: SBMLKineticLaw?

    public init(
        id: String,
        name: String? = nil,
        reversible: Bool = true,
        fast: Bool = false,
        reactants: [SBMLSpeciesReference] = [],
        products: [SBMLSpeciesReference] = [],
        modifiers: [String] = [],
        kineticLaw: SBMLKineticLaw? = nil
    ) {
        self.id = id
        self.name = name
        self.reversible = reversible
        self.fast = fast
        self.reactants = reactants
        self.products = products
        self.modifiers = modifiers
        self.kineticLaw = kineticLaw
    }
}

public struct SBMLModel: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var level: Int
    public var version: Int
    public var compartments: [SBMLCompartment]
    public var species: [SBMLSpecies]
    public var parameters: [SBMLParameter]
    public var reactions: [SBMLReaction]

    public init(
        id: String,
        name: String? = nil,
        level: Int,
        version: Int,
        compartments: [SBMLCompartment] = [],
        species: [SBMLSpecies] = [],
        parameters: [SBMLParameter] = [],
        reactions: [SBMLReaction] = []
    ) {
        self.id = id
        self.name = name
        self.level = level
        self.version = version
        self.compartments = compartments
        self.species = species
        self.parameters = parameters
        self.reactions = reactions
    }

    public func validated() throws -> Self {
        guard !id.isEmpty else { throw SBMLError.missingAttribute(element: "model", attribute: "id") }
        let compartmentIDs = Set(compartments.map(\.id))
        guard compartmentIDs.count == compartments.count else { throw SBMLError.duplicateIdentifier("compartment") }
        let speciesIDs = Set(species.map(\.id))
        guard speciesIDs.count == species.count else { throw SBMLError.duplicateIdentifier("species") }
        let parameterIDs = Set(parameters.map(\.id))
        guard parameterIDs.count == parameters.count else { throw SBMLError.duplicateIdentifier("parameter") }
        for species in species where !compartmentIDs.contains(species.compartment) { throw SBMLError.unknownCompartment(species.compartment) }
        for reaction in reactions {
            for reference in reaction.reactants + reaction.products where !speciesIDs.contains(reference.species) {
                throw SBMLError.unknownSpecies(reference.species)
            }
        }
        return self
    }

    public func initialSymbolTable() -> [String: Double] {
        var values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.value) })
        for compartment in compartments { values[compartment.id] = compartment.size }
        let compartmentByID = Dictionary(uniqueKeysWithValues: compartments.map { ($0.id, $0) })
        for item in species {
            if let amount = item.initialAmount { values[item.id] = amount }
            else if let concentration = item.initialConcentration {
                values[item.id] = concentration * (compartmentByID[item.compartment]?.size ?? 1)
            } else { values[item.id] = 0 }
        }
        return values
    }
}

public enum SBMLError: Error, Sendable, CustomStringConvertible {
    case xml(String)
    case missingAttribute(element: String, attribute: String)
    case invalidNumber(element: String, attribute: String, value: String)
    case duplicateIdentifier(String)
    case unknownCompartment(String)
    case unknownSpecies(String)
    case unknownSymbol(String)
    case unsupportedMathML(String)
    case malformedMathML(String)
    case domainError(String)

    public var description: String {
        switch self {
        case .xml(let message): return "SBML XML error: \(message)"
        case .missingAttribute(let element, let attribute): return "SBML <\(element)> is missing \(attribute)"
        case .invalidNumber(let element, let attribute, let value): return "Invalid SBML number \(value) for \(element).\(attribute)"
        case .duplicateIdentifier(let kind): return "Duplicate SBML \(kind) identifier"
        case .unknownCompartment(let id): return "Unknown SBML compartment \(id)"
        case .unknownSpecies(let id): return "Unknown SBML species \(id)"
        case .unknownSymbol(let id): return "Unknown SBML symbol \(id)"
        case .unsupportedMathML(let element): return "Unsupported MathML element \(element)"
        case .malformedMathML(let reason): return "Malformed MathML: \(reason)"
        case .domainError(let reason): return "SBML mathematical domain error: \(reason)"
        }
    }
}
