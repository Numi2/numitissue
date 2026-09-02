import Foundation
import NumiTissueCore

// MARK: - Tile, population, allocation and manifest

extension TissueModelCompiler {
    struct CompiledPopulations {
        var populations: [CompiledPopulation]
        var table: [GPUCompiledPopulation]
        var members: [UInt32]
    }

    func compilePopulations(
        descriptors: [PopulationDescriptor],
        cells: [CellInstance],
        cellIndexByID: [CellID: UInt32]
    ) -> CompiledPopulations {
        var populations: [CompiledPopulation] = []
        var table: [GPUCompiledPopulation] = []
        var members: [UInt32] = []
        for descriptor in descriptors.sorted(by: { $0.id < $1.id }) {
            let populationMembers = cells
                .filter { $0.population == descriptor.id }
                .compactMap { cellIndexByID[$0.id] }
                .sorted()
            let offset = UInt32(members.count)
            members.append(contentsOf: populationMembers)
            populations.append(
                .init(
                    descriptor: descriptor,
                    memberIndices: populationMembers
                )
            )
            table.append(
                .init(
                    id: descriptor.id,
                    memberOffset: offset,
                    memberCount: UInt32(populationMembers.count)
                )
            )
        }
        return .init(populations: populations, table: table, members: members)
    }

    func validateTileCapacities(
        _ membership: [CompiledTileMembership]
    ) throws {
        for tile in membership {
            guard tile.cellIndices.count <= Int(configuration.tile.maximumCells) else {
                throw ModelValidationError.capacityExceeded(
                    "cells at tile \(tile.coordinate)"
                )
            }
            guard tile.segmentIndices.count <= Int(configuration.tile.maximumNeuriteSegments) else {
                throw ModelValidationError.capacityExceeded(
                    "segments at tile \(tile.coordinate)"
                )
            }
            guard tile.compartmentIndices.count <= Int(configuration.tile.maximumCompartments) else {
                throw ModelValidationError.capacityExceeded(
                    "compartments at tile \(tile.coordinate)"
                )
            }
            guard tile.synapseIndices.count <= Int(configuration.tile.maximumExplicitSynapses) else {
                throw ModelValidationError.capacityExceeded(
                    "synapses at tile \(tile.coordinate)"
                )
            }
            guard tile.microdomainIndices.count <= Int(configuration.tile.maximumMicrodomains) else {
                throw ModelValidationError.capacityExceeded(
                    "microdomains at tile \(tile.coordinate)"
                )
            }
        }
    }

    func makeTileHeaders(
        coordinates: [TileCoordinate],
        membership: [CompiledTileMembership],
        voxelsPerTile: Int
    ) throws -> [GPUTileHeader] {
        var headers: [GPUTileHeader] = []
        headers.reserveCapacity(coordinates.count)
        for index in coordinates.indices {
            let tile = membership[index]
            var header = GPUTileHeader(coordinate: coordinates[index])
            header.counts0 = UInt4(
                UInt32(tile.cellIndices.count),
                UInt32(tile.segmentIndices.count),
                UInt32(tile.compartmentIndices.count),
                UInt32(tile.synapseIndices.count)
            )
            header.counts1 = UInt4(
                UInt32(tile.microdomainIndices.count),
                0,
                0,
                0
            )
            header.offsets0 = UInt4(
                try checkedUInt32(
                    index * Int(configuration.tile.maximumCells),
                    "tile cell membership offset"
                ),
                try checkedUInt32(
                    index * Int(configuration.tile.maximumNeuriteSegments),
                    "tile segment membership offset"
                ),
                try checkedUInt32(
                    index * Int(configuration.tile.maximumCompartments),
                    "tile compartment membership offset"
                ),
                try checkedUInt32(
                    index * Int(configuration.tile.maximumExplicitSynapses),
                    "tile synapse membership offset"
                )
            )
            header.offsets1 = UInt4(
                try checkedUInt32(index * voxelsPerTile, "tile field offset"),
                try checkedUInt32(
                    index * Int(configuration.tile.maximumMicrodomains),
                    "tile microdomain membership offset"
                ),
                UInt32(index * 27),
                0
            )
            var flags = TileFlags.fieldsActive
            if !tile.compartmentIndices.isEmpty { flags.insert(.electricallyActive) }
            if !tile.microdomainIndices.isEmpty { flags.insert(.molecularActive) }
            header.flags.x = flags.rawValue
            headers.append(header)
        }
        return headers
    }

