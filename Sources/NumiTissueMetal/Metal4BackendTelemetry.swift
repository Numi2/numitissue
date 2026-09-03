#if canImport(Metal) && compiler(>=6.2)
import Foundation
import NumiTissueRuntime

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
extension Metal4TissueBackend: RuntimeTelemetryProvidingBackend {
    public func telemetrySnapshot() async throws -> RuntimeBackendTelemetry {
        let classic = context.telemetry.snapshot(
            backendName: name,
            numericalProfile: options.effectiveNumericalProfile,
            capabilities: context.capabilities,
            options: options
        )
        let unified = metal4Context.telemetry.snapshot()
        let gpuSeconds: Double?
        switch (classic.accumulatedGPUSeconds, unified.accumulatedGPUSeconds) {
        case (.none, .none):
            gpuSeconds = nil
        case (.some(let lhs), .none):
            gpuSeconds = lhs
        case (.none, .some(let rhs)):
            gpuSeconds = rhs
        case (.some(let lhs), .some(let rhs)):
            gpuSeconds = lhs + rhs
        }

        var counters = classic.hardwareCounters
        counters["metal4.commandBufferCommits"] = Double(
            unified.commandBufferCommits
        )
        counters["metal4.unifiedComputeEncoders"] = Double(
            unified.unifiedComputeEncoders
        )
        counters["metal4.barriers"] = Double(unified.barriers)
        counters["metal4.blitCommands"] = Double(unified.blitCommands)
        counters["metal4.dispatches"] = Double(unified.dispatches)
        counters["metal4.directDispatches"] = Double(
            lastEncodingStatistics.directDispatchCount
        )
        counters["metal4.indirectDispatches"] = Double(
            lastEncodingStatistics.indirectDispatchCount
        )
        if let residency = lastStableResidencySnapshot {
            counters["metal4.stableResidencyBytes"] = Double(
                residency.allocatedSize
            )
            counters["metal4.stableResidencyAllocations"] = Double(
                residency.allocationCount
            )
        }

        var metadata = classic.metadata
        metadata["metal.api"] = "4"
        metadata["metal4.requirement"] = metal4Configuration.requirement.rawValue
        metadata["metal4.batchingMode"] = metal4Configuration.batchingMode.rawValue
        metadata["metal4.indirectPolicy"] = metal4Configuration.indirectDispatchPolicy.rawValue
        metadata["metal4.pipelineArchive"] = metal4Configuration.pipelineArchivePath ?? "none"
        metadata["metal4.commandSlots"] = String(
            metal4Configuration.commandBufferSlotCount
        )
        metadata["metal4.cachedArgumentTables"] = String(
            argumentTableCache.cachedTableCount
        )
        metadata["metal4.supportReasons"] = supportReport.reasons.joined(
            separator: ";"
        )
        metadata["metal4.qualification"] = qualificationReport?.promotionApproved == true
            ? "approved"
            : "not-supplied"
        metadata["metal4.last.commands"] = String(
            lastEncodingStatistics.commandCount
        )
        metadata["metal4.last.dispatches"] = String(
            lastEncodingStatistics.dispatchCount
        )
        metadata["metal4.last.blits"] = String(
            lastEncodingStatistics.blitCount
        )
        metadata["metal4.last.barriers"] = String(
            lastEncodingStatistics.barrierCount
        )

        return RuntimeBackendTelemetry(
            backendName: name,
            numericalProfile: options.effectiveNumericalProfile,
            deviceName: context.capabilities.name,
            deviceRegistryID: context.capabilities.registryID,
            unifiedMemory: context.capabilities.unifiedMemory,
            allocatedPrivateBytes: classic.allocatedPrivateBytes,
            allocatedSharedBytes: classic.allocatedSharedBytes,
            hostToDeviceBytes: classic.hostToDeviceBytes,
            deviceToHostBytes: classic.deviceToHostBytes,
            computeCommandBuffers: classic.computeCommandBuffers &+
                unified.commandBufferCommits,
            transferCommandBuffers: classic.transferCommandBuffers,
            computeEncoders: classic.computeEncoders &+
                unified.unifiedComputeEncoders,
            blitEncoders: classic.blitEncoders,
            dispatches: classic.dispatches &+ unified.dispatches,
            completedCommandBuffers: classic.completedCommandBuffers &+
                unified.completedCommandBuffers,
            failedCommandBuffers: classic.failedCommandBuffers &+
                unified.failedCommandBuffers,
            accumulatedGPUSeconds: gpuSeconds,
            energyJoules: nil,
            hardwareCounters: counters,
            metadata: metadata
        )
    }
}
#endif
