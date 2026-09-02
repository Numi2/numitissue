import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct CircuitNeuronInput: Sendable {
    public var nodeID: UInt64
    public var morphology: SWCMorphology
    public var positionOffsetMicrometers: SIMD3<Double>
    public var typeIndex: UInt16
    public var developmentalState: UInt16
    public var fidelity: FidelityLevel
    public var tileOverride: TileCoordinate?
    public var metadata: [String: String]

    public init(
        nodeID: UInt64,
        morphology: SWCMorphology,
        positionOffsetMicrometers: SIMD3<Double> = .zero,
        typeIndex: UInt16 = 0,
        developmentalState: UInt16 = 0,
        fidelity: FidelityLevel = .detailedNeuron,
        tileOverride: TileCoordinate? = nil,
        metadata: [String: String] = [:]
    ) {
        self.nodeID = nodeID
        self.morphology = morphology
        self.positionOffsetMicrometers = positionOffsetMicrometers
        self.typeIndex = typeIndex
        self.developmentalState = developmentalState
        self.fidelity = fidelity
        self.tileOverride = tileOverride
        self.metadata = metadata
    }
}

public struct CircuitConnectionInput: Sendable, Hashable, Codable {
    public var edgeID: UInt64
    public var sourceNodeID: UInt64
    public var targetNodeID: UInt64
    public var sourceMorphologyNodeID: Int?
    public var targetMorphologyNodeID: Int?
    public var parameterIndex: UInt16
    public var flags: UInt16
    public var delayMilliseconds: Double
    public var weight: Double

    public init(
        edgeID: UInt64,
        sourceNodeID: UInt64,
        targetNodeID: UInt64,
        sourceMorphologyNodeID: Int? = nil,
        targetMorphologyNodeID: Int? = nil,
        parameterIndex: UInt16 = 0,
        flags: UInt16 = 0,
        delayMilliseconds: Double,
        weight: Double
    ) {
        self.edgeID = edgeID
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.sourceMorphologyNodeID = sourceMorphologyNodeID
        self.targetMorphologyNodeID = targetMorphologyNodeID
        self.parameterIndex = parameterIndex
        self.flags = flags
        self.delayMilliseconds = delayMilliseconds
        self.weight = weight
    }
}

public struct CircuitRuntimeCompilerConfiguration: Sendable, Hashable, Codable {
    public var tileEdgeMicrometers: Double
    public var cellIDBase: UInt64
    public var segmentIDBase: UInt64
    public var compartmentIDBase: UInt64
    public var synapseIDBase: UInt64
    public var membraneCapacitanceMicrofaradsPerSquareCentimeter: Double
    public var axialResistivityOhmCentimeters: Double
    public var restingVoltageMillivolts: Float
    public var defaultMechanismStateCount: Int
    public var fieldResolution: Int
    public var capacityScale: Double

    public init(
        tileEdgeMicrometers: Double = 200,
        cellIDBase: UInt64 = 1,
        segmentIDBase: UInt64 = 1,
        compartmentIDBase: UInt64 = 1,
        synapseIDBase: UInt64 = 1,
        membraneCapacitanceMicrofaradsPerSquareCentimeter: Double = 1,
        axialResistivityOhmCentimeters: Double = 100,
        restingVoltageMillivolts: Float = -65,
        defaultMechanismStateCount: Int = 16,
        fieldResolution: Int = 32,
        capacityScale: Double = 1.25
    ) {
        self.tileEdgeMicrometers = tileEdgeMicrometers
        self.cellIDBase = cellIDBase
        self.segmentIDBase = segmentIDBase
        self.compartmentIDBase = compartmentIDBase
        self.synapseIDBase = synapseIDBase
        self.membraneCapacitanceMicrofaradsPerSquareCentimeter = membraneCapacitanceMicrofaradsPerSquareCentimeter
        self.axialResistivityOhmCentimeters = axialResistivityOhmCentimeters
        self.restingVoltageMillivolts = restingVoltageMillivolts
        self.defaultMechanismStateCount = defaultMechanismStateCount
        self.fieldResolution = fieldResolution
        self.capacityScale = capacityScale
    }

