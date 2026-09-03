#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

public struct MetalExecutionOptions: Sendable, Hashable, Codable {
    public enum HazardMode: UInt8, Sendable, Codable {
        case tracked
        case untrackedWithExplicitBarriers
    }

    public var inFlightTransactions: Int
    public var privateHeapBytes: Int
    public var stagingBytes: Int
    public var hazardMode: HazardMode
    public var enableCounterSampling: Bool
    public var enableShaderValidation: Bool
    public var retainShaderSource: Bool
    public var maximumThreadgroupMemoryBytes: Int
    /// Optional for backward-compatible decoding of existing option documents. A nil value keeps
    /// the historical fast-math production behavior; scientific callers must request a profile.
    public var requestedNumericalProfile: RuntimeNumericalProfile?

    public init(
        inFlightTransactions: Int = 2,
        privateHeapBytes: Int = 512 * 1_024 * 1_024,
        stagingBytes: Int = 64 * 1_024 * 1_024,
        hazardMode: HazardMode = .untrackedWithExplicitBarriers,
        enableCounterSampling: Bool = false,
        enableShaderValidation: Bool = true,
        retainShaderSource: Bool = false,
        maximumThreadgroupMemoryBytes: Int = 32 * 1_024,
        requestedNumericalProfile: RuntimeNumericalProfile? = nil
    ) {
        precondition(inFlightTransactions > 0)
        precondition(privateHeapBytes > 0)
        precondition(stagingBytes > 0)
        self.inFlightTransactions = inFlightTransactions
        self.privateHeapBytes = privateHeapBytes
        self.stagingBytes = stagingBytes
        self.hazardMode = hazardMode
        self.enableCounterSampling = enableCounterSampling
        self.enableShaderValidation = enableShaderValidation
        self.retainShaderSource = retainShaderSource
        self.maximumThreadgroupMemoryBytes = maximumThreadgroupMemoryBytes
        self.requestedNumericalProfile = requestedNumericalProfile
    }

    public var effectiveNumericalProfile: RuntimeNumericalProfile {
        requestedNumericalProfile ?? .performance32
    }
}

public struct MetalDeviceCapabilities: Sendable, Hashable, Codable {
    public var name: String
    public var registryID: UInt64
    public var unifiedMemory: Bool
    public var lowPower: Bool
    public var removable: Bool
    public var recommendedWorkingSetBytes: UInt64
    public var maxBufferLength: UInt64
    public var maxThreadsPerThreadgroup: SIMD3<Int>
    public var argumentBufferTier: UInt8
    public var supportsAppleFamily7: Bool
    public var supportsAppleFamily8: Bool
    public var supportsAppleFamily9: Bool
    public var supportsDynamicLibraries: Bool
    public var supportsRaytracing: Bool
    public var supportsFunctionPointers: Bool
    public var counterSetNames: [String]

    public init(device: MTLDevice) {
        name = device.name
        registryID = device.registryID
        unifiedMemory = device.hasUnifiedMemory
        lowPower = device.isLowPower
        removable = device.isRemovable
        recommendedWorkingSetBytes = UInt64(device.recommendedMaxWorkingSetSize)
        maxBufferLength = UInt64(device.maxBufferLength)
        let size = device.maxThreadsPerThreadgroup
        maxThreadsPerThreadgroup = SIMD3(size.width, size.height, size.depth)
        argumentBufferTier = device.argumentBuffersSupport == .tier2 ? 2 : 1
        supportsAppleFamily7 = device.supportsFamily(.apple7)
        supportsAppleFamily8 = device.supportsFamily(.apple8)
        supportsAppleFamily9 = device.supportsFamily(.apple9)
        supportsDynamicLibraries = device.supportsDynamicLibraries
        supportsRaytracing = device.supportsRaytracing
        supportsFunctionPointers = device.supportsFunctionPointers
        counterSetNames = (device.counterSets ?? []).map(\.name).sorted()
    }
}

public enum MetalRuntimeError: Error, Sendable, CustomStringConvertible {
    case noDevice
    case commandQueueCreationFailed
    case heapCreationFailed(label: String, bytes: Int)
    case bufferAllocationFailed(label: String, bytes: Int)
    case libraryCompilationFailed(String)
    case functionMissing(String)
    case pipelineCreationFailed(function: String, reason: String)
    case commandBufferCreationFailed
    case encoderCreationFailed(String)
    case commandBufferFailed(String)
    case stateNotLoaded
    case transactionAlreadyOpen
    case noOpenTransaction
    case incompatibleGPU(String)
    case capacityExceeded(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .noDevice: return "No Metal device is available"
        case .commandQueueCreationFailed: return "Unable to create the Metal command queue"
        case .heapCreationFailed(let label, let bytes): return "Unable to create heap \(label) with \(bytes) bytes"
        case .bufferAllocationFailed(let label, let bytes): return "Unable to allocate buffer \(label) with \(bytes) bytes"
        case .libraryCompilationFailed(let reason): return "Metal library compilation failed: \(reason)"
        case .functionMissing(let name): return "Metal function \(name) is missing"
        case .pipelineCreationFailed(let function, let reason): return "Pipeline creation failed for \(function): \(reason)"
        case .commandBufferCreationFailed: return "Unable to create a Metal command buffer"
        case .encoderCreationFailed(let label): return "Unable to create encoder for \(label)"
        case .commandBufferFailed(let reason): return "Metal command buffer failed: \(reason)"
        case .stateNotLoaded: return "Metal tissue state has not been loaded"
        case .transactionAlreadyOpen: return "A Metal tissue transaction is already open"
        case .noOpenTransaction: return "No Metal tissue transaction is open"
        case .incompatibleGPU(let reason): return "The selected GPU is incompatible: \(reason)"
        case .capacityExceeded(let pool): return "Metal capacity exceeded for \(pool)"
        case .unsupported(let feature): return "Unsupported Metal feature: \(feature)"
        }
    }
}

