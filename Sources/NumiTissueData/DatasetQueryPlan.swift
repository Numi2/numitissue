import Foundation
import NumiTissueIO

public enum BiologicalRequestMethod: String, Codable, Sendable, CaseIterable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

public enum DatasetRequestPriority: Int, Codable, Sendable, CaseIterable, Comparable {
    case background = 0
    case normal = 1
    case high = 2
    case critical = 3

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DatasetRequestCachePolicy: String, Codable, Sendable, CaseIterable {
    case immutable
    case revalidate
    case transient
    case bypass
}

public struct DatasetQueryRequest: Codable, Sendable, Equatable {
    public var id: String
    public var assetID: String?
    public var method: BiologicalRequestMethod
    public var locator: DataLocator
    public var byteRange: ByteRange?
    public var headers: [String: String]
    public var body: Data?
    public var credentialScope: String?
    public var decoderID: String
    public var expectedEncoding: DataStorageEncoding
    public var expectedCompression: DataCompression
    public var expectedMediaType: String?
    public var expectedChecksum: ScientificSHA256Digest?
    public var expectedByteCount: UInt64?
    public var estimatedDecodedBytes: UInt64?
    public var dependencies: [String]
    public var priority: DatasetRequestPriority
    public var optional: Bool
    public var cachePolicy: DatasetRequestCachePolicy
    public var metadata: [String: String]

    public init(
        id: String,
        assetID: String? = nil,
        method: BiologicalRequestMethod = .get,
        locator: DataLocator,
        byteRange: ByteRange? = nil,
        headers: [String: String] = [:],
        body: Data? = nil,
        credentialScope: String? = nil,
        decoderID: String,
        expectedEncoding: DataStorageEncoding,
        expectedCompression: DataCompression = .none,
        expectedMediaType: String? = nil,
        expectedChecksum: ScientificSHA256Digest? = nil,
        expectedByteCount: UInt64? = nil,
        estimatedDecodedBytes: UInt64? = nil,
        dependencies: [String] = [],
        priority: DatasetRequestPriority = .normal,
        optional: Bool = false,
        cachePolicy: DatasetRequestCachePolicy = .revalidate,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.assetID = assetID
        self.method = method
        self.locator = locator
        self.byteRange = byteRange
        self.headers = headers
        self.body = body
        self.credentialScope = credentialScope
        self.decoderID = decoderID
        self.expectedEncoding = expectedEncoding
        self.expectedCompression = expectedCompression
        self.expectedMediaType = expectedMediaType
        self.expectedChecksum = expectedChecksum
        self.expectedByteCount = expectedByteCount
        self.estimatedDecodedBytes = estimatedDecodedBytes
        self.dependencies = dependencies
        self.priority = priority
        self.optional = optional
        self.cachePolicy = cachePolicy
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty,
              !decoderID.isEmpty,
              expectedByteCount.map({ $0 > 0 }) ?? true,
              estimatedDecodedBytes.map({ $0 > 0 }) ?? true,
              Set(dependencies).count == dependencies.count,
              !dependencies.contains(id),
              headers.keys.allSatisfy({ !$0.isEmpty }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetQueryPlanError.invalidRequest(id)
        }
        _ = try locator.validated()
        if let byteRange { _ = try byteRange.validated() }
        if method == .head, body != nil {
            throw DatasetQueryPlanError.invalidRequest(id)
        }
        if method == .get, body != nil {
            throw DatasetQueryPlanError.invalidRequest(id)
        }
        let forbidden = Set(["authorization", "cookie", "proxy-authorization", "x-api-key"])
        let inlineSecrets = Set(headers.keys.map { $0.lowercased() }).intersection(forbidden)
        guard inlineSecrets.isEmpty else {
            throw DatasetQueryPlanError.inlineCredential(id)
        }
        if let credentialScope, credentialScope.isEmpty {
            throw DatasetQueryPlanError.invalidRequest(id)
        }
        return self
    }

