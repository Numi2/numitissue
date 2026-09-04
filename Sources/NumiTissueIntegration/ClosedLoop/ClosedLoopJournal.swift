import Foundation
import NumiTissueIO
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ClosedLoopAuditRecord: Sendable, Codable {
    public var schemaVersion: UInt32 = 1
    public var runID: UUID
    public var sequence: UInt64
    public var previousSHA256: ScientificSHA256Digest?
    public var kind: String
    public var deviceNanoseconds: UInt64
    public var payload: Data
    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

public protocol ClosedLoopAuditSink: Sendable {
    /// A durable sink must fsync before returning. Failure is ambiguous and must stop dispatch.
    var durable: Bool { get }
    func append(kind: String, deviceNanoseconds: UInt64, payload: Data) async throws
}

public actor MemoryClosedLoopJournal: ClosedLoopAuditSink {
    public nonisolated let durable = false
    private let runID: UUID
    private var records: [ClosedLoopAuditRecord] = []
    private let maximumRecords: Int
    public init(runID: UUID, maximumRecords: Int = 100_000) throws {
        guard maximumRecords > 0, maximumRecords <= 1_000_000 else {
            throw ClosedLoopError.invalid("journal capacity")
        }
        self.runID = runID; self.maximumRecords = maximumRecords
    }
    public func append(kind: String, deviceNanoseconds: UInt64, payload: Data) throws {
        guard records.count < maximumRecords, payload.count <= 1_048_576, !kind.isEmpty else {
            throw ClosedLoopError.capacity("journal record or payload")
        }
        let previous = try records.last?.digest()
        records.append(.init(runID: runID, sequence: UInt64(records.count), previousSHA256: previous,
            kind: kind, deviceNanoseconds: deviceNanoseconds, payload: payload))
    }
    public func snapshot() -> [ClosedLoopAuditRecord] { records }
}

/// Exclusive, append-only, single-writer log. Does not silently truncate or reopen an old run.
/// The parent directory must already exist. Rotation/new-run decisions belong to the operator.
public actor FileClosedLoopJournal: ClosedLoopAuditSink {
    public nonisolated let durable = true
    private let handle: FileHandle
    private let runID: UUID
    private let maximumBytes: UInt64
    private var bytes: UInt64 = 0
    private var sequence: UInt64 = 0
    private var previous: ScientificSHA256Digest?
    private var poisoned = false

    public init(url: URL, runID: UUID, maximumBytes: UInt64 = 1_073_741_824) throws {
        guard url.isFileURL, maximumBytes > 0 else { throw ClosedLoopError.invalid("journal path or capacity") }
        try LoopJournalPaths.checkParents(url)
        #if canImport(Darwin) || canImport(Glibc)
        let fd = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw ClosedLoopError.invalid("journal must be a new exclusive regular file") }
        let opened = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        // Persist the directory entry as well as later data writes.
        let parentFD = url.deletingLastPathComponent().path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
        guard parentFD >= 0 else { try? opened.close(); throw ClosedLoopError.invalid("journal parent open") }
        let synced = fsync(parentFD)
        _ = close(parentFD)
        guard synced == 0 else { try? opened.close(); throw ClosedLoopError.invalid("journal directory sync") }
        self.handle = opened
        #else
        throw ClosedLoopError.invalid("durable journal is unsupported on this platform")
        #endif
        self.runID = runID; self.maximumBytes = maximumBytes
    }

    public func append(kind: String, deviceNanoseconds: UInt64, payload: Data) throws {
        guard !poisoned, !kind.isEmpty, payload.count <= 1_048_576, sequence < UInt64.max else {
            throw ClosedLoopError.latched("journal unavailable or record bounds exceeded")
        }
        let record = ClosedLoopAuditRecord(runID: runID, sequence: sequence,
            previousSHA256: previous, kind: kind, deviceNanoseconds: deviceNanoseconds, payload: payload)
        let digest = try record.digest()
        var encoded = try ScientificCanonicalJSON.encode(record)
        encoded.append(10)
        let nextBytes = try LoopArithmetic.add(bytes, UInt64(encoded.count))
        guard nextBytes <= maximumBytes else { throw ClosedLoopError.capacity("journal byte budget") }
        do {
            try handle.write(contentsOf: encoded)
            try handle.synchronize()
        } catch {
            poisoned = true // Never append after an ambiguous partial write.
            throw error
        }
        previous = digest; sequence += 1; bytes = nextBytes
    }
}

public enum ClosedLoopJournalVerifier {
    public static func verify(_ records: [ClosedLoopAuditRecord], expectedRunID: UUID) throws -> ScientificSHA256Digest {
        guard !records.isEmpty, records.count <= 1_000_000 else { throw ClosedLoopError.invalid("empty or unbounded journal") }
        var previous: ScientificSHA256Digest?
        for (index, record) in records.enumerated() {
            guard record.schemaVersion == 1, record.runID == expectedRunID,
                  record.sequence == UInt64(index), record.previousSHA256 == previous,
                  !record.kind.isEmpty, record.payload.count <= 1_048_576 else {
                throw ClosedLoopError.invalid("journal chain at record \(index)")
            }
            previous = try record.digest()
        }
        guard let previous else { throw ClosedLoopError.invalid("empty journal") }
        return previous
    }
}

enum LoopJournalPaths {
    static func checkParents(_ url: URL) throws {
        guard !url.pathComponents.contains(".."), url.lastPathComponent != "." else {
            throw ClosedLoopError.invalid("journal traversal")
        }
        var current = url.deletingLastPathComponent()
        while current.path != "/" {
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw ClosedLoopError.invalid("journal parent must be a real directory")
            }
            current.deleteLastPathComponent()
        }
    }
}
