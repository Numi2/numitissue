import Foundation
import NumiTissueIO

public struct DatasetCacheKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var digest: ScientificSHA256Digest

    public init(digest: ScientificSHA256Digest) {
        self.digest = digest
    }

    public init(request: DatasetQueryRequest) {
        let bodyDigest = request.body.map {
            ScientificSHA256Digest(data: $0).hexadecimal
        } ?? "-"
        let range: String
        if let byteRange = request.byteRange {
            range = "\(byteRange.offset):\(byteRange.length)"
        } else {
            range = "-"
        }
        let headers = request.headers.keys
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { "\($0.lowercased())=\(request.headers[$0] ?? "")" }
            .joined(separator: "\u{1e}")
        let descriptor = [
            request.method.rawValue,
            request.locator.canonicalDescription,
            range,
            headers,
            bodyDigest,
            request.decoderID,
            request.expectedEncoding.rawValue,
            request.expectedCompression.rawValue
        ].joined(separator: "\u{1f}")
        digest = ScientificSHA256Digest(data: Data(descriptor.utf8))
    }

    public var description: String { digest.hexadecimal }
}

public struct DatasetCacheRecord: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var key: DatasetCacheKey
    public var requestID: String
    public var statusCode: Int
    public var finalLocator: DataLocator
    public var headers: [String: String]
    public var byteCount: UInt64
    public var contentDigest: ScientificSHA256Digest
    public var policy: DatasetRequestCachePolicy
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var expiresAt: Date?
    public var transferDurationSeconds: Double

    public init(
        schemaVersion: UInt32 = 1,
        key: DatasetCacheKey,
        requestID: String,
        statusCode: Int,
        finalLocator: DataLocator,
        headers: [String: String],
        byteCount: UInt64,
        contentDigest: ScientificSHA256Digest,
        policy: DatasetRequestCachePolicy,
        createdAt: Date,
        lastAccessedAt: Date,
        expiresAt: Date?,
        transferDurationSeconds: Double
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.requestID = requestID
        self.statusCode = statusCode
        self.finalLocator = finalLocator
        self.headers = headers
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.policy = policy
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.expiresAt = expiresAt
        self.transferDurationSeconds = transferDurationSeconds
    }

    public var etag: String? { headers["etag"] }
    public var lastModified: String? { headers["last-modified"] }

    public func isFresh(at date: Date = Date()) -> Bool {
        switch policy {
        case .immutable:
            return true
        case .revalidate:
            return expiresAt.map { date < $0 } ?? false
        case .transient:
            return expiresAt.map { date < $0 } ?? true
        case .bypass:
            return false
        }
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !requestID.isEmpty,
              (200..<300).contains(statusCode),
              byteCount > 0,
              transferDurationSeconds.isFinite,
              transferDurationSeconds >= 0,
              lastAccessedAt >= createdAt else {
            throw DatasetCacheError.invalidRecord(key.description)
        }
        _ = try finalLocator.validated()
        return self
    }
}

public struct DatasetCachedResponse: Sendable, Equatable {
    public var record: DatasetCacheRecord
    public var response: BiologicalDataResponse

    public init(record: DatasetCacheRecord, response: BiologicalDataResponse) {
        self.record = record
        self.response = response
    }
}

public struct DatasetCacheConfiguration: Sendable, Equatable {
    public var directory: URL?
    public var memoryCapacityBytes: UInt64
    public var diskCapacityBytes: UInt64
    public var maximumEntryBytes: UInt64
    public var defaultRevalidationIntervalSeconds: Double
    public var transientLifetimeSeconds: Double
    public var verifyContentDigestOnRead: Bool

    public init(
        directory: URL? = nil,
        memoryCapacityBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        diskCapacityBytes: UInt64 = 256 * 1_024 * 1_024 * 1_024,
        maximumEntryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024,
        defaultRevalidationIntervalSeconds: Double = 86_400,
        transientLifetimeSeconds: Double = 3_600,
        verifyContentDigestOnRead: Bool = true
    ) {
        self.directory = directory
        self.memoryCapacityBytes = memoryCapacityBytes
        self.diskCapacityBytes = diskCapacityBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.defaultRevalidationIntervalSeconds = defaultRevalidationIntervalSeconds
        self.transientLifetimeSeconds = transientLifetimeSeconds
        self.verifyContentDigestOnRead = verifyContentDigestOnRead
    }

