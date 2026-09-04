import Foundation
import NumiTissueIO

/// Replays supplied recordings. Stimulation receipts are simulated bookkeeping only:
/// recorded biological responses do not change when the policy changes.
public actor ReplayNeuralCultureBackend: NonphysicalNeuralCultureBackend {
    public nonisolated let name = "NumiTissue recording replay (no physical output)"
    public var capabilities: NeuralCultureBackendCapabilities {
        .init(maximumElectrodes: 4096, supportedSampleRatesHertz: Array(Set(recordings.map { $0.request.sampleRateHertz })).sorted(),
            minimumStimulationLeadTimeNanoseconds: 0, timestampResolutionNanoseconds: 1_000,
            supportsScheduledStimulation: true, supportsStreaming: false,
            supportsImpedanceMeasurement: false, supportsHardwareLoop: false)
    }
    private let recordings: [NeuralRecording]
    private let sessionID: UUID
    private var session: NeuralCultureSession?
    private var configuration: MEAConfiguration?
    private var cursor = 0
    private var clock: UInt64 = 0
    private var requests: [UUID: NeuralStimulationRequest] = [:]
    private var receipts: [UUID: NeuralStimulationReceipt] = [:]
    public init(recordings: [NeuralRecording], sessionID: UUID) throws {
        guard !recordings.isEmpty, recordings.count <= 100_000 else { throw ClosedLoopError.invalid("bounded replay corpus") }
        for record in recordings {
            guard record.request.durationNanoseconds > 0,
                  record.backendTimestampNanoseconds >= (try LoopArithmetic.add(record.request.startTimeNanoseconds, record.request.durationNanoseconds)) else {
                throw ClosedLoopError.invalid("replay acquisition timestamp")
            }
        }
        guard zip(recordings, recordings.dropFirst()).allSatisfy({
            $0.backendTimestampNanoseconds <= $1.request.startTimeNanoseconds
        }) else { throw ClosedLoopError.invalid("overlapping or unordered replay windows") }
        self.recordings = recordings; self.sessionID = sessionID
    }
    public func open(cultureID: String, configuration: MEAConfiguration) throws -> NeuralCultureSession {
        guard session == nil, cursor == 0, !cultureID.isEmpty else { throw ClosedLoopError.invalid("replay is single-session") }
        self.configuration = try configuration.validated()
        let value = NeuralCultureSession(id: sessionID, backendName: name, cultureID: cultureID,
            startedAt: Date(timeIntervalSince1970: 0), timebaseEpochNanoseconds: 0,
            metadata: ["mode": "replay", "physicalOutput": "false"])
        session = value
        return value
    }
    public func close(session: NeuralCultureSession) throws {
        try require(session)
        self.session = nil
        for (id, receipt) in receipts where receipt.status == .accepted {
            var updated = receipt; updated.status = .cancelled; receipts[id] = updated
        }
    }
    public func backendTimeNanoseconds(session: NeuralCultureSession) throws -> UInt64 { try require(session); return clock }
    public func health(session: NeuralCultureSession) throws -> NeuralCultureHealth {
        try require(session)
        return .init(status: .healthy, activeElectrodes: configuration?.electrodes.filter(\.enabled).count ?? 0,
            temperatureKelvin: 310.15, message: "Synthetic replay health; not a culture sensor reading")
    }
    public func record(session: NeuralCultureSession, request: NeuralRecordingRequest) throws -> NeuralRecording {
        try require(session)
        guard cursor < recordings.count, recordings[cursor].request == request else {
            throw ClosedLoopError.invalid("replay input differs from the next recorded request")
        }
        let value = recordings[cursor]
        clock = value.backendTimestampNanoseconds; cursor += 1
        for (id, receipt) in receipts where receipt.status == .accepted {
            guard let pending = requests[id], pending.scheduledTimeNanoseconds <= clock else { continue }
            var executed = receipt; executed.status = .executed
            executed.executedAtNanoseconds = pending.scheduledTimeNanoseconds
            receipts[id] = executed
        }
        return value
    }
    public func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) throws -> NeuralStimulationReceipt {
        try require(session)
        if let previous = requests[request.id] {
            guard previous == request, let receipt = receipts[request.id] else {
                throw ClosedLoopError.invalid("request ID reused with a different stimulation")
            }
            return receipt
        }
        guard requests.count < 100_000, request.scheduledTimeNanoseconds >= clock,
              let deadline = request.deadlineNanoseconds, deadline >= request.scheduledTimeNanoseconds else {
            throw ClosedLoopError.invalid("replay stimulation time or capacity")
        }
        let receipt = NeuralStimulationReceipt(requestID: request.id, status: .accepted,
            acceptedAtNanoseconds: clock, message: "Simulated acceptance; no physical stimulus")
        requests[request.id] = request; receipts[request.id] = receipt
        return receipt
    }
    public func cancel(session: NeuralCultureSession, requestID: UUID) throws {
        try require(session)
        guard var receipt = receipts[requestID], receipt.status == .accepted else {
            throw ClosedLoopError.invalid("unknown or already executed replay request")
        }
        receipt.status = .cancelled; receipts[requestID] = receipt
    }
    public func stimulationReceipts() -> [NeuralStimulationReceipt] {
        receipts.values.sorted { $0.requestID.uuidString < $1.requestID.uuidString }
    }
    private func require(_ proposed: NeuralCultureSession) throws {
        guard let session, session == proposed else { throw ClosedLoopError.invalid("replay session identity") }
    }
}

public typealias ClosedLoopPolicy = @Sendable (NeuralRecording) async throws -> NeuralStimulationRequest?

public struct ClosedLoopRunSummary: Sendable, Codable {
    public var completedWindows: Int
    public var submittedRequests: Int
    public var safeStopConfirmed: Bool
}

public enum ClosedLoopRunner {
    /// Bounded supervision loop. Does not claim hard real-time scheduling or host watchdog coverage.
    /// Physical low-latency execution belongs to the device-local adapter; stale results are rejected.
    public static func run(session: GuardedNeuralCultureSession,
                           windows: [NeuralRecordingRequest], policy: @escaping ClosedLoopPolicy) async throws -> ClosedLoopRunSummary {
        guard !windows.isEmpty, windows.count <= 100_000 else { throw ClosedLoopError.invalid("loop window budget") }
        var completed = 0, submitted = 0
        do {
            for request in windows {
                try Task.checkCancellation()
                let recording = try await session.observe(request)
                let digest = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(recording))
                let proposal = try await policy(recording)
                try Task.checkCancellation()
                if let proposal {
                    _ = try await session.submit(proposal, basedOn: digest)
                    submitted += 1
                }
                completed += 1
            }
            let stopped = await session.stop(reason: "bounded run completed")
            guard stopped else { throw ClosedLoopError.unsafe("final physical stop not confirmed") }
            return .init(completedWindows: completed, submittedRequests: submitted, safeStopConfirmed: stopped)
        } catch {
            _ = await session.stop(reason: "bounded run failed or cancelled: \(error)")
            throw error
        }
    }
}
