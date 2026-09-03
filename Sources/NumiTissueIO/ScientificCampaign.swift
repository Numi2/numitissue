import Foundation

public struct ScientificCampaignTrial: Sendable, Hashable, Codable {
    public var id: UInt64
    public var randomSeed: UInt64
    public var estimatedWorkUnits: UInt64
    public var modelDigest: ScientificSHA256Digest
    public var parameterDigest: ScientificSHA256Digest?
    public var requiredArtifactDigests: [ScientificSHA256Digest]
    public var metadata: [String: String]

    public init(
        id: UInt64,
        randomSeed: UInt64,
        estimatedWorkUnits: UInt64 = 1,
        modelDigest: ScientificSHA256Digest,
        parameterDigest: ScientificSHA256Digest? = nil,
        requiredArtifactDigests: [ScientificSHA256Digest] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.randomSeed = randomSeed
        self.estimatedWorkUnits = estimatedWorkUnits
        self.modelDigest = modelDigest
        self.parameterDigest = parameterDigest
        self.requiredArtifactDigests = requiredArtifactDigests
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard estimatedWorkUnits > 0,
              Set(requiredArtifactDigests).count == requiredArtifactDigests.count else {
            throw ScientificCampaignError.invalidTrial(id)
        }
        return self
    }
}

public struct ScientificCampaignShard: Sendable, Hashable, Codable {
    public var id: UUID
    public var index: Int
    public var trials: [ScientificCampaignTrial]
    public var totalEstimatedWorkUnits: UInt64
    public var digest: ScientificSHA256Digest

    public init(
        id: UUID,
        index: Int,
        trials: [ScientificCampaignTrial],
        totalEstimatedWorkUnits: UInt64,
        digest: ScientificSHA256Digest
    ) {
        self.id = id
        self.index = index
        self.trials = trials
        self.totalEstimatedWorkUnits = totalEstimatedWorkUnits
        self.digest = digest
    }

    public func validated() throws -> Self {
        guard index >= 0,
              !trials.isEmpty,
              Set(trials.map(\.id)).count == trials.count else {
            throw ScientificCampaignError.invalidShard(index)
        }
        var total: UInt64 = 0
        for trial in trials {
            _ = try trial.validated()
            let (next, overflow) = total.addingReportingOverflow(
                trial.estimatedWorkUnits
            )
            guard !overflow else { throw ScientificCampaignError.workOverflow }
            total = next
        }
        guard total == totalEstimatedWorkUnits,
              try ScientificCampaignSharder.digest(
                  index: index,
                  trials: trials
              ) == digest else {
            throw ScientificCampaignError.invalidShard(index)
        }
        return self
    }
}

public struct ScientificCampaignManifest: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var shards: [ScientificCampaignShard]
    public var trialCount: Int
    public var totalEstimatedWorkUnits: UInt64
    public var campaignDigest: ScientificSHA256Digest
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        shards: [ScientificCampaignShard],
        trialCount: Int,
        totalEstimatedWorkUnits: UInt64,
        campaignDigest: ScientificSHA256Digest,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.shards = shards
        self.trialCount = trialCount
        self.totalEstimatedWorkUnits = totalEstimatedWorkUnits
        self.campaignDigest = campaignDigest
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !name.isEmpty,
              !shards.isEmpty,
              Set(shards.map(\.id)).count == shards.count,
              Set(shards.map(\.index)).count == shards.count,
              shards.map(\.index).sorted() == Array(0..<shards.count) else {
            throw ScientificCampaignError.invalidManifest
        }
        for shard in shards { _ = try shard.validated() }
        let trials = shards.flatMap(\.trials)
        guard trialCount == trials.count,
              Set(trials.map(\.id)).count == trials.count else {
            throw ScientificCampaignError.invalidManifest
        }
        var total: UInt64 = 0
        for shard in shards {
            let (next, overflow) = total.addingReportingOverflow(
                shard.totalEstimatedWorkUnits
            )
            guard !overflow else { throw ScientificCampaignError.workOverflow }
            total = next
        }
        guard total == totalEstimatedWorkUnits,
              try ScientificCampaignSharder.campaignDigest(
                  name: name,
                  shards: shards
              ) == campaignDigest else {
            throw ScientificCampaignError.invalidManifest
        }
        return self
    }

    public func writeAtomically(to url: URL) throws {
        let data = try ScientificCanonicalJSON.encode(try validated())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}

