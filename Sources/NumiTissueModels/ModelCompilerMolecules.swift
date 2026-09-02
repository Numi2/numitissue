import Foundation
import NumiTissueCore

// MARK: - Fields and molecular domains

extension TissueModelCompiler {
    struct CompiledMolecules {
        var headers: [GPUMicrodomainHeader]
        var species: [GPUMolecularSpeciesState]
        var reactions: [GPUMolecularReaction]
    }

    func checkedVoxelCount(_ edge: UInt32) throws -> Int {
        let count = UInt64(edge) * UInt64(edge) * UInt64(edge)
        guard count <= UInt64(Int.max) else {
            throw ModelValidationError.capacityExceeded("field voxel count")
        }
        return Int(count)
    }

    func initializeFields(
        tileCount: Int,
        voxelsPerTile: Int,
        descriptors: [FieldSpeciesDescriptor]
    ) -> [GPUFieldVoxel] {
        var baseline = GPUFieldVoxel(baseline: false)
        for descriptor in descriptors { baseline[descriptor.channel] = descriptor.baseline }
        return [GPUFieldVoxel](
            repeating: baseline,
            count: tileCount * voxelsPerTile
        )
    }

    func compileMolecularDomains(
        domains: [MolecularDomainInstance],
        networkByName: [String: MolecularNetwork],
        cellIndexByID: [CellID: UInt32],
        cellTileIndex: [CellID: Int],
        cellCompartmentMap: [CellID: [UInt32: UInt32]],
        voxelsPerTile: Int,
        tileMembership: inout [CompiledTileMembership]
    ) throws -> CompiledMolecules {
        let ordered = domains.sorted {
            let lhsTile = cellTileIndex[$0.cell] ?? Int.max
            let rhsTile = cellTileIndex[$1.cell] ?? Int.max
            return lhsTile == rhsTile ? $0.id < $1.id : lhsTile < rhsTile
        }
        var headers: [GPUMicrodomainHeader] = []
        var speciesStates: [GPUMolecularSpeciesState] = []
        var reactionStates: [GPUMolecularReaction] = []

        for domain in ordered {
            guard let network = networkByName[domain.network],
                  let cellIndex = cellIndexByID[domain.cell],
                  let tileIndex = cellTileIndex[domain.cell] else {
                throw ModelValidationError.unknownReference(
                    "molecular domain \(domain.id)"
                )
            }
            let speciesIndex = Dictionary(
                uniqueKeysWithValues: network.species.enumerated().map {
                    ($0.element.name, UInt32($0.offset))
                }
            )
            let speciesOffset = try checkedUInt32(
                speciesStates.count,
                "molecular species offset"
            )
            let voxelCount = max(Int(network.voxelCount), 1)
            for _ in 0..<voxelCount {
                speciesStates.append(
                    contentsOf: network.species.map {
                        .init(
                            amount: $0.initialAmount,
                            diffusion: $0.diffusionCoefficient,
                            minimum: $0.minimumAmount
                        )
                    }
                )
            }
            let reactionOffset = try checkedUInt32(
                reactionStates.count,
                "molecular reaction offset"
            )
            for reaction in network.reactions {
                var gpu = GPUMolecularReaction()
                for (index, participant) in reaction.reactants.enumerated() {
                    guard let species = speciesIndex[participant.species] else {
                        throw ModelValidationError.unknownReference(
                            "species \(participant.species)"
                        )
                    }
                    gpu.reactants[index] = species
                    gpu.stoichiometry[index] = participant.stoichiometry
                }
                for (index, participant) in reaction.products.enumerated() {
                    guard let species = speciesIndex[participant.species] else {
                        throw ModelValidationError.unknownReference(
                            "species \(participant.species)"
                        )
                    }
                    gpu.products[index] = species
                    gpu.stoichiometry[index + 2] = participant.stoichiometry
                }
                gpu.kinetics = Float4(
                    reaction.forwardRate,
                    reaction.reverseRate ?? 0,
                    0,
                    0
                )
                reactionStates.append(gpu)
            }

            let localVoxel = domain.fieldVoxel.map(Int.init)
            if let localVoxel, localVoxel < 0 || localVoxel >= voxelsPerTile {
                throw ModelValidationError.invalidMolecularNetwork(
                    "domain \(domain.id) field voxel is outside its tile"
                )
            }
            let globalFieldVoxel = localVoxel.map {
                UInt32(tileIndex * voxelsPerTile + $0)
            } ?? UInt32.max
            let compartment = domain.morphologyNode.flatMap {
                cellCompartmentMap[domain.cell]?[$0]
            } ?? UInt32.max

            var header = GPUMicrodomainHeader()
            header.countsAndOffsets0 = UInt4(
                UInt32(network.species.count),
                UInt32(network.reactions.count),
                speciesOffset,
                reactionOffset
            )
            header.countsAndOffsets1 = UInt4(UInt32(voxelCount), 0, 0, 0)
            header.coupling = UInt4(
                cellIndex,
                compartment,
                globalFieldVoxel,
                UInt32(network.solver.rawValue)
            )
            header.timeAndError = Float4(0, 0, 1e-4, 0)
            let domainIndex = UInt32(headers.count)
            headers.append(header)
            tileMembership[tileIndex].microdomainIndices.append(domainIndex)
        }
        return .init(
            headers: headers,
            species: speciesStates,
            reactions: reactionStates
        )
    }

