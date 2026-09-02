import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct NMLPoint: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var diameter: Double

    public init(x: Double, y: Double, z: Double, diameter: Double) {
        self.x = x; self.y = y; self.z = z; self.diameter = diameter
    }
}

public struct NMLSegment: Sendable, Hashable, Codable {
    public var id: Int
    public var name: String?
    public var parentID: Int?
    public var fractionAlongParent: Double
    public var proximal: NMLPoint?
    public var distal: NMLPoint

    public init(id: Int, name: String? = nil, parentID: Int? = nil, fractionAlongParent: Double = 1, proximal: NMLPoint? = nil, distal: NMLPoint) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.fractionAlongParent = fractionAlongParent
        self.proximal = proximal
        self.distal = distal
    }
}

public struct NMLSegmentGroup: Sendable, Hashable, Codable {
    public var id: String
    public var members: Set<Int>
    public var includedGroups: Set<String>
    public var neuroLexID: String?

    public init(id: String, members: Set<Int> = [], includedGroups: Set<String> = [], neuroLexID: String? = nil) {
        self.id = id
        self.members = members
        self.includedGroups = includedGroups
        self.neuroLexID = neuroLexID
    }
}

public struct NMLChannelDensity: Sendable, Hashable, Codable {
    public var id: String
    public var ionChannelID: String
    public var ion: String?
    public var segmentGroupID: String?
    public var conductanceDensity: String
    public var reversalPotential: String?
    public var mode: String

    public init(id: String, ionChannelID: String, ion: String? = nil, segmentGroupID: String? = nil, conductanceDensity: String, reversalPotential: String? = nil, mode: String = "fixed") {
        self.id = id
        self.ionChannelID = ionChannelID
        self.ion = ion
        self.segmentGroupID = segmentGroupID
        self.conductanceDensity = conductanceDensity
        self.reversalPotential = reversalPotential
        self.mode = mode
    }
}

public struct NMLCellDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var notes: String?
    public var segments: [NMLSegment]
    public var segmentGroups: [NMLSegmentGroup]
    public var channelDensities: [NMLChannelDensity]
    public var specificCapacitance: String?
    public var resistivity: String?
    public var initialMembranePotential: String?

    public init(
        id: String,
        notes: String? = nil,
        segments: [NMLSegment] = [],
        segmentGroups: [NMLSegmentGroup] = [],
        channelDensities: [NMLChannelDensity] = [],
        specificCapacitance: String? = nil,
        resistivity: String? = nil,
        initialMembranePotential: String? = nil
    ) {
        self.id = id
        self.notes = notes
        self.segments = segments
        self.segmentGroups = segmentGroups
        self.channelDensities = channelDensities
        self.specificCapacitance = specificCapacitance
        self.resistivity = resistivity
        self.initialMembranePotential = initialMembranePotential
    }

    public func validated() throws -> Self {
        guard !id.isEmpty else { throw NeuroML2Error.missingAttribute(element: "cell", attribute: "id") }
        var byID: [Int: NMLSegment] = [:]
        for segment in segments {
            guard byID.updateValue(segment, forKey: segment.id) == nil else { throw NeuroML2Error.duplicateSegment(segment.id) }
            guard segment.distal.diameter > 0, segment.distal.diameter.isFinite else { throw NeuroML2Error.invalidDiameter(segment.id) }
            guard segment.fractionAlongParent >= 0, segment.fractionAlongParent <= 1 else { throw NeuroML2Error.invalidFraction(segment.id) }
        }
        for segment in segments {
            if let parent = segment.parentID, byID[parent] == nil { throw NeuroML2Error.missingParent(segment: segment.id, parent: parent) }
        }
        try validateSegmentCycles(byID)
        let groups = Dictionary(uniqueKeysWithValues: segmentGroups.map { ($0.id, $0) })
        guard groups.count == segmentGroups.count else { throw NeuroML2Error.duplicateGroup }
        for group in segmentGroups {
            for member in group.members where byID[member] == nil { throw NeuroML2Error.missingSegment(member) }
            _ = try expandedMembers(of: group.id)
        }
        return self
    }

    public func expandedMembers(of groupID: String) throws -> Set<Int> {
        let groups = Dictionary(uniqueKeysWithValues: segmentGroups.map { ($0.id, $0) })
        var active = Set<String>()
        func visit(_ id: String) throws -> Set<Int> {
            guard let group = groups[id] else { throw NeuroML2Error.missingGroup(id) }
            guard active.insert(id).inserted else { throw NeuroML2Error.groupCycle(id) }
            defer { active.remove(id) }
            var result = group.members
            for included in group.includedGroups { result.formUnion(try visit(included)) }
            return result
        }
        return try visit(groupID)
    }

    public func swcMorphology() throws -> SWCMorphology {
        let cell = try validated()
        let sorted = cell.segments.sorted { $0.id < $1.id }
        let swcID = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($0.element.id, $0.offset + 1) })
        let soma = (try? expandedMembers(of: "soma_group")) ?? []
        let axon = (try? expandedMembers(of: "axon_group")) ?? []
        let apical = (try? expandedMembers(of: "apical_dendrite_group")) ?? []
        let nodes = sorted.map { segment -> SWCNode in
            let kind: SWCNodeKind
            if soma.contains(segment.id) { kind = .soma }
            else if axon.contains(segment.id) { kind = .axon }
            else if apical.contains(segment.id) { kind = .apicalDendrite }
            else { kind = .basalDendrite }
            return SWCNode(
                id: swcID[segment.id]!,
                kind: kind,
                positionMicrometers: SIMD3(segment.distal.x, segment.distal.y, segment.distal.z),
                radiusMicrometers: segment.distal.diameter * 0.5,
                parentID: segment.parentID.flatMap { swcID[$0] }
            )
        }
        return try SWCMorphology(metadata: ["format": "NeuroML", "cell": id], nodes: nodes).validated()
    }

    private func validateSegmentCycles(_ byID: [Int: NMLSegment]) throws {
        enum Mark { case active, complete }
        var marks: [Int: Mark] = [:]
        for segment in segments where marks[segment.id] == nil {
            var chain: [Int] = []
            var current: Int? = segment.id
            while let id = current {
                if marks[id] == .active { throw NeuroML2Error.segmentCycle(id) }
                if marks[id] == .complete { break }
                marks[id] = .active
                chain.append(id)
                current = byID[id]?.parentID
            }
            for id in chain { marks[id] = .complete }
        }
    }
}

