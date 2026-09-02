import Foundation
import NumiTissueCore
import NumiTissueRuntime

public enum SWCNodeKind: Int, Sendable, Codable, CaseIterable {
    case undefined = 0
    case soma = 1
    case axon = 2
    case basalDendrite = 3
    case apicalDendrite = 4
    case forkPoint = 5
    case endPoint = 6
    case custom = 7
}

public struct SWCNode: Sendable, Hashable, Codable {
    public var id: Int
    public var kind: SWCNodeKind
    public var customKind: Int?
    public var positionMicrometers: SIMD3<Double>
    public var radiusMicrometers: Double
    public var parentID: Int?

    public init(
        id: Int,
        kind: SWCNodeKind,
        customKind: Int? = nil,
        positionMicrometers: SIMD3<Double>,
        radiusMicrometers: Double,
        parentID: Int?
    ) {
        self.id = id
        self.kind = kind
        self.customKind = customKind
        self.positionMicrometers = positionMicrometers
        self.radiusMicrometers = radiusMicrometers
        self.parentID = parentID
    }
}

public struct SWCMorphology: Sendable, Hashable, Codable {
    public var metadata: [String: String]
    public var nodes: [SWCNode]

    public init(metadata: [String: String] = [:], nodes: [SWCNode]) {
        self.metadata = metadata
        self.nodes = nodes
    }

    public func validated() throws -> SWCMorphology {
        guard !nodes.isEmpty else { throw SWCError.empty }
        var byID: [Int: SWCNode] = [:]
        for node in nodes {
            guard node.id > 0 else { throw SWCError.invalidNodeID(node.id) }
            guard byID.updateValue(node, forKey: node.id) == nil else { throw SWCError.duplicateNodeID(node.id) }
            guard node.radiusMicrometers.isFinite, node.radiusMicrometers > 0 else { throw SWCError.invalidRadius(nodeID: node.id, value: node.radiusMicrometers) }
            guard node.positionMicrometers.x.isFinite, node.positionMicrometers.y.isFinite, node.positionMicrometers.z.isFinite else {
                throw SWCError.nonFiniteCoordinate(node.id)
            }
        }
        for node in nodes {
            if let parent = node.parentID {
                guard parent != node.id else { throw SWCError.selfParent(node.id) }
                guard byID[parent] != nil else { throw SWCError.missingParent(nodeID: node.id, parentID: parent) }
            }
        }
        try detectCycles(byID: byID)
        return self
    }

    public var roots: [SWCNode] { nodes.filter { $0.parentID == nil } }

    private func detectCycles(byID: [Int: SWCNode]) throws {
        enum Mark { case active, complete }
        var marks: [Int: Mark] = [:]
        for node in nodes where marks[node.id] == nil {
            var chain: [Int] = []
            var current: Int? = node.id
            while let id = current {
                if marks[id] == .active { throw SWCError.cycle(nodeID: id) }
                if marks[id] == .complete { break }
                marks[id] = .active
                chain.append(id)
                current = byID[id]?.parentID
            }
            for id in chain { marks[id] = .complete }
        }
    }
}

public enum SWCError: Error, Sendable, CustomStringConvertible {
    case empty
    case malformedLine(number: Int, line: String)
    case invalidNodeID(Int)
    case duplicateNodeID(Int)
    case invalidRadius(nodeID: Int, value: Double)
    case nonFiniteCoordinate(Int)
    case missingParent(nodeID: Int, parentID: Int)
    case selfParent(Int)
    case cycle(nodeID: Int)
    case disconnectedRoots(Int)

