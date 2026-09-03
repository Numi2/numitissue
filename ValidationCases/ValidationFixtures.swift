import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

struct ValidationFixtures {
    static let modelDigest: UInt64 = 0x4E_54_56_41_4C_49_44_31

    static func capabilities(
        name: String = "NumiTissue CPU Reference Validation"
    ) -> TissueRuntimeCapabilities {
        TissueRuntimeCapabilities(
            backendName: name,
            gpuResident: false,
            transactional: true,
            supportsAdaptiveFidelity: true,
            supportsMolecularDomains: true,
            supportsIndirectDispatch: false,
            supportsMetal4: false
        )
    }

    static func emptyModel(tileCount: UInt32 = 1) -> CompiledTissueModel {
        CompiledTissueModel(
            configuration: .scientific,
            manifest: ExecutableManifest(
                modelName: "validation-fixture",
                modelHash: String(modelDigest, radix: 16),
                tileCount: tileCount,
                sections: [:]
            ),
            allocation: RuntimeAllocationPlan(
                tileCount: tileCount,
                cellCapacity: 0,
                segmentCapacity: 0,
                compartmentCapacity: 1,
                synapseCapacity: 0,
                microdomainCapacity: 0,
                eventNodeCapacity: 65_536,
                eventWheelBucketCount: 4_096,
                fieldVoxelCount: 0,
                estimatedCommittedBytes: 0,
                estimatedTransactionalBytes: 0
            ),
            sourceMetadata: ["fixture": "phase-1"],
            tileCoordinates: [],
            tileHeaders: [],
            tileMembership: [],
            cells: [],
            cellPrograms: [],
            neuriteSegments: [],
            compartments: [],
            compartmentAdjacency: [],
            neurons: [],
            neuronRouting: [],
            morphologyLevelOffsets: [],
            morphologyLevelIndices: [],
            morphologyChildIndices: [],
            synapses: [],
            synapseParameters: [],
            outgoingRoutes: [],
            fieldVoxels: [],
            fieldParameters: [],
            mechanismSets: [],
            channelParameters: [],
            regulatoryPrograms: [],
            regulatoryMatrix: [],
            regulatoryBiases: [],
            fateTransitions: [],
            growthPrograms: [],
            glialPrograms: [],
            microdomainHeaders: [],
            molecularSpecies: [],
            molecularReactions: [],
            populations: [],
            populationTable: [],
            populationMembers: []
        )
    }

    static func passiveState(
        time: TissueTime = TissueTime(),
        epoch: UInt64 = 0,
        voltageMillivolts: Float = -65
    ) -> TissueRuntimeState {
        var state = TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 1,
                cells: 0,
                segments: 0,
                compartments: 1,
                synapses: 0,
                events: 65_536,
                fieldValues: 0,
                microdomains: 0,
                molecularSpecies: 0
            )
        )
        state.time = time
        state.epoch = epoch
        var tile = TileRuntimeState(
            id: TileID(rawValue: 1),
            coordinate: TileCoordinate(x: 0, y: 0, z: 0)
        )
        tile.compartmentRange = RuntimeRange(lowerBound: 0, count: 1)
        state.tiles = [tile]
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 1),
                neuronIndex: 0,
                mechanismRange: RuntimeRange(lowerBound: 0, count: 16),
                voltageMillivolts: voltageMillivolts,
                previousVoltageMillivolts: voltageMillivolts,
                capacitanceNanofarads: 1
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 16)
        state.mechanismState[10] = 0.1
        state.mechanismState[11] = -6.5
        return state
    }

    static func context(
        transaction: UInt64,
        epoch: UInt64,
        startTick: UInt64,
        seed: UInt64 = 1
    ) -> ExecutionContext {
        ExecutionContext(
            transaction: TransactionID(rawValue: transaction),
            epoch: epoch,
            startTime: TissueTime(tick: startTick),
            randomSeed: seed,
            cadence: RuntimeCadence()
        )
    }

    static func temporaryDirectory(
        prefix: String = "numitissue-validation"
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
