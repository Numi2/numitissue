#if canImport(Metal)
import Foundation
import Metal
import NumiTissueRuntime

/// Selects whether Metal 4 is disabled, preferred with an explicit legacy fallback, or required.
/// The requirement is recorded in experiment provenance so a scientific run cannot silently move
/// between submission models.
public enum Metal4BackendRequirement: String, Sendable, Hashable, Codable, CaseIterable {
    case disabled
    case preferred
    case required
}

/// Controls how the Metal 4 backend groups work into unified compute passes.
public enum Metal4BatchingMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Encode the complete five-millisecond transaction into one compute pass whenever no
    /// inspection or host decision requires a split.
    case unifiedTransaction
    /// Split only at runtime phase boundaries. This is the diagnostic mode used to isolate
    /// encoder-level issues while preserving Metal 4 resource binding and command allocation.
    case phaseBoundaries
    /// Split after a bounded number of dispatches to cap command-memory growth.
    case boundedDispatchGroups
}

/// Controls use of GPU-authored dispatch arguments. Automatic mode never assumes that indirect
/// dispatch is faster; a kernel must be present in the measured qualification allow-list.
public enum Metal4IndirectDispatchMode: String, Sendable, Hashable, Codable, CaseIterable {
    case disabled
    case qualifiedAutomatic
    case requireQualified
}

/// Immutable configuration for the Metal 4 execution path. Values are deliberately bounded so a
/// malformed configuration cannot allocate unbounded command or binding state.
public struct Metal4ExecutionConfiguration: Sendable, Hashable, Codable {
    public var requirement: Metal4BackendRequirement
    public var commandBufferPoolSize: Int
    public var maximumBufferBindingCount: Int
    public var batchingMode: Metal4BatchingMode
    public var maximumDispatchesPerGroup: Int
    public var indirectDispatchMode: Metal4IndirectDispatchMode
    public var indirectDispatchMinimumThreadCount: Int
    public var qualifiedIndirectKernelNames: [String]
    public var attachStableResidencySetToQueue: Bool
    public var requestResidencyAheadOfExecution: Bool
    public var validateBarrierPlan: Bool
    public var requireQualificationBeforePerformanceMode: Bool
    public var pipelineArchivePath: String?

    public init(
        requirement: Metal4BackendRequirement = .preferred,
        commandBufferPoolSize: Int = 3,
        maximumBufferBindingCount: Int = 32,
        batchingMode: Metal4BatchingMode = .unifiedTransaction,
        maximumDispatchesPerGroup: Int = 2_048,
        indirectDispatchMode: Metal4IndirectDispatchMode = .qualifiedAutomatic,
        indirectDispatchMinimumThreadCount: Int = 4_096,
        qualifiedIndirectKernelNames: [String] = [],
        attachStableResidencySetToQueue: Bool = true,
        requestResidencyAheadOfExecution: Bool = true,
        validateBarrierPlan: Bool = true,
        requireQualificationBeforePerformanceMode: Bool = true,
        pipelineArchivePath: String? = nil
    ) {
        self.requirement = requirement
        self.commandBufferPoolSize = commandBufferPoolSize
        self.maximumBufferBindingCount = maximumBufferBindingCount
        self.batchingMode = batchingMode
        self.maximumDispatchesPerGroup = maximumDispatchesPerGroup
        self.indirectDispatchMode = indirectDispatchMode
        self.indirectDispatchMinimumThreadCount = indirectDispatchMinimumThreadCount
        self.qualifiedIndirectKernelNames = qualifiedIndirectKernelNames
        self.attachStableResidencySetToQueue = attachStableResidencySetToQueue
        self.requestResidencyAheadOfExecution = requestResidencyAheadOfExecution
        self.validateBarrierPlan = validateBarrierPlan
        self.requireQualificationBeforePerformanceMode = requireQualificationBeforePerformanceMode
        self.pipelineArchivePath = pipelineArchivePath
    }

    public static let scientific = Self(
        requirement: .required,
        commandBufferPoolSize: 2,
        batchingMode: .unifiedTransaction,
        indirectDispatchMode: .disabled,
        validateBarrierPlan: true,
        requireQualificationBeforePerformanceMode: true
    )

