import Foundation
import NumiTissueCore
import NumiTissueModels

public struct RuntimeStateFootprint: Sendable, Hashable, Codable {
    public var activeStateBytes: UInt64
    public var reservedStateBytes: UInt64
    public var bytesPerCell: Double?
    public var bytesPerCompartment: Double?
    public var bytesPerSynapse: Double?
    public var poolBytes: [RuntimeComparisonDomain: UInt64]

    public init(
        activeStateBytes: UInt64,
        reservedStateBytes: UInt64,
        bytesPerCell: Double?,
        bytesPerCompartment: Double?,
        bytesPerSynapse: Double?,
        poolBytes: [RuntimeComparisonDomain: UInt64]
    ) {
        self.activeStateBytes = activeStateBytes
        self.reservedStateBytes = reservedStateBytes
        self.bytesPerCell = bytesPerCell
        self.bytesPerCompartment = bytesPerCompartment
        self.bytesPerSynapse = bytesPerSynapse
        self.poolBytes = poolBytes
    }
}

public enum RuntimeStateFootprintEstimator {
    public static func estimate(_ state: TissueRuntimeState) -> RuntimeStateFootprint {
        let active: [RuntimeComparisonDomain: UInt64] = [
            .tiles: bytes(state.tiles.count, MemoryLayout<TileRuntimeState>.stride),
            .cells: bytes(state.cells.count, MemoryLayout<RuntimeCellState>.stride),
            .regulatoryState: bytes(state.regulatoryState.count, MemoryLayout<Float>.stride),
            .segments: bytes(state.segments.count, MemoryLayout<RuntimeSegmentState>.stride),
            .compartments: bytes(state.compartments.count, MemoryLayout<RuntimeCompartmentState>.stride),
            .mechanismState: bytes(state.mechanismState.count, MemoryLayout<Float>.stride),
            .synapses: bytes(state.synapses.count, MemoryLayout<RuntimeSynapseState>.stride),
            .fields: bytes(state.fields.count, MemoryLayout<RuntimeFieldValue>.stride),
            .microdomains: bytes(state.microdomains.count, MemoryLayout<RuntimeMicrodomainState>.stride),
            .molecularSpecies: bytes(state.molecularSpecies.count, MemoryLayout<Float>.stride),
            .pendingEvents: bytes(state.capacity.events, MemoryLayout<RoutedEvent>.stride)
        ]
        let activeBytes = active.values.reduce(0, +)
        let regulatoryCapacity = max(state.regulatoryState.count, state.capacity.cells * 32)
        let mechanismCapacity = max(state.mechanismState.count, state.capacity.compartments * 16)
        let reserved =
            bytes(state.capacity.tiles, MemoryLayout<TileRuntimeState>.stride) +
            bytes(state.capacity.cells, MemoryLayout<RuntimeCellState>.stride) +
            bytes(regulatoryCapacity, MemoryLayout<Float>.stride) +
            bytes(state.capacity.segments, MemoryLayout<RuntimeSegmentState>.stride) +
            bytes(state.capacity.compartments, MemoryLayout<RuntimeCompartmentState>.stride) +
            bytes(mechanismCapacity, MemoryLayout<Float>.stride) +
            bytes(state.capacity.synapses, MemoryLayout<RuntimeSynapseState>.stride) +
            bytes(state.capacity.fieldValues, MemoryLayout<RuntimeFieldValue>.stride) +
            bytes(state.capacity.microdomains, MemoryLayout<RuntimeMicrodomainState>.stride) +
            bytes(state.capacity.molecularSpecies, MemoryLayout<Float>.stride) +
            bytes(state.capacity.events, MemoryLayout<RoutedEvent>.stride)
        return RuntimeStateFootprint(
            activeStateBytes: activeBytes,
            reservedStateBytes: reserved,
            bytesPerCell: ratio(activeBytes, state.cells.count),
            bytesPerCompartment: ratio(activeBytes, state.compartments.count),
            bytesPerSynapse: ratio(activeBytes, state.synapses.count),
            poolBytes: active
        )
    }