    public var redactedDescription: String {
        "\(method.rawValue) \(locator.canonicalDescription) [\(id)]"
    }
}

public struct DatasetQueryPlanStatistics: Codable, Sendable, Equatable {
    public var requestCount: Int
    public var requiredRequestCount: Int
    public var optionalRequestCount: Int
    public var knownTransferBytes: UInt64
    public var unknownTransferRequestCount: Int
    public var knownDecodedBytes: UInt64
    public var unknownDecodedRequestCount: Int
    public var dependencyDepth: Int
    public var maximumParallelWidth: Int

    public init(
        requestCount: Int,
        requiredRequestCount: Int,
        optionalRequestCount: Int,
        knownTransferBytes: UInt64,
        unknownTransferRequestCount: Int,
        knownDecodedBytes: UInt64,
        unknownDecodedRequestCount: Int,
        dependencyDepth: Int,
        maximumParallelWidth: Int
    ) {
        self.requestCount = requestCount
        self.requiredRequestCount = requiredRequestCount
        self.optionalRequestCount = optionalRequestCount
        self.knownTransferBytes = knownTransferBytes
        self.unknownTransferRequestCount = unknownTransferRequestCount
        self.knownDecodedBytes = knownDecodedBytes
        self.unknownDecodedRequestCount = unknownDecodedRequestCount
        self.dependencyDepth = dependencyDepth
        self.maximumParallelWidth = maximumParallelWidth
    }
}

public struct DatasetQueryPlan: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var id: String
    public var adapterID: String
    public var dataset: DatasetVersion
    public var selection: DatasetSelection
    public var requests: [DatasetQueryRequest]
    public var enforceRuntimeBudget: Bool
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: String,
        adapterID: String,
        dataset: DatasetVersion,
        selection: DatasetSelection,
        requests: [DatasetQueryRequest],
        enforceRuntimeBudget: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.adapterID = adapterID
        self.dataset = dataset
        self.selection = selection
        self.requests = requests
        self.enforceRuntimeBudget = enforceRuntimeBudget
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw DatasetQueryPlanError.unsupportedSchema(schemaVersion)
        }
        guard !id.isEmpty,
              !adapterID.isEmpty,
              !requests.isEmpty,
              Set(requests.map(\.id)).count == requests.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetQueryPlanError.invalidPlan(id)
        }
        _ = try dataset.validated()
        let selection = try selection.validated()
        let requestIDs = Set(requests.map(\.id))
        for request in requests {
            _ = try request.validated()
            guard request.dependencies.allSatisfy(requestIDs.contains) else {
                throw DatasetQueryPlanError.unknownDependency(request.id)
            }
        }
        _ = try topologicalLevels()
        let statistics = try statistics()
        guard UInt64(requests.count) <= selection.budget.maximumAssets else {
            throw DatasetQueryPlanError.assetBudgetExceeded(
                planned: UInt64(requests.count),
                maximum: selection.budget.maximumAssets
            )
        }
        guard statistics.knownTransferBytes <=
                selection.budget.maximumTransferredBytes else {
            throw DatasetQueryPlanError.transferBudgetExceeded(
                planned: statistics.knownTransferBytes,
                maximum: selection.budget.maximumTransferredBytes
            )
        }
        guard statistics.knownDecodedBytes <= selection.budget.maximumDecodedBytes else {
            throw DatasetQueryPlanError.decodedBudgetExceeded(
                planned: statistics.knownDecodedBytes,
                maximum: selection.budget.maximumDecodedBytes
            )
        }
        return self
    }

    public func topologicalLevels() throws -> [[DatasetQueryRequest]] {
        let requestByID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        var indegree = Dictionary(uniqueKeysWithValues: requests.map {
            ($0.id, $0.dependencies.count)
        })
        var dependents: [String: [String]] = [:]
        for request in requests {
            for dependency in request.dependencies {
                dependents[dependency, default: []].append(request.id)
            }
        }
        for key in dependents.keys { dependents[key]?.sort() }

        var ready = indegree
            .filter { $0.value == 0 }
            .map(\.key)
            .sorted(by: { requestOrder(requestByID[$0], requestByID[$1]) })
        var levels: [[DatasetQueryRequest]] = []
        var visited = 0

        while !ready.isEmpty {
            let currentIDs = ready
            ready.removeAll(keepingCapacity: true)
            let level = currentIDs.compactMap { requestByID[$0] }
            levels.append(level)
            visited += level.count

            for identifier in currentIDs {
                for dependent in dependents[identifier] ?? [] {
                    guard let degree = indegree[dependent] else { continue }
                    let next = degree - 1
                    indegree[dependent] = next
                    if next == 0 { ready.append(dependent) }
                }
            }
            ready.sort(by: { requestOrder(requestByID[$0], requestByID[$1]) })
        }

        guard visited == requests.count else {
            let cycle = indegree.filter { $0.value > 0 }.map(\.key).sorted()
            throw DatasetQueryPlanError.dependencyCycle(cycle)
        }
        return levels
    }

    public func statistics() throws -> DatasetQueryPlanStatistics {
        let levels = try topologicalLevels()
        var transfer: UInt64 = 0
        var decoded: UInt64 = 0
        var unknownTransfer = 0
        var unknownDecoded = 0
        for request in requests {
            if let value = request.expectedByteCount {
                let (next, overflow) = transfer.addingReportingOverflow(value)
                guard !overflow else { throw DatasetQueryPlanError.byteCountOverflow }
                transfer = next
            } else {
                unknownTransfer += 1
            }
            if let value = request.estimatedDecodedBytes {
                let (next, overflow) = decoded.addingReportingOverflow(value)
                guard !overflow else { throw DatasetQueryPlanError.byteCountOverflow }
                decoded = next
            } else {
                unknownDecoded += 1
            }
        }
        return DatasetQueryPlanStatistics(
            requestCount: requests.count,
            requiredRequestCount: requests.filter { !$0.optional }.count,
            optionalRequestCount: requests.filter(\.optional).count,
            knownTransferBytes: transfer,
            unknownTransferRequestCount: unknownTransfer,
            knownDecodedBytes: decoded,
            unknownDecodedRequestCount: unknownDecoded,
            dependencyDepth: levels.count,
            maximumParallelWidth: levels.map(\.count).max() ?? 0
        )
    }
}

