#if canImport(Metal)
import Foundation
import NumiTissueRuntime

public extension Metal4ExecutionConfiguration {
    /// Phase 3 scientific default. It normally records a complete small transaction in one group,
    /// but can split at safe submission boundaries when deep cable trees exceed the bounded arena.
    static let phase3Scientific = Self(
        requirement: .required,
        commandBufferPoolSize: 3,
        maximumBufferBindingCount: 31,
        batchingMode: .boundedDispatchGroups,
        maximumDispatchesPerGroup: 8_192,
        indirectDispatchMode: .disabled,
        indirectDispatchMinimumThreadCount: 4_096,
        qualifiedIndirectKernelNames: [],
        attachStableResidencySetToQueue: true,
        requestResidencyAheadOfExecution: true,
        validateBarrierPlan: true,
        requireQualificationBeforePerformanceMode: true,
        pipelineArchivePath: nil
    )

    /// Performance candidate remains qualification-gated and direct-dispatch-only until individual
    /// worklist kernels have a verified indirect argument layout.
    static let phase3PerformanceCandidate = Self(
        requirement: .required,
        commandBufferPoolSize: 4,
        maximumBufferBindingCount: 31,
        batchingMode: .boundedDispatchGroups,
        maximumDispatchesPerGroup: 16_384,
        indirectDispatchMode: .qualifiedAutomatic,
        indirectDispatchMinimumThreadCount: 4_096,
        qualifiedIndirectKernelNames: [],
        attachStableResidencySetToQueue: true,
        requestResidencyAheadOfExecution: true,
        validateBarrierPlan: true,
        requireQualificationBeforePerformanceMode: true,
        pipelineArchivePath: nil
    )

    /// The historical property name is retained for configuration compatibility. Metal 4 counts
    /// every encoded copy, fill, dispatch, and header transfer against this bound.
    var maximumCommandsPerGroup: Int { maximumDispatchesPerGroup }

    func validatedForMetal4Backend() throws -> Self {
        let value = try validated()
        let requested = Set(value.qualifiedIndirectKernelNames)
        let unsupported = requested.subtracting(
            Metal4IndirectDispatchCatalog.supportedKernelNames
        )
        guard unsupported.isEmpty else {
            throw Metal4ExecutionPolicyError.unsupportedIndirectKernels(
                unsupported.sorted()
            )
        }
        if value.indirectDispatchMode == .disabled,
           !requested.isEmpty {
            throw Metal4ExecutionPolicyError.indirectDisabledWithQualifiedKernels
        }
        return value
    }
}

/// No existing tissue kernel is yet permitted to use the generic worklist dispatch arguments.
/// `nt_encode_indirect_dispatch` emits category counts, while current kernels still index global
/// state pools; enabling it would skip or misaddress entities. Kernels move into this set only after
/// their worklist-indexing ABI and CPU/Metal equivalence fixture are committed.
public enum Metal4IndirectDispatchCatalog {
    public static let supportedKernelNames: Set<String> = []

    public static func supports(_ kernel: MetalKernel) -> Bool {
        supportedKernelNames.contains(kernel.rawValue)
    }
}

public struct Metal4CommandBudgetEstimate: Sendable, Hashable, Codable {
    public var scheduledPhaseCount: Int
    public var kernelDispatchCount: Int
    public var phaseHeaderCopyCount: Int
    public var stateCopyCount: Int
    public var parameterResetCount: Int
    public var transientFillCount: Int
    public var overlayDispatchCount: Int
    public var totalCommandCount: Int
    public var maximumCommandsPerGroup: Int
    public var minimumGroupCount: Int

    public init(
        scheduledPhaseCount: Int,
        kernelDispatchCount: Int,
        phaseHeaderCopyCount: Int,
        stateCopyCount: Int,
        parameterResetCount: Int,
        transientFillCount: Int,
        overlayDispatchCount: Int,
        totalCommandCount: Int,
        maximumCommandsPerGroup: Int,
        minimumGroupCount: Int
    ) {
        self.scheduledPhaseCount = scheduledPhaseCount
        self.kernelDispatchCount = kernelDispatchCount
        self.phaseHeaderCopyCount = phaseHeaderCopyCount
        self.stateCopyCount = stateCopyCount
        self.parameterResetCount = parameterResetCount
        self.transientFillCount = transientFillCount
        self.overlayDispatchCount = overlayDispatchCount
        self.totalCommandCount = totalCommandCount
        self.maximumCommandsPerGroup = maximumCommandsPerGroup
        self.minimumGroupCount = minimumGroupCount
    }
}