    private static func bytes(_ count: Int, _ stride: Int) -> UInt64 {
        guard count > 0, stride > 0 else { return 0 }
        let product = count.multipliedReportingOverflow(by: stride)
        return product.overflow ? UInt64.max : UInt64(product.partialValue)
    }

    private static func ratio(_ bytes: UInt64, _ count: Int) -> Double? {
        count > 0 ? Double(bytes) / Double(count) : nil
    }
}

public struct RuntimeBackendTelemetry: Sendable, Hashable, Codable {
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var deviceName: String?
    public var deviceRegistryID: UInt64?
    public var unifiedMemory: Bool?
    public var allocatedPrivateBytes: UInt64
    public var allocatedSharedBytes: UInt64
    public var hostToDeviceBytes: UInt64
    public var deviceToHostBytes: UInt64
    public var computeCommandBuffers: UInt64
    public var transferCommandBuffers: UInt64
    public var computeEncoders: UInt64
    public var blitEncoders: UInt64
    public var dispatches: UInt64
    public var completedCommandBuffers: UInt64
    public var failedCommandBuffers: UInt64
    public var accumulatedGPUSeconds: Double?
    public var energyJoules: Double?
    public var hardwareCounters: [String: Double]
    public var metadata: [String: String]

    public init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        deviceName: String? = nil,
        deviceRegistryID: UInt64? = nil,
        unifiedMemory: Bool? = nil,
        allocatedPrivateBytes: UInt64 = 0,
        allocatedSharedBytes: UInt64 = 0,
        hostToDeviceBytes: UInt64 = 0,
        deviceToHostBytes: UInt64 = 0,
        computeCommandBuffers: UInt64 = 0,
        transferCommandBuffers: UInt64 = 0,
        computeEncoders: UInt64 = 0,
        blitEncoders: UInt64 = 0,
        dispatches: UInt64 = 0,
        completedCommandBuffers: UInt64 = 0,
        failedCommandBuffers: UInt64 = 0,
        accumulatedGPUSeconds: Double? = nil,
        energyJoules: Double? = nil,
        hardwareCounters: [String: Double] = [:],
        metadata: [String: String] = [:]
    ) {
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.deviceName = deviceName
        self.deviceRegistryID = deviceRegistryID
        self.unifiedMemory = unifiedMemory
        self.allocatedPrivateBytes = allocatedPrivateBytes
        self.allocatedSharedBytes = allocatedSharedBytes
        self.hostToDeviceBytes = hostToDeviceBytes
        self.deviceToHostBytes = deviceToHostBytes
        self.computeCommandBuffers = computeCommandBuffers
        self.transferCommandBuffers = transferCommandBuffers
        self.computeEncoders = computeEncoders
        self.blitEncoders = blitEncoders
        self.dispatches = dispatches
        self.completedCommandBuffers = completedCommandBuffers
        self.failedCommandBuffers = failedCommandBuffers
        self.accumulatedGPUSeconds = accumulatedGPUSeconds
        self.energyJoules = energyJoules
        self.hardwareCounters = hardwareCounters
        self.metadata = metadata
    }

    public func delta(from baseline: Self) -> Self {
        Self(
            backendName: backendName,
            numericalProfile: numericalProfile,
            deviceName: deviceName,
            deviceRegistryID: deviceRegistryID,
            unifiedMemory: unifiedMemory,
            allocatedPrivateBytes: subtract(allocatedPrivateBytes, baseline.allocatedPrivateBytes),
            allocatedSharedBytes: subtract(allocatedSharedBytes, baseline.allocatedSharedBytes),
            hostToDeviceBytes: subtract(hostToDeviceBytes, baseline.hostToDeviceBytes),
            deviceToHostBytes: subtract(deviceToHostBytes, baseline.deviceToHostBytes),
            computeCommandBuffers: subtract(computeCommandBuffers, baseline.computeCommandBuffers),
            transferCommandBuffers: subtract(transferCommandBuffers, baseline.transferCommandBuffers),
            computeEncoders: subtract(computeEncoders, baseline.computeEncoders),
            blitEncoders: subtract(blitEncoders, baseline.blitEncoders),
            dispatches: subtract(dispatches, baseline.dispatches),
            completedCommandBuffers: subtract(completedCommandBuffers, baseline.completedCommandBuffers),
            failedCommandBuffers: subtract(failedCommandBuffers, baseline.failedCommandBuffers),
            accumulatedGPUSeconds: optionalDifference(accumulatedGPUSeconds, baseline.accumulatedGPUSeconds),
            energyJoules: optionalDifference(energyJoules, baseline.energyJoules),
            hardwareCounters: hardwareCounters.reduce(into: [:]) { result, item in
                result[item.key] = item.value - (baseline.hardwareCounters[item.key] ?? 0)
            },
            metadata: metadata
        )
    }

    private func subtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    private func optionalDifference(_ lhs: Double?, _ rhs: Double?) -> Double? {
        guard let lhs else { return nil }
        return lhs - (rhs ?? 0)
    }
}

