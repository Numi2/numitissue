import Foundation

public struct TissueExperimentMetric: Sendable, Hashable, Codable {
    public var name: String
    public var value: Double
    public var unit: String?
    public var uncertainty: Double?
    public var tags: [String: String]

    public init(name: String, value: Double, unit: String? = nil, uncertainty: Double? = nil, tags: [String: String] = [:]) {
        self.name = name
        self.value = value
        self.unit = unit
        self.uncertainty = uncertainty
        self.tags = tags
    }
}

public struct TissueExperimentTrial: Sendable, Hashable, Codable {
    public var id: UInt64
    public var replicate: Int
    public var parameters: [String: Double]
    public var interventions: TissueInterventionPlan
    public var metadata: [String: String]

    public init(id: UInt64, replicate: Int, parameters: [String: Double] = [:], interventions: TissueInterventionPlan = TissueInterventionPlan(interventions: []), metadata: [String: String] = [:]) {
        self.id = id
        self.replicate = replicate
        self.parameters = parameters
        self.interventions = interventions
        self.metadata = metadata
    }
}

public struct TissueExperimentDefinition: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var modelDigest: UInt64
    public var stepsPerTrial: Int
    public var baseSeed: UInt64
    public var trials: [TissueExperimentTrial]
    public var checkpointEverySteps: Int?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        modelDigest: UInt64,
        stepsPerTrial: Int,
        baseSeed: UInt64,
        trials: [TissueExperimentTrial],
        checkpointEverySteps: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.modelDigest = modelDigest
        self.stepsPerTrial = stepsPerTrial
        self.baseSeed = baseSeed
        self.trials = trials
        self.checkpointEverySteps = checkpointEverySteps
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty, stepsPerTrial >= 0 else { throw TissueExperimentError.invalidDefinition }
        guard !trials.isEmpty, Set(trials.map(\.id)).count == trials.count else { throw TissueExperimentError.invalidDefinition }
        if let checkpointEverySteps, checkpointEverySteps <= 0 { throw TissueExperimentError.invalidDefinition }
        return self
    }
}

public struct TissueTrialRuntime: Sendable {
    public var model: CompiledTissueModel
    public var state: TissueRuntimeState
    public var backend: any NumiTissueExecutionBackend

    public init(model: CompiledTissueModel, state: TissueRuntimeState, backend: any NumiTissueExecutionBackend) {
        self.model = model
        self.state = state
        self.backend = backend
    }
}

public typealias TissueTrialRuntimeFactory = @Sendable (_ trial: TissueExperimentTrial) async throws -> TissueTrialRuntime
public typealias TissueTrialInputProvider = @Sendable (_ trial: TissueExperimentTrial, _ epoch: UInt64, _ time: TissueTime) async throws -> RuntimeInputFrame
public typealias TissueTrialMetricExtractor = @Sendable (_ trial: TissueExperimentTrial, _ reports: [NumiTissueStepReport], _ finalState: TissueRuntimeState) async throws -> [TissueExperimentMetric]

public struct TissueExperimentProvenance: Sendable, Hashable, Codable {
    public var simulatorVersion: String
    public var createdAt: Date
    public var completedAt: Date
    public var operatingSystem: String
    public var processorCount: Int
    public var physicalMemoryBytes: UInt64
    public var environment: [String: String]
    public var sourceRevision: String?

    public init(createdAt: Date, completedAt: Date, environment: [String: String] = [:], sourceRevision: String? = nil) {
        let info = ProcessInfo.processInfo
        simulatorVersion = NumiTissueBuild.semanticVersion
        self.createdAt = createdAt
        self.completedAt = completedAt
        operatingSystem = info.operatingSystemVersionString
        processorCount = info.processorCount
        physicalMemoryBytes = info.physicalMemory
        self.environment = environment
        self.sourceRevision = sourceRevision
    }
}

public struct TissueTrialResult: Sendable, Codable {
    public enum Status: String, Sendable, Hashable, Codable { case completed, rejected, failed }

    public var trial: TissueExperimentTrial
    public var status: Status
    public var seed: UInt64
    public var completedSteps: Int
    public var finalEpoch: UInt64
    public var finalTick: UInt64
    public var metrics: [TissueExperimentMetric]
    public var issues: [String]
    public var errorDescription: String?
    public var elapsedSeconds: Double

