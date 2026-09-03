#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal
import NumiTissueRuntime

/// Bounded shared ring for immutable per-dispatch simulation headers. Each header is copied into the
/// shader-visible header buffer immediately before its dispatch inside the unified Metal 4 pass.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public final class Metal4PhaseHeaderRing: @unchecked Sendable {
    public let buffer: MTLBuffer
    public let stride: Int
    public let capacity: Int
    public private(set) var count: Int = 0

    private let telemetry: MetalTelemetryRecorder

    public init(
        context: MetalDeviceContext,
        capacity: Int
    ) throws {
        guard (1...1_000_000).contains(capacity) else {
            throw Metal4StateEncodingError.invalidHeaderCapacity(capacity)
        }
        stride = MetalTissueABI.alignment
        self.capacity = capacity
        self.telemetry = context.telemetry
        buffer = try context.makeSharedBuffer(
            length: capacity * stride,
            label: "NumiTissue.Metal4.phaseHeaders",
            writeCombined: true
        )
    }

    public func reset() {
        count = 0
    }

    public func append(_ header: MetalSimulationHeader) throws -> Int {
        guard count < capacity else {
            throw Metal4StateEncodingError.headerCapacityExceeded(capacity)
        }
        let offset = count * stride
        memset(buffer.contents().advanced(by: offset), 0, stride)
        withUnsafeBytes(of: header) { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.contents().advanced(by: offset).copyMemory(
                from: base,
                byteCount: bytes.count
            )
            telemetry.recordUpload(bytes: bytes.count)
        }
        count += 1
        return offset
    }
}

/// Unified-pass state movement. These operations use the exact buffers owned by the established
/// Metal arena, but encode them through the Metal 4 compute encoder so the transaction has one
/// submission and one synchronization authority.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4StateEncoder {
    public static func copyCommittedToShadow(
        arena: MetalStateArena,
        session: Metal4EncodingSession
    ) throws {
        let committed = arena.committed
        let shadow = arena.shadow
        let transient = arena.transient
        let operations: [Metal4BufferCopy] = [
            copy(committed.tiles, shadow.tiles),
            copy(committed.cells, shadow.cells),
            copy(committed.regulatoryState, shadow.regulatoryState),
            copy(committed.segments, shadow.segments),
            copy(committed.compartments, shadow.compartments),
            copy(committed.mechanismState, shadow.mechanismState),
            copy(committed.synapses, shadow.synapses),
            copy(committed.fields, shadow.fields),
            copy(committed.microdomains, shadow.microdomains),
            copy(committed.molecularSpecies, shadow.molecularSpecies),
            copy(
                transient.committedEventWheel.localEvents,
                transient.shadowEventWheel.localEvents
            ),
            copy(
                transient.committedEventWheel.eventBucketCounts,
                transient.shadowEventWheel.eventBucketCounts
            )
        ]
        try session.encodeCopies(
            operations,
            access: .copyCommittedToShadow
        )
    }

    public static func resetEffectiveParameters(
        model: MetalModelBuffers,
        session: Metal4EncodingSession
    ) throws {
        var operations: [Metal4BufferCopy] = []
        operations.reserveCapacity(model.parameterTables.count + 1)
        for domain in model.parameterTables.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard let table = model.parameterTables[domain] else { continue }
            operations.append(copy(table.baseline, table.effective))
        }
        operations.append(copy(
            model.molecularReactionsBaseline,
            model.molecularReactions
        ))
        try session.encodeCopies(
            operations,
            access: .resetEffectiveParameters
        )
    }

    /// Clears only private transaction scratch. Shared counters, validation records, and control
    /// scalars are reset on the CPU before submission; clearing them again on the GPU would erase
    /// the neuromodulator and hormone frame written into `outputScalars` for this transaction.
    /// Delayed-event buckets are committed state and are never cleared here.
    public static func resetTransactionTransientState(
        arena: MetalStateArena,
        session: Metal4EncodingSession
    ) throws {
        let transient = arena.transient
        let operations: [Metal4BufferFill] = [
            fill(transient.outgoingEvents),
            fill(transient.electricalWorklist),
            fill(transient.fieldWorklist),
            fill(transient.molecularWorklist),
            fill(transient.mechanicsWorklist),
            fill(transient.developmentWorklist),
            fill(transient.fidelityWorklist),
            fill(transient.indirectDispatch)
        ]
        try session.encodeFills(
            operations,
            access: .resetTransientState
        )
    }

    public static func copyPhaseHeader(
        _ header: MetalSimulationHeader,
        ring: Metal4PhaseHeaderRing,
        destination: MTLBuffer,
        session: Metal4EncodingSession
    ) throws {
        let offset = try ring.append(header)
        try session.encodeCopy(
            source: ring.buffer,
            sourceOffset: offset,
            destination: destination,
            destinationOffset: 0,
            size: MemoryLayout<MetalSimulationHeader>.stride,
            access: .copyPhaseHeader
        )
    }

    private static func copy(
        _ source: MTLBuffer,
        _ destination: MTLBuffer
    ) -> Metal4BufferCopy {
        Metal4BufferCopy(
            source: source,
            destination: destination,
            size: min(source.length, destination.length)
        )
    }

    private static func fill(_ buffer: MTLBuffer) -> Metal4BufferFill {
        Metal4BufferFill(
            buffer: buffer,
            range: 0..<buffer.length,
            value: 0
        )
    }
}

