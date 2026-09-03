#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

public final class MetalStateBufferSet: @unchecked Sendable {
    public let tiles: MTLBuffer
    public let cells: MTLBuffer
    public let regulatoryState: MTLBuffer
    public let segments: MTLBuffer
    public let compartments: MTLBuffer
    public let mechanismState: MTLBuffer
    public let synapses: MTLBuffer
    public let fields: MTLBuffer
    public let microdomains: MTLBuffer
    public let molecularSpecies: MTLBuffer

    public init(context: MetalDeviceContext, capacity: RuntimeCapacity, label: String, regulatoryCount: Int, mechanismCount: Int) throws {
        tiles = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<MetalTileState>.stride, label: "\(label).tiles")
        cells = try context.makePrivateBuffer(length: max(1, capacity.cells) * MemoryLayout<MetalCellState>.stride, label: "\(label).cells")
        regulatoryState = try context.makePrivateBuffer(length: max(1, regulatoryCount) * MemoryLayout<Float>.stride, label: "\(label).regulatory")
        segments = try context.makePrivateBuffer(length: max(1, capacity.segments) * MemoryLayout<MetalSegmentState>.stride, label: "\(label).segments")
        compartments = try context.makePrivateBuffer(length: max(1, capacity.compartments) * MemoryLayout<MetalCompartmentState>.stride, label: "\(label).compartments")
        mechanismState = try context.makePrivateBuffer(length: max(1, mechanismCount) * MemoryLayout<Float>.stride, label: "\(label).mechanisms")
        synapses = try context.makePrivateBuffer(length: max(1, capacity.synapses) * MemoryLayout<MetalSynapseState>.stride, label: "\(label).synapses")
        fields = try context.makePrivateBuffer(length: max(1, capacity.fieldValues) * MemoryLayout<MetalFieldState>.stride, label: "\(label).fields")
        microdomains = try context.makePrivateBuffer(length: max(1, capacity.microdomains) * MemoryLayout<MetalMicrodomainState>.stride, label: "\(label).microdomains")
        molecularSpecies = try context.makePrivateBuffer(length: max(1, capacity.molecularSpecies) * MemoryLayout<Float>.stride, label: "\(label).molecular")
    }

    public var all: [MTLBuffer] {
        [tiles, cells, regulatoryState, segments, compartments, mechanismState, synapses, fields, microdomains, molecularSpecies]
    }
}

/// Double-buffered delayed-event storage. Events generated during a transaction are written to
/// the shadow wheel and become authoritative only when the state arena commits. This keeps event
/// scheduling inside the same shadow -> validate -> commit contract as the biological pools.
public final class MetalEventWheelBuffers: @unchecked Sendable {
    public let localEvents: MTLBuffer
    public let eventBucketCounts: MTLBuffer

    public init(
        context: MetalDeviceContext,
        eventCapacity: Int,
        label: String
    ) throws {
        let capacity = max(1, eventCapacity)
        localEvents = try context.makePrivateBuffer(
            length: capacity * MemoryLayout<MetalEvent>.stride,
            label: "\(label).events"
        )
        eventBucketCounts = try context.makePrivateBuffer(
            length: 4_096 * MemoryLayout<UInt32>.stride,
            label: "\(label).counts"
        )
    }
}

public final class MetalTransientBuffers: @unchecked Sendable {
    public let header: MTLBuffer
    public let inputEvents: MTLBuffer
    public let stimuli: MTLBuffer
    public let outgoingEvents: MTLBuffer
    public let outputEvents: MTLBuffer
    public private(set) var committedEventWheel: MetalEventWheelBuffers
    public private(set) var shadowEventWheel: MetalEventWheelBuffers
    public let worklistCounts: MTLBuffer
    public let electricalWorklist: MTLBuffer
    public let fieldWorklist: MTLBuffer
    public let molecularWorklist: MTLBuffer
    public let mechanicsWorklist: MTLBuffer
    public let developmentWorklist: MTLBuffer
    public let fidelityWorklist: MTLBuffer
    public let validationRecords: MTLBuffer
    public let counters: MTLBuffer
    public let outputScalars: MTLBuffer
    public let indirectDispatch: MTLBuffer

    public let eventCapacity: Int
    public let validationCapacity: Int

