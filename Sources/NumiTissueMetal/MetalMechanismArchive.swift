#if canImport(Metal)
import Foundation
import NumiTissueIO

@frozen
public struct MetalMechanismInstanceInput: Sendable, Hashable, Codable {
    public var values: SIMD4<Float>

    public init(voltageMillivolts: Float, dtMilliseconds: Float, timeMilliseconds: Float, celsius: Float = 34) {
        values = SIMD4(voltageMillivolts, dtMilliseconds, timeMilliseconds, celsius)
    }
}

public struct MetalMechanismArchive: Sendable {
    public var programs: [MetalMechanismProgramDescriptor]
    public var instructions: [MetalMechanismInstructionABI]
    public var constants: [Float]
    public var routines: [MetalMechanismRoutineDescriptor]
    public var routineSlots: [UInt32]
    public var integrators: [MetalMechanismIntegratorDescriptor]
    public var sourcePrograms: [CompiledMechanismProgramIR]

    public init(compiling sourcePrograms: [CompiledMechanismProgramIR]) throws {
        guard !sourcePrograms.isEmpty else { throw MetalMechanismArchiveError.empty }
        self.programs = []
        self.instructions = []
        self.constants = []
        self.routines = []
        self.routineSlots = []
        self.integrators = []
        self.sourcePrograms = []

        try MetalMechanismABI.validateHostLayout()
        self.programs.reserveCapacity(sourcePrograms.count)
        self.sourcePrograms.reserveCapacity(sourcePrograms.count)
        for source in sourcePrograms {
            try append(try source.validated())
        }
    }

    public var programCount: Int { programs.count }

    public func programIndex(named name: String) -> Int? {
        sourcePrograms.firstIndex { $0.name == name }
    }

    public func makeInstances(
        programIndices: [Int],
        compartmentIndices: [UInt32]? = nil,
        inputs: [MetalMechanismInstanceInput]? = nil
    ) throws -> MetalMechanismInstanceSet {
        if let compartmentIndices, compartmentIndices.count != programIndices.count {
            throw MetalMechanismArchiveError.instanceMetadataCount
        }
        if let inputs, inputs.count != programIndices.count {
            throw MetalMechanismArchiveError.instanceMetadataCount
        }

        var descriptors: [MetalMechanismInstanceDescriptor] = []
        var state: [Float] = []
        var resolvedInputs: [MetalMechanismInstanceInput] = []
        descriptors.reserveCapacity(programIndices.count)
        resolvedInputs.reserveCapacity(programIndices.count)

        for (instanceIndex, programIndex) in programIndices.enumerated() {
            guard programIndex >= 0, programIndex < programs.count else {
                throw MetalMechanismArchiveError.invalidProgramIndex(programIndex)
            }
            let source = sourcePrograms[programIndex]
            let descriptor = programs[programIndex]
            let stateOffset = UInt32(clamping: state.count)
            state.append(contentsOf: repeatElement(0, count: Int(descriptor.stateStride)))
            for variable in source.variables {
                guard Int(variable.offset) < Int(descriptor.stateStride) else {
                    throw MetalMechanismArchiveError.variableOutsideState(variable.name)
                }
                for element in 0..<Int(variable.count) {
                    state[Int(stateOffset) + Int(variable.offset) + element] = variable.defaultValue
                }
            }
            descriptors.append(MetalMechanismInstanceDescriptor(
                programIndex: UInt32(programIndex),
                stateOffset: stateOffset,
                compartmentIndex: compartmentIndices?[instanceIndex] ?? UInt32.max
            ))
            resolvedInputs.append(inputs?[instanceIndex] ?? MetalMechanismInstanceInput(
                voltageMillivolts: -65,
                dtMilliseconds: 0.025,
                timeMilliseconds: 0
            ))
        }
        return MetalMechanismInstanceSet(descriptors: descriptors, state: state, inputs: resolvedInputs)
    }

