import Foundation
import NumiTissueCore
import NumiTissueModels

public struct RuntimeReplayStepIdentity: Sendable, Hashable, Codable {
    public var ordinal: Int
    public var transaction: TransactionID
    public var stateDigest: RuntimeComparisonDigest
    public var backendCheckpointDigest: RuntimeComparisonDigest?
    public var outputDigest: RuntimeComparisonDigest
    public var counters: RuntimeCounters
    public var validationDigest: RuntimeComparisonDigest

    public init(
        ordinal: Int,
        transaction: TransactionID,
        stateDigest: RuntimeComparisonDigest,
        backendCheckpointDigest: RuntimeComparisonDigest?,
        outputDigest: RuntimeComparisonDigest,
        counters: RuntimeCounters,
        validationDigest: RuntimeComparisonDigest
    ) {
        self.ordinal = ordinal
        self.transaction = transaction
        self.stateDigest = stateDigest
        self.backendCheckpointDigest = backendCheckpointDigest
        self.outputDigest = outputDigest
        self.counters = counters
        self.validationDigest = validationDigest
    }
}

public struct RuntimeReplayRun: Sendable, Hashable, Codable {
    public var ordinal: Int
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var steps: [RuntimeReplayStepIdentity]
    public var failureDescription: String?

    public init(
        ordinal: Int,
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        steps: [RuntimeReplayStepIdentity],
        failureDescription: String? = nil
    ) {
        self.ordinal = ordinal
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.steps = steps
        self.failureDescription = failureDescription
    }
}

public struct RuntimeReplayMismatch: Sendable, Hashable, Codable {
    public var runOrdinal: Int
    public var stepOrdinal: Int?
    public var component: String
    public var baseline: String
    public var candidate: String

    public init(
        runOrdinal: Int,
        stepOrdinal: Int?,
        component: String,
        baseline: String,
        candidate: String
    ) {
        self.runOrdinal = runOrdinal
        self.stepOrdinal = stepOrdinal
        self.component = component
        self.baseline = baseline
        self.candidate = candidate
    }
}

public struct RuntimeReproducibilityConfiguration: Sendable, Hashable, Codable {
    public var repetitions: Int
    public var transactionsPerRun: Int
    public var randomSeed: UInt64
    public var requireBackendCheckpointIdentity: Bool
    public var maximumReportedMismatches: Int

    public init(
        repetitions: Int = 3,
        transactionsPerRun: Int = 10,
        randomSeed: UInt64 = 0x5245_5052_4F44_5543,
        requireBackendCheckpointIdentity: Bool = true,
        maximumReportedMismatches: Int = 128
    ) {
        precondition(repetitions >= 2)
        precondition(transactionsPerRun > 0)
        precondition(maximumReportedMismatches > 0)
        self.repetitions = repetitions
        self.transactionsPerRun = transactionsPerRun
        self.randomSeed = randomSeed
        self.requireBackendCheckpointIdentity = requireBackendCheckpointIdentity
        self.maximumReportedMismatches = maximumReportedMismatches
    }
}

public struct RuntimeReproducibilityCertificate: Sendable, Codable {
    public var schemaVersion: UInt32
    public var generatedAt: Date
    public var configuration: RuntimeReproducibilityConfiguration
    public var runs: [RuntimeReplayRun]
    public var mismatches: [RuntimeReplayMismatch]
    public var omittedMismatchCount: Int
    public var metadata: [String: String]

    public init(
        configuration: RuntimeReproducibilityConfiguration,
        runs: [RuntimeReplayRun],
        mismatches: [RuntimeReplayMismatch],
        omittedMismatchCount: Int,
        metadata: [String: String] = [:]
    ) {
        schemaVersion = 1
        generatedAt = Date()
        self.configuration = configuration
        self.runs = runs
        self.mismatches = mismatches
        self.omittedMismatchCount = omittedMismatchCount
        self.metadata = metadata
    }

    public var passed: Bool {
        runs.allSatisfy { $0.failureDescription == nil } && mismatches.isEmpty && omittedMismatchCount == 0
    }
}

public typealias RuntimeReproducibilityBackendFactory = @Sendable () async throws -> any RuntimePhaseInspectableBackend
public typealias RuntimeReproducibilityInputProvider = @Sendable (_ ordinal: Int, _ time: TissueTime) async throws -> RuntimeInputFrame

