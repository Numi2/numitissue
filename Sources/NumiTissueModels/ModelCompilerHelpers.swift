import Foundation
import NumiTissueCore

// MARK: - Compilation helpers

extension TissueModelCompiler {
    struct CompiledMechanisms {
        var sets: [GPUMechanismSet]
        var channels: [GPUChannelParameter]
    }

    func compileMechanisms(_ source: [MechanismSet]) -> CompiledMechanisms {
        var sets: [GPUMechanismSet] = []
        var channels: [GPUChannelParameter] = []
        for mechanism in source {
            let channelOffset = UInt32(channels.count)
            channels.append(contentsOf: mechanism.channels.map(GPUChannelParameter.init))
            sets.append(
                .init(
                    channelOffset: channelOffset,
                    channelCount: UInt32(mechanism.channels.count),
                    temperatureCelsius: mechanism.temperatureCelsius,
                    q10: mechanism.q10
                )
            )
        }
        return .init(sets: sets, channels: channels)
    }

    struct CompiledCellPrograms {
        var programs: [GPUCellProgram]
        var indexByPrototype: [String: UInt32]
    }

    func compileCellPrograms(
        _ prototypes: [CellPrototype],
        mechanismIndexByName: [String: UInt32],
        regulatoryIndexByName: [String: UInt32],
        glialIndexByName: [String: UInt32]
    ) throws -> CompiledCellPrograms {
        var programs: [GPUCellProgram] = []
        var indexByPrototype: [String: UInt32] = [:]
        for prototype in prototypes {
            let index = try checkedUInt32(programs.count, "cell program index")
            let mechanism = prototype.mechanismSet
                .flatMap { mechanismIndexByName[$0] } ?? UInt32.max
            let regulatory = prototype.regulatoryProgram
                .flatMap { regulatoryIndexByName[$0] } ?? UInt32.max
            let glial = prototype.glialProgram
                .flatMap { glialIndexByName[$0] } ?? UInt32.max
            programs.append(
                .init(
                    prototype: prototype,
                    mechanismIndex: mechanism,
                    regulatoryIndex: regulatory,
                    glialIndex: glial
                )
            )
            indexByPrototype[prototype.name] = index
        }
        return .init(programs: programs, indexByPrototype: indexByPrototype)
    }

    struct CompiledRegulation {
        var programs: [GPURegulatoryProgram]
        var matrix: [Float4]
        var biases: [Float]
        var transitions: [GPUFateTransition]
        var growth: [GPUGrowthProgram]
    }

    func compileRegulatoryPrograms(
        _ source: [RegulatoryProgram]
    ) -> CompiledRegulation {
        var programs: [GPURegulatoryProgram] = []
        var matrix: [Float4] = []
        var biases: [Float] = []
        var transitions: [GPUFateTransition] = []
        var growth: [GPUGrowthProgram] = []

        for program in source {
            let matrixOffset = UInt32(matrix.count)
            matrix.append(contentsOf: program.recurrentRows)
            let biasOffset = UInt32(biases.count)
            biases.append(contentsOf: program.biases)
            let transitionOffset = UInt32(transitions.count)
            transitions.append(contentsOf: program.fateTransitions.map(GPUFateTransition.init))
            let growthIndex: UInt32
            if let growthProgram = program.growthCone {
                growthIndex = UInt32(growth.count)
                growth.append(.init(growthProgram))
            } else {
                growthIndex = UInt32.max
            }
            let inferredStates = max(
                8,
                min(32, max(program.biases.count, program.recurrentRows.count))
            )
            programs.append(
                .init(
                    stateCount: UInt32(inferredStates),
                    matrixOffset: matrixOffset,
                    matrixCount: UInt32(program.recurrentRows.count),
                    biasOffset: biasOffset,
                    transitionOffset: transitionOffset,
                    transitionCount: UInt32(program.fateTransitions.count),
                    timeConstants0: program.timeConstantsSeconds0,
                    timeConstants1: program.timeConstantsSeconds1,
                    divisionHazard: program.divisionHazardPerSecond,
                    apoptosisHazard: program.apoptosisHazardPerSecond,
                    growthProgramIndex: growthIndex
                )
            )
        }
        return .init(
            programs: programs,
            matrix: matrix,
            biases: biases,
            transitions: transitions,
            growth: growth
        )
    }