    public func validated() throws -> Self {
        guard (1...64).contains(commandBufferPoolSize) else {
            throw Metal4ContractError.invalidCommandBufferPoolSize(commandBufferPoolSize)
        }
        guard (1...256).contains(maximumBufferBindingCount) else {
            throw Metal4ContractError.invalidBindingCount(maximumBufferBindingCount)
        }
        guard (1...1_000_000).contains(maximumDispatchesPerGroup) else {
            throw Metal4ContractError.invalidDispatchGroupLimit(maximumDispatchesPerGroup)
        }
        guard indirectDispatchMinimumThreadCount >= 1 else {
            throw Metal4ContractError.invalidIndirectThreshold(
                indirectDispatchMinimumThreadCount
            )
        }
        guard qualifiedIndirectKernelNames.allSatisfy({ !$0.isEmpty }),
              Set(qualifiedIndirectKernelNames).count == qualifiedIndirectKernelNames.count else {
            throw Metal4ContractError.invalidQualifiedKernelNames
        }
        if let pipelineArchivePath {
            guard !pipelineArchivePath.isEmpty,
                  !pipelineArchivePath.contains("\0") else {
                throw Metal4ContractError.invalidPipelineArchivePath
            }
        }
        var result = self
        result.qualifiedIndirectKernelNames.sort()
        return result
    }
}

/// Logical resource domains used to derive synchronization requirements. They are semantic rather
/// than byte ranges: a future layout change cannot silently remove a required barrier.
public enum Metal4ResourceDomain: String, Sendable, Hashable, Codable, CaseIterable {
    case phaseHeader
    case committedState
    case shadowState
    case structuralTopology
    case fidelityMigration
    case inputEvents
    case stimuli
    case eventWheel
    case outgoingEvents
    case outputEvents
    case worklists
    case validationRecords
    case runtimeCounters
    case outputScalars
    case indirectDispatch
    case modelMetadata
    case baselineParameters
    case effectiveParameters
    case diagnosticDigest
}

public enum Metal4AccessMode: String, Sendable, Hashable, Codable {
    case read
    case write
    case readWrite

    public var reads: Bool { self != .write }
    public var writes: Bool { self != .read }
}

public enum Metal4CommandStage: String, Sendable, Hashable, Codable {
    case blit
    case dispatch
}

public struct Metal4ResourceAccess: Sendable, Hashable, Codable {
    public var resource: Metal4ResourceDomain
    public var mode: Metal4AccessMode

    public init(_ resource: Metal4ResourceDomain, _ mode: Metal4AccessMode) {
        self.resource = resource
        self.mode = mode
    }
}

/// A command-level access declaration used by the synchronization planner. The label is stable and
/// is included in diagnostics when a generated barrier plan is rejected.
public struct Metal4CommandAccess: Sendable, Hashable, Codable {
    public var label: String
    public var stage: Metal4CommandStage
    public var accesses: [Metal4ResourceAccess]

    public init(
        label: String,
        stage: Metal4CommandStage,
        accesses: [Metal4ResourceAccess]
    ) {
        self.label = label
        self.stage = stage
        self.accesses = accesses
    }

    public static let copyCommittedToShadow = Self(
        label: "copy-committed-to-shadow",
        stage: .blit,
        accesses: [
            .init(.committedState, .read),
            .init(.shadowState, .write),
            .init(.structuralTopology, .read)
        ]
    )

    public static let resetEffectiveParameters = Self(
        label: "reset-effective-parameters",
        stage: .blit,
        accesses: [
            .init(.baselineParameters, .read),
            .init(.effectiveParameters, .write)
        ]
    )

    public static let copyPhaseHeader = Self(
        label: "copy-phase-header",
        stage: .blit,
        accesses: [.init(.phaseHeader, .write)]
    )

    public static let resetTransientState = Self(
        label: "reset-transient-state",
        stage: .blit,
        accesses: [
            .init(.eventWheel, .write),
            .init(.outgoingEvents, .write),
            .init(.outputEvents, .write),
            .init(.worklists, .write),
            .init(.validationRecords, .write),
            .init(.runtimeCounters, .write),
            .init(.outputScalars, .write),
            .init(.indirectDispatch, .write)
        ]
    )

    public static func dispatch(_ kernel: MetalKernel) -> Self {
        Metal4KernelAccessCatalog.command(for: kernel)
    }
}

public struct Metal4BarrierDecision: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case none
        case blitToBlit
        case blitToDispatch
        case dispatchToBlit
        case dispatchToDispatch
    }

    public var kind: Kind
    public var afterLabel: String?
    public var beforeLabel: String
    public var hazards: [Metal4ResourceDomain]

    public init(
        kind: Kind,
        afterLabel: String?,
        beforeLabel: String,
        hazards: [Metal4ResourceDomain]
    ) {
        self.kind = kind
        self.afterLabel = afterLabel
        self.beforeLabel = beforeLabel
        self.hazards = hazards
    }

    public var requiresBarrier: Bool { kind != .none }
}