    public init(context: MetalDeviceContext, capacity: RuntimeCapacity, validationCapacity: Int = 4_096) throws {
        self.eventCapacity = max(1, capacity.events)
        self.validationCapacity = max(1, validationCapacity)
        header = try context.makeSharedBuffer(length: 256, label: "NumiTissue.header", writeCombined: true)
        inputEvents = try context.makeSharedBuffer(length: self.eventCapacity * MemoryLayout<MetalEvent>.stride, label: "NumiTissue.inputEvents", writeCombined: true)
        stimuli = try context.makeSharedBuffer(length: self.eventCapacity * MemoryLayout<MetalEvent>.stride, label: "NumiTissue.stimuli", writeCombined: true)
        committedEventWheel = try MetalEventWheelBuffers(
            context: context,
            eventCapacity: self.eventCapacity,
            label: "NumiTissue.committedEventWheel"
        )
        shadowEventWheel = try MetalEventWheelBuffers(
            context: context,
            eventCapacity: self.eventCapacity,
            label: "NumiTissue.shadowEventWheel"
        )
        outgoingEvents = try context.makePrivateBuffer(length: self.eventCapacity * MemoryLayout<MetalEvent>.stride, label: "NumiTissue.outgoingEvents")
        outputEvents = try context.makeSharedBuffer(length: self.eventCapacity * MemoryLayout<MetalEvent>.stride, label: "NumiTissue.outputEvents")
        worklistCounts = try context.makeSharedBuffer(length: 16 * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklistCounts")
        electricalWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.electrical")
        fieldWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.fields")
        molecularWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.molecular")
        mechanicsWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.mechanics")
        developmentWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.development")
        fidelityWorklist = try context.makePrivateBuffer(length: max(1, capacity.tiles) * MemoryLayout<UInt32>.stride, label: "NumiTissue.worklist.fidelity")
        validationRecords = try context.makeSharedBuffer(length: self.validationCapacity * MemoryLayout<MetalValidationRecord>.stride, label: "NumiTissue.validation")
        counters = try context.makeSharedBuffer(length: MemoryLayout<MetalRuntimeCounters>.stride, label: "NumiTissue.counters")
        outputScalars = try context.makeSharedBuffer(length: max(4_096, capacity.tiles * 16) * MemoryLayout<Float>.stride, label: "NumiTissue.outputScalars")
        indirectDispatch = try context.makePrivateBuffer(length: 32 * MemoryLayout<MTLDispatchThreadgroupsIndirectArguments>.stride, label: "NumiTissue.indirectDispatch")
    }

    /// The active event wheel for the next transaction. It is deliberately the shadow wheel:
    /// `MetalStateArena.commit()` swaps the two wheel objects at the same time as the biological
    /// state buffers.
    public var localEvents: MTLBuffer { shadowEventWheel.localEvents }
    public var eventBucketCounts: MTLBuffer { shadowEventWheel.eventBucketCounts }

    public var committedLocalEvents: MTLBuffer { committedEventWheel.localEvents }
    public var committedEventBucketCounts: MTLBuffer { committedEventWheel.eventBucketCounts }

    public func swapEventWheels() {
        swap(&committedEventWheel, &shadowEventWheel)
    }

    public func resetCPUVisible() {
        memset(worklistCounts.contents(), 0, worklistCounts.length)
        memset(validationRecords.contents(), 0, validationRecords.length)
        memset(counters.contents(), 0, counters.length)
        memset(outputScalars.contents(), 0, outputScalars.length)
    }
}

/// Owns committed/shadow state and implements copy-on-transaction entirely with blit encoders.
public final class MetalStateArena: @unchecked Sendable {
    public let context: MetalDeviceContext
    public let capacity: RuntimeCapacity
    public let transient: MetalTransientBuffers

    public private(set) var committed: MetalStateBufferSet
    public private(set) var shadow: MetalStateBufferSet
    public private(set) var committedCPUState: TissueRuntimeState

    private let regulatoryCount: Int
    private let mechanismCount: Int

    public init(context: MetalDeviceContext, initialState: TissueRuntimeState) throws {
        try MetalTissueABI.validateHostLayout()
        self.context = context
        let requested = initialState.capacity
        self.capacity = RuntimeCapacity(
            tiles: max(requested.tiles, initialState.tiles.count),
            cells: max(requested.cells, initialState.cells.count),
            segments: max(requested.segments, initialState.segments.count),
            compartments: max(requested.compartments, initialState.compartments.count),
            synapses: max(requested.synapses, initialState.synapses.count),
            events: max(requested.events, 65_536),
            fieldValues: max(requested.fieldValues, initialState.fields.count),
            microdomains: max(requested.microdomains, initialState.microdomains.count),
            molecularSpecies: max(requested.molecularSpecies, initialState.molecularSpecies.count)
        )
        regulatoryCount = max(1, initialState.regulatoryState.count, self.capacity.cells * 32)
        mechanismCount = max(1, initialState.mechanismState.count, self.capacity.compartments * 16)
        committed = try MetalStateBufferSet(context: context, capacity: self.capacity, label: "NumiTissue.committed", regulatoryCount: regulatoryCount, mechanismCount: mechanismCount)
        shadow = try MetalStateBufferSet(context: context, capacity: self.capacity, label: "NumiTissue.shadow", regulatoryCount: regulatoryCount, mechanismCount: mechanismCount)
        transient = try MetalTransientBuffers(context: context, capacity: self.capacity)
        committedCPUState = initialState
    }