/// Sendable hand-off for a command buffer that is created and encoded inside one actor, then
/// awaited by the device context. The Metal object itself remains encapsulated in this checked
/// ownership boundary; no raw command buffer crosses a Swift concurrency isolation boundary.
public final class MetalCommandBufferHandle: @unchecked Sendable {
    fileprivate let commandBuffer: MTLCommandBuffer

    public init(_ commandBuffer: MTLCommandBuffer) {
        self.commandBuffer = commandBuffer
    }
}

/// All mutable simulation buffers remain GPU resident. Shared buffers are restricted to command
/// metadata, compact output, validation flags, counters, and explicit snapshot transfer.
public final class MetalDeviceContext: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let transferQueue: MTLCommandQueue
    public let capabilities: MetalDeviceCapabilities
    public let options: MetalExecutionOptions
    public let privateHeap: MTLHeap
    public let telemetry: MetalTelemetryRecorder

    private let lock = NSLock()
    private var sequence: UInt64 = 0

    public init(device requestedDevice: MTLDevice? = nil, options: MetalExecutionOptions = MetalExecutionOptions()) throws {
        guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice() else { throw MetalRuntimeError.noDevice }
        guard device.hasUnifiedMemory else {
            throw MetalRuntimeError.incompatibleGPU("NumiTissue production execution requires Apple unified memory")
        }
        guard let commandQueue = device.makeCommandQueue(), let transferQueue = device.makeCommandQueue() else {
            throw MetalRuntimeError.commandQueueCreationFailed
        }

        let descriptor = MTLHeapDescriptor()
        descriptor.size = options.privateHeapBytes
        descriptor.storageMode = .private
        descriptor.cpuCacheMode = .defaultCache
        descriptor.hazardTrackingMode = options.hazardMode == .tracked ? .tracked : .untracked
        descriptor.type = .automatic
        guard let privateHeap = device.makeHeap(descriptor: descriptor) else {
            throw MetalRuntimeError.heapCreationFailed(label: "NumiTissue.Private", bytes: options.privateHeapBytes)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.transferQueue = transferQueue
        self.capabilities = MetalDeviceCapabilities(device: device)
        self.options = options
        self.privateHeap = privateHeap
        self.telemetry = MetalTelemetryRecorder()
        self.privateHeap.label = "NumiTissue.Private"
        self.commandQueue.label = "NumiTissue.Compute"
        self.transferQueue.label = "NumiTissue.Transfer"
    }

    public func nextSequence() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        return sequence
    }

    public func makePrivateBuffer(length: Int, label: String) throws -> MTLBuffer {
        guard length > 0 else { throw MetalRuntimeError.bufferAllocationFailed(label: label, bytes: length) }
        let alignment = 256
        let padded = (length + alignment - 1) & ~(alignment - 1)
        guard let buffer = privateHeap.makeBuffer(length: padded, options: .storageModePrivate) else {
            throw MetalRuntimeError.bufferAllocationFailed(label: label, bytes: padded)
        }
        buffer.label = label
        telemetry.recordPrivateAllocation(bytes: padded)
        return buffer
    }

    public func makeSharedBuffer(length: Int, label: String, writeCombined: Bool = false) throws -> MTLBuffer {
        guard length > 0 else { throw MetalRuntimeError.bufferAllocationFailed(label: label, bytes: length) }
        var options: MTLResourceOptions = [.storageModeShared]
        if writeCombined { options.insert(.cpuCacheModeWriteCombined) }
        guard let buffer = device.makeBuffer(length: length, options: options) else {
            throw MetalRuntimeError.bufferAllocationFailed(label: label, bytes: length)
        }
        buffer.label = label
        telemetry.recordSharedAllocation(bytes: length)
        return buffer
    }

    public func makeCommandBuffer(label: String) throws -> MTLCommandBuffer {
        guard let buffer = commandQueue.makeCommandBuffer() else { throw MetalRuntimeError.commandBufferCreationFailed }
        buffer.label = "\(label)#\(nextSequence())"
        telemetry.recordComputeCommandBuffer()
        return buffer
    }

    public func makeTransferCommandBuffer(label: String) throws -> MTLCommandBuffer {
        guard let buffer = transferQueue.makeCommandBuffer() else { throw MetalRuntimeError.commandBufferCreationFailed }
        buffer.label = "\(label)#\(nextSequence())"
        telemetry.recordTransferCommandBuffer()
        return buffer
    }

    public func awaitCompletion(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { [telemetry] completed in
                telemetry.recordCompletion(completed)
                if completed.status == .completed {
                    continuation.resume()
                } else {
                    let reason = completed.error.map(String.init(describing:)) ?? "status=\(completed.status.rawValue)"
                    continuation.resume(throwing: MetalRuntimeError.commandBufferFailed(reason))
                }
            }
            commandBuffer.commit()
        }
    }

    public func awaitCompletion(_ handle: MetalCommandBufferHandle) async throws {
        let commandBuffer = handle.commandBuffer
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { [telemetry] completed in
                telemetry.recordCompletion(completed)
                if completed.status == .completed {
                    continuation.resume()
                } else {
                    let reason = completed.error.map(String.init(describing:)) ?? "status=\(completed.status.rawValue)"
                    continuation.resume(throwing: MetalRuntimeError.commandBufferFailed(reason))
                }
            }
            commandBuffer.commit()
        }
    }
}
#endif