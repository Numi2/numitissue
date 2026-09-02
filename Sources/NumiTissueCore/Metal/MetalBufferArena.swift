import Foundation

#if canImport(Metal)
import Metal

public enum NTMetalStorageClass: UInt8, Sendable {
    case privatePersistent
    case privateScratch
    case sharedStaging
    case sharedReadback
}

public final class NTMetalBufferResource: @unchecked Sendable {
    public let slot: NTMetalBufferSlot
    public let storageClass: NTMetalStorageClass
    public let buffer: any MTLBuffer
    public let logicalLength: Int
    public let allocatedLength: Int
    public let generation: UInt64

    public init(
        slot: NTMetalBufferSlot,
        storageClass: NTMetalStorageClass,
        buffer: any MTLBuffer,
        logicalLength: Int,
        allocatedLength: Int,
        generation: UInt64
    ) {
        self.slot = slot
        self.storageClass = storageClass
        self.buffer = buffer
        self.logicalLength = logicalLength
        self.allocatedLength = allocatedLength
        self.generation = generation
    }
}

@frozen
public struct NTMetalArenaStatistics: Sendable {
    public var privateHeapCapacity: UInt64
    public var privateHeapUsed: UInt64
    public var privateFallbackBytes: UInt64
    public var sharedBytes: UInt64
    public var resourceCount: UInt32
    public var generation: UInt64

    public init() {
        privateHeapCapacity = 0
        privateHeapUsed = 0
        privateFallbackBytes = 0
        sharedBytes = 0
        resourceCount = 0
        generation = 0
    }
}

/// GPU-resident buffer arena. Authoritative fast state is allocated from a private Metal heap;
/// shared buffers are limited to immutable uploads, control records, checkpoints and readback.
public final class NTMetalBufferArena: @unchecked Sendable {
    public let device: any MTLDevice
    public let commandQueue: any MTLCommandQueue
    public private(set) var generation: UInt64 = 1

    private var persistentHeap: (any MTLHeap)?
    private var scratchHeap: (any MTLHeap)?
    private var resources: [NTMetalBufferSlot: NTMetalBufferResource] = [:]
    private var staging: [NTMetalBufferSlot: NTMetalBufferResource] = [:]
    private var readback: [NTMetalBufferSlot: NTMetalBufferResource] = [:]
    private var privateFallbackBytes: UInt64 = 0
    private var sharedBytes: UInt64 = 0

