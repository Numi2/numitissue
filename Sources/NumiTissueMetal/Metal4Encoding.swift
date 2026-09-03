#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4StageBarrier: Sendable, Hashable, Codable {
    public var afterBlit: Bool
    public var afterDispatch: Bool
    public var beforeStage: Metal4CommandStage
    public var hazards: [Metal4ResourceDomain]
    public var beforeLabel: String

    public init(
        afterBlit: Bool,
        afterDispatch: Bool,
        beforeStage: Metal4CommandStage,
        hazards: [Metal4ResourceDomain],
        beforeLabel: String
    ) {
        self.afterBlit = afterBlit
        self.afterDispatch = afterDispatch
        self.beforeStage = beforeStage
        self.hazards = hazards
        self.beforeLabel = beforeLabel
    }

    public var requiresBarrier: Bool { afterBlit || afterDispatch }
}

/// Tracks every unsynchronized access since the last relevant barrier. An unrelated command cannot
/// hide a prior write hazard, which is essential when the whole tissue transaction occupies one
/// Metal 4 compute pass.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4HazardTracker: Sendable {
    private var pendingBlit: [Metal4ResourceDomain: Metal4AccessMode] = [:]
    private var pendingDispatch: [Metal4ResourceDomain: Metal4AccessMode] = [:]

    public init() {}

    public mutating func prepare(
        _ command: Metal4CommandAccess
    ) -> Metal4StageBarrier {
        let next = merged(command.accesses)
        let blitHazards = hazards(previous: pendingBlit, next: next)
        let dispatchHazards = hazards(previous: pendingDispatch, next: next)
        let combined = Set(blitHazards)
            .union(dispatchHazards)
            .sorted { $0.rawValue < $1.rawValue }
        let barrier = Metal4StageBarrier(
            afterBlit: !blitHazards.isEmpty,
            afterDispatch: !dispatchHazards.isEmpty,
            beforeStage: command.stage,
            hazards: combined,
            beforeLabel: command.label
        )

        if barrier.afterBlit { pendingBlit.removeAll(keepingCapacity: true) }
        if barrier.afterDispatch {
            pendingDispatch.removeAll(keepingCapacity: true)
        }
        switch command.stage {
        case .blit:
            merge(next, into: &pendingBlit)
        case .dispatch:
            merge(next, into: &pendingDispatch)
        }
        return barrier
    }

    public mutating func reset() {
        pendingBlit.removeAll(keepingCapacity: true)
        pendingDispatch.removeAll(keepingCapacity: true)
    }

    private func hazards(
        previous: [Metal4ResourceDomain: Metal4AccessMode],
        next: [Metal4ResourceDomain: Metal4AccessMode]
    ) -> [Metal4ResourceDomain] {
        Set(previous.keys).intersection(next.keys).filter { resource in
            guard let lhs = previous[resource],
                  let rhs = next[resource] else { return false }
            return lhs.writes || rhs.writes
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private func merged(
        _ accesses: [Metal4ResourceAccess]
    ) -> [Metal4ResourceDomain: Metal4AccessMode] {
        Dictionary(
            accesses.map { ($0.resource, $0.mode) },
            uniquingKeysWith: mergeMode
        )
    }

    private func merge(
        _ source: [Metal4ResourceDomain: Metal4AccessMode],
        into destination: inout [Metal4ResourceDomain: Metal4AccessMode]
    ) {
        for (resource, mode) in source {
            if let previous = destination[resource] {
                destination[resource] = mergeMode(previous, mode)
            } else {
                destination[resource] = mode
            }
        }
    }

    private func mergeMode(
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

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4EncodingStatistics: Sendable, Hashable, Codable {
    public var commandCount: Int
    public var dispatchCount: Int
    public var blitCount: Int
    public var barrierCount: Int
    public var directDispatchCount: Int
    public var indirectDispatchCount: Int
    public var encodedThreadCount: UInt64

    public init(
        commandCount: Int = 0,
        dispatchCount: Int = 0,
        blitCount: Int = 0,
        barrierCount: Int = 0,
        directDispatchCount: Int = 0,
        indirectDispatchCount: Int = 0,
        encodedThreadCount: UInt64 = 0
    ) {
        self.commandCount = commandCount
        self.dispatchCount = dispatchCount
        self.blitCount = blitCount
        self.barrierCount = barrierCount
        self.directDispatchCount = directDispatchCount
        self.indirectDispatchCount = indirectDispatchCount
        self.encodedThreadCount = encodedThreadCount
    }
}

/// One unified Metal 4 compute pass. It centralizes synchronization, resource retention, binding,
/// dispatch policy, and telemetry so production kernels cannot bypass the Phase 3 contract.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4EncodingSession: @unchecked Sendable {
    public let lease: Metal4CommandLease
    public let configuration: Metal4ExecutionConfiguration
    public let telemetry: Metal4SubmissionTelemetryRecorder

    private var hazardTracker = Metal4HazardTracker()
    private var statisticsValue = Metal4EncodingStatistics()
    private var ended = false

    public init(
        lease: Metal4CommandLease,
        configuration: Metal4ExecutionConfiguration,
        telemetry: Metal4SubmissionTelemetryRecorder
    ) {
        self.lease = lease
        self.configuration = configuration
        self.telemetry = telemetry
    }

    public var statistics: Metal4EncodingStatistics { statisticsValue }

    public func encodeCopy(
        source: MTLBuffer,
        sourceOffset: Int = 0,
        destination: MTLBuffer,
        destinationOffset: Int = 0,
        size: Int,
        access: Metal4CommandAccess
    ) throws {
        try ensureCanEncode()
        guard size > 0,
              sourceOffset >= 0,
              destinationOffset >= 0,
              sourceOffset <= source.length - min(size, source.length),
              destinationOffset <= destination.length - min(size, destination.length),
              size <= source.length - sourceOffset,
              size <= destination.length - destinationOffset else {
            throw Metal4EncodingError.invalidCopyRange(
                sourceLength: source.length,
                sourceOffset: sourceOffset,
                destinationLength: destination.length,
                destinationOffset: destinationOffset,
                size: size
            )
        }
        try prepare(access)
        lease.encoder.copy(
            sourceBuffer: source,
            sourceOffset: sourceOffset,
            destinationBuffer: destination,
            destinationOffset: destinationOffset,
            size: size
        )
        lease.retain(source)
        lease.retain(destination)
        statisticsValue.commandCount += 1
        statisticsValue.blitCount += 1
        telemetry.recordBlit()
    }

    public func encodeFill(
        buffer: MTLBuffer,
        range: Range<Int>,
        value: UInt8,
        access: Metal4CommandAccess
    ) throws {
        try ensureCanEncode()
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= buffer.length else {
            throw Metal4EncodingError.invalidFillRange(
                bufferLength: buffer.length,
                range: range
            )
        }
        try prepare(access)
        lease.encoder.fill(buffer: buffer, range: range, value: value)
        lease.retain(buffer)
        statisticsValue.commandCount += 1
        statisticsValue.blitCount += 1
        telemetry.recordBlit()
    }

    public func encodeDispatch(
        kernel: MetalKernel,
        threadCount: Int,
        pipeline: MTLComputePipelineState,
        argumentTable: Metal4ArgumentTableEntry,
        specialization: Metal4KernelSpecialization = .init(),
        indirectAddress: MTLGPUAddress? = nil,
        indirectThreadsPerThreadgroup: MTLSize? = nil
    ) throws {
        try ensureCanEncode()
        let decision = try Metal4DispatchPlanner.decide(
            kernel: kernel,
            threadCount: threadCount,
            specialization: specialization,
            configuration: configuration
        )
        guard decision.threadCount > 0 else { return }
        try prepare(.dispatch(kernel))

        lease.encoder.setArgumentTable(argumentTable.table)
        lease.encoder.setComputePipelineState(pipeline)
        switch decision.mode {
        case .direct:
            let width = Self.threadgroupWidth(pipeline)
            lease.encoder.dispatchThreads(
                threadsPerGrid: MTLSize(
                    width: decision.threadCount,
                    height: 1,
                    depth: 1
                ),
                threadsPerThreadgroup: MTLSize(
                    width: width,
                    height: 1,
                    depth: 1
                )
            )
            statisticsValue.directDispatchCount += 1
        case .indirect:
            guard let indirectAddress,
                  let indirectThreadsPerThreadgroup else {
                throw Metal4EncodingError.missingIndirectArguments(
                    kernel.rawValue
                )
            }
            lease.encoder.dispatchThreadgroups(
                indirectBuffer: indirectAddress,
                threadsPerThreadgroup: indirectThreadsPerThreadgroup
            )
            statisticsValue.indirectDispatchCount += 1
        }

        lease.retain(contentsOf: argumentTable.retainedObjects)
        lease.retain(pipeline)
        statisticsValue.commandCount += 1
        statisticsValue.dispatchCount += 1
        statisticsValue.encodedThreadCount &+= UInt64(decision.threadCount)
        telemetry.recordDispatch()
    }

    public func markEnded() throws {
        guard !ended else { throw Metal4EncodingError.sessionAlreadyEnded }
        ended = true
    }

    private func prepare(_ command: Metal4CommandAccess) throws {
        let barrier = hazardTracker.prepare(command)
        if barrier.requiresBarrier {
            var after: MTLStages = []
            if barrier.afterBlit { after.insert(.blit) }
            if barrier.afterDispatch { after.insert(.dispatch) }
            let before: MTLStages = barrier.beforeStage == .blit
                ? .blit
                : .dispatch
            lease.encoder.barrier(
                afterEncoderStages: after,
                beforeEncoderStages: before,
                visibilityOptions: [.device]
            )
            statisticsValue.barrierCount += 1
            telemetry.recordBarrier()
        }
    }

    private func ensureCanEncode() throws {
        guard !ended else { throw Metal4EncodingError.sessionAlreadyEnded }
        guard statisticsValue.commandCount <
                configuration.maximumDispatchesPerGroup else {
            throw Metal4EncodingError.commandGroupLimitExceeded(
                configuration.maximumDispatchesPerGroup
            )
        }
    }

    private static func threadgroupWidth(
        _ pipeline: MTLComputePipelineState
    ) -> Int {
        min(
            pipeline.maxTotalThreadsPerThreadgroup,
            max(pipeline.threadExecutionWidth, 64)
        )
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4EncodingError: Error, Sendable, CustomStringConvertible {
    case invalidCopyRange(
        sourceLength: Int,
        sourceOffset: Int,
        destinationLength: Int,
        destinationOffset: Int,
        size: Int
    )
    case invalidFillRange(bufferLength: Int, range: Range<Int>)
    case missingIndirectArguments(String)
    case commandGroupLimitExceeded(Int)
    case sessionAlreadyEnded

    public var description: String {
        switch self {
        case .invalidCopyRange(
            let sourceLength,
            let sourceOffset,
            let destinationLength,
            let destinationOffset,
            let size
        ):
            return "Invalid Metal 4 copy: source \(sourceOffset)+\(size)/\(sourceLength), destination \(destinationOffset)+\(size)/\(destinationLength)"
        case .invalidFillRange(let bufferLength, let range):
            return "Invalid Metal 4 fill range \(range) for \(bufferLength)-byte buffer"
        case .missingIndirectArguments(let kernel):
            return "Metal 4 indirect dispatch for \(kernel) is missing its argument address or threadgroup size"
        case .commandGroupLimitExceeded(let limit):
            return "Metal 4 unified command group exceeded \(limit) commands"
        case .sessionAlreadyEnded:
            return "Metal 4 encoding session has already ended"
        }
    }
}
#endif