private func requestOrder(
    _ lhs: DatasetQueryRequest?,
    _ rhs: DatasetQueryRequest?
) -> Bool {
    guard let lhs else { return false }
    guard let rhs else { return true }
    if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
    return lhs.id < rhs.id
}

public enum DatasetQueryPlanError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidRequest(String)
    case inlineCredential(String)
    case invalidPlan(String)
    case unknownDependency(String)
    case dependencyCycle([String])
    case assetBudgetExceeded(planned: UInt64, maximum: UInt64)
    case transferBudgetExceeded(planned: UInt64, maximum: UInt64)
    case decodedBudgetExceeded(planned: UInt64, maximum: UInt64)
    case byteCountOverflow

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported dataset query-plan schema \(version)."
        case .invalidRequest(let identifier):
            return "Dataset query request \(identifier) is invalid."
        case .inlineCredential(let identifier):
            return "Dataset query request \(identifier) contains an inline credential; use credentialScope."
        case .invalidPlan(let identifier):
            return "Dataset query plan \(identifier) is invalid."
        case .unknownDependency(let identifier):
            return "Dataset query request \(identifier) has an unknown dependency."
        case .dependencyCycle(let identifiers):
            return "Dataset query plan has a dependency cycle: \(identifiers.joined(separator: ", "))."
        case .assetBudgetExceeded(let planned, let maximum):
            return "Dataset query plans \(planned) assets; budget allows \(maximum)."
        case .transferBudgetExceeded(let planned, let maximum):
            return "Dataset query plans \(planned) transferred bytes; budget allows \(maximum)."
        case .decodedBudgetExceeded(let planned, let maximum):
            return "Dataset query plans \(planned) decoded bytes; budget allows \(maximum)."
        case .byteCountOverflow:
            return "Dataset query byte-count accumulation overflowed."
        }
    }
}
