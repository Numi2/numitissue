import Foundation
import NumiTissueCore

@frozen
public struct TissueRuntimeCapabilities: Sendable, Hashable {
    public var backendName: String
    public var gpuResident: Bool
    public var transactional: Bool
    public var supportsAdaptiveFidelity: Bool
    public var supportsMolecularDomains: Bool
    public var supportsIndirectDispatch: Bool
    public var supportsMetal4: Bool
    public var recommendedWorkingSetBytes: UInt64?
    public var maximumThreadgroupMemoryBytes: UInt64?

    public init(
        backendName: String,
        gpuResident: Bool,
        transactional: Bool,
        supportsAdaptiveFidelity: Bool,
        supportsMolecularDomains: Bool,
        supportsIndirectDispatch: Bool,
        supportsMetal4: Bool,
        recommendedWorkingSetBytes: UInt64? = nil,
        maximumThreadgroupMemoryBytes: UInt64? = nil
    ) {
        self.backendName = backendName
        self.gpuResident = gpuResident
        self.transactional = transactional
        self.supportsAdaptiveFidelity = supportsAdaptiveFidelity
        self.supportsMolecularDomains = supportsMolecularDomains
        self.supportsIndirectDispatch = supportsIndirectDispatch
        self.supportsMetal4 = supportsMetal4
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.maximumThreadgroupMemoryBytes = maximumThreadgroupMemoryBytes
    }
}

@frozen
public struct TissueRuntimeSnapshot: Sendable {
    public var schemaVersion: UInt32
    public var modelHash: String
    public var time: TissueTime
    public var transactionIndex: UInt64
    public var tileHeaders: [GPUTileHeader]
    public var tileMembership: [CompiledTileMembership]
    public var cells: [GPUCellState]
    public var segments: [GPUNeuriteSegment]
    public var compartments: [GPUCompartmentState]
    public var synapses: [GPUSynapseState]
    public var fields: [GPUFieldVoxel]
    public var microdomains: [GPUMicrodomainHeader]
    public var molecularSpecies: [GPUMolecularSpeciesState]
    public var pendingEvents: [GPUEvent]

    public init(
        model: CompiledTissueModel,
        time: TissueTime = .init(),
        transactionIndex: UInt64 = 0,
        pendingEvents: [GPUEvent] = []
    ) {
        self.schemaVersion = NumiTissueBuild.snapshotSchemaVersion
        self.modelHash = model.manifest.modelHash
        self.time = time
        self.transactionIndex = transactionIndex
        self.tileHeaders = model.tileHeaders
        self.tileMembership = model.tileMembership
        self.cells = model.cells
        self.segments = model.neuriteSegments
        self.compartments = model.compartments
        self.synapses = model.synapses
        self.fields = model.fieldVoxels
        self.microdomains = model.microdomainHeaders
        self.molecularSpecies = model.molecularSpecies
        self.pendingEvents = pendingEvents
    }
}

public protocol TissueRuntime: AnyObject, Sendable {
    var capabilities: TissueRuntimeCapabilities { get }
    func load(_ model: CompiledTissueModel) async throws
    func step(_ input: TissueInput) async throws -> TissueStepResult
    func captureSnapshot() async throws -> TissueRuntimeSnapshot
    func restoreSnapshot(_ snapshot: TissueRuntimeSnapshot) async throws
    func reset() async throws
}