    public func validated() throws -> Self {
        guard memoryCapacityBytes > 0,
              diskCapacityBytes > 0,
              maximumEntryBytes > 0,
              defaultRevalidationIntervalSeconds.isFinite,
              defaultRevalidationIntervalSeconds > 0,
              transientLifetimeSeconds.isFinite,
              transientLifetimeSeconds > 0 else {
            throw DatasetCacheError.invalidConfiguration
        }
        return self
    }
}

public struct DatasetCacheStatistics: Codable, Sendable, Equatable {
    public var memoryEntryCount: Int
    public var memoryBytes: UInt64
    public var diskEntryCount: Int
    public var diskBytes: UInt64
    public var hits: UInt64
    public var misses: UInt64
    public var integrityFailures: UInt64
    public var evictions: UInt64

    public init(
        memoryEntryCount: Int = 0,
        memoryBytes: UInt64 = 0,
        diskEntryCount: Int = 0,
        diskBytes: UInt64 = 0,
        hits: UInt64 = 0,
        misses: UInt64 = 0,
        integrityFailures: UInt64 = 0,
        evictions: UInt64 = 0
    ) {
        self.memoryEntryCount = memoryEntryCount
        self.memoryBytes = memoryBytes
        self.diskEntryCount = diskEntryCount
        self.diskBytes = diskBytes
        self.hits = hits
        self.misses = misses
        self.integrityFailures = integrityFailures
        self.evictions = evictions
    }
}