    public init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        persistentHeapBytes: UInt64,
        scratchHeapBytes: UInt64
    ) throws {
        self.device = device
        self.commandQueue = commandQueue
        persistentHeap = try Self.makePrivateHeap(
            device: device,
            bytes: max(persistentHeapBytes, 4 * 1_024 * 1_024),
            label: "NumiTissue.PersistentHeap"
        )
        scratchHeap = try Self.makePrivateHeap(
            device: device,
            bytes: max(scratchHeapBytes, 4 * 1_024 * 1_024),
            label: "NumiTissue.ScratchHeap"
        )
    }

    public func resource(_ slot: NTMetalBufferSlot) -> NTMetalBufferResource? {
        resources[slot]
    }

    public func stagingResource(_ slot: NTMetalBufferSlot) -> NTMetalBufferResource? {
        staging[slot]
    }

    public func readbackResource(_ slot: NTMetalBufferSlot) -> NTMetalBufferResource? {
        readback[slot]
    }

    @discardableResult
    public func allocate(
        slot: NTMetalBufferSlot,
        logicalLength: Int,
        storageClass: NTMetalStorageClass,
        label: String? = nil,
        zeroed: Bool = false
    ) throws -> NTMetalBufferResource {
        guard logicalLength >= 0 else {
            throw NTRuntimeError.invalidConfiguration("Metal buffer length cannot be negative.")
        }
        let requestedLength = max(logicalLength, 256)
        let allocationLength = Self.align(requestedLength, to: 256)
        if let existing = resourceMap(for: storageClass)[slot], existing.allocatedLength >= allocationLength {
            return existing
        }

        let options: MTLResourceOptions
        let buffer: any MTLBuffer
        switch storageClass {
        case .privatePersistent, .privateScratch:
            options = [.storageModePrivate, .hazardTrackingModeTracked]
            let heap = storageClass == .privatePersistent ? persistentHeap : scratchHeap
            if let heap, let allocated = heap.makeBuffer(length: allocationLength, options: options) {
                buffer = allocated
            } else if let allocated = device.makeBuffer(length: allocationLength, options: options) {
                buffer = allocated
                privateFallbackBytes &+= UInt64(allocationLength)
            } else {
                throw NTRuntimeError.resourceExhausted("Metal failed to allocate \(allocationLength) private bytes for \(slot).")
            }
        case .sharedStaging, .sharedReadback:
            options = [.storageModeShared, .cpuCacheModeWriteCombined, .hazardTrackingModeTracked]
            guard let allocated = device.makeBuffer(length: allocationLength, options: options) else {
                throw NTRuntimeError.resourceExhausted("Metal failed to allocate \(allocationLength) shared bytes for \(slot).")
            }
            buffer = allocated
            sharedBytes &+= UInt64(allocationLength)
        }
        buffer.label = label ?? "NumiTissue.\(slot)"
        let resource = NTMetalBufferResource(
            slot: slot,
            storageClass: storageClass,
            buffer: buffer,
            logicalLength: logicalLength,
            allocatedLength: allocationLength,
            generation: generation
        )
        set(resource: resource, for: storageClass)
        if zeroed, storageClass == .sharedStaging || storageClass == .sharedReadback {
            memset(buffer.contents(), 0, allocationLength)
        }
        return resource
    }

    @discardableResult
    public func upload<T>(
        _ values: [T],
        slot: NTMetalBufferSlot,
        commandBuffer: any MTLCommandBuffer,
        label: String? = nil
    ) throws -> NTMetalBufferResource {
        let byteCount = values.count * MemoryLayout<T>.stride
        let destination = try allocate(
            slot: slot,
            logicalLength: byteCount,
            storageClass: .privatePersistent,
            label: label
        )
        let source = try allocateStaging(slot: slot, logicalLength: byteCount, label: "\(label ?? String(describing: slot)).Upload")
        if byteCount > 0 {
            values.withUnsafeBytes { bytes in
                memcpy(source.buffer.contents(), bytes.baseAddress!, byteCount)
            }
        }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw NTRuntimeError.backendUnavailable("Metal could not create a blit encoder for state upload.")
        }
        encoder.label = "NumiTissue.Upload.\(slot)"
        if byteCount > 0 {
            encoder.copy(
                from: source.buffer,
                sourceOffset: 0,
                to: destination.buffer,
                destinationOffset: 0,
                size: byteCount
            )
        }
        encoder.endEncoding()
        return destination
    }

    @discardableResult
    public func uploadBytes(
        _ data: Data,
        slot: NTMetalBufferSlot,
        commandBuffer: any MTLCommandBuffer,
        storageClass: NTMetalStorageClass = .privatePersistent,
        label: String? = nil
    ) throws -> NTMetalBufferResource {
        if storageClass == .sharedStaging || storageClass == .sharedReadback {
            let resource = try allocate(slot: slot, logicalLength: data.count, storageClass: storageClass, label: label)
            if !data.isEmpty {
                data.copyBytes(to: resource.buffer.contents().assumingMemoryBound(to: UInt8.self), count: data.count)
            }
            return resource
        }
        let destination = try allocate(slot: slot, logicalLength: data.count, storageClass: storageClass, label: label)
        let source = try allocateStaging(slot: slot, logicalLength: data.count, label: "\(label ?? String(describing: slot)).Upload")
        if !data.isEmpty {
            data.copyBytes(to: source.buffer.contents().assumingMemoryBound(to: UInt8.self), count: data.count)
        }
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw NTRuntimeError.backendUnavailable("Metal could not create a blit encoder for byte upload.")
        }
        encoder.label = "NumiTissue.UploadBytes.\(slot)"
        if !data.isEmpty {
            encoder.copy(from: source.buffer, sourceOffset: 0, to: destination.buffer, destinationOffset: 0, size: data.count)
        }
        encoder.endEncoding()
        return destination
    }

    @discardableResult
    public func scheduleReadback(
        slot: NTMetalBufferSlot,
        byteCount: Int,
        commandBuffer: any MTLCommandBuffer,
        sourceOffset: Int = 0
    ) throws -> NTMetalBufferResource {
        guard let source = resources[slot] else {
            throw NTRuntimeError.internalInvariant("No GPU resource exists for readback slot \(slot).")
        }
        guard sourceOffset >= 0, byteCount >= 0, sourceOffset + byteCount <= source.logicalLength else {
            throw NTRuntimeError.invalidConfiguration("Readback range exceeds GPU resource \(slot).")
        }
        let destination = try allocateReadback(slot: slot, logicalLength: byteCount)
        guard let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw NTRuntimeError.backendUnavailable("Metal could not create a blit encoder for readback.")
        }
        encoder.label = "NumiTissue.Readback.\(slot)"
        if byteCount > 0 {
            encoder.copy(
                from: source.buffer,
                sourceOffset: sourceOffset,
                to: destination.buffer,
                destinationOffset: 0,
                size: byteCount
            )
        }
        encoder.endEncoding()
        return destination
    }

    public func typedReadback<T>(slot: NTMetalBufferSlot, as type: T.Type, count: Int) throws -> [T] {
        guard let source = readback[slot] else {
            throw NTRuntimeError.internalInvariant("Readback for slot \(slot) was not scheduled.")
        }
        let required = count * MemoryLayout<T>.stride
        guard required <= source.logicalLength else {
            throw NTRuntimeError.internalInvariant("Typed readback exceeds staged byte count.")
        }
        guard count > 0 else { return [] }
        let pointer = source.buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    public func resetScratch() throws {
        resources = resources.filter { $0.value.storageClass != .privateScratch }
        scratchHeap?.setPurgeableState(.empty)
        scratchHeap = try Self.makePrivateHeap(
            device: device,
            bytes: UInt64(max(scratchHeap?.size ?? 0, 4 * 1_024 * 1_024)),
            label: "NumiTissue.ScratchHeap.\(generation &+ 1)"
        )
        generation &+= 1
    }

    public func removeAll() {
        resources.removeAll(keepingCapacity: false)
        staging.removeAll(keepingCapacity: false)
        readback.removeAll(keepingCapacity: false)
        persistentHeap = nil
        scratchHeap = nil
        privateFallbackBytes = 0
        sharedBytes = 0
        generation &+= 1
    }

    public func statistics() -> NTMetalArenaStatistics {
        var value = NTMetalArenaStatistics()
        value.privateHeapCapacity = UInt64((persistentHeap?.size ?? 0) + (scratchHeap?.size ?? 0))
        value.privateHeapUsed = UInt64((persistentHeap?.usedSize ?? 0) + (scratchHeap?.usedSize ?? 0))
        value.privateFallbackBytes = privateFallbackBytes
        value.sharedBytes = sharedBytes
        value.resourceCount = UInt32(resources.count + staging.count + readback.count)
        value.generation = generation
        return value
    }

    private func allocateStaging(
        slot: NTMetalBufferSlot,
        logicalLength: Int,
        label: String
    ) throws -> NTMetalBufferResource {
        if let existing = staging[slot], existing.allocatedLength >= max(logicalLength, 256) {
            return NTMetalBufferResource(
                slot: slot,
                storageClass: .sharedStaging,
                buffer: existing.buffer,
                logicalLength: logicalLength,
                allocatedLength: existing.allocatedLength,
                generation: existing.generation
            )
        }
        let resource = try allocate(
            slot: slot,
            logicalLength: logicalLength,
            storageClass: .sharedStaging,
            label: label
        )
        staging[slot] = resource
        return resource
    }

    private func allocateReadback(slot: NTMetalBufferSlot, logicalLength: Int) throws -> NTMetalBufferResource {
        if let existing = readback[slot], existing.allocatedLength >= max(logicalLength, 256) {
            return NTMetalBufferResource(
                slot: slot,
                storageClass: .sharedReadback,
                buffer: existing.buffer,
                logicalLength: logicalLength,
                allocatedLength: existing.allocatedLength,
                generation: existing.generation
            )
        }
        let resource = try allocate(
            slot: slot,
            logicalLength: logicalLength,
            storageClass: .sharedReadback,
            label: "NumiTissue.\(slot).Readback"
        )
        readback[slot] = resource
        return resource
    }

    private func resourceMap(for storageClass: NTMetalStorageClass) -> [NTMetalBufferSlot: NTMetalBufferResource] {
        switch storageClass {
        case .privatePersistent, .privateScratch: return resources
        case .sharedStaging: return staging
        case .sharedReadback: return readback
        }
    }

    private func set(resource: NTMetalBufferResource, for storageClass: NTMetalStorageClass) {
        switch storageClass {
        case .privatePersistent, .privateScratch: resources[resource.slot] = resource
        case .sharedStaging: staging[resource.slot] = resource
        case .sharedReadback: readback[resource.slot] = resource
        }
    }

    private static func makePrivateHeap(
        device: any MTLDevice,
        bytes: UInt64,
        label: String
    ) throws -> any MTLHeap {
        let descriptor = MTLHeapDescriptor()
        descriptor.storageMode = .private
        descriptor.cpuCacheMode = .defaultCache
        descriptor.hazardTrackingMode = .tracked
        descriptor.size = Int(align(Int(bytes), to: 64 * 1_024))
        guard let heap = device.makeHeap(descriptor: descriptor) else {
            throw NTRuntimeError.resourceExhausted("Metal failed to allocate private heap \(label) with \(descriptor.size) bytes.")
        }
        heap.label = label
        return heap
    }

    @inline(__always)
    private static func align(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        return (value + alignment - 1) & ~(alignment - 1)
    }
}

