import Foundation
import NumiTissueCore

// MARK: - Synapses and routes

extension TissueModelCompiler {
    struct SynapseRecord {
        var id: SynapseID
        var prototype: SynapsePrototype
        var parameterIndex: UInt32
        var sourceCompartment: UInt32
        var targetCompartment: UInt32
        var targetTile: Int
        var weight: Float
        var delayTicks: UInt32
    }

    struct CompiledSynapses {
        var synapses: [GPUSynapseState]
        var compartmentAdjacency: [GPUCompartmentAdjacency]
        var routes: [GPULongRangeRoute]
    }

    func compileSynapses(
        connections: [SynapseConnection],
        synapsePrototypeByName: [String: SynapsePrototype],
        synapseParameterIndexByName: [String: UInt32],
        cellSpikeSource: [CellID: UInt32],
        cellCompartmentMap: [CellID: [UInt32: UInt32]],
        cellOriginalParentMap: [CellID: [UInt32: UInt32?]],
        cellTileIndex: [CellID: Int],
        fastQuantumMilliseconds: Float,
        tileMembership: inout [CompiledTileMembership],
        compartmentCount: Int,
        neuronIndexBySpikeSource: [UInt32: UInt32],
        neuronRouting: inout [GPUNeuronRouting]
    ) throws -> CompiledSynapses {
        var records: [SynapseRecord] = []
        records.reserveCapacity(connections.count)
        for connection in connections {
            guard let prototype = synapsePrototypeByName[connection.prototype],
                  let parameterIndex = synapseParameterIndexByName[connection.prototype],
                  let source = cellSpikeSource[connection.presynapticCell],
                  let targetMap = cellCompartmentMap[connection.postsynapticCell],
                  let targetTile = cellTileIndex[connection.postsynapticCell] else {
                throw ModelValidationError.invalidSynapse(connection.id.description)
            }
            let target = resolveTargetCompartment(
                requestedNode: connection.postsynapticMorphologyNode,
                available: targetMap,
                originalParents: cellOriginalParentMap[connection.postsynapticCell] ?? [:]
            )
            guard let target else {
                throw ModelValidationError.invalidSynapse(connection.id.description)
            }
            let delayTicksDouble = Double(connection.delayMilliseconds * 1_000) /
                Double(TissueTime.quantumMicroseconds)
            guard delayTicksDouble <= Double(UInt32.max) else {
                throw ModelValidationError.invalidSynapse(
                    "\(connection.id): delay exceeds GPU representation"
                )
            }
            let delayTicks = UInt32(max(1, delayTicksDouble.rounded()))
            records.append(
                .init(
                    id: connection.id,
                    prototype: prototype,
                    parameterIndex: parameterIndex,
                    sourceCompartment: source,
                    targetCompartment: target,
                    targetTile: targetTile,
                    weight: connection.weight ?? prototype.defaultWeight,
                    delayTicks: delayTicks
                )
            )
        }

        records.sort {
            if $0.targetCompartment != $1.targetCompartment {
                return $0.targetCompartment < $1.targetCompartment
            }
            return $0.id < $1.id
        }

        var synapses: [GPUSynapseState] = []
        synapses.reserveCapacity(records.count)
        var routeRecords: [(source: UInt32, synapse: UInt32, delay: UInt32)] = []
        routeRecords.reserveCapacity(records.count)
        var adjacency = [GPUCompartmentAdjacency](
            repeating: .init(),
            count: compartmentCount
        )

        var cursor = 0
        while cursor < records.count {
            let target = records[cursor].targetCompartment
            let start = synapses.count
            while cursor < records.count && records[cursor].targetCompartment == target {
                let record = records[cursor]
                let synapseIndex = UInt32(synapses.count)
                var state = GPUSynapseState(
                    postCompartment: record.targetCompartment,
                    route: UInt32.max,
                    receptor: record.prototype.receptor,
                    weight: record.weight
                )
                state.routing.w |= record.parameterIndex << 16
                state.kinetics.y = exp(
                    -fastQuantumMilliseconds /
                        max(record.prototype.decayMilliseconds, 1e-6)
                )
                state.kinetics.z = record.prototype.reversalPotentialMillivolts
                synapses.append(state)
                tileMembership[record.targetTile].synapseIndices.append(synapseIndex)
                routeRecords.append(
                    (record.sourceCompartment, synapseIndex, record.delayTicks)
                )
                cursor += 1
            }
            adjacency[Int(target)] = .init(
                offset: UInt32(start),
                count: UInt32(synapses.count - start)
            )
        }

        routeRecords.sort {
            if $0.source != $1.source { return $0.source < $1.source }
            return $0.synapse < $1.synapse
        }
        var routes: [GPULongRangeRoute] = []
        cursor = 0
        while cursor < routeRecords.count {
            let source = routeRecords[cursor].source
            let routeStart = routes.count
            while cursor < routeRecords.count && routeRecords[cursor].source == source {
                let record = routeRecords[cursor]
                let routeIndex = UInt32(routes.count)
                routes.append(
                    .init(
                        source: source,
                        destinationStart: record.synapse,
                        destinationCount: 1,
                        delayTicks: record.delay
                    )
                )
                synapses[Int(record.synapse)].routing.y = routeIndex
                cursor += 1
            }
            if let neuronIndex = neuronIndexBySpikeSource[source] {
                neuronRouting[Int(neuronIndex)] = .init(
                    offset: UInt32(routeStart),
                    count: UInt32(routes.count - routeStart)
                )
            }
        }
        return .init(
            synapses: synapses,
            compartmentAdjacency: adjacency,
            routes: routes
        )
    }

    func resolveTargetCompartment(
        requestedNode: UInt32?,
        available: [UInt32: UInt32],
        originalParents: [UInt32: UInt32?]
    ) -> UInt32? {
        guard var requestedNode else { return available.values.min() }
        var visited = Set<UInt32>()
        while visited.insert(requestedNode).inserted {
            if let compartment = available[requestedNode] { return compartment }
            guard let optionalParent = originalParents[requestedNode],
                  let parent = optionalParent else { break }
            requestedNode = parent
        }
        return available.values.min()
    }
}
