import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum SBMLXMLImporter {
    public static func load(url: URL) throws -> SBMLDocumentModel {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> SBMLDocumentModel {
        let delegate = SBMLDocumentParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            throw delegate.failure ?? SBMLImportError.xml(parser.parserError?.localizedDescription ?? "Unknown XML parser failure")
        }
        if let failure = delegate.failure { throw failure }
        guard let document = delegate.document else { throw SBMLImportError.xml("No SBML model was found") }
        return try document.validated()
    }
}

private final class SBMLDocumentParserDelegate: NSObject, XMLParserDelegate {
    var document: SBMLDocumentModel?
    var failure: SBMLImportError?

    private var level = 3
    private var version = 2
    private var modelID: String?
    private var modelName: String?
    private var compartments: [SBMLCompartmentDefinition] = []
    private var species: [SBMLSpeciesDefinition] = []
    private var parameters: [SBMLParameterDefinition] = []
    private var reactions: [SBMLReactionDefinition] = []
    private var initialAssignments: [SBMLInitialAssignmentDefinition] = []
    private var assignmentRules: [SBMLAssignmentRuleDefinition] = []

    private enum SpeciesListContext { case none, reactants, products }
    private var speciesListContext: SpeciesListContext = .none
    private var reaction: SBMLReactionDefinition?
    private var kineticLocalParameters: [SBMLParameterDefinition] = []
    private var inKineticLaw = false
    private var initialAssignmentSymbol: String?
    private var assignmentRuleVariable: String?

    private enum MathTarget { case kineticLaw, initialAssignment, assignmentRule }
    private var mathTarget: MathTarget?
    private var mathRoot: MutableMathMLNode?
    private var mathStack: [MutableMathMLNode] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        let element = localName(elementName)

        if mathRoot != nil || element == "math" {
            beginMathElement(name: element, attributes: attributeDict)
            return
        }

