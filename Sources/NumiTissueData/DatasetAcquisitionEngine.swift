import Foundation
import NumiTissueIO

public enum DatasetRequestDisposition: String, Codable, Sendable, CaseIterable {
    case network
    case cacheHit
    case cacheRevalidated
    case failed
    case optionalFailure
    case dependencySkipped
}

public struct DatasetRequestAcquisitionReport: Codable, Sendable, Equatable {
    public var requestID: String
    public var decoderID: String
    public var disposition: DatasetRequestDisposition
    public var expansionDepth: Int
    public var statusCode: Int?
    public var payloadBytes: UInt64
    public var decodedBudgetBytes: UInt64
    public var networkTransferredBytes: UInt64
    public var contentDigest: String?
    public var transferDurationSeconds: Double
    public var decodeDurationSeconds: Double
    public var finalLocator: String?
    public var errorDescription: String?
    public var dependencyIDs: [String]

    public init(
        requestID: String,
        decoderID: String,
        disposition: DatasetRequestDisposition,
        expansionDepth: Int,
        statusCode: Int? = nil,
        payloadBytes: UInt64 = 0,
        decodedBudgetBytes: UInt64 = 0,
        networkTransferredBytes: UInt64 = 0,
        contentDigest: String? = nil,
        transferDurationSeconds: Double = 0,
        decodeDurationSeconds: Double = 0,
        finalLocator: String? = nil,
        errorDescription: String? = nil,
        dependencyIDs: [String] = []
    ) {
        self.requestID = requestID
        self.decoderID = decoderID
        self.disposition = disposition
        self.expansionDepth = expansionDepth
        self.statusCode = statusCode
        self.payloadBytes = payloadBytes
        self.decodedBudgetBytes = decodedBudgetBytes
        self.networkTransferredBytes = networkTransferredBytes
        self.contentDigest = contentDigest
        self.transferDurationSeconds = transferDurationSeconds
        self.decodeDurationSeconds = decodeDurationSeconds
        self.finalLocator = finalLocator
        self.errorDescription = errorDescription
        self.dependencyIDs = dependencyIDs
    }
}

public struct DatasetAcquisitionReport: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var acquisitionID: String
    public var adapterID: String
    public var datasetReference: String
    public var startedAt: Date
    public var completedAt: Date
    public var requestReports: [DatasetRequestAcquisitionReport]
    public var fragmentCount: Int
    public var assetCount: Int
    public var partitionCount: Int
    public var evidenceRecordCount: Int
    public var uniqueEntityCount: Int
    public var networkTransferredBytes: UInt64
    public var decodedBudgetBytes: UInt64
    public var maximumExpansionDepth: Int
    public var cacheStatistics: DatasetCacheStatistics?
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        acquisitionID: String,
        adapterID: String,
        datasetReference: String,
        startedAt: Date,
        completedAt: Date,
        requestReports: [DatasetRequestAcquisitionReport],
        fragmentCount: Int,
        assetCount: Int,
        partitionCount: Int,
        evidenceRecordCount: Int,
        uniqueEntityCount: Int,
        networkTransferredBytes: UInt64,
        decodedBudgetBytes: UInt64,
        maximumExpansionDepth: Int,
        cacheStatistics: DatasetCacheStatistics?,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.acquisitionID = acquisitionID
        self.adapterID = adapterID
        self.datasetReference = datasetReference
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.requestReports = requestReports
        self.fragmentCount = fragmentCount
        self.assetCount = assetCount
        self.partitionCount = partitionCount
        self.evidenceRecordCount = evidenceRecordCount
        self.uniqueEntityCount = uniqueEntityCount
        self.networkTransferredBytes = networkTransferredBytes
        self.decodedBudgetBytes = decodedBudgetBytes
        self.maximumExpansionDepth = maximumExpansionDepth
        self.cacheStatistics = cacheStatistics
        self.metadata = metadata
    }
}

public struct DatasetAcquisitionResult: Sendable {
    public var plan: DatasetQueryPlan
    public var batch: EvidenceBatch
    public var fragments: [DatasetDecodedFragment]
    public var report: DatasetAcquisitionReport

    public init(
        plan: DatasetQueryPlan,
        batch: EvidenceBatch,
        fragments: [DatasetDecodedFragment],
        report: DatasetAcquisitionReport
    ) {
        self.plan = plan
        self.batch = batch
        self.fragments = fragments
        self.report = report
    }
}

public struct DatasetAcquisitionConfiguration: Sendable, Equatable {
    public var maximumResponseBytesPerRequest: UInt64
    public var maximumConcurrency: Int?
    public var maximumExpansionDepth: Int
    public var maximumTotalRequests: UInt64
    public var maximumPartitions: UInt64
    public var requireDeclaredChecksum: Bool
    public var verifyExpectedByteCount: Bool
    public var verifyExpectedMediaType: Bool
    public var requireMediaTypeHeaderWhenDeclared: Bool
    public var verifyContentLengthHeader: Bool
    public var requireExpansionParentDependency: Bool
    public var failOnDecoderErrorDiagnostics: Bool
    public var failOnDecoderWarningDiagnostics: Bool
    public var allowEmptyEvidenceBatch: Bool