    func completeFieldSpecies(
        _ provided: [FieldSpeciesDescriptor]
    ) -> [FieldSpeciesDescriptor] {
        let defaults: [FieldChannel: FieldSpeciesDescriptor] = [
            .extracellularPotassium: .init(
                channel: .extracellularPotassium,
                name: "K_ext",
                diffusionMicrometersSquaredPerMillisecond: 2,
                baseline: 3.5,
                maximum: 20
            ),
            .extracellularCalcium: .init(
                channel: .extracellularCalcium,
                name: "Ca_ext",
                diffusionMicrometersSquaredPerMillisecond: 0.6,
                baseline: 1.2,
                maximum: 5
            ),
            .glutamate: .init(
                channel: .glutamate,
                name: "glutamate",
                diffusionMicrometersSquaredPerMillisecond: 0.75,
                decayPerMillisecond: 0.1,
                baseline: 0,
                maximum: 10
            ),
            .oxygen: .init(
                channel: .oxygen,
                name: "oxygen",
                diffusionMicrometersSquaredPerMillisecond: 2.5,
                baseline: 0.2,
                maximum: 1
            ),
            .glucose: .init(
                channel: .glucose,
                name: "glucose",
                diffusionMicrometersSquaredPerMillisecond: 0.6,
                baseline: 1,
                maximum: 5
            ),
            .lactate: .init(
                channel: .lactate,
                name: "lactate",
                diffusionMicrometersSquaredPerMillisecond: 0.8,
                decayPerMillisecond: 0.001,
                baseline: 0,
                maximum: 10
            ),
            .pHWaste: .init(
                channel: .pHWaste,
                name: "pH_waste",
                diffusionMicrometersSquaredPerMillisecond: 1,
                decayPerMillisecond: 0.001,
                baseline: 0,
                maximum: 10
            ),
            .trophicSupport: .init(
                channel: .trophicSupport,
                name: "trophic",
                diffusionMicrometersSquaredPerMillisecond: 0.05,
                decayPerMillisecond: 0.0001,
                baseline: 1,
                maximum: 10
            ),
            .attractiveGuidance: .init(
                channel: .attractiveGuidance,
                name: "guidance_attract",
                diffusionMicrometersSquaredPerMillisecond: 0.02,
                decayPerMillisecond: 0.0001,
                baseline: 0,
                maximum: 10
            ),
            .repulsiveGuidance: .init(
                channel: .repulsiveGuidance,
                name: "guidance_repel",
                diffusionMicrometersSquaredPerMillisecond: 0.02,
                decayPerMillisecond: 0.0001,
                baseline: 0,
                maximum: 10
            ),
            .inflammatoryDamage: .init(
                channel: .inflammatoryDamage,
                name: "damage",
                diffusionMicrometersSquaredPerMillisecond: 0.05,
                decayPerMillisecond: 0.0001,
                baseline: 0,
                maximum: 10
            ),
            .extracellularMatrix: .init(
                channel: .extracellularMatrix,
                name: "ECM",
                diffusionMicrometersSquaredPerMillisecond: 0,
                baseline: 1,
                maximum: 10
            )
        ]
        let supplied = Dictionary(
            uniqueKeysWithValues: provided.map { ($0.channel, $0) }
        )
        return FieldChannel.allCases.map { supplied[$0] ?? defaults[$0]! }
    }
}
