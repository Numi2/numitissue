import Foundation
import NumiTissueCore
import NumiTissueModels

public struct DifferentialBackendParticipant: Sendable {
    public var identifier: String
    public var backend: any RuntimePhaseInspectableBackend

    public init(identifier: String, backend: any RuntimePhaseInspectableBackend) {
        precondition(!identifier.isEmpty)
        self.identifier = identifier
        self.backend = backend
    }
}

public enum DifferentialCommitPolicy: String, Sendable, Codable {
    /// Preserves every committed backend state and is the safest mode for isolated validation.
    case rollbackAfterComparison
    /// Advances all backends after every comparison and validation gate succeeds.
    case commitAfterValidation
}

public struct DifferentialExecutionConfiguration: Sendable {
    public var phasePlanner: RuntimePhasePlanner
    public var contract: RuntimeDeterminismContract
    public var commitPolicy: DifferentialCommitPolicy
    public var stopAtFirstDivergence: Bool
    public var inspectedPhases: [RuntimePhase]
    public var maximumInspectionPoints: Int

    public init(
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner(),
        contract: RuntimeDeterminismContract = .scientific32,
        commitPolicy: DifferentialCommitPolicy = .rollbackAfterComparison,
        stopAtFirstDivergence: Bool = true,
        inspectedPhases: [RuntimePhase] = RuntimePhase.allCases,
        maximumInspectionPoints: Int = 20_000
    ) {
        precondition(maximumInspectionPoints > 0)
        self.phasePlanner = phasePlanner
        self.contract = contract
        self.commitPolicy = commitPolicy
        self.stopAtFirstDivergence = stopAtFirstDivergence
        self.inspectedPhases = inspectedPhases
        self.maximumInspectionPoints = maximumInspectionPoints
    }

    public func inspects(_ phase: RuntimePhase) -> Bool {
        inspectedPhases.contains { $0.rawValue == phase.rawValue }
    }
}

public struct DifferentialDigestComparison: Sendable, Codable {
    public var referenceBackend: String
    public var candidateBackend: String
    public var exactDigestMatch: Bool
    public var countMatch: Bool
    public var counterMatch: Bool
    public var mismatchedDomains: [RuntimeComparisonDomain]

    public init(
        referenceBackend: String,
        candidateBackend: String,
        exactDigestMatch: Bool,
        countMatch: Bool,
        counterMatch: Bool,
        mismatchedDomains: [RuntimeComparisonDomain]
    ) {
        self.referenceBackend = referenceBackend
        self.candidateBackend = candidateBackend
        self.exactDigestMatch = exactDigestMatch
        self.countMatch = countMatch
        self.counterMatch = counterMatch
        self.mismatchedDomains = mismatchedDomains
    }

    public var requiresSemanticComparison: Bool {
        !exactDigestMatch || !countMatch || !counterMatch
    }
}

public struct DifferentialCandidatePhaseReport: Sendable, Codable {
    public var candidateBackend: String
    public var candidateProfile: RuntimeNumericalProfile
    public var digestComparison: DifferentialDigestComparison
    public var semanticComparison: RuntimeStateComparisonReport?

    public init(
        candidateBackend: String,
        candidateProfile: RuntimeNumericalProfile,
        digestComparison: DifferentialDigestComparison,
        semanticComparison: RuntimeStateComparisonReport?
    ) {
        self.candidateBackend = candidateBackend
        self.candidateProfile = candidateProfile
        self.digestComparison = digestComparison
        self.semanticComparison = semanticComparison
    }

    public var passed: Bool {
        if let semanticComparison { return semanticComparison.passed }
        return !digestComparison.requiresSemanticComparison
    }
}

public struct DifferentialPhaseReport: Sendable, Codable {
    public var ordinal: Int
    public var phase: RuntimePhase
    public var tickRange: Range<UInt64>
    public var referenceBackend: String
    public var referenceProfile: RuntimeNumericalProfile
    public var referenceDigest: RuntimeComparisonDigest
    public var candidates: [DifferentialCandidatePhaseReport]