    public init(
        maximumResponseBytesPerRequest: UInt64 = 16 * 1_024 * 1_024 * 1_024,
        maximumConcurrency: Int? = nil,
        maximumExpansionDepth: Int = 8,
        maximumTotalRequests: UInt64 = 100_000,
        maximumPartitions: UInt64 = 10_000_000,
        requireDeclaredChecksum: Bool = false,
        verifyExpectedByteCount: Bool = true,
        verifyExpectedMediaType: Bool = true,
        requireMediaTypeHeaderWhenDeclared: Bool = false,
        verifyContentLengthHeader: Bool = true,
        requireExpansionParentDependency: Bool = true,
        failOnDecoderErrorDiagnostics: Bool = true,
        failOnDecoderWarningDiagnostics: Bool = false,
        allowEmptyEvidenceBatch: Bool = true
    ) {
        self.maximumResponseBytesPerRequest = maximumResponseBytesPerRequest
        self.maximumConcurrency = maximumConcurrency
        self.maximumExpansionDepth = maximumExpansionDepth
        self.maximumTotalRequests = maximumTotalRequests
        self.maximumPartitions = maximumPartitions
        self.requireDeclaredChecksum = requireDeclaredChecksum
        self.verifyExpectedByteCount = verifyExpectedByteCount
        self.verifyExpectedMediaType = verifyExpectedMediaType
        self.requireMediaTypeHeaderWhenDeclared = requireMediaTypeHeaderWhenDeclared
        self.verifyContentLengthHeader = verifyContentLengthHeader
        self.requireExpansionParentDependency = requireExpansionParentDependency
        self.failOnDecoderErrorDiagnostics = failOnDecoderErrorDiagnostics
        self.failOnDecoderWarningDiagnostics = failOnDecoderWarningDiagnostics
        self.allowEmptyEvidenceBatch = allowEmptyEvidenceBatch
    }

    public func validated() throws -> Self {
        guard maximumResponseBytesPerRequest > 0,
              maximumConcurrency.map({ $0 > 0 && $0 <= 256 }) ?? true,
              maximumExpansionDepth >= 0,
              maximumExpansionDepth <= 64,
              maximumTotalRequests > 0,
              maximumTotalRequests <= 1_000_000,
              maximumPartitions > 0,
              maximumPartitions <= 1_000_000_000 else {
            throw DatasetAcquisitionError.invalidConfiguration
        }
        return self
    }
}

public struct DatasetAcquisitionEngine: Sendable {
    public let transport: any BiologicalDataTransport
    public let cache: DatasetCache?
    public let decoders: DatasetDecoderRegistry
    public let assembler: DatasetEvidenceAssembler
    public let configuration: DatasetAcquisitionConfiguration

    public init(
        transport: any BiologicalDataTransport,
        cache: DatasetCache? = nil,
        decoders: DatasetDecoderRegistry,
        assembler: DatasetEvidenceAssembler = DatasetEvidenceAssembler(),
        configuration: DatasetAcquisitionConfiguration = DatasetAcquisitionConfiguration()
    ) throws {
        self.transport = transport
        self.cache = cache
        self.decoders = decoders
        self.assembler = assembler
        self.configuration = try configuration.validated()
    }

    public func acquire(
        using adapter: any BiologicalDatasetAdapter,
        dataset: DatasetVersion,
        selection: DatasetSelection
    ) async throws -> DatasetAcquisitionResult {
        let plan = try adapter.makeQueryPlan(
            dataset: dataset,
            selection: selection
        )
        return try await acquire(plan: plan)
    }

