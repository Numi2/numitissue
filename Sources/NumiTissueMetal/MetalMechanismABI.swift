#if canImport(Metal)
import Foundation
import Metal
import NumiTissueIO

@frozen
public struct MetalMechanismInstructionABI: Sendable {
    public var opcode: UInt16
    public var flags: UInt16
    public var operandA: UInt32
    public var operandB: UInt32
    public var immediate: Float

    public init(_ instruction: MechanismInstruction) {
        opcode = instruction.opcode.rawValue
        flags = instruction.flags
        operandA = instruction.operandA
        operandB = instruction.operandB
        immediate = instruction.immediate
    }
}

@frozen
public struct MetalMechanismProgramDescriptor: Sendable {
    public var instructionOffset: UInt32
    public var instructionCount: UInt32
    public var constantOffset: UInt32
    public var constantCount: UInt32

    public var routineOffset: UInt32
    public var routineCount: UInt32
    public var routineSlotOffset: UInt32
    public var routineSlotCount: UInt32

    public var integratorOffset: UInt32
    public var integratorCount: UInt32
    public var stateStride: UInt32
    public var maximumStackDepth: UInt32

    public var initialOffset: UInt32
    public var initialCount: UInt32
    public var breakpointOffset: UInt32
    public var breakpointCount: UInt32

    public var beforeStepOffset: UInt32
    public var beforeStepCount: UInt32
    public var afterStepOffset: UInt32
    public var afterStepCount: UInt32

    public var maximumCallDepth: UInt32
    public var sourceHashLo: UInt32
    public var sourceHashHi: UInt32
    public var flags: UInt32

    public init(
        instructionOffset: UInt32,
        instructionCount: UInt32,
        constantOffset: UInt32,
        constantCount: UInt32,
        routineOffset: UInt32,
        routineCount: UInt32,
        routineSlotOffset: UInt32,
        routineSlotCount: UInt32,
        integratorOffset: UInt32,
        integratorCount: UInt32,
        stateStride: UInt32,
        maximumStackDepth: UInt32,
        initialOffset: UInt32,
        initialCount: UInt32,
        breakpointOffset: UInt32,
        breakpointCount: UInt32,
        beforeStepOffset: UInt32,
        beforeStepCount: UInt32,
        afterStepOffset: UInt32,
        afterStepCount: UInt32,
        maximumCallDepth: UInt32,
        sourceHash: UInt64,
        flags: UInt32 = 0
    ) {
        self.instructionOffset = instructionOffset
        self.instructionCount = instructionCount
        self.constantOffset = constantOffset
        self.constantCount = constantCount
        self.routineOffset = routineOffset
        self.routineCount = routineCount
        self.routineSlotOffset = routineSlotOffset
        self.routineSlotCount = routineSlotCount
        self.integratorOffset = integratorOffset
        self.integratorCount = integratorCount
        self.stateStride = stateStride
        self.maximumStackDepth = maximumStackDepth
        self.initialOffset = initialOffset
        self.initialCount = initialCount
        self.breakpointOffset = breakpointOffset
        self.breakpointCount = breakpointCount
        self.beforeStepOffset = beforeStepOffset
        self.beforeStepCount = beforeStepCount
        self.afterStepOffset = afterStepOffset
        self.afterStepCount = afterStepCount
        self.maximumCallDepth = maximumCallDepth
        self.sourceHashLo = UInt32(truncatingIfNeeded: sourceHash)
        self.sourceHashHi = UInt32(truncatingIfNeeded: sourceHash >> 32)
        self.flags = flags
    }
}

@frozen
public struct MetalMechanismRoutineDescriptor: Sendable {
    public var instructionOffset: UInt32
    public var instructionCount: UInt32
    public var slotOffset: UInt32
    public var argumentCount: UInt32
    public var localCount: UInt32
    public var kind: UInt32
    public var maximumStackDepth: UInt32
    public var flags: UInt32

    public init(
        instructionOffset: UInt32,
        instructionCount: UInt32,
        slotOffset: UInt32,
        argumentCount: UInt32,
        localCount: UInt32,
        kind: UInt32,
        maximumStackDepth: UInt32,
        flags: UInt32 = 0
    ) {
        self.instructionOffset = instructionOffset
        self.instructionCount = instructionCount
        self.slotOffset = slotOffset
        self.argumentCount = argumentCount
        self.localCount = localCount
        self.kind = kind
        self.maximumStackDepth = maximumStackDepth
        self.flags = flags
    }
}

