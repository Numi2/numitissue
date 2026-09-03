#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4BufferBinding: @unchecked Sendable {
    public var index: Int
    public var buffer: MTLBuffer
    public var offset: Int

    public init(index: Int, buffer: MTLBuffer, offset: Int = 0) {
        self.index = index
        self.buffer = buffer
        self.offset = offset
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
private struct Metal4AddressBindingKey: Hashable {
    var index: Int
    var address: UInt64
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
private struct Metal4ArgumentTableKey: Hashable {
    var maximumBindingCount: Int
    var bindings: [Metal4AddressBindingKey]
}

/// Retains both the Metal 4 argument table and every buffer whose GPU address it contains.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4ArgumentTableEntry: @unchecked Sendable {
    public let table: any MTL4ArgumentTable
    public let buffers: [MTLBuffer]
    public let bindingCount: Int
    public let label: String

    fileprivate init(
        table: any MTL4ArgumentTable,
        buffers: [MTLBuffer],
        bindingCount: Int,
        label: String
    ) {
        self.table = table
        self.buffers = buffers
        self.bindingCount = bindingCount
        self.label = label
    }

    public var retainedObjects: [AnyObject] {
        [table as AnyObject] + buffers.map { $0 as AnyObject }
    }
}

/// Caches root binding tables by stable GPU address. The existing `MetalArgumentTable` remains the
/// shader-visible argument buffer at binding zero; Metal 4 argument tables provide the root GPU
/// address bindings required by the new encoder model.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4ArgumentTableCache: @unchecked Sendable {
    public let device: MTLDevice
    public let maximumBindingCount: Int

    private let lock = NSLock()
    private var entries: [Metal4ArgumentTableKey: Metal4ArgumentTableEntry] = [:]
    private var generation: UInt64 = 0

    public init(device: MTLDevice, maximumBindingCount: Int = 32) throws {
        guard (1...256).contains(maximumBindingCount) else {
            throw Metal4ArgumentTableError.invalidMaximumBindingCount(
                maximumBindingCount
            )
        }
        self.device = device
        self.maximumBindingCount = maximumBindingCount
    }

    public func table(
        rootArgumentBuffer: MTLBuffer,
        additionalBindings: [Metal4BufferBinding] = [],
        label: String
    ) throws -> Metal4ArgumentTableEntry {
        var bindings = [
            Metal4BufferBinding(
                index: 0,
                buffer: rootArgumentBuffer,
                offset: 0
            )
        ]
        bindings.append(contentsOf: additionalBindings)
        return try table(bindings: bindings, label: label)
    }

    public func table(
        bindings source: [Metal4BufferBinding],
        label: String
    ) throws -> Metal4ArgumentTableEntry {
        guard !source.isEmpty else {
            throw Metal4ArgumentTableError.emptyBindings
        }
        guard !label.isEmpty else {
            throw Metal4ArgumentTableError.emptyLabel
        }

        let bindings = try canonicalBindings(source)
        let key = Metal4ArgumentTableKey(
            maximumBindingCount: maximumBindingCount,
            bindings: bindings.map {
                Metal4AddressBindingKey(
                    index: $0.index,
                    address: UInt64($0.buffer.gpuAddress) &+
                        UInt64($0.offset)
                )
            }
        )

        return try withLock {
            if let cached = entries[key] { return cached }

            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.label = label
            descriptor.maxBufferBindCount = maximumBindingCount
            descriptor.maxTextureBindCount = 0
            descriptor.maxSamplerStateBindCount = 0
            descriptor.initializeBindings = true
            descriptor.supportAttributeStrides = false
            let table: any MTL4ArgumentTable
            do {
                table = try device.makeArgumentTable(descriptor: descriptor)
            } catch {
                throw Metal4ArgumentTableError.creationFailed(
                    String(describing: error)
                )
            }
            for binding in bindings {
                table.setAddress(
                    binding.buffer.gpuAddress &+
                        MTLGPUAddress(binding.offset),
                    index: binding.index
                )
            }
            generation &+= 1
            let entry = Metal4ArgumentTableEntry(
                table: table,
                buffers: bindings.map(\.buffer),
                bindingCount: bindings.count,
                label: "\(label).g\(generation)"
            )
            entries[key] = entry
            return entry
        }
    }

    public func invalidateAll() {
        withLock {
            entries.removeAll(keepingCapacity: true)
            generation &+= 1
        }
    }

    public var cachedTableCount: Int {
        withLock { entries.count }
    }

    private func canonicalBindings(
        _ source: [Metal4BufferBinding]
    ) throws -> [Metal4BufferBinding] {
        var byIndex: [Int: Metal4BufferBinding] = [:]
        byIndex.reserveCapacity(source.count)
        for binding in source {
            guard binding.index >= 0,
                  binding.index < maximumBindingCount else {
                throw Metal4ArgumentTableError.bindingIndexOutOfRange(
                    index: binding.index,
                    maximum: maximumBindingCount
                )
            }
            guard binding.offset >= 0,
                  binding.offset <= binding.buffer.length else {
                throw Metal4ArgumentTableError.offsetOutOfRange(
                    index: binding.index,
                    offset: binding.offset,
                    bufferLength: binding.buffer.length
                )
            }
            guard byIndex.updateValue(binding, forKey: binding.index) == nil else {
                throw Metal4ArgumentTableError.duplicateBindingIndex(
                    binding.index
                )
            }
        }
        return byIndex.values.sorted { $0.index < $1.index }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4ArgumentTableError: Error, Sendable, CustomStringConvertible {
    case invalidMaximumBindingCount(Int)
    case emptyBindings
    case emptyLabel
    case bindingIndexOutOfRange(index: Int, maximum: Int)
    case duplicateBindingIndex(Int)
    case offsetOutOfRange(index: Int, offset: Int, bufferLength: Int)
    case creationFailed(String)

    public var description: String {
        switch self {
        case .invalidMaximumBindingCount(let count):
            return "Metal 4 argument-table binding count \(count) is outside 1...256"
        case .emptyBindings:
            return "Metal 4 argument table requires at least one binding"
        case .emptyLabel:
            return "Metal 4 argument table requires a nonempty label"
        case .bindingIndexOutOfRange(let index, let maximum):
            return "Metal 4 binding index \(index) is outside 0..<\(maximum)"
        case .duplicateBindingIndex(let index):
            return "Metal 4 argument table contains duplicate binding index \(index)"
        case .offsetOutOfRange(let index, let offset, let bufferLength):
            return "Metal 4 binding \(index) offset \(offset) exceeds buffer length \(bufferLength)"
        case .creationFailed(let reason):
            return "Metal 4 argument-table creation failed: \(reason)"
        }
    }
}
#endif
