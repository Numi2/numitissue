#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

struct MetalDigestCounts: Sendable {
    var regulatoryStateCount: UInt32
    var mechanismStateCount: UInt32
    var reserved0: UInt32
    var reserved1: UInt32

    init(state: TissueRuntimeState) {
        regulatoryStateCount = UInt32(clamping: state.regulatoryState.count)
        mechanismStateCount = UInt32(clamping: state.mechanismState.count)
        reserved0 = 0
        reserved1 = 0
    }
}

/// Small persistent buffers for diagnostic state hashing. Ten GPU threads each walk one canonical
/// state pool and return one four-lane digest. The CPU reads 320 bytes instead of the full arena.
final class MetalPhaseDigestBuffers: @unchecked Sendable {
    static let stateDomainCount = 10

    let context: MetalDeviceContext
    let output: MTLBuffer
    let counts: MTLBuffer

    init(context: MetalDeviceContext) throws {
        precondition(MemoryLayout<MetalDigestCounts>.stride == 16)
        precondition(MemoryLayout<SIMD4<UInt64>>.stride == 32)
        self.context = context
        output = try context.makeSharedBuffer(
            length: Self.stateDomainCount * MemoryLayout<SIMD4<UInt64>>.stride,
            label: "NumiTissue.differential.phaseDigests"
        )
        counts = try context.makeSharedBuffer(
            length: MemoryLayout<MetalDigestCounts>.stride,
            label: "NumiTissue.differential.digestCounts",
            writeCombined: true
        )
    }

    func encode(
        command: MTLCommandBuffer,
        library: MetalShaderLibrary,
        argumentTable: MetalArgumentTable,
        state: MetalStateBufferSet,
        transient: MetalTransientBuffers,
        stateTemplate: TissueRuntimeState
    ) throws {
        memset(output.contents(), 0, output.length)
        var value = MetalDigestCounts(state: stateTemplate)
        withUnsafeBytes(of: &value) { bytes in
            guard let base = bytes.baseAddress else { return }
            counts.contents().copyMemory(
                from: base,
                byteCount: bytes.count
            )
            context.telemetry.recordUpload(bytes: bytes.count)
        }

        guard let encoder = command.makeComputeCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed(
                MetalKernel.digestShadowState.rawValue
            )
        }
        encoder.label = "NumiTissue.\(MetalKernel.digestShadowState.rawValue)"
        encoder.setBuffer(argumentTable.buffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(counts, offset: 0, index: 2)
        encoder.useResource(output, usage: .write)
        encoder.useResource(counts, usage: .read)
        argumentTable.useResources(
            on: encoder,
            state: state,
            transient: transient
        )
        let pipeline = try library.pipeline(.digestShadowState)
        encoder.ntDispatch1D(
            count: Self.stateDomainCount,
            pipeline: pipeline
        )
        encoder.endEncoding()
        context.telemetry.recordComputeEncoder()
    }

    func read(
        metadata: RuntimeComparisonDigest,
        pendingEvents: RuntimeComparisonDigest
    ) -> RuntimePoolDigests {
        context.telemetry.recordReadback(bytes: output.length)
        let pointer = output.contents().bindMemory(
            to: SIMD4<UInt64>.self,
            capacity: Self.stateDomainCount
        )
        func digest(_ index: Int) -> RuntimeComparisonDigest {
            let value = pointer[index]
            return RuntimeComparisonDigest(
                lane0: value.x,
                lane1: value.y,
                lane2: value.z,
                lane3: value.w
            )
        }
        return RuntimePoolDigests(
            metadata: metadata,
            tiles: digest(0),
            cells: digest(1),
            regulatoryState: digest(2),
            segments: digest(3),
            compartments: digest(4),
            mechanismState: digest(5),
            synapses: digest(6),
            fields: digest(7),
            microdomains: digest(8),
            molecularSpecies: digest(9),
            pendingEvents: pendingEvents
        )
    }
}

public struct MetalStateDigestResult: Sendable, Codable {
    public var numericalProfile: RuntimeNumericalProfile
    public var deviceName: String
    public var deviceRegistryID: UInt64
    public var stateCounts: RuntimeCapacity
    public var pendingEventCount: Int
    public var poolDigests: RuntimePoolDigests
    public var telemetry: RuntimeBackendTelemetry

