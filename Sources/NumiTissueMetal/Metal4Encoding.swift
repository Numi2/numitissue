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
public struct Metal4BufferCopy: @unchecked Sendable {
    public var source: MTLBuffer
    public var sourceOffset: Int
    public var destination: MTLBuffer
    public var destinationOffset: Int
    public var size: Int

    public init(
        source: MTLBuffer,
        sourceOffset: Int = 0,
        destination: MTLBuffer,
        destinationOffset: Int = 0,
        size: Int
    ) {
        self.source = source
        self.sourceOffset = sourceOffset
        self.destination = destination
        self.destinationOffset = destinationOffset
        self.size = size
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public struct Metal4BufferFill: @unchecked Sendable {
    public var buffer: MTLBuffer
    public var range: Range<Int>
    public var value: UInt8

    public init(buffer: MTLBuffer, range: Range<Int>, value: UInt8) {
        self.buffer = buffer
        self.range = range
        self.value = value
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
        try encodeCopies(
            [
                Metal4BufferCopy(
                    source: source,
                    sourceOffset: sourceOffset,
                    destination: destination,
                    destinationOffset: destinationOffset,
                    size: size
                )
            ],
            access: access
        )
    }

    /// Encodes several byte copies as one semantic operation. The access graph is evaluated once,
    /// so copying all structure-of-arrays pools does not insert barriers between independent buffers.
    public func encodeCopies(
        _ operations: [Metal4BufferCopy],
        access: Metal4CommandAccess
    ) throws {
        guard !operations.isEmpty else { return }
        try ensureCanEncode(additionalCommands: operations.count)
        for operation in operations {
            try validate(operation)
        }
        try prepare(access)
        for operation in operations {
            lease.encoder.copy(
                sourceBuffer: operation.source,
                sourceOffset: operation.sourceOffset,
                destinationBuffer: operation.destination,
                destinationOffset: operation.destinationOffset,
                size: operation.size
            )
            lease.retain(operation.source)
            lease.retain(operation.destination)
            telemetry.recordBlit()
        }
        statisticsValue.commandCount += operations.count
        statisticsValue.blitCount += operations.count
    }

    public func encodeFill(
        buffer: MTLBuffer,
        range: Range<Int>,
        value: UInt8,
        access: Metal4CommandAccess
    ) throws {
        try encodeFills(
            [Metal4BufferFill(buffer: buffer, range: range, value: value)],
            access: access
        )
    }

    /// Encodes a bounded collection of fills under one synchronization decision. This is used for
    /// transient counters, validation storage, worklists, and output buffers at transaction start.
    public func encodeFills(
        _ operations: [Metal4BufferFill],
        access: Metal4CommandAccess
    ) throws {
        guard !operations.isEmpty else { return }
        try ensureCanEncode(additionalCommands: operations.count)
        for operation in operations {
            try validate(operation)
        }
        try prepare(access)
        for operation in operations {
            lease.encoder.fill(
                buffer: operation.buffer,
                range: operation.range,
                value: operation.value
            )
            lease.retain(operation.buffer)
            telemetry.recordBlit()
        }
        statisticsValue.commandCount += operations.count
        statisticsValue.blitCount += operations.count
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
        let decision = try Metal4DispatchPlanner.decide(
            kernel: kernel,
            threadCount: threadCount,
            specialization: specialization,
            configuration: configuration
        )
        guard decision.threadCount > 0 else { return }
        try ensureCanEncode(additionalCommands: 1)
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

    private func ensureCanEncode(additionalCommands: Int) throws {
        guard !ended else { throw Metal4EncodingError.sessionAlreadyEnded }
        guard additionalCommands >= 0 else {
            throw Metal4EncodingError.invalidCommandCount(additionalCommands)
        }
        let total = statisticsValue.commandCount.addingReportingOverflow(
            additionalCommands
        )
        guard !total.overflow,
              total.partialValue <= configuration.maximumDispatchesPerGroup else {
            throw Metal4EncodingError.commandGroupLimitExceeded(
                configuration.maximumDispatchesPerGroup
            )
        }
    }

    private func validate(_ operation: Metal4BufferCopy) throws {
        guard operation.size > 0,
              operation.sourceOffset >= 0,
              operation.destinationOffset >= 0,
              operation.sourceOffset <= operation.source.length,
              operation.destinationOffset <= operation.destination.length,
              operation.size <= operation.source.length - operation.sourceOffset,
              operation.size <= operation.destination.length - operation.destinationOffset else {
            throw Metal4EncodingError.invalidCopyRange(
                sourceLength: operation.source.length,
                sourceOffset: operation.sourceOffset,
                destinationLength: operation.destination.length,
                destinationOffset: operation.destinationOffset,
                size: operation.size
            )
        }
    }

    private func validate(_ operation: Metal4BufferFill) throws {
        guard !operation.range.isEmpty,
              operation.range.lowerBound >= 0,
              operation.range.upperBound <= operation.buffer.length else {
            throw Metal4EncodingError.invalidFillRange(
                bufferLength: operation.buffer.length,
                range: operation.range
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
    case invalidCommandCount(Int)
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
        case .invalidCommandCount(let count):
            return "Metal 4 logical command group contains invalid count \(count)"
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
