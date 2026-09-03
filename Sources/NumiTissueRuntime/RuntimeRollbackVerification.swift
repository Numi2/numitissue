import Foundation
import NumiTissueCore
import NumiTissueModels

public struct RuntimeRollbackBackendBundle: Sendable {
    public var backend: any RuntimePhaseInspectableBackend
    public var checkpointAuthority: (any RuntimeBackendCheckpointStateProvider)?

    public init(
        backend: any RuntimePhaseInspectableBackend,
        checkpointAuthority: (any RuntimeBackendCheckpointStateProvider)? = nil
    ) {
        self.backend = backend
        self.checkpointAuthority = checkpointAuthority
    }
}

public typealias RuntimeRollbackBackendFactory = @Sendable () async throws -> RuntimeRollbackBackendBundle
public typealias RuntimeRollbackInputProvider = @Sendable (_ context: ExecutionContext) async throws -> RuntimeInputFrame

public struct RuntimeRollbackConfiguration: Sendable, Hashable, Codable {
    public var randomSeed: UInt64
    public var requireInjectedFailure: Bool
    public var requireCheckpointIdentity: Bool
    public var inspectCommittedStateAfterRollback: Bool

    public init(
        randomSeed: UInt64 = 0x524F_4C4C_4241_434B,
        requireInjectedFailure: Bool = true,
        requireCheckpointIdentity: Bool = true,
        inspectCommittedStateAfterRollback: Bool = true
    ) {
        self.randomSeed = randomSeed
        self.requireInjectedFailure = requireInjectedFailure
        self.requireCheckpointIdentity = requireCheckpointIdentity
        self.inspectCommittedStateAfterRollback = inspectCommittedStateAfterRollback
    }
}

public enum RuntimeRollbackTrigger: String, Sendable, Hashable, Codable {
    case executionFailure
    case validationRejection
    case explicitRollback
    case beginFailure
}

public struct RuntimeRollbackCertificate: Sendable, Codable {
    public var schemaVersion: UInt32
    public var generatedAt: Date
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var context: DifferentialExecutionContextRecord
    public var trigger: RuntimeRollbackTrigger
    public var failureDescription: String?
    public var baselineStateDigest: RuntimeComparisonDigest
    public var finalStateDigest: RuntimeComparisonDigest?
    public var stateIdentityPreserved: Bool
    public var baselineCheckpointDigest: RuntimeComparisonDigest?
    public var finalCheckpointDigest: RuntimeComparisonDigest?
    public var checkpointIdentityPreserved: Bool?
    public var validationIssues: [RuntimeValidationIssue]
    public var triggeredFaults: [RuntimeFaultObservation]
    public var metadata: [String: String]

    public init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        context: DifferentialExecutionContextRecord,
        trigger: RuntimeRollbackTrigger,
        failureDescription: String?,
        baselineStateDigest: RuntimeComparisonDigest,
        finalStateDigest: RuntimeComparisonDigest?,
        stateIdentityPreserved: Bool,
        baselineCheckpointDigest: RuntimeComparisonDigest?,
        finalCheckpointDigest: RuntimeComparisonDigest?,
        checkpointIdentityPreserved: Bool?,
        validationIssues: [RuntimeValidationIssue],
        triggeredFaults: [RuntimeFaultObservation],
        metadata: [String: String]
    ) {
        schemaVersion = 1
        generatedAt = Date()
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.context = context
        self.trigger = trigger
        self.failureDescription = failureDescription
        self.baselineStateDigest = baselineStateDigest
        self.finalStateDigest = finalStateDigest
        self.stateIdentityPreserved = stateIdentityPreserved
        self.baselineCheckpointDigest = baselineCheckpointDigest
        self.finalCheckpointDigest = finalCheckpointDigest
        self.checkpointIdentityPreserved = checkpointIdentityPreserved
        self.validationIssues = validationIssues
        self.triggeredFaults = triggeredFaults
        self.metadata = metadata
    }

    public var passed: Bool {
        stateIdentityPreserved &&
            (checkpointIdentityPreserved ?? true) &&
            finalStateDigest != nil &&
            (failureDescription != nil || trigger == .explicitRollback)
    }
}