/// Flat GPU resource set compiled from production state and canonical topology.
public final class NTMetalStateResources: @unchecked Sendable {
    public let topologyGeneration: UInt64
    public let topologyFingerprint: UInt64
    public let resources: [NTMetalBufferSlot: NTMetalBufferResource]
    public let fieldValueCount: Int
    public let eventCapacity: Int
    public let outputSpikeCapacity: Int

    public init(
        topologyGeneration: UInt64,
        topologyFingerprint: UInt64,
        resources: [NTMetalBufferSlot: NTMetalBufferResource],
        fieldValueCount: Int,
        eventCapacity: Int,
        outputSpikeCapacity: Int
    ) {
        self.topologyGeneration = topologyGeneration
        self.topologyFingerprint = topologyFingerprint
        self.resources = resources
        self.fieldValueCount = fieldValueCount
        self.eventCapacity = eventCapacity
        self.outputSpikeCapacity = outputSpikeCapacity
    }

    public subscript(_ slot: NTMetalBufferSlot) -> NTMetalBufferResource? { resources[slot] }
}

public struct NTMetalStateUploader: Sendable {
    public init() {}

    public func upload(
        state: NTProductionState,
        topology: NTCompiledTopology,
        fieldModel: NTFieldModel,
        transaction: TransactionID,
        arena: NTMetalBufferArena,
        commandBuffer: any MTLCommandBuffer
    ) throws -> NTMetalStateResources {
        var uploaded: [NTMetalBufferSlot: NTMetalBufferResource] = [:]
        let tileIndex = Dictionary(uniqueKeysWithValues: state.tiles.enumerated().map { ($0.element.membership.id, UInt32($0.offset)) })
        var tileCells: [UInt32] = []
        var tileCompartments: [UInt32] = []
        var tileSynapses: [UInt32] = []
        var tileMicrodomains: [UInt32] = []
        var tileHeaders: [NTMetalTileHeader] = []
        tileHeaders.reserveCapacity(state.tiles.count)
        let fieldIndex = Dictionary(uniqueKeysWithValues: state.fields.enumerated().map { ($0.element.tile, Int32($0.offset)) })
        for tile in state.tiles {
            let cellStart = UInt32(tileCells.count)
            let compartmentStart = UInt32(tileCompartments.count)
            let synapseStart = UInt32(tileSynapses.count)
            let microdomainStart = UInt32(tileMicrodomains.count)
            tileCells.append(contentsOf: tile.membership.cellIndices)
            tileCompartments.append(contentsOf: tile.membership.compartmentIndices)
            tileSynapses.append(contentsOf: tile.membership.synapseIndices)
            tileMicrodomains.append(contentsOf: tile.membership.microdomainIndices)
            tileHeaders.append(.init(
                membership: tile.membership,
                cellStart: cellStart,
                compartmentStart: compartmentStart,
                synapseStart: synapseStart,
                microdomainStart: microdomainStart,
                fieldBrickIndex: fieldIndex[tile.membership.id] ?? -1
            ))
        }

        let constants = NTMetalWorldConstants(
            configuration: state.configuration,
            tileCount: state.tiles.count,
            cellCount: state.cells.count,
            compartmentCount: state.compartments.count,
            synapseCount: state.synapses.count,
            routeCount: topology.routeRecords.count,
            microdomainCount: state.microdomains.count,
            eventCapacity: max(1_048_576, state.configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, state.tiles.count)),
            time: state.time,
            transaction: transaction
        )
        uploaded[.constants] = try arena.upload([constants], slot: .constants, commandBuffer: commandBuffer)
        uploaded[.tileHeaders] = try arena.upload(tileHeaders, slot: .tileHeaders, commandBuffer: commandBuffer)
        uploaded[.tileCells] = try arena.upload(tileCells, slot: .tileCells, commandBuffer: commandBuffer)
        uploaded[.tileCompartments] = try arena.upload(tileCompartments, slot: .tileCompartments, commandBuffer: commandBuffer)
        uploaded[.tileSynapses] = try arena.upload(tileSynapses, slot: .tileSynapses, commandBuffer: commandBuffer)
        uploaded[.tileMicrodomains] = try arena.upload(tileMicrodomains, slot: .tileMicrodomains, commandBuffer: commandBuffer)