public struct NMLIonChannelDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var species: String?
    public var conductance: String?
    public var gates: [NMLGateDefinition]

    public init(id: String, species: String? = nil, conductance: String? = nil, gates: [NMLGateDefinition] = []) {
        self.id = id; self.species = species; self.conductance = conductance; self.gates = gates
    }
}

public struct NMLGateDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var instances: Int
    public var forwardRate: NMLRateDefinition?
    public var reverseRate: NMLRateDefinition?
    public var steadyState: NMLRateDefinition?
    public var timeCourse: NMLRateDefinition?

    public init(id: String, instances: Int = 1, forwardRate: NMLRateDefinition? = nil, reverseRate: NMLRateDefinition? = nil, steadyState: NMLRateDefinition? = nil, timeCourse: NMLRateDefinition? = nil) {
        self.id = id
        self.instances = instances
        self.forwardRate = forwardRate
        self.reverseRate = reverseRate
        self.steadyState = steadyState
        self.timeCourse = timeCourse
    }
}

public struct NMLRateDefinition: Sendable, Hashable, Codable {
    public var type: String
    public var rate: String?
    public var midpoint: String?
    public var scale: String?
    public var expression: String?

    public init(type: String, rate: String? = nil, midpoint: String? = nil, scale: String? = nil, expression: String? = nil) {
        self.type = type; self.rate = rate; self.midpoint = midpoint; self.scale = scale; self.expression = expression
    }
}

public struct NMLSynapseDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var type: String
    public var reversalPotential: String?
    public var riseTime: String?
    public var decayTime: String?
    public var conductance: String?

    public init(id: String, type: String, reversalPotential: String? = nil, riseTime: String? = nil, decayTime: String? = nil, conductance: String? = nil) {
        self.id = id; self.type = type; self.reversalPotential = reversalPotential; self.riseTime = riseTime; self.decayTime = decayTime; self.conductance = conductance
    }
}

public struct NMLPopulationDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var componentID: String
    public var size: Int
    public init(id: String, componentID: String, size: Int) { self.id = id; self.componentID = componentID; self.size = size }
}

public struct NMLConnectionDefinition: Sendable, Hashable, Codable {
    public var id: Int
    public var preCell: String
    public var postCell: String
    public var preSegmentID: Int?
    public var postSegmentID: Int?
    public var delay: String?
    public var weight: Double?

    public init(id: Int, preCell: String, postCell: String, preSegmentID: Int? = nil, postSegmentID: Int? = nil, delay: String? = nil, weight: Double? = nil) {
        self.id = id; self.preCell = preCell; self.postCell = postCell; self.preSegmentID = preSegmentID; self.postSegmentID = postSegmentID; self.delay = delay; self.weight = weight
    }
}

public struct NMLProjectionDefinition: Sendable, Hashable, Codable {
    public var id: String
    public var presynapticPopulationID: String
    public var postsynapticPopulationID: String
    public var synapseID: String
    public var connections: [NMLConnectionDefinition]