    public func validated() throws -> Self {
        guard tileEdgeMicrometers.isFinite, tileEdgeMicrometers > 0 else { throw CircuitRuntimeCompileError.invalidConfiguration("tile edge") }
        guard membraneCapacitanceMicrofaradsPerSquareCentimeter.isFinite, membraneCapacitanceMicrofaradsPerSquareCentimeter > 0 else { throw CircuitRuntimeCompileError.invalidConfiguration("membrane capacitance") }
        guard axialResistivityOhmCentimeters.isFinite, axialResistivityOhmCentimeters > 0 else { throw CircuitRuntimeCompileError.invalidConfiguration("axial resistivity") }
        guard defaultMechanismStateCount >= 0, defaultMechanismStateCount <= 4_096 else { throw CircuitRuntimeCompileError.invalidConfiguration("mechanism state count") }
        guard fieldResolution > 0, fieldResolution <= 128 else { throw CircuitRuntimeCompileError.invalidConfiguration("field resolution") }
        guard capacityScale >= 1, capacityScale.isFinite else { throw CircuitRuntimeCompileError.invalidConfiguration("capacity scale") }
        return self
    }
}

public struct CompiledCircuitRuntime: Sendable {
    public var state: TissueRuntimeState
    public var cellIDByNodeID: [UInt64: CellID]
    public var compartmentIDByNodeAndMorphologyNode: [CircuitCompartmentKey: CompartmentID]
    public var metadataByCellID: [CellID: [String: String]]

    public init(
        state: TissueRuntimeState,
        cellIDByNodeID: [UInt64: CellID],
        compartmentIDByNodeAndMorphologyNode: [CircuitCompartmentKey: CompartmentID],
        metadataByCellID: [CellID: [String: String]]
    ) {
        self.state = state
        self.cellIDByNodeID = cellIDByNodeID
        self.compartmentIDByNodeAndMorphologyNode = compartmentIDByNodeAndMorphologyNode
        self.metadataByCellID = metadataByCellID
    }
}

public struct CircuitCompartmentKey: Sendable, Hashable, Codable {
    public var nodeID: UInt64
    public var morphologyNodeID: Int

    public init(nodeID: UInt64, morphologyNodeID: Int) {
        self.nodeID = nodeID
        self.morphologyNodeID = morphologyNodeID
    }
}