        let metalCells = state.cells.map { NTMetalCell($0, tileIndex: tileIndex[$0.record.tile] ?? NTMetalABI.invalidIndex) }
        var regulatoryState: [Float] = []
        regulatoryState.reserveCapacity(state.cells.count * 32)
        for cell in state.cells {
            var values = Array(cell.record.regulatoryState.prefix(32))
            if values.count < 32 { values.append(contentsOf: repeatElement(0, count: 32 - values.count)) }
            regulatoryState.append(contentsOf: values)
        }
        let metalCompartments = state.compartments.map { NTMetalCompartment($0, tileIndex: tileIndex[$0.record.tile] ?? NTMetalABI.invalidIndex) }
        let metalSynapses = state.synapses.map(NTMetalSynapse.init)
        let metalRoutes = topology.routeRecords.map(NTMetalRoute.init)
        var speciesStart: UInt32 = 0
        var metalMicrodomains: [NTMetalMicrodomain] = []
        var molecularSpecies: [Float] = []
        for domain in state.microdomains {
            metalMicrodomains.append(.init(
                domain,
                speciesStart: speciesStart,
                tileIndex: tileIndex[domain.tile] ?? NTMetalABI.invalidIndex
            ))
            molecularSpecies.append(contentsOf: domain.speciesAmounts)
            speciesStart &+= UInt32(domain.speciesAmounts.count)
        }