public protocol RuntimeTelemetryProvidingBackend: NumiTissueExecutionBackend {
    func telemetrySnapshot() async throws -> RuntimeBackendTelemetry
}

public struct RuntimeBenchmarkConfiguration: Sendable, Hashable, Codable {
    public var warmupTransactions: Int
    public var measuredTransactions: Int
    public var randomSeed: UInt64
    public var stopOnValidationWarning: Bool
    public var captureFinalDigest: Bool

    public init(
        warmupTransactions: Int = 10,
        measuredTransactions: Int = 100,
        randomSeed: UInt64 = 0x4245_4E43_484D_4152,
        stopOnValidationWarning: Bool = false,
        captureFinalDigest: Bool = true
    ) {
        precondition(warmupTransactions >= 0)
        precondition(measuredTransactions > 0)
        self.warmupTransactions = warmupTransactions
        self.measuredTransactions = measuredTransactions
        self.randomSeed = randomSeed
        self.stopOnValidationWarning = stopOnValidationWarning
        self.captureFinalDigest = captureFinalDigest
    }
}

public struct RuntimeBenchmarkSample: Sendable, Hashable, Codable {
    public var ordinal: Int
    public var transaction: TransactionID
    public var startTick: UInt64
    public var endTick: UInt64
    public var wallNanoseconds: UInt64
    public var counters: RuntimeCounters
    public var validationIssueCount: Int

    public init(
        ordinal: Int,
        transaction: TransactionID,
        startTick: UInt64,
        endTick: UInt64,
        wallNanoseconds: UInt64,
        counters: RuntimeCounters,
        validationIssueCount: Int
    ) {
        self.ordinal = ordinal
        self.transaction = transaction
        self.startTick = startTick
        self.endTick = endTick
        self.wallNanoseconds = wallNanoseconds
        self.counters = counters
        self.validationIssueCount = validationIssueCount
    }
}

public struct RuntimeBenchmarkStatistics: Sendable, Hashable, Codable {
    public var minimumNanoseconds: UInt64
    public var medianNanoseconds: UInt64
    public var p95Nanoseconds: UInt64
    public var p99Nanoseconds: UInt64
    public var maximumNanoseconds: UInt64
    public var meanNanoseconds: Double
    public var standardDeviationNanoseconds: Double

    public init(samples: [UInt64]) {
        precondition(!samples.isEmpty)
        let ordered = samples.sorted()
        minimumNanoseconds = ordered[0]
        medianNanoseconds = Self.percentile(ordered, probability: 0.50)
        p95Nanoseconds = Self.percentile(ordered, probability: 0.95)
        p99Nanoseconds = Self.percentile(ordered, probability: 0.99)
        maximumNanoseconds = ordered[ordered.count - 1]
        meanNanoseconds = ordered.reduce(0) { $0 + Double($1) } / Double(ordered.count)
        if ordered.count > 1 {
            standardDeviationNanoseconds = sqrt(ordered.reduce(0) {
                let delta = Double($1) - meanNanoseconds
                return $0 + delta * delta
            } / Double(ordered.count - 1))
        } else {
            standardDeviationNanoseconds = 0
        }
    }

