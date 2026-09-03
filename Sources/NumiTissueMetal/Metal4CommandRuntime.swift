#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4SubmissionTelemetry: Sendable, Hashable, Codable {
    public var commandBufferBegins: UInt64
    public var commandBufferCommits: UInt64
    public var allocatorResets: UInt64
    public var unifiedComputeEncoders: UInt64
    public var dispatches: UInt64
    public var blitCommands: UInt64
    public var barriers: UInt64
    public var completedSubmissions: UInt64
    public var failedSubmissions: UInt64
    public var accumulatedGPUSeconds: Double
    public var retainedResourceHighWatermark: Int
    public var commandPoolSize: Int
    public var commandPoolExhaustions: UInt64

    public init(
        commandBufferBegins: UInt64 = 0,
        commandBufferCommits: UInt64 = 0,
        allocatorResets: UInt64 = 0,
        unifiedComputeEncoders: UInt64 = 0,
        dispatches: UInt64 = 0,
        blitCommands: UInt64 = 0,
        barriers: UInt64 = 0,
        completedSubmissions: UInt64 = 0,
        failedSubmissions: UInt64 = 0,
        accumulatedGPUSeconds: Double = 0,
        retainedResourceHighWatermark: Int = 0,
        commandPoolSize: Int = 0,
        commandPoolExhaustions: UInt64 = 0
    ) {
        self.commandBufferBegins = commandBufferBegins
        self.commandBufferCommits = commandBufferCommits
        self.allocatorResets = allocatorResets
        self.unifiedComputeEncoders = unifiedComputeEncoders
        self.dispatches = dispatches
        self.blitCommands = blitCommands
        self.barriers = barriers
        self.completedSubmissions = completedSubmissions
        self.failedSubmissions = failedSubmissions
        self.accumulatedGPUSeconds = accumulatedGPUSeconds
        self.retainedResourceHighWatermark = retainedResourceHighWatermark
        self.commandPoolSize = commandPoolSize
        self.commandPoolExhaustions = commandPoolExhaustions
    }

    public func delta(from baseline: Self) -> Self {
        Self(
            commandBufferBegins: subtract(commandBufferBegins, baseline.commandBufferBegins),
            commandBufferCommits: subtract(commandBufferCommits, baseline.commandBufferCommits),
            allocatorResets: subtract(allocatorResets, baseline.allocatorResets),
            unifiedComputeEncoders: subtract(unifiedComputeEncoders, baseline.unifiedComputeEncoders),
            dispatches: subtract(dispatches, baseline.dispatches),
            blitCommands: subtract(blitCommands, baseline.blitCommands),
            barriers: subtract(barriers, baseline.barriers),
            completedSubmissions: subtract(completedSubmissions, baseline.completedSubmissions),
            failedSubmissions: subtract(failedSubmissions, baseline.failedSubmissions),
            accumulatedGPUSeconds: max(
                accumulatedGPUSeconds - baseline.accumulatedGPUSeconds,
                0
            ),
            retainedResourceHighWatermark: retainedResourceHighWatermark,
            commandPoolSize: commandPoolSize,
            commandPoolExhaustions: subtract(
                commandPoolExhaustions,
                baseline.commandPoolExhaustions
            )
        )
    }

    private func subtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4SubmissionTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Metal4SubmissionTelemetry

    public init(commandPoolSize: Int) {
        value = Metal4SubmissionTelemetry(commandPoolSize: commandPoolSize)
    }

    public func recordBegin() {
        withLock {
            value.commandBufferBegins &+= 1
            value.allocatorResets &+= 1
            value.unifiedComputeEncoders &+= 1
        }
    }

    public func recordDispatch() {
        withLock { value.dispatches &+= 1 }
    }

    public func recordBlit() {
        withLock { value.blitCommands &+= 1 }
    }

    public func recordBarrier() {
        withLock { value.barriers &+= 1 }
    }

    public func recordCommit(retainedResourceCount: Int) {
        withLock {
            value.commandBufferCommits &+= 1
            value.retainedResourceHighWatermark = max(
                value.retainedResourceHighWatermark,
                retainedResourceCount
            )
        }
    }

    public func recordCompletion(feedback: any MTL4CommitFeedback) {
        withLock {
            if feedback.error == nil {
                value.completedSubmissions &+= 1
            } else {
                value.failedSubmissions &+= 1
            }
            let start = feedback.gpuStartTime
            let end = feedback.gpuEndTime
            if start.isFinite, end.isFinite, end >= start {
                value.accumulatedGPUSeconds += end - start
            }
        }
    }

    public func recordPoolExhaustion() {
        withLock { value.commandPoolExhaustions &+= 1 }
    }

    public func snapshot() -> Metal4SubmissionTelemetry {
        withLock { value }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
final class Metal4CommandSlot: @unchecked Sendable {
    let index: Int
    let allocator: any MTL4CommandAllocator
    let commandBuffer: any MTL4CommandBuffer
    var generation: UInt64 = 0
    var inFlight = false
    var retainedObjects: [AnyObject] = []

    init(
        index: Int,
        allocator: any MTL4CommandAllocator,
        commandBuffer: any MTL4CommandBuffer
    ) {
        self.index = index
        self.allocator = allocator
        self.commandBuffer = commandBuffer
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4CommandLease: @unchecked Sendable {
    fileprivate let slot: Metal4CommandSlot
    public let slotIndex: Int
    public let generation: UInt64
    public let commandBuffer: any MTL4CommandBuffer
    public let encoder: any MTL4ComputeCommandEncoder

    fileprivate init(
        slot: Metal4CommandSlot,
        encoder: any MTL4ComputeCommandEncoder
    ) {
        self.slot = slot
        self.slotIndex = slot.index
        self.generation = slot.generation
        self.commandBuffer = slot.commandBuffer
        self.encoder = encoder
    }

    /// Retains resources through commit feedback. Metal 4 command buffers do not retain resources
    /// automatically, so every object referenced by encoded work must remain strongly held.
    public func retain(_ object: AnyObject) {
        slot.retainedObjects.append(object)
    }

    public func retain(contentsOf objects: [AnyObject]) {
        slot.retainedObjects.append(contentsOf: objects)
    }

    public var retainedResourceCount: Int {
        slot.retainedObjects.count
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4CommandPool: @unchecked Sendable {
    private let lock = NSLock()
    private let slots: [Metal4CommandSlot]
    public let telemetry: Metal4SubmissionTelemetryRecorder

    public init(device: MTLDevice, capacity: Int) throws {
        guard (1...64).contains(capacity) else {
            throw Metal4CommandRuntimeError.invalidPoolSize(capacity)
        }
        var created: [Metal4CommandSlot] = []
        created.reserveCapacity(capacity)
        for index in 0..<capacity {
            guard let allocator = device.makeCommandAllocator() else {
                throw Metal4CommandRuntimeError.commandAllocatorCreationFailed(
                    index
                )
            }
            guard let commandBuffer = device.makeCommandBuffer() else {
                throw Metal4CommandRuntimeError.commandBufferCreationFailed(
                    index
                )
            }
            created.append(Metal4CommandSlot(
                index: index,
                allocator: allocator,
                commandBuffer: commandBuffer
            ))
        }
        slots = created
        telemetry = Metal4SubmissionTelemetryRecorder(
            commandPoolSize: capacity
        )
    }

    public var capacity: Int { slots.count }

    public func acquire() throws -> Metal4CommandLease {
        let slot: Metal4CommandSlot? = withLock {
            guard let slot = slots.first(where: { !$0.inFlight }) else {
                return nil
            }
            slot.inFlight = true
            slot.generation &+= 1
            slot.retainedObjects.removeAll(keepingCapacity: true)
            return slot
        }
        guard let slot else {
            telemetry.recordPoolExhaustion()
            throw Metal4CommandRuntimeError.commandPoolExhausted(
                capacity: slots.count
            )
        }

        slot.allocator.reset()
        slot.commandBuffer.beginCommandBuffer(allocator: slot.allocator)
        guard let encoder = slot.commandBuffer.makeComputeCommandEncoder() else {
            slot.commandBuffer.endCommandBuffer()
            release(slot)
            throw Metal4CommandRuntimeError.computeEncoderCreationFailed
        }
        telemetry.recordBegin()
        return Metal4CommandLease(slot: slot, encoder: encoder)
    }

    public func abandon(_ lease: Metal4CommandLease) {
        guard lease.slot.generation == lease.generation else { return }
        lease.encoder.endEncoding()
        lease.commandBuffer.endCommandBuffer()
        release(lease.slot)
    }

    fileprivate func release(_ slot: Metal4CommandSlot) {
        withLock {
            slot.retainedObjects.removeAll(keepingCapacity: true)
            slot.inFlight = false
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4RuntimeContext: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: any MTL4CommandQueue
    public let configuration: Metal4ExecutionConfiguration
    public let commandPool: Metal4CommandPool

    public var telemetry: Metal4SubmissionTelemetryRecorder {
        commandPool.telemetry
    }

    public init(
        device requestedDevice: MTLDevice? = nil,
        configuration source: Metal4ExecutionConfiguration = .init()
    ) throws {
        let configuration = try source.validatedForMetal4Backend()
        guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice() else {
            throw Metal4CommandRuntimeError.noDevice
        }
        _ = try Metal4Support.require(device: device)
        guard let queue = device.makeMTL4CommandQueue() else {
            throw Metal4CommandRuntimeError.commandQueueCreationFailed
        }
        self.device = device
        self.queue = queue
        self.configuration = configuration
        self.commandPool = try Metal4CommandPool(
            device: device,
            capacity: configuration.commandBufferPoolSize
        )
    }

    public func beginUnifiedComputePass() throws -> Metal4CommandLease {
        try commandPool.acquire()
    }

    public func submit(_ lease: Metal4CommandLease) async throws {
        lease.encoder.endEncoding()
        lease.commandBuffer.endCommandBuffer()
        commandPool.telemetry.recordCommit(
            retainedResourceCount: lease.retainedResourceCount
        )

        let options = MTL4CommitOptions()
        let pool = commandPool
        let telemetry = commandPool.telemetry
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            options.addFeedbackHandler { feedback in
                telemetry.recordCompletion(feedback: feedback)
                pool.release(lease.slot)
                if let error = feedback.error {
                    continuation.resume(
                        throwing: Metal4CommandRuntimeError.submissionFailed(
                            String(describing: error)
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
            queue.commit([lease.commandBuffer], options: options)
        }
    }

    public func abandon(_ lease: Metal4CommandLease) {
        commandPool.abandon(lease)
    }

    public func telemetrySnapshot() -> Metal4SubmissionTelemetry {
        commandPool.telemetry.snapshot()
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4CommandRuntimeError: Error, Sendable, CustomStringConvertible {
    case noDevice
    case invalidPoolSize(Int)
    case commandQueueCreationFailed
    case commandAllocatorCreationFailed(Int)
    case commandBufferCreationFailed(Int)
    case computeEncoderCreationFailed
    case commandPoolExhausted(capacity: Int)
    case submissionFailed(String)

    public var description: String {
        switch self {
        case .noDevice:
            return "No Metal device is available for Metal 4 execution"
        case .invalidPoolSize(let value):
            return "Metal 4 command-pool size \(value) is outside 1...64"
        case .commandQueueCreationFailed:
            return "Unable to create an MTL4CommandQueue"
        case .commandAllocatorCreationFailed(let index):
            return "Unable to create Metal 4 command allocator \(index)"
        case .commandBufferCreationFailed(let index):
            return "Unable to create reusable Metal 4 command buffer \(index)"
        case .computeEncoderCreationFailed:
            return "Unable to create a unified Metal 4 compute encoder"
        case .commandPoolExhausted(let capacity):
            return "All \(capacity) Metal 4 command slots are in flight"
        case .submissionFailed(let reason):
            return "Metal 4 command submission failed: \(reason)"
        }
    }
}
#endif
