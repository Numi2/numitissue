import Foundation
import NumiTissueCore

public enum IonChannelKind: UInt16, Codable, Sendable, CaseIterable {
    case leak = 0
    case fastSodium = 1
    case delayedRectifierPotassium = 2
    case highVoltageCalcium = 3
    case calciumActivatedPotassium = 4
    case hcn = 5
    case mCurrent = 6
    case customOhmic = 7
}

public enum GateKineticsKind: UInt16, Codable, Sendable, CaseIterable {
    case none = 0
    case hodgkinHuxleyM = 1
    case hodgkinHuxleyH = 2
    case hodgkinHuxleyN = 3
    case sigmoidTau = 4
    case calciumHill = 5
}

@frozen
public struct GateKinetics: Codable, Sendable, Hashable {
    public var kind: GateKineticsKind
    public var parameters: Float4

    public init(kind: GateKineticsKind, parameters: Float4 = .zero) {
        self.kind = kind
        self.parameters = parameters
    }
}

@frozen
public struct IonChannelDescriptor: Codable, Sendable, Hashable {
    public var name: String
    public var kind: IonChannelKind
    public var maximumConductance: Float
    public var reversalPotentialMillivolts: Float
    public var activationPower: UInt8
    public var inactivationPower: UInt8
    public var activationGate: GateKinetics
    public var inactivationGate: GateKinetics

    public init(
        name: String,
        kind: IonChannelKind,
        maximumConductance: Float,
        reversalPotentialMillivolts: Float,
        activationPower: UInt8 = 0,
        inactivationPower: UInt8 = 0,
        activationGate: GateKinetics = .init(kind: .none),
        inactivationGate: GateKinetics = .init(kind: .none)
    ) {
        self.name = name
        self.kind = kind
        self.maximumConductance = maximumConductance
        self.reversalPotentialMillivolts = reversalPotentialMillivolts
        self.activationPower = activationPower
        self.inactivationPower = inactivationPower
        self.activationGate = activationGate
        self.inactivationGate = inactivationGate
    }
}

@frozen
public struct MechanismSet: Codable, Sendable, Hashable {
    public var name: String
    public var temperatureCelsius: Float
    public var q10: Float
    public var channels: [IonChannelDescriptor]

    public init(name: String, temperatureCelsius: Float = 37, q10: Float = 3, channels: [IonChannelDescriptor]) {
        self.name = name
        self.temperatureCelsius = temperatureCelsius
        self.q10 = q10
        self.channels = channels
    }

    public static let corticalRegularSpiking = Self(
        name: "cortical-regular-spiking",
        channels: [
            .init(
                name: "NaV-fast",
                kind: .fastSodium,
                maximumConductance: 120,
                reversalPotentialMillivolts: 50,
                activationPower: 3,
                inactivationPower: 1,
                activationGate: .init(kind: .hodgkinHuxleyM),
                inactivationGate: .init(kind: .hodgkinHuxleyH)
            ),
            .init(
                name: "KV-delayed-rectifier",
                kind: .delayedRectifierPotassium,
                maximumConductance: 36,
                reversalPotentialMillivolts: -77,
                activationPower: 4,
                activationGate: .init(kind: .hodgkinHuxleyN)
            )
        ]
    )
}

@frozen
public struct MorphologyNode: Codable, Sendable, Hashable {
    public var id: UInt32
    public var parent: UInt32?
    public var kind: SegmentKind
    public var positionMicrometers: Float4
    public var radiusMicrometers: Float

    public init(id: UInt32, parent: UInt32?, kind: SegmentKind, positionMicrometers: Float4, radiusMicrometers: Float) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.positionMicrometers = positionMicrometers
        self.radiusMicrometers = radiusMicrometers
    }
}

@frozen
public struct NeuronMorphology: Codable, Sendable, Hashable {
    public var name: String
    public var nodes: [MorphologyNode]

    public init(name: String, nodes: [MorphologyNode]) {
        self.name = name
        self.nodes = nodes
    }