/// Derives the minimum conservative intra-pass synchronization required by semantic resource
/// hazards. Read-after-read transitions never receive barriers.
public enum Metal4HazardPlanner {
    public static func barrier(
        after previous: Metal4CommandAccess?,
        before next: Metal4CommandAccess
    ) -> Metal4BarrierDecision {
        guard let previous else {
            return Metal4BarrierDecision(
                kind: .none,
                afterLabel: nil,
                beforeLabel: next.label,
                hazards: []
            )
        }

        let previousByResource = Dictionary(
            previous.accesses.map { ($0.resource, $0.mode) },
            uniquingKeysWith: Self.merge
        )
        let nextByResource = Dictionary(
            next.accesses.map { ($0.resource, $0.mode) },
            uniquingKeysWith: Self.merge
        )
        let hazards = Set(previousByResource.keys)
            .intersection(nextByResource.keys)
            .filter { resource in
                guard let lhs = previousByResource[resource],
                      let rhs = nextByResource[resource] else { return false }
                return lhs.writes || rhs.writes
            }
            .sorted { $0.rawValue < $1.rawValue }

        guard !hazards.isEmpty else {
            return Metal4BarrierDecision(
                kind: .none,
                afterLabel: previous.label,
                beforeLabel: next.label,
                hazards: []
            )
        }

        let kind: Metal4BarrierDecision.Kind
        switch (previous.stage, next.stage) {
        case (.blit, .blit): kind = .blitToBlit
        case (.blit, .dispatch): kind = .blitToDispatch
        case (.dispatch, .blit): kind = .dispatchToBlit
        case (.dispatch, .dispatch): kind = .dispatchToDispatch
        }
        return Metal4BarrierDecision(
            kind: kind,
            afterLabel: previous.label,
            beforeLabel: next.label,
            hazards: hazards
        )
    }

    public static func plan(
        _ commands: [Metal4CommandAccess]
    ) -> [Metal4BarrierDecision] {
        var previous: Metal4CommandAccess?
        var result: [Metal4BarrierDecision] = []
        result.reserveCapacity(commands.count)
        for command in commands {
            result.append(barrier(after: previous, before: command))
            previous = command
        }
        return result
    }

    public static func validate(
        commands: [Metal4CommandAccess],
        decisions: [Metal4BarrierDecision]
    ) throws {
        guard commands.count == decisions.count else {
            throw Metal4ContractError.barrierPlanCountMismatch(
                commands: commands.count,
                decisions: decisions.count
            )
        }
        let expected = plan(commands)
        for index in commands.indices where expected[index] != decisions[index] {
            throw Metal4ContractError.barrierPlanMismatch(
                index: index,
                expected: expected[index],
                actual: decisions[index]
            )
        }
    }

    private static func merge(
        _ lhs: Metal4AccessMode,
        _ rhs: Metal4AccessMode
    ) -> Metal4AccessMode {
        if lhs == rhs { return lhs }
        if lhs.writes || rhs.writes {
            return lhs.reads || rhs.reads ? .readWrite : .write
        }
        return .read
    }
}