public enum CircuitRuntimeCompiler {
    public static func compile(
        neurons: [CircuitNeuronInput],
        connections: [CircuitConnectionInput],
        configuration: CircuitRuntimeCompilerConfiguration = CircuitRuntimeCompilerConfiguration(),
        time: TissueTime = TissueTime(),
        epoch: UInt64 = 0
    ) throws -> CompiledCircuitRuntime {
        let configuration = try configuration.validated()
        guard !neurons.isEmpty else { throw CircuitRuntimeCompileError.noNeurons }
        guard Set(neurons.map(\.nodeID)).count == neurons.count else { throw CircuitRuntimeCompileError.duplicateNodeID }
        guard Set(connections.map(\.edgeID)).count == connections.count else { throw CircuitRuntimeCompileError.duplicateEdgeID }

        let ordered = neurons.sorted { $0.nodeID < $1.nodeID }
        var builder = TissueRuntimeStateBuilder(time: time, epoch: epoch, fieldResolution: configuration.fieldResolution)
        var cellIDByNodeID: [UInt64: CellID] = [:]
        var compartmentIDByKey: [CircuitCompartmentKey: CompartmentID] = [:]
        var firstCompartmentByNodeID: [UInt64: CompartmentID] = [:]
        var metadataByCellID: [CellID: [String: String]] = [:]
        var nextSegmentID = configuration.segmentIDBase
        var nextCompartmentID = configuration.compartmentIDBase

        for (ordinal, input) in ordered.enumerated() {
            let morphology = try input.morphology.validated()
            let nodes = try topologicallyOrdered(morphology.nodes)
            let nodeIndexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
            let cellIDRaw = try checkedAdd(configuration.cellIDBase, UInt64(ordinal))
            let cellID = CellID(rawValue: cellIDRaw)
            let root = nodes.first(where: { $0.kind == .soma }) ?? nodes.first!
            let rootPosition = root.positionMicrometers + input.positionOffsetMicrometers
            let tile = input.tileOverride ?? tileCoordinate(position: rootPosition, edge: configuration.tileEdgeMicrometers)
            let largestRootRadius = nodes.filter { $0.parentID == nil || $0.kind == .soma }.map(\.radiusMicrometers).max() ?? root.radiusMicrometers
            try builder.addCell(RuntimeCellBlueprint(
                id: cellID,
                lineage: LineageID(rawValue: cellIDRaw),
                tile: tile,
                typeIndex: input.typeIndex,
                developmentalState: input.developmentalState,
                fidelity: input.fidelity,
                position: float4(rootPosition),
                semiAxes: Float4(Float(largestRootRadius), Float(largestRootRadius), Float(largestRootRadius), 0)
            ))

            var segments: [RuntimeSegmentBlueprint] = []
            var compartments: [RuntimeCompartmentBlueprint] = []
            var segmentCompartments: [Int?] = []
            segments.reserveCapacity(nodes.count)
            compartments.reserveCapacity(nodes.count)
            segmentCompartments.reserveCapacity(nodes.count)

            for (localIndex, node) in nodes.enumerated() {
                let parentIndex = node.parentID.flatMap { nodeIndexByID[$0] }
                let parent = parentIndex.map { nodes[$0] }
                let start = (parent?.positionMicrometers ?? node.positionMicrometers) + input.positionOffsetMicrometers
                let end = node.positionMicrometers + input.positionOffsetMicrometers
                let lengthMicrometers = max(vectorLength(end - start), max(node.radiusMicrometers * 0.1, 0.01))
                let radiusMicrometers = max(node.radiusMicrometers, 0.001)
                let areaSquareCentimeters = 2 * Double.pi * radiusMicrometers * lengthMicrometers * 1e-8
                let capacitanceNanofarads = configuration.membraneCapacitanceMicrofaradsPerSquareCentimeter * areaSquareCentimeters * 1_000
                let axialConductanceMicrosiemens: Double
                if parentIndex == nil {
                    axialConductanceMicrosiemens = 0
                } else {
                    let radiusCentimeters = radiusMicrometers * 1e-4
                    let lengthCentimeters = lengthMicrometers * 1e-4
                    let resistanceOhms = configuration.axialResistivityOhmCentimeters * lengthCentimeters / (Double.pi * radiusCentimeters * radiusCentimeters)
                    axialConductanceMicrosiemens = 1e6 / max(resistanceOhms, 1e-12)
                }
                let segmentID = SegmentID(rawValue: nextSegmentID)
                let compartmentID = CompartmentID(rawValue: nextCompartmentID)
                nextSegmentID = try checkedAdd(nextSegmentID, 1)
                nextCompartmentID = try checkedAdd(nextCompartmentID, 1)

                segments.append(RuntimeSegmentBlueprint(
                    id: segmentID,
                    parentLocalIndex: parentIndex,
                    type: UInt16(clamping: node.kind.rawValue),
                    start: float4(start),
                    end: float4(end),
                    radiusMicrometers: Float(radiusMicrometers)
                ))
                compartments.append(RuntimeCompartmentBlueprint(
                    id: compartmentID,
                    parentLocalIndex: parentIndex,
                    voltageMillivolts: configuration.restingVoltageMillivolts,
                    capacitanceNanofarads: Float(max(capacitanceNanofarads, 1e-8)),
                    axialConductanceMicrosiemens: Float(axialConductanceMicrosiemens),
                    mechanismState: Array(repeating: 0, count: configuration.defaultMechanismStateCount)
                ))
                segmentCompartments.append(localIndex)
                compartmentIDByKey[CircuitCompartmentKey(nodeID: input.nodeID, morphologyNodeID: node.id)] = compartmentID
                if firstCompartmentByNodeID[input.nodeID] == nil || node.kind == .soma {
                    firstCompartmentByNodeID[input.nodeID] = compartmentID
                }
            }
            try builder.addNeuron(RuntimeNeuronBlueprint(
                cellID: cellID,
                segments: segments,
                compartments: compartments,
                segmentCompartmentLocalIndices: segmentCompartments
            ))
            cellIDByNodeID[input.nodeID] = cellID
            metadataByCellID[cellID] = input.metadata.merging(morphology.metadata, uniquingKeysWith: { explicit, _ in explicit })
        }

        for (ordinal, connection) in connections.sorted(by: { $0.edgeID < $1.edgeID }).enumerated() {
            guard cellIDByNodeID[connection.sourceNodeID] != nil else { throw CircuitRuntimeCompileError.unknownSourceNode(connection.sourceNodeID) }
            guard cellIDByNodeID[connection.targetNodeID] != nil else { throw CircuitRuntimeCompileError.unknownTargetNode(connection.targetNodeID) }
            let source = connection.sourceMorphologyNodeID.flatMap {
                compartmentIDByKey[CircuitCompartmentKey(nodeID: connection.sourceNodeID, morphologyNodeID: $0)]
            } ?? firstCompartmentByNodeID[connection.sourceNodeID]
            let target = connection.targetMorphologyNodeID.flatMap {
                compartmentIDByKey[CircuitCompartmentKey(nodeID: connection.targetNodeID, morphologyNodeID: $0)]
            } ?? firstCompartmentByNodeID[connection.targetNodeID]
            guard let source else { throw CircuitRuntimeCompileError.missingCompartment(connection.sourceNodeID) }
            guard let target else { throw CircuitRuntimeCompileError.missingCompartment(connection.targetNodeID) }
            guard connection.weight.isFinite else { throw CircuitRuntimeCompileError.invalidWeight(connection.edgeID) }
            guard connection.delayMilliseconds.isFinite, connection.delayMilliseconds >= 0 else { throw CircuitRuntimeCompileError.invalidDelay(connection.edgeID) }
            let delayTicks = UInt32(clamping: Int((connection.delayMilliseconds / 0.025).rounded()))
            try builder.addSynapse(RuntimeSynapseBlueprint(
                id: SynapseID(rawValue: try checkedAdd(configuration.synapseIDBase, UInt64(ordinal))),
                sourceCompartmentID: source,
                targetCompartmentID: target,
                parameterIndex: connection.parameterIndex,
                flags: connection.flags,
                delayTicks: delayTicks,
                weight: Float(connection.weight)
            ))
        }

        return CompiledCircuitRuntime(
            state: try builder.build(capacityScale: configuration.capacityScale),
            cellIDByNodeID: cellIDByNodeID,
            compartmentIDByNodeAndMorphologyNode: compartmentIDByKey,
            metadataByCellID: metadataByCellID
        )
    }