    public func acquire(
        adapterID: String,
        dataset: DatasetVersion,
        selection: DatasetSelection,
        registry: BiologicalDatasetAdapterRegistry
    ) async throws -> DatasetAcquisitionResult {
        let plan = try await registry.makeQueryPlan(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        return try await acquire(plan: plan)
    }

    public func acquire(
        plan sourcePlan: DatasetQueryPlan
    ) async throws -> DatasetAcquisitionResult {
        try Task.checkCancellation()
        let startedAt = Date()
        let plan = try sourcePlan.validated()

        var knownRequests: [String: ScheduledDatasetRequest] = [:]
        var pending: [String: ScheduledDatasetRequest] = [:]
        for request in plan.requests {
            let scheduled = ScheduledDatasetRequest(
                request: request,
                expansionDepth: 0
            )
            knownRequests[request.id] = scheduled
            pending[request.id] = scheduled
        }
        try validatePlannedBudgets(
            plan: plan,
            requests: Array(knownRequests.values)
        )

        var completed = Set<String>()
        var unavailable = Set<String>()
        var fragments: [DatasetDecodedFragment] = []
        var requestReports: [DatasetRequestAcquisitionReport] = []
        var networkTransferredBytes: UInt64 = 0
        var decodedBudgetBytes: UInt64 = 0
        var maximumExpansionDepth = 0

        while !pending.isEmpty {
            try Task.checkCancellation()
            let blocked = pending.values
                .filter { !$0.request.dependencies.isDisjoint(with: unavailable) }
                .sorted(by: scheduledRequestOrder)
            for scheduled in blocked {
                pending.removeValue(forKey: scheduled.request.id)
                unavailable.insert(scheduled.request.id)
                let unavailableDependencies = scheduled.request.dependencies
                    .filter(unavailable.contains)
                    .sorted()
                if !scheduled.request.optional {
                    throw DatasetAcquisitionError.requiredDependencyUnavailable(
                        request: scheduled.request.id,
                        dependencies: unavailableDependencies
                    )
                }
                requestReports.append(DatasetRequestAcquisitionReport(
                    requestID: scheduled.request.id,
                    decoderID: scheduled.request.decoderID,
                    disposition: .dependencySkipped,
                    expansionDepth: scheduled.expansionDepth,
                    errorDescription: "Unavailable dependencies: \(unavailableDependencies.joined(separator: ", "))",
                    dependencyIDs: scheduled.request.dependencies.sorted()
                ))
            }
            guard !pending.isEmpty else { break }

            let ready = pending.values
                .filter {
                    Set($0.request.dependencies).isSubset(of: completed)
                }
                .sorted(by: scheduledRequestOrder)
            guard !ready.isEmpty else {
                let pendingIDs = Set(pending.keys)
                let missing = pending.values.flatMap { scheduled in
                    scheduled.request.dependencies.filter {
                        !completed.contains($0) &&
                            !unavailable.contains($0) &&
                            !pendingIDs.contains($0)
                    }
                }
                if !missing.isEmpty {
                    throw DatasetAcquisitionError.unknownDynamicDependency(
                        Array(Set(missing)).sorted()
                    )
                }
                throw DatasetAcquisitionError.dynamicDependencyCycle(
                    pending.keys.sorted()
                )
            }

            let maximumConcurrency = min(
                configuration.maximumConcurrency ??
                    plan.selection.budget.maximumConcurrentRequests,
                plan.selection.budget.maximumConcurrentRequests
            )
            let completedSnapshot = completed
            let outcomes = await executeReady(
                ready,
                plan: plan,
                startedAt: startedAt,
                completedRequestIDs: completedSnapshot,
                maximumConcurrency: maximumConcurrency
            ).sorted { $0.requestID < $1.requestID }

            for scheduled in ready {
                pending.removeValue(forKey: scheduled.request.id)
            }

            for outcome in outcomes {
                let report = outcome.report
                requestReports.append(report)
                networkTransferredBytes = try addBytes(
                    networkTransferredBytes,
                    report.networkTransferredBytes
                )
                decodedBudgetBytes = try addBytes(
                    decodedBudgetBytes,
                    report.decodedBudgetBytes
                )
                if plan.enforceRuntimeBudget {
                    try enforceRuntimeByteBudgets(
                        networkTransferredBytes: networkTransferredBytes,
                        decodedBudgetBytes: decodedBudgetBytes,
                        selection: plan.selection
                    )
                }

                switch outcome {
                case .success(let execution):
                    completed.insert(execution.scheduled.request.id)
                    fragments.append(execution.fragment)
                    maximumExpansionDepth = max(
                        maximumExpansionDepth,
                        execution.scheduled.expansionDepth
                    )
                    try enforceDiagnosticPolicy(execution.fragment)
                    try addFollowUpRequests(
                        execution.fragment.followUpRequests,
                        emittedBy: execution.scheduled,
                        plan: plan,
                        knownRequests: &knownRequests,
                        pending: &pending,
                        completed: completed,
                        unavailable: unavailable
                    )
                case .failure(let failure):
                    unavailable.insert(failure.scheduled.request.id)
                    if !failure.scheduled.request.optional {
                        throw DatasetAcquisitionError.requestFailed(
                            request: failure.scheduled.request.id,
                            description: failure.description
                        )
                    }
                }
            }
        }

        let sortedFragments = fragments.sorted { $0.requestID < $1.requestID }
        let batch = try assembler.assemble(
            plan: plan,
            fragments: sortedFragments
        )
        if plan.enforceRuntimeBudget {
            try validateFinalBudgets(
                batch: batch,
                fragments: sortedFragments,
                selection: plan.selection
            )
        }
        if !configuration.allowEmptyEvidenceBatch,
           batch.assets.isEmpty,
           batch.records.isEmpty {
            throw DatasetAcquisitionError.emptyEvidenceBatch(plan.id)
        }

        let completedAt = Date()
        let cacheStatistics = await cache?.statistics()
        let uniqueEntities = Set(batch.records.map { $0.entity.stableKey }).count
        let partitionCount = Set(
            sortedFragments.flatMap(\.partitions).map(\.id)
        ).count
        let diagnostics = sortedFragments.flatMap(\.diagnostics)
        let report = DatasetAcquisitionReport(
            acquisitionID: plan.id,
            adapterID: plan.adapterID,
            datasetReference: plan.dataset.stableReference,
            startedAt: startedAt,
            completedAt: completedAt,
            requestReports: requestReports.sorted { $0.requestID < $1.requestID },
            fragmentCount: sortedFragments.count,
            assetCount: batch.assets.count,
            partitionCount: partitionCount,
            evidenceRecordCount: batch.records.count,
            uniqueEntityCount: uniqueEntities,
            networkTransferredBytes: networkTransferredBytes,
            decodedBudgetBytes: decodedBudgetBytes,
            maximumExpansionDepth: maximumExpansionDepth,
            cacheStatistics: cacheStatistics,
            metadata: [
                "numitissue.data.completed-requests": String(completed.count),
                "numitissue.data.unavailable-requests": String(unavailable.count),
                "numitissue.data.total-requests": String(knownRequests.count),
                "numitissue.data.diagnostics.information": String(
                    diagnostics.filter { $0.severity == .information }.count
                ),
                "numitissue.data.diagnostics.warning": String(
                    diagnostics.filter { $0.severity == .warning }.count
                ),
                "numitissue.data.diagnostics.error": String(
                    diagnostics.filter { $0.severity == .error }.count
                )
            ]
        )
        return DatasetAcquisitionResult(
            plan: plan,
            batch: batch,
            fragments: sortedFragments,
            report: report
        )
    }
}

private extension DatasetAcquisitionEngine {
    struct ScheduledDatasetRequest: Sendable, Equatable {
        var request: DatasetQueryRequest
        var expansionDepth: Int
    }