public enum ScientificCampaignSharder {
    public static func makeManifest(
        name: String,
        trials sourceTrials: [ScientificCampaignTrial],
        shardCount requestedShardCount: Int,
        campaignID: UUID = UUID(),
        createdAt: Date = Date(),
        metadata: [String: String] = [:]
    ) throws -> ScientificCampaignManifest {
        guard !name.isEmpty,
              !sourceTrials.isEmpty,
              requestedShardCount > 0,
              Set(sourceTrials.map(\.id)).count == sourceTrials.count else {
            throw ScientificCampaignError.invalidShardingRequest
        }
        let trials = try sourceTrials.map { try $0.validated() }
        let shardCount = min(requestedShardCount, trials.count)
        let ordered = trials.sorted {
            if $0.estimatedWorkUnits != $1.estimatedWorkUnits {
                return $0.estimatedWorkUnits > $1.estimatedWorkUnits
            }
            return $0.id < $1.id
        }
        var assignments = Array(repeating: [ScientificCampaignTrial](), count: shardCount)
        var loads = Array(repeating: UInt64(0), count: shardCount)

        for trial in ordered {
            let selected = (0..<shardCount).min { lhs, rhs in
                if loads[lhs] != loads[rhs] { return loads[lhs] < loads[rhs] }
                return lhs < rhs
            } ?? 0
            let (next, overflow) = loads[selected].addingReportingOverflow(
                trial.estimatedWorkUnits
            )
            guard !overflow else { throw ScientificCampaignError.workOverflow }
            assignments[selected].append(trial)
            loads[selected] = next
        }

        var shards: [ScientificCampaignShard] = []
        shards.reserveCapacity(shardCount)
        for index in 0..<shardCount {
            let sortedTrials = assignments[index].sorted { $0.id < $1.id }
            shards.append(ScientificCampaignShard(
                id: deterministicShardID(
                    campaignID: campaignID,
                    index: index
                ),
                index: index,
                trials: sortedTrials,
                totalEstimatedWorkUnits: loads[index],
                digest: try digest(index: index, trials: sortedTrials)
            ))
        }
        let total = try loads.reduce(UInt64(0)) { partial, value in
            let (next, overflow) = partial.addingReportingOverflow(value)
            guard !overflow else { throw ScientificCampaignError.workOverflow }
            return next
        }
        return try ScientificCampaignManifest(
            id: campaignID,
            name: name,
            createdAt: createdAt,
            shards: shards,
            trialCount: trials.count,
            totalEstimatedWorkUnits: total,
            campaignDigest: campaignDigest(name: name, shards: shards),
            metadata: metadata
        ).validated()
    }

    static func digest(
        index: Int,
        trials: [ScientificCampaignTrial]
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var index: Int
            var trials: [ScientificCampaignTrial]
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(index: index, trials: trials)
            )
        )
    }

    static func campaignDigest(
        name: String,
        shards: [ScientificCampaignShard]
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var name: String
            var shardDigests: [ScientificSHA256Digest]
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(Payload(
                name: name,
                shardDigests: shards.sorted { $0.index < $1.index }.map(\.digest)
            ))
        )
    }

    private static func deterministicShardID(
        campaignID: UUID,
        index: Int
    ) -> UUID {
        let digest = ScientificSHA256Digest(
            data: Data("\(campaignID.uuidString):\(index)".utf8)
        ).hexadecimal
        let text = String(digest.prefix(32))
        var components: [String] = []
        components.reserveCapacity(5)
        components.append(String(text.prefix(8)))
        components.append(String(text.dropFirst(8).prefix(4)))
        components.append(String(text.dropFirst(12).prefix(4)))
        components.append(String(text.dropFirst(16).prefix(4)))
        components.append(String(text.dropFirst(20).prefix(12)))
        let formatted = components.joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}