/// Complete access catalog for production kernels. Adding a `MetalKernel` case makes this switch
/// non-exhaustive, forcing the synchronization contract to be updated with the kernel.
public enum Metal4KernelAccessCatalog {
    public static func command(for kernel: MetalKernel) -> Metal4CommandAccess {
        let access: [Metal4ResourceAccess]
        switch kernel {
        case .resetTransientState:
            access = Metal4CommandAccess.resetTransientState.accesses
        case .materializeStateOverlays:
            access = [
                .init(.shadowState, .readWrite),
                .init(.effectiveParameters, .read),
                .init(.runtimeCounters, .readWrite)
            ]
        case .materializeParameterOverlays:
            access = [
                .init(.effectiveParameters, .readWrite),
                .init(.runtimeCounters, .readWrite)
            ]
        case .buildWorklists:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .read),
                .init(.worklists, .write),
                .init(.runtimeCounters, .readWrite)
            ]
        case .encodeIndirectDispatch:
            access = [
                .init(.phaseHeader, .read),
                .init(.worklists, .read),
                .init(.indirectDispatch, .write)
            ]
        case .ingestInputEvents:
            access = [
                .init(.phaseHeader, .read),
                .init(.inputEvents, .read),
                .init(.stimuli, .read),
                .init(.eventWheel, .readWrite),
                .init(.runtimeCounters, .readWrite)
            ]
        case .sortEventBucket:
            access = [
                .init(.phaseHeader, .read),
                .init(.eventWheel, .readWrite)
            ]
        case .deliverEvents:
            access = [
                .init(.phaseHeader, .read),
                .init(.eventWheel, .readWrite),
                .init(.shadowState, .readWrite),
                .init(.effectiveParameters, .read),
                .init(.runtimeCounters, .readWrite)
            ]
        case .clearEventBucket:
            access = [
                .init(.phaseHeader, .read),
                .init(.eventWheel, .write)
            ]
        case .decaySynapses:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.effectiveParameters, .read)
            ]
        case .updateChannels:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.modelMetadata, .read),
                .init(.effectiveParameters, .read)
            ]
        case .assembleCableSystem,
             .eliminateCableLevels,
             .solveCableRoots,
             .backSubstituteCableLevels:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.structuralTopology, .read)
            ]
        case .detectSpikes:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.effectiveParameters, .read),
                .init(.outgoingEvents, .write),
                .init(.runtimeCounters, .readWrite)
            ]
        case .routeSpikes:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .read),
                .init(.outgoingEvents, .read),
                .init(.eventWheel, .readWrite),
                .init(.runtimeCounters, .readWrite)
            ]
        case .clearSpikeFlags:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .write)
            ]
        case .updateFastFields:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.effectiveParameters, .read)
            ]
        case .updateMolecularDomains:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.modelMetadata, .read),
                .init(.effectiveParameters, .read),
                .init(.runtimeCounters, .readWrite)
            ]
        case .updateGliaAndMetabolism,
             .updateMyelination,
             .updateMicroglialPruning,
             .applyPlasticity,
             .updateCellMechanics,
             .updateDevelopment,
             .updateStructuralPlasticity,
             .updateAdaptiveFidelity:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .readWrite),
                .init(.structuralTopology, .readWrite),
                .init(.modelMetadata, .read),
                .init(.effectiveParameters, .read),
                .init(.runtimeCounters, .readWrite),
                .init(.fidelityMigration, .readWrite)
            ]
        case .collectOutputs:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .read),
                .init(.eventWheel, .read),
                .init(.outputEvents, .write),
                .init(.outputScalars, .write),
                .init(.runtimeCounters, .readWrite)
            ]
        case .validateState:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .read),
                .init(.structuralTopology, .read),
                .init(.eventWheel, .read),
                .init(.validationRecords, .write),
                .init(.runtimeCounters, .readWrite)
            ]
        case .digestShadowState:
            access = [
                .init(.phaseHeader, .read),
                .init(.shadowState, .read),
                .init(.diagnosticDigest, .write)
            ]
        }
        return Metal4CommandAccess(
            label: kernel.rawValue,
            stage: .dispatch,
            accesses: access
        )
    }
}

public enum Metal4DispatchMode: String, Sendable, Hashable, Codable {
    case direct
    case indirect
}

/// Stable specialization key. It intentionally uses an explicit deterministic mixer instead of
/// Swift `Hasher`, whose seed is process-randomized.
public struct Metal4KernelSpecialization: Sendable, Hashable, Codable {
    public var topologyDepth: UInt32
    public var channelFamily: UInt32
    public var synapseModel: UInt32
    public var fieldStencil: UInt32
    public var molecularSolver: UInt32
    public var fidelityLevel: UInt32
    public var precisionClass: UInt32

    public init(
        topologyDepth: UInt32 = 0,
        channelFamily: UInt32 = 0,
        synapseModel: UInt32 = 0,
        fieldStencil: UInt32 = 0,
        molecularSolver: UInt32 = 0,
        fidelityLevel: UInt32 = 0,
        precisionClass: UInt32 = 0
    ) {
        self.topologyDepth = topologyDepth
        self.channelFamily = channelFamily
        self.synapseModel = synapseModel
        self.fieldStencil = fieldStencil
        self.molecularSolver = molecularSolver
        self.fidelityLevel = fidelityLevel
        self.precisionClass = precisionClass
    }

    public var stableHash: UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for word in [
            topologyDepth,
            channelFamily,
            synapseModel,
            fieldStencil,
            molecularSolver,
            fidelityLevel,
            precisionClass
        ] {
            value ^= UInt64(word)
            value &*= 0x0000_0100_0000_01B3
            value ^= value >> 32
        }
        return value
    }
}

public struct Metal4DispatchDecision: Sendable, Hashable, Codable {
    public var kernelName: String
    public var threadCount: Int
    public var mode: Metal4DispatchMode
    public var specialization: Metal4KernelSpecialization
    public var reason: String

    public init(
        kernelName: String,
        threadCount: Int,
        mode: Metal4DispatchMode,
        specialization: Metal4KernelSpecialization,
        reason: String
    ) {
        self.kernelName = kernelName
        self.threadCount = threadCount
        self.mode = mode
        self.specialization = specialization
        self.reason = reason
    }
}

