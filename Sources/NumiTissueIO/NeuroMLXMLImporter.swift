import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum NeuroMLXMLImporterV2 {
    public static func load(url: URL) throws -> NeuroMLDocumentV2 {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> NeuroMLDocumentV2 {
        let delegate = NeuroMLV2ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            throw delegate.failure ?? NeuroML2Error.parser(parser.parserError?.localizedDescription ?? "Unknown XML parser failure")
        }
        if let failure = delegate.failure { throw failure }
        return try delegate.document.validated()
    }
}

private final class NeuroMLV2ParserDelegate: NSObject, XMLParserDelegate {
    var document = NeuroMLDocumentV2()
    var failure: NeuroML2Error?

    private var cell: NMLCellDefinition?
    private var segmentID: Int?
    private var segmentName: String?
    private var segmentParent: Int?
    private var segmentFraction = 1.0
    private var segmentProximal: NMLPoint?
    private var segmentDistal: NMLPoint?
    private var segmentGroup: NMLSegmentGroup?
    private var ionChannel: NMLIonChannelDefinition?
    private var gate: NMLGateDefinition?
    private var projection: NMLProjectionDefinition?
    private var captureNotes = false
    private var notesBuffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributes: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        let element = local(elementName)
        do {
            switch element {
            case "neuroml": document.id = attributes["id"]
            case "include":
                if let groupID = attributes["segmentGroup"] {
                    segmentGroup?.includedGroups.insert(groupID)
                } else if let href = attributes["href"] {
                    document.includes.append(href)
                }
            case "notes":
                if cell != nil { captureNotes = true; notesBuffer.removeAll(keepingCapacity: true) }
            case "cell":
                cell = NMLCellDefinition(id: try required(attributes["id"], element: element, attribute: "id"))
            case "segment":
                segmentID = try int(attributes["id"], element: element, attribute: "id")
                segmentName = attributes["name"]
                segmentParent = nil
                segmentFraction = 1
                segmentProximal = nil
                segmentDistal = nil
            case "parent":
                segmentParent = try int(attributes["segment"], element: element, attribute: "segment")
                if let fraction = attributes["fractionAlong"] {
                    segmentFraction = try double(fraction, element: element, attribute: "fractionAlong")
                }
            case "proximal": segmentProximal = try point(attributes, element: element)
            case "distal": segmentDistal = try point(attributes, element: element)
            case "segmentgroup":
                segmentGroup = NMLSegmentGroup(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    neuroLexID: attributes["neuroLexId"] ?? attributes["neurolexid"]
                )
            case "member":
                segmentGroup?.members.insert(try int(attributes["segment"], element: element, attribute: "segment"))
            case "channeldensity", "channeldensitynernst", "channeldensityghk", "channeldensitynonuniform":
                guard cell != nil else { break }
                cell?.channelDensities.append(NMLChannelDensity(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    ionChannelID: try required(attributes["ionChannel"], element: element, attribute: "ionChannel"),
                    ion: attributes["ion"],
                    segmentGroupID: attributes["segmentGroup"],
                    conductanceDensity: try required(attributes["condDensity"], element: element, attribute: "condDensity"),
                    reversalPotential: attributes["erev"],
                    mode: element
                ))
            case "specificcapacitance": cell?.specificCapacitance = attributes["value"]
            case "resistivity": cell?.resistivity = attributes["value"]
            case "initmembpotential": cell?.initialMembranePotential = attributes["value"]
            case "ionchannelhh", "ionchannel":
                ionChannel = NMLIonChannelDefinition(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    species: attributes["species"],
                    conductance: attributes["conductance"]
                )
            case "gatehhstates", "gatehhinstantaneous", "gatefractional", "gate":
                gate = NMLGateDefinition(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    instances: attributes["instances"].flatMap(Int.init) ?? 1
                )
            case "forwardrate": gate?.forwardRate = rate(attributes, element: element)
            case "reverserate": gate?.reverseRate = rate(attributes, element: element)
            case "steadystate": gate?.steadyState = rate(attributes, element: element)
            case "timecourse": gate?.timeCourse = rate(attributes, element: element)
            case "exptwosynapse", "exponesynapse", "alphacurrentsynapse", "blockingplasticsynapse":
                document.synapses.append(NMLSynapseDefinition(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    type: element,
                    reversalPotential: attributes["erev"],
                    riseTime: attributes["tauRise"],
                    decayTime: attributes["tauDecay"] ?? attributes["tauSyn"],
                    conductance: attributes["gbase"]
                ))
            case "population":
                document.populations.append(NMLPopulationDefinition(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    componentID: try required(attributes["component"], element: element, attribute: "component"),
                    size: try int(attributes["size"], element: element, attribute: "size")
                ))
            case "projection":
                projection = NMLProjectionDefinition(
                    id: try required(attributes["id"], element: element, attribute: "id"),
                    presynapticPopulationID: try required(attributes["presynapticPopulation"], element: element, attribute: "presynapticPopulation"),
                    postsynapticPopulationID: try required(attributes["postsynapticPopulation"], element: element, attribute: "postsynapticPopulation"),
                    synapseID: try required(attributes["synapse"], element: element, attribute: "synapse")
                )
            case "connection", "connectionwd":
                guard projection != nil else { break }
                projection?.connections.append(NMLConnectionDefinition(
                    id: try int(attributes["id"], element: element, attribute: "id"),
                    preCell: try required(attributes["preCellId"], element: element, attribute: "preCellId"),
                    postCell: try required(attributes["postCellId"], element: element, attribute: "postCellId"),
                    preSegmentID: attributes["preSegmentId"].flatMap(Int.init),
                    postSegmentID: attributes["postSegmentId"].flatMap(Int.init),
                    delay: attributes["delay"],
                    weight: attributes["weight"].flatMap(Double.init)
                ))
            default: break
            }
        } catch let error as NeuroML2Error {
            failure = error
            parser.abortParsing()
        } catch {
            failure = .parser(String(describing: error))
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
        let element = local(elementName)
        switch element {
        case "notes":
            if captureNotes { cell?.notes = notesBuffer.trimmingCharacters(in: .whitespacesAndNewlines) }
            captureNotes = false
        case "segment":
            guard let id = segmentID, let distal = segmentDistal else {
                failure = .malformedSegment(segmentID ?? -1)
                parser.abortParsing()
                return
            }
            cell?.segments.append(NMLSegment(
                id: id,
                name: segmentName,
                parentID: segmentParent,
                fractionAlongParent: segmentFraction,
                proximal: segmentProximal,
                distal: distal
            ))
            segmentID = nil
        case "segmentgroup":
            if let segmentGroup { cell?.segmentGroups.append(segmentGroup) }
            segmentGroup = nil
        case "cell":
            if let cell { document.cells.append(cell) }
            cell = nil
        case "gatehhstates", "gatehhinstantaneous", "gatefractional", "gate":
            if let gate { ionChannel?.gates.append(gate) }
            gate = nil
        case "ionchannelhh", "ionchannel":
            if let ionChannel { document.ionChannels.append(ionChannel) }
            ionChannel = nil
        case "projection":
            if let projection { document.projections.append(projection) }
            projection = nil
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if captureNotes { notesBuffer.append(string) }
    }

    private func point(_ attributes: [String: String], element: String) throws -> NMLPoint {
        NMLPoint(
            x: try double(try required(attributes["x"], element: element, attribute: "x"), element: element, attribute: "x"),
            y: try double(try required(attributes["y"], element: element, attribute: "y"), element: element, attribute: "y"),
            z: try double(try required(attributes["z"], element: element, attribute: "z"), element: element, attribute: "z"),
            diameter: try double(try required(attributes["diameter"], element: element, attribute: "diameter"), element: element, attribute: "diameter")
        )
    }

    private func rate(_ attributes: [String: String], element: String) -> NMLRateDefinition {
        NMLRateDefinition(
            type: attributes["type"] ?? element,
            rate: attributes["rate"],
            midpoint: attributes["midpoint"],
            scale: attributes["scale"],
            expression: attributes["value"] ?? attributes["expression"]
        )
    }

    private func local(_ value: String) -> String {
        value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }

    private func required(_ value: String?, element: String, attribute: String) throws -> String {
        guard let value, !value.isEmpty else { throw NeuroML2Error.missingAttribute(element: element, attribute: attribute) }
        return value
    }

    private func int(_ value: String?, element: String, attribute: String) throws -> Int {
        let value = try required(value, element: element, attribute: attribute)
        guard let result = Int(value) else { throw NeuroML2Error.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }

    private func double(_ value: String, element: String, attribute: String) throws -> Double {
        guard let result = Double(value), result.isFinite else { throw NeuroML2Error.invalidNumber(element: element, attribute: attribute, value: value) }
        return result
    }
}