public enum ScientificCampaignWorkStatus: String, Sendable, Hashable, Codable {
    case pending
    case leased
    case running
    case completed
    case failed
    case cancelled
}

public enum ScientificCampaignEventKind: String, Sendable, Hashable, Codable {
    case campaignCreated
    case shardLeased
    case shardStarted
    case trialStarted
    case trialCompleted
    case trialFailed
    case shardCompleted
    case shardFailed
    case leaseReleased
    case leaseExpired
    case campaignCompleted
    case campaignCancelled
}

public struct ScientificCampaignJournalEvent: Sendable, Hashable, Codable {
    public var sequence: UInt64
    public var eventID: UUID
    public var campaignID: UUID
    public var shardID: UUID?
    public var trialID: UInt64?
    public var kind: ScientificCampaignEventKind
    public var timestamp: Date
    public var workerID: String?
    public var leaseID: UUID?
    public var leaseExpiresAt: Date?
    public var runManifestDigest: ScientificSHA256Digest?
    public var message: String?
    public var metadata: [String: String]

    public init(
        sequence: UInt64,
        eventID: UUID = UUID(),
        campaignID: UUID,
        shardID: UUID? = nil,
        trialID: UInt64? = nil,
        kind: ScientificCampaignEventKind,
        timestamp: Date = Date(),
        workerID: String? = nil,
        leaseID: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        runManifestDigest: ScientificSHA256Digest? = nil,
        message: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sequence = sequence
        self.eventID = eventID
        self.campaignID = campaignID
        self.shardID = shardID
        self.trialID = trialID
        self.kind = kind
        self.timestamp = timestamp
        self.workerID = workerID
        self.leaseID = leaseID
        self.leaseExpiresAt = leaseExpiresAt
        self.runManifestDigest = runManifestDigest
        self.message = message
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard workerID?.isEmpty != true,
              message?.isEmpty != true else {
            throw ScientificCampaignError.invalidEvent(sequence)
        }
        switch kind {
        case .campaignCreated, .campaignCompleted, .campaignCancelled:
            guard shardID == nil, trialID == nil else {
                throw ScientificCampaignError.invalidEvent(sequence)
            }
        case .shardLeased:
            guard shardID != nil,
                  trialID == nil,
                  workerID != nil,
                  leaseID != nil,
                  let leaseExpiresAt,
                  leaseExpiresAt > timestamp else {
                throw ScientificCampaignError.invalidEvent(sequence)
            }
        case .trialStarted, .trialCompleted, .trialFailed:
            guard shardID != nil, trialID != nil else {
                throw ScientificCampaignError.invalidEvent(sequence)
            }
        default:
            guard shardID != nil, trialID == nil else {
                throw ScientificCampaignError.invalidEvent(sequence)
            }
        }
        if kind == .trialCompleted, runManifestDigest == nil {
            throw ScientificCampaignError.invalidEvent(sequence)
        }
        return self
    }
}

public struct ScientificCampaignLease: Sendable, Hashable, Codable {
    public var leaseID: UUID
    public var shardID: UUID
    public var workerID: String
    public var acquiredAt: Date
    public var expiresAt: Date

    public init(
        leaseID: UUID,
        shardID: UUID,
        workerID: String,
        acquiredAt: Date,
        expiresAt: Date
    ) {
        self.leaseID = leaseID
        self.shardID = shardID
        self.workerID = workerID
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
    }

    public func isActive(at date: Date) -> Bool { expiresAt > date }
}

public struct ScientificCampaignLedgerState: Sendable, Hashable, Codable {
    public var campaignID: UUID
    public var lastSequence: UInt64?
    public var shardStatus: [UUID: ScientificCampaignWorkStatus]
    public var trialStatus: [UInt64: ScientificCampaignWorkStatus]
    public var activeLeases: [UUID: ScientificCampaignLease]
    public var completedRunDigests: [UInt64: ScientificSHA256Digest]
    public var failedMessages: [UInt64: String]
    public var cancelled: Bool
    public var completed: Bool