    public init(id: String, presynapticPopulationID: String, postsynapticPopulationID: String, synapseID: String, connections: [NMLConnectionDefinition] = []) {
        self.id = id
        self.presynapticPopulationID = presynapticPopulationID
        self.postsynapticPopulationID = postsynapticPopulationID
        self.synapseID = synapseID
        self.connections = connections
    }
}

public struct NeuroMLDocumentV2: Sendable, Hashable, Codable {
    public var id: String?
    public var includes: [String]
    public var cells: [NMLCellDefinition]
    public var ionChannels: [NMLIonChannelDefinition]
    public var synapses: [NMLSynapseDefinition]
    public var populations: [NMLPopulationDefinition]
    public var projections: [NMLProjectionDefinition]

    public init(id: String? = nil, includes: [String] = [], cells: [NMLCellDefinition] = [], ionChannels: [NMLIonChannelDefinition] = [], synapses: [NMLSynapseDefinition] = [], populations: [NMLPopulationDefinition] = [], projections: [NMLProjectionDefinition] = []) {
        self.id = id
        self.includes = includes
        self.cells = cells
        self.ionChannels = ionChannels
        self.synapses = synapses
        self.populations = populations
        self.projections = projections
    }

    public func validated() throws -> Self {
        var copy = self
        copy.cells = try cells.map { try $0.validated() }
        try requireUnique(copy.cells.map(\.id), kind: "cell")
        try requireUnique(copy.ionChannels.map(\.id), kind: "ion channel")
        try requireUnique(copy.synapses.map(\.id), kind: "synapse")
        try requireUnique(copy.populations.map(\.id), kind: "population")
        try requireUnique(copy.projections.map(\.id), kind: "projection")
        let cellIDs = Set(copy.cells.map(\.id))
        let populationByID = Dictionary(uniqueKeysWithValues: copy.populations.map { ($0.id, $0) })
        let synapseIDs = Set(copy.synapses.map(\.id))
        for population in copy.populations where !cellIDs.contains(population.componentID) {
            throw NeuroML2Error.unknownComponent(population.componentID)
        }
        for projection in copy.projections {
            guard populationByID[projection.presynapticPopulationID] != nil else { throw NeuroML2Error.unknownPopulation(projection.presynapticPopulationID) }
            guard populationByID[projection.postsynapticPopulationID] != nil else { throw NeuroML2Error.unknownPopulation(projection.postsynapticPopulationID) }
            guard synapseIDs.contains(projection.synapseID) else { throw NeuroML2Error.unknownSynapse(projection.synapseID) }
        }
        return copy
    }

    private func requireUnique(_ values: [String], kind: String) throws {
        guard Set(values).count == values.count else { throw NeuroML2Error.duplicateIdentifier(kind) }
    }
}

public enum NeuroML2Error: Error, Sendable, CustomStringConvertible {
    case parser(String)
    case missingAttribute(element: String, attribute: String)
    case invalidNumber(element: String, attribute: String, value: String)
    case duplicateIdentifier(String)
    case duplicateSegment(Int)
    case duplicateGroup
    case missingSegment(Int)
    case missingParent(segment: Int, parent: Int)
    case invalidDiameter(Int)
    case invalidFraction(Int)
    case segmentCycle(Int)
    case missingGroup(String)
    case groupCycle(String)
    case malformedSegment(Int)
    case malformedConnection(String)
    case unknownComponent(String)
    case unknownPopulation(String)
    case unknownSynapse(String)

    public var description: String {
        switch self {
        case .parser(let message): return "NeuroML parse error: \(message)"
        case .missingAttribute(let element, let attribute): return "NeuroML <\(element)> is missing \(attribute)"
        case .invalidNumber(let element, let attribute, let value): return "Invalid \(element).\(attribute) value \(value)"
        case .duplicateIdentifier(let kind): return "Duplicate NeuroML \(kind) identifier"
        case .duplicateSegment(let id): return "Duplicate NeuroML segment \(id)"
        case .duplicateGroup: return "Duplicate NeuroML segment group"
        case .missingSegment(let id): return "Missing NeuroML segment \(id)"
        case .missingParent(let segment, let parent): return "Segment \(segment) references missing parent \(parent)"
        case .invalidDiameter(let id): return "Segment \(id) has an invalid diameter"
        case .invalidFraction(let id): return "Segment \(id) has an invalid fractionAlong"
        case .segmentCycle(let id): return "Morphology cycle at segment \(id)"
        case .missingGroup(let id): return "Missing segment group \(id)"
        case .groupCycle(let id): return "Segment group include cycle at \(id)"
        case .malformedSegment(let id): return "Malformed morphology segment \(id)"
        case .malformedConnection(let id): return "Malformed connection \(id)"
        case .unknownComponent(let id): return "Unknown NeuroML component \(id)"
        case .unknownPopulation(let id): return "Unknown NeuroML population \(id)"
        case .unknownSynapse(let id): return "Unknown NeuroML synapse \(id)"
        }
    }
}
