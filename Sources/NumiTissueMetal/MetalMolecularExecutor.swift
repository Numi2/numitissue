#if canImport(Metal)
import Foundation
import Metal

public struct MetalMolecularExecutionReport: Sendable {
    public var domains: [MetalMolecularDomainDescriptor]
    public var species: [Float]
    public var statuses: [MetalMolecularExecutionStatus]

    public init(domains: [MetalMolecularDomainDescriptor], species: [Float], statuses: [MetalMolecularExecutionStatus]) {
        self.domains = domains
        self.species = species
        self.statuses = statuses
    }

    public var firstFault: (domain: Int, code: UInt32)? {
        for (index, status) in statuses.enumerated() where status.faultCode != 0 { return (index, status.faultCode) }
        return nil
    }
}

public actor MetalMolecularExecutor {
    public let device: MTLDevice
    public let archive: MetalMolecularArchive
    public let maximumReactionFiringsPerStep: Int

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let networkBuffer: MTLBuffer
    private let reactionBuffer: MTLBuffer
    private var domainBuffer: MTLBuffer?
    private var speciesBuffer: MTLBuffer?
    private var statusBuffer: MTLBuffer?
    private var domains = MetalMolecularDomainSet(descriptors: [], species: [])

    public init(
        device: MTLDevice,
        archive: MetalMolecularArchive,
        maximumReactionFiringsPerStep: Int = 100_000,
        shaderSource: String? = nil
    ) throws {
        guard maximumReactionFiringsPerStep > 0 else { throw MetalMolecularExecutorError.invalidFiringBudget }
        guard let queue = device.makeCommandQueue() else { throw MetalMolecularExecutorError.commandQueue }
        let source = try shaderSource ?? Self.loadShaderSource()
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "nt_molecular_execute") else { throw MetalMolecularExecutorError.missingKernel }
        self.device = device
        self.archive = archive
        self.maximumReactionFiringsPerStep = maximumReactionFiringsPerStep
        self.queue = queue
        self.pipeline = try device.makeComputePipelineState(function: function)
        self.networkBuffer = try Self.makeBuffer(device: device, values: archive.networks, label: "NumiTissue.Molecular.Networks")
        self.reactionBuffer = try Self.makeBuffer(device: device, values: archive.reactions, label: "NumiTissue.Molecular.Reactions")
    }

    public func load(_ domains: MetalMolecularDomainSet) throws {
        guard !domains.descriptors.isEmpty else { throw MetalMolecularExecutorError.emptyDomains }
        for domain in domains.descriptors {
            guard Int(domain.networkIndex) < archive.networks.count else { throw MetalMolecularExecutorError.invalidNetwork(Int(domain.networkIndex)) }
            let count = Int(archive.networks[Int(domain.networkIndex)].speciesCount)
            guard Int(domain.speciesOffset) + count <= domains.species.count else { throw MetalMolecularExecutorError.speciesRange }
        }
        self.domains = domains
        domainBuffer = try Self.makeBuffer(device: device, values: domains.descriptors, label: "NumiTissue.Molecular.Domains")
        speciesBuffer = try Self.makeBuffer(device: device, values: domains.species, label: "NumiTissue.Molecular.Species")
        statusBuffer = try Self.makeBuffer(device: device, count: domains.descriptors.count, as: MetalMolecularExecutionStatus.self, label: "NumiTissue.Molecular.Status")
    }

    public func replaceSpecies(_ species: [Float]) throws {
        guard species.count == domains.species.count, let speciesBuffer else { throw MetalMolecularExecutorError.speciesRange }
        guard species.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw MetalMolecularExecutorError.invalidSpecies }
        domains.species = species
        try Self.write(species, to: speciesBuffer)
    }

    public func step(
        dtSeconds: Float,
        randomSeed: UInt64,
        minimumTauSeconds: Float = 1e-8,
        maximumTauSeconds: Float = 1e-3,
        failOnFault: Bool = true
    ) async throws -> MetalMolecularExecutionReport {
        guard dtSeconds.isFinite, dtSeconds > 0 else { throw MetalMolecularExecutorError.invalidTimeStep }
        guard minimumTauSeconds.isFinite, maximumTauSeconds.isFinite, minimumTauSeconds > 0, maximumTauSeconds >= minimumTauSeconds else {
            throw MetalMolecularExecutorError.invalidTauRange
        }
        guard let domainBuffer, let speciesBuffer, let statusBuffer, !domains.descriptors.isEmpty else { throw MetalMolecularExecutorError.notLoaded }
        memset(statusBuffer.contents(), 0, statusBuffer.length)
        guard let commandBuffer = queue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalMolecularExecutorError.commandEncoding
        }
        commandBuffer.label = "NumiTissue Molecular Step"
        encoder.label = commandBuffer.label
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(networkBuffer, offset: 0, index: 0)
        encoder.setBuffer(reactionBuffer, offset: 0, index: 1)
        encoder.setBuffer(domainBuffer, offset: 0, index: 2)
        encoder.setBuffer(speciesBuffer, offset: 0, index: 3)
        encoder.setBuffer(statusBuffer, offset: 0, index: 4)
        var parameters = MetalMolecularExecutionParameters(
            domainCount: UInt32(clamping: domains.descriptors.count),
            maximumFirings: UInt32(clamping: maximumReactionFiringsPerStep),
            seedLo: UInt32(truncatingIfNeeded: randomSeed),
            seedHi: UInt32(truncatingIfNeeded: randomSeed >> 32),
            dtSeconds: dtSeconds,
            minimumTauSeconds: minimumTauSeconds,
            maximumTauSeconds: maximumTauSeconds
        )
        encoder.setBytes(&parameters, length: MemoryLayout<MetalMolecularExecutionParameters>.stride, index: 5)
        let width = min(max(pipeline.threadExecutionWidth, 1), max(pipeline.maxTotalThreadsPerThreadgroup, 1))
        encoder.dispatchThreads(
            MTLSize(width: domains.descriptors.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        try await complete(commandBuffer)

        let updatedDomains = Self.readArray(from: domainBuffer, count: domains.descriptors.count, as: MetalMolecularDomainDescriptor.self)
        let updatedSpecies = Self.readArray(from: speciesBuffer, count: domains.species.count, as: Float.self)
        let statuses = Self.readArray(from: statusBuffer, count: domains.descriptors.count, as: MetalMolecularExecutionStatus.self)
        domains = MetalMolecularDomainSet(descriptors: updatedDomains, species: updatedSpecies)
        let report = MetalMolecularExecutionReport(domains: updatedDomains, species: updatedSpecies, statuses: statuses)
        if failOnFault, let fault = report.firstFault { throw MetalMolecularExecutorError.executionFault(domain: fault.domain, code: fault.code) }
        return report
    }

    public func exportDomains() throws -> MetalMolecularDomainSet {
        guard let domainBuffer, let speciesBuffer else { throw MetalMolecularExecutorError.notLoaded }
        return MetalMolecularDomainSet(
            descriptors: Self.readArray(from: domainBuffer, count: domains.descriptors.count, as: MetalMolecularDomainDescriptor.self),
            species: Self.readArray(from: speciesBuffer, count: domains.species.count, as: Float.self)
        )
    }

    private static func loadShaderSource() throws -> String {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "NumiTissueMolecularVM", withExtension: "metal", subdirectory: "Shaders")
            ?? bundle.url(forResource: "NumiTissueMolecularVM", withExtension: "metal")
        guard let url else { throw MetalMolecularExecutorError.missingShaderResource }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T], label: String) throws -> MTLBuffer {
        let length = max(values.count * MemoryLayout<T>.stride, MemoryLayout<T>.stride)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { throw MetalMolecularExecutorError.bufferAllocation(label) }
        buffer.label = label
        try write(values, to: buffer)
        return buffer
    }

    private static func makeBuffer<T>(device: MTLDevice, count: Int, as: T.Type, label: String) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(count * MemoryLayout<T>.stride, MemoryLayout<T>.stride), options: .storageModeShared) else {
            throw MetalMolecularExecutorError.bufferAllocation(label)
        }
        buffer.label = label
        memset(buffer.contents(), 0, buffer.length)
        return buffer
    }

    private static func write<T>(_ values: [T], to buffer: MTLBuffer) throws {
        let byteCount = values.count * MemoryLayout<T>.stride
        guard byteCount <= buffer.length else { throw MetalMolecularExecutorError.bufferOverflow }
        values.withUnsafeBytes { bytes in if let address = bytes.baseAddress, byteCount > 0 { memcpy(buffer.contents(), address, byteCount) } }
    }

    private static func readArray<T>(from buffer: MTLBuffer, count: Int, as: T.Type) -> [T] {
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
    }

    private func complete(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if buffer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: MetalMolecularExecutorError.commandFailed(buffer.error?.localizedDescription ?? "unknown Metal error")) }
            }
            commandBuffer.commit()
        }
    }
}