    public init(manifest: ScientificCampaignManifest) {
        campaignID = manifest.id
        lastSequence = nil
        shardStatus = Dictionary(
            uniqueKeysWithValues: manifest.shards.map { ($0.id, .pending) }
        )
        trialStatus = Dictionary(
            uniqueKeysWithValues: manifest.shards.flatMap(\.trials).map {
                ($0.id, .pending)
            }
        )
        activeLeases = [:]
        completedRunDigests = [:]
        failedMessages = [:]
        cancelled = false
        completed = false
    }

    public mutating func apply(
        _ sourceEvent: ScientificCampaignJournalEvent,
        manifest: ScientificCampaignManifest
    ) throws {
        let event = try sourceEvent.validated()
        guard event.campaignID == campaignID else {
            throw ScientificCampaignError.campaignMismatch
        }
        if let lastSequence {
            guard event.sequence == lastSequence + 1 else {
                throw ScientificCampaignError.nonContiguousSequence
            }
        } else if event.sequence != 0 {
            throw ScientificCampaignError.nonContiguousSequence
        }
        guard !cancelled || event.kind == .campaignCancelled else {
            throw ScientificCampaignError.invalidTransition(event.sequence)
        }

        switch event.kind {
        case .campaignCreated:
            guard lastSequence == nil else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
        case .shardLeased:
            guard let shardID = event.shardID,
                  shardStatus[shardID] == .pending,
                  let leaseID = event.leaseID,
                  let workerID = event.workerID,
                  let expiresAt = event.leaseExpiresAt else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            activeLeases[shardID] = ScientificCampaignLease(
                leaseID: leaseID,
                shardID: shardID,
                workerID: workerID,
                acquiredAt: event.timestamp,
                expiresAt: expiresAt
            )
            shardStatus[shardID] = .leased
        case .shardStarted:
            guard let shardID = event.shardID,
                  shardStatus[shardID] == .leased,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            shardStatus[shardID] = .running
        case .trialStarted:
            guard let shardID = event.shardID,
                  let trialID = event.trialID,
                  shardStatus[shardID] == .running,
                  trialBelongs(trialID, to: shardID, manifest: manifest),
                  trialStatus[trialID] == .pending,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            trialStatus[trialID] = .running
        case .trialCompleted:
            guard let shardID = event.shardID,
                  let trialID = event.trialID,
                  trialStatus[trialID] == .running,
                  let digest = event.runManifestDigest,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            trialStatus[trialID] = .completed
            completedRunDigests[trialID] = digest
        case .trialFailed:
            guard let shardID = event.shardID,
                  let trialID = event.trialID,
                  trialStatus[trialID] == .running,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            trialStatus[trialID] = .failed
            failedMessages[trialID] = event.message ?? "unspecified failure"
        case .shardCompleted:
            guard let shardID = event.shardID,
                  shardStatus[shardID] == .running,
                  leaseMatches(event, shardID: shardID),
                  shardTrials(shardID, manifest: manifest).allSatisfy({
                      trialStatus[$0.id] == .completed
                  }) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            shardStatus[shardID] = .completed
            activeLeases.removeValue(forKey: shardID)
        case .shardFailed:
            guard let shardID = event.shardID,
                  shardStatus[shardID] == .running,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            shardStatus[shardID] = .failed
            activeLeases.removeValue(forKey: shardID)
        case .leaseReleased, .leaseExpired:
            guard let shardID = event.shardID,
                  shardStatus[shardID] == .leased
                    || shardStatus[shardID] == .running,
                  leaseMatches(event, shardID: shardID) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            shardStatus[shardID] = .pending
            activeLeases.removeValue(forKey: shardID)
            for trial in shardTrials(shardID, manifest: manifest)
                where trialStatus[trial.id] == .running {
                trialStatus[trial.id] = .pending
            }
        case .campaignCompleted:
            guard shardStatus.values.allSatisfy({ $0 == .completed }) else {
                throw ScientificCampaignError.invalidTransition(event.sequence)
            }
            completed = true
        case .campaignCancelled:
            cancelled = true
            for shardID in shardStatus.keys where shardStatus[shardID] != .completed {
                shardStatus[shardID] = .cancelled
            }
            for trialID in trialStatus.keys where trialStatus[trialID] != .completed {
                trialStatus[trialID] = .cancelled
            }
            activeLeases.removeAll()
        }
        lastSequence = event.sequence
    }

