import Foundation

public struct NumiTissueObservedStepReport: Sendable {
    public var step: NumiTissueStepReport
    public var observations: TissueObservationBatch?
    public var observationErrorDescription: String?

    public init(
        step: NumiTissueStepReport,
        observations: TissueObservationBatch? = nil,
        observationErrorDescription: String? = nil
    ) {
        self.step = step
        self.observations = observations
        self.observationErrorDescription = observationErrorDescription
    }
}

/// Adds host-side scientific observations without forcing committed-state export on every step.
/// Observation failures are reported separately and never alter an already committed transaction.
public actor ObservedNumiTissueSession {
    public let session: NumiTissueSession
    public let recorder: TissueStateRecorder

    public init(session: NumiTissueSession, recorder: TissueStateRecorder) {
        self.session = session
        self.recorder = recorder
    }

    public init(
        backend: any NumiTissueExecutionBackend,
        recorder: TissueStateRecorder,
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner()
    ) {
        session = NumiTissueSession(
            backend: backend,
            phasePlanner: phasePlanner
        )
        self.recorder = recorder
    }

    public func load(
        model: CompiledTissueModel,
        state: TissueRuntimeState,
        sampleInitialState: Bool = true
    ) async throws -> TissueObservationBatch? {
        try await session.load(model: model, state: state)
        guard sampleInitialState,
              await recorder.requiresSample(at: state.time.tick) else {
            return nil
        }
        return try await recorder.sample(state)
    }

    public func step(
        input: RuntimeInputFrame = RuntimeInputFrame(),
        randomSeed: UInt64,
        intervention: TissueInterventionFrame? = nil
    ) async -> NumiTissueObservedStepReport {
        let report = await session.step(
            input: input,
            randomSeed: randomSeed,
            intervention: intervention
        )
        guard report.status == .committed,
              await recorder.requiresSample(at: report.context.endTime.tick) else {
            return NumiTissueObservedStepReport(step: report)
        }
        do {
            let state = try await session.exportState()
            let batch = try await recorder.sample(state)
            return NumiTissueObservedStepReport(
                step: report,
                observations: batch
            )
        } catch {
            return NumiTissueObservedStepReport(
                step: report,
                observationErrorDescription: String(describing: error)
            )
        }
    }

    public func run(
        steps: Int,
        input: @Sendable (
            _ epoch: UInt64,
            _ time: TissueTime
        ) async throws -> RuntimeInputFrame,
        intervention: @Sendable (
            _ epoch: UInt64,
            _ time: TissueTime
        ) async throws -> TissueInterventionFrame? = { _, _ in nil },
        seed: @Sendable (_ epoch: UInt64) -> UInt64
    ) async throws -> [NumiTissueObservedStepReport] {
        guard steps >= 0 else { throw NumiTissueSessionError.invalidStepCount }
        var reports: [NumiTissueObservedStepReport] = []
        reports.reserveCapacity(steps)
        for _ in 0..<steps {
            let epoch = await session.epoch()
            let time = await session.time()
            let report = await step(
                input: try await input(epoch, time),
                randomSeed: seed(epoch),
                intervention: try await intervention(epoch, time)
            )
            reports.append(report)
            guard report.step.status == .committed else { break }
        }
        return reports
    }

    public func exportState() async throws -> TissueRuntimeState {
        try await session.exportState()
    }

    public func flushObservations() async throws {
        try await recorder.flush()
    }
}