/// Executes one transaction, forces or observes rollback, and certifies that both authoritative
/// state and backend-private delayed state retain their exact pre-transaction identities.
public actor RuntimeRollbackVerifier {
    public let backendFactory: RuntimeRollbackBackendFactory
    public let model: CompiledTissueModel
    public let initialState: TissueRuntimeState
    public let phasePlanner: RuntimePhasePlanner
    public let configuration: RuntimeRollbackConfiguration

    public init(
        backendFactory: @escaping RuntimeRollbackBackendFactory,
        model: CompiledTissueModel,
        initialState: TissueRuntimeState,
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner(),
        configuration: RuntimeRollbackConfiguration = RuntimeRollbackConfiguration()
    ) {
        self.backendFactory = backendFactory
        self.model = model
        self.initialState = initialState
        self.phasePlanner = phasePlanner
        self.configuration = configuration
    }

    public func verify(
        input: @escaping RuntimeRollbackInputProvider = { _ in RuntimeInputFrame() },
        metadata: [String: String] = [:]
    ) async throws -> RuntimeRollbackCertificate {
        try initialState.validateCapacity()
        let bundle = try await backendFactory()
        let backend = bundle.backend
        try await backend.load(model: model, initialState: initialState)

        let baselineState = try await backend.exportCommittedState()
        let baselineStateDigest = RuntimeStateDigestBuilder.make(
            state: baselineState
        ).combined
        let baselineCheckpoint = try await checkpointDigest(
            bundle.checkpointAuthority
        )
        if configuration.requireCheckpointIdentity,
           baselineCheckpoint == nil {
            throw RuntimeRollbackVerificationError.missingCheckpointAuthority
        }

        let context = phasePlanner.context(
            startTime: initialState.time,
            epoch: initialState.epoch,
            transaction: TransactionID(rawValue: 1),
            randomSeed: configuration.randomSeed
        )
        var began = false
        var trigger: RuntimeRollbackTrigger = .explicitRollback
        var failureDescription: String?
        var validationIssues: [RuntimeValidationIssue] = []

        do {
            let frame = try await input(context)
            try await backend.beginShadowStep(context: context, input: frame)
            began = true
            for scheduled in phasePlanner.plan(startTick: context.startTime.tick) {
                try await backend.execute(
                    phase: scheduled.phase,
                    tickRange: scheduled.tickRange,
                    context: context
                )
            }
            _ = try await backend.collectOutput(context: context)
            validationIssues = try await backend.validateShadow(context: context)
            if validationIssues.contains(where: { $0.severity == .reject }) {
                trigger = .validationRejection
                failureDescription = "Shadow validation rejected the transaction"
            } else if configuration.requireInjectedFailure {
                failureDescription = "Transaction completed without the required injected failure"
            }
        } catch {
            failureDescription = String(describing: error)
            trigger = began ? .executionFailure : .beginFailure
        }

        if began {
            await backend.rollbackShadow(context: context)
        }

        if configuration.requireInjectedFailure,
           trigger == .explicitRollback {
            throw RuntimeRollbackVerificationError.expectedFailureDidNotOccur
        }

        let finalState: TissueRuntimeState?
        if configuration.inspectCommittedStateAfterRollback {
            finalState = try await backend.exportCommittedState()
        } else {
            finalState = nil
        }
        let finalStateDigest = finalState.map {
            RuntimeStateDigestBuilder.make(state: $0).combined
        }
        let finalCheckpoint = try await checkpointDigest(
            bundle.checkpointAuthority
        )
        let checkpointIdentity: Bool?
        if baselineCheckpoint != nil || finalCheckpoint != nil {
            checkpointIdentity = baselineCheckpoint == finalCheckpoint
        } else {
            checkpointIdentity = nil
        }
        let faults: [RuntimeFaultObservation]
        if let faulting = backend as? FaultInjectingTissueBackend {
            faults = await faulting.triggeredFaults()
        } else {
            faults = []
        }

        return RuntimeRollbackCertificate(
            backendName: backend.name,
            numericalProfile: backend.numericalProfile,
            context: DifferentialExecutionContextRecord(context),
            trigger: trigger,
            failureDescription: failureDescription,
            baselineStateDigest: baselineStateDigest,
            finalStateDigest: finalStateDigest,
            stateIdentityPreserved: finalStateDigest == baselineStateDigest,
            baselineCheckpointDigest: baselineCheckpoint,
            finalCheckpointDigest: finalCheckpoint,
            checkpointIdentityPreserved: checkpointIdentity,
            validationIssues: validationIssues,
            triggeredFaults: faults,
            metadata: metadata
        )
    }

    private func checkpointDigest(
        _ provider: (any RuntimeBackendCheckpointStateProvider)?
    ) async throws -> RuntimeComparisonDigest? {
        guard let provider else { return nil }
        let data = try await provider.exportBackendCheckpointState()
        var digest = RuntimeDigestAccumulator(domain: 0x524F_4C4C_4348_4B50)
        digest.combine(data.count)
        for byte in data { digest.combine(byte) }
        return digest.finalize()
    }
}

public enum RuntimeRollbackVerificationError: Error, Sendable, CustomStringConvertible {
    case missingCheckpointAuthority
    case expectedFailureDidNotOccur

    public var description: String {
        switch self {
        case .missingCheckpointAuthority:
            return "Rollback verification requires backend checkpoint authority"
        case .expectedFailureDidNotOccur:
            return "Rollback verification expected an injected failure, but execution completed"
        }
    }
}
