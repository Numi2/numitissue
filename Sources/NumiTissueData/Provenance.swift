import Foundation

public enum ProvenanceNodeKind: String, Codable, Sendable, CaseIterable {
    case entity
    case activity
    case agent
}

public struct ProvenanceNode: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ProvenanceNodeKind
    public var label: String
    public var type: String
    public var timestamp: Date?
    public var datasetReference: String?
    public var checksum: String?
    public var softwareVersion: String?
    public var metadata: [String: String]

    public init(
        id: String,
        kind: ProvenanceNodeKind,
        label: String,
        type: String,
        timestamp: Date? = nil,
        datasetReference: String? = nil,
        checksum: String? = nil,
        softwareVersion: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.type = type
        self.timestamp = timestamp
        self.datasetReference = datasetReference
        self.checksum = checksum
        self.softwareVersion = softwareVersion
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty, !label.isEmpty, !type.isEmpty else {
            throw ProvenanceError.invalidNode(id)
        }
        return self
    }
}

public enum ProvenanceEdgeKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// A derived entity points to the source entity.
    case derivedFrom
    /// A generated entity points to the activity that generated it.
    case generatedBy
    /// An activity points to an entity it consumed.
    case used
    /// An entity or activity points to its responsible person or organization.
    case attributedTo
    /// A transformed entity points to the transformation activity.
    case transformedBy
    /// A record points to the source dataset selection.
    case selectedFrom
    /// A result points to the experiment or observation it describes.
    case describes
    /// A node points to the software or model agent that implemented it.
    case implementedBy
}

public struct ProvenanceEdge: Codable, Sendable, Hashable {
    public var from: String
    public var to: String
    public var kind: ProvenanceEdgeKind
    public var role: String?

    public init(
        from: String,
        to: String,
        kind: ProvenanceEdgeKind,
        role: String? = nil
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.role = role
    }

    public func validated() throws -> Self {
        guard !from.isEmpty, !to.isEmpty, from != to else {
            throw ProvenanceError.invalidEdge(from: from, to: to)
        }
        return self
    }
}

