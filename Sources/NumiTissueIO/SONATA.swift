import Foundation
import NumiTissueCore

public enum SONATAValue: Sendable, Hashable, Codable {
    case integer(Int64)
    case floating(Double)
    case string(String)
    case boolean(Bool)
    case null

    public init(any value: Any) {
        switch value {
        case let value as Bool: self = .boolean(value)
        case let value as Int: self = .integer(Int64(value))
        case let value as Int64: self = .integer(value)
        case let value as Double: self = .floating(value)
        case let value as Float: self = .floating(Double(value))
        case let value as String: self = .string(value)
        default: self = .null
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .floating(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var intValue: Int64? {
        switch self {
        case .integer(let value): return value
        case .floating(let value): return Int64(exactly: value)
        case .string(let value): return Int64(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .floating(let value): return String(value)
        case .boolean(let value): return String(value)
        case .null: return nil
        }
    }
}

public struct SONATANodeRecord: Sendable, Hashable, Codable {
    public var nodeID: UInt64
    public var nodeTypeID: UInt32
    public var population: String
    public var attributes: [String: SONATAValue]

    public init(nodeID: UInt64, nodeTypeID: UInt32, population: String, attributes: [String: SONATAValue] = [:]) {
        self.nodeID = nodeID
        self.nodeTypeID = nodeTypeID
        self.population = population
        self.attributes = attributes
    }
}

public struct SONATAEdgeRecord: Sendable, Hashable, Codable {
    public var edgeID: UInt64
    public var sourceNodeID: UInt64
    public var targetNodeID: UInt64
    public var edgeTypeID: UInt32
    public var population: String
    public var attributes: [String: SONATAValue]

    public init(
        edgeID: UInt64,
        sourceNodeID: UInt64,
        targetNodeID: UInt64,
        edgeTypeID: UInt32,
        population: String,
        attributes: [String: SONATAValue] = [:]
    ) {
        self.edgeID = edgeID
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.edgeTypeID = edgeTypeID
        self.population = population
        self.attributes = attributes
    }
}

public struct SONATANodePopulation: Sendable, Codable {
    public var name: String
    public var records: [SONATANodeRecord]
    public init(name: String, records: [SONATANodeRecord]) { self.name = name; self.records = records }
}

public struct SONATAEdgePopulation: Sendable, Codable {
    public var name: String
    public var records: [SONATAEdgeRecord]
    public init(name: String, records: [SONATAEdgeRecord]) { self.name = name; self.records = records }
}

public struct SONATANetworkReference: Sendable, Hashable, Codable {
    public var nodesFile: String?
    public var nodeTypesFile: String?
    public var edgesFile: String?
    public var edgeTypesFile: String?

    public init(nodesFile: String? = nil, nodeTypesFile: String? = nil, edgesFile: String? = nil, edgeTypesFile: String? = nil) {
        self.nodesFile = nodesFile
        self.nodeTypesFile = nodeTypesFile
        self.edgesFile = edgesFile
        self.edgeTypesFile = edgeTypesFile
    }
}

public struct SONATACircuitConfiguration: Sendable, Codable {
    public var manifest: [String: String]
    public var networks: [SONATANetworkReference]
    public var components: [String: String]
    public var raw: [String: JSONValue]

    public init(manifest: [String: String], networks: [SONATANetworkReference], components: [String: String], raw: [String: JSONValue]) {
        self.manifest = manifest
        self.networks = networks
        self.components = components
        self.raw = raw
    }

    public func resolve(path: String, relativeTo configurationURL: URL) throws -> URL {
        var expanded = path
        var iterations = 0
        while expanded.contains("$") && iterations < 64 {
            iterations += 1
            var changed = false
            for (key, value) in manifest {
                let token = "$\(key)"
                if expanded.contains(token) {
                    expanded = expanded.replacingOccurrences(of: token, with: value)
                    changed = true
                }
            }
            if !changed { break }
        }
        if expanded.contains("$") { throw SONATAError.unresolvedManifestPath(expanded) }
        if expanded.hasPrefix("file://"), let url = URL(string: expanded) { return url }
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return configurationURL.deletingLastPathComponent().appendingPathComponent(expanded)
    }
}

public enum JSONValue: Sendable, Hashable, Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    public init(any: Any) {
        switch any {
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .boolean(value.boolValue) }
            else { self = .number(value.doubleValue) }
        default: self = .null
        }
    }

    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}

public enum SONATAConfigurationLoader {
    public static func load(url: URL) throws -> SONATACircuitConfiguration {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw SONATAError.invalidConfiguration("Root must be a JSON object") }
        let raw = root.mapValues(JSONValue.init(any:))
        let manifest = (root["manifest"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let components = (root["components"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let networksObject = root["networks"] as? [String: Any] ?? [:]
        var networks: [SONATANetworkReference] = []
        for node in networksObject["nodes"] as? [[String: Any]] ?? [] {
            networks.append(SONATANetworkReference(
                nodesFile: node["nodes_file"] as? String,
                nodeTypesFile: node["node_types_file"] as? String
            ))
        }
        for edge in networksObject["edges"] as? [[String: Any]] ?? [] {
            networks.append(SONATANetworkReference(
                edgesFile: edge["edges_file"] as? String,
                edgeTypesFile: edge["edge_types_file"] as? String
            ))
        }
        return SONATACircuitConfiguration(manifest: manifest, networks: networks, components: components, raw: raw)
    }
}

public protocol SONATAContainerReader: Sendable {
    func nodePopulations(at url: URL) async throws -> [String]
    func edgePopulations(at url: URL) async throws -> [String]
    func readNodes(at url: URL, population: String) async throws -> SONATANodePopulation
    func readEdges(at url: URL, population: String) async throws -> SONATAEdgePopulation
}

/// HDF5 is intentionally an injected provider. This keeps the core package dependency-free while
/// allowing production applications to bind HDF5Kit, SwiftHDF5, a C HDF5 module, or remote stores.
public protocol SONATAHDF5Provider: SONATAContainerReader {}

public enum SONATACSVReader {
    public static func readRows(url: URL) throws -> [[String: String]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var parser = RFC4180Parser(text: text)
        let table = try parser.parse()
        guard let header = table.first else { return [] }
        return table.dropFirst().enumerated().map { rowIndex, row in
            var value: [String: String] = [:]
            for column in header.indices {
                value[header[column]] = column < row.count ? row[column] : ""
            }
            value["__row"] = String(rowIndex + 2)
            return value
        }
    }

    public static func readNodeTypes(url: URL) throws -> [UInt32: [String: SONATAValue]] {
        var result: [UInt32: [String: SONATAValue]] = [:]
        for row in try readRows(url: url) {
            guard let text = row["node_type_id"], let id = UInt32(text) else { continue }
            result[id] = row.reduce(into: [:]) { output, pair in
                guard pair.key != "node_type_id" && pair.key != "__row" else { return }
                output[pair.key] = parseValue(pair.value)
            }
        }
        return result
    }

    public static func readEdgeTypes(url: URL) throws -> [UInt32: [String: SONATAValue]] {
        var result: [UInt32: [String: SONATAValue]] = [:]
        for row in try readRows(url: url) {
            guard let text = row["edge_type_id"], let id = UInt32(text) else { continue }
            result[id] = row.reduce(into: [:]) { output, pair in
                guard pair.key != "edge_type_id" && pair.key != "__row" else { return }
                output[pair.key] = parseValue(pair.value)
            }
        }
        return result
    }

    private static func parseValue(_ text: String) -> SONATAValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "null" || trimmed.lowercased() == "none" { return .null }
        if let integer = Int64(trimmed) { return .integer(integer) }
        if let floating = Double(trimmed) { return .floating(floating) }
        if let boolean = Bool(trimmed.lowercased()) { return .boolean(boolean) }
        return .string(trimmed)
    }
}

public enum SONATAError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case unresolvedManifestPath(String)
    case malformedCSV(row: Int, column: Int, reason: String)
    case missingColumn(String)
    case unsupportedContainer(URL)
    case duplicateNode(UInt64)
    case danglingEdge(edge: UInt64, node: UInt64)

    public var description: String {
        switch self {
        case .invalidConfiguration(let reason): return "Invalid SONATA configuration: \(reason)"
        case .unresolvedManifestPath(let path): return "Unresolved SONATA manifest path: \(path)"
        case .malformedCSV(let row, let column, let reason): return "Malformed CSV at row \(row), column \(column): \(reason)"
        case .missingColumn(let column): return "SONATA table is missing column \(column)"
        case .unsupportedContainer(let url): return "No SONATA container reader is registered for \(url.path)"
        case .duplicateNode(let id): return "Duplicate SONATA node ID \(id)"
        case .danglingEdge(let edge, let node): return "SONATA edge \(edge) references missing node \(node)"
        }
    }
}

private struct RFC4180Parser {
    let text: String
    private var index: String.Index
    private var row = 1
    private var column = 1

    init(text: String) {
        self.text = text
        self.index = text.startIndex
    }

    mutating func parse() throws -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var quoted = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"":
                    if !field.isEmpty { throw SONATAError.malformedCSV(row: row, column: column, reason: "Quote inside unquoted field") }
                    quoted = true
                case ",":
                    currentRow.append(field)
                    field.removeAll(keepingCapacity: true)
                    column += 1
                case "\n":
                    currentRow.append(field)
                    rows.append(currentRow)
                    currentRow.removeAll(keepingCapacity: true)
                    field.removeAll(keepingCapacity: true)
                    row += 1
                    column = 1
                case "\r": break
                default: field.append(character)
                }
            }
            index = next
        }
        if quoted { throw SONATAError.malformedCSV(row: row, column: column, reason: "Unterminated quoted field") }
        if !field.isEmpty || !currentRow.isEmpty {
            currentRow.append(field)
            rows.append(currentRow)
        }
        return rows
    }
}

public enum SONATAValidator {
    public static func validate(nodes: [SONATANodePopulation], edges: [SONATAEdgePopulation]) throws {
        var nodeIDs = Set<UInt64>()
        for population in nodes {
            for node in population.records {
                guard nodeIDs.insert(node.nodeID).inserted else { throw SONATAError.duplicateNode(node.nodeID) }
            }
        }
        for population in edges {
            for edge in population.records {
                if !nodeIDs.contains(edge.sourceNodeID) { throw SONATAError.danglingEdge(edge: edge.edgeID, node: edge.sourceNodeID) }
                if !nodeIDs.contains(edge.targetNodeID) { throw SONATAError.danglingEdge(edge: edge.edgeID, node: edge.targetNodeID) }
            }
        }
    }
}
