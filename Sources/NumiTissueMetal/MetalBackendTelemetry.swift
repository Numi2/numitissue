#if canImport(Metal)
import Foundation
import NumiTissueRuntime

extension MetalTissueBackend: RuntimeTelemetryProvidingBackend {
    public func telemetrySnapshot() async throws -> RuntimeBackendTelemetry {
        context.telemetry.snapshot(
            backendName: name,
            numericalProfile: numericalProfile,
            capabilities: context.capabilities,
            options: options
        )
    }

    public func resetTelemetry() {
        context.telemetry.reset()
    }
}
#endif
