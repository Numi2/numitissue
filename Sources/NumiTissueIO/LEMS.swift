import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct LEMSDimension: Sendable, Hashable, Codable {
    public var mass: Int
    public var length: Int
    public var time: Int
    public var electricCurrent: Int
    public var temperature: Int
    public var amount: Int
    public var luminousIntensity: Int

    public init(mass: Int = 0, length: Int = 0, time: Int = 0, electricCurrent: Int = 0, temperature: Int = 0, amount: Int = 0, luminousIntensity: Int = 0) {
        self.mass = mass
        self.length = length
        self.time = time
        self.electricCurrent = electricCurrent
        self.temperature = temperature
        self.amount = amount
        self.luminousIntensity = luminousIntensity
    }

    public static let dimensionless = Self()
}

public struct LEMSUnitDefinition: Sendable, Hashable, Codable {
    public var symbol: String
    public var dimensionID: String
    public var power: Int
    public var scale: Double
    public var offset: Double

    public init(symbol: String, dimensionID: String, power: Int = 0, scale: Double = 1, offset: Double = 0) {
        self.symbol = symbol
        self.dimensionID = dimensionID
        self.power = power
        self.scale = scale
        self.offset = offset
    }

    public func toSI(_ value: Double) -> Double { (value + offset) * scale * Foundation.pow(10, Double(power)) }
    public func fromSI(_ value: Double) -> Double { value / (scale * Foundation.pow(10, Double(power))) - offset }
}

public struct LEMSQuantity: Sendable, Hashable, Codable {
    public var valueSI: Double
    public var dimensionID: String?
    public var sourceUnit: String?

    public init(valueSI: Double, dimensionID: String? = nil, sourceUnit: String? = nil) {
        self.valueSI = valueSI
        self.dimensionID = dimensionID
        self.sourceUnit = sourceUnit
    }
}

public struct LEMSParameterDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var dimensionID: String?
    public var description: String?
}

public struct LEMSConstantDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var dimensionID: String?
    public var value: String
}

public struct LEMSStateVariableDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var dimensionID: String?
    public var exposure: String?
}

public struct LEMSDerivedVariableDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var dimensionID: String?
    public var exposure: String?
    public var expression: PortableExpressionIR
    public var reduce: String?
    public var select: String?
}

public struct LEMSTimeDerivativeDefinition: Sendable, Hashable, Codable {
    public var variable: String
    public var expression: PortableExpressionIR
}

public struct LEMSStateAssignmentDefinition: Sendable, Hashable, Codable {
    public var variable: String
    public var expression: PortableExpressionIR
}

public struct LEMSEventOutDefinition: Sendable, Hashable, Codable {
    public var port: String
}

public struct LEMSTransitionDefinition: Sendable, Hashable, Codable {
    public var targetRegime: String
}

public struct LEMSOnConditionDefinition: Sendable, Hashable, Codable {
    public var test: PortableExpressionIR
    public var assignments: [LEMSStateAssignmentDefinition]
    public var events: [LEMSEventOutDefinition]
    public var transition: LEMSTransitionDefinition?
}

public struct LEMSOnEventDefinition: Sendable, Hashable, Codable {
    public var port: String
    public var assignments: [LEMSStateAssignmentDefinition]
    public var events: [LEMSEventOutDefinition]
    public var transition: LEMSTransitionDefinition?
}

public struct LEMSOnStartDefinition: Sendable, Hashable, Codable {
    public var assignments: [LEMSStateAssignmentDefinition]
}

public struct LEMSRegimeDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var initial: Bool
    public var derivatives: [LEMSTimeDerivativeDefinition]
    public var onConditions: [LEMSOnConditionDefinition]
    public var onEvents: [LEMSOnEventDefinition]
    public var onEntry: [LEMSStateAssignmentDefinition]
}

public struct LEMSDynamicsDefinition: Sendable, Hashable, Codable {
    public var stateVariables: [LEMSStateVariableDefinition]
    public var derivedVariables: [LEMSDerivedVariableDefinition]
    public var derivatives: [LEMSTimeDerivativeDefinition]
    public var onStart: LEMSOnStartDefinition?
    public var onConditions: [LEMSOnConditionDefinition]
    public var onEvents: [LEMSOnEventDefinition]
    public var regimes: [LEMSRegimeDefinition]