    public var description: String {
        switch self {
        case .empty: return "SWC morphology is empty"
        case .malformedLine(let number, let line): return "Malformed SWC line \(number): \(line)"
        case .invalidNodeID(let id): return "SWC node ID must be positive; got \(id)"
        case .duplicateNodeID(let id): return "Duplicate SWC node ID \(id)"
        case .invalidRadius(let id, let value): return "Invalid SWC radius \(value) at node \(id)"
        case .nonFiniteCoordinate(let id): return "Non-finite SWC coordinate at node \(id)"
        case .missingParent(let node, let parent): return "SWC node \(node) references missing parent \(parent)"
        case .selfParent(let id): return "SWC node \(id) is its own parent"
        case .cycle(let id): return "Cycle detected at SWC node \(id)"
        case .disconnectedRoots(let count): return "SWC morphology contains \(count) roots"
        }
    }
}

public enum SWCImporter {
    public static func parse(_ text: String, requireSingleRoot: Bool = false) throws -> SWCMorphology {
        var metadata: [String: String] = [:]
        var nodes: [SWCNode] = []
        for (zeroBasedLine, rawLine) in text.split(whereSeparator: \.isNewline, omittingEmptySubsequences: false).enumerated() {
            let lineNumber = zeroBasedLine + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let payload = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let separator = payload.firstIndex(of: "=") {
                    let key = payload[..<separator].trimmingCharacters(in: .whitespaces)
                    let value = payload[payload.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty { metadata[key] = value }
                } else {
                    metadata["comment.\(lineNumber)"] = payload
                }
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 7,
                  let id = Int(fields[0]),
                  let rawKind = Int(fields[1]),
                  let x = Double(fields[2]),
                  let y = Double(fields[3]),
                  let z = Double(fields[4]),
                  let radius = Double(fields[5]),
                  let rawParent = Int(fields[6]) else {
                throw SWCError.malformedLine(number: lineNumber, line: line)
            }
            let kind = SWCNodeKind(rawValue: rawKind) ?? .custom
            nodes.append(SWCNode(
                id: id,
                kind: kind,
                customKind: kind == .custom ? rawKind : nil,
                positionMicrometers: SIMD3(x, y, z),
                radiusMicrometers: radius,
                parentID: rawParent < 0 ? nil : rawParent
            ))
        }
        let morphology = try SWCMorphology(metadata: metadata, nodes: nodes).validated()
        if requireSingleRoot && morphology.roots.count != 1 { throw SWCError.disconnectedRoots(morphology.roots.count) }
        return morphology
    }

    public static func load(url: URL, requireSingleRoot: Bool = false) throws -> SWCMorphology {
        try parse(String(contentsOf: url, encoding: .utf8), requireSingleRoot: requireSingleRoot)
    }
}

public enum SWCExporter {
    public static func encode(_ morphology: SWCMorphology) throws -> String {
        let morphology = try morphology.validated()
        var lines: [String] = morphology.metadata.sorted { $0.key < $1.key }.map { "# \($0.key)=\($0.value)" }
        lines.reserveCapacity(lines.count + morphology.nodes.count)
        for node in morphology.nodes.sorted(by: { $0.id < $1.id }) {
            let kind = node.kind == .custom ? node.customKind ?? SWCNodeKind.custom.rawValue : node.kind.rawValue
            let parent = node.parentID ?? -1
            lines.append("\(node.id) \(kind) \(format(node.positionMicrometers.x)) \(format(node.positionMicrometers.y)) \(format(node.positionMicrometers.z)) \(format(node.radiusMicrometers)) \(parent)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String { String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value) }
}

public struct SWCRuntimeCompiler: Sendable {
    public var cellID: CellID
    public var neuronIndex: UInt32
    public var segmentIDBase: UInt64
    public var compartmentIDBase: UInt64
    public var membraneCapacitancePerArea: Float
    public var axialResistivityOhmCentimeters: Float

    public init(
        cellID: CellID,
        neuronIndex: UInt32,
        segmentIDBase: UInt64,
        compartmentIDBase: UInt64,
        membraneCapacitancePerArea: Float = 1,
        axialResistivityOhmCentimeters: Float = 100
    ) {
        self.cellID = cellID
        self.neuronIndex = neuronIndex
        self.segmentIDBase = segmentIDBase
        self.compartmentIDBase = compartmentIDBase
        self.membraneCapacitancePerArea = membraneCapacitancePerArea
        self.axialResistivityOhmCentimeters = axialResistivityOhmCentimeters
    }

    public func compile(_ morphology: SWCMorphology, cellIndex: UInt32) throws -> (segments: [RuntimeSegmentState], compartments: [RuntimeCompartmentState]) {
        let morphology = try morphology.validated()
        let ordered = morphology.nodes.sorted { $0.id < $1.id }
        let indexByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, UInt32($0.offset)) })
        var children: [Int: [Int]] = [:]
        for node in ordered {
            if let parent = node.parentID { children[parent, default: []].append(node.id) }
        }
        var segments: [RuntimeSegmentState] = []
        var compartments: [RuntimeCompartmentState] = []
        segments.reserveCapacity(ordered.count)
        compartments.reserveCapacity(ordered.count)

        for (index, node) in ordered.enumerated() {
            let parentIndex = node.parentID.flatMap { indexByID[$0] } ?? RuntimeSegmentState.invalidIndex
            let parentNode = node.parentID.flatMap { id in ordered.first(where: { $0.id == id }) }
            let start = parentNode?.positionMicrometers ?? node.positionMicrometers
            let end = node.positionMicrometers
            let length = max(lengthMicrometers(start: start, end: end), max(node.radiusMicrometers * 0.1, 0.01))
            let radius = max(node.radiusMicrometers, 0.001)
            let areaSquareMicrometers = 2 * Double.pi * radius * length
            let capacitanceNanofarads = Float(areaSquareMicrometers * 1e-8) * membraneCapacitancePerArea
            let axialMicrosiemens: Float
            if parentIndex == RuntimeSegmentState.invalidIndex {
                axialMicrosiemens = 0
            } else {
                let radiusCentimeters = radius * 1e-4
                let lengthCentimeters = length * 1e-4
                let resistance = Double(axialResistivityOhmCentimeters) * lengthCentimeters / (Double.pi * radiusCentimeters * radiusCentimeters)
                axialMicrosiemens = Float(1e6 / max(resistance, 1e-12))
            }
            let childIDs = (children[node.id] ?? []).sorted()
            let firstChild = childIDs.first.flatMap { indexByID[$0] } ?? RuntimeSegmentState.invalidIndex
            let type = UInt16(clamping: node.kind.rawValue)
            let depth = UInt32(depth(of: node, byID: Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })))
            segments.append(RuntimeSegmentState(
                id: SegmentID(rawValue: segmentIDBase + UInt64(index)),
                cellIndex: cellIndex,
                parentSegmentIndex: parentIndex,
                firstChildIndex: firstChild,
                nextSiblingIndex: RuntimeSegmentState.invalidIndex,
                compartmentIndex: UInt32(index),
                type: type,
                start: Float4(Float(start.x), Float(start.y), Float(start.z), 0),
                end: Float4(Float(end.x), Float(end.y), Float(end.z), 0),
                radiusMicrometers: Float(radius)
            ))
            compartments.append(RuntimeCompartmentState(
                id: CompartmentID(rawValue: compartmentIDBase + UInt64(index)),
                neuronIndex: neuronIndex,
                parentIndex: parentIndex,
                capacitanceNanofarads: max(capacitanceNanofarads, 1e-8),
                axialConductanceMicrosiemens: axialMicrosiemens,
                flags: depth << 16
            ))
        }
        return (segments, compartments)
    }

    private func depth(of node: SWCNode, byID: [Int: SWCNode]) -> Int {
        var value = 0
        var parent = node.parentID
        while let id = parent, let current = byID[id] {
            value += 1
            parent = current.parentID
        }
        return min(value, 255)
    }

    private func lengthMicrometers(start: SIMD3<Double>, end: SIMD3<Double>) -> Double {
        let d = end - start
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    }
}