    public init(
        numericalProfile: RuntimeNumericalProfile,
        deviceName: String,
        deviceRegistryID: UInt64,
        stateCounts: RuntimeCapacity,
        pendingEventCount: Int,
        poolDigests: RuntimePoolDigests,
        telemetry: RuntimeBackendTelemetry
    ) {
        self.numericalProfile = numericalProfile
        self.deviceName = deviceName
        self.deviceRegistryID = deviceRegistryID
        self.stateCounts = stateCounts
        self.pendingEventCount = pendingEventCount
        self.poolDigests = poolDigests
        self.telemetry = telemetry
    }
}

/// Standalone host/GPU digest validator. It deliberately owns an isolated arena so digest-kernel
/// validation cannot modify a production transaction or depend on backend-private state.
public actor MetalStateDigestEngine {
    public let context: MetalDeviceContext
    public let numericalProfile: RuntimeNumericalProfile

    private let library: MetalShaderLibrary
    private let digestBuffers: MetalPhaseDigestBuffers

    public init(
        device: MTLDevice? = nil,
        options sourceOptions: MetalExecutionOptions = MetalExecutionOptions(
            privateHeapBytes: 128 * 1_024 * 1_024,
            stagingBytes: 8 * 1_024 * 1_024,
            requestedNumericalProfile: .scientific32
        )
    ) async throws {
        var options = sourceOptions
        if options.requestedNumericalProfile == nil {
            options.requestedNumericalProfile = .scientific32
        }
        let context = try MetalDeviceContext(device: device, options: options)
        let library = try await MetalShaderLibrary(context: context)
        _ = try library.pipeline(.digestShadowState)
        self.context = context
        self.numericalProfile = options.effectiveNumericalProfile
        self.library = library
        self.digestBuffers = try MetalPhaseDigestBuffers(context: context)
    }

    public func digest(
        state sourceState: TissueRuntimeState,
        pendingEvents: [RuntimePendingEvent] = []
    ) async throws -> MetalStateDigestResult {
        var state = sourceState
        state.reserveCapacity(state.capacity)
        try state.validateCapacity()
        let arena = try MetalStateArena(context: context, initialState: state)
        try await arena.uploadInitialState(state)
        let argumentTable = try MetalArgumentTable(
            context: context,
            shaderLibrary: library,
            state: arena.shadow,
            transient: arena.transient,
            label: "NumiTissue.differential.standalone.arguments"
        )
        let execution = ExecutionContext(
            transaction: TransactionID(rawValue: 0),
            epoch: state.epoch,
            startTime: state.time,
            randomSeed: 0,
            cadence: RuntimeCadence()
        )
        arena.updateHeader(MetalSimulationHeader(
            state: state,
            context: execution,
            phase: .validate,
            phaseRange: state.time.tick..<state.time.tick
        ))

        let before = context.telemetry.snapshot(
            backendName: "NumiTissue Metal State Digest",
            numericalProfile: numericalProfile,
            capabilities: context.capabilities,
            options: context.options
        )
        let command = try context.makeCommandBuffer(
            label: "NumiTissue.differential.standalone"
        )
        try digestBuffers.encode(
            command: command,
            library: library,
            argumentTable: argumentTable,
            state: arena.shadow,
            transient: arena.transient,
            stateTemplate: state
        )
        try await context.awaitCompletion(MetalCommandBufferHandle(command))
        let poolDigests = digestBuffers.read(
            metadata: RuntimeStateDigestBuilder.metadataDigest(state: state),
            pendingEvents: RuntimeStateDigestBuilder.pendingEventsDigest(
                pendingEvents
            )
        )
        let after = context.telemetry.snapshot(
            backendName: "NumiTissue Metal State Digest",
            numericalProfile: numericalProfile,
            capabilities: context.capabilities,
            options: context.options
        )
        return MetalStateDigestResult(
            numericalProfile: numericalProfile,
            deviceName: context.capabilities.name,
            deviceRegistryID: context.capabilities.registryID,
            stateCounts: state.counts,
            pendingEventCount: pendingEvents.count,
            poolDigests: poolDigests,
            telemetry: after.delta(from: before)
        )
    }
}
#endif
