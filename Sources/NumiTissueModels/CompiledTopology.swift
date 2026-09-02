import Foundation
import NumiTissueCore

@frozen
public struct GPUCompiledNeuron: Sendable {
    public var compartmentRange: UInt4
    public var levelRange: UInt4
    public var identity: UInt4

    public init(
        compartmentOffset: UInt32,
        compartmentCount: UInt32,
        levelOffset: UInt32,
        levelCount: UInt32,
        cellIndex: UInt32,
        population: PopulationID
    ) {
        self.compartmentRange = UInt4(compartmentOffset, compartmentCount, 0, 0)
        self.levelRange = UInt4(levelOffset, levelCount, 0, 0)
        self.identity = UInt4(
            cellIndex,
            UInt32(truncatingIfNeeded: population.rawValue),
            UInt32(truncatingIfNeeded: population.rawValue >> 32),
            0
        )
    }
}

@frozen
public struct GPUCompartmentAdjacency: Sendable {
    public var incomingSynapses: UInt4

    public init(offset: UInt32 = 0, count: UInt32 = 0) {
        self.incomingSynapses = UInt4(offset, count, 0, 0)
    }
}

@frozen
public struct GPUNeuronRouting: Sendable {
    public var outgoingRoutes: UInt4

    public init(offset: UInt32 = 0, count: UInt32 = 0) {
        self.outgoingRoutes = UInt4(offset, count, 0, 0)
    }
}

@frozen
public struct GPUCompiledPopulation: Sendable {
    public var identity: UInt4
    public var memberRange: UInt4

    public init(id: PopulationID, memberOffset: UInt32, memberCount: UInt32) {
        self.identity = UInt4(
            UInt32(truncatingIfNeeded: id.rawValue),
            UInt32(truncatingIfNeeded: id.rawValue >> 32),
            0,
            0
        )
        self.memberRange = UInt4(memberOffset, memberCount, 0, 0)
    }
}

@frozen
public struct GPUMolecularSpeciesState: Sendable {
    public var values: Float4

    public init(amount: Float, diffusion: Float, minimum: Float) {
        self.values = Float4(amount, diffusion, minimum, 0)
    }
}

@frozen
public struct CompiledTileMembership: Sendable {
    public var coordinate: TileCoordinate
    public var cellIndices: [UInt32]
    public var segmentIndices: [UInt32]
    public var compartmentIndices: [UInt32]
    public var synapseIndices: [UInt32]
    public var microdomainIndices: [UInt32]

    public init(coordinate: TileCoordinate) {
        self.coordinate = coordinate
        self.cellIndices = []
        self.segmentIndices = []
        self.compartmentIndices = []
        self.synapseIndices = []
        self.microdomainIndices = []
    }
}

@frozen
public struct CompiledPopulation: Sendable {
    public var descriptor: PopulationDescriptor
    public var memberIndices: [UInt32]

    public init(descriptor: PopulationDescriptor, memberIndices: [UInt32]) {
        self.descriptor = descriptor
        self.memberIndices = memberIndices
    }
}

@frozen
public struct RuntimeAllocationPlan: Codable, Sendable, Hashable {
    public var tileCount: UInt32
    public var cellCapacity: UInt64
    public var segmentCapacity: UInt64
    public var compartmentCapacity: UInt64
    public var synapseCapacity: UInt64
    public var microdomainCapacity: UInt64
    public var eventNodeCapacity: UInt64
    public var eventWheelBucketCount: UInt32
    public var fieldVoxelCount: UInt64
    public var estimatedCommittedBytes: UInt64
    public var estimatedTransactionalBytes: UInt64

    public init(
        tileCount: UInt32,
        cellCapacity: UInt64,
        segmentCapacity: UInt64,
        compartmentCapacity: UInt64,
        synapseCapacity: UInt64,
        microdomainCapacity: UInt64,
        eventNodeCapacity: UInt64,
        eventWheelBucketCount: UInt32,
        fieldVoxelCount: UInt64,
        estimatedCommittedBytes: UInt64,
        estimatedTransactionalBytes: UInt64
    ) {
        self.tileCount = tileCount
        self.cellCapacity = cellCapacity
        self.segmentCapacity = segmentCapacity
        self.compartmentCapacity = compartmentCapacity
        self.synapseCapacity = synapseCapacity
        self.microdomainCapacity = microdomainCapacity
        self.eventNodeCapacity = eventNodeCapacity
        self.eventWheelBucketCount = eventWheelBucketCount
        self.fieldVoxelCount = fieldVoxelCount
        self.estimatedCommittedBytes = estimatedCommittedBytes
        self.estimatedTransactionalBytes = estimatedTransactionalBytes
    }
}