    struct SuccessfulRequestExecution: Sendable {
        var scheduled: ScheduledDatasetRequest
        var fragment: DatasetDecodedFragment
        var report: DatasetRequestAcquisitionReport
    }

    struct FailedRequestExecution: Sendable {
        var scheduled: ScheduledDatasetRequest
        var description: String
        var report: DatasetRequestAcquisitionReport
    }

    enum RequestExecutionOutcome: Sendable {
        case success(SuccessfulRequestExecution)
        case failure(FailedRequestExecution)

        var requestID: String {
            switch self {
            case .success(let value): return value.scheduled.request.id
            case .failure(let value): return value.scheduled.request.id
            }
        }

        var report: DatasetRequestAcquisitionReport {
            switch self {
            case .success(let value): return value.report
            case .failure(let value): return value.report
            }
        }
    }

    struct FetchedDatasetResponse: Sendable {
        var response: BiologicalDataResponse
        var disposition: DatasetRequestDisposition
        var networkTransferredBytes: UInt64
    }

    func executeReady(
        _ requests: [ScheduledDatasetRequest],
        plan: DatasetQueryPlan,
        startedAt: Date,
        completedRequestIDs: Set<String>,
        maximumConcurrency: Int
    ) async -> [RequestExecutionOutcome] {
        await withTaskGroup(of: RequestExecutionOutcome.self) { group in
            var iterator = requests.makeIterator()
            var active = 0
            var outcomes: [RequestExecutionOutcome] = []
            outcomes.reserveCapacity(requests.count)

            while active < maximumConcurrency,
                  let request = iterator.next() {
                active += 1
                group.addTask {
                    await executeOne(
                        request,
                        plan: plan,
                        startedAt: startedAt,
                        completedRequestIDs: completedRequestIDs
                    )
                }
            }
            while let outcome = await group.next() {
                outcomes.append(outcome)
                active -= 1
                if let request = iterator.next() {
                    active += 1
                    group.addTask {
                        await executeOne(
                            request,
                            plan: plan,
                            startedAt: startedAt,
                            completedRequestIDs: completedRequestIDs
                        )
                    }
                }
            }
            return outcomes
        }
    }

    func executeOne(
        _ scheduled: ScheduledDatasetRequest,
        plan: DatasetQueryPlan,
        startedAt: Date,
        completedRequestIDs: Set<String>
    ) async -> RequestExecutionOutcome {
        let request = scheduled.request
        var fetched: FetchedDatasetResponse?
        var decodeStartedAt: Date?
        do {
            try Task.checkCancellation()
            let fetchedValue = try await fetch(request)
            fetched = fetchedValue
            let decodeStart = Date()
            decodeStartedAt = decodeStart
            let context = DatasetDecodeContext(
                adapterID: plan.adapterID,
                acquisitionID: plan.id,
                dataset: plan.dataset,
                selection: plan.selection,
                expansionDepth: scheduled.expansionDepth,
                acquisitionStartedAt: startedAt,
                completedRequestIDs: completedRequestIDs,
                metadata: plan.metadata
            )
            let fragment = try await decoders.decode(DatasetDecodeInput(
                request: request,
                response: fetchedValue.response,
                context: context
            ))
            let decodeDuration = max(0, Date().timeIntervalSince(decodeStart))
            let report = makeReport(
                scheduled: scheduled,
                fetched: fetchedValue,
                decodeDurationSeconds: decodeDuration,
                errorDescription: nil
            )
            return .success(SuccessfulRequestExecution(
                scheduled: scheduled,
                fragment: fragment,
                report: report
            ))
        } catch {
            let description = String(describing: error)
            let decodeDuration = decodeStartedAt.map {
                max(0, Date().timeIntervalSince($0))
            } ?? 0
            let report: DatasetRequestAcquisitionReport
            if let fetched {
                report = makeReport(
                    scheduled: scheduled,
                    fetched: fetched,
                    decodeDurationSeconds: decodeDuration,
                    errorDescription: description
                )
            } else {
                report = DatasetRequestAcquisitionReport(
                    requestID: request.id,
                    decoderID: request.decoderID,
                    disposition: request.optional ? .optionalFailure : .failed,
                    expansionDepth: scheduled.expansionDepth,
                    errorDescription: description,
                    dependencyIDs: request.dependencies.sorted()
                )
            }
            return .failure(FailedRequestExecution(
                scheduled: scheduled,
                description: description,
                report: report
            ))
        }
    }

