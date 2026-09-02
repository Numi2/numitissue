import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SBMLCompartmentDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var size: Double
    public var spatialDimensions: Double
    public var units: String?
    public var constant: Bool

    public init(id: String, name: String? = nil, size: Double = 1, spatialDimensions: Double = 3, units: String? = nil, constant: Bool = true) {
        self.id = id
        self.name = name
        self.size = size
        self.spatialDimensions = spatialDimensions
        self.units = units
        self.constant = constant
    }
}

public struct SBMLSpeciesDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var compartmentID: String
    public var initialAmount: Double?
    public var initialConcentration: Double?
    public var substanceUnits: String?
    public var boundaryCondition: Bool
    public var constant: Bool
    public var hasOnlySubstanceUnits: Bool

    public init(
        id: String,
        name: String? = nil,
        compartmentID: String,
        initialAmount: Double? = nil,
        initialConcentration: Double? = nil,
        substanceUnits: String? = nil,
        boundaryCondition: Bool = false,
        constant: Bool = false,
        hasOnlySubstanceUnits: Bool = false
    ) {
        self.id = id
        self.name = name
        self.compartmentID = compartmentID
        self.initialAmount = initialAmount
        self.initialConcentration = initialConcentration
        self.substanceUnits = substanceUnits
        self.boundaryCondition = boundaryCondition
        self.constant = constant
        self.hasOnlySubstanceUnits = hasOnlySubstanceUnits
    }
}

public struct SBMLParameterDefinition: Sendable, Hashable, Codable {
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

public struct SBMLSpeciesReferenceDefinition: Sendable, Hashable, Codable {
    public var speciesID: String
    public var stoichiometry: Double
    public var constant: Bool

    public init(speciesID: String, stoichiometry: Double = 1, constant: Bool = true) {
        self.speciesID = speciesID
        self.stoichiometry = stoichiometry
        self.constant = constant
    }
}

public struct SBMLKineticLawDefinition: Sendable, Hashable, Codable {
    public var expression: PortableExpressionIR
    public var localParameters: [SBMLParameterDefinition]

    public init(expression: PortableExpressionIR, localParameters: [SBMLParameterDefinition] = []) {
        self.expression = expression
        self.localParameters = localParameters
    }
}

public struct SBMLReactionDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var reversible: Bool
    public var fast: Bool
    public var reactants: [SBMLSpeciesReferenceDefinition]
    public var products: [SBMLSpeciesReferenceDefinition]
    public var modifiers: [String]
    public var kineticLaw: SBMLKineticLawDefinition?

