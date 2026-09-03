#if canImport(Metal)
import Foundation
import Metal
import NumiTissueIO

@frozen
public struct MetalMechanismBuiltinSlots: Sendable {
    public var voltage: UInt32
    public var dt: UInt32
    public var time: UInt32
    public var celsius: UInt32

    public init(voltage: UInt32 = UInt32.max, dt: UInt32 = UInt32.max, time: UInt32 = UInt32.max, celsius: UInt32 = UInt32.max) {
        self.voltage = voltage
        self.dt = dt
        self.time = time
        self.celsius = celsius
    }
}

public struct MetalMechanismExecutionReport: Sendable {
    public var state: [Float]
    public var statuses: [MetalMechanismExecutionStatus]
    public var events: [[MetalMechanismEvent]]

    public init(state: [Float], statuses: [MetalMechanismExecutionStatus], events: [[MetalMechanismEvent]]) {
        self.state = state
        self.statuses = statuses
        self.events = events
    }

    public var firstFault: (instance: Int, code: UInt32)? {
        for (index, status) in statuses.enumerated() where status.faultCode != 0 { return (index, status.faultCode) }
        return nil
    }
}

public actor MetalMechanismExecutor {
    public enum Mode: UInt32, Sendable { case initialize = 0, step = 1 }

    public let device: MTLDevice
    public let archive: MetalMechanismArchive
    public let maximumEventsPerInstance: Int
    public let instructionBudget: Int

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let programBuffer: MTLBuffer
    private let instructionBuffer: MTLBuffer
    private let constantBuffer: MTLBuffer
    private let routineBuffer: MTLBuffer
    private let routineSlotBuffer: MTLBuffer
    private let integratorBuffer: MTLBuffer
    private let builtinSlotBuffer: MTLBuffer

    private var instanceBuffer: MTLBuffer?
    private var inputBuffer: MTLBuffer?
    private var stateBuffer: MTLBuffer?
    private var eventBuffer: MTLBuffer?
    private var statusBuffer: MTLBuffer?
    private var instances = MetalMechanismInstanceSet(descriptors: [], state: [], inputs: [])

    public init(
        device: MTLDevice,
        archive: MetalMechanismArchive,
        maximumEventsPerInstance: Int = 8,
        instructionBudget: Int = 100_000,
        shaderSource: String? = nil
    ) throws {
        guard maximumEventsPerInstance > 0, maximumEventsPerInstance <= 256 else { throw MetalMechanismExecutorError.invalidEventCapacity }
        guard instructionBudget > 0 else { throw MetalMechanismExecutorError.invalidInstructionBudget }
        guard let commandQueue = device.makeCommandQueue() else { throw MetalMechanismExecutorError.commandQueue }
        try MetalMechanismABI.validateHostLayout()

        let source = try shaderSource ?? Self.loadShaderSource()
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "nt_mechanism_execute") else { throw MetalMechanismExecutorError.missingKernel }
        let pipeline = try device.makeComputePipelineState(function: function)

        self.device = device
        self.archive = archive
        self.maximumEventsPerInstance = maximumEventsPerInstance
        self.instructionBudget = instructionBudget
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.programBuffer = try Self.makeBuffer(device: device, values: archive.programs, label: "NumiTissue.Mechanism.Programs")
        self.instructionBuffer = try Self.makeBuffer(device: device, values: archive.instructions, label: "NumiTissue.Mechanism.Instructions")
        self.constantBuffer = try Self.makeBuffer(device: device, values: archive.constants, label: "NumiTissue.Mechanism.Constants")
        self.routineBuffer = try Self.makeBuffer(device: device, values: archive.routines, label: "NumiTissue.Mechanism.Routines")
        self.routineSlotBuffer = try Self.makeBuffer(device: device, values: archive.routineSlots, label: "NumiTissue.Mechanism.RoutineSlots")
        self.integratorBuffer = try Self.makeBuffer(device: device, values: archive.integrators, label: "NumiTissue.Mechanism.Integrators")
        let builtinSlots = archive.sourcePrograms.map(Self.builtinSlots)
        self.builtinSlotBuffer = try Self.makeBuffer(device: device, values: builtinSlots, label: "NumiTissue.Mechanism.BuiltinSlots")
    }

    public func load(_ instances: MetalMechanismInstanceSet) throws {
        guard instances.descriptors.count == instances.inputs.count else { throw MetalMechanismExecutorError.instanceMetadataCount }
        for descriptor in instances.descriptors {
            guard Int(descriptor.programIndex) < archive.programs.count else { throw MetalMechanismExecutorError.invalidProgramIndex(Int(descriptor.programIndex)) }
            let stride = Int(archive.programs[Int(descriptor.programIndex)].stateStride)
            guard Int(descriptor.stateOffset) + stride <= instances.state.count else { throw MetalMechanismExecutorError.stateRange }
        }
        self.instances = instances
        instanceBuffer = try Self.makeBuffer(device: device, values: instances.descriptors, label: "NumiTissue.Mechanism.Instances")
        inputBuffer = try Self.makeBuffer(device: device, values: instances.inputs, label: "NumiTissue.Mechanism.Inputs")
        stateBuffer = try Self.makeBuffer(device: device, values: instances.state, label: "NumiTissue.Mechanism.State")
        eventBuffer = try Self.makeBuffer(
            device: device,
            count: max(instances.count * maximumEventsPerInstance, 1),
            as: MetalMechanismEvent.self,
            label: "NumiTissue.Mechanism.Events"
        )
        statusBuffer = try Self.makeBuffer(
            device: device,
            count: max(instances.count, 1),
            as: MetalMechanismExecutionStatus.self,
            label: "NumiTissue.Mechanism.Status"
        )
    }

    public func replaceInputs(_ inputs: [MetalMechanismInstanceInput]) throws {
        guard inputs.count == instances.count, let inputBuffer else { throw MetalMechanismExecutorError.instanceMetadataCount }
        instances.inputs = inputs
        try Self.write(inputs, to: inputBuffer)
    }

    public func updateInput(instance index: Int, _ input: MetalMechanismInstanceInput) throws {
        guard instances.inputs.indices.contains(index), let inputBuffer else { throw MetalMechanismExecutorError.invalidInstanceIndex(index) }
        instances.inputs[index] = input
        let offset = index * MemoryLayout<MetalMechanismInstanceInput>.stride
        _ = withUnsafeBytes(of: input) { bytes in
            memcpy(inputBuffer.contents().advanced(by: offset), bytes.baseAddress!, bytes.count)
        }
    }

    public func initialize(failOnFault: Bool = true) async throws -> MetalMechanismExecutionReport {
        try await execute(mode: .initialize, failOnFault: failOnFault)
    }

    public func step(failOnFault: Bool = true) async throws -> MetalMechanismExecutionReport {
        try await execute(mode: .step, failOnFault: failOnFault)
    }

    public func exportState() throws -> [Float] {
        guard let stateBuffer else { throw MetalMechanismExecutorError.notLoaded }
        return Self.readArray(from: stateBuffer, count: instances.state.count, as: Float.self)
    }

    private func execute(mode: Mode, failOnFault: Bool) async throws -> MetalMechanismExecutionReport {
        guard instances.count > 0,
              let instanceBuffer,
              let inputBuffer,
              let stateBuffer,
              let eventBuffer,
              let statusBuffer else { throw MetalMechanismExecutorError.notLoaded }

        memset(eventBuffer.contents(), 0, eventBuffer.length)
        memset(statusBuffer.contents(), 0, statusBuffer.length)
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalMechanismExecutorError.commandEncoding }
        commandBuffer.label = "NumiTissue Mechanism \(mode == .initialize ? "Initialize" : "Step")"
        encoder.label = commandBuffer.label
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(programBuffer, offset: 0, index: 0)
        encoder.setBuffer(instructionBuffer, offset: 0, index: 1)
        encoder.setBuffer(constantBuffer, offset: 0, index: 2)
        encoder.setBuffer(routineBuffer, offset: 0, index: 3)
        encoder.setBuffer(routineSlotBuffer, offset: 0, index: 4)
        encoder.setBuffer(integratorBuffer, offset: 0, index: 5)
        encoder.setBuffer(builtinSlotBuffer, offset: 0, index: 6)
        encoder.setBuffer(instanceBuffer, offset: 0, index: 7)
        encoder.setBuffer(inputBuffer, offset: 0, index: 8)
        encoder.setBuffer(stateBuffer, offset: 0, index: 9)
        encoder.setBuffer(eventBuffer, offset: 0, index: 10)
        encoder.setBuffer(statusBuffer, offset: 0, index: 11)
        var parameters = MetalMechanismExecutionParameters(
            voltageMillivolts: 0,
            dtMilliseconds: 0,
            timeMilliseconds: 0,
            celsius: 0,
            instanceCount: UInt32(clamping: instances.count),
            maximumEventsPerInstance: UInt32(maximumEventsPerInstance),
            instructionBudget: UInt32(clamping: instructionBudget),
            mode: mode.rawValue
        )
        encoder.setBytes(&parameters, length: MemoryLayout<MetalMechanismExecutionParameters>.stride, index: 12)
        let width = min(max(pipeline.threadExecutionWidth, 1), max(pipeline.maxTotalThreadsPerThreadgroup, 1))
        encoder.dispatchThreads(
            MTLSize(width: instances.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        try await complete(commandBuffer)

        let state = Self.readArray(from: stateBuffer, count: instances.state.count, as: Float.self)
        let statuses = Self.readArray(from: statusBuffer, count: instances.count, as: MetalMechanismExecutionStatus.self)
        let flatEvents = Self.readArray(
            from: eventBuffer,
            count: instances.count * maximumEventsPerInstance,
            as: MetalMechanismEvent.self
        )
        let events = statuses.enumerated().map { index, status -> [MetalMechanismEvent] in
            let count = min(Int(status.eventCount), maximumEventsPerInstance)
            let lower = index * maximumEventsPerInstance
            return count == 0 ? [] : Array(flatEvents[lower..<(lower + count)])
        }
        instances.state = state
        let report = MetalMechanismExecutionReport(state: state, statuses: statuses, events: events)
        if failOnFault, let first = report.firstFault {
            throw MetalMechanismExecutorError.executionFault(instance: first.instance, code: first.code)
        }
        return report
    }

    private static func builtinSlots(_ source: CompiledMechanismProgramIR) -> MetalMechanismBuiltinSlots {
        let variables = Dictionary(uniqueKeysWithValues: source.variables.map { ($0.name, $0.offset) })
        return MetalMechanismBuiltinSlots(
            voltage: variables["v"] ?? UInt32.max,
            dt: variables["dt"] ?? UInt32.max,
            time: variables["t"] ?? UInt32.max,
            celsius: variables["celsius"] ?? UInt32.max
        )
    }

    private static func loadShaderSource() throws -> String {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "NumiTissueMechanismVM", withExtension: "metal", subdirectory: "Shaders")
            ?? bundle.url(forResource: "NumiTissueMechanismVM", withExtension: "metal")
        guard let url else { throw MetalMechanismExecutorError.missingShaderResource }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T], label: String) throws -> MTLBuffer {
        let byteCount = values.count * MemoryLayout<T>.stride
        guard let buffer = device.makeBuffer(length: max(byteCount, MemoryLayout<T>.stride), options: .storageModeShared) else {
            throw MetalMechanismExecutorError.bufferAllocation(label)
        }
        buffer.label = label
        if !values.isEmpty { try write(values, to: buffer) }
        return buffer
    }

    private static func makeBuffer<T>(device: MTLDevice, count: Int, as type: T.Type, label: String) throws -> MTLBuffer {
        guard let buffer = device.makeBuffer(length: max(count * MemoryLayout<T>.stride, MemoryLayout<T>.stride), options: .storageModeShared) else {
            throw MetalMechanismExecutorError.bufferAllocation(label)
        }
        buffer.label = label
        memset(buffer.contents(), 0, buffer.length)
        return buffer
    }

    private static func write<T>(_ values: [T], to buffer: MTLBuffer) throws {
        let byteCount = values.count * MemoryLayout<T>.stride
        guard byteCount <= buffer.length else { throw MetalMechanismExecutorError.bufferOverflow }
        values.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress, byteCount > 0 { memcpy(buffer.contents(), address, byteCount) }
        }
    }

    private static func readArray<T>(from buffer: MTLBuffer, count: Int, as type: T.Type) -> [T] {
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func complete(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { continuation in
            commandBuffer.addCompletedHandler { buffer in
                if buffer.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: MetalMechanismExecutorError.commandFailed(buffer.error?.localizedDescription ?? "unknown Metal error")) }
            }
            commandBuffer.commit()
        }
    }
}

