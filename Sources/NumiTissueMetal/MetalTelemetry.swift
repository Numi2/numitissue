#if canImport(Metal)
import Foundation
import Metal
import NumiTissueRuntime

/// Thread-safe cumulative telemetry. Command-buffer completion handlers update this recorder
/// directly; no simulation actor hop is required and no estimate is reported as a measurement.
public final class MetalTelemetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var allocatedPrivateBytes: UInt64 = 0
    private var allocatedSharedBytes: UInt64 = 0
    private var hostToDeviceBytes: UInt64 = 0
    private var deviceToHostBytes: UInt64 = 0
    private var computeCommandBuffers: UInt64 = 0
    private var transferCommandBuffers: UInt64 = 0
    private var computeEncoders: UInt64 = 0
    private var blitEncoders: UInt64 = 0
    private var dispatches: UInt64 = 0
    private var completedCommandBuffers: UInt64 = 0
    private var failedCommandBuffers: UInt64 = 0
    private var accumulatedGPUSeconds: Double = 0
    private var timedCommandBuffers: UInt64 = 0
    private var hardwareCounters: [String: Double] = [:]

    public init() {}

    public func recordPrivateAllocation(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { allocatedPrivateBytes &+= UInt64(bytes) }
    }

    public func recordSharedAllocation(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { allocatedSharedBytes &+= UInt64(bytes) }
    }

    public func recordUpload(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { hostToDeviceBytes &+= UInt64(bytes) }
    }

    public func recordReadback(bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock { deviceToHostBytes &+= UInt64(bytes) }
    }

    public func recordComputeCommandBuffer() {
        lock.withLock { computeCommandBuffers &+= 1 }
    }

    public func recordTransferCommandBuffer() {
        lock.withLock { transferCommandBuffers &+= 1 }
    }

    public func recordComputeEncoder(dispatches count: Int = 1) {
        lock.withLock {
            computeEncoders &+= 1
            dispatches &+= UInt64(max(count, 0))
        }
    }

    public func recordBlitEncoder() {
        lock.withLock { blitEncoders &+= 1 }
    }

    public func recordCompletion(_ commandBuffer: MTLCommandBuffer) {
        let status = commandBuffer.status
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime
        lock.withLock {
            if status == .completed {
                completedCommandBuffers &+= 1
            } else {
                failedCommandBuffers &+= 1
            }
            if start.isFinite, end.isFinite, end >= start, end > 0 {
                accumulatedGPUSeconds += end - start
                timedCommandBuffers &+= 1
            }
        }
    }

    /// External counter-sampling code can merge named values without changing the benchmark ABI.
    public func addHardwareCounter(name: String, value: Double) {
        guard !name.isEmpty, value.isFinite else { return }
        lock.withLock { hardwareCounters[name, default: 0] += value }
    }

    public func snapshot(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        capabilities: MetalDeviceCapabilities,
        options: MetalExecutionOptions
    ) -> RuntimeBackendTelemetry {
        lock.withLock {
            RuntimeBackendTelemetry(
                backendName: backendName,
                numericalProfile: numericalProfile,
                deviceName: capabilities.name,
                deviceRegistryID: capabilities.registryID,
                unifiedMemory: capabilities.unifiedMemory,
                allocatedPrivateBytes: allocatedPrivateBytes,
                allocatedSharedBytes: allocatedSharedBytes,
                hostToDeviceBytes: hostToDeviceBytes,
                deviceToHostBytes: deviceToHostBytes,
                computeCommandBuffers: computeCommandBuffers,
                transferCommandBuffers: transferCommandBuffers,
                computeEncoders: computeEncoders,
                blitEncoders: blitEncoders,
                dispatches: dispatches,
                completedCommandBuffers: completedCommandBuffers,
                failedCommandBuffers: failedCommandBuffers,
                accumulatedGPUSeconds: timedCommandBuffers > 0
                    ? accumulatedGPUSeconds
                    : nil,
                energyJoules: nil,
                hardwareCounters: hardwareCounters,
                metadata: [
                    "counterSampling.requested": String(options.enableCounterSampling),
                    "counterSampling.availableSets": capabilities.counterSetNames.joined(separator: ","),
                    "counterSampling.values": hardwareCounters.isEmpty
                        ? "not-sampled"
                        : "measured",
                    "encoderDispatchInstrumentation": "partial",
                    "energy.measurement": "not-provided",
                    "hazardMode": String(describing: options.hazardMode),
                    "mathProfile": numericalProfile.rawValue
                ]
            )
        }
    }

    public func reset() {
        lock.withLock {
            allocatedPrivateBytes = 0
            allocatedSharedBytes = 0
            hostToDeviceBytes = 0
            deviceToHostBytes = 0
            computeCommandBuffers = 0
            transferCommandBuffers = 0
            computeEncoders = 0
            blitEncoders = 0
            dispatches = 0
            completedCommandBuffers = 0
            failedCommandBuffers = 0
            accumulatedGPUSeconds = 0
            timedCommandBuffers = 0
            hardwareCounters.removeAll(keepingCapacity: true)
        }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