    private static func percentile(_ ordered: [UInt64], probability: Double) -> UInt64 {
        let rank = Int(ceil(probability * Double(ordered.count))) - 1
        return ordered[min(max(rank, 0), ordered.count - 1)]
    }
}

public struct RuntimeBenchmarkReport: Sendable, Codable {
    public var schemaVersion: UInt32
    public var generatedAt: Date
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var configuration: RuntimeBenchmarkConfiguration
    public var samples: [RuntimeBenchmarkSample]
    public var statistics: RuntimeBenchmarkStatistics
    public var simulatedMilliseconds: Double
    public var wallSeconds: Double
    public var simulatedMillisecondsPerWallSecond: Double
    public var footprint: RuntimeStateFootprint
    public var telemetry: RuntimeBackendTelemetry?
    public var finalStateDigest: RuntimeComparisonDigest?
    public var metadata: [String: String]

    public init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        configuration: RuntimeBenchmarkConfiguration,
        samples: [RuntimeBenchmarkSample],
        statistics: RuntimeBenchmarkStatistics,
        simulatedMilliseconds: Double,
        wallSeconds: Double,
        footprint: RuntimeStateFootprint,
        telemetry: RuntimeBackendTelemetry?,
        finalStateDigest: RuntimeComparisonDigest?,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = 1
        self.generatedAt = Date()
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.configuration = configuration
        self.samples = samples
        self.statistics = statistics
        self.simulatedMilliseconds = simulatedMilliseconds
        self.wallSeconds = wallSeconds
        self.simulatedMillisecondsPerWallSecond = wallSeconds > 0
            ? simulatedMilliseconds / wallSeconds
            : 0
        self.footprint = footprint
        self.telemetry = telemetry
        self.finalStateDigest = finalStateDigest
        self.metadata = metadata
    }
}

public typealias RuntimeBenchmarkBackendFactory = @Sendable () async throws -> any RuntimePhaseInspectableBackend
public typealias RuntimeBenchmarkInputProvider = @Sendable (_ ordinal: Int, _ time: TissueTime) async throws -> RuntimeInputFrame