    func deriveTileCoordinates(from cells: [CellInstance]) -> [TileCoordinate] {
        let coordinates = Set(cells.map { tileCoordinate(for: $0.positionMicrometers) })
        return coordinates.isEmpty
            ? [TileCoordinate(x: 0, y: 0, z: 0)]
            : coordinates.sorted()
    }

    func tileCoordinate(for position: Float4) -> TileCoordinate {
        let edge = configuration.tile.edgeMicrometers
        return TileCoordinate(
            x: Int32(floor(position.x / edge)),
            y: Int32(floor(position.y / edge)),
            z: Int32(floor(position.z / edge))
        )
    }

    static func somaMorphology(name: String, radius: Float) -> NeuronMorphology {
        .init(
            name: name,
            nodes: [
                .init(
                    id: 0,
                    parent: nil,
                    kind: .soma,
                    positionMicrometers: .zero,
                    radiusMicrometers: radius
                )
            ]
        )
    }

    func reduce(
        _ morphology: NeuronMorphology,
        maximumCompartments: Int
    ) -> NeuronMorphology {
        guard morphology.nodes.count > maximumCompartments else { return morphology }
        let byID = Dictionary(
            uniqueKeysWithValues: morphology.nodes.map { ($0.id, $0) }
        )
        let childPairs = morphology.nodes.compactMap { node in
            node.parent.map { ($0, node.id) }
        }
        let childIDs = Dictionary(grouping: childPairs, by: { $0.0 })
        guard let root = morphology.nodes.first(where: { $0.parent == nil }) else {
            return morphology
        }
        let terminals = morphology.nodes
            .filter { childIDs[$0.id] == nil }
            .sorted { $0.id < $1.id }
        var selected = Set<UInt32>([root.id])
        for terminal in terminals.prefix(maximumCompartments - 1) {
            selected.insert(terminal.id)
        }
        if selected.count < maximumCompartments {
            let ordered = morphology.nodes.sorted { $0.id < $1.id }
            let step = max(1, ordered.count / maximumCompartments)
            for index in stride(from: 0, to: ordered.count, by: step) {
                selected.insert(ordered[index].id)
                if selected.count == maximumCompartments { break }
            }
        }
        let selectedNodes = morphology.nodes.compactMap { node -> MorphologyNode? in
            guard selected.contains(node.id) else { return nil }
            var result = node
            var parent = node.parent
            while let current = parent, !selected.contains(current) {
                parent = byID[current]?.parent
            }
            result.parent = parent
            return result
        }
        return .init(name: morphology.name + "-reduced", nodes: selectedNodes)
    }

    func level(of localIndex: Int, offsets: [UInt32]) -> Int {
        guard offsets.count > 1 else { return 0 }
        var lower = 0
        var upper = offsets.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if UInt32(localIndex) >= offsets[middle] {
                lower = middle
            } else {
                upper = middle
            }
        }
        return lower
    }

    func compileChildAdjacency(
        orderedNodes: [MorphologyNode],
        localIndexByNode: [UInt32: UInt32],
        compartmentOffset: UInt32,
        compartments: inout [GPUCompartmentState],
        childIndices: inout [UInt32]
    ) {
        var childrenByLocalIndex: [[UInt32]] = Array(
            repeating: [],
            count: orderedNodes.count
        )
        for node in orderedNodes {
            guard let parentID = node.parent,
                  let parentLocal = localIndexByNode[parentID],
                  let childLocal = localIndexByNode[node.id] else { continue }
            childrenByLocalIndex[Int(parentLocal)].append(
                compartmentOffset + childLocal
            )
        }
        for localIndex in orderedNodes.indices {
            let offset = UInt32(childIndices.count)
            let children = childrenByLocalIndex[localIndex].sorted()
            childIndices.append(contentsOf: children)
            let global = Int(compartmentOffset) + localIndex
            compartments[global].topology.y = offset
            compartments[global].topology.z = UInt32(children.count)
        }
    }

    func normalizeQuaternion(_ q: Float4) -> Float4 {
        let magnitude = sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
        guard magnitude > 1e-8 else { return Float4(0, 0, 0, 1) }
        return q / magnitude
    }

    func rotate(_ vector: Float4, by q: Float4) -> Float4 {
        let u = SIMD3<Float>(q.x, q.y, q.z)
        let v = SIMD3<Float>(vector.x, vector.y, vector.z)
        let uv = cross(u, v)
        let uuv = cross(u, uv)
        let result = v + ((uv * q.w) + uuv) * 2
        return Float4(result.x, result.y, result.z, 0)
    }

    func cross(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}
