import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum LEMSXMLImporter {
    public static func load(url: URL) throws -> LEMSDocument {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> LEMSDocument {
        let delegate = LEMSParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw delegate.failure ?? LEMSError.xml(parser.parserError?.localizedDescription ?? "Unknown XML parser failure")
        }
        if let failure = delegate.failure { throw failure }
        return try delegate.document.validated()
    }
}

private final class LEMSParserDelegate: NSObject, XMLParserDelegate {
    var document = LEMSDocument()
    var failure: LEMSError?

    private var componentType: LEMSComponentTypeDefinition?
    private var dynamics: LEMSDynamicsDefinition?
    private var regime: LEMSRegimeDefinition?
    private var onCondition: LEMSOnConditionDefinition?
    private var onEvent: LEMSOnEventDefinition?
    private var onStart: LEMSOnStartDefinition?
    private var onEntryAssignments: [LEMSStateAssignmentDefinition]?
    private var componentStack: [LEMSComponentInstance] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        let element = local(elementName)
        do {
            switch element {
            case "include":
                if let file = attributes["file"] ?? attributes["href"] { document.includes.append(file) }
            case "dimension":
                let name = try required(attributes["name"], element: element, attribute: "name")
                document.dimensions[name] = LEMSDimension(
                    mass: try integer(attributes["m"], element: element, attribute: "m", default: 0),
                    length: try integer(attributes["l"], element: element, attribute: "l", default: 0),
                    time: try integer(attributes["t"], element: element, attribute: "t", default: 0),
                    electricCurrent: try integer(attributes["i"], element: element, attribute: "i", default: 0),
                    temperature: try integer(attributes["k"], element: element, attribute: "k", default: 0),
                    amount: try integer(attributes["n"], element: element, attribute: "n", default: 0),
                    luminousIntensity: try integer(attributes["j"], element: element, attribute: "j", default: 0)
                )
            case "unit":
                document.units.append(LEMSUnitDefinition(
                    symbol: try required(attributes["symbol"], element: element, attribute: "symbol"),
                    dimensionID: try required(attributes["dimension"], element: element, attribute: "dimension"),
                    power: try integer(attributes["power"], element: element, attribute: "power", default: 0),
                    scale: try number(attributes["scale"], element: element, attribute: "scale", default: 1),
                    offset: try number(attributes["offset"], element: element, attribute: "offset", default: 0)
                ))
            case "componenttype":
                componentType = LEMSComponentTypeDefinition(
                    name: try required(attributes["name"], element: element, attribute: "name"),
                    extends: attributes["extends"],
                    description: attributes["description"]
                )
            case "parameter":
                componentType?.parameters.append(LEMSParameterDefinition(
                    name: try required(attributes["name"], element: element, attribute: "name"),
                    dimensionID: attributes["dimension"],
                    description: attributes["description"]
                ))
            case "constant":
                componentType?.constants.append(LEMSConstantDefinition(
                    name: try required(attributes["name"], element: element, attribute: "name"),
                    dimensionID: attributes["dimension"],
                    value: try required(attributes["value"], element: element, attribute: "value")
                ))
            case "exposure":
                if let name = attributes["name"] { componentType?.exposures[name] = attributes["dimension"] }
            case "requirement":
                if let name = attributes["name"] { componentType?.requirements[name] = attributes["dimension"] }
            case "eventport":
                if let name = attributes["name"] { componentType?.eventPorts[name] = attributes["direction"] ?? "in" }
            case "dynamics": dynamics = LEMSDynamicsDefinition()
            case "statevariable":
                dynamics?.stateVariables.append(LEMSStateVariableDefinition(
                    name: try required(attributes["name"], element: element, attribute: "name"),
                    dimensionID: attributes["dimension"],
                    exposure: attributes["exposure"]
                ))
            case "derivedvariable", "conditionalderivedvariable":
                guard let name = attributes["name"] else { throw LEMSError.missingAttribute(element: element, attribute: "name") }
                let expressionSource = attributes["value"] ?? attributes["expression"] ?? "0"
                dynamics?.derivedVariables.append(LEMSDerivedVariableDefinition(
                    name: name,
                    dimensionID: attributes["dimension"],
                    exposure: attributes["exposure"],
                    expression: try expression(expressionSource),
                    reduce: attributes["reduce"],
                    select: attributes["select"]
                ))
            case "timederivative":
                let derivative = LEMSTimeDerivativeDefinition(
                    variable: try required(attributes["variable"], element: element, attribute: "variable"),
                    expression: try expression(try required(attributes["value"], element: element, attribute: "value"))
                )
                if regime != nil { regime?.derivatives.append(derivative) } else { dynamics?.derivatives.append(derivative) }
            case "onstart": onStart = LEMSOnStartDefinition(assignments: [])
            case "oncondition":
                onCondition = LEMSOnConditionDefinition(
                    test: try expression(try required(attributes["test"], element: element, attribute: "test")),
                    assignments: [],
                    events: [],
                    transition: nil
                )
            case "onevent":
                onEvent = LEMSOnEventDefinition(
                    port: try required(attributes["port"], element: element, attribute: "port"),
                    assignments: [],
                    events: [],
                    transition: nil
                )
            case "onentry": onEntryAssignments = []
            case "stateassignment":
                let assignment = LEMSStateAssignmentDefinition(
                    variable: try required(attributes["variable"], element: element, attribute: "variable"),
                    expression: try expression(try required(attributes["value"], element: element, attribute: "value"))
                )
                if onCondition != nil { onCondition?.assignments.append(assignment) }
                else if onEvent != nil { onEvent?.assignments.append(assignment) }
                else if onStart != nil { onStart?.assignments.append(assignment) }
                else if onEntryAssignments != nil { onEntryAssignments?.append(assignment) }
                else { throw LEMSError.malformedDynamics("StateAssignment is outside an event handler") }
            case "eventout":
                let event = LEMSEventOutDefinition(port: try required(attributes["port"], element: element, attribute: "port"))
                if onCondition != nil { onCondition?.events.append(event) }
                else if onEvent != nil { onEvent?.events.append(event) }
                else { throw LEMSError.malformedDynamics("EventOut is outside OnCondition/OnEvent") }
            case "transition":
                let transition = LEMSTransitionDefinition(targetRegime: try required(attributes["regime"], element: element, attribute: "regime"))
                if onCondition != nil { onCondition?.transition = transition }
                else if onEvent != nil { onEvent?.transition = transition }
                else { throw LEMSError.malformedDynamics("Transition is outside OnCondition/OnEvent") }
            case "regime":
                regime = LEMSRegimeDefinition(
                    name: try required(attributes["name"], element: element, attribute: "name"),
                    initial: boolean(attributes["initial"], default: false),
                    derivatives: [],
                    onConditions: [],
                    onEvents: [],
                    onEntry: []
                )
            case "component":
                let reserved = Set(["id", "type"])
                let values = attributes.filter { !reserved.contains($0.key) }
                componentStack.append(LEMSComponentInstance(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    type: try required(attributes["type"], element: element, attribute: "type"),
                    parameters: values
                ))
            default: break
            }
        } catch let error as LEMSError {
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
        switch local(elementName) {
        case "onstart":
            dynamics?.onStart = onStart
            onStart = nil
        case "oncondition":
            if let value = onCondition {
                if regime != nil { regime?.onConditions.append(value) } else { dynamics?.onConditions.append(value) }
            }
            onCondition = nil
        case "onevent":
            if let value = onEvent {
                if regime != nil { regime?.onEvents.append(value) } else { dynamics?.onEvents.append(value) }
            }
            onEvent = nil
        case "onentry":
            if let assignments = onEntryAssignments { regime?.onEntry.append(contentsOf: assignments) }
            onEntryAssignments = nil
        case "regime":
            if let regime { dynamics?.regimes.append(regime) }
            regime = nil
        case "dynamics":
            componentType?.dynamics = dynamics
            dynamics = nil
        case "componenttype":
            if let componentType { document.componentTypes.append(componentType) }
            componentType = nil
        case "component":
            guard let completed = componentStack.popLast() else { return }
            if componentStack.isEmpty { document.components.append(completed) }
            else { componentStack[componentStack.count - 1].children.append(completed) }
        default: break
        }
    }

    private func expression(_ source: String) throws -> PortableExpressionIR {
        do { return try PortableExpressionParser.parse(source.replacingOccurrences(of: ".gt.", with: ">").replacingOccurrences(of: ".lt.", with: "<")) }
        catch { throw LEMSError.invalidExpression("\(source): \(error)") }
    }

    private func local(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }

    private func required(_ value: String?, element: String, attribute: String) throws -> String {
        guard let value, !value.isEmpty else { throw LEMSError.missingAttribute(element: element, attribute: attribute) }
        return value
    }

    private func integer(_ value: String?, element: String, attribute: String, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let result = Int(value) else { throw LEMSError.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }

    private func number(_ value: String?, element: String, attribute: String, default fallback: Double) throws -> Double {
        guard let value else { return fallback }
        guard let result = Double(value), result.isFinite else { throw LEMSError.invalidNumber(element: element, attribute: attribute, value: value) }
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