public enum MetalMolecularExecutorError: Error, Sendable, CustomStringConvertible {
    case invalidFiringBudget
    case commandQueue
    case commandEncoding
    case commandFailed(String)
    case missingShaderResource
    case missingKernel
    case bufferAllocation(String)
    case bufferOverflow
    case emptyDomains
    case invalidNetwork(Int)
    case speciesRange
    case invalidSpecies
    case invalidTimeStep
    case invalidTauRange
    case notLoaded
    case executionFault(domain: Int, code: UInt32)

    public var description: String {
        switch self {
        case .invalidFiringBudget: return "Molecular reaction firing budget must be positive"
        case .commandQueue: return "Metal molecular command queue could not be created"
        case .commandEncoding: return "Metal molecular command could not be encoded"
        case .commandFailed(let value): return "Metal molecular command failed: \(value)"
        case .missingShaderResource: return "NumiTissueMolecularVM.metal is missing from package resources"
        case .missingKernel: return "nt_molecular_execute was not found in the Metal library"
        case .bufferAllocation(let value): return "Could not allocate molecular buffer \(value)"
        case .bufferOverflow: return "Molecular buffer write would overflow"
        case .emptyDomains: return "No molecular domains were supplied"
        case .invalidNetwork(let value): return "Invalid molecular network index \(value)"
        case .speciesRange: return "Molecular species range is invalid"
        case .invalidSpecies: return "Molecular species must be finite and nonnegative"
        case .invalidTimeStep: return "Molecular time step must be positive and finite"
        case .invalidTauRange: return "Molecular tau range is invalid"
        case .notLoaded: return "No molecular domains are loaded"
        case .executionFault(let domain, let code): return "Molecular domain \(domain) returned Metal fault \(code)"
        }
    }
}
#endif