    public static func compileSONATA(
        nodes: [SONATANodePopulation],
        edges: [SONATAEdgePopulation],
        morphologyProvider: @Sendable (SONATANodeRecord) async throws -> SWCMorphology,
        configuration: CircuitRuntimeCompilerConfiguration = CircuitRuntimeCompilerConfiguration(),
        time: TissueTime = TissueTime(),
        epoch: UInt64 = 0
    ) async throws -> CompiledCircuitRuntime {
        try SONATAValidator.validate(nodes: nodes, edges: edges)
        let records = nodes.flatMap(\.records).sorted { $0.nodeID < $1.nodeID }
        var neurons: [CircuitNeuronInput] = []
        neurons.reserveCapacity(records.count)
        for record in records {
            let position = SIMD3(
                record.attributes["x"]?.doubleValue ?? 0,
                record.attributes["y"]?.doubleValue ?? 0,
                record.attributes["z"]?.doubleValue ?? 0
            )
            let type = UInt16(clamping: Int(record.nodeTypeID))
            let fidelityRaw = record.attributes["numitissue_fidelity"]?.intValue.flatMap(Int.init) ?? FidelityLevel.detailedNeuron.rawValue
            let fidelity = FidelityLevel(rawValue: fidelityRaw) ?? .detailedNeuron
            neurons.append(CircuitNeuronInput(
                nodeID: record.nodeID,
                morphology: try await morphologyProvider(record),
                positionOffsetMicrometers: position,
                typeIndex: type,
                fidelity: fidelity,
                metadata: record.attributes.compactMapValues(\.stringValue).merging(["population": record.population], uniquingKeysWith: { explicit, _ in explicit })
            ))
        }

        let connections = edges.flatMap(\.records).map { record in
            CircuitConnectionInput(
                edgeID: record.edgeID,
                sourceNodeID: record.sourceNodeID,
                targetNodeID: record.targetNodeID,
                sourceMorphologyNodeID: integerAttribute(record.attributes, keys: ["source_section_id", "efferent_section_id"]),
                targetMorphologyNodeID: integerAttribute(record.attributes, keys: ["target_section_id", "afferent_section_id", "sec_id"]),
                parameterIndex: UInt16(clamping: Int(record.edgeTypeID)),
                flags: UInt16(clamping: integerAttribute(record.attributes, keys: ["flags"]) ?? 0),
                delayMilliseconds: floatingAttribute(record.attributes, keys: ["delay", "delay_ms"]) ?? 0.025,
                weight: floatingAttribute(record.attributes, keys: ["syn_weight", "weight", "conductance"]) ?? 1
            )
        }
        return try compile(neurons: neurons, connections: connections, configuration: configuration, time: time, epoch: epoch)
    }