    public init(
        trial: TissueExperimentTrial,
        status: Status,
        seed: UInt64,
        completedSteps: Int,
        finalEpoch: UInt64,
        finalTick: UInt64,
        metrics: [TissueExperimentMetric] = [],
        issues: [String] = [],
        errorDescription: String? = nil,
        elapsedSeconds: Double
    ) {
        self.trial = trial
        self.status = status
        self.seed = seed
        self.completedSteps = completedSteps
        self.finalEpoch = finalEpoch
        self.finalTick = finalTick
        self.metrics = metrics
        self.issues = issues
        self.errorDescription = errorDescription
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct TissueExperimentResult: Sendable, Codable {
    public var definition: TissueExperimentDefinition
    public var trials: [TissueTrialResult]
    public var provenance: TissueExperimentProvenance

    public init(definition: TissueExperimentDefinition, trials: [TissueTrialResult], provenance: TissueExperimentProvenance) {
        self.definition = definition
        self.trials = trials
        self.provenance = provenance
    }

    public var completedCount: Int { trials.count { $0.status == .completed } }
    public var rejectedCount: Int { trials.count { $0.status == .rejected } }
    public var failedCount: Int { trials.count { $0.status == .failed } }

    public func metric(named name: String) -> [(trialID: UInt64, value: Double)] {
        trials.compactMap { result in result.metrics.first(where: { $0.name == name }).map { (result.trial.id, $0.value) } }
    }
}

public actor NumiTissueExperimentRunner {
    public let maximumConcurrentTrials: Int
    private let runtimeFactory: TissueTrialRuntimeFactory
    private let inputProvider: TissueTrialInputProvider
    private let metricExtractor: TissueTrialMetricExtractor

    public init(
        maximumConcurrentTrials: Int,
        runtimeFactory: @escaping TissueTrialRuntimeFactory,
        inputProvider: @escaping TissueTrialInputProvider = { _, _, _ in RuntimeInputFrame() },
        metricExtractor: @escaping TissueTrialMetricExtractor = { _, _, _ in [] }
    ) throws {
        guard maximumConcurrentTrials > 0 else { throw TissueExperimentError.invalidConcurrency }
        self.maximumConcurrentTrials = maximumConcurrentTrials
        self.runtimeFactory = runtimeFactory
        self.inputProvider = inputProvider
        self.metricExtractor = metricExtractor
    }

    public func run(
        _ definition: TissueExperimentDefinition,
        environment: [String: String] = [:],
        sourceRevision: String? = nil
    ) async throws -> TissueExperimentResult {
        let definition = try definition.validated()
        let started = Date()
        var pending = Array(definition.trials.sorted { $0.id < $1.id })
        var results: [TissueTrialResult] = []
        results.reserveCapacity(pending.count)
        let runtimeFactory = self.runtimeFactory
        let inputProvider = self.inputProvider
        let metricExtractor = self.metricExtractor
        let concurrency = maximumConcurrentTrials

        while !pending.isEmpty {
            let batch = Array(pending.prefix(concurrency))
            pending.removeFirst(batch.count)
            let batchResults = await withTaskGroup(of: TissueTrialResult.self) { group in
                for trial in batch {
                    group.addTask {
                        await Self.execute(
                            trial: trial,
                            definition: definition,
                            runtimeFactory: runtimeFactory,
                            inputProvider: inputProvider,
                            metricExtractor: metricExtractor
                        )
                    }
                }
                var values: [TissueTrialResult] = []
                for await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
        }
        results.sort { $0.trial.id < $1.trial.id }
        return TissueExperimentResult(
            definition: definition,
            trials: results,
            provenance: TissueExperimentProvenance(createdAt: started, completedAt: Date(), environment: environment, sourceRevision: sourceRevision)
        )
    }

    private static func execute(
        trial: TissueExperimentTrial,
        definition: TissueExperimentDefinition,
        runtimeFactory: TissueTrialRuntimeFactory,
        inputProvider: TissueTrialInputProvider,
        metricExtractor: TissueTrialMetricExtractor
    ) async -> TissueTrialResult {
        let started = ContinuousClock.now
        let seed = trialSeed(base: definition.baseSeed, trial: trial)
        do {
            let runtime = try await runtimeFactory(trial)
            var initialState = runtime.state
            let initialFrame = trial.interventions.frame(at: initialState.time.tick)
            try TissueStateInterventionApplier.apply(initialFrame, to: &initialState)
            let session = NumiTissueSession(backend: runtime.backend)
            try await session.load(model: runtime.model, state: initialState)
            var reports: [NumiTissueStepReport] = []
            reports.reserveCapacity(definition.stepsPerTrial)
            var status: TissueTrialResult.Status = .completed
            for step in 0..<definition.stepsPerTrial {
                let epoch = await session.epoch()
                let time = await session.time()
                var input = try await inputProvider(trial, epoch, time)
                let intervention = trial.interventions.frame(at: time.tick)
                input.stimuli.append(contentsOf: intervention.stimuli)
                if let aware = runtime.backend as? any InterventionAwareTissueBackend {
                    let transaction = TransactionID(rawValue: UInt64(step + 1))
                    let context = RuntimePhasePlanner().context(startTime: time, epoch: epoch, transaction: transaction, randomSeed: seed ^ UInt64(step))
                    try await aware.stageInterventions(intervention, context: context)
                }
                let report = await session.step(input: input, randomSeed: seed ^ UInt64(step) &* 0x9E37_79B9_7F4A_7C15)
                reports.append(report)
                if report.status == .rejected { status = .rejected; break }
                if report.status == .failed { status = .failed; break }
            }
            let finalState = try await session.exportState()
            let metrics = try await metricExtractor(trial, reports, finalState)
            let issues = reports.flatMap { $0.issues.map(\.message) }
            return TissueTrialResult(
                trial: trial,
                status: status,
                seed: seed,
                completedSteps: reports.count { $0.status == .committed },
                finalEpoch: finalState.epoch,
                finalTick: finalState.time.tick,
                metrics: metrics,
                issues: issues,
                errorDescription: reports.last?.errorDescription,
                elapsedSeconds: elapsed(started)
            )
        } catch {
            return TissueTrialResult(
                trial: trial,
                status: .failed,
                seed: seed,
                completedSteps: 0,
                finalEpoch: 0,
                finalTick: 0,
                errorDescription: String(describing: error),
                elapsedSeconds: elapsed(started)
            )
        }
    }

    private static func trialSeed(base: UInt64, trial: TissueExperimentTrial) -> UInt64 {
        var value = base ^ trial.id ^ UInt64(bitPattern: Int64(trial.replicate))
        value &+= 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}

public struct TissueSweepAxis: Sendable, Hashable, Codable {
    public var name: String
    public var values: [Double]

    public init(name: String, values: [Double]) {
        self.name = name
        self.values = values
    }
}

public enum TissueExperimentDesign {
    public static func factorial(
        axes: [TissueSweepAxis],
        replicates: Int,
        intervention: @Sendable ([String: Double]) throws -> TissueInterventionPlan = { _ in TissueInterventionPlan(interventions: []) }
    ) throws -> [TissueExperimentTrial] {
        guard replicates > 0, axes.allSatisfy({ !$0.name.isEmpty && !$0.values.isEmpty && $0.values.allSatisfy(\.isFinite) }) else {
            throw TissueExperimentError.invalidDesign
        }
        var combinations: [[String: Double]] = [[:]]
        for axis in axes {
            guard Set(axes.map(\.name)).count == axes.count else { throw TissueExperimentError.invalidDesign }
            combinations = combinations.flatMap { prefix in
                axis.values.map { value in var next = prefix; next[axis.name] = value; return next }
            }
        }
        var trials: [TissueExperimentTrial] = []
        for (combinationIndex, parameters) in combinations.enumerated() {
            for replicate in 0..<replicates {
                let id = UInt64(combinationIndex * replicates + replicate + 1)
                trials.append(TissueExperimentTrial(id: id, replicate: replicate, parameters: parameters, interventions: try intervention(parameters)))
            }
        }
        return trials
    }

    public static func logarithmicDoseResponse(
        parameterName: String,
        minimum: Double,
        maximum: Double,
        points: Int,
        replicates: Int,
        intervention: @Sendable (Double) throws -> TissueInterventionPlan
    ) throws -> [TissueExperimentTrial] {
        guard minimum > 0, maximum >= minimum, points >= 2 else { throw TissueExperimentError.invalidDesign }
        let values = (0..<points).map { index in
            exp(log(minimum) + Double(index) / Double(points - 1) * (log(maximum) - log(minimum)))
        }
        return try factorial(axes: [TissueSweepAxis(name: parameterName, values: values)], replicates: replicates) { values in
            try intervention(values[parameterName]!)
        }
    }
}

public enum TissueExperimentError: Error, Sendable, CustomStringConvertible {
    case invalidDefinition
    case invalidConcurrency
    case invalidDesign

    public var description: String {
        switch self {
        case .invalidDefinition: return "Tissue experiment definition is invalid"
        case .invalidConcurrency: return "Maximum concurrent trials must be positive"
        case .invalidDesign: return "Tissue experiment design is invalid"
        }
    }
}
