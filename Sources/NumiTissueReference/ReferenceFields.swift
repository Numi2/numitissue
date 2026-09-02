import Foundation
import NumiTissueCore
import NumiTissueModels

extension ReferenceTissueRuntime {
    func runFieldAndMolecularBlock(
        transactionIndex: UInt64,
        blockIndex: UInt32,
        input: TissueInput,
        model: CompiledTissueModel,
        topology: ReferenceStaticTopology,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        let dtMilliseconds = Float(model.configuration.scheduler.eventBlockMicroseconds) / 1_000
        updateExtracellularFields(
            dtMilliseconds: dtMilliseconds,
            input: input,
            model: model,
            topology: topology,
            state: &state,
            accumulator: &accumulator
        )
        updateMolecularDomains(
            transactionIndex: transactionIndex,
            blockIndex: blockIndex,
            dtSeconds: dtMilliseconds / 1_000,
            model: model,
            state: &state,
            accumulator: &accumulator
        )
        if blockIndex.isMultiple(of: 4) {
            updateMetabolismAndGlia(
                dtMilliseconds: dtMilliseconds * 4,
                input: input,
                model: model,
                topology: topology,
                state: &state,
                accumulator: &accumulator
            )
        }
    }

    func updateExtracellularFields(
        dtMilliseconds: Float,
        input: TissueInput,
        model: CompiledTissueModel,
        topology: ReferenceStaticTopology,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        let edge = Int(model.configuration.tile.fieldGridEdge)
        let voxelsPerTile = edge * edge * edge
        guard state.fields.count == model.tileCoordinates.count * voxelsPerTile else { return }
        var next = state.fields

        if accumulator.metrics.fieldVoxelsUpdated == 0 {
            accumulator.fieldMassBefore = fieldMasses(state.fields)
        }

        for tileIndex in model.tileCoordinates.indices {
            let coordinate = model.tileCoordinates[tileIndex]
            for z in 0..<edge {
                for y in 0..<edge {
                    for x in 0..<edge {
                        let index = fieldIndex(tile: tileIndex, x: x, y: y, z: z, edge: edge)
                        let current = state.fields[index]
                        var updated = current
                        for channel in FieldChannel.allCases {
                            let parameterIndex = Int(channel.rawValue)
                            guard parameterIndex < model.fieldParameters.count else { continue }
                            let parameter = model.fieldParameters[parameterIndex]
                            let alpha = min(max(parameter.dynamics.x, 0), 1.0 / 6.0)
                            var neighborSum: Float = 0
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x - 1, y: y, z: z, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x + 1, y: y, z: z, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x, y: y - 1, z: z, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x, y: y + 1, z: z, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x, y: y, z: z - 1, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            neighborSum += fieldValue(
                                channel: channel, tile: tileIndex, coordinate: coordinate,
                                x: x, y: y, z: z + 1, edge: edge,
                                topology: topology, model: model, fields: state.fields,
                                boundary: input.metabolicBoundary
                            )
                            let value = current[channel]
                            var result = value + alpha * (neighborSum - 6 * value)
                            result = parameter.dynamics.z +
                                (result - parameter.dynamics.z) * parameter.dynamics.y
                            if channel == .oxygen {
                                result += input.metabolicBoundary.perfusion * dtMilliseconds * 1e-4 *
                                    (input.metabolicBoundary.oxygen - result)
                            } else if channel == .glucose {
                                result += input.metabolicBoundary.perfusion * dtMilliseconds * 1e-4 *
                                    (input.metabolicBoundary.glucose - result)
                            }
                            updated[channel] = min(max(result, parameter.bounds.x), parameter.bounds.y)
                        }
                        next[index] = updated
                    }
                }
            }
        }
        state.fields = next
        accumulator.metrics.fieldVoxelsUpdated &+= UInt64(state.fields.count)
        accumulator.fieldMassAfter = fieldMasses(state.fields)
    }

    func fieldValue(
        channel: FieldChannel,
        tile: Int,
        coordinate: TileCoordinate,
        x: Int,
        y: Int,
        z: Int,
        edge: Int,
        topology: ReferenceStaticTopology,
        model: CompiledTissueModel,
        fields: [GPUFieldVoxel],
        boundary: MetabolicBoundary
    ) -> Float {
        var localX = x
        var localY = y
        var localZ = z
        var dx: Int32 = 0
        var dy: Int32 = 0
        var dz: Int32 = 0
        if localX < 0 { localX += edge; dx = -1 }
        else if localX >= edge { localX -= edge; dx = 1 }
        if localY < 0 { localY += edge; dy = -1 }
        else if localY >= edge { localY -= edge; dy = 1 }
        if localZ < 0 { localZ += edge; dz = -1 }
        else if localZ >= edge { localZ -= edge; dz = 1 }

        if dx == 0, dy == 0, dz == 0 {
            return fields[fieldIndex(tile: tile, x: localX, y: localY, z: localZ, edge: edge)][channel]
        }
        let neighborCoordinate = coordinate.neighbor(dx: dx, dy: dy, dz: dz)
        if let neighborTile = topology.tileIndexByCoordinate[neighborCoordinate] {
            return fields[fieldIndex(tile: neighborTile, x: localX, y: localY, z: localZ, edge: edge)][channel]
        }
        switch channel {
        case .oxygen: return boundary.oxygen
        case .glucose: return boundary.glucose
        default:
            let ownIndex = fieldIndex(
                tile: tile,
                x: min(max(x, 0), edge - 1),
                y: min(max(y, 0), edge - 1),
                z: min(max(z, 0), edge - 1),
                edge: edge
            )
            return fields[ownIndex][channel]
        }
    }

    @inline(__always)
    func fieldIndex(tile: Int, x: Int, y: Int, z: Int, edge: Int) -> Int {
        tile * edge * edge * edge + (z * edge + y) * edge + x
    }

    func fieldMasses(_ fields: [GPUFieldVoxel]) -> [Double] {
        var result = [Double](repeating: 0, count: FieldChannel.allCases.count)
        for voxel in fields {
            for channel in FieldChannel.allCases {
                result[Int(channel.rawValue)] += Double(voxel[channel])
            }
        }
        return result
    }

}