public actor DatasetCache {
    private struct MemoryEntry: Sendable {
        var cached: DatasetCachedResponse
        var accessOrdinal: UInt64
    }

    public let configuration: DatasetCacheConfiguration
    private let root: URL?
    private var memory: [DatasetCacheKey: MemoryEntry] = [:]
    private var diskRecords: [DatasetCacheKey: DatasetCacheRecord] = [:]
    private var memoryBytes: UInt64 = 0
    private var accessOrdinal: UInt64 = 0
    private var counters = DatasetCacheStatistics()

    public init(configuration: DatasetCacheConfiguration = DatasetCacheConfiguration()) throws {
        self.configuration = try configuration.validated()
        if let directory = configuration.directory?.standardizedFileURL {
            let cacheRoot = directory.appendingPathComponent(
                "numitissue-data-cache-v1",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: cacheRoot,
                withIntermediateDirectories: true
            )
            root = cacheRoot
            diskRecords = try Self.loadDiskIndex(root: cacheRoot)
        } else {
            root = nil
        }
    }

    public func lookup(
        _ key: DatasetCacheKey,
        allowExpired: Bool = true,
        now: Date = Date()
    ) throws -> DatasetCachedResponse? {
        if var entry = memory[key] {
            guard allowExpired || entry.cached.record.isFresh(at: now) else {
                counters.misses &+= 1
                return nil
            }
            accessOrdinal &+= 1
            entry.accessOrdinal = accessOrdinal
            entry.cached.record.lastAccessedAt = now
            entry.cached.response.receivedAt = now
            memory[key] = entry
            counters.hits &+= 1
            refreshStatistics()
            return entry.cached
        }

        guard var record = diskRecords[key], let root else {
            counters.misses &+= 1
            refreshStatistics()
            return nil
        }
        guard allowExpired || record.isFresh(at: now) else {
            counters.misses &+= 1
            refreshStatistics()
            return nil
        }
        let url = dataURL(for: key, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            diskRecords.removeValue(forKey: key)
            counters.misses &+= 1
            refreshStatistics()
            return nil
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard UInt64(data.count) == record.byteCount else {
            try invalidateCorruptEntry(key, root: root)
            throw DatasetCacheError.contentLengthMismatch(key.description)
        }
        if configuration.verifyContentDigestOnRead {
            let actual = ScientificSHA256Digest(data: data)
            guard actual == record.contentDigest else {
                try invalidateCorruptEntry(key, root: root)
                throw DatasetCacheError.contentDigestMismatch(key.description)
            }
        }

        record.lastAccessedAt = now
        diskRecords[key] = record
        try persist(record, root: root)
        let response = BiologicalDataResponse(
            requestID: record.requestID,
            statusCode: record.statusCode,
            data: data,
            headers: record.headers,
            finalLocator: record.finalLocator,
            receivedAt: now,
            transferDurationSeconds: record.transferDurationSeconds
        )
        let cached = DatasetCachedResponse(record: record, response: response)
        insertMemory(cached)
        counters.hits &+= 1
        refreshStatistics()
        return cached
    }

    @discardableResult
    public func store(
        response: BiologicalDataResponse,
        for request: DatasetQueryRequest,
        now: Date = Date()
    ) throws -> DatasetCacheRecord? {
        guard request.cachePolicy != .bypass,
              response.isSuccess,
              !response.data.isEmpty else {
            return nil
        }
        let byteCount = UInt64(response.data.count)
        guard byteCount <= configuration.maximumEntryBytes else {
            throw DatasetCacheError.entryTooLarge(
                bytes: byteCount,
                maximum: configuration.maximumEntryBytes
            )
        }
        let key = DatasetCacheKey(request: request)
        let expiresAt: Date?
        switch request.cachePolicy {
        case .immutable:
            expiresAt = nil
        case .revalidate:
            expiresAt = now.addingTimeInterval(
                configuration.defaultRevalidationIntervalSeconds
            )
        case .transient:
            expiresAt = now.addingTimeInterval(
                configuration.transientLifetimeSeconds
            )
        case .bypass:
            return nil
        }
        let record = DatasetCacheRecord(
            key: key,
            requestID: request.id,
            statusCode: response.statusCode,
            finalLocator: response.finalLocator,
            headers: response.headers,
            byteCount: byteCount,
            contentDigest: ScientificSHA256Digest(data: response.data),
            policy: request.cachePolicy,
            createdAt: now,
            lastAccessedAt: now,
            expiresAt: expiresAt,
            transferDurationSeconds: response.transferDurationSeconds
        )
        _ = try record.validated()
        let cached = DatasetCachedResponse(record: record, response: response)
        insertMemory(cached)

        if request.cachePolicy != .transient, let root {
            try persist(data: response.data, record: record, root: root)
            diskRecords[key] = record
            try pruneDiskIfNeeded(root: root)
        }
        refreshStatistics()
        return record
    }

    public func conditionalHeaders(for key: DatasetCacheKey) -> [String: String] {
        let record = memory[key]?.cached.record ?? diskRecords[key]
        guard let record else { return [:] }
        if let etag = record.etag { return ["If-None-Match": etag] }
        if let lastModified = record.lastModified {
            return ["If-Modified-Since": lastModified]
        }
        return [:]
    }

    public func refreshAfterNotModified(
        _ key: DatasetCacheKey,
        now: Date = Date()
    ) throws -> DatasetCachedResponse? {
        guard var cached = try lookup(key, allowExpired: true, now: now) else {
            return nil
        }
        cached.record.lastAccessedAt = now
        if cached.record.policy == .revalidate {
            cached.record.expiresAt = now.addingTimeInterval(
                configuration.defaultRevalidationIntervalSeconds
            )
        }
        cached.response.receivedAt = now
        insertMemory(cached)
        if let root, diskRecords[key] != nil {
            diskRecords[key] = cached.record
            try persist(cached.record, root: root)
        }
        refreshStatistics()
        return cached
    }

    public func remove(_ key: DatasetCacheKey) throws {
        if let value = memory.removeValue(forKey: key) {
            memoryBytes = memoryBytes >= value.cached.record.byteCount
                ? memoryBytes - value.cached.record.byteCount
                : 0
        }
        if let root {
            try? FileManager.default.removeItem(at: dataURL(for: key, root: root))
            try? FileManager.default.removeItem(at: recordURL(for: key, root: root))
        }
        diskRecords.removeValue(forKey: key)
        refreshStatistics()
    }

    public func removeAll() throws {
        memory.removeAll(keepingCapacity: false)
        diskRecords.removeAll(keepingCapacity: false)
        memoryBytes = 0
        if let root {
            let contents = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            for url in contents { try FileManager.default.removeItem(at: url) }
        }
        refreshStatistics()
    }

    public func statistics() -> DatasetCacheStatistics {
        refreshStatistics()
        return counters
    }
}

private extension DatasetCache {
    static func loadDiskIndex(root: URL) throws -> [DatasetCacheKey: DatasetCacheRecord] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var result: [DatasetCacheKey: DatasetCacheRecord] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? ScientificCanonicalJSON.decode(
                    DatasetCacheRecord.self,
                    from: data
                  ),
                  (try? record.validated()) != nil else {
                continue
            }
            let dataURL = dataURL(for: record.key, root: root)
            guard FileManager.default.fileExists(atPath: dataURL.path) else { continue }
            result[record.key] = record
        }
        return result
    }

    func insertMemory(_ cached: DatasetCachedResponse) {
        let key = cached.record.key
        if let previous = memory[key] {
            memoryBytes = memoryBytes >= previous.cached.record.byteCount
                ? memoryBytes - previous.cached.record.byteCount
                : 0
        }
        accessOrdinal &+= 1
        memory[key] = MemoryEntry(cached: cached, accessOrdinal: accessOrdinal)
        let (next, overflow) = memoryBytes.addingReportingOverflow(
            cached.record.byteCount
        )
        memoryBytes = overflow ? UInt64.max : next
        pruneMemoryIfNeeded()
    }

    func pruneMemoryIfNeeded() {
        while memoryBytes > configuration.memoryCapacityBytes,
              let oldest = memory.min(by: {
                  $0.value.accessOrdinal < $1.value.accessOrdinal
              }) {
            let removed = memory.removeValue(forKey: oldest.key)
            if let removed {
                memoryBytes = memoryBytes >= removed.cached.record.byteCount
                    ? memoryBytes - removed.cached.record.byteCount
                    : 0
                counters.evictions &+= 1
            }
        }
    }

    func pruneDiskIfNeeded(root: URL) throws {
        var total = diskRecords.values.reduce(UInt64(0)) {
            let (next, overflow) = $0.addingReportingOverflow($1.byteCount)
            return overflow ? UInt64.max : next
        }
        guard total > configuration.diskCapacityBytes else { return }
        let ordered = diskRecords.values.sorted {
            if $0.lastAccessedAt != $1.lastAccessedAt {
                return $0.lastAccessedAt < $1.lastAccessedAt
            }
            return $0.key.description < $1.key.description
        }
        for record in ordered where total > configuration.diskCapacityBytes {
            try? FileManager.default.removeItem(
                at: dataURL(for: record.key, root: root)
            )
            try? FileManager.default.removeItem(
                at: recordURL(for: record.key, root: root)
            )
            diskRecords.removeValue(forKey: record.key)
            total = total >= record.byteCount ? total - record.byteCount : 0
            counters.evictions &+= 1
        }
    }

    func persist(
        data: Data,
        record: DatasetCacheRecord,
        root: URL
    ) throws {
        try data.write(to: dataURL(for: record.key, root: root), options: [.atomic])
        try persist(record, root: root)
    }

    func persist(_ record: DatasetCacheRecord, root: URL) throws {
        let encoded = try ScientificCanonicalJSON.encode(record)
        try encoded.write(
            to: recordURL(for: record.key, root: root),
            options: [.atomic]
        )
    }

    func invalidateCorruptEntry(
        _ key: DatasetCacheKey,
        root: URL
    ) throws {
        counters.integrityFailures &+= 1
        memory.removeValue(forKey: key)
        diskRecords.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: dataURL(for: key, root: root))
        try? FileManager.default.removeItem(at: recordURL(for: key, root: root))
        refreshStatistics()
    }

    func refreshStatistics() {
        counters.memoryEntryCount = memory.count
        counters.memoryBytes = memoryBytes
        counters.diskEntryCount = diskRecords.count
        counters.diskBytes = diskRecords.values.reduce(UInt64(0)) {
            let (next, overflow) = $0.addingReportingOverflow($1.byteCount)
            return overflow ? UInt64.max : next
        }
    }

    nonisolated static func dataURL(
        for key: DatasetCacheKey,
        root: URL
    ) -> URL {
        root.appendingPathComponent(key.description + ".bin", isDirectory: false)
    }

    nonisolated static func recordURL(
        for key: DatasetCacheKey,
        root: URL
    ) -> URL {
        root.appendingPathComponent(key.description + ".json", isDirectory: false)
    }

    func dataURL(for key: DatasetCacheKey, root: URL) -> URL {
        Self.dataURL(for: key, root: root)
    }

    func recordURL(for key: DatasetCacheKey, root: URL) -> URL {
        Self.recordURL(for: key, root: root)
    }
}

public enum DatasetCacheError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidRecord(String)
    case entryTooLarge(bytes: UInt64, maximum: UInt64)
    case contentLengthMismatch(String)
    case contentDigestMismatch(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Dataset cache configuration is invalid."
        case .invalidRecord(let key):
            return "Dataset cache record \(key) is invalid."
        case .entryTooLarge(let bytes, let maximum):
            return "Dataset cache entry uses \(bytes) bytes; maximum is \(maximum)."
        case .contentLengthMismatch(let key):
            return "Dataset cache entry \(key) has an invalid byte count."
        case .contentDigestMismatch(let key):
            return "Dataset cache entry \(key) failed SHA-256 verification."
        }
    }
}