    public func uploadInitialState(_ state: TissueRuntimeState) async throws {
        try state.validateCapacity()
        let tiles = state.tiles.map(MetalTileState.init)
        let cells = state.cells.map(MetalCellState.init)
        let segments = state.segments.map(MetalSegmentState.init)
        let compartments = state.compartments.map(MetalCompartmentState.init)
        let synapses = state.synapses.map(MetalSynapseState.init)
        let fields = state.fields.map(MetalFieldState.init)
        let microdomains = state.microdomains.map(MetalMicrodomainState.init)

        let commandBuffer = try context.makeTransferCommandBuffer(label: "NumiTissue.initialUpload")
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw MetalRuntimeError.encoderCreationFailed("initialUpload") }
        context.telemetry.recordBlitEncoder()
        var staging: [MTLBuffer] = []
        try upload(tiles, to: committed.tiles, staging: &staging, blit: blit, label: "tiles")
        try upload(cells, to: committed.cells, staging: &staging, blit: blit, label: "cells")
        try upload(state.regulatoryState, to: committed.regulatoryState, staging: &staging, blit: blit, label: "regulatory")
        try upload(segments, to: committed.segments, staging: &staging, blit: blit, label: "segments")
        try upload(compartments, to: committed.compartments, staging: &staging, blit: blit, label: "compartments")
        try upload(state.mechanismState, to: committed.mechanismState, staging: &staging, blit: blit, label: "mechanisms")
        try upload(synapses, to: committed.synapses, staging: &staging, blit: blit, label: "synapses")
        try upload(fields, to: committed.fields, staging: &staging, blit: blit, label: "fields")
        try upload(microdomains, to: committed.microdomains, staging: &staging, blit: blit, label: "microdomains")
        try upload(state.molecularSpecies, to: committed.molecularSpecies, staging: &staging, blit: blit, label: "molecular")
        blit.fill(
            buffer: transient.committedEventWheel.eventBucketCounts,
            range: 0..<transient.committedEventWheel.eventBucketCounts.length,
            value: 0
        )
        blit.fill(
            buffer: transient.shadowEventWheel.eventBucketCounts,
            range: 0..<transient.shadowEventWheel.eventBucketCounts.length,
            value: 0
        )
        blit.fill(
            buffer: transient.committedEventWheel.localEvents,
            range: 0..<transient.committedEventWheel.localEvents.length,
            value: 0
        )
        blit.fill(
            buffer: transient.shadowEventWheel.localEvents,
            range: 0..<transient.shadowEventWheel.localEvents.length,
            value: 0
        )
        blit.endEncoding()
        try await context.awaitCompletion(MetalCommandBufferHandle(commandBuffer))
        try await copyCommittedToShadow()
        committedCPUState = state
        _ = staging
    }

    public func copyCommittedToShadow() async throws {
        let commandBuffer = try context.makeCommandBuffer(label: "NumiTissue.beginShadow")
        try encodeCommittedToShadow(on: commandBuffer)
        try await context.awaitCompletion(MetalCommandBufferHandle(commandBuffer))
    }