    private mutating func append(_ source: CompiledMechanismProgramIR) throws {
        guard source.maximumStackDepth <= MetalMechanismABI.maximumStackDepth else {
            throw MetalMechanismArchiveError.stackDepth(Int(source.maximumStackDepth))
        }
        guard source.maximumCallDepth <= MetalMechanismABI.maximumCallDepth else {
            throw MetalMechanismArchiveError.callDepth(Int(source.maximumCallDepth))
        }

        let instructionBase = UInt32(clamping: instructions.count)
        let constantBase = UInt32(clamping: constants.count)
        let routineBase = UInt32(clamping: routines.count)
        let routineSlotBase = UInt32(clamping: routineSlots.count)
        let integratorBase = UInt32(clamping: integrators.count)

        constants.append(contentsOf: source.constants)
        for instruction in source.instructions {
            var adjusted = instruction
            switch adjusted.opcode {
            case .pushConstant:
                adjusted.operandA &+= constantBase
            case .call, .solve:
                adjusted.operandA &+= routineBase
            case .jump, .jumpIfZero:
                adjusted.operandA &+= instructionBase
            default: break
            }
            instructions.append(MetalMechanismInstructionABI(adjusted))
        }

        var requiredStateStride = Int(source.stateStride)
        for routine in source.routines {
            let slotOffset = UInt32(clamping: routineSlots.count)
            routineSlots.append(contentsOf: routine.argumentOffsets)
            routineSlots.append(contentsOf: routine.localOffsets)
            for slot in routine.argumentOffsets + routine.localOffsets {
                requiredStateStride = max(requiredStateStride, Int(slot) + 1)
            }
            routines.append(MetalMechanismRoutineDescriptor(
                instructionOffset: instructionBase + routine.instructionOffset,
                instructionCount: routine.instructionCount,
                slotOffset: slotOffset,
                argumentCount: UInt32(clamping: routine.argumentOffsets.count),
                localCount: UInt32(clamping: routine.localOffsets.count),
                kind: routineKindCode(routine.kind),
                maximumStackDepth: UInt32(routine.maximumStackDepth)
            ))
        }
        for integrator in source.integrators {
            requiredStateStride = max(requiredStateStride, Int(integrator.stateOffset) + 1, Int(integrator.derivativeOffset) + 1)
            integrators.append(MetalMechanismIntegratorDescriptor(
                stateOffset: integrator.stateOffset,
                derivativeOffset: integrator.derivativeOffset,
                method: solveMethodCode(integrator.method),
                routineIndex: routineBase + UInt32(integrator.derivativeRoutineIndex)
            ))
        }
        guard requiredStateStride <= 4_096 else {
            throw MetalMechanismArchiveError.stateStride(requiredStateStride)
        }

        programs.append(MetalMechanismProgramDescriptor(
            instructionOffset: instructionBase,
            instructionCount: UInt32(clamping: source.instructions.count),
            constantOffset: constantBase,
            constantCount: UInt32(clamping: source.constants.count),
            routineOffset: routineBase,
            routineCount: UInt32(clamping: source.routines.count),
            routineSlotOffset: routineSlotBase,
            routineSlotCount: UInt32(clamping: routineSlots.count) - routineSlotBase,
            integratorOffset: integratorBase,
            integratorCount: UInt32(clamping: source.integrators.count),
            stateStride: UInt32(requiredStateStride),
            maximumStackDepth: UInt32(source.maximumStackDepth),
            initialOffset: instructionBase + source.entries.initial.lowerBound,
            initialCount: source.entries.initial.upperBound - source.entries.initial.lowerBound,
            breakpointOffset: instructionBase + source.entries.breakpoint.lowerBound,
            breakpointCount: source.entries.breakpoint.upperBound - source.entries.breakpoint.lowerBound,
            beforeStepOffset: instructionBase + source.entries.beforeStep.lowerBound,
            beforeStepCount: source.entries.beforeStep.upperBound - source.entries.beforeStep.lowerBound,
            afterStepOffset: instructionBase + source.entries.afterStep.lowerBound,
            afterStepCount: source.entries.afterStep.upperBound - source.entries.afterStep.lowerBound,
            maximumCallDepth: UInt32(source.maximumCallDepth),
            sourceHash: source.sourceHash
        ))
        self.sourcePrograms.append(source)
    }

    private func routineKindCode(_ kind: MechanismRoutineKindIR) -> UInt32 {
        switch kind {
        case .procedure: return 0
        case .function: return 1
        case .derivative: return 2
        case .kinetic: return 3
        case .linear: return 4
        case .nonlinear: return 5
        case .discrete: return 6
        case .netReceive: return 7
        }
    }

    private func solveMethodCode(_ method: MechanismSolveMethodIR) -> UInt32 {
        switch method {
        case .unknown: return 0
        case .cnexp: return 1
        case .derivimplicit: return 2
        case .sparse: return 3
        case .afterCVode: return 4
        case .direct: return 5
        case .euler: return 6
        }
    }
}

public struct MetalMechanismInstanceSet: Sendable {
    public var descriptors: [MetalMechanismInstanceDescriptor]
    public var state: [Float]
    public var inputs: [MetalMechanismInstanceInput]

    public init(descriptors: [MetalMechanismInstanceDescriptor], state: [Float], inputs: [MetalMechanismInstanceInput]) {
        self.descriptors = descriptors
        self.state = state
        self.inputs = inputs
    }

    public var count: Int { descriptors.count }

    public mutating func updateInput(
        instance: Int,
        voltageMillivolts: Float,
        dtMilliseconds: Float,
        timeMilliseconds: Float,
        celsius: Float
    ) throws {
        guard inputs.indices.contains(instance) else { throw MetalMechanismArchiveError.invalidInstanceIndex(instance) }
        inputs[instance] = MetalMechanismInstanceInput(
            voltageMillivolts: voltageMillivolts,
            dtMilliseconds: dtMilliseconds,
            timeMilliseconds: timeMilliseconds,
            celsius: celsius
        )
    }
}

public enum MetalMechanismArchiveError: Error, Sendable, CustomStringConvertible {
    case empty
    case invalidProgramIndex(Int)
    case invalidInstanceIndex(Int)
    case instanceMetadataCount
    case variableOutsideState(String)
    case stackDepth(Int)
    case callDepth(Int)
    case stateStride(Int)

    public var description: String {
        switch self {
        case .empty: return "Metal mechanism archive is empty"
        case .invalidProgramIndex(let value): return "Invalid mechanism program index \(value)"
        case .invalidInstanceIndex(let value): return "Invalid mechanism instance index \(value)"
        case .instanceMetadataCount: return "Mechanism instance metadata counts disagree"
        case .variableOutsideState(let value): return "Mechanism variable \(value) lies outside its state allocation"
        case .stackDepth(let value): return "Mechanism stack depth \(value) exceeds the Metal ABI"
        case .callDepth(let value): return "Mechanism call depth \(value) exceeds the Metal ABI"
        case .stateStride(let value): return "Mechanism state stride \(value) exceeds 4096 values"
        }
    }
}
#endif
