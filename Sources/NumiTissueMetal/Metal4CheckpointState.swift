#if canImport(Metal) && compiler(>=6.2)
import Foundation
import NumiTissueRuntime

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
private struct Metal4BackendCheckpointPayload: Sendable, Codable {
    var schemaVersion: UInt32
    var numericalProfile: RuntimeNumericalProfile
    var routingBlockTicks: UInt64
    var eventWheel: MetalEventWheelSnapshot
    var metal4Configuration: Metal4ExecutionConfiguration

    init(
        numericalProfile: RuntimeNumericalProfile,
        routingBlockTicks: UInt64,
        eventWheel: MetalEventWheelSnapshot,
        metal4Configuration: Metal4ExecutionConfiguration
    ) {
        schemaVersion = 1
        self.numericalProfile = numericalProfile
        self.routingBlockTicks = routingBlockTicks
        self.eventWheel = eventWheel
        self.metal4Configuration = metal4Configuration
    }

    func validated(committedState: TissueRuntimeState) throws -> Self {
        guard schemaVersion == 1 else {
            throw Metal4CheckpointError.unsupportedPayloadVersion(schemaVersion)
        }
        guard routingBlockTicks > 0 else {
            throw Metal4CheckpointError.invalidRoutingBlockTicks
        }
        guard eventWheel.routingBlockTicks == routingBlockTicks,
              eventWheel.minimumArrivalTick == committedState.time.tick else {
            throw Metal4CheckpointError.stateMismatch
        }
        _ = try eventWheel.validated()
        _ = try metal4Configuration.validatedForMetal4Backend()
        return self
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
extension Metal4TissueBackend: RuntimeBackendCheckpointStateProvider {
    nonisolated public var checkpointBackendIdentifier: String {
        "numitissue.metal4"
    }

    public func validateBackendCheckpointState(
        _ data: Data,
        committedState: TissueRuntimeState
    ) async throws {
        let payload = try RuntimeBackendCheckpointArchive.decode(
            Metal4BackendCheckpointPayload.self,
            from: data,
            expectedBackendIdentifier: checkpointBackendIdentifier,
            expectedPayloadVersion: 1
        )
        let valid = try payload.validated(committedState: committedState)
        guard valid.numericalProfile == options.effectiveNumericalProfile else {
            throw Metal4CheckpointError.numericalProfileMismatch(
                expected: options.effectiveNumericalProfile,
                actual: valid.numericalProfile
            )
        }
        guard valid.metal4Configuration.batchingMode ==
                metal4Configuration.batchingMode,
              valid.metal4Configuration.indirectDispatchMode ==
                metal4Configuration.indirectDispatchMode else {
            throw Metal4CheckpointError.executionConfigurationMismatch
        }
    }

    public func exportBackendCheckpointState() async throws -> Data {
        guard currentContext == nil,
              let arena else {
            if self.arena == nil { throw RuntimeExecutionError.notLoaded }
            throw RuntimeExecutionError.transactionInProgress
        }
        let routingTicks = checkpointRoutingBlockTicks ??
            RuntimeCadence.routingBlockTicks
        let state = try await arena.downloadCommittedState()
        let wheel = try await arena.exportPersistentEventWheel(
            state: state,
            routingBlockTicks: routingTicks,
            minimumArrivalTick: state.time.tick,
            wheel: arena.transient.committedEventWheel
        )
        return try RuntimeBackendCheckpointArchive.encode(
            backendIdentifier: checkpointBackendIdentifier,
            payloadVersion: 1,
            payload: Metal4BackendCheckpointPayload(
                numericalProfile: options.effectiveNumericalProfile,
                routingBlockTicks: routingTicks,
                eventWheel: wheel,
                metal4Configuration: metal4Configuration
            ),
            metadata: [
                "eventCount": String(wheel.events.count),
                "routingBlockTicks": String(routingTicks),
                "metalAPI": "4",
                "numericalProfile": options.effectiveNumericalProfile.rawValue
            ]
        )
    }

    public func restoreBackendCheckpointState(_ data: Data) async throws {
        guard currentContext == nil,
              let arena else {
            if self.arena == nil { throw RuntimeExecutionError.notLoaded }
            throw RuntimeExecutionError.transactionInProgress
        }
        let state = try await arena.downloadCommittedState()
        let payload = try RuntimeBackendCheckpointArchive.decode(
            Metal4BackendCheckpointPayload.self,
            from: data,
            expectedBackendIdentifier: checkpointBackendIdentifier,
            expectedPayloadVersion: 1
        )
        let valid = try payload.validated(committedState: state)
        guard valid.numericalProfile == options.effectiveNumericalProfile else {
            throw Metal4CheckpointError.numericalProfileMismatch(
                expected: options.effectiveNumericalProfile,
                actual: valid.numericalProfile
            )
        }
        try await arena.importPersistentEventWheel(
            valid.eventWheel,
            state: state
        )
        checkpointRoutingBlockTicks = valid.routingBlockTicks
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4CheckpointError: Error, Sendable, CustomStringConvertible {
    case unsupportedPayloadVersion(UInt32)
    case invalidRoutingBlockTicks
    case stateMismatch
    case numericalProfileMismatch(
        expected: RuntimeNumericalProfile,
        actual: RuntimeNumericalProfile
    )
    case executionConfigurationMismatch

    public var description: String {
        switch self {
        case .unsupportedPayloadVersion(let version):
            return "Unsupported Metal 4 checkpoint payload version \(version)"
        case .invalidRoutingBlockTicks:
            return "Metal 4 checkpoint routing cadence must be positive"
        case .stateMismatch:
            return "Metal 4 checkpoint event wheel does not match committed tissue time"
        case .numericalProfileMismatch(let expected, let actual):
            return "Metal 4 checkpoint profile \(actual.rawValue) does not match backend profile \(expected.rawValue)"
        case .executionConfigurationMismatch:
            return "Metal 4 checkpoint execution configuration is incompatible with this backend"
        }
    }
}
#endif