/// Recreates the backend for every repetition and executes an identical input/seed sequence. The
/// certificate covers authoritative state, delayed/backend-specific state when supported, output,
/// validation and counters after every committed transaction.
public actor RuntimeReproducibilityVerifier {
    public let backendFactory: RuntimeReproducibilityBackendFactory
    public let model: CompiledTissueModel
    public let initialState: TissueRuntimeState
    public let phasePlanner: RuntimePhasePlanner
    public let configuration: RuntimeReproducibilityConfiguration

    public init(
        backendFactory: @escaping RuntimeReproducibilityBackendFactory,
        model: CompiledTissueModel,
        initialState: TissueRuntimeState,
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner(),
        configuration: RuntimeReproducibilityConfiguration = RuntimeReproducibilityConfiguration()
    ) {
        self.backendFactory = backendFactory
        self.model = model
        self.initialState = initialState
        self.phasePlanner = phasePlanner
        self.configuration = configuration
    }

    public func verify(
        input: @escaping RuntimeReproducibilityInputProvider = { _, _ in RuntimeInputFrame() },
        metadata: [String: String] = [:]
    ) async throws -> RuntimeReproducibilityCertificate {
        try initialState.validateCapacity()
        var runs: [RuntimeReplayRun] = []
        runs.reserveCapacity(configuration.repetitions)
        for repetition in 0..<configuration.repetitions {
            runs.append(try await executeRun(ordinal: repetition, input: input))
        }

        var mismatches: [RuntimeReplayMismatch] = []
        var omitted = 0
        if let baseline = runs.first {
            for run in runs.dropFirst() {
                compare(
                    baseline: baseline,
                    candidate: run,
                    mismatches: &mismatches,
                    omitted: &omitted
                )
            }
        }
        return RuntimeReproducibilityCertificate(
            configuration: configuration,
            runs: runs,
            mismatches: mismatches,
            omittedMismatchCount: omitted,
            metadata: metadata
        )
    }

    private func executeRun(
        ordinal: Int,
        input: @escaping RuntimeReproducibilityInputProvider
    ) async throws -> RuntimeReplayRun {
        let backend = try await backendFactory()
        try await backend.load(model: model, initialState: initialState)
        var time = initialState.time
        var epoch = initialState.epoch
        var steps: [RuntimeReplayStepIdentity] = []
        steps.reserveCapacity(configuration.transactionsPerRun)

        for stepOrdinal in 0..<configuration.transactionsPerRun {
            let context = phasePlanner.context(
                startTime: time,
                epoch: epoch,
                transaction: TransactionID(rawValue: UInt64(stepOrdinal + 1)),
                randomSeed: transactionSeed(stepOrdinal)
            )
            let frame = try await input(stepOrdinal, time)
            do {
                try await backend.beginShadowStep(context: context, input: frame)
                for scheduled in phasePlanner.plan(startTick: time.tick) {
                    try await backend.execute(
                        phase: scheduled.phase,
                        tickRange: scheduled.tickRange,
                        context: context
                    )
                }
                let output = try await backend.collectOutput(context: context)
                let issues = try await backend.validateShadow(context: context)
                guard !issues.contains(where: { $0.severity == .reject }) else {
                    await backend.rollbackShadow(context: context)
                    return RuntimeReplayRun(
                        ordinal: ordinal,
                        backendName: backend.name,
                        numericalProfile: backend.numericalProfile,
                        steps: steps,
                        failureDescription: "Validation rejected step \(stepOrdinal)"
                    )
                }
                try await backend.commitShadow(context: context)
                let state = try await backend.exportCommittedState()
                let checkpointDigest: RuntimeComparisonDigest?
                if let provider = backend as? any RuntimeBackendCheckpointStateProvider {
                    checkpointDigest = Self.digest(
                        data: try await provider.exportBackendCheckpointState(),
                        domain: 0x4348_4543_4B50_4F49
                    )
                } else if configuration.requireBackendCheckpointIdentity {
                    return RuntimeReplayRun(
                        ordinal: ordinal,
                        backendName: backend.name,
                        numericalProfile: backend.numericalProfile,
                        steps: steps,
                        failureDescription: "Backend does not expose deterministic checkpoint state"
                    )
                } else {
                    checkpointDigest = nil
                }
                steps.append(RuntimeReplayStepIdentity(
                    ordinal: stepOrdinal,
                    transaction: context.transaction,
                    stateDigest: RuntimeStateDigestBuilder.make(state: state).combined,
                    backendCheckpointDigest: checkpointDigest,
                    outputDigest: Self.digest(output: output),
                    counters: await backend.counters(context: context),
                    validationDigest: Self.digest(validationIssues: issues)
                ))
                time = context.endTime
                epoch &+= 1
            } catch {
                await backend.rollbackShadow(context: context)
                return RuntimeReplayRun(
                    ordinal: ordinal,
                    backendName: backend.name,
                    numericalProfile: backend.numericalProfile,
                    steps: steps,
                    failureDescription: String(describing: error)
                )
            }
        }
        return RuntimeReplayRun(
            ordinal: ordinal,
            backendName: backend.name,
            numericalProfile: backend.numericalProfile,
            steps: steps
        )
    }

    private func compare(
        baseline: RuntimeReplayRun,
        candidate: RuntimeReplayRun,
        mismatches: inout [RuntimeReplayMismatch],
        omitted: inout Int
    ) {
        compareValue(
            baseline.backendName,
            candidate.backendName,
            run: candidate.ordinal,
            step: nil,
            component: "backendName",
            mismatches: &mismatches,
            omitted: &omitted
        )
        compareValue(
            baseline.numericalProfile,
            candidate.numericalProfile,
            run: candidate.ordinal,
            step: nil,
            component: "numericalProfile",
            mismatches: &mismatches,
            omitted: &omitted
        )
        compareValue(
            baseline.failureDescription,
            candidate.failureDescription,
            run: candidate.ordinal,
            step: nil,
            component: "failureDescription",
            mismatches: &mismatches,
            omitted: &omitted
        )
        compareValue(
            baseline.steps.count,
            candidate.steps.count,
            run: candidate.ordinal,
            step: nil,
            component: "stepCount",
            mismatches: &mismatches,
            omitted: &omitted
        )
        for index in 0..<min(baseline.steps.count, candidate.steps.count) {
            let left = baseline.steps[index]
            let right = candidate.steps[index]
            compareValue(left.transaction, right.transaction, run: candidate.ordinal, step: index, component: "transaction", mismatches: &mismatches, omitted: &omitted)
            compareValue(left.stateDigest, right.stateDigest, run: candidate.ordinal, step: index, component: "stateDigest", mismatches: &mismatches, omitted: &omitted)
            compareValue(left.backendCheckpointDigest, right.backendCheckpointDigest, run: candidate.ordinal, step: index, component: "backendCheckpointDigest", mismatches: &mismatches, omitted: &omitted)
            compareValue(left.outputDigest, right.outputDigest, run: candidate.ordinal, step: index, component: "outputDigest", mismatches: &mismatches, omitted: &omitted)
            compareValue(left.counters, right.counters, run: candidate.ordinal, step: index, component: "counters", mismatches: &mismatches, omitted: &omitted)
            compareValue(left.validationDigest, right.validationDigest, run: candidate.ordinal, step: index, component: "validationDigest", mismatches: &mismatches, omitted: &omitted)
        }
    }

    private func compareValue<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        run: Int,
        step: Int?,
        component: String,
        mismatches: inout [RuntimeReplayMismatch],
        omitted: inout Int
    ) {
        guard lhs != rhs else { return }
        if mismatches.count < configuration.maximumReportedMismatches {
            mismatches.append(RuntimeReplayMismatch(
                runOrdinal: run,
                stepOrdinal: step,
                component: component,
                baseline: String(describing: lhs),
                candidate: String(describing: rhs)
            ))
        } else {
            omitted += 1
        }
    }

    private func transactionSeed(_ ordinal: Int) -> UInt64 {
        var value = configuration.randomSeed &+ UInt64(ordinal) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func digest(output: RuntimeOutputFrame) -> RuntimeComparisonDigest {
        var digest = RuntimeDigestAccumulator(domain: 0x4F55_5450_5554_0001)
        digest.combine(output.startTime.tick)
        digest.combine(output.endTime.tick)
        digest.combine(output.efferentEvents.count)
        for event in output.efferentEvents {
            combine(event, into: &digest)
        }
        digest.combine(output.populationActivity.count)
        for value in output.populationActivity { digest.combine(value) }
        digest.combine(output.localFieldPotentials.count)
        for value in output.localFieldPotentials { digest.combine(value) }
        digest.combine(output.metabolicDemand.count)
        for value in output.metabolicDemand { digest.combine(value) }
        digest.combine(output.damageEvents.count)
        for event in output.damageEvents { combine(event, into: &digest) }
        digest.combine(output.uncertainty)
        digest.combine(output.plasticityMagnitude)
        return digest.finalize()
    }

    private static func digest(
        validationIssues: [RuntimeValidationIssue]
    ) -> RuntimeComparisonDigest {
        var digest = RuntimeDigestAccumulator(domain: 0x5641_4C49_4441_5445)
        let issues = validationIssues.sorted {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue < $1.severity.rawValue
            }
            if $0.code != $1.code { return $0.code < $1.code }
            if $0.entity != $1.entity { return $0.entity < $1.entity }
            if $0.value.bitPattern != $1.value.bitPattern {
                return $0.value.bitPattern < $1.value.bitPattern
            }
            return $0.message < $1.message
        }
        digest.combine(issues.count)
        for issue in issues {
            digest.combine(issue.severity.rawValue)
            digest.combine(issue.code)
            digest.combine(issue.entity)
            digest.combine(issue.value)
            combine(issue.message, into: &digest)
        }
        return digest.finalize()
    }

    private static func digest(
        data: Data,
        domain: UInt64
    ) -> RuntimeComparisonDigest {
        var digest = RuntimeDigestAccumulator(domain: domain)
        digest.combine(data.count)
        for byte in data { digest.combine(byte) }
        return digest.finalize()
    }

    private static func combine(
        _ event: RoutedEvent,
        into digest: inout RuntimeDigestAccumulator
    ) {
        digest.combine(event.arrivalTick)
        digest.combine(event.source)
        digest.combine(event.destination)
        digest.combine(event.amplitude)
        digest.combine(event.kind.rawValue)
        digest.combine(event.flags)
        digest.combine(event.sequence)
    }

    private static func combine(
        _ string: String,
        into digest: inout RuntimeDigestAccumulator
    ) {
        let bytes = string.data(using: .utf8) ?? Data()
        digest.combine(bytes.count)
        for byte in bytes { digest.combine(byte) }
    }
}