    public init(
        stateVariables: [LEMSStateVariableDefinition] = [],
        derivedVariables: [LEMSDerivedVariableDefinition] = [],
        derivatives: [LEMSTimeDerivativeDefinition] = [],
        onStart: LEMSOnStartDefinition? = nil,
        onConditions: [LEMSOnConditionDefinition] = [],
        onEvents: [LEMSOnEventDefinition] = [],
        regimes: [LEMSRegimeDefinition] = []
    ) {
        self.stateVariables = stateVariables
        self.derivedVariables = derivedVariables
        self.derivatives = derivatives
        self.onStart = onStart
        self.onConditions = onConditions
        self.onEvents = onEvents
        self.regimes = regimes
    }
}

public struct LEMSComponentTypeDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var extends: String?
    public var description: String?
    public var parameters: [LEMSParameterDefinition]
    public var constants: [LEMSConstantDefinition]
    public var exposures: [String: String?]
    public var requirements: [String: String?]
    public var eventPorts: [String: String]
    public var dynamics: LEMSDynamicsDefinition?

    public init(
        name: String,
        extends: String? = nil,
        description: String? = nil,
        parameters: [LEMSParameterDefinition] = [],
        constants: [LEMSConstantDefinition] = [],
        exposures: [String: String?] = [:],
        requirements: [String: String?] = [:],
        eventPorts: [String: String] = [:],
        dynamics: LEMSDynamicsDefinition? = nil
    ) {
        self.name = name
        self.extends = extends
        self.description = description
        self.parameters = parameters
        self.constants = constants
        self.exposures = exposures
        self.requirements = requirements
        self.eventPorts = eventPorts
        self.dynamics = dynamics
    }
}

public struct LEMSComponentInstance: Sendable, Hashable, Codable {
    public var id: String
    public var type: String
    public var parameters: [String: String]
    public var children: [LEMSComponentInstance]

    public init(id: String, type: String, parameters: [String: String] = [:], children: [LEMSComponentInstance] = []) {
        self.id = id
        self.type = type
        self.parameters = parameters
        self.children = children
    }
}

public struct LEMSDocument: Sendable, Hashable, Codable {
    public var includes: [String]
    public var dimensions: [String: LEMSDimension]
    public var units: [LEMSUnitDefinition]
    public var componentTypes: [LEMSComponentTypeDefinition]
    public var components: [LEMSComponentInstance]

    public init(includes: [String] = [], dimensions: [String: LEMSDimension] = [:], units: [LEMSUnitDefinition] = [], componentTypes: [LEMSComponentTypeDefinition] = [], components: [LEMSComponentInstance] = []) {
        self.includes = includes
        self.dimensions = dimensions
        self.units = units
        self.componentTypes = componentTypes
        self.components = components
    }

    public func validated() throws -> Self {
        guard Set(componentTypes.map(\.name)).count == componentTypes.count else { throw LEMSError.duplicateComponentType }
        guard Set(units.map(\.symbol)).count == units.count else { throw LEMSError.duplicateUnit }
        let typeNames = Set(componentTypes.map(\.name))
        for type in componentTypes {
            if let parent = type.extends, !typeNames.contains(parent) { throw LEMSError.unknownComponentType(parent) }
            if let dynamics = type.dynamics {
                let stateNames = Set(dynamics.stateVariables.map(\.name))
                for derivative in dynamics.derivatives where !stateNames.contains(derivative.variable) { throw LEMSError.unknownStateVariable(derivative.variable) }
                for regime in dynamics.regimes {
                    for derivative in regime.derivatives where !stateNames.contains(derivative.variable) { throw LEMSError.unknownStateVariable(derivative.variable) }
                }
            }
        }
        return self
    }

    public func unitMapWithBuiltins() -> [String: LEMSUnitDefinition] {
        var values = Dictionary(uniqueKeysWithValues: Self.builtinUnits.map { ($0.symbol, $0) })
        for unit in units { values[unit.symbol] = unit }
        return values
    }

    public func parseQuantity(_ text: String, expectedDimension: String? = nil) throws -> LEMSQuantity {
        try LEMSQuantityParser.parse(text, units: unitMapWithBuiltins(), expectedDimension: expectedDimension)
    }