    public init(
        id: String,
        name: String? = nil,
        reversible: Bool = true,
        fast: Bool = false,
        reactants: [SBMLSpeciesReferenceDefinition] = [],
        products: [SBMLSpeciesReferenceDefinition] = [],
        modifiers: [String] = [],
        kineticLaw: SBMLKineticLawDefinition? = nil
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

public struct SBMLInitialAssignmentDefinition: Sendable, Hashable, Codable {
    public var symbol: String
    public var expression: PortableExpressionIR

    public init(symbol: String, expression: PortableExpressionIR) {
        self.symbol = symbol
        self.expression = expression
    }
}

public struct SBMLAssignmentRuleDefinition: Sendable, Hashable, Codable {
    public var variable: String
    public var expression: PortableExpressionIR

    public init(variable: String, expression: PortableExpressionIR) {
        self.variable = variable
        self.expression = expression
    }
}

public struct SBMLDocumentModel: Sendable, Hashable, Codable {
    public var id: String
    public var name: String?
    public var level: Int
    public var version: Int
    public var compartments: [SBMLCompartmentDefinition]
    public var species: [SBMLSpeciesDefinition]
    public var parameters: [SBMLParameterDefinition]
    public var reactions: [SBMLReactionDefinition]
    public var initialAssignments: [SBMLInitialAssignmentDefinition]
    public var assignmentRules: [SBMLAssignmentRuleDefinition]

    public init(
        id: String,
        name: String? = nil,
        level: Int = 3,
        version: Int = 2,
        compartments: [SBMLCompartmentDefinition] = [],
        species: [SBMLSpeciesDefinition] = [],
        parameters: [SBMLParameterDefinition] = [],
        reactions: [SBMLReactionDefinition] = [],
        initialAssignments: [SBMLInitialAssignmentDefinition] = [],
        assignmentRules: [SBMLAssignmentRuleDefinition] = []
    ) {
        self.id = id
        self.name = name
        self.level = level
        self.version = version
        self.compartments = compartments
        self.species = species
        self.parameters = parameters
        self.reactions = reactions
        self.initialAssignments = initialAssignments
        self.assignmentRules = assignmentRules
    }

    public func validated() throws -> Self {
        guard !id.isEmpty else { throw SBMLImportError.missingAttribute(element: "model", attribute: "id") }
        try requireUnique(compartments.map(\.id), kind: "compartment")
        try requireUnique(species.map(\.id), kind: "species")
        try requireUnique(parameters.map(\.id), kind: "parameter")
        try requireUnique(reactions.map(\.id), kind: "reaction")
        let compartmentIDs = Set(compartments.map(\.id))
        let speciesIDs = Set(species.map(\.id))
        let parameterIDs = Set(parameters.map(\.id))
        let knownSymbols = speciesIDs.union(parameterIDs).union(compartmentIDs)

        for compartment in compartments {
            guard compartment.size.isFinite, compartment.size > 0 else { throw SBMLImportError.invalidValue("Compartment \(compartment.id) must have positive finite size") }
        }
        for item in species {
            guard compartmentIDs.contains(item.compartmentID) else { throw SBMLImportError.unknownCompartment(item.compartmentID) }
            if let amount = item.initialAmount, (!amount.isFinite || amount < 0) { throw SBMLImportError.invalidValue("Species \(item.id) has invalid initialAmount") }
            if let concentration = item.initialConcentration, (!concentration.isFinite || concentration < 0) { throw SBMLImportError.invalidValue("Species \(item.id) has invalid initialConcentration") }
        }
        for parameter in parameters where !parameter.value.isFinite { throw SBMLImportError.invalidValue("Parameter \(parameter.id) is non-finite") }
        for reaction in reactions {
            for reference in reaction.reactants + reaction.products where !speciesIDs.contains(reference.speciesID) {
                throw SBMLImportError.unknownSpecies(reference.speciesID)
            }
            for modifier in reaction.modifiers where !speciesIDs.contains(modifier) { throw SBMLImportError.unknownSpecies(modifier) }
        }
        for assignment in initialAssignments where !knownSymbols.contains(assignment.symbol) { throw SBMLImportError.unknownSymbol(assignment.symbol) }
        for rule in assignmentRules where !knownSymbols.contains(rule.variable) { throw SBMLImportError.unknownSymbol(rule.variable) }
        return self
    }

    public func initialSymbolTable() throws -> [String: Double] {
        let validated = try self.validated()
        var symbols = Dictionary(uniqueKeysWithValues: validated.parameters.map { ($0.id, $0.value) })
        for compartment in validated.compartments { symbols[compartment.id] = compartment.size }
        let compartmentsByID = Dictionary(uniqueKeysWithValues: validated.compartments.map { ($0.id, $0) })
        for item in validated.species {
            if let amount = item.initialAmount { symbols[item.id] = amount }
            else if let concentration = item.initialConcentration { symbols[item.id] = concentration * (compartmentsByID[item.compartmentID]?.size ?? 1) }
            else { symbols[item.id] = 0 }
        }
        for assignment in validated.initialAssignments {
            symbols[assignment.symbol] = try assignment.expression.evaluate(symbols: symbols)
        }
        return symbols
    }

    private func requireUnique(_ values: [String], kind: String) throws {
        guard Set(values).count == values.count else { throw SBMLImportError.duplicateIdentifier(kind) }
    }
}

public enum SBMLToMolecularIRCompiler {
    public static func compile(_ document: SBMLDocumentModel) throws -> MolecularProgramIR {
        let document = try document.validated()
        let initial = try document.initialSymbolTable()
        let compartments = document.compartments.map {
            MolecularCompartmentIR(id: $0.id, volumeLiters: $0.size, spatialDimensions: $0.spatialDimensions)
        }
        let species = document.species.map {
            MolecularSpeciesIR(
                id: $0.id,
                compartmentID: $0.compartmentID,
                initialAmount: initial[$0.id] ?? 0,
                boundaryCondition: $0.boundaryCondition,
                constant: $0.constant,
                units: $0.substanceUnits
            )
        }
        let parameters = Dictionary(uniqueKeysWithValues: document.parameters.map { ($0.id, $0.value) })
        let reactions = try document.reactions.map { reaction -> MolecularReactionIR in
            let reactants = try reaction.reactants.map { try stoichiometry($0, reactionID: reaction.id) }
            let products = try reaction.products.map { try stoichiometry($0, reactionID: reaction.id) }
            let law = reaction.kineticLaw?.expression ?? .constant(0)
            let massAction = identifyMassAction(
                expression: law,
                reaction: reaction,
                parameters: parameters.merging(
                    Dictionary(uniqueKeysWithValues: (reaction.kineticLaw?.localParameters ?? []).map { ($0.id, $0.value) }),
                    uniquingKeysWith: { _, local in local }
                )
            )
            return MolecularReactionIR(
                id: reaction.id,
                reactants: reactants,
                products: products,
                modifiers: reaction.modifiers,
                rateConstant: massAction?.forward ?? 0,
                reverseRateConstant: massAction?.reverse ?? 0,
                reversible: reaction.reversible,
                rateLaw: massAction == nil ? .expression(law) : .massAction,
                flags: reaction.fast ? 1 : 0
            )
        }
        return try MolecularProgramIR(
            species: species,
            compartments: compartments,
            parameters: parameters,
            reactions: reactions,
            observables: document.assignmentRules.map { MolecularObservableIR(id: $0.variable, expression: $0.expression) },
            sourceMetadata: ["format": "SBML", "level": String(document.level), "version": String(document.version), "model": document.id]
        ).validated()
    }

    private static func stoichiometry(_ reference: SBMLSpeciesReferenceDefinition, reactionID: String) throws -> MolecularStoichiometryIR {
        guard reference.stoichiometry.isFinite,
              reference.stoichiometry > 0,
              reference.stoichiometry.rounded() == reference.stoichiometry,
              reference.stoichiometry <= Double(UInt8.max) else {
            throw SBMLImportError.unsupportedFeature("Reaction \(reactionID) has nonintegral or excessive stoichiometry")
        }
        return MolecularStoichiometryIR(speciesID: reference.speciesID, stoichiometry: UInt8(reference.stoichiometry))
    }

    /// Recognizes k*Π(reactant^stoichiometry), optionally represented as subtraction of two such terms.
    private static func identifyMassAction(
        expression: PortableExpressionIR,
        reaction: SBMLReactionDefinition,
        parameters: [String: Double]
    ) -> (forward: Double, reverse: Double)? {
        if case .subtract(let forwardExpression, let reverseExpression) = expression,
           let forward = rateConstant(from: forwardExpression, expectedSpecies: reaction.reactants, parameters: parameters),
           let reverse = rateConstant(from: reverseExpression, expectedSpecies: reaction.products, parameters: parameters) {
            return (forward, reverse)
        }
        if let forward = rateConstant(from: expression, expectedSpecies: reaction.reactants, parameters: parameters) {
            return (forward, 0)
        }
        return nil
    }

    private static func rateConstant(
        from expression: PortableExpressionIR,
        expectedSpecies: [SBMLSpeciesReferenceDefinition],
        parameters: [String: Double]
    ) -> Double? {
        var factors: [PortableExpressionIR]
        if case .multiply(let values) = expression { factors = values } else { factors = [expression] }
        var remaining = Dictionary(uniqueKeysWithValues: expectedSpecies.map { ($0.speciesID, Int($0.stoichiometry.rounded())) })
        var coefficient = 1.0
        for factor in factors {
            switch factor {
            case .constant(let value): coefficient *= value
            case .symbol(let name):
                if let count = remaining[name], count > 0 { remaining[name] = count - 1 }
                else if let value = parameters[name] { coefficient *= value }
                else { return nil }
            case .power(.symbol(let name), .constant(let exponent)):
                guard exponent.rounded() == exponent, let count = remaining[name], count == Int(exponent) else { return nil }
                remaining[name] = 0
            default: return nil
            }
        }
        return remaining.values.allSatisfy { $0 == 0 } && coefficient.isFinite && coefficient >= 0 ? coefficient : nil
    }
}

public enum SBMLImportError: Error, Sendable, CustomStringConvertible {
    case xml(String)
    case missingAttribute(element: String, attribute: String)
    case invalidNumber(element: String, attribute: String, value: String)
    case invalidValue(String)
    case duplicateIdentifier(String)
    case unknownCompartment(String)
    case unknownSpecies(String)
    case unknownSymbol(String)
    case malformedMathML(String)
    case unsupportedMathML(String)
    case unsupportedFeature(String)

    public var description: String {
        switch self {
        case .xml(let message): return "SBML XML error: \(message)"
        case .missingAttribute(let element, let attribute): return "SBML <\(element)> is missing \(attribute)"
        case .invalidNumber(let element, let attribute, let value): return "Invalid number \(value) for SBML \(element).\(attribute)"
        case .invalidValue(let message): return "Invalid SBML value: \(message)"
        case .duplicateIdentifier(let kind): return "Duplicate SBML \(kind) identifier"
        case .unknownCompartment(let id): return "Unknown SBML compartment \(id)"
        case .unknownSpecies(let id): return "Unknown SBML species \(id)"
        case .unknownSymbol(let id): return "Unknown SBML symbol \(id)"
        case .malformedMathML(let message): return "Malformed MathML: \(message)"
        case .unsupportedMathML(let element): return "Unsupported MathML element \(element)"
        case .unsupportedFeature(let message): return "Unsupported SBML feature: \(message)"
        }
    }
}
