#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4ResidencySnapshot: Sendable, Hashable, Codable {
    public var generation: UInt64
    public var allocationCount: Int
    public var allocatedBytes: UInt64
    public var attachedToQueue: Bool
    public var residencyRequestedAhead: Bool
    public var label: String?

    public init(
        generation: UInt64,
        allocationCount: Int,
        allocatedBytes: UInt64,
        attachedToQueue: Bool,
        residencyRequestedAhead: Bool,
        label: String?
    ) {
        self.generation = generation
        self.allocationCount = allocationCount
        self.allocatedBytes = allocatedBytes
        self.attachedToQueue = attachedToQueue
        self.residencyRequestedAhead = residencyRequestedAhead
        self.label = label
    }
}

/// Owns one stable queue-level residency set. Arena migration replaces the set atomically from the
/// host's perspective: the new set is committed and optionally prepared before the old set is
/// removed from the queue.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4ResidencyController: @unchecked Sendable {
    public let device: MTLDevice
    public let queue: any MTL4CommandQueue
    public let attachToQueue: Bool
    public let requestAhead: Bool

    private let lock = NSLock()
    private var currentSet: (any MTLResidencySet)?
    private var currentSnapshot = Metal4ResidencySnapshot(
        generation: 0,
        allocationCount: 0,
        allocatedBytes: 0,
        attachedToQueue: false,
        residencyRequestedAhead: false,
        label: nil
    )

    public init(
        device: MTLDevice,
        queue: any MTL4CommandQueue,
        attachToQueue: Bool = true,
        requestAhead: Bool = true
    ) {
        self.device = device
        self.queue = queue
        self.attachToQueue = attachToQueue
        self.requestAhead = requestAhead
    }

    public func install(
        allocations source: [any MTLAllocation],
        label: String
    ) throws -> Metal4ResidencySnapshot {
        guard !label.isEmpty else {
            throw Metal4ResidencyError.emptyLabel
        }
        let allocations = deduplicated(source)
        guard !allocations.isEmpty else {
            throw Metal4ResidencyError.emptyAllocationSet
        }

        let descriptor = MTLResidencySetDescriptor()
        descriptor.label = label
        descriptor.initialCapacity = allocations.count
        let replacement: any MTLResidencySet
        do {
            replacement = try device.makeResidencySet(descriptor: descriptor)
        } catch {
            throw Metal4ResidencyError.creationFailed(
                String(describing: error)
            )
        }
        replacement.addAllocations(allocations)
        replacement.commit()
        if requestAhead { replacement.requestResidency() }

        return withLock {
            let previous = currentSet
            if attachToQueue {
                queue.addResidencySet(replacement)
            }
            if let previous, attachToQueue {
                queue.removeResidencySet(previous)
            }
            currentSet = replacement
            currentSnapshot = Metal4ResidencySnapshot(
                generation: currentSnapshot.generation &+ 1,
                allocationCount: replacement.allocationCount,
                allocatedBytes: replacement.allocatedSize,
                attachedToQueue: attachToQueue,
                residencyRequestedAhead: requestAhead,
                label: replacement.label
            )
            return currentSnapshot
        }
    }

    public func install(
        heap: MTLHeap,
        sharedBuffers: [MTLBuffer],
        standaloneBuffers: [MTLBuffer] = [],
        pipelines: [MTLComputePipelineState] = [],
        label: String
    ) throws -> Metal4ResidencySnapshot {
        var allocations: [any MTLAllocation] = [heap]
        allocations.append(contentsOf: sharedBuffers.map { $0 as any MTLAllocation })
        allocations.append(contentsOf: standaloneBuffers.map { $0 as any MTLAllocation })
        allocations.append(contentsOf: pipelines.map { $0 as any MTLAllocation })
        return try install(allocations: allocations, label: label)
    }

    public func detach() {
        withLock {
            if let currentSet, attachToQueue {
                queue.removeResidencySet(currentSet)
            }
            currentSet = nil
            currentSnapshot = Metal4ResidencySnapshot(
                generation: currentSnapshot.generation &+ 1,
                allocationCount: 0,
                allocatedBytes: 0,
                attachedToQueue: false,
                residencyRequestedAhead: false,
                label: nil
            )
        }
    }

    public func snapshot() -> Metal4ResidencySnapshot {
        withLock { currentSnapshot }
    }

    public func contains(_ allocation: any MTLAllocation) -> Bool {
        withLock { currentSet?.containsAllocation(allocation) ?? false }
    }

    private func deduplicated(
        _ allocations: [any MTLAllocation]
    ) -> [any MTLAllocation] {
        var seen = Set<ObjectIdentifier>()
        var result: [any MTLAllocation] = []
        result.reserveCapacity(allocations.count)
        for allocation in allocations {
            let identifier = ObjectIdentifier(allocation as AnyObject)
            if seen.insert(identifier).inserted {
                result.append(allocation)
            }
        }
        return result
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4ResidencyError: Error, Sendable, CustomStringConvertible {
    case emptyLabel
    case emptyAllocationSet
    case creationFailed(String)

    public var description: String {
        switch self {
        case .emptyLabel:
            return "Metal 4 residency set requires a nonempty label"
        case .emptyAllocationSet:
            return "Metal 4 residency set requires at least one allocation"
        case .creationFailed(let reason):
            return "Metal 4 residency-set creation failed: \(reason)"
        }
    }
}
#endif