    public func nextPendingShard(
        manifest: ScientificCampaignManifest
    ) -> ScientificCampaignShard? {
        manifest.shards
            .filter { shardStatus[$0.id] == .pending }
            .sorted {
                if $0.totalEstimatedWorkUnits != $1.totalEstimatedWorkUnits {
                    return $0.totalEstimatedWorkUnits > $1.totalEstimatedWorkUnits
                }
                return $0.index < $1.index
            }
            .first
    }

    private func leaseMatches(
        _ event: ScientificCampaignJournalEvent,
        shardID: UUID
    ) -> Bool {
        guard let lease = activeLeases[shardID] else { return false }
        return event.leaseID == lease.leaseID
            && event.workerID == lease.workerID
    }

    private func trialBelongs(
        _ trialID: UInt64,
        to shardID: UUID,
        manifest: ScientificCampaignManifest
    ) -> Bool {
        shardTrials(shardID, manifest: manifest).contains { $0.id == trialID }
    }

    private func shardTrials(
        _ shardID: UUID,
        manifest: ScientificCampaignManifest
    ) -> [ScientificCampaignTrial] {
        manifest.shards.first { $0.id == shardID }?.trials ?? []
    }
}

public actor ScientificCampaignJournal {
    public let manifest: ScientificCampaignManifest
    public let url: URL
    private var state: ScientificCampaignLedgerState
    private var handle: FileHandle

    public init(
        manifest sourceManifest: ScientificCampaignManifest,
        url: URL,
        createIfMissing: Bool = true
    ) throws {
        manifest = try sourceManifest.validated()
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            guard createIfMissing,
                  FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw ScientificCampaignError.cannotOpenJournal(url.path)
            }
        }
        let existing = try Data(contentsOf: url)
        let events = try Self.decodeLines(existing)
        var replayed = ScientificCampaignLedgerState(manifest: manifest)
        for event in events { try replayed.apply(event, manifest: manifest) }
        state = replayed
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func snapshot() -> ScientificCampaignLedgerState { state }

    @discardableResult
    public func append(
        kind: ScientificCampaignEventKind,
        shardID: UUID? = nil,
        trialID: UInt64? = nil,
        workerID: String? = nil,
        leaseID: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        runManifestDigest: ScientificSHA256Digest? = nil,
        message: String? = nil,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) throws -> ScientificCampaignJournalEvent {
        let sequence: UInt64
        if let last = state.lastSequence {
            guard last != UInt64.max else {
                throw ScientificCampaignError.sequenceOverflow
            }
            sequence = last + 1
        } else {
            sequence = 0
        }
        let event = try ScientificCampaignJournalEvent(
            sequence: sequence,
            campaignID: manifest.id,
            shardID: shardID,
            trialID: trialID,
            kind: kind,
            timestamp: timestamp,
            workerID: workerID,
            leaseID: leaseID,
            leaseExpiresAt: leaseExpiresAt,
            runManifestDigest: runManifestDigest,
            message: message,
            metadata: metadata
        ).validated()
        var candidateState = state
        try candidateState.apply(event, manifest: manifest)
        var line = try ScientificCanonicalJSON.encode(event)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
        state = candidateState
        return event
    }

    public func claimNextShard(
        workerID: String,
        leaseDurationSeconds: TimeInterval,
        now: Date = Date()
    ) throws -> ScientificCampaignLease? {
        guard !workerID.isEmpty,
              leaseDurationSeconds.isFinite,
              leaseDurationSeconds > 0 else {
            throw ScientificCampaignError.invalidLease
        }
        try expireLeases(now: now)
        guard let shard = state.nextPendingShard(manifest: manifest) else {
            return nil
        }
        let leaseID = UUID()
        let expiresAt = now.addingTimeInterval(leaseDurationSeconds)
        _ = try append(
            kind: .shardLeased,
            shardID: shard.id,
            workerID: workerID,
            leaseID: leaseID,
            leaseExpiresAt: expiresAt,
            timestamp: now
        )
        return state.activeLeases[shard.id]
    }

    public func expireLeases(now: Date = Date()) throws {
        let expired = state.activeLeases.values
            .filter { !$0.isActive(at: now) }
            .sorted { $0.shardID.uuidString < $1.shardID.uuidString }
        for lease in expired {
            _ = try append(
                kind: .leaseExpired,
                shardID: lease.shardID,
                workerID: lease.workerID,
                leaseID: lease.leaseID,
                message: "lease expired",
                timestamp: now
            )
        }
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }

    private static func decodeLines(
        _ data: Data
    ) throws -> [ScientificCampaignJournalEvent] {
        guard !data.isEmpty else { return [] }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ScientificCampaignError.invalidJournalEncoding
        }
        return try text.split(whereSeparator: \Character.isNewline).map { line in
            try ScientificCanonicalJSON.decode(
                ScientificCampaignJournalEvent.self,
                from: Data(line.utf8)
            )
        }
    }
}