    func makeReport(
        scheduled: ScheduledDatasetRequest,
        fetched: FetchedDatasetResponse,
        decodeDurationSeconds: Double,
        errorDescription: String?
    ) -> DatasetRequestAcquisitionReport {
        let request = scheduled.request
        let payloadBytes = UInt64(fetched.response.data.count)
        let decodedCharge = max(
            payloadBytes,
            request.estimatedDecodedBytes ?? 0
        )
        let digest = request.method == .head
            ? nil
            : ScientificSHA256Digest(data: fetched.response.data).hexadecimal
        return DatasetRequestAcquisitionReport(
            requestID: request.id,
            decoderID: request.decoderID,
            disposition: errorDescription == nil
                ? fetched.disposition
                : (request.optional ? .optionalFailure : .failed),
            expansionDepth: scheduled.expansionDepth,
            statusCode: fetched.response.statusCode,
            payloadBytes: payloadBytes,
            decodedBudgetBytes: decodedCharge,
            networkTransferredBytes: fetched.networkTransferredBytes,
            contentDigest: digest,
            transferDurationSeconds: fetched.response.transferDurationSeconds,
            decodeDurationSeconds: decodeDurationSeconds,
            finalLocator: fetched.response.finalLocator.canonicalDescription,
            errorDescription: errorDescription,
            dependencyIDs: request.dependencies.sorted()
        )
    }

    func fetch(_ request: DatasetQueryRequest) async throws -> FetchedDatasetResponse {
        _ = try request.validated()
        let key = DatasetCacheKey(request: request)
        var staleCached: DatasetCachedResponse?

        if request.cachePolicy != .bypass, let cache,
           let cached = try await cache.lookup(key, allowExpired: true) {
            let rebound = cached.rebindingRequestID(request.id)
            if cached.record.isFresh() {
                try validateResponse(rebound.response, for: request)
                return FetchedDatasetResponse(
                    response: rebound.response,
                    disposition: .cacheHit,
                    networkTransferredBytes: 0
                )
            }
            staleCached = rebound
        }

        let conditionalHeaders: [String: String]
        if staleCached != nil,
           request.cachePolicy == .revalidate,
           let cache {
            conditionalHeaders = await cache.conditionalHeaders(for: key)
        } else {
            conditionalHeaders = [:]
        }
        let maximumBytes = min(
            configuration.maximumResponseBytesPerRequest,
            request.expectedByteCount ??
                configuration.maximumResponseBytesPerRequest
        )
        let transportRequest = BiologicalDataRequest(
            query: request,
            maximumResponseBytes: maximumBytes,
            additionalHeaders: conditionalHeaders
        )
        let response = try await transport.execute(transportRequest)

        if response.isNotModified {
            guard let cache,
                  let refreshed = try await cache.refreshAfterNotModified(key) else {
                throw DatasetAcquisitionError.notModifiedWithoutCachedEntity(
                    request.id
                )
            }
            let rebound = refreshed.rebindingRequestID(request.id)
            try validateResponse(rebound.response, for: request)
            return FetchedDatasetResponse(
                response: rebound.response,
                disposition: .cacheRevalidated,
                networkTransferredBytes: 0
            )
        }

        try validateResponse(response, for: request)
        if let cache {
            _ = try await cache.store(response: response, for: request)
        }
        return FetchedDatasetResponse(
            response: response,
            disposition: .network,
            networkTransferredBytes: UInt64(response.data.count)
        )
    }

    func validateResponse(
        _ response: BiologicalDataResponse,
        for request: DatasetQueryRequest
    ) throws {
        guard response.requestID == request.id,
              response.isSuccess else {
            throw DatasetAcquisitionError.invalidResponse(request.id)
        }
        _ = try response.finalLocator.validated()

        let receivedBytes = UInt64(response.data.count)
        guard receivedBytes <= configuration.maximumResponseBytesPerRequest else {
            throw DatasetAcquisitionError.responseTooLarge(
                request: request.id,
                actual: receivedBytes,
                maximum: configuration.maximumResponseBytesPerRequest
            )
        }
        if configuration.requireDeclaredChecksum,
           request.method != .head,
           request.expectedChecksum == nil {
            throw DatasetAcquisitionError.missingDeclaredChecksum(request.id)
        }
        if let expected = request.expectedChecksum,
           request.method != .head {
            let actual = ScientificSHA256Digest(data: response.data)
            guard actual == expected else {
                throw DatasetAcquisitionError.checksumMismatch(
                    request: request.id,
                    expected: expected.hexadecimal,
                    actual: actual.hexadecimal
                )
            }
        }
        if configuration.verifyExpectedByteCount,
           let expected = request.expectedByteCount {
            let actual: UInt64
            if request.method == .head,
               let contentLength = response.header("content-length"),
               let parsed = UInt64(contentLength) {
                actual = parsed
            } else {
                actual = receivedBytes
            }
            guard actual == expected else {
                throw DatasetAcquisitionError.byteCountMismatch(
                    request: request.id,
                    expected: expected,
                    actual: actual
                )
            }
        }
        if configuration.verifyContentLengthHeader,
           request.method != .head,
           response.header("content-encoding") == nil,
           let contentLength = response.header("content-length"),
           let parsed = UInt64(contentLength),
           parsed != receivedBytes {
            throw DatasetAcquisitionError.contentLengthHeaderMismatch(
                request: request.id,
                declared: parsed,
                actual: receivedBytes
            )
        }
        if configuration.verifyExpectedMediaType,
           let expected = request.expectedMediaType {
            guard let actualHeader = response.contentType else {
                if configuration.requireMediaTypeHeaderWhenDeclared {
                    throw DatasetAcquisitionError.missingMediaType(request.id)
                }
                return
            }
            let actual = normalizedMediaType(actualHeader)
            let normalizedExpected = normalizedMediaType(expected)
            guard mediaTypesCompatible(
                expected: normalizedExpected,
                actual: actual
            ) else {
                throw DatasetAcquisitionError.mediaTypeMismatch(
                    request: request.id,
                    expected: normalizedExpected,
                    actual: actual
                )
            }
        }
    }