@frozen
public struct MetalMechanismIntegratorDescriptor: Sendable {
    public var stateOffset: UInt32
    public var derivativeOffset: UInt32
    public var method: UInt32
    public var routineIndex: UInt32

    public init(stateOffset: UInt32, derivativeOffset: UInt32, method: UInt32, routineIndex: UInt32) {
        self.stateOffset = stateOffset
        self.derivativeOffset = derivativeOffset
        self.method = method
        self.routineIndex = routineIndex
    }
}

@frozen
public struct MetalMechanismInstanceDescriptor: Sendable {
    public var programIndex: UInt32
    public var stateOffset: UInt32
    public var compartmentIndex: UInt32
    public var flags: UInt32

    public init(programIndex: UInt32, stateOffset: UInt32, compartmentIndex: UInt32, flags: UInt32 = 0) {
        self.programIndex = programIndex
        self.stateOffset = stateOffset
        self.compartmentIndex = compartmentIndex
        self.flags = flags
    }
}

@frozen
public struct MetalMechanismExecutionParameters: Sendable {
    public var timing: SIMD4<Float>
    public var counts: SIMD4<UInt32>

    public init(
        voltageMillivolts: Float,
        dtMilliseconds: Float,
        timeMilliseconds: Float,
        celsius: Float,
        instanceCount: UInt32,
        maximumEventsPerInstance: UInt32,
        instructionBudget: UInt32,
        mode: UInt32
    ) {
        timing = SIMD4(voltageMillivolts, dtMilliseconds, timeMilliseconds, celsius)
        counts = SIMD4(instanceCount, maximumEventsPerInstance, instructionBudget, mode)
    }
}

@frozen
public struct MetalMechanismEvent: Sendable, Hashable, Codable {
    public var kind: UInt32
    public var flag: Int32
    public var instanceIndex: UInt32
    public var reserved: UInt32
    public var value: Float
    public var timeFraction: Float
    public var reserved2: Float
    public var reserved3: Float

    public init(kind: UInt32 = 0, flag: Int32 = 0, instanceIndex: UInt32 = 0, value: Float = 0, timeFraction: Float = 0) {
        self.kind = kind
        self.flag = flag
        self.instanceIndex = instanceIndex
        self.reserved = 0
        self.value = value
        self.timeFraction = timeFraction
        self.reserved2 = 0
        self.reserved3 = 0
    }
}

@frozen
public struct MetalMechanismExecutionStatus: Sendable, Hashable, Codable {
    public var faultCode: UInt32
    public var instructionCount: UInt32
    public var eventCount: UInt32
    public var reserved: UInt32

    public init(faultCode: UInt32 = 0, instructionCount: UInt32 = 0, eventCount: UInt32 = 0) {
        self.faultCode = faultCode
        self.instructionCount = instructionCount
        self.eventCount = eventCount
        self.reserved = 0
    }
}

public enum MetalMechanismABI {
    public static let maximumStackDepth = 128
    public static let maximumCallDepth = 8

    public static func validateHostLayout() throws {
        guard MemoryLayout<MetalMechanismInstructionABI>.stride == 16 else { throw MetalMechanismABIError.layout("instruction") }
        guard MemoryLayout<MetalMechanismProgramDescriptor>.stride == 96 else { throw MetalMechanismABIError.layout("program") }
        guard MemoryLayout<MetalMechanismRoutineDescriptor>.stride == 32 else { throw MetalMechanismABIError.layout("routine") }
        guard MemoryLayout<MetalMechanismIntegratorDescriptor>.stride == 16 else { throw MetalMechanismABIError.layout("integrator") }
        guard MemoryLayout<MetalMechanismInstanceDescriptor>.stride == 16 else { throw MetalMechanismABIError.layout("instance") }
        guard MemoryLayout<MetalMechanismExecutionParameters>.stride == 32 else { throw MetalMechanismABIError.layout("parameters") }
        guard MemoryLayout<MetalMechanismEvent>.stride == 32 else { throw MetalMechanismABIError.layout("event") }
        guard MemoryLayout<MetalMechanismExecutionStatus>.stride == 16 else { throw MetalMechanismABIError.layout("status") }
    }
}

public enum MetalMechanismABIError: Error, Sendable, CustomStringConvertible {
    case layout(String)

    public var description: String {
        switch self { case .layout(let type): return "Host and Metal mechanism ABI disagree for \(type)" }
    }
}
#endif
