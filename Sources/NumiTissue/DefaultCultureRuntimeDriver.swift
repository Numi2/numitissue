import Foundation
import NumiTissueModels
import NumiTissueRuntime
import NumiTissueIntegration
import NumiTissueIO

public struct CultureRuntimeContinuation: Sendable, Codable {
    public var schemaVersion: UInt32
    public var modelHash: String
    public var state: TissueRuntimeState
    public var backendIdentifier: String?
    public var backendCheckpoint: Data?
    public var metadata: [String: String]

    public init(modelHash: String, state: TissueRuntimeState,
                backendIdentifier: String?, backendCheckpoint: Data?,
                metadata: [String: String] = [:]) {
        self.schemaVersion = 1; self.modelHash = modelHash; self.state = state
        self.backendIdentifier = backendIdentifier; self.backendCheckpoint = backendCheckpoint
        self.metadata = metadata
    }

    public func validated(maximumCheckpointBytes: Int = 512 * 1_024 * 1_024) throws -> Self {
        guard schemaVersion == 1, !modelHash.isEmpty,
              backendIdentifier?.isEmpty != true,
              backendCheckpoint.map({ !$0.isEmpty && $0.count <= maximumCheckpointBytes }) ?? true,
              (backendIdentifier == nil) == (backendCheckpoint == nil),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw CultureTwinError.invalid("culture runtime continuation")
        }
        try state.validateCapacity()
        return self
    }

    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(validated())
    }

    public static func decode(_ data: Data,
                              maximumBytes: Int = 1_024 * 1_024 * 1_024) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw CultureTwinError.invalid("culture continuation size")
        }
        return try PropertyListDecoder().decode(Self.self, from: data).validated()
    }
}

public typealias CultureParameterizedModelFactory = @Sendable (
    _ parameters: [String: Double]
) throws -> CompiledTissueModel

public typealias CultureInitialStateFactory = @Sendable (
    _ model: CompiledTissueModel,
    _ parameters: [String: Double],
    _ request: CultureForecastRequest
) throws -> TissueRuntimeState

public typealias CultureExecutionBackendFactory = @Sendable () throws -> any NumiTissueExecutionBackend

public typealias CultureRuntimeInputFactory = @Sendable (
    _ request: CultureForecastRequest,
    _ startTime: TissueTime,
    _ cadence: RuntimeCadence
) throws -> RuntimeInputFrame

/// Concrete correctness-first runtime driver. Each forecast owns a fresh backend/runtime instance.
/// Sample times must lie exactly on the authoritative 25-us NumiTissue tick lattice. This avoids
/// interpolating electrical state on the host and makes the current observation path reproducible.
public struct DefaultCultureRuntimeDriver: CultureProductionRuntimeDriver, Sendable {
    public var modelFactory: CultureParameterizedModelFactory
    public var initialStateFactory: CultureInitialStateFactory
    public var backendFactory: CultureExecutionBackendFactory
    public var inputFactory: CultureRuntimeInputFactory
    public var randomSeedBase: UInt64
    public var maximumContinuationBytes: Int

    public init(
        modelFactory: @escaping CultureParameterizedModelFactory,
        initialStateFactory: @escaping CultureInitialStateFactory,
        backendFactory: @escaping CultureExecutionBackendFactory,
        inputFactory: @escaping CultureRuntimeInputFactory = { _, _, _ in RuntimeInputFrame() },
        randomSeedBase: UInt64 = 0x4355_4C54_5552_4536,
        maximumContinuationBytes: Int = 1_024 * 1_024 * 1_024
    ) {
        self.modelFactory = modelFactory
        self.initialStateFactory = initialStateFactory
        self.backendFactory = backendFactory
        self.inputFactory = inputFactory
        self.randomSeedBase = randomSeedBase
        self.maximumContinuationBytes = maximumContinuationBytes
    }

