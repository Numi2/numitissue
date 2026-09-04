import Foundation
import NumiTissueCore
import NumiTissueIO
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct SuiteRecoveryDecision: Sendable, Codable {
    public var context: SuiteTransactionContext
    public var tokens: [SuiteCommitToken]
    public var commitDecided: Bool
    public var terminal: Bool
    public var lastEvent: String
}

/// Fsync-backed WAL. Reopening is explicit, locked, bounded and rejects partial trailing records.
/// A hash chain detects corruption; it is not an external signature or proof of physical execution.
public actor DurableSuiteTransactionJournal: SuiteTransactionJournal {
    private struct Event: Codable {
        var context: SuiteTransactionContext
        var tokens: [SuiteCommitToken]
        var reason: String?
    }
    private let file: FileHandle
    private let runID: UUID
    private let maximumBytes: UInt64
    private var bytes: UInt64
    private var sequence: UInt64
    private var previous: ScientificSHA256Digest?
    private var decisions: [TransactionID: SuiteRecoveryDecision]
    private var poisoned = false

    public init(url: URL, runID: UUID, reopenExisting: Bool = false,
                maximumBytes: UInt64 = 67_108_864) throws {
        guard url.isFileURL, maximumBytes > 0, maximumBytes <= 1_073_741_824 else {
            throw ClosedLoopError.invalid("suite journal path or bounds")
        }
        try LoopJournalPaths.checkParents(url)
        #if canImport(Darwin) || canImport(Glibc)
        let flags = O_RDWR | O_APPEND | O_NOFOLLOW | (reopenExisting ? 0 : (O_CREAT | O_EXCL))
        let fd = url.path.withCString { open($0, flags, mode_t(0o600)) }
        guard fd >= 0 else { throw ClosedLoopError.invalid("suite journal open") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close(); throw ClosedLoopError.invalid("suite journal already has a writer")
        }
        var adopted = false
        defer { if !adopted { try? handle.close() } }
        let size = try handle.seekToEnd()
        guard size <= maximumBytes, size <= UInt64(Int.max) else { throw ClosedLoopError.capacity("suite journal") }
        try handle.seek(toOffset: 0)
        let data = try handle.readToEnd() ?? Data()
        guard UInt64(data.count) == size, data.isEmpty || data.last == 10 else {
            throw ClosedLoopError.invalid("partial journal tail requires explicit operator recovery")
        }
        var map: [TransactionID: SuiteRecoveryDecision] = [:]
        var prior: ScientificSHA256Digest?
        var next: UInt64 = 0
        for line in data.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
            guard !line.isEmpty, line.count <= 1_048_576 else { throw ClosedLoopError.invalid("journal record size") }
            let record = try ScientificCanonicalJSON.decode(ClosedLoopAuditRecord.self, from: Data(line))
            guard record.schemaVersion == 1, record.runID == runID, record.sequence == next,
                  record.previousSHA256 == prior else { throw ClosedLoopError.invalid("suite journal chain") }
            let event = try ScientificCanonicalJSON.decode(Event.self, from: record.payload)
            try Self.reduce(kind: record.kind, event: event, into: &map)
            prior = try record.digest(); next += 1
        }
        if !reopenExisting {
            let parentFD = url.deletingLastPathComponent().path.withCString { open($0, O_RDONLY | O_DIRECTORY) }
            guard parentFD >= 0 else { throw ClosedLoopError.invalid("suite journal directory") }
            let status = fsync(parentFD); _ = close(parentFD)
            guard status == 0 else { throw ClosedLoopError.invalid("suite journal directory sync") }
        }
        self.file = handle; self.runID = runID; self.maximumBytes = maximumBytes
        self.bytes = size; self.sequence = next; self.previous = prior; self.decisions = map
        adopted = true
        #else
        throw ClosedLoopError.invalid("durable journal unsupported on this platform")
        #endif
    }

    public func recordPrepared(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) throws {
        try append("prepared", .init(context: context, tokens: tokens, reason: nil))
    }
    public func recordCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) throws {
        if let prior = decisions[context.transaction], prior.commitDecided,
           prior.context == context, prior.tokens == tokens { return }
        try append("commit-decided", .init(context: context, tokens: tokens, reason: nil))
    }
    public func hasCommitDecision(context: SuiteTransactionContext, tokens: [SuiteCommitToken]) throws -> Bool {
        guard !poisoned else { throw ClosedLoopError.latched("reopen journal after ambiguous write") }
        guard let prior = decisions[context.transaction] else { return false }
        guard prior.context == context, prior.tokens == tokens else { throw ClosedLoopError.invalid("decision identity") }
        return prior.commitDecided
    }
    public func recordCommitted(context: SuiteTransactionContext) throws {
        guard let prior = decisions[context.transaction] else { throw ClosedLoopError.invalid("commit without decision") }
        if prior.terminal, prior.lastEvent == "committed", prior.context == context { return }
        try append("committed", .init(context: context, tokens: prior.tokens, reason: nil))
    }
    public func recordAborted(context: SuiteTransactionContext, reason: String) throws {
        try append("aborted", .init(context: context, tokens: decisions[context.transaction]?.tokens ?? [], reason: reason))
    }
    public func recordInDoubt(context: SuiteTransactionContext, tokens: [SuiteCommitToken], reason: String) throws {
        try append("in-doubt", .init(context: context, tokens: tokens, reason: reason))
    }
    public func recoveryDecisions() throws -> [SuiteRecoveryDecision] {
        guard !poisoned else { throw ClosedLoopError.latched("journal requires reopen") }
        return decisions.values.filter { !$0.terminal }.sorted { $0.context.transaction.rawValue < $1.context.transaction.rawValue }
    }

    private func append(_ kind: String, _ event: Event) throws {
        guard !poisoned, sequence < UInt64.max, decisions.count <= 1_000_000 else {
            throw ClosedLoopError.latched("suite journal is poisoned or full")
        }
        var next = decisions
        try Self.reduce(kind: kind, event: event, into: &next)
        let payload = try ScientificCanonicalJSON.encode(event)
        guard payload.count <= 1_048_576 else { throw ClosedLoopError.capacity("suite journal payload") }
        let record = ClosedLoopAuditRecord(runID: runID, sequence: sequence, previousSHA256: previous,
            kind: kind, deviceNanoseconds: 0, payload: payload)
        let digest = try record.digest()
        var encoded = try ScientificCanonicalJSON.encode(record); encoded.append(10)
        let count = try LoopArithmetic.add(bytes, UInt64(encoded.count))
        guard count <= maximumBytes else { throw ClosedLoopError.capacity("suite journal bytes") }
        do { try file.write(contentsOf: encoded); try file.synchronize() }
        catch { poisoned = true; throw error }
        decisions = next; previous = digest; bytes = count; sequence += 1
    }

    private static func reduce(kind: String, event: Event,
                               into states: inout [TransactionID: SuiteRecoveryDecision]) throws {
        let c = event.context
        guard c.endTime > c.startTime, Set(event.tokens.map(\.participant)).count == event.tokens.count,
              event.tokens.allSatisfy({ $0.transaction == c.transaction && !$0.participant.isEmpty }) else {
            throw ClosedLoopError.invalid("suite journal context or tokens")
        }
        var state = states[c.transaction] ?? .init(context: c, tokens: event.tokens,
            commitDecided: false, terminal: false, lastEvent: "")
        guard state.context == c, !state.terminal,
              state.lastEvent.isEmpty || state.tokens == event.tokens else {
            throw ClosedLoopError.invalid("suite journal conflicting or terminal transaction")
        }
        switch kind {
        case "prepared":
            guard state.lastEvent.isEmpty else { throw ClosedLoopError.invalid("duplicate prepare") }
        case "commit-decided":
            guard state.lastEvent == "prepared", !state.commitDecided else {
                throw ClosedLoopError.invalid("decision without prepare")
            }
            state.commitDecided = true
        case "committed":
            guard state.commitDecided else { throw ClosedLoopError.invalid("publication without commit decision") }
            state.terminal = true
        case "aborted":
            guard !state.commitDecided else { throw ClosedLoopError.invalid("abort after commit decision") }
            state.terminal = true
        case "in-doubt":
            guard !state.lastEvent.isEmpty else { throw ClosedLoopError.invalid("in-doubt without prepare") }
        default: throw ClosedLoopError.invalid("unknown suite journal event")
        }
        state.lastEvent = kind; states[c.transaction] = state
    }
}