    /// Records the copy-on-write transition into an existing transaction command buffer. The
    /// transaction backend uses this form so a normal step has one GPU submission and one final
    /// completion wait, while initialization and standalone callers can keep the awaited helper
    /// above.
    public func encodeCommittedToShadow(
        on commandBuffer: MTLCommandBuffer,
        fence: MTLFence? = nil
    ) throws {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { throw MetalRuntimeError.encoderCreationFailed("beginShadow") }
        context.telemetry.recordBlitEncoder()
        copy(source: committed.tiles, destination: shadow.tiles, blit: blit)
        copy(source: committed.cells, destination: shadow.cells, blit: blit)
        copy(source: committed.regulatoryState, destination: shadow.regulatoryState, blit: blit)
        copy(source: committed.segments, destination: shadow.segments, blit: blit)
        copy(source: committed.compartments, destination: shadow.compartments, blit: blit)
        copy(source: committed.mechanismState, destination: shadow.mechanismState, blit: blit)
        copy(source: committed.synapses, destination: shadow.synapses, blit: blit)
        copy(source: committed.fields, destination: shadow.fields, blit: blit)
        copy(source: committed.microdomains, destination: shadow.microdomains, blit: blit)
        copy(source: committed.molecularSpecies, destination: shadow.molecularSpecies, blit: blit)
        copy(
            source: transient.committedEventWheel.localEvents,
            destination: transient.shadowEventWheel.localEvents,
            blit: blit
        )
        copy(
            source: transient.committedEventWheel.eventBucketCounts,
            destination: transient.shadowEventWheel.eventBucketCounts,
            blit: blit
        )
        if let fence {
            blit.updateFence(fence)
        }
        blit.endEncoding()
    }

    /// Commit is an O(1) ownership swap after the final command buffer and validation readback finish.
    public func commit(time: TissueTime, epoch: UInt64) {
        swap(&committed, &shadow)
        transient.swapEventWheels()
        committedCPUState.time = time
        committedCPUState.epoch = epoch
    }

    /// Rollback leaves committed buffers untouched. The next begin step overwrites shadow.
    public func rollback() {
        transient.resetCPUVisible()
    }

    public func updateHeader(_ header: MetalSimulationHeader) {
        transient.header.contents().copyMemory(from: [header], byteCount: MemoryLayout<MetalSimulationHeader>.stride)
        context.telemetry.recordUpload(bytes: MemoryLayout<MetalSimulationHeader>.stride)
    }

    public func uploadInput(events: [RoutedEvent], stimuli: [TissueStimulus]) throws {
        guard events.count <= transient.eventCapacity else { throw MetalRuntimeError.capacityExceeded("input events") }
        guard stimuli.count <= transient.eventCapacity else { throw MetalRuntimeError.capacityExceeded("stimuli") }
        // CPU EventDelayWheel assigns a fresh sequence in ingestion order rather than trusting
        // the caller's placeholder. Mirror that contract before the unordered GPU ingestion
        // kernel; the bounded bucket sort then reproduces the reference ordering for equal-time
        // events without depending on atomic reservation order.
        let metalEvents = events.enumerated().map { index, event in
            var result = MetalEvent(event)
            result.sequence = UInt32(clamping: index)
            return result
        }
        metalEvents.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { transient.inputEvents.contents().copyMemory(from: base, byteCount: bytes.count) }
            context.telemetry.recordUpload(bytes: bytes.count)
        }
        let metalStimuli = stimuli.enumerated().map { index, stimulus in
            var result = MetalEvent(RoutedEvent(
                arrivalTick: stimulus.startTick,
                source: 0,
                destination: stimulus.destination,
                amplitude: stimulus.amplitude,
                kind: .electrodeStimulus,
                flags: stimulus.flags,
                sequence: stimulus.durationTicks
            ))
            result.sequence = UInt32(clamping: events.count + index)
            return result
        }
        metalStimuli.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { transient.stimuli.contents().copyMemory(from: base, byteCount: bytes.count) }
            context.telemetry.recordUpload(bytes: bytes.count)
        }
    }

    private func copy(source: MTLBuffer, destination: MTLBuffer, blit: MTLBlitCommandEncoder) {
        let size = min(source.length, destination.length)
        blit.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0, size: size)
    }

    private func upload<T>(_ values: [T], to destination: MTLBuffer, staging: inout [MTLBuffer], blit: MTLBlitCommandEncoder, label: String) throws {
        guard !values.isEmpty else { return }
        let bytes = values.count * MemoryLayout<T>.stride
        guard bytes <= destination.length else { throw MetalRuntimeError.capacityExceeded(label) }
        let buffer = try context.makeSharedBuffer(length: bytes, label: "NumiTissue.upload.\(label)", writeCombined: true)
        values.withUnsafeBytes { source in
            if let base = source.baseAddress { buffer.contents().copyMemory(from: base, byteCount: source.count) }
        }
        blit.copy(from: buffer, sourceOffset: 0, to: destination, destinationOffset: 0, size: bytes)
        context.telemetry.recordUpload(bytes: bytes)
        staging.append(buffer)
    }
}

private extension UnsafeMutableRawPointer {
    func copyMemory<T>(from values: [T], byteCount: Int) {
        values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            self.copyMemory(from: base, byteCount: min(byteCount, bytes.count))
        }
    }
}
#endif