public struct ProvenanceGraph: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var nodes: [ProvenanceNode]
    public var edges: [ProvenanceEdge]

    public init(
        schemaVersion: UInt32 = 1,
        nodes: [ProvenanceNode] = [],
        edges: [ProvenanceEdge] = []
    ) {
        self.schemaVersion = schemaVersion
        self.nodes = nodes
        self.edges = edges
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw ProvenanceError.unsupportedSchema(schemaVersion)
        }
        for node in nodes { _ = try node.validated() }
        for edge in edges { _ = try edge.validated() }

        guard Set(nodes.map(\.id)).count == nodes.count else {
            throw ProvenanceError.duplicateNode
        }
        guard Set(edges).count == edges.count else {
            throw ProvenanceError.duplicateEdge
        }

        let nodeIDs = Set(nodes.map(\.id))
        for edge in edges {
            guard nodeIDs.contains(edge.from), nodeIDs.contains(edge.to) else {
                throw ProvenanceError.unknownEndpoint(from: edge.from, to: edge.to)
            }
        }
        _ = try topologicalOrder()
        return self
    }

    public func node(_ id: String) -> ProvenanceNode? {
        nodes.first { $0.id == id }
    }

    public func outgoing(
        from nodeID: String,
        kinds: Set<ProvenanceEdgeKind> = Set(ProvenanceEdgeKind.allCases)
    ) -> [ProvenanceEdge] {
        edges.filter { $0.from == nodeID && kinds.contains($0.kind) }.sorted {
            if $0.to != $1.to { return $0.to < $1.to }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    public func incoming(
        to nodeID: String,
        kinds: Set<ProvenanceEdgeKind> = Set(ProvenanceEdgeKind.allCases)
    ) -> [ProvenanceEdge] {
        edges.filter { $0.to == nodeID && kinds.contains($0.kind) }.sorted {
            if $0.from != $1.from { return $0.from < $1.from }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    /// Returns causal ancestors in deterministic breadth-first order.
    public func lineage(
        of nodeID: String,
        maximumDepth: Int = 128
    ) throws -> [ProvenanceNode] {
        guard node(nodeID) != nil else {
            throw ProvenanceError.unknownNode(nodeID)
        }
        guard maximumDepth >= 0 else {
            throw ProvenanceError.invalidDepth(maximumDepth)
        }

        let traversedKinds: Set<ProvenanceEdgeKind> = [
            .derivedFrom,
            .generatedBy,
            .used,
            .transformedBy,
            .selectedFrom,
            .describes,
            .implementedBy,
            .attributedTo
        ]
        var visited: Set<String> = [nodeID]
        var queue: [(String, Int)] = [(nodeID, 0)]
        var cursor = 0
        var result: [ProvenanceNode] = []

        while cursor < queue.count {
            let (current, depth) = queue[cursor]
            cursor += 1
            guard depth < maximumDepth else { continue }
            for edge in outgoing(from: current, kinds: traversedKinds) {
                guard visited.insert(edge.to).inserted else { continue }
                if let target = node(edge.to) {
                    result.append(target)
                    queue.append((target.id, depth + 1))
                }
            }
        }
        return result
    }

    /// Causal edges must form a DAG. Attribution and descriptive edges are excluded.
    public func topologicalOrder() throws -> [String] {
        let causalKinds: Set<ProvenanceEdgeKind> = [
            .derivedFrom,
            .generatedBy,
            .used,
            .transformedBy,
            .selectedFrom
        ]
        let causalEdges = edges.filter { causalKinds.contains($0.kind) }
        var indegree: [String: Int] = [:]
        for node in nodes { indegree[node.id] = 0 }
        var adjacency: [String: [String]] = [:]

        for edge in causalEdges {
            adjacency[edge.from, default: []].append(edge.to)
            indegree[edge.to, default: 0] += 1
        }
        for key in adjacency.keys {
            adjacency[key]?.sort()
        }

        var ready = indegree
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted()
        var order: [String] = []
        order.reserveCapacity(nodes.count)

        while !ready.isEmpty {
            let current = ready.removeFirst()
            order.append(current)
            for target in adjacency[current] ?? [] {
                guard let currentDegree = indegree[target] else { continue }
                let next = currentDegree - 1
                indegree[target] = next
                if next == 0 {
                    ready.append(target)
                    ready.sort()
                }
            }
        }

        guard order.count == nodes.count else {
            let cyclic = indegree.filter { $0.value > 0 }.map(\.key).sorted()
            throw ProvenanceError.cycle(cyclic)
        }
        return order
    }

    public func merging(_ other: ProvenanceGraph) throws -> ProvenanceGraph {
        var byID: [String: ProvenanceNode] = [:]
        for node in nodes + other.nodes {
            if let existing = byID[node.id], existing != node {
                throw ProvenanceError.conflictingNode(node.id)
            }
            byID[node.id] = node
        }
        let merged = ProvenanceGraph(
            nodes: byID.values.sorted { $0.id < $1.id },
            edges: Array(Set(edges).union(other.edges)).sorted {
                if $0.from != $1.from { return $0.from < $1.from }
                if $0.to != $1.to { return $0.to < $1.to }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        )
        return try merged.validated()
    }
}

public struct ProvenanceBuilder: Sendable {
    private var nodesByID: [String: ProvenanceNode]
    private var edges: Set<ProvenanceEdge>

    public init(graph: ProvenanceGraph = ProvenanceGraph()) throws {
        _ = try graph.validated()
        nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        edges = Set(graph.edges)
    }

    public mutating func add(node: ProvenanceNode) throws {
        _ = try node.validated()
        if let existing = nodesByID[node.id], existing != node {
            throw ProvenanceError.conflictingNode(node.id)
        }
        nodesByID[node.id] = node
    }

    public mutating func add(edge: ProvenanceEdge) throws {
        _ = try edge.validated()
        guard nodesByID[edge.from] != nil, nodesByID[edge.to] != nil else {
            throw ProvenanceError.unknownEndpoint(from: edge.from, to: edge.to)
        }
        edges.insert(edge)
    }

    public mutating func recordDerivation(
        output: ProvenanceNode,
        activity: ProvenanceNode,
        inputs: [ProvenanceNode],
        agents: [ProvenanceNode] = []
    ) throws {
        try add(node: output)
        try add(node: activity)
        for input in inputs { try add(node: input) }
        for agent in agents { try add(node: agent) }

        try add(edge: ProvenanceEdge(
            from: output.id,
            to: activity.id,
            kind: .generatedBy
        ))
        for input in inputs {
            try add(edge: ProvenanceEdge(
                from: activity.id,
                to: input.id,
                kind: .used
            ))
        }
        for agent in agents {
            try add(edge: ProvenanceEdge(
                from: activity.id,
                to: agent.id,
                kind: .attributedTo
            ))
        }
    }

    public func build() throws -> ProvenanceGraph {
        try ProvenanceGraph(
            nodes: nodesByID.values.sorted { $0.id < $1.id },
            edges: edges.sorted {
                if $0.from != $1.from { return $0.from < $1.from }
                if $0.to != $1.to { return $0.to < $1.to }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        ).validated()
    }
}

public enum ProvenanceError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidNode(String)
    case invalidEdge(from: String, to: String)
    case duplicateNode
    case duplicateEdge
    case unknownEndpoint(from: String, to: String)
    case unknownNode(String)
    case invalidDepth(Int)
    case cycle([String])
    case conflictingNode(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported provenance schema \(version)."
        case .invalidNode(let id):
            return "Provenance node \(id) is invalid."
        case .invalidEdge(let from, let to):
            return "Provenance edge \(from) -> \(to) is invalid."
        case .duplicateNode:
            return "Provenance graph contains duplicate nodes."
        case .duplicateEdge:
            return "Provenance graph contains duplicate edges."
        case .unknownEndpoint(let from, let to):
            return "Provenance edge \(from) -> \(to) references an unknown node."
        case .unknownNode(let id):
            return "Provenance node \(id) does not exist."
        case .invalidDepth(let depth):
            return "Provenance traversal depth \(depth) is invalid."
        case .cycle(let identifiers):
            return "Provenance causal graph contains a cycle: \(identifiers.joined(separator: ", "))."
        case .conflictingNode(let id):
            return "Provenance node \(id) has conflicting definitions."
        }
    }
}