    public init(
        ordinal: Int,
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        referenceBackend: String,
        referenceProfile: RuntimeNumericalProfile,
        referenceDigest: RuntimeComparisonDigest,
        candidates: [DifferentialCandidatePhaseReport]
    ) {
        self.ordinal = ordinal
        self.phase = phase
        self.tickRange = tickRange
        self.referenceBackend = referenceBackend
        self.referenceProfile = referenceProfile
        self.referenceDigest = referenceDigest
        self.candidates = candidates
    }

    public var passed: Bool { candidates.allSatisfy(\.passed) }
}

public struct DifferentialValidationOutcome: Sendable, Codable {
    public var backend: String
    public var issues: [RuntimeValidationIssue]

    public init(backend: String, issues: [RuntimeValidationIssue]) {
        self.backend = backend
        self.issues = issues
    }

    public var rejected: Bool { issues.contains { $0.severity == .reject } }
}

public enum DifferentialTransactionDisposition: String, Sendable, Codable {
    case committed
    case rolledBackAfterComparison
    case diverged
    case validationRejected
    case failed
}

public struct DifferentialTransactionReport: Sendable, Codable {
    public var context: DifferentialExecutionContextRecord
    public var contractIdentifier: String
    public var phaseReports: [DifferentialPhaseReport]
    public var outputReports: [RuntimeOutputComparisonReport]
    public var validationOutcomes: [DifferentialValidationOutcome]
    public var disposition: DifferentialTransactionDisposition
    public var firstDivergentPhaseOrdinal: Int?
    public var failureDescription: String?

    public init(
        context: DifferentialExecutionContextRecord,
        contractIdentifier: String,
        phaseReports: [DifferentialPhaseReport],
        outputReports: [RuntimeOutputComparisonReport],
        validationOutcomes: [DifferentialValidationOutcome],
        disposition: DifferentialTransactionDisposition,
        firstDivergentPhaseOrdinal: Int? = nil,
        failureDescription: String? = nil
    ) {
        self.context = context
        self.contractIdentifier = contractIdentifier
        self.phaseReports = phaseReports
        self.outputReports = outputReports
        self.validationOutcomes = validationOutcomes
        self.disposition = disposition
        self.firstDivergentPhaseOrdinal = firstDivergentPhaseOrdinal
        self.failureDescription = failureDescription
    }

    public var passed: Bool {
        firstDivergentPhaseOrdinal == nil &&
            outputReports.allSatisfy(\.passed) &&
            !validationOutcomes.contains(where: \.rejected) &&
            disposition != .failed
    }
}

/// Codable projection of ExecutionContext used by reports and campaign artifacts.
public struct DifferentialExecutionContextRecord: Sendable, Codable {
    public var transaction: TransactionID
    public var epoch: UInt64
    public var startTick: UInt64
    public var endTick: UInt64
    public var randomSeed: UInt64

    public init(_ context: ExecutionContext) {
        transaction = context.transaction
        epoch = context.epoch
        startTick = context.startTime.tick
        endTick = context.endTime.tick
        randomSeed = context.randomSeed
    }
}