    public func validate() throws {
        guard !nodes.isEmpty else { throw ModelValidationError.emptyMorphology(name) }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard byID.count == nodes.count else { throw ModelValidationError.duplicateMorphologyNode(name) }
        let roots = nodes.filter { $0.parent == nil }
        guard roots.count == 1 else { throw ModelValidationError.invalidRootCount(name, roots.count) }
        for node in nodes {
            guard node.radiusMicrometers > 0 else { throw ModelValidationError.invalidRadius(name, node.id) }
            if let parent = node.parent, byID[parent] == nil {
                throw ModelValidationError.missingParent(name, node.id, parent)
            }
        }
        var visiting = Set<UInt32>()
        var visited = Set<UInt32>()
        func visit(_ id: UInt32) throws {
            if visiting.contains(id) { throw ModelValidationError.morphologyCycle(name, id) }
            if visited.contains(id) { return }
            visiting.insert(id)
            if let parent = byID[id]?.parent { try visit(parent) }
            visiting.remove(id)
            visited.insert(id)
        }
        for node in nodes { try visit(node.id) }
    }

    public func orderedNodesAndLevels() throws -> (nodes: [MorphologyNode], levelOffsets: [UInt32]) {
        try validate()
        let sortedByID = nodes.sorted { $0.id < $1.id }
        let byID = Dictionary(uniqueKeysWithValues: sortedByID.map { ($0.id, $0) })
        var depthCache: [UInt32: Int] = [:]
        func depth(_ id: UInt32) -> Int {
            if let cached = depthCache[id] { return cached }
            let result: Int
            if let parent = byID[id]?.parent { result = depth(parent) + 1 } else { result = 0 }
            depthCache[id] = result
            return result
        }
        let ordered = sortedByID.sorted {
            let ld = depth($0.id), rd = depth($1.id)
            return ld == rd ? $0.id < $1.id : ld < rd
        }
        let maxDepth = ordered.map { depth($0.id) }.max() ?? 0
        var offsets = [UInt32](repeating: 0, count: maxDepth + 2)
        var cursor = 0
        for level in 0...maxDepth {
            offsets[level] = UInt32(cursor)
            while cursor < ordered.count && depth(ordered[cursor].id) == level { cursor += 1 }
        }
        offsets[maxDepth + 1] = UInt32(ordered.count)
        return (ordered, offsets)
    }
}

@frozen
public struct CellPrototype: Codable, Sendable, Hashable {
    public var name: String
    public var kind: CellKind
    public var defaultFidelity: FidelityLevel
    public var morphology: String?
    public var mechanismSet: String?
    public var radiusMicrometers: Float
    public var membraneCapacitance: Float
    public var leakConductance: Float
    public var leakReversalMillivolts: Float
    public var regulatoryProgram: String?
    public var glialProgram: String?

    public init(
        name: String,
        kind: CellKind,
        defaultFidelity: FidelityLevel,
        morphology: String? = nil,
        mechanismSet: String? = nil,
        radiusMicrometers: Float = 5,
        membraneCapacitance: Float = 1,
        leakConductance: Float = 0.1,
        leakReversalMillivolts: Float = -65,
        regulatoryProgram: String? = nil,
        glialProgram: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.defaultFidelity = defaultFidelity
        self.morphology = morphology
        self.mechanismSet = mechanismSet
        self.radiusMicrometers = radiusMicrometers
        self.membraneCapacitance = membraneCapacitance
        self.leakConductance = leakConductance
        self.leakReversalMillivolts = leakReversalMillivolts
        self.regulatoryProgram = regulatoryProgram
        self.glialProgram = glialProgram
    }
}

@frozen
public struct CellInstance: Codable, Sendable, Hashable {
    public var id: CellID
    public var lineage: LineageID
    public var prototype: String
    public var population: PopulationID
    public var positionMicrometers: Float4
    public var orientation: Float4
    public var fidelityOverride: FidelityLevel?

    public init(
        id: CellID,
        lineage: LineageID,
        prototype: String,
        population: PopulationID,
        positionMicrometers: Float4,
        orientation: Float4 = Float4(0, 0, 0, 1),
        fidelityOverride: FidelityLevel? = nil
    ) {
        self.id = id
        self.lineage = lineage
        self.prototype = prototype
        self.population = population
        self.positionMicrometers = positionMicrometers
        self.orientation = orientation
        self.fidelityOverride = fidelityOverride
    }
}

@frozen
public struct PopulationDescriptor: Codable, Sendable, Hashable {
    public var id: PopulationID
    public var name: String
    public var region: String
    public var tags: [String]

    public init(id: PopulationID, name: String, region: String, tags: [String] = []) {
        self.id = id
        self.name = name
        self.region = region
        self.tags = tags
    }
}