public enum MetalMechanismExecutorError: Error, Sendable, CustomStringConvertible {
    case invalidEventCapacity
    case invalidInstructionBudget
    case commandQueue
    case commandEncoding
    case commandFailed(String)
    case missingShaderResource
    case missingKernel
    case bufferAllocation(String)
    case bufferOverflow
    case instanceMetadataCount
    case invalidProgramIndex(Int)
    case invalidInstanceIndex(Int)
    case stateRange
    case notLoaded
    case executionFault(instance: Int, code: UInt32)

    public var description: String {
        switch self {
        case .invalidEventCapacity: return "Mechanism event capacity must be in 1...256"
        case .invalidInstructionBudget: return "Mechanism instruction budget must be positive"
        case .commandQueue: return "Metal command queue could not be created"
        case .commandEncoding: return "Metal mechanism command could not be encoded"
        case .commandFailed(let value): return "Metal mechanism command failed: \(value)"
        case .missingShaderResource: return "NumiTissueMechanismVM.metal is missing from package resources"
        case .missingKernel: return "nt_mechanism_execute was not found in the Metal library"
        case .bufferAllocation(let value): return "Could not allocate Metal buffer \(value)"
        case .bufferOverflow: return "Metal mechanism buffer write would overflow"
        case .instanceMetadataCount: return "Mechanism instance metadata counts disagree"
        case .invalidProgramIndex(let value): return "Invalid mechanism program index \(value)"
        case .invalidInstanceIndex(let value): return "Invalid mechanism instance index \(value)"
        case .stateRange: return "Mechanism instance state range is invalid"
        case .notLoaded: return "No mechanism instances are loaded"
        case .executionFault(let instance, let code): return "Mechanism instance \(instance) returned Metal fault \(code)"
        }
    }
}
#endif