public enum Metal4DispatchPlanner {
    public static func decide(
        kernel: MetalKernel,
        threadCount: Int,
        specialization: Metal4KernelSpecialization = .init(),
        configuration source: Metal4ExecutionConfiguration
    ) throws -> Metal4DispatchDecision {
        let configuration = try source.validated()
        guard threadCount >= 0 else {
            throw Metal4ContractError.negativeThreadCount(threadCount)
        }
        if threadCount == 0 {
            return Metal4DispatchDecision(
                kernelName: kernel.rawValue,
                threadCount: 0,
                mode: .direct,
                specialization: specialization,
                reason: "empty dispatch is omitted"
            )
        }

        let qualified = configuration.qualifiedIndirectKernelNames
            .contains(kernel.rawValue)
        switch configuration.indirectDispatchMode {
        case .disabled:
            return Metal4DispatchDecision(
                kernelName: kernel.rawValue,
                threadCount: threadCount,
                mode: .direct,
                specialization: specialization,
                reason: "indirect dispatch disabled"
            )
        case .qualifiedAutomatic:
            let useIndirect = qualified &&
                threadCount >= configuration.indirectDispatchMinimumThreadCount
            return Metal4DispatchDecision(
                kernelName: kernel.rawValue,
                threadCount: threadCount,
                mode: useIndirect ? .indirect : .direct,
                specialization: specialization,
                reason: useIndirect
                    ? "kernel and workload size are benchmark-qualified"
                    : "direct dispatch retained until measured qualification"
            )
        case .requireQualified:
            guard qualified else {
                throw Metal4ContractError.indirectKernelNotQualified(
                    kernel.rawValue
                )
            }
            guard threadCount >= configuration.indirectDispatchMinimumThreadCount else {
                throw Metal4ContractError.indirectWorkloadBelowQualifiedThreshold(
                    kernel: kernel.rawValue,
                    count: threadCount,
                    threshold: configuration.indirectDispatchMinimumThreadCount
                )
            }
            return Metal4DispatchDecision(
                kernelName: kernel.rawValue,
                threadCount: threadCount,
                mode: .indirect,
                specialization: specialization,
                reason: "qualified indirect dispatch required"
            )
        }
    }
}

public enum Metal4ContractError: Error, Sendable, CustomStringConvertible {
    case invalidCommandBufferPoolSize(Int)
    case invalidBindingCount(Int)
    case invalidDispatchGroupLimit(Int)
    case invalidIndirectThreshold(Int)
    case invalidQualifiedKernelNames
    case invalidPipelineArchivePath
    case negativeThreadCount(Int)
    case indirectKernelNotQualified(String)
    case indirectWorkloadBelowQualifiedThreshold(
        kernel: String,
        count: Int,
        threshold: Int
    )
    case barrierPlanCountMismatch(commands: Int, decisions: Int)
    case barrierPlanMismatch(
        index: Int,
        expected: Metal4BarrierDecision,
        actual: Metal4BarrierDecision
    )

    public var description: String {
        switch self {
        case .invalidCommandBufferPoolSize(let value):
            return "Metal 4 command-buffer pool size \(value) is outside 1...64"
        case .invalidBindingCount(let value):
            return "Metal 4 buffer-binding count \(value) is outside 1...256"
        case .invalidDispatchGroupLimit(let value):
            return "Metal 4 dispatch group limit \(value) is outside 1...1000000"
        case .invalidIndirectThreshold(let value):
            return "Metal 4 indirect-dispatch threshold must be positive, received \(value)"
        case .invalidQualifiedKernelNames:
            return "Metal 4 qualified indirect-kernel names must be unique and nonempty"
        case .invalidPipelineArchivePath:
            return "Metal 4 pipeline archive path is invalid"
        case .negativeThreadCount(let value):
            return "Metal 4 dispatch thread count cannot be negative: \(value)"
        case .indirectKernelNotQualified(let kernel):
            return "Metal 4 indirect dispatch is not qualified for \(kernel)"
        case .indirectWorkloadBelowQualifiedThreshold(
            let kernel,
            let count,
            let threshold
        ):
            return "Metal 4 indirect dispatch for \(kernel) has \(count) threads, below qualified threshold \(threshold)"
        case .barrierPlanCountMismatch(let commands, let decisions):
            return "Metal 4 barrier plan has \(decisions) decisions for \(commands) commands"
        case .barrierPlanMismatch(let index, let expected, let actual):
            return "Metal 4 barrier \(index) differs: expected \(expected), received \(actual)"
        }
    }
}
#endif