    public static func neuronInput(
        nodeID: UInt64,
        neuroMLCell: NMLCellDefinition,
        positionOffsetMicrometers: SIMD3<Double> = .zero,
        typeIndex: UInt16 = 0,
        fidelity: FidelityLevel = .detailedNeuron
    ) throws -> CircuitNeuronInput {
        CircuitNeuronInput(
            nodeID: nodeID,
            morphology: try neuroMLCell.swcMorphology(),
            positionOffsetMicrometers: positionOffsetMicrometers,
            typeIndex: typeIndex,
            fidelity: fidelity,
            metadata: ["format": "NeuroML", "component": neuroMLCell.id]
        )
    }

    private static func topologicallyOrdered(_ nodes: [SWCNode]) throws -> [SWCNode] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        var children: [Int?: [Int]] = [:]
        for node in nodes { children[node.parentID, default: []].append(node.id) }
        for key in children.keys { children[key]?.sort() }
        var result: [SWCNode] = []
        var active = Set<Int>()
        var complete = Set<Int>()
        func visit(_ id: Int) throws {
            guard let node = byID[id] else { return }
            if complete.contains(id) { return }
            guard active.insert(id).inserted else { throw CircuitRuntimeCompileError.morphologyCycle(id) }
            if let parent = node.parentID { try visit(parent) }
            active.remove(id)
            if complete.insert(id).inserted { result.append(node) }
        }
        for id in nodes.map(\.id).sorted() { try visit(id) }
        return result
    }

    private static func tileCoordinate(position: SIMD3<Double>, edge: Double) -> TileCoordinate {
        TileCoordinate(
            Int32(clamping: Int(floor(position.x / edge))),
            Int32(clamping: Int(floor(position.y / edge))),
            Int32(clamping: Int(floor(position.z / edge)))
        )
    }

    private static func float4(_ value: SIMD3<Double>) -> Float4 { Float4(Float(value.x), Float(value.y), Float(value.z), 0) }
    private static func vectorLength(_ value: SIMD3<Double>) -> Double { sqrt(value.x * value.x + value.y * value.y + value.z * value.z) }

    private static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CircuitRuntimeCompileError.identifierOverflow }
        return value
    }

    private static func integerAttribute(_ attributes: [String: SONATAValue], keys: [String]) -> Int? {
        for key in keys {
            if let value = attributes[key]?.intValue { return Int(exactly: value) }
        }
        return nil
    }

    private static func floatingAttribute(_ attributes: [String: SONATAValue], keys: [String]) -> Double? {
        for key in keys {
            if let value = attributes[key]?.doubleValue { return value }
        }
        return nil
    }
}

public enum CircuitRuntimeCompileError: Error, Sendable, CustomStringConvertible {
    case noNeurons
    case duplicateNodeID
    case duplicateEdgeID
    case unknownSourceNode(UInt64)
    case unknownTargetNode(UInt64)
    case missingCompartment(UInt64)
    case invalidWeight(UInt64)
    case invalidDelay(UInt64)
    case morphologyCycle(Int)
    case identifierOverflow
    case invalidConfiguration(String)

    public var description: String {
        switch self {
        case .noNeurons: return "Circuit contains no neurons"
        case .duplicateNodeID: return "Circuit contains duplicate node IDs"
        case .duplicateEdgeID: return "Circuit contains duplicate edge IDs"
        case .unknownSourceNode(let id): return "Connection references unknown source node \(id)"
        case .unknownTargetNode(let id): return "Connection references unknown target node \(id)"
        case .missingCompartment(let id): return "Node \(id) has no electrical compartment"
        case .invalidWeight(let id): return "Connection \(id) has a non-finite weight"
        case .invalidDelay(let id): return "Connection \(id) has an invalid delay"
        case .morphologyCycle(let id): return "Morphology cycle at SWC node \(id)"
        case .identifierOverflow: return "Runtime entity identifier overflow"
        case .invalidConfiguration(let value): return "Invalid circuit compiler configuration: \(value)"
        }
    }
}
