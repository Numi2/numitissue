import Foundation
import NumiTissueCore
import NumiTissueModels

extension CPUReferenceTissueBackend {
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

    /// Executes the bounded reaction layout used by the legacy reference working state. The
    /// reaction table is shared with the Metal representation: reactant/product indices are local
    /// to a domain, and kinetics.x/y are forward/reverse mass-action rates. Keeping this fallback
    /// here prevents an incomplete helper path from silently skipping molecular state updates.
    func updateMolecularDomains(
        transactionIndex: UInt64,
        blockIndex: UInt32,
        dtSeconds: Float,
        model: CompiledTissueModel,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        _ = transactionIndex
        _ = blockIndex
        guard dtSeconds.isFinite, dtSeconds > 0 else { return }
        for domainIndex in state.microdomains.indices {
            var header = state.microdomains[domainIndex]
            let speciesCount = Int(header.countsAndOffsets0.x)
            let reactionCount = Int(header.countsAndOffsets0.y)
            let speciesOffset = Int(header.countsAndOffsets0.z)
            let reactionOffset = Int(header.countsAndOffsets0.w)
            let voxelCount = max(Int(header.countsAndOffsets1.x), 1)
            guard speciesCount > 0,
                  reactionCount >= 0,
                  speciesOffset >= 0,
                  reactionOffset >= 0,
                  speciesOffset + speciesCount * voxelCount <= state.molecularSpecies.count,
                  reactionOffset + reactionCount <= model.molecularReactions.count else { continue }

            var totalPropensity: Float = 0
            for voxel in 0..<voxelCount {
                let base = speciesOffset + voxel * speciesCount
                var delta = [Float](repeating: 0, count: speciesCount)
                for reactionIndex in 0..<reactionCount {
                    let reaction = model.molecularReactions[reactionOffset + reactionIndex]
                    let reactantIndices = [reaction.reactants.x, reaction.reactants.y, reaction.reactants.z, reaction.reactants.w]
                    let productIndices = [reaction.products.x, reaction.products.y, reaction.products.z, reaction.products.w]
                    let reactantStoichiometry = [reaction.stoichiometry.x, reaction.stoichiometry.y]
                    let productStoichiometry = [reaction.stoichiometry.z, reaction.stoichiometry.w]
                    var forward = max(reaction.kinetics.x, 0)
                    var reverse = max(reaction.kinetics.y, 0)
                    for participant in 0..<2 {
                        let index = Int(reactantIndices[participant])
                        let order = max(reactantStoichiometry[participant], 0)
                        if index == Int(UInt32.max) || index >= speciesCount || order == 0 { continue }
                        forward *= Float(Foundation.pow(Swift.max(Double(state.molecularSpecies[base + index].values.x), 0.0), Double(order)))
                    }
                    for participant in 0..<2 {
                        let index = Int(productIndices[participant])
                        let order = max(productStoichiometry[participant], 0)
                        if index == Int(UInt32.max) || index >= speciesCount || order == 0 { continue }
                        reverse *= Float(Foundation.pow(Swift.max(Double(state.molecularSpecies[base + index].values.x), 0.0), Double(order)))
                    }
                    let net = Float(forward - reverse)
                    guard net.isFinite else { continue }
                    totalPropensity += abs(net)
                    for participant in 0..<2 {
                        let index = Int(reactantIndices[participant])
                        let coefficient = max(reactantStoichiometry[participant], 0)
                        if index >= 0, index < speciesCount, index != Int(UInt32.max) {
                            delta[index] -= net * coefficient * dtSeconds
                        }
                    }
                    for participant in 0..<2 {
                        let index = Int(productIndices[participant])
                        let coefficient = max(productStoichiometry[participant], 0)
                        if index >= 0, index < speciesCount, index != Int(UInt32.max) {
                            delta[index] += net * coefficient * dtSeconds
                        }
                    }
                }
                for index in 0..<speciesCount {
                    let current = state.molecularSpecies[base + index].values.x
                    let updated = current + delta[index]
                    state.molecularSpecies[base + index].values.x = updated.isFinite ? max(updated, 0) : current
                }
            }
            header.timeAndError.x += dtSeconds
            header.timeAndError.y = dtSeconds
            header.timeAndError.w = totalPropensity
            state.microdomains[domainIndex] = header
            accumulator.metrics.molecularReactions &+= UInt64(reactionCount)
        }
    }

    /// Updates ATP/stress from the local oxygen/glucose field while retaining the explicit input
    /// boundary as the fallback for cells without a valid field voxel.
    func updateMetabolismAndGlia(
        dtMilliseconds: Float,
        input: TissueInput,
        model: CompiledTissueModel,
        topology: ReferenceStaticTopology,
        state: inout ReferenceWorkingState,
        accumulator: inout ReferenceStepAccumulator
    ) {
        _ = model
        _ = topology
        let dtSeconds = max(dtMilliseconds, 0) / 1_000
        for index in state.cells.indices {
            var cell = state.cells[index]
            let tileIndexValue = state.cellToTile.indices.contains(index) ? state.cellToTile[index] : UInt32.max
            let tileIndex = safeIndex(tileIndexValue, count: state.tileHeaders.count)
            let fieldIndex = tileIndex.map { Int(state.tileHeaders[$0].offsets1.x) }
            let oxygen = fieldIndex.flatMap { $0 < state.fields.count ? state.fields[$0][.oxygen] : nil } ?? input.metabolicBoundary.oxygen
            let glucose = fieldIndex.flatMap { $0 < state.fields.count ? state.fields[$0][.glucose] : nil } ?? input.metabolicBoundary.glucose
            let oxygenStress = min(max(input.metabolicBoundary.oxygen - oxygen, 0), 1)
            let glucoseStress = min(max(input.metabolicBoundary.glucose - glucose, 0), 1)
            let demand = max(cell.metabolism.x, 0)
            cell.metabolism.y = oxygenStress
            cell.metabolism.z = glucoseStress
            cell.metabolism.x = max(0, demand + dtSeconds * (min(oxygen, glucose) - demand))
            cell.metabolism.w = min(max(cell.metabolism.w + dtSeconds * (oxygenStress + glucoseStress), 0), 1)
            state.cells[index] = cell
        }
        _ = accumulator
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