        do {
            switch element {
            case "sbml":
                level = try integer(attributeDict["level"], element: element, attribute: "level", default: 3)
                version = try integer(attributeDict["version"], element: element, attribute: "version", default: 2)
            case "model":
                modelID = try required(attributeDict["id"], element: element, attribute: "id")
                modelName = attributeDict["name"]
            case "compartment":
                compartments.append(SBMLCompartmentDefinition(
                    id: try required(attributeDict["id"], element: element, attribute: "id"),
                    name: attributeDict["name"],
                    size: try number(attributeDict["size"], element: element, attribute: "size", default: 1),
                    spatialDimensions: try number(attributeDict["spatialDimensions"], element: element, attribute: "spatialDimensions", default: 3),
                    units: attributeDict["units"],
                    constant: boolean(attributeDict["constant"], default: true)
                ))
            case "species":
                species.append(SBMLSpeciesDefinition(
                    id: try required(attributeDict["id"], element: element, attribute: "id"),
                    name: attributeDict["name"],
                    compartmentID: try required(attributeDict["compartment"], element: element, attribute: "compartment"),
                    initialAmount: try optionalNumber(attributeDict["initialAmount"], element: element, attribute: "initialAmount"),
                    initialConcentration: try optionalNumber(attributeDict["initialConcentration"], element: element, attribute: "initialConcentration"),
                    substanceUnits: attributeDict["substanceUnits"],
                    boundaryCondition: boolean(attributeDict["boundaryCondition"], default: false),
                    constant: boolean(attributeDict["constant"], default: false),
                    hasOnlySubstanceUnits: boolean(attributeDict["hasOnlySubstanceUnits"], default: false)
                ))
            case "parameter":
                let value = SBMLParameterDefinition(
                    id: try required(attributeDict["id"], element: element, attribute: "id"),
                    name: attributeDict["name"],
                    value: try number(attributeDict["value"], element: element, attribute: "value", default: 0),
                    units: attributeDict["units"],
                    constant: boolean(attributeDict["constant"], default: true)
                )
                if inKineticLaw { kineticLocalParameters.append(value) } else { parameters.append(value) }
            case "localparameter":
                kineticLocalParameters.append(SBMLParameterDefinition(
                    id: try required(attributeDict["id"], element: element, attribute: "id"),
                    name: attributeDict["name"],
                    value: try number(attributeDict["value"], element: element, attribute: "value", default: 0),
                    units: attributeDict["units"],
                    constant: true
                ))
            case "reaction":
                reaction = SBMLReactionDefinition(
                    id: try required(attributeDict["id"], element: element, attribute: "id"),
                    name: attributeDict["name"],
                    reversible: boolean(attributeDict["reversible"], default: true),
                    fast: boolean(attributeDict["fast"], default: false)
                )
                kineticLocalParameters.removeAll(keepingCapacity: true)
            case "listofreactants": speciesListContext = .reactants
            case "listofproducts": speciesListContext = .products
            case "speciesreference":
                let reference = SBMLSpeciesReferenceDefinition(
                    speciesID: try required(attributeDict["species"], element: element, attribute: "species"),
                    stoichiometry: try number(attributeDict["stoichiometry"], element: element, attribute: "stoichiometry", default: 1),
                    constant: boolean(attributeDict["constant"], default: true)
                )
                switch speciesListContext {
                case .reactants: reaction?.reactants.append(reference)
                case .products: reaction?.products.append(reference)
                case .none: break
                }
            case "modifierspeciesreference":
                if let id = attributeDict["species"] { reaction?.modifiers.append(id) }
            case "kineticlaw":
                inKineticLaw = true
                kineticLocalParameters.removeAll(keepingCapacity: true)
                mathTarget = .kineticLaw
            case "initialassignment":
                initialAssignmentSymbol = try required(attributeDict["symbol"], element: element, attribute: "symbol")
                mathTarget = .initialAssignment
            case "assignmentrule":
                assignmentRuleVariable = try required(attributeDict["variable"], element: element, attribute: "variable")
                mathTarget = .assignmentRule
            default: break
            }
        } catch let error as SBMLImportError {
            failure = error
            parser.abortParsing()
        } catch {
            failure = .xml(String(describing: error))
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        let element = localName(elementName)

        if mathRoot != nil {
            endMathElement(name: element, parser: parser)
            return
        }

        switch element {
        case "listofreactants", "listofproducts": speciesListContext = .none
        case "kineticlaw":
            inKineticLaw = false
            mathTarget = nil
        case "reaction":
            if let reaction { reactions.append(reaction) }
            reaction = nil
            kineticLocalParameters.removeAll(keepingCapacity: true)
        case "initialassignment":
            initialAssignmentSymbol = nil
            mathTarget = nil
        case "assignmentrule":
            assignmentRuleVariable = nil
            mathTarget = nil
        case "model":
            guard let modelID else {
                failure = .missingAttribute(element: "model", attribute: "id")
                parser.abortParsing()
                return
            }
            document = SBMLDocumentModel(
                id: modelID,
                name: modelName,
                level: level,
                version: version,
                compartments: compartments,
                species: species,
                parameters: parameters,
                reactions: reactions,
                initialAssignments: initialAssignments,
                assignmentRules: assignmentRules
            )
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let node = mathStack.last { node.text.append(string) }
    }

    private func beginMathElement(name: String, attributes: [String: String]) {
        let node = MutableMathMLNode(name: name, attributes: attributes)
        if let parent = mathStack.last { parent.children.append(node) }
        else { mathRoot = node }
        mathStack.append(node)
    }

    private func endMathElement(name: String, parser: XMLParser) {
        guard let current = mathStack.last, current.name == name else {
            failure = .malformedMathML("Mismatched closing element \(name)")
            parser.abortParsing()
            return
        }
        mathStack.removeLast()
        guard name == "math" else { return }
        guard let root = mathRoot else {
            failure = .malformedMathML("Missing MathML root")
            parser.abortParsing()
            return
        }
        do {
            let expression = try MathMLPortableExpressionParser.parse(root)
            switch mathTarget {
            case .kineticLaw:
                reaction?.kineticLaw = SBMLKineticLawDefinition(expression: expression, localParameters: kineticLocalParameters)
            case .initialAssignment:
                guard let symbol = initialAssignmentSymbol else { throw SBMLImportError.malformedMathML("Initial assignment has no symbol") }
                initialAssignments.append(SBMLInitialAssignmentDefinition(symbol: symbol, expression: expression))
            case .assignmentRule:
                guard let variable = assignmentRuleVariable else { throw SBMLImportError.malformedMathML("Assignment rule has no variable") }
                assignmentRules.append(SBMLAssignmentRuleDefinition(variable: variable, expression: expression))
            case .none:
                throw SBMLImportError.malformedMathML("Math element has no SBML target")
            }
        } catch let error as SBMLImportError {
            failure = error
            parser.abortParsing()
        } catch {
            failure = .malformedMathML(String(describing: error))
            parser.abortParsing()
        }
        mathRoot = nil
        mathStack.removeAll(keepingCapacity: true)
    }

    private func localName(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }

    private func required(_ value: String?, element: String, attribute: String) throws -> String {
        guard let value, !value.isEmpty else { throw SBMLImportError.missingAttribute(element: element, attribute: attribute) }
        return value
    }

    private func number(_ value: String?, element: String, attribute: String, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let result = Double(value), result.isFinite else { throw SBMLImportError.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }

    private func optionalNumber(_ value: String?, element: String, attribute: String) throws -> Double? {
        guard let value else { return nil }
        guard let result = Double(value), result.isFinite else { throw SBMLImportError.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }

    private func integer(_ value: String?, element: String, attribute: String, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let result = Int(value) else { throw SBMLImportError.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }

    private func boolean(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        switch value.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return fallback
        }
    }
}

private final class MutableMathMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [MutableMathMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
}

private enum MathMLPortableExpressionParser {
    static func parse(_ root: MutableMathMLNode) throws -> PortableExpressionIR {
        guard root.name == "math" else { throw SBMLImportError.malformedMathML("Expected <math>, found <\(root.name)>") }
        guard root.children.count == 1, let child = root.children.first else { throw SBMLImportError.malformedMathML("<math> must contain one expression") }
        return try expression(child)
    }

    private static func expression(_ node: MutableMathMLNode) throws -> PortableExpressionIR {
        switch node.name {
        case "cn":
            let value = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Double(value) else { throw SBMLImportError.malformedMathML("Invalid numeric literal \(value)") }
            return .constant(number)
        case "ci":
            let symbol = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !symbol.isEmpty else { throw SBMLImportError.malformedMathML("Empty <ci>") }
            return .symbol(symbol)
        case "csymbol":
            let definition = node.attributes["definitionURL"] ?? node.attributes["definitionurl"] ?? ""
            let symbol = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if definition.lowercased().contains("time") || symbol.lowercased() == "time" { return .time }
            guard !symbol.isEmpty else { throw SBMLImportError.malformedMathML("Empty <csymbol>") }
            return .symbol(symbol)
        case "apply": return try application(node)
        case "piecewise": return try piecewise(node)
        case "true": return .constant(1)
        case "false": return .constant(0)
        default: throw SBMLImportError.unsupportedMathML(node.name)
        }
    }

    private static func application(_ node: MutableMathMLNode) throws -> PortableExpressionIR {
        guard let operatorNode = node.children.first else { throw SBMLImportError.malformedMathML("Empty <apply>") }
        let arguments = try node.children.dropFirst().map(expression)
        switch operatorNode.name {
        case "plus": return .add(arguments)
        case "times": return .multiply(arguments)
        case "minus":
            guard arguments.count == 1 || arguments.count == 2 else { throw arity("minus", expected: "one or two", actual: arguments.count) }
            return arguments.count == 1 ? .subtract(.constant(0), arguments[0]) : .subtract(arguments[0], arguments[1])
        case "divide":
            guard arguments.count == 2 else { throw arity("divide", expected: "two", actual: arguments.count) }
            return .divide(arguments[0], arguments[1])
        case "power":
            guard arguments.count == 2 else { throw arity("power", expected: "two", actual: arguments.count) }
            return .power(arguments[0], arguments[1])
        case "root":
            guard arguments.count == 1 || arguments.count == 2 else { throw arity("root", expected: "one or two", actual: arguments.count) }
            return arguments.count == 1 ? .power(arguments[0], .constant(0.5)) : .power(arguments[1], .divide(.constant(1), arguments[0]))
        case "exp": return try unary(arguments, name: "exp", transform: PortableExpressionIR.exponential)
        case "ln": return try unary(arguments, name: "ln", transform: PortableExpressionIR.logarithm)
        case "log": return try unary(arguments, name: "log", transform: PortableExpressionIR.logarithm)
        case "abs": return try unary(arguments, name: "abs", transform: PortableExpressionIR.absolute)
        case "min": return .minimum(arguments)
        case "max": return .maximum(arguments)
        case "lt": return try binary(arguments, name: "lt", transform: PortableExpressionIR.less)
        case "leq": return try binary(arguments, name: "leq", transform: PortableExpressionIR.lessOrEqual)
        case "gt": return try binary(arguments, name: "gt", transform: PortableExpressionIR.greater)
        case "geq": return try binary(arguments, name: "geq", transform: PortableExpressionIR.greaterOrEqual)
        case "eq": return try binary(arguments, name: "eq", transform: PortableExpressionIR.equal)
        case "neq":
            let equal = try binary(arguments, name: "neq", transform: PortableExpressionIR.equal)
            return .logicalNot(equal)
        case "and": return .logicalAnd(arguments)
        case "or": return .logicalOr(arguments)
        case "not": return try unary(arguments, name: "not", transform: PortableExpressionIR.logicalNot)
        default: throw SBMLImportError.unsupportedMathML(operatorNode.name)
        }
    }

    private static func piecewise(_ node: MutableMathMLNode) throws -> PortableExpressionIR {
        var otherwise: PortableExpressionIR = .constant(0)
        var pieces: [(PortableExpressionIR, PortableExpressionIR)] = []
        for child in node.children {
            switch child.name {
            case "piece":
                guard child.children.count == 2 else { throw SBMLImportError.malformedMathML("<piece> needs value and condition") }
                pieces.append((try expression(child.children[0]), try expression(child.children[1])))
            case "otherwise":
                guard child.children.count == 1 else { throw SBMLImportError.malformedMathML("<otherwise> needs one value") }
                otherwise = try expression(child.children[0])
            default: throw SBMLImportError.unsupportedMathML(child.name)
            }
        }
        for piece in pieces.reversed() { otherwise = .conditional(condition: piece.1, then: piece.0, otherwise: otherwise) }
        return otherwise
    }

    private static func unary(
        _ arguments: [PortableExpressionIR],
        name: String,
        transform: (PortableExpressionIR) -> PortableExpressionIR
    ) throws -> PortableExpressionIR {
        guard arguments.count == 1 else { throw arity(name, expected: "one", actual: arguments.count) }
        return transform(arguments[0])
    }

    private static func binary(
        _ arguments: [PortableExpressionIR],
        name: String,
        transform: (PortableExpressionIR, PortableExpressionIR) -> PortableExpressionIR
    ) throws -> PortableExpressionIR {
        guard arguments.count == 2 else { throw arity(name, expected: "two", actual: arguments.count) }
        return transform(arguments[0], arguments[1])
    }

    private static func arity(_ name: String, expected: String, actual: Int) -> SBMLImportError {
        .malformedMathML("Operator \(name) expected \(expected) argument(s), received \(actual)")
    }
}