/// Enumerates long-lived allocations required by the Metal 4 queue-level residency set. Private
/// buffers are represented by their owning heap; shared buffers and pipeline states are listed
/// explicitly. Transaction-local overlay buffers are appended when present.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4ResidencyCatalog {
    public static func allocations(
        context: MetalDeviceContext,
        arena: MetalStateArena,
        argumentTables: [MetalArgumentTable],
        phaseHeaderRing: Metal4PhaseHeaderRing,
        pipelines: [MTLComputePipelineState],
        overlay: MetalTransactionOverlayBuffers? = nil,
        additionalSharedBuffers: [MTLBuffer] = []
    ) -> [any MTLAllocation] {
        var result: [any MTLAllocation] = [context.privateHeap]
        let transient = arena.transient
        let shared: [MTLBuffer] = [
            transient.header,
            transient.inputEvents,
            transient.stimuli,
            transient.outputEvents,
            transient.worklistCounts,
            transient.validationRecords,
            transient.counters,
            transient.outputScalars,
            phaseHeaderRing.buffer
        ] + argumentTables.map(\.buffer) + additionalSharedBuffers
        result.append(contentsOf: shared.map { $0 as any MTLAllocation })
        if let overlay {
            result.append(overlay.groups as any MTLAllocation)
            result.append(overlay.records as any MTLAllocation)
            result.append(overlay.parameters as any MTLAllocation)
        }
        result.append(contentsOf: pipelines.map {
            $0 as any MTLAllocation
        })
        return deduplicated(result)
    }

    private static func deduplicated(
        _ source: [any MTLAllocation]
    ) -> [any MTLAllocation] {
        var identifiers = Set<ObjectIdentifier>()
        var result: [any MTLAllocation] = []
        result.reserveCapacity(source.count)
        for allocation in source {
            let identifier = ObjectIdentifier(allocation as AnyObject)
            if identifiers.insert(identifier).inserted {
                result.append(allocation)
            }
        }
        return result
    }
}

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4StateEncodingError: Error, Sendable, CustomStringConvertible {
    case invalidHeaderCapacity(Int)
    case headerCapacityExceeded(Int)

    public var description: String {
        switch self {
        case .invalidHeaderCapacity(let capacity):
            return "Metal 4 phase-header capacity \(capacity) is outside 1...1,000,000"
        case .headerCapacityExceeded(let capacity):
            return "Metal 4 phase-header ring exceeded \(capacity) entries"
        }
    }
}
#endif