    public func simulate(
        memberID: UInt64,
        parameters: [String: Double],
        priorOpaqueState: Data?,
        request: CultureForecastRequest,
        sampleRateHertz: Double,
        maximumFrames: Int
    ) async throws -> CultureRuntimeSimulationTrace {
        try Task.checkCancellation()
        guard sampleRateHertz.isFinite, sampleRateHertz > 0,
              sampleRateHertz <= 40_000,
              maximumFrames >= 3, maximumFrames <= 10_000_000,
              parameters.values.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("runtime driver sampling or parameters")
        }
        let ticksPerSampleExact = 40_000.0 / sampleRateHertz
        let ticksPerSample = UInt64(ticksPerSampleExact.rounded())
        guard ticksPerSample > 0,
              abs(Double(ticksPerSample) - ticksPerSampleExact) <= 1e-9 else {
            throw CultureTwinError.invalid("sample rate is not aligned to 25-us runtime ticks")
        }
        let cadence = RuntimeCadence(
            transactionTicks: ticksPerSample,
            routingBlockTicks: ticksPerSample,
            fastQuantumTicks: 1
        )
        let model = try modelFactory(parameters)
        let continuation: CultureRuntimeContinuation?
        if let priorOpaqueState {
            continuation = try CultureRuntimeContinuation.decode(
                priorOpaqueState,
                maximumBytes: maximumContinuationBytes
            )
        } else {
            continuation = nil
        }
        var state: TissueRuntimeState
        if let continuation {
            guard continuation.modelHash == model.manifest.modelHash else {
                throw CultureTwinError.invalid("continuation model hash mismatch")
            }
            state = continuation.state
        } else {
            state = try initialStateFactory(model, parameters, request)
        }
        guard state.time.tick <= request.session.simulationTick else {
            throw CultureTwinError.invalid("simulation target precedes continuation")
        }
        let delta = request.session.simulationTick - state.time.tick
        guard delta > 0, delta.isMultiple(of: ticksPerSample) else {
            throw CultureTwinError.invalid("session tick is not aligned to recording cadence")
        }
        let requiredFrames = Int(delta / ticksPerSample)
        guard requiredFrames >= 3, requiredFrames <= maximumFrames else {
            throw CultureTwinError.invalid("runtime trace exceeds recording frame bound")
        }

        let backend = try backendFactory()
        let runtime = NumiTissueRuntime(
            model: model,
            backend: backend,
            cadence: cadence,
            randomSeed: randomSeedBase ^ memberID
        )
        try await runtime.load(initialState: state)
        if let continuation,
           let data = continuation.backendCheckpoint {
            guard let checkpointProvider = backend as? any RuntimeBackendCheckpointStateProvider,
                  continuation.backendIdentifier == checkpointProvider.checkpointBackendIdentifier else {
                throw CultureTwinError.invalid("backend cannot restore continuation checkpoint")
            }
            try await checkpointProvider.validateBackendCheckpointState(data, committedState: state)
            try await checkpointProvider.restoreBackendCheckpointState(data)
        } else if continuation?.backendIdentifier != nil {
            throw CultureTwinError.invalid("continuation checkpoint is incomplete")
        }

        var frames: [CultureRuntimeObservationFrame] = []
        frames.reserveCapacity(requiredFrames)
        for sampleIndex in 0..<requiredFrames {
            try Task.checkCancellation()
            let start = await runtime.currentTime()
            let input = try inputFactory(request, start, cadence)
            let result = try await runtime.step(input: input)
            guard result.status == .committed || result.status == .committedWithPromotion else {
                throw CultureTwinError.invalid("runtime culture sample transaction was not committed")
            }
            state = try await runtime.snapshot()
            frames.append(CultureRuntimeObservationFrame(
                sampleIndex: sampleIndex,
                timeSeconds: Double(state.time.tick) * 25e-6,
                dtMilliseconds: Double(ticksPerSample) * 0.025,
                state: state
            ))
        }
        guard state.time.tick == request.session.simulationTick else {
            throw CultureTwinError.invalid("runtime stopped at wrong session tick")
        }

        let backendIdentifier: String?
        let backendCheckpoint: Data?
        if let checkpointProvider = backend as? any RuntimeBackendCheckpointStateProvider {
            backendIdentifier = checkpointProvider.checkpointBackendIdentifier
            backendCheckpoint = try await checkpointProvider.exportBackendCheckpointState()
        } else {
            backendIdentifier = nil
            backendCheckpoint = nil
        }
        let finalContinuation = CultureRuntimeContinuation(
            modelHash: model.manifest.modelHash,
            state: state,
            backendIdentifier: backendIdentifier,
            backendCheckpoint: backendCheckpoint,
            metadata: [
                "member": String(memberID),
                "culture-session": request.session.id,
                "sampling-ticks": String(ticksPerSample)
            ]
        )
        let finalData = try finalContinuation.encoded()
        guard finalData.count <= maximumContinuationBytes else {
            throw CultureTwinError.invalid("encoded continuation exceeds configured bound")
        }
        return try CultureRuntimeSimulationTrace(
            frames: frames,
            finalOpaqueState: finalData,
            topologyRevision: state.epoch,
            metadata: [
                "backend": backend.name,
                "sample-rate-hz": String(sampleRateHertz),
                "tick-aligned": "true"
            ]
        ).validated(maximumFrames: maximumFrames)
    }
}