    public static let builtinUnits: [LEMSUnitDefinition] = [
        .init(symbol: "s", dimensionID: "time"),
        .init(symbol: "ms", dimensionID: "time", power: -3),
        .init(symbol: "us", dimensionID: "time", power: -6),
        .init(symbol: "ns", dimensionID: "time", power: -9),
        .init(symbol: "V", dimensionID: "voltage"),
        .init(symbol: "mV", dimensionID: "voltage", power: -3),
        .init(symbol: "uV", dimensionID: "voltage", power: -6),
        .init(symbol: "A", dimensionID: "current"),
        .init(symbol: "mA", dimensionID: "current", power: -3),
        .init(symbol: "uA", dimensionID: "current", power: -6),
        .init(symbol: "nA", dimensionID: "current", power: -9),
        .init(symbol: "pA", dimensionID: "current", power: -12),
        .init(symbol: "S", dimensionID: "conductance"),
        .init(symbol: "mS", dimensionID: "conductance", power: -3),
        .init(symbol: "uS", dimensionID: "conductance", power: -6),
        .init(symbol: "nS", dimensionID: "conductance", power: -9),
        .init(symbol: "F", dimensionID: "capacitance"),
        .init(symbol: "uF", dimensionID: "capacitance", power: -6),
        .init(symbol: "nF", dimensionID: "capacitance", power: -9),
        .init(symbol: "pF", dimensionID: "capacitance", power: -12),
        .init(symbol: "m", dimensionID: "length"),
        .init(symbol: "cm", dimensionID: "length", power: -2),
        .init(symbol: "mm", dimensionID: "length", power: -3),
        .init(symbol: "um", dimensionID: "length", power: -6),
        .init(symbol: "nm", dimensionID: "length", power: -9),
        .init(symbol: "K", dimensionID: "temperature"),
        .init(symbol: "degC", dimensionID: "temperature", offset: 273.15),
        .init(symbol: "mol", dimensionID: "amount"),
        .init(symbol: "mM", dimensionID: "concentration", power: 0, scale: 1),
        .init(symbol: "uM", dimensionID: "concentration", power: -3, scale: 1),
        .init(symbol: "nM", dimensionID: "concentration", power: -6, scale: 1),
        .init(symbol: "per_s", dimensionID: "per_time"),
        .init(symbol: "per_ms", dimensionID: "per_time", power: 3)
    ]
}

public enum LEMSQuantityParser {
    public static func parse(_ source: String, units: [String: LEMSUnitDefinition], expectedDimension: String? = nil) throws -> LEMSQuantity {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LEMSError.invalidQuantity(source) }
        var split = trimmed.startIndex
        while split < trimmed.endIndex {
            let c = trimmed[split]
            if c.isNumber || c == "." || c == "+" || c == "-" || c == "e" || c == "E" { split = trimmed.index(after: split) }
            else { break }
        }
        let numberText = String(trimmed[..<split]).trimmingCharacters(in: .whitespaces)
        let unitText = String(trimmed[split...]).trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberText), value.isFinite else { throw LEMSError.invalidQuantity(source) }
        if unitText.isEmpty {
            return LEMSQuantity(valueSI: value, dimensionID: expectedDimension, sourceUnit: nil)
        }
        guard let unit = units[unitText] else { throw LEMSError.unknownUnit(unitText) }
        if let expectedDimension, unit.dimensionID != expectedDimension { throw LEMSError.dimensionMismatch(expected: expectedDimension, actual: unit.dimensionID) }
        return LEMSQuantity(valueSI: unit.toSI(value), dimensionID: unit.dimensionID, sourceUnit: unit.symbol)
    }
}

public enum LEMSError: Error, Sendable, CustomStringConvertible {
    case xml(String)
    case missingAttribute(element: String, attribute: String)
    case invalidNumber(element: String, attribute: String, value: String)
    case invalidExpression(String)
    case invalidQuantity(String)
    case unknownUnit(String)
    case dimensionMismatch(expected: String, actual: String)
    case duplicateComponentType
    case duplicateUnit
    case unknownComponentType(String)
    case unknownStateVariable(String)
    case malformedDynamics(String)

    public var description: String {
        switch self {
        case .xml(let value): return "LEMS XML error: \(value)"
        case .missingAttribute(let element, let attribute): return "LEMS <\(element)> is missing \(attribute)"
        case .invalidNumber(let element, let attribute, let value): return "Invalid LEMS \(element).\(attribute) value \(value)"
        case .invalidExpression(let value): return "Invalid LEMS expression: \(value)"
        case .invalidQuantity(let value): return "Invalid LEMS quantity: \(value)"
        case .unknownUnit(let value): return "Unknown LEMS unit \(value)"
        case .dimensionMismatch(let expected, let actual): return "Expected dimension \(expected), received \(actual)"
        case .duplicateComponentType: return "Duplicate LEMS component type"
        case .duplicateUnit: return "Duplicate LEMS unit symbol"
        case .unknownComponentType(let value): return "Unknown LEMS component type \(value)"
        case .unknownStateVariable(let value): return "Unknown LEMS state variable \(value)"
        case .malformedDynamics(let value): return "Malformed LEMS dynamics: \(value)"
        }
    }
}
