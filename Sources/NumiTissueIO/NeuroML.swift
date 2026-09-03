import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct NeuroMLPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var diameter: Double

    public init(x: Double, y: Double, z: Double, diameter: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.diameter = diameter
    }
}

public struct NeuroMLSegment: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String?
    public var parentID: Int?
    public var fractionAlongParent: Double
    public var proximal: NeuroMLPoint?
    public var distal: NeuroMLPoint

    public init(
        id: Int,
        name: String? = nil,
        parentID: Int? = nil,
        fractionAlongParent: Double = 1,
        proximal: NeuroMLPoint? = nil,
        distal: NeuroMLPoint
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.fractionAlongParent = fractionAlongParent
        self.proximal = proximal
        self.distal = distal
    }
}

public struct NeuroMLSegmentGroup: Sendable, Hashable, Codable {
    public var id: String
    public var members: Set<Int>
    public var includes: Set<String>
    public var neuroLexID: String?

    public init(id: String, members: Set<Int> = [], includes: Set<String> = [], neuroLexID: String? = nil) {
        self.id = id
        self.members = members
        self.includes = includes
        self.neuroLexID = neuroLexID
    }
}

public struct NeuroMLChannelDensity: Sendable, Hashable, Codable {
    public var id: String
    public var ionChannel: String
    public var ion: String?
    public var segmentGroup: String?
    public var conductanceDensity: String
    public var reversalPotential: String?

    public init(id: String, ionChannel: String, ion: String? = nil, segmentGroup: String? = nil, conductanceDensity: String, reversalPotential: String? = nil) {
        self.id = id
        self.ionChannel = ionChannel
        self.ion = ion
        self.segmentGroup = segmentGroup
        self.conductanceDensity = conductanceDensity
        self.reversalPotential = reversalPotential
    }
}

public struct NeuroMLCell: Sendable, Hashable, Codable {
    public var id: String
    public var segments: [NeuroMLSegment]
    public var segmentGroups: [NeuroMLSegmentGroup]
    public var channelDensities: [NeuroMLChannelDensity]
    public var specificCapacitance: String?
    public var resistivity: String?
    public var initialMembranePotential: String?

    public init(
        id: String,
        segments: [NeuroMLSegment] = [],
        segmentGroups: [NeuroMLSegmentGroup] = [],
        channelDensities: [NeuroMLChannelDensity] = [],
        specificCapacitance: String? = nil,
        resistivity: String? = nil,
        initialMembranePotential: String? = nil
    ) {
        self.id = id
        self.segments = segments
        self.segmentGroups = segmentGroups
        self.channelDensities = channelDensities
        self.specificCapacitance = specificCapacitance
        self.resistivity = resistivity
        self.initialMembranePotential = initialMembranePotential
    }

    public func expandedMembers(of groupID: String) throws -> Set<Int> {
        let groups = Dictionary(uniqueKeysWithValues: segmentGroups.map { ($0.id, $0) })
        var active = Set<String>()
        func expand(_ id: String) throws -> Set<Int> {
            guard let group = groups[id] else { throw NeuroMLError.missingSegmentGroup(id) }
            guard active.insert(id).inserted else { throw NeuroMLError.segmentGroupCycle(id) }
            defer { active.remove(id) }
            var result = group.members
            for included in group.includes { result.formUnion(try expand(included)) }
            return result
        }
        return try expand(groupID)
    }

    public func validated() throws -> Self {
        guard !id.isEmpty else { throw NeuroMLError.missingAttribute(element: "cell", attribute: "id") }
        var ids = Set<Int>()
        for segment in segments {
            guard ids.insert(segment.id).inserted else { throw NeuroMLError.duplicateSegment(segment.id) }
            guard segment.distal.diameter > 0 else { throw NeuroMLError.invalidDiameter(segment: segment.id) }
            guard segment.fractionAlongParent >= 0 && segment.fractionAlongParent <= 1 else { throw NeuroMLError.invalidParentFraction(segment: segment.id) }
        }
        for segment in segments {
            if let parent = segment.parentID, !ids.contains(parent) { throw NeuroMLError.missingParent(segment: segment.id, parent: parent) }
        }
        for group in segmentGroups {
            for member in group.members where !ids.contains(member) { throw NeuroMLError.missingSegment(member) }
            _ = try expandedMembers(of: group.id)
        }
        return self
    }