public enum ScientificCampaignMerger {
    public static func validateCompletedRuns(
        manifest sourceManifest: ScientificCampaignManifest,
        runManifests: [ScientificRunProvenanceManifest]
    ) throws -> [UInt64: ScientificRunProvenanceManifest] {
        let manifest = try sourceManifest.validated()
        let expectedTrials = Set(manifest.shards.flatMap(\.trials).map(\.id))
        guard runManifests.allSatisfy({
            $0.campaignID == manifest.id
                && $0.status == .completed
                && $0.trialID != nil
        }) else {
            throw ScientificCampaignError.invalidRunManifestSet
        }
        var result: [UInt64: ScientificRunProvenanceManifest] = [:]
        for run in runManifests {
            let run = try run.validated()
            guard let trialID = run.trialID,
                  expectedTrials.contains(trialID),
                  result[trialID] == nil else {
                throw ScientificCampaignError.invalidRunManifestSet
            }
            result[trialID] = run
        }
        return result
    }
}

public enum ScientificCampaignError: Error, Sendable, CustomStringConvertible {
    case invalidTrial(UInt64)
    case invalidShard(Int)
    case invalidManifest
    case invalidShardingRequest
    case workOverflow
    case invalidEvent(UInt64)
    case invalidTransition(UInt64)
    case campaignMismatch
    case nonContiguousSequence
    case cannotOpenJournal(String)
    case invalidJournalEncoding
    case invalidLease
    case sequenceOverflow
    case invalidRunManifestSet

    public var description: String {
        switch self {
        case .invalidTrial(let id):
            return "Scientific campaign trial \(id) is invalid"
        case .invalidShard(let index):
            return "Scientific campaign shard \(index) is invalid"
        case .invalidManifest:
            return "Scientific campaign manifest is invalid"
        case .invalidShardingRequest:
            return "Scientific campaign sharding request is invalid"
        case .workOverflow:
            return "Scientific campaign work accounting overflowed UInt64"
        case .invalidEvent(let sequence):
            return "Scientific campaign event \(sequence) is invalid"
        case .invalidTransition(let sequence):
            return "Scientific campaign event \(sequence) is not a valid state transition"
        case .campaignMismatch:
            return "Scientific campaign event belongs to another campaign"
        case .nonContiguousSequence:
            return "Scientific campaign journal sequence is not contiguous"
        case .cannotOpenJournal(let path):
            return "Scientific campaign journal could not be opened at \(path)"
        case .invalidJournalEncoding:
            return "Scientific campaign journal is not valid UTF-8"
        case .invalidLease:
            return "Scientific campaign lease request is invalid"
        case .sequenceOverflow:
            return "Scientific campaign journal exhausted UInt64 sequence numbers"
        case .invalidRunManifestSet:
            return "Scientific campaign run manifests do not form a valid completed set"
        }
    }
}