        uploaded[.cells] = try arena.upload(metalCells, slot: .cells, commandBuffer: commandBuffer)
        uploaded[.regulatoryState] = try arena.upload(regulatoryState, slot: .regulatoryState, commandBuffer: commandBuffer)
        uploaded[.compartments] = try arena.upload(metalCompartments, slot: .compartments, commandBuffer: commandBuffer)
        uploaded[.synapses] = try arena.upload(metalSynapses, slot: .synapses, commandBuffer: commandBuffer)
        uploaded[.routes] = try arena.upload(metalRoutes, slot: .routes, commandBuffer: commandBuffer)
        uploaded[.routeDestinations] = try arena.upload(topology.routeDestinationSynapseIndices, slot: .routeDestinations, commandBuffer: commandBuffer)
        uploaded[.microdomains] = try arena.upload(metalMicrodomains, slot: .microdomains, commandBuffer: commandBuffer)
        uploaded[.molecularSpecies] = try arena.upload(molecularSpecies, slot: .molecularSpecies, commandBuffer: commandBuffer)

        var fieldRead: [Float] = []
        var fieldSources: [Float] = []
        for field in state.fields {
            fieldRead.append(contentsOf: field.concentrations)
            fieldSources.append(contentsOf: field.sources)
        }
        uploaded[.fieldRead] = try arena.upload(fieldRead, slot: .fieldRead, commandBuffer: commandBuffer)
        uploaded[.fieldWrite] = try arena.allocate(
            slot: .fieldWrite,
            logicalLength: fieldRead.count * MemoryLayout<Float>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        uploaded[.fieldSources] = try arena.upload(fieldSources, slot: .fieldSources, commandBuffer: commandBuffer)
        uploaded[.fieldSpecies] = try arena.upload(fieldModel.parameters.map(NTMetalFieldSpecies.init), slot: .fieldSpecies, commandBuffer: commandBuffer)

        let activeTiles = topology.tileWorklists.map { UInt32(truncatingIfNeeded: $0.tile.rawValue) }
        let activeCompartments = topology.tileWorklists.flatMap(\.compartmentIndices)
        let activeSynapses = topology.tileWorklists.flatMap(\.synapseIndices)
        let activeMicrodomains = topology.tileWorklists.flatMap(\.microdomainIndices)
        uploaded[.activeTiles] = try arena.upload(activeTiles, slot: .activeTiles, commandBuffer: commandBuffer)
        uploaded[.activeCompartments] = try arena.upload(activeCompartments, slot: .activeCompartments, commandBuffer: commandBuffer)
        uploaded[.activeSynapses] = try arena.upload(activeSynapses, slot: .activeSynapses, commandBuffer: commandBuffer)
        uploaded[.activeMicrodomains] = try arena.upload(activeMicrodomains, slot: .activeMicrodomains, commandBuffer: commandBuffer)

        var hinesLevels: [SIMD4<UInt32>] = []
        var hinesIndices: [UInt32] = []
        for (scheduleIndex, schedule) in topology.neuronSchedules.enumerated() {
            for level in schedule.eliminationLevels {
                let start = UInt32(hinesIndices.count)
                hinesIndices.append(contentsOf: level.compartmentIndices)
                hinesLevels.append(SIMD4(UInt32(scheduleIndex), UInt32(level.level), start, UInt32(level.compartmentIndices.count)))
            }
        }
        uploaded[.hinesLevels] = try arena.upload(hinesLevels, slot: .hinesLevels, commandBuffer: commandBuffer)
        uploaded[.hinesIndices] = try arena.upload(hinesIndices, slot: .hinesIndices, commandBuffer: commandBuffer)

        uploaded[.matrixDiagonal] = try arena.allocate(
            slot: .matrixDiagonal,
            logicalLength: state.compartments.count * MemoryLayout<Float>.stride,
            storageClass: .privateScratch,
            zeroed: false
        )
        uploaded[.matrixRHS] = try arena.allocate(
            slot: .matrixRHS,
            logicalLength: state.compartments.count * MemoryLayout<Float>.stride,
            storageClass: .privateScratch,
            zeroed: false
        )
        let eventCapacity = max(1_048_576, state.configuration.resourceBudget.maximumEventsPerBlockPerTile * max(1, state.tiles.count))
        uploaded[.events] = try arena.allocate(
            slot: .events,
            logicalLength: eventCapacity * MemoryLayout<NTMetalEvent>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        uploaded[.eventCounters] = try arena.allocate(
            slot: .eventCounters,
            logicalLength: 16 * MemoryLayout<UInt32>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        uploaded[.dispatchArguments] = try arena.allocate(
            slot: .dispatchArguments,
            logicalLength: NTMetalKernel.allCases.count * MemoryLayout<NTMetalDispatchArguments>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        uploaded[.validation] = try arena.allocate(
            slot: .validation,
            logicalLength: MemoryLayout<NTMetalValidationCounters>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        let outputCapacity = max(65_536, state.compartments.count * 4)
        uploaded[.outputSpikes] = try arena.allocate(
            slot: .outputSpikes,
            logicalLength: outputCapacity * MemoryLayout<NTMetalEvent>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        uploaded[.outputCounters] = try arena.allocate(
            slot: .outputCounters,
            logicalLength: 16 * MemoryLayout<UInt32>.stride,
            storageClass: .privatePersistent,
            zeroed: false
        )
        return NTMetalStateResources(
            topologyGeneration: topology.generation,
            topologyFingerprint: topology.topologyFingerprint,
            resources: uploaded,
            fieldValueCount: fieldRead.count,
            eventCapacity: eventCapacity,
            outputSpikeCapacity: outputCapacity
        )
    }
}

#else

public enum NTMetalStorageClass: UInt8, Sendable {
    case privatePersistent
    case privateScratch
    case sharedStaging
    case sharedReadback
}

public struct NTMetalArenaStatistics: Sendable {
    public init() {}
}

#endif