    public func asSWC() throws -> SWCMorphology {
        let validated = try self.validated()
        let sorted = validated.segments.sorted { $0.id < $1.id }
        let idMap = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset + 1) })
        let somaMembers = try? expandedMembers(of: "soma_group")
        let axonMembers = try? expandedMembers(of: "axon_group")
        let apicalMembers = try? expandedMembers(of: "apical_dendrite_group")
        let nodes = sorted.map { segment -> SWCNode in
            let kind: SWCNodeKind
            if somaMembers?.contains(segment.id) == true { kind = .soma }
            else if axonMembers?.contains(segment.id) == true { kind = .axon }
            else if apicalMembers?.contains(segment.id) == true { kind = .apicalDendrite }
            else { kind = .basalDendrite }
            return SWCNode(
                id: idMap[segment.id]!,
                kind: kind,
                positionMicrometers: SIMD3(segment.distal.x, segment.distal.y, segment.distal.z),
                radiusMicrometers: segment.distal.diameter * 0.5,
                parentID: segment.parentID.flatMap { idMap[$0] }
            )
        }
        return try SWCMorphology(metadata: ["source": "NeuroML", "cell": id], nodes: nodes).validated()
    }
}

public struct NeuroMLSynapseDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var kind: String
    public var reversalPotential: String?
    public var riseTime: String?
    public var decayTime: String?
    public var conductance: String?
}

public struct NeuroMLPopulation: Sendable, Hashable, Codable {
    public var id: String
    public var component: String
    public var size: Int
}

public struct NeuroMLConnection: Sendable, Hashable, Codable {
    public var id: Int
    public var preCell: String
    public var postCell: String
    public var preSegment: Int?
    public var postSegment: Int?
    public var delay: String?
    public var weight: Double?
}

public struct NeuroMLProjection: Sendable, Hashable, Codable {
    public var id: String
    public var presynapticPopulation: String
    public var postsynapticPopulation: String
    public var synapse: String
    public var connections: [NeuroMLConnection]
}

public struct NeuroMLDocument: Sendable, Codable {
    public var id: String?
    public var cells: [NeuroMLCell]
    public var synapses: [NeuroMLSynapseDefinition]
    public var populations: [NeuroMLPopulation]
    public var projections: [NeuroMLProjection]
    public var includes: [String]

    public init(id: String? = nil, cells: [NeuroMLCell] = [], synapses: [NeuroMLSynapseDefinition] = [], populations: [NeuroMLPopulation] = [], projections: [NeuroMLProjection] = [], includes: [String] = []) {
        self.id = id
        self.cells = cells
        self.synapses = synapses
        self.populations = populations
        self.projections = projections
        self.includes = includes
    }
}

public enum NeuroMLError: Error, Sendable, CustomStringConvertible {
    case parser(String)
    case missingAttribute(element: String, attribute: String)
    case duplicateSegment(Int)
    case missingSegment(Int)
    case missingParent(segment: Int, parent: Int)
    case invalidDiameter(segment: Int)
    case invalidParentFraction(segment: Int)
    case missingSegmentGroup(String)
    case segmentGroupCycle(String)
    case malformedPoint(segment: Int)
    case malformedConnection(String)

    public var description: String {
        switch self {
        case .parser(let message): return "NeuroML parse error: \(message)"
        case .missingAttribute(let element, let attribute): return "NeuroML <\(element)> is missing \(attribute)"
        case .duplicateSegment(let id): return "Duplicate NeuroML segment \(id)"
        case .missingSegment(let id): return "Missing NeuroML segment \(id)"
        case .missingParent(let segment, let parent): return "NeuroML segment \(segment) references missing parent \(parent)"
        case .invalidDiameter(let segment): return "NeuroML segment \(segment) has a nonpositive diameter"
        case .invalidParentFraction(let segment): return "NeuroML segment \(segment) has invalid fractionAlong"
        case .missingSegmentGroup(let id): return "Missing NeuroML segmentGroup \(id)"
        case .segmentGroupCycle(let id): return "Cycle in NeuroML segmentGroup \(id)"
        case .malformedPoint(let segment): return "Malformed morphology point in segment \(segment)"
        case .malformedConnection(let id): return "Malformed NeuroML connection \(id)"
        }
    }
}

public enum NeuroMLImporter {
    public static func load(url: URL) throws -> NeuroMLDocument {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> NeuroMLDocument {
        let delegate = NeuroMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw NeuroMLError.parser(parser.parserError?.localizedDescription ?? delegate.failure.map(String.init(describing:)) ?? "Unknown XML error")
        }
        if let failure = delegate.failure { throw failure }
        var document = delegate.document
        document.cells = try document.cells.map { try $0.validated() }
        return document
    }
}