    func addFollowUpRequests(
        _ sourceRequests: [DatasetQueryRequest],
        emittedBy source: ScheduledDatasetRequest,
        plan: DatasetQueryPlan,
        knownRequests: inout [String: ScheduledDatasetRequest],
        pending: inout [String: ScheduledDatasetRequest],
        completed: Set<String>,
        unavailable: Set<String>
    ) throws {
        guard !sourceRequests.isEmpty else { return }
        let depth = source.expansionDepth + 1
        guard depth <= configuration.maximumExpansionDepth else {
            throw DatasetAcquisitionError.expansionDepthExceeded(
                request: source.request.id,
                depth: depth,
                maximum: configuration.maximumExpansionDepth
            )
        }

        var staged = knownRequests
        var stagedPending = pending
        for sourceFollowUp in sourceRequests.sorted(by: queryRequestOrder) {
            var followUp = sourceFollowUp
            if configuration.requireExpansionParentDependency,
               !followUp.dependencies.contains(source.request.id) {
                followUp.dependencies.append(source.request.id)
                followUp.dependencies.sort()
            }
            _ = try followUp.validated()
            if let existing = staged[followUp.id] {
                guard existing.request == followUp else {
                    throw DatasetAcquisitionError.conflictingDynamicRequest(
                        followUp.id
                    )
                }
                continue
            }
            guard !completed.contains(followUp.id),
                  !unavailable.contains(followUp.id) else {
                throw DatasetAcquisitionError.reusedCompletedRequest(followUp.id)
            }
            let scheduled = ScheduledDatasetRequest(
                request: followUp,
                expansionDepth: depth
            )
            staged[followUp.id] = scheduled
            stagedPending[followUp.id] = scheduled
        }

        let knownIDs = Set(staged.keys)
        let missing = staged.values.flatMap { scheduled in
            scheduled.request.dependencies.filter { !knownIDs.contains($0) }
        }
        guard missing.isEmpty else {
            throw DatasetAcquisitionError.unknownDynamicDependency(
                Array(Set(missing)).sorted()
            )
        }
        try validateAcyclic(staged.values.map(\.request))
        try validatePlannedBudgets(
            plan: plan,
            requests: Array(staged.values)
        )
        knownRequests = staged
        pending = stagedPending
    }

    func validateAcyclic(_ requests: [DatasetQueryRequest]) throws {
        var indegree = Dictionary(uniqueKeysWithValues: requests.map {
            ($0.id, $0.dependencies.count)
        })
        var dependents: [String: [String]] = [:]
        for request in requests {
            for dependency in request.dependencies {
                dependents[dependency, default: []].append(request.id)
            }
        }
        var ready = indegree.filter { $0.value == 0 }.map(\.key)
        var cursor = 0
        var visited = 0
        while cursor < ready.count {
            let identifier = ready[cursor]
            cursor += 1
            visited += 1
            for dependent in dependents[identifier] ?? [] {
                guard let degree = indegree[dependent] else { continue }
                let next = degree - 1
                indegree[dependent] = next
                if next == 0 { ready.append(dependent) }
            }
        }
        guard visited == requests.count else {
            throw DatasetAcquisitionError.dynamicDependencyCycle(
                indegree.filter { $0.value > 0 }.map(\.key).sorted()
            )
        }
    }

    func validatePlannedBudgets(
        plan: DatasetQueryPlan,
        requests: [ScheduledDatasetRequest]
    ) throws {
        let requestCount = UInt64(requests.count)
        guard requestCount <= configuration.maximumTotalRequests else {
            throw DatasetAcquisitionError.dynamicRequestBudgetExceeded(
                planned: requestCount,
                maximum: configuration.maximumTotalRequests
            )
        }
        guard plan.enforceRuntimeBudget else { return }

        var transfer: UInt64 = 0
        var decoded: UInt64 = 0
        for scheduled in requests {
            if let value = scheduled.request.expectedByteCount {
                transfer = try addBytes(transfer, value)
            }
            if let value = scheduled.request.estimatedDecodedBytes {
                decoded = try addBytes(decoded, value)
            }
        }
        guard transfer <= plan.selection.budget.maximumTransferredBytes else {
            throw DatasetAcquisitionError.plannedTransferBudgetExceeded(
                planned: transfer,
                maximum: plan.selection.budget.maximumTransferredBytes
            )
        }
        guard decoded <= plan.selection.budget.maximumDecodedBytes else {
            throw DatasetAcquisitionError.plannedDecodedBudgetExceeded(
                planned: decoded,
                maximum: plan.selection.budget.maximumDecodedBytes
            )
        }
    }

