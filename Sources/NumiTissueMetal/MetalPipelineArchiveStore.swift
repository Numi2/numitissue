#if canImport(Metal)
import Foundation
import Metal

/// Thread-safe device-specific binary archive. The archive is optional and never changes numerical
/// behavior; failure to create or serialize it is reported rather than silently changing pipeline
/// compilation policy.
public final class MetalPipelineArchiveStore: @unchecked Sendable {
    public let device: MTLDevice
    public let url: URL
    public let archive: any MTLBinaryArchive

    private let lock = NSLock()
    private var dirty = false
    private var registeredLabels = Set<String>()

    public init(device: MTLDevice, url: URL) throws {
        guard url.isFileURL else {
            throw MetalPipelineArchiveError.nonFileURL(url.absoluteString)
        }
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        let descriptor = MTLBinaryArchiveDescriptor()
        if FileManager.default.fileExists(atPath: standardized.path) {
            descriptor.url = standardized
        }
        do {
            archive = try device.makeBinaryArchive(descriptor: descriptor)
        } catch {
            throw MetalPipelineArchiveError.creationFailed(
                path: standardized.path,
                reason: String(describing: error)
            )
        }
        self.device = device
        self.url = standardized
        archive.label = "NumiTissue.ComputePipelines.\(device.registryID)"
    }

    /// Associates the archive with a pipeline and registers the descriptor when it has not already
    /// been seen during this process. Function constants are represented by the caller's stable
    /// label, so distinct specializations remain distinct archive entries.
    public func prepare(
        descriptor: MTLComputePipelineDescriptor,
        stableLabel: String
    ) throws {
        guard !stableLabel.isEmpty else {
            throw MetalPipelineArchiveError.emptyPipelineLabel
        }
        descriptor.binaryArchives = [archive]
        try withLock {
            guard registeredLabels.insert(stableLabel).inserted else { return }
            do {
                try archive.addComputePipelineFunctions(descriptor: descriptor)
                dirty = true
            } catch {
                registeredLabels.remove(stableLabel)
                throw MetalPipelineArchiveError.registrationFailed(
                    pipeline: stableLabel,
                    reason: String(describing: error)
                )
            }
        }
    }

    /// Serializes only after new descriptors have been registered. Callers may invoke this after
    /// every prewarm without causing redundant file writes.
    public func serializeIfNeeded() throws {
        try withLock {
            guard dirty else { return }
            do {
                try archive.serialize(to: url)
                dirty = false
            } catch {
                throw MetalPipelineArchiveError.serializationFailed(
                    path: url.path,
                    reason: String(describing: error)
                )
            }
        }
    }

    public var registeredPipelineCount: Int {
        withLock { registeredLabels.count }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public enum MetalPipelineArchiveError: Error, Sendable, CustomStringConvertible {
    case nonFileURL(String)
    case emptyPipelineLabel
    case creationFailed(path: String, reason: String)
    case registrationFailed(pipeline: String, reason: String)
    case serializationFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .nonFileURL(let value):
            return "Metal pipeline archive requires a file URL: \(value)"
        case .emptyPipelineLabel:
            return "Metal pipeline archive requires a stable nonempty pipeline label"
        case .creationFailed(let path, let reason):
            return "Unable to create Metal pipeline archive at \(path): \(reason)"
        case .registrationFailed(let pipeline, let reason):
            return "Unable to register pipeline \(pipeline) in the Metal archive: \(reason)"
        case .serializationFailed(let path, let reason):
            return "Unable to serialize Metal pipeline archive to \(path): \(reason)"
        }
    }
}
#endif
