#if canImport(Metal)
import Foundation
import Metal

public struct Metal4SupportReport: Sendable, Hashable, Codable {
    public var sdkCompiled: Bool
    public var operatingSystemAvailable: Bool
    public var gpuFamilyAvailable: Bool
    public var commandQueueAvailable: Bool
    public var deviceName: String?
    public var deviceRegistryID: UInt64?
    public var reason: String?

    public init(
        sdkCompiled: Bool,
        operatingSystemAvailable: Bool,
        gpuFamilyAvailable: Bool,
        commandQueueAvailable: Bool,
        deviceName: String?,
        deviceRegistryID: UInt64?,
        reason: String?
    ) {
        self.sdkCompiled = sdkCompiled
        self.operatingSystemAvailable = operatingSystemAvailable
        self.gpuFamilyAvailable = gpuFamilyAvailable
        self.commandQueueAvailable = commandQueueAvailable
        self.deviceName = deviceName
        self.deviceRegistryID = deviceRegistryID
        self.reason = reason
    }

    public var supported: Bool {
        sdkCompiled &&
        operatingSystemAvailable &&
        gpuFamilyAvailable &&
        commandQueueAvailable
    }
}

public enum Metal4Support {
    public static func probe(
        device requestedDevice: MTLDevice? = nil
    ) -> Metal4SupportReport {
        guard let device = requestedDevice ?? MTLCreateSystemDefaultDevice() else {
            return Metal4SupportReport(
                sdkCompiled: Self.sdkCompiled,
                operatingSystemAvailable: false,
                gpuFamilyAvailable: false,
                commandQueueAvailable: false,
                deviceName: nil,
                deviceRegistryID: nil,
                reason: "No Metal device is available"
            )
        }

        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *) {
            let family = device.supportsFamily(.metal4)
            guard family else {
                return Metal4SupportReport(
                    sdkCompiled: true,
                    operatingSystemAvailable: true,
                    gpuFamilyAvailable: false,
                    commandQueueAvailable: false,
                    deviceName: device.name,
                    deviceRegistryID: device.registryID,
                    reason: "The selected GPU does not advertise MTLGPUFamily.metal4"
                )
            }
            let queueAvailable = device.makeMTL4CommandQueue() != nil
            return Metal4SupportReport(
                sdkCompiled: true,
                operatingSystemAvailable: true,
                gpuFamilyAvailable: true,
                commandQueueAvailable: queueAvailable,
                deviceName: device.name,
                deviceRegistryID: device.registryID,
                reason: queueAvailable
                    ? nil
                    : "Metal 4 command-queue creation failed"
            )
        }
        return Metal4SupportReport(
            sdkCompiled: true,
            operatingSystemAvailable: false,
            gpuFamilyAvailable: false,
            commandQueueAvailable: false,
            deviceName: device.name,
            deviceRegistryID: device.registryID,
            reason: "Metal 4 requires an operating system that exposes the Metal 4 API"
        )
        #else
        return Metal4SupportReport(
            sdkCompiled: false,
            operatingSystemAvailable: false,
            gpuFamilyAvailable: false,
            commandQueueAvailable: false,
            deviceName: device.name,
            deviceRegistryID: device.registryID,
            reason: "This build was compiled without the Metal 4 SDK surface"
        )
        #endif
    }

    public static var sdkCompiled: Bool {
        #if compiler(>=6.2)
        true
        #else
        false
        #endif
    }

    public static func require(
        device: MTLDevice? = nil
    ) throws -> Metal4SupportReport {
        let report = probe(device: device)
        guard report.supported else {
            throw Metal4SupportError.unsupported(
                report.reason ?? "Metal 4 is unavailable"
            )
        }
        return report
    }
}

public enum Metal4SupportError: Error, Sendable, CustomStringConvertible {
    case unsupported(String)

    public var description: String {
        switch self {
        case .unsupported(let reason):
            return "Metal 4 backend is unavailable: \(reason)"
        }
    }
}
#endif