    func enforceRuntimeByteBudgets(
        networkTransferredBytes: UInt64,
        decodedBudgetBytes: UInt64,
        selection: DatasetSelection
    ) throws {
        guard networkTransferredBytes <=
                selection.budget.maximumTransferredBytes else {
            throw DatasetAcquisitionError.actualTransferBudgetExceeded(
                actual: networkTransferredBytes,
                maximum: selection.budget.maximumTransferredBytes
            )
        }
        guard decodedBudgetBytes <= selection.budget.maximumDecodedBytes else {
            throw DatasetAcquisitionError.actualDecodedBudgetExceeded(
                actual: decodedBudgetBytes,
                maximum: selection.budget.maximumDecodedBytes
            )
        }
    }

    func validateFinalBudgets(
        batch: EvidenceBatch,
        fragments: [DatasetDecodedFragment],
        selection: DatasetSelection
    ) throws {
        guard UInt64(batch.assets.count) <= selection.budget.maximumAssets else {
            throw DatasetAcquisitionError.finalAssetBudgetExceeded(
                actual: UInt64(batch.assets.count),
                maximum: selection.budget.maximumAssets
            )
        }
        let entities = Set(batch.records.map { $0.entity.stableKey })
        guard UInt64(entities.count) <= selection.budget.maximumEntities else {
            throw DatasetAcquisitionError.finalEntityBudgetExceeded(
                actual: UInt64(entities.count),
                maximum: selection.budget.maximumEntities
            )
        }
        let cells = Set(batch.records.compactMap {
            $0.entity.kind == .cell ? $0.entity.stableKey : nil
        })
        guard UInt64(cells.count) <= selection.budget.maximumCells else {
            throw DatasetAcquisitionError.finalCellBudgetExceeded(
                actual: UInt64(cells.count),
                maximum: selection.budget.maximumCells
            )
        }
        let synapses = Set(batch.records.compactMap {
            $0.entity.kind == .synapse ? $0.entity.stableKey : nil
        })
        guard UInt64(synapses.count) <= selection.budget.maximumSynapses else {
            throw DatasetAcquisitionError.finalSynapseBudgetExceeded(
                actual: UInt64(synapses.count),
                maximum: selection.budget.maximumSynapses
            )
        }
        let partitions = Set(fragments.flatMap(\.partitions).map(\.id))
        guard UInt64(partitions.count) <= configuration.maximumPartitions else {
            throw DatasetAcquisitionError.finalPartitionBudgetExceeded(
                actual: UInt64(partitions.count),
                maximum: configuration.maximumPartitions
            )
        }
    }

    func enforceDiagnosticPolicy(
        _ fragment: DatasetDecodedFragment
    ) throws {
        if configuration.failOnDecoderErrorDiagnostics,
           let diagnostic = fragment.diagnostics.first(where: {
               $0.severity == .error
           }) {
            throw DatasetAcquisitionError.decoderDiagnostic(
                request: fragment.requestID,
                code: diagnostic.code,
                message: diagnostic.message
            )
        }
        if configuration.failOnDecoderWarningDiagnostics,
           let diagnostic = fragment.diagnostics.first(where: {
               $0.severity == .warning
           }) {
            throw DatasetAcquisitionError.decoderDiagnostic(
                request: fragment.requestID,
                code: diagnostic.code,
                message: diagnostic.message
            )
        }
    }

    func normalizedMediaType(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    func mediaTypesCompatible(expected: String, actual: String) -> Bool {
        if expected == actual { return true }
        if expected == "application/json",
           actual.hasPrefix("application/"),
           actual.hasSuffix("+json") {
            return true
        }
        return false
    }

    func addBytes(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw DatasetAcquisitionError.byteCountOverflow
        }
        return value
    }

    func scheduledRequestOrder(
        _ lhs: ScheduledDatasetRequest,
        _ rhs: ScheduledDatasetRequest
    ) -> Bool {
        queryRequestOrder(lhs.request, rhs.request)
    }

    func queryRequestOrder(
        _ lhs: DatasetQueryRequest,
        _ rhs: DatasetQueryRequest
    ) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.id < rhs.id
    }
}

private extension DatasetCachedResponse {
    func rebindingRequestID(_ identifier: String) -> DatasetCachedResponse {
        var result = self
        result.response.requestID = identifier
        return result
    }
}

private extension Array where Element == String {
    func isDisjoint(with values: Set<String>) -> Bool {
        !contains(where: values.contains)
    }
}