/// Runs one authoritative phase schedule through a reference backend and one or more candidates.
/// Digests are compared first; complete semantic state is requested only when a digest, count or
/// exact counter differs. The runner never hides a backend failure or substitutes another backend.
public actor DifferentialTissueRunner {
    public let reference: DifferentialBackendParticipant
    public let candidates: [DifferentialBackendParticipant]
    public let configuration: DifferentialExecutionConfiguration

    private var loaded = false
    private var currentTime = TissueTime()
    private var currentEpoch: UInt64 = 0
    private var nextTransaction: UInt64 = 1

    public init(
        reference: DifferentialBackendParticipant,
        candidates: [DifferentialBackendParticipant],
        configuration: DifferentialExecutionConfiguration = DifferentialExecutionConfiguration()
    ) {
        precondition(!candidates.isEmpty)
        let identifiers = [reference.identifier] + candidates.map(\.identifier)
        precondition(Set(identifiers).count == identifiers.count)
        self.reference = reference
        self.candidates = candidates
        self.configuration = configuration
    }

    public func load(
        model: CompiledTissueModel,
        initialState: TissueRuntimeState
    ) async throws {
        guard !loaded else { throw DifferentialExecutionError.alreadyLoaded }
        try initialState.validateCapacity()
        var loadedParticipants: [DifferentialBackendParticipant] = []
        do {
            try await reference.backend.load(model: model, initialState: initialState)
            loadedParticipants.append(reference)
            for candidate in candidates {
                try await candidate.backend.load(model: model, initialState: initialState)
                loadedParticipants.append(candidate)
            }
        } catch {
            throw DifferentialExecutionError.loadFailure(
                loadedBackends: loadedParticipants.map(\.identifier),
                reason: String(describing: error)
            )
        }
        currentTime = initialState.time
        currentEpoch = initialState.epoch
        loaded = true
    }

    public func step(
        input: RuntimeInputFrame = RuntimeInputFrame(),
        randomSeed: UInt64
    ) async -> DifferentialTransactionReport {
        let context = configuration.phasePlanner.context(
            startTime: currentTime,
            epoch: currentEpoch,
            transaction: TransactionID(rawValue: nextTransaction),
            randomSeed: randomSeed
        )
        nextTransaction &+= 1
        guard loaded else {
            return failedReport(
                context: context,
                reason: DifferentialExecutionError.notLoaded.description
            )
        }

        let participants = [reference] + candidates
        var begun: [DifferentialBackendParticipant] = []
        var phaseReports: [DifferentialPhaseReport] = []
        var outputReports: [RuntimeOutputComparisonReport] = []
        var validationOutcomes: [DifferentialValidationOutcome] = []
        var firstDivergence: Int?

        do {
            for participant in participants {
                try await participant.backend.beginShadowStep(
                    context: context,
                    input: input
                )
                begun.append(participant)
            }

            let schedule = configuration.phasePlanner.plan(
                startTick: context.startTime.tick
            )
            var inspectionCount = 0
            phaseLoop: for (ordinal, scheduled) in schedule.enumerated() {
                for participant in participants {
                    try await participant.backend.execute(
                        phase: scheduled.phase,
                        tickRange: scheduled.tickRange,
                        context: context
                    )
                }

                guard configuration.inspects(scheduled.phase) else { continue }
                inspectionCount += 1
                guard inspectionCount <= configuration.maximumInspectionPoints else {
                    throw DifferentialExecutionError.inspectionLimitExceeded(
                        configuration.maximumInspectionPoints
                    )
                }

                let referenceDigest = try await reference.backend.captureShadowDigest(
                    phase: scheduled.phase,
                    tickRange: scheduled.tickRange,
                    context: context
                )
                var candidateDigests: [RuntimePhaseDigestSnapshot] = []
                candidateDigests.reserveCapacity(candidates.count)
                for candidate in candidates {
                    candidateDigests.append(try await candidate.backend.captureShadowDigest(
                        phase: scheduled.phase,
                        tickRange: scheduled.tickRange,
                        context: context
                    ))
                }

                var semanticReference: RuntimeShadowInspection?
                var candidateReports: [DifferentialCandidatePhaseReport] = []
                for (index, candidate) in candidates.enumerated() {
                    let candidateDigest = candidateDigests[index]
                    let digestComparison = compareDigests(
                        reference: referenceDigest,
                        candidate: candidateDigest,
                        contract: configuration.contract
                    )
                    var semanticComparison: RuntimeStateComparisonReport?
                    if digestComparison.requiresSemanticComparison {
                        if semanticReference == nil {
                            semanticReference = try await reference.backend.exportShadowInspection(
                                phase: scheduled.phase,
                                tickRange: scheduled.tickRange,
                                context: context
                            )
                        }
                        let inspection = try await candidate.backend.exportShadowInspection(
                            phase: scheduled.phase,
                            tickRange: scheduled.tickRange,
                            context: context
                        )
                        semanticComparison = RuntimeStateComparator.compare(
                            reference: semanticReference!,
                            candidate: inspection,
                            contract: configuration.contract
                        )
                    }
                    let report = DifferentialCandidatePhaseReport(
                        candidateBackend: candidate.identifier,
                        candidateProfile: candidateDigest.numericalProfile,
                        digestComparison: digestComparison,
                        semanticComparison: semanticComparison
                    )
                    if !report.passed, firstDivergence == nil {
                        firstDivergence = ordinal
                    }
                    candidateReports.append(report)
                }

                phaseReports.append(DifferentialPhaseReport(
                    ordinal: ordinal,
                    phase: scheduled.phase,
                    tickRange: scheduled.tickRange,
                    referenceBackend: reference.identifier,
                    referenceProfile: referenceDigest.numericalProfile,
                    referenceDigest: referenceDigest.poolDigests.combined,
                    candidates: candidateReports
                ))
                if firstDivergence != nil && configuration.stopAtFirstDivergence {
                    break phaseLoop
                }
            }

            if firstDivergence != nil {
                await rollback(participants: begun, context: context)
                return DifferentialTransactionReport(
                    context: DifferentialExecutionContextRecord(context),
                    contractIdentifier: configuration.contract.identifier,
                    phaseReports: phaseReports,
                    outputReports: [],
                    validationOutcomes: [],
                    disposition: .diverged,
                    firstDivergentPhaseOrdinal: firstDivergence
                )
            }

            let referenceOutput = try await reference.backend.collectOutput(context: context)
            for candidate in candidates {
                let candidateOutput = try await candidate.backend.collectOutput(context: context)
                let comparison = RuntimeStateComparator.compareOutputs(
                    reference: referenceOutput,
                    candidate: candidateOutput,
                    referenceBackend: reference.identifier,
                    candidateBackend: candidate.identifier,
                    contract: configuration.contract
                )
                outputReports.append(comparison)
            }
            if outputReports.contains(where: { !$0.passed }) {
                await rollback(participants: begun, context: context)
                return DifferentialTransactionReport(
                    context: DifferentialExecutionContextRecord(context),
                    contractIdentifier: configuration.contract.identifier,
                    phaseReports: phaseReports,
                    outputReports: outputReports,
                    validationOutcomes: [],
                    disposition: .diverged,
                    firstDivergentPhaseOrdinal: phaseReports.last?.ordinal
                )
            }

            for participant in participants {
                let issues = try await participant.backend.validateShadow(context: context)
                validationOutcomes.append(DifferentialValidationOutcome(
                    backend: participant.identifier,
                    issues: issues
                ))
            }
            let rejectionPattern = validationOutcomes.map(\.rejected)
            let validationParity = Set(rejectionPattern).count <= 1
            if !validationParity || rejectionPattern.contains(true) {
                await rollback(participants: begun, context: context)
                return DifferentialTransactionReport(
                    context: DifferentialExecutionContextRecord(context),
                    contractIdentifier: configuration.contract.identifier,
                    phaseReports: phaseReports,
                    outputReports: outputReports,
                    validationOutcomes: validationOutcomes,
                    disposition: .validationRejected
                )
            }

            switch configuration.commitPolicy {
            case .rollbackAfterComparison:
                await rollback(participants: begun, context: context)
                return DifferentialTransactionReport(
                    context: DifferentialExecutionContextRecord(context),
                    contractIdentifier: configuration.contract.identifier,
                    phaseReports: phaseReports,
                    outputReports: outputReports,
                    validationOutcomes: validationOutcomes,
                    disposition: .rolledBackAfterComparison
                )
            case .commitAfterValidation:
                for participant in participants {
                    try await participant.backend.commitShadow(context: context)
                }
                currentTime = context.endTime
                currentEpoch &+= 1
                return DifferentialTransactionReport(
                    context: DifferentialExecutionContextRecord(context),
                    contractIdentifier: configuration.contract.identifier,
                    phaseReports: phaseReports,
                    outputReports: outputReports,
                    validationOutcomes: validationOutcomes,
                    disposition: .committed
                )
            }
        } catch {
            await rollback(participants: begun, context: context)
            return DifferentialTransactionReport(
                context: DifferentialExecutionContextRecord(context),
                contractIdentifier: configuration.contract.identifier,
                phaseReports: phaseReports,
                outputReports: outputReports,
                validationOutcomes: validationOutcomes,
                disposition: .failed,
                firstDivergentPhaseOrdinal: firstDivergence,
                failureDescription: String(describing: error)
            )
        }
    }

    public func time() -> TissueTime { currentTime }
    public func epoch() -> UInt64 { currentEpoch }

    private func compareDigests(
        reference lhs: RuntimePhaseDigestSnapshot,
        candidate rhs: RuntimePhaseDigestSnapshot,
        contract: RuntimeDeterminismContract
    ) -> DifferentialDigestComparison {
        var mismatched: [RuntimeComparisonDomain] = []
        let pairs: [(RuntimeComparisonDomain, RuntimeComparisonDigest, RuntimeComparisonDigest)] = [
            (.metadata, lhs.poolDigests.metadata, rhs.poolDigests.metadata),
            (.tiles, lhs.poolDigests.tiles, rhs.poolDigests.tiles),
            (.cells, lhs.poolDigests.cells, rhs.poolDigests.cells),
            (.regulatoryState, lhs.poolDigests.regulatoryState, rhs.poolDigests.regulatoryState),
            (.segments, lhs.poolDigests.segments, rhs.poolDigests.segments),
            (.compartments, lhs.poolDigests.compartments, rhs.poolDigests.compartments),
            (.mechanismState, lhs.poolDigests.mechanismState, rhs.poolDigests.mechanismState),
            (.synapses, lhs.poolDigests.synapses, rhs.poolDigests.synapses),
            (.fields, lhs.poolDigests.fields, rhs.poolDigests.fields),
            (.microdomains, lhs.poolDigests.microdomains, rhs.poolDigests.microdomains),
            (.molecularSpecies, lhs.poolDigests.molecularSpecies, rhs.poolDigests.molecularSpecies),
            (.pendingEvents, lhs.poolDigests.pendingEvents, rhs.poolDigests.pendingEvents)
        ]
        for (domain, left, right) in pairs where left != right {
            mismatched.append(domain)
        }
        let counterMatch = !contract.requireExactCounters || lhs.counters == rhs.counters
        return DifferentialDigestComparison(
            referenceBackend: lhs.backendName,
            candidateBackend: rhs.backendName,
            exactDigestMatch: mismatched.isEmpty,
            countMatch: lhs.counts == rhs.counts && lhs.pendingEventCount == rhs.pendingEventCount,
            counterMatch: counterMatch,
            mismatchedDomains: mismatched
        )
    }

    private func rollback(
        participants: [DifferentialBackendParticipant],
        context: ExecutionContext
    ) async {
        for participant in participants.reversed() {
            await participant.backend.rollbackShadow(context: context)
        }
    }

    private func failedReport(
        context: ExecutionContext,
        reason: String
    ) -> DifferentialTransactionReport {
        DifferentialTransactionReport(
            context: DifferentialExecutionContextRecord(context),
            contractIdentifier: configuration.contract.identifier,
            phaseReports: [],
            outputReports: [],
            validationOutcomes: [],
            disposition: .failed,
            failureDescription: reason
        )
    }
}

public enum DifferentialExecutionError: Error, Sendable, CustomStringConvertible {
    case notLoaded
    case alreadyLoaded
    case loadFailure(loadedBackends: [String], reason: String)
    case inspectionLimitExceeded(Int)

    public var description: String {
        switch self {
        case .notLoaded:
            return "Differential runner is not loaded"
        case .alreadyLoaded:
            return "Differential runner is already loaded"
        case .loadFailure(let loaded, let reason):
            return "Differential load failed after [\(loaded.joined(separator: ", "))]: \(reason)"
        case .inspectionLimitExceeded(let limit):
            return "Differential phase inspection exceeded configured limit \(limit)"
        }
    }
}