/// Reproducible single-backend benchmark. It performs no backend substitution and records the
/// numerical profile, exact transaction cadence, validation outcome, final state identity and any
/// backend-provided telemetry. Energy remains nil unless measured by a real provider.
public actor RuntimeBenchmarkRunner {
    public let backendFactory: RuntimeBenchmarkBackendFactory
    public let model: CompiledTissueModel
    public let initialState: TissueRuntimeState
    public let phasePlanner: RuntimePhasePlanner
    public let configuration: RuntimeBenchmarkConfiguration

    public init(
        backendFactory: @escaping RuntimeBenchmarkBackendFactory,
        model: CompiledTissueModel,
        initialState: TissueRuntimeState,
        phasePlanner: RuntimePhasePlanner = RuntimePhasePlanner(),
        configuration: RuntimeBenchmarkConfiguration = RuntimeBenchmarkConfiguration()
    ) {
        self.backendFactory = backendFactory
        self.model = model
        self.initialState = initialState
        self.phasePlanner = phasePlanner
        self.configuration = configuration
    }

    public func run(
        input: @escaping RuntimeBenchmarkInputProvider = { _, _ in RuntimeInputFrame() },
        metadata: [String: String] = [:]
    ) async throws -> RuntimeBenchmarkReport {
        try initialState.validateCapacity()
        let backend = try await backendFactory()
        try await backend.load(model: model, initialState: initialState)
        let telemetryProvider = backend as? any RuntimeTelemetryProvidingBackend
        let telemetryBefore = try await telemetryProvider?.telemetrySnapshot()

        var time = initialState.time
        var epoch = initialState.epoch
        var transactionRaw: UInt64 = 1
        let total = configuration.warmupTransactions + configuration.measuredTransactions
        var samples: [RuntimeBenchmarkSample] = []
        samples.reserveCapacity(configuration.measuredTransactions)

        for ordinal in 0..<total {
            let context = phasePlanner.context(
                startTime: time,
                epoch: epoch,
                transaction: TransactionID(rawValue: transactionRaw),
                randomSeed: transactionSeed(ordinal)
            )
            transactionRaw &+= 1
            let frame = try await input(ordinal, time)
            let start = ContinuousClock.now
            try await backend.beginShadowStep(context: context, input: frame)
            do {
                for scheduled in phasePlanner.plan(startTick: time.tick) {
                    try await backend.execute(
                        phase: scheduled.phase,
                        tickRange: scheduled.tickRange,
                        context: context
                    )
                }
                _ = try await backend.collectOutput(context: context)
                let issues = try await backend.validateShadow(context: context)
                if issues.contains(where: { $0.severity == .reject }) ||
                    (configuration.stopOnValidationWarning && !issues.isEmpty) {
                    await backend.rollbackShadow(context: context)
                    throw RuntimeBenchmarkError.validationRejected(
                        backend: backend.name,
                        transaction: context.transaction,
                        issues: issues
                    )
                }
                try await backend.commitShadow(context: context)
                let duration = Self.nanoseconds(start.duration(to: .now))
                if ordinal >= configuration.warmupTransactions {
                    samples.append(RuntimeBenchmarkSample(
                        ordinal: ordinal - configuration.warmupTransactions,
                        transaction: context.transaction,
                        startTick: context.startTime.tick,
                        endTick: context.endTime.tick,
                        wallNanoseconds: duration,
                        counters: await backend.counters(context: context),
                        validationIssueCount: issues.count
                    ))
                }
                time = context.endTime
                epoch &+= 1
            } catch {
                await backend.rollbackShadow(context: context)
                throw error
            }
        }

        guard !samples.isEmpty else { throw RuntimeBenchmarkError.noSamples }
        let finalState = try await backend.exportCommittedState()
        let telemetryAfter = try await telemetryProvider?.telemetrySnapshot()
        let telemetry = telemetryAfter.flatMap { after in
            telemetryBefore.map { after.delta(from: $0) } ?? after
        }
        let wallNanoseconds = samples.reduce(UInt64(0)) { partial, sample in
            let value = partial.addingReportingOverflow(sample.wallNanoseconds)
            return value.overflow ? UInt64.max : value.partialValue
        }
        let simulatedTicks = samples.reduce(UInt64(0)) { partial, sample in
            partial &+ (sample.endTick &- sample.startTick)
        }
        let simulatedMilliseconds = Double(simulatedTicks) * Double(TissueTime.quantumMicroseconds) / 1_000
        let finalDigest = configuration.captureFinalDigest
            ? RuntimeStateDigestBuilder.make(state: finalState).combined
            : nil

        return RuntimeBenchmarkReport(
            backendName: backend.name,
            numericalProfile: backend.numericalProfile,
            configuration: configuration,
            samples: samples,
            statistics: RuntimeBenchmarkStatistics(samples: samples.map(\.wallNanoseconds)),
            simulatedMilliseconds: simulatedMilliseconds,
            wallSeconds: Double(wallNanoseconds) / 1_000_000_000,
            footprint: RuntimeStateFootprintEstimator.estimate(finalState),
            telemetry: telemetry,
            finalStateDigest: finalDigest,
            metadata: metadata
        )
    }

    private func transactionSeed(_ ordinal: Int) -> UInt64 {
        var value = configuration.randomSeed &+ UInt64(ordinal) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = components.seconds >= 0 ? UInt64(components.seconds) : 0
        let attoseconds = components.attoseconds >= 0 ? UInt64(components.attoseconds) : 0
        let secondsPart = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let nanosPart = attoseconds / 1_000_000_000
        guard !secondsPart.overflow else { return UInt64.max }
        let total = secondsPart.partialValue.addingReportingOverflow(nanosPart)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

public enum RuntimeBenchmarkError: Error, Sendable, CustomStringConvertible {
    case noSamples
    case validationRejected(
        backend: String,
        transaction: TransactionID,
        issues: [RuntimeValidationIssue]
    )

    public var description: String {
        switch self {
        case .noSamples:
            return "Runtime benchmark produced no measured samples"
        case .validationRejected(let backend, let transaction, let issues):
            return "Runtime benchmark backend \(backend) rejected transaction \(transaction) with \(issues.count) validation issue(s)"
        }
    }
}