public enum DatasetAcquisitionError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case requestFailed(request: String, description: String)
    case requiredDependencyUnavailable(request: String, dependencies: [String])
    case unknownDynamicDependency([String])
    case dynamicDependencyCycle([String])
    case conflictingDynamicRequest(String)
    case reusedCompletedRequest(String)
    case expansionDepthExceeded(request: String, depth: Int, maximum: Int)
    case dynamicRequestBudgetExceeded(planned: UInt64, maximum: UInt64)
    case plannedTransferBudgetExceeded(planned: UInt64, maximum: UInt64)
    case plannedDecodedBudgetExceeded(planned: UInt64, maximum: UInt64)
    case actualTransferBudgetExceeded(actual: UInt64, maximum: UInt64)
    case actualDecodedBudgetExceeded(actual: UInt64, maximum: UInt64)
    case finalAssetBudgetExceeded(actual: UInt64, maximum: UInt64)
    case finalEntityBudgetExceeded(actual: UInt64, maximum: UInt64)
    case finalCellBudgetExceeded(actual: UInt64, maximum: UInt64)
    case finalSynapseBudgetExceeded(actual: UInt64, maximum: UInt64)
    case finalPartitionBudgetExceeded(actual: UInt64, maximum: UInt64)
    case invalidResponse(String)
    case responseTooLarge(request: String, actual: UInt64, maximum: UInt64)
    case missingDeclaredChecksum(String)
    case checksumMismatch(request: String, expected: String, actual: String)
    case byteCountMismatch(request: String, expected: UInt64, actual: UInt64)
    case contentLengthHeaderMismatch(request: String, declared: UInt64, actual: UInt64)
    case missingMediaType(String)
    case mediaTypeMismatch(request: String, expected: String, actual: String)
    case notModifiedWithoutCachedEntity(String)
    case decoderDiagnostic(request: String, code: String, message: String)
    case emptyEvidenceBatch(String)
    case byteCountOverflow

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Dataset acquisition configuration is invalid."
        case .requestFailed(let request, let description):
            return "Dataset request \(request) failed: \(description)"
        case .requiredDependencyUnavailable(let request, let dependencies):
            return "Required request \(request) has unavailable dependencies: \(dependencies.joined(separator: ", "))."
        case .unknownDynamicDependency(let dependencies):
            return "Dynamic request graph references unknown dependencies: \(dependencies.joined(separator: ", "))."
        case .dynamicDependencyCycle(let requests):
            return "Dynamic request graph contains a cycle among: \(requests.joined(separator: ", "))."
        case .conflictingDynamicRequest(let request):
            return "Dynamic request \(request) has conflicting definitions."
        case .reusedCompletedRequest(let request):
            return "Dynamic request \(request) reuses a completed or unavailable identifier."
        case .expansionDepthExceeded(let request, let depth, let maximum):
            return "Dynamic request \(request) reaches depth \(depth); maximum is \(maximum)."
        case .dynamicRequestBudgetExceeded(let planned, let maximum):
            return "Acquisition planned \(planned) requests; maximum is \(maximum)."
        case .plannedTransferBudgetExceeded(let planned, let maximum):
            return "Acquisition plans \(planned) transferred bytes; maximum is \(maximum)."
        case .plannedDecodedBudgetExceeded(let planned, let maximum):
            return "Acquisition plans \(planned) decoded bytes; maximum is \(maximum)."
        case .actualTransferBudgetExceeded(let actual, let maximum):
            return "Acquisition transferred \(actual) bytes; maximum is \(maximum)."
        case .actualDecodedBudgetExceeded(let actual, let maximum):
            return "Acquisition charged \(actual) decoded bytes; maximum is \(maximum)."
        case .finalAssetBudgetExceeded(let actual, let maximum):
            return "Acquisition produced \(actual) assets; maximum is \(maximum)."
        case .finalEntityBudgetExceeded(let actual, let maximum):
            return "Acquisition produced \(actual) entities; maximum is \(maximum)."
        case .finalCellBudgetExceeded(let actual, let maximum):
            return "Acquisition produced \(actual) cells; maximum is \(maximum)."
        case .finalSynapseBudgetExceeded(let actual, let maximum):
            return "Acquisition produced \(actual) synapses; maximum is \(maximum)."
        case .finalPartitionBudgetExceeded(let actual, let maximum):
            return "Acquisition produced \(actual) partitions; maximum is \(maximum)."
        case .invalidResponse(let request):
            return "Dataset response for request \(request) is invalid."
        case .responseTooLarge(let request, let actual, let maximum):
            return "Dataset response \(request) uses \(actual) bytes; maximum is \(maximum)."
        case .missingDeclaredChecksum(let request):
            return "Dataset request \(request) has no declared checksum."
        case .checksumMismatch(let request, let expected, let actual):
            return "Dataset request \(request) checksum mismatch: expected \(expected), received \(actual)."
        case .byteCountMismatch(let request, let expected, let actual):
            return "Dataset request \(request) byte-count mismatch: expected \(expected), received \(actual)."
        case .contentLengthHeaderMismatch(let request, let declared, let actual):
            return "Dataset response \(request) declared \(declared) bytes but delivered \(actual)."
        case .missingMediaType(let request):
            return "Dataset response \(request) has no media type."
        case .mediaTypeMismatch(let request, let expected, let actual):
            return "Dataset request \(request) media type mismatch: expected \(expected), received \(actual)."
        case .notModifiedWithoutCachedEntity(let request):
            return "Dataset request \(request) returned 304 without a cached entity."
        case .decoderDiagnostic(let request, let code, let message):
            return "Dataset decoder for \(request) emitted \(code): \(message)"
        case .emptyEvidenceBatch(let acquisition):
            return "Dataset acquisition \(acquisition) produced no assets or evidence."
        case .byteCountOverflow:
            return "Dataset acquisition byte-count accumulation overflowed."
        }
    }
}
