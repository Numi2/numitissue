import Foundation
import NumiTissueRuntime

extension CPUReferenceTissueBackend: RuntimeTelemetryProvidingBackend {
    public func telemetrySnapshot() async throws -> RuntimeBackendTelemetry {
        let state = try await exportCommittedState()
        let footprint = RuntimeStateFootprintEstimator.estimate(state)
        return RuntimeBackendTelemetry(
            backendName: name,
            numericalProfile: numericalProfile,
            allocatedSharedBytes: footprint.reservedStateBytes,
            metadata: [
                "device": "host-cpu",
                "state.activeBytes": String(footprint.activeStateBytes),
                "state.reservedBytes": String(footprint.reservedStateBytes),
                "energy.measurement": "not-provided",
                "hardwareCounters": "not-provided"
            ]
        )
    }
}