/// Conservative source-level estimate for the current phase schedule. It counts kernels even when a
/// particular state pool is empty, so allocation and header-ring limits are checked before opening
/// a transaction. Runtime encoding can only produce the same or fewer commands.
public enum Metal4CommandBudgetEstimator {
    public static func estimate(
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner(),
        startTick: UInt64 = 0,
        maximumCableDepth: UInt32,
        parameterTableCount: Int,
        includesParameterOverlay: Bool,
        maximumCommandsPerGroup: Int
    ) throws -> Metal4CommandBudgetEstimate {
        guard parameterTableCount >= 0,
              maximumCommandsPerGroup > 0 else {
            throw Metal4ExecutionPolicyError.invalidBudgetInputs
        }
        let schedule = phasePlanner.plan(startTick: startTick)
        var dispatches = 0
        for scheduled in schedule {
            dispatches += dispatchCount(
                phase: scheduled.phase,
                tickRange: scheduled.tickRange,
                cadence: phasePlanner.routingBlockTicks,
                cableDepth: maximumCableDepth
            )
        }

        let stateCopies = 12
        let parameterResets = parameterTableCount + 1
        let transientFills = 8
        let overlays = includesParameterOverlay ? 2 : 0
        let headerCopies = dispatches
        let base = stateCopies
            .addingReportingOverflow(parameterResets)
        guard !base.overflow else {
            throw Metal4ExecutionPolicyError.commandBudgetOverflow
        }
        let scratch = base.partialValue.addingReportingOverflow(transientFills)
        guard !scratch.overflow else {
            throw Metal4ExecutionPolicyError.commandBudgetOverflow
        }
        let overlayTotal = scratch.partialValue.addingReportingOverflow(overlays)
        guard !overlayTotal.overflow else {
            throw Metal4ExecutionPolicyError.commandBudgetOverflow
        }
        let dispatchTotal = dispatches.addingReportingOverflow(headerCopies)
        guard !dispatchTotal.overflow else {
            throw Metal4ExecutionPolicyError.commandBudgetOverflow
        }
        let total = overlayTotal.partialValue.addingReportingOverflow(
            dispatchTotal.partialValue
        )
        guard !total.overflow else {
            throw Metal4ExecutionPolicyError.commandBudgetOverflow
        }
        let groups = max(
            1,
            (total.partialValue + maximumCommandsPerGroup - 1) /
                maximumCommandsPerGroup
        )
        return Metal4CommandBudgetEstimate(
            scheduledPhaseCount: schedule.count,
            kernelDispatchCount: dispatches,
            phaseHeaderCopyCount: headerCopies,
            stateCopyCount: stateCopies,
            parameterResetCount: parameterResets,
            transientFillCount: transientFills,
            overlayDispatchCount: overlays,
            totalCommandCount: total.partialValue,
            maximumCommandsPerGroup: maximumCommandsPerGroup,
            minimumGroupCount: groups
        )
    }

    private static func dispatchCount(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        cadence: UInt64,
        cableDepth: UInt32
    ) -> Int {
        switch phase {
        case .ingestInputs: return 1
        case .buildWorklists: return 2
        case .deliverEvents:
            let clears = tickRange.upperBound > tickRange.lowerBound &&
                tickRange.upperBound.isMultiple(of: cadence)
            return clears ? 3 : 2
        case .decaySynapses: return 1
        case .updateChannels: return 1
        case .solveCableTrees:
            let depth = Int(cableDepth)
            let doubled = depth.multipliedReportingOverflow(by: 2)
            return doubled.overflow ? Int.max : doubled.partialValue + 2
        case .detectSpikes: return 1
        case .routeSpikes: return 2
        case .updateFastFields: return 2
        case .updateMolecularDomains: return 1
        case .updateGliaAndMetabolism: return 3
        case .applyPlasticity: return 1
        case .updateCellMechanics: return 1
        case .updateDevelopment: return 1
        case .updateStructuralPlasticity: return 1
        case .updateAdaptiveFidelity: return 1
        case .collectOutputs: return 1
        case .validate: return 1
        }
    }
}

public enum Metal4ExecutionPolicyError: Error, Sendable, CustomStringConvertible {
    case unsupportedIndirectKernels([String])
    case indirectDisabledWithQualifiedKernels
    case invalidBudgetInputs
    case commandBudgetOverflow

    public var description: String {
        switch self {
        case .unsupportedIndirectKernels(let kernels):
            return "Metal 4 indirect dispatch is not implemented for: \(kernels.joined(separator: ", "))"
        case .indirectDisabledWithQualifiedKernels:
            return "Metal 4 indirect dispatch is disabled but qualified kernels were supplied"
        case .invalidBudgetInputs:
            return "Metal 4 command-budget inputs are invalid"
        case .commandBudgetOverflow:
            return "Metal 4 command-budget estimation overflowed"
        }
    }
}
#endif