    func makeAllocationPlan(
        tileCount: Int,
        voxelsPerTile: Int,
        initialSynapseCount: Int
    ) throws -> RuntimeAllocationPlan {
        let tileCount64 = UInt64(tileCount)
        let cellCapacity = try checkedMultiply(
            tileCount64,
            UInt64(configuration.tile.maximumCells),
            "cell capacity"
        )
        let segmentCapacity = try checkedMultiply(
            tileCount64,
            UInt64(configuration.tile.maximumNeuriteSegments),
            "segment capacity"
        )
        let compartmentCapacity = try checkedMultiply(
            tileCount64,
            UInt64(configuration.tile.maximumCompartments),
            "compartment capacity"
        )
        let synapseCapacity = try checkedMultiply(
            tileCount64,
            UInt64(configuration.tile.maximumExplicitSynapses),
            "synapse capacity"
        )
        let microdomainCapacity = try checkedMultiply(
            tileCount64,
            UInt64(configuration.tile.maximumMicrodomains),
            "microdomain capacity"
        )
        let fieldVoxelCount = try checkedMultiply(
            tileCount64,
            UInt64(voxelsPerTile),
            "field voxel count"
        )
        for (name, value) in [
            ("cell", cellCapacity),
            ("segment", segmentCapacity),
            ("compartment", compartmentCapacity),
            ("synapse", synapseCapacity),
            ("microdomain", microdomainCapacity),
            ("field voxel", fieldVoxelCount)
        ] where value > UInt64(UInt32.max) {
            throw ModelValidationError.capacityExceeded(
                "\(name) pool exceeds the UInt32 GPU address space"
            )
        }

        let eventNodeCapacity = min(
            max(UInt64(initialSynapseCount) * 8, 65_536),
            16_777_216
        )
        let eventWheelBucketCount: UInt32 = 4_096

        var dynamicBytes: UInt64 = 0
        dynamicBytes += cellCapacity * UInt64(GPUABI.cellStride)
        dynamicBytes += segmentCapacity * UInt64(GPUABI.segmentStride)
        dynamicBytes += compartmentCapacity * UInt64(GPUABI.compartmentStride)
        dynamicBytes += synapseCapacity * UInt64(GPUABI.synapseStride)
        dynamicBytes += microdomainCapacity * UInt64(GPUABI.microdomainHeaderStride)
        dynamicBytes += fieldVoxelCount * UInt64(GPUABI.fieldVoxelStride)
        dynamicBytes += eventNodeCapacity * UInt64(GPUABI.eventStride + 16)
        dynamicBytes += (cellCapacity + segmentCapacity + compartmentCapacity +
            synapseCapacity + microdomainCapacity) * UInt64(MemoryLayout<UInt32>.stride)

        let transactionalBytes = dynamicBytes * 2 +
            UInt64(eventWheelBucketCount) * UInt64(MemoryLayout<UInt32>.stride) * 2
        return .init(
            tileCount: UInt32(tileCount),
            cellCapacity: cellCapacity,
            segmentCapacity: segmentCapacity,
            compartmentCapacity: compartmentCapacity,
            synapseCapacity: synapseCapacity,
            microdomainCapacity: microdomainCapacity,
            eventNodeCapacity: eventNodeCapacity,
            eventWheelBucketCount: eventWheelBucketCount,
            fieldVoxelCount: fieldVoxelCount,
            estimatedCommittedBytes: dynamicBytes,
            estimatedTransactionalBytes: transactionalBytes
        )
    }

    func checkedMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64,
        _ label: String
    ) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw ModelValidationError.capacityExceeded(label)
        }
        return result.partialValue
    }

    func checkedUInt32(_ value: Int, _ label: String) throws -> UInt32 {
        guard value >= 0, value <= Int(UInt32.max) else {
            throw ModelValidationError.capacityExceeded(label)
        }
        return UInt32(value)
    }

    func stableHash(_ model: TissueModel) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(model)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    func makeSections(
        tileHeaders: Int,
        cells: Int,
        cellPrograms: Int,
        segments: Int,
        compartments: Int,
        compartmentAdjacency: Int,
        neurons: Int,
        levelIndices: Int,
        childIndices: Int,
        synapses: Int,
        synapseParameters: Int,
        routes: Int,
        fields: Int,
        mechanisms: Int,
        channels: Int,
        microdomains: Int,
        molecularSpecies: Int,
        molecularReactions: Int,
        populations: Int,
        populationMembers: Int
    ) -> [ExecutableSectionKind: PackedSection] {
        var cursor = 0
        var result: [ExecutableSectionKind: PackedSection] = [:]

        func append<T>(
            _ kind: ExecutableSectionKind,
            count: Int,
            _: T.Type
        ) {
            cursor = alignUp(cursor, to: GPUABI.alignment)
            let stride = alignUp(MemoryLayout<T>.stride, to: 16)
            let bytes = stride * count
            result[kind] = PackedSection(
                offset: UInt64(cursor),
                byteCount: UInt64(bytes),
                stride: UInt32(stride),
                count: UInt64(count)
            )
            cursor += bytes
        }

        append(.tileHeaders, count: tileHeaders, GPUTileHeader.self)
        append(.cells, count: cells, GPUCellState.self)
        append(.neuriteSegments, count: segments, GPUNeuriteSegment.self)
        append(.compartments, count: compartments, GPUCompartmentState.self)
        append(.morphologyLevels, count: levelIndices, UInt32.self)
        append(.synapses, count: synapses, GPUSynapseState.self)
        append(.fieldVoxels, count: fields, GPUFieldVoxel.self)
        append(.microdomainHeaders, count: microdomains, GPUMicrodomainHeader.self)
        append(.molecularSpecies, count: molecularSpecies, GPUMolecularSpeciesState.self)
        append(.molecularReactions, count: molecularReactions, GPUMolecularReaction.self)
        append(.longRangeRoutes, count: routes, GPULongRangeRoute.self)
        append(.mechanismTables, count: mechanisms, GPUMechanismSet.self)
        append(.populationTables, count: populations, GPUCompiledPopulation.self)
        return result
    }
}
