@_exported import NumiTissueCore
@_exported import NumiTissueModels
@_exported import NumiTissueRuntime
@_exported import NumiTissueIO
@_exported import NumiTissueReference
@_exported import NumiTissueMetal
@_exported import NumiTissueIntegration

import Foundation

public enum NumiTissueBuild {
    public static let semanticVersion = "1.0.0-dev"
    public static let checkpointFormatVersion: UInt32 = 1
    public static let fastTickMicroseconds: UInt64 = 25
    public static let transactionTicks: UInt64 = 200
    public static let transactionMilliseconds: Double = 5
}

public enum NumiTissueStepStatus: String, Sendable, Hashable, Codable {
    case committed
    case rejected
    case failed
}

public struct NumiTissueStepReport: Sendable {
    public var status: NumiTissueStepStatus
    public var context: ExecutionContext
    public var output: RuntimeOutputFrame?
    public var issues: [RuntimeValidationIssue]
    public var counters: RuntimeCounters
    public var errorDescription: String?

    public init(
        status: NumiTissueStepStatus,
        context: ExecutionContext,
        output: RuntimeOutputFrame? = nil,
        issues: [RuntimeValidationIssue] = [],
        counters: RuntimeCounters = RuntimeCounters(),
        errorDescription: String? = nil
    ) {
        self.status = status
        self.context = context
        self.output = output
        self.issues = issues
        self.counters = counters
        self.errorDescription = errorDescription
    }
}

/// Standalone transactional runtime. NumiSuiteCoordinator uses the same backend protocol when
/// NumiTissue is coupled to NumiBrain and NumanX.
public actor NumiTissueSession {
    public let backend: any NumiTissueExecutionBackend
    public let phasePlanner: RuntimePhasePlanner

    private var loaded = false
    private var currentTime = TissueTime()
    private var currentEpoch: UInt64 = 0
    private var nextTransaction: UInt64 = 1

    public init(
        backend: any NumiTissueExecutionBackend,
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner()
    ) {
        self.backend = backend
        self.phasePlanner = phasePlanner
    }

    public func load(model: CompiledTissueModel, state: TissueRuntimeState) async throws {
        guard !loaded else { throw NumiTissueSessionError.alreadyLoaded }
        try state.validateCapacity()
        try await backend.load(model: model, initialState: state)
        currentTime = state.time
        currentEpoch = state.epoch
        loaded = true
    }

    public func step(input: RuntimeInputFrame = RuntimeInputFrame(), randomSeed: UInt64) async -> NumiTissueStepReport {
        let transaction = TransactionID(rawValue: nextTransaction)
        nextTransaction &+= 1
        let context = phasePlanner.context(
            startTime: currentTime,
            epoch: currentEpoch,
            transaction: transaction,
            randomSeed: randomSeed
        )
        guard loaded else {
            return NumiTissueStepReport(status: .failed, context: context, errorDescription: NumiTissueSessionError.notLoaded.description)
        }
        var began = false
        do {
            try await backend.beginShadowStep(context: context, input: input)
            began = true
            for scheduled in phasePlanner.plan(startTick: currentTime.tick) {
                try await backend.execute(phase: scheduled.phase, tickRange: scheduled.tickRange, context: context)
            }
            let output = try await backend.collectOutput(context: context)
            let issues = try await backend.validateShadow(context: context)
            let counters = await backend.counters(context: context)
            if issues.contains(where: { $0.severity == .reject }) {
                await backend.rollbackShadow(context: context)
                return NumiTissueStepReport(status: .rejected, context: context, output: output, issues: issues, counters: counters)
            }
            try await backend.commitShadow(context: context)
            currentTime = context.endTime
            currentEpoch &+= 1
            return NumiTissueStepReport(status: .committed, context: context, output: output, issues: issues, counters: counters)
        } catch {
            if began { await backend.rollbackShadow(context: context) }
            return NumiTissueStepReport(
                status: .failed,
                context: context,
                issues: [],
                counters: await backend.counters(context: context),
                errorDescription: String(describing: error)
            )
        }
    }

    public func run(
        steps: Int,
        input: @Sendable (_ epoch: UInt64, _ time: TissueTime) async throws -> RuntimeInputFrame,
        seed: @Sendable (_ epoch: UInt64) -> UInt64
    ) async throws -> [NumiTissueStepReport] {
        guard steps >= 0 else { throw NumiTissueSessionError.invalidStepCount }
        var reports: [NumiTissueStepReport] = []
        reports.reserveCapacity(steps)
        for _ in 0..<steps {
            let frame = try await input(currentEpoch, currentTime)
            let report = await step(input: frame, randomSeed: seed(currentEpoch))
            reports.append(report)
            guard report.status == .committed else { break }
        }
        return reports
    }

    public func exportState() async throws -> TissueRuntimeState {
        guard loaded else { throw NumiTissueSessionError.notLoaded }
        return try await backend.exportCommittedState()
    }

    public func makeCheckpoint(
        modelDigest: UInt64,
        randomSeed: UInt64,
        metadata: [String: String] = [:],
        participantState: [String: Data] = [:]
    ) async throws -> TissueCheckpoint {
        let state = try await exportState()
        return try TissueCheckpoint.make(
            state: state,
            simulatorVersion: NumiTissueBuild.semanticVersion,
            randomSeed: randomSeed,
            modelDigest: modelDigest,
            metadata: metadata,
            suiteParticipantState: participantState
        )
    }

    public func time() -> TissueTime { currentTime }
    public func epoch() -> UInt64 { currentEpoch }
}

public enum NumiTissueSessionError: Error, Sendable, CustomStringConvertible {
    case alreadyLoaded
    case notLoaded
    case invalidStepCount

    public var description: String {
        switch self {
        case .alreadyLoaded: return "NumiTissue session is already loaded"
        case .notLoaded: return "NumiTissue session is not loaded"
        case .invalidStepCount: return "NumiTissue step count cannot be negative"
        }
    }
}