private final class NeuroMLParserDelegate: NSObject, XMLParserDelegate {
    var document = NeuroMLDocument()
    var failure: NeuroMLError?
    private var cell: NeuroMLCell?
    private var segmentID: Int?
    private var segmentName: String?
    private var segmentParent: Int?
    private var segmentFraction: Double = 1
    private var proximal: NeuroMLPoint?
    private var distal: NeuroMLPoint?
    private var group: NeuroMLSegmentGroup?
    private var projection: NeuroMLProjection?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        guard failure == nil else { return }
        let element = local(elementName)
        switch element {
        case "neuroml": document.id = attributeDict["id"]
        case "include":
            if let href = attributeDict["href"] { document.includes.append(href) }
            if let id = attributeDict["segmentGroup"] { group?.includes.insert(id) }
        case "cell":
            guard let id = attributeDict["id"] else { return fail(.missingAttribute(element: element, attribute: "id")) }
            cell = NeuroMLCell(id: id)
        case "segment":
            guard let text = attributeDict["id"], let id = Int(text) else { return fail(.missingAttribute(element: element, attribute: "id")) }
            segmentID = id
            segmentName = attributeDict["name"]
            segmentParent = nil
            segmentFraction = 1
            proximal = nil
            distal = nil
        case "parent":
            if let text = attributeDict["segment"], let id = Int(text) { segmentParent = id }
            if let text = attributeDict["fractionAlong"], let value = Double(text) { segmentFraction = value }
        case "proximal": proximal = point(attributes: attributeDict)
        case "distal": distal = point(attributes: attributeDict)
        case "segmentgroup":
            guard let id = attributeDict["id"] else { return fail(.missingAttribute(element: element, attribute: "id")) }
            group = NeuroMLSegmentGroup(id: id, neuroLexID: attributeDict["neuroLexId"])
        case "member": if let text = attributeDict["segment"], let id = Int(text) { group?.members.insert(id) }
        case "channeldensity", "channeldensitynernst", "channeldensityghk":
            guard let id = attributeDict["id"], let channel = attributeDict["ionChannel"], let density = attributeDict["condDensity"] else { return }
            cell?.channelDensities.append(NeuroMLChannelDensity(
                id: id,
                ionChannel: channel,
                ion: attributeDict["ion"],
                segmentGroup: attributeDict["segmentGroup"],
                conductanceDensity: density,
                reversalPotential: attributeDict["erev"]
            ))
        case "specificcapacitance": cell?.specificCapacitance = attributeDict["value"]
        case "resistivity": cell?.resistivity = attributeDict["value"]
        case "initmembpotential": cell?.initialMembranePotential = attributeDict["value"]
        case "exptwosynapse", "exponesynapse", "alphacurrentsynapse":
            guard let id = attributeDict["id"] else { return }
            document.synapses.append(NeuroMLSynapseDefinition(
                id: id,
                kind: element,
                reversalPotential: attributeDict["erev"],
                riseTime: attributeDict["tauRise"],
                decayTime: attributeDict["tauDecay"] ?? attributeDict["tauSyn"],
                conductance: attributeDict["gbase"]
            ))
        case "population":
            guard let id = attributeDict["id"], let component = attributeDict["component"], let sizeText = attributeDict["size"], let size = Int(sizeText) else { return }
            document.populations.append(NeuroMLPopulation(id: id, component: component, size: size))
        case "projection":
            guard let id = attributeDict["id"], let pre = attributeDict["presynapticPopulation"], let post = attributeDict["postsynapticPopulation"], let synapse = attributeDict["synapse"] else { return }
            projection = NeuroMLProjection(id: id, presynapticPopulation: pre, postsynapticPopulation: post, synapse: synapse, connections: [])
        case "connection", "connectionwd":
            guard var projection else { return }
            guard let idText = attributeDict["id"], let id = Int(idText), let pre = attributeDict["preCellId"], let post = attributeDict["postCellId"] else {
                return fail(.malformedConnection(attributeDict["id"] ?? "unknown"))
            }
            projection.connections.append(NeuroMLConnection(
                id: id,
                preCell: pre,
                postCell: post,
                preSegment: attributeDict["preSegmentId"].flatMap(Int.init),
                postSegment: attributeDict["postSegmentId"].flatMap(Int.init),
                delay: attributeDict["delay"],
                weight: attributeDict["weight"].flatMap(Double.init)
            ))
            self.projection = projection
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil else { return }
        switch local(elementName) {
        case "segment":
            guard let id = segmentID, let distal else { return fail(.malformedPoint(segment: segmentID ?? -1)) }
            cell?.segments.append(NeuroMLSegment(id: id, name: segmentName, parentID: segmentParent, fractionAlongParent: segmentFraction, proximal: proximal, distal: distal))
            segmentID = nil
        case "segmentgroup": if let group { cell?.segmentGroups.append(group) }; group = nil
        case "cell": if let cell { document.cells.append(cell) }; cell = nil
        case "projection": if let projection { document.projections.append(projection) }; projection = nil
        default: break
        }
    }

    private func point(attributes: [String: String]) -> NeuroMLPoint? {
        guard let x = attributes["x"].flatMap(Double.init),
              let y = attributes["y"].flatMap(Double.init),
              let z = attributes["z"].flatMap(Double.init),
              let diameter = attributes["diameter"].flatMap(Double.init) else { return nil }
        return NeuroMLPoint(x: x, y: y, z: z, diameter: diameter)
    }

    private func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased() }
    private func fail(_ error: NeuroMLError) { failure = error }
}
