import Foundation
import NumiTissueIO

public struct MechanismVMEvent: Sendable, Hashable, Codable {
    public var kind: UInt16
    public var flag: Int32
    public var value: Double

    public init(kind: UInt16, flag: Int32 = 0, value: Double = 0) {
        self.kind = kind
        self.flag = flag
        self.value = value
    }
}

public struct MechanismVMExecutionResult: Sendable, Hashable, Codable {
    public var events: [MechanismVMEvent]
    public var instructionCount: UInt64
    public var numericalFault: String?

    public init(events: [MechanismVMEvent] = [], instructionCount: UInt64 = 0, numericalFault: String? = nil) {
        self.events = events
        self.instructionCount = instructionCount
        self.numericalFault = numericalFault
    }
}

public struct CPUReferenceMechanismVM: Sendable {
    public var program: CompiledMechanismProgramIR
    public var maximumInstructionsPerEntry: Int

    public init(program: CompiledMechanismProgramIR, maximumInstructionsPerEntry: Int = 100_000) throws {
        self.program = try program.validated()
        self.maximumInstructionsPerEntry = maximumInstructionsPerEntry
    }

    public func makeInitialState() -> [Double] {
        var values = Array(repeating: 0.0, count: Int(program.stateStride))
        for variable in program.variables {
            let count = Int(variable.count)
            for offset in 0..<count where Int(variable.offset) + offset < values.count {
                values[Int(variable.offset) + offset] = Double(variable.defaultValue)
            }
        }
        return values
    }

    @discardableResult
    public func initialize(state: inout [Double]) throws -> MechanismVMExecutionResult {
        try ensureState(&state)
        var result = MechanismVMExecutionResult()
        _ = try execute(range: program.entries.initial, state: &state, result: &result, depth: 0)
        try ensureFinite(state)
        return result
    }

    @discardableResult
    public func step(
        state: inout [Double],
        voltageMillivolts: Double,
        dtMilliseconds: Double,
        timeMilliseconds: Double,
        celsius: Double
    ) throws -> MechanismVMExecutionResult {
        try ensureState(&state)
        assignIfPresent("v", value: voltageMillivolts, state: &state)
        assignIfPresent("dt", value: dtMilliseconds, state: &state)
        assignIfPresent("t", value: timeMilliseconds, state: &state)
        assignIfPresent("celsius", value: celsius, state: &state)
        var result = MechanismVMExecutionResult()
        _ = try execute(range: program.entries.beforeStep, state: &state, result: &result, depth: 0)
        _ = try execute(range: program.entries.breakpoint, state: &state, result: &result, depth: 0)
        _ = try execute(range: program.entries.afterStep, state: &state, result: &result, depth: 0)
        try enforceBounds(state: &state)
        try ensureFinite(state)
        return result
    }

    private func execute(
        range: Range<UInt32>,
        state: inout [Double],
        result: inout MechanismVMExecutionResult,
        depth: Int
    ) throws -> Double? {
        guard depth <= Int(program.maximumCallDepth) else { throw MechanismVMError.callDepthExceeded }
        var pc = Int(range.lowerBound)
        let end = min(Int(range.upperBound), program.instructions.count)
        var stack: [Double] = []
        stack.reserveCapacity(Int(program.maximumStackDepth))
        while pc < end {
            guard result.instructionCount < UInt64(maximumInstructionsPerEntry) else { throw MechanismVMError.instructionBudgetExceeded }
            result.instructionCount &+= 1
            let instruction = program.instructions[pc]
            pc += 1
            switch instruction.opcode {
            case .noOperation: continue
            case .pushConstant:
                guard Int(instruction.operandA) < program.constants.count else { throw MechanismVMError.invalidConstant(instruction.operandA) }
                stack.append(Double(program.constants[Int(instruction.operandA)]))
            case .loadVariable:
                stack.append(try load(instruction.operandA, state: state))
            case .loadIndexedVariable:
                let index = try pop(&stack)
                let offset = Int64(instruction.operandA) + Int64(index.rounded(.towardZero))
                guard offset >= 0 else { throw MechanismVMError.invalidVariable(UInt32.max) }
                stack.append(try load(UInt32(offset), state: state))
            case .storeVariable:
                try store(instruction.operandA, value: try pop(&stack), state: &state)
            case .storeIndexedVariable:
                let index = try pop(&stack)
                let value = try pop(&stack)
                let offset = Int64(instruction.operandA) + Int64(index.rounded(.towardZero))
                guard offset >= 0 else { throw MechanismVMError.invalidVariable(UInt32.max) }
                try store(UInt32(offset), value: value, state: &state)
            case .storeDerivative:
                try store(instruction.operandA, value: try pop(&stack), state: &state)
            case .add: try binary(&stack, +)
            case .subtract: try binary(&stack, -)
            case .multiply: try binary(&stack, *)
            case .divide:
                let rhs = try pop(&stack)
                guard rhs != 0 else { throw MechanismVMError.domain("division by zero") }
                let lhs = try pop(&stack)
                stack.append(lhs / rhs)
            case .power: try binary(&stack, Foundation.pow)
            case .negate: stack.append(-(try pop(&stack)))
            case .logicalNot: stack.append(try pop(&stack) == 0 ? 1 : 0)
            case .less: try comparison(&stack, <)
            case .lessOrEqual: try comparison(&stack, <=)
            case .greater: try comparison(&stack, >)
            case .greaterOrEqual: try comparison(&stack, >=)
            case .equal: try comparison(&stack, ==)
            case .notEqual: try comparison(&stack, !=)
            case .logicalAnd: try comparison(&stack) { $0 != 0 && $1 != 0 }
            case .logicalOr: try comparison(&stack) { $0 != 0 || $1 != 0 }
            case .exponential: stack.append(exp(try pop(&stack)))
            case .logarithm:
                let value = try pop(&stack)
                guard value > 0 else { throw MechanismVMError.domain("logarithm of nonpositive value") }
                stack.append(log(value))
            case .squareRoot:
                let value = try pop(&stack)
                guard value >= 0 else { throw MechanismVMError.domain("square root of negative value") }
                stack.append(sqrt(value))
            case .absolute: stack.append(abs(try pop(&stack)))
            case .sine: stack.append(sin(try pop(&stack)))
            case .cosine: stack.append(cos(try pop(&stack)))
            case .hyperbolicTangent: stack.append(tanh(try pop(&stack)))
            case .floor: stack.append(floor(try pop(&stack)))
            case .ceiling: stack.append(ceil(try pop(&stack)))
            case .minimum: try binary(&stack, min)
            case .maximum: try binary(&stack, max)
            case .jump:
                guard Int(instruction.operandA) <= program.instructions.count else { throw MechanismVMError.invalidJump(instruction.operandA) }
                pc = Int(instruction.operandA)
            case .jumpIfZero:
                let condition = try pop(&stack)
                if condition == 0 {
                    guard Int(instruction.operandA) <= program.instructions.count else { throw MechanismVMError.invalidJump(instruction.operandA) }
                    pc = Int(instruction.operandA)
                }
            case .call:
                let arguments = try popArguments(count: Int(instruction.operandB), stack: &stack)
                let value = try executeRoutine(index: Int(instruction.operandA), arguments: arguments, state: &state, result: &result, depth: depth + 1)
                if instruction.flags & 1 != 0 { stack.append(value ?? 0) }
            case .returnValue: return stack.isEmpty ? 0 : try pop(&stack)
            case .returnVoid: return nil
            case .solve:
                try solve(routineIndex: Int(instruction.operandA), methodCode: instruction.flags, state: &state, result: &result, depth: depth + 1)
            case .conserve:
                // Conservation metadata is enforced in the source-level reference interpreter.
                // The bytecode form acts as a certificate boundary and intentionally changes no state.
                stack.removeAll(keepingCapacity: true)
            case .reaction:
                throw MechanismVMError.unsupportedOpcode(.reaction)
            case .emitNetEvent:
                result.events.append(MechanismVMEvent(kind: 1, value: try pop(&stack)))
            case .watch:
                let condition = try pop(&stack)
                if condition != 0 { result.events.append(MechanismVMEvent(kind: 2, flag: Int32(bitPattern: instruction.operandA), value: condition)) }
            case .end: return nil
            }
        }
        return nil
    }

    private func executeRoutine(
        index: Int,
        arguments: [Double],
        state: inout [Double],
        result: inout MechanismVMExecutionResult,
        depth: Int
    ) throws -> Double? {
        guard index >= 0, index < program.routines.count else { throw MechanismVMError.invalidRoutine(index) }
        let routine = program.routines[index]
        guard arguments.count == routine.argumentOffsets.count else { throw MechanismVMError.routineArity(routine.name) }
        for (slot, value) in zip(routine.argumentOffsets, arguments) { try store(slot, value: value, state: &state) }
        for slot in routine.localOffsets { try store(slot, value: 0, state: &state) }
        let range = routine.instructionOffset..<(routine.instructionOffset + routine.instructionCount)
        return try execute(range: range, state: &state, result: &result, depth: depth)
    }

    private func solve(
        routineIndex: Int,
        methodCode: UInt16,
        state: inout [Double],
        result: inout MechanismVMExecutionResult,
        depth: Int
    ) throws {
        _ = try executeRoutine(index: routineIndex, arguments: [], state: &state, result: &result, depth: depth)
        let dt = value(named: "dt", state: state) ?? 0.025
        for integrator in program.integrators where Int(integrator.derivativeRoutineIndex) == routineIndex {
            let stateIndex = Int(integrator.stateOffset)
            let derivativeIndex = Int(integrator.derivativeOffset)
            guard stateIndex < state.count, derivativeIndex < state.count else { throw MechanismVMError.invalidVariable(integrator.stateOffset) }
            let x = state[stateIndex]
            let f0 = state[derivativeIndex]
            let epsilon = max(abs(x) * 1e-6, 1e-8)
            state[stateIndex] = x + epsilon
            _ = try executeRoutine(index: routineIndex, arguments: [], state: &state, result: &result, depth: depth)
            let f1 = state[derivativeIndex]
            state[stateIndex] = x
            let slope = (f1 - f0) / epsilon
            let intercept = f0 - slope * x
            let method = integrator.method == .unknown ? decodeMethod(methodCode) : integrator.method
            let updated: Double
            switch method {
            case .cnexp where abs(slope) > 1e-12:
                let equilibrium = -intercept / slope
                updated = equilibrium + (x - equilibrium) * exp(slope * dt)
            case .derivimplicit where abs(1 - dt * slope) > 1e-12:
                updated = (x + dt * intercept) / (1 - dt * slope)
            case .sparse, .direct, .euler, .unknown, .afterCVode, .cnexp, .derivimplicit:
                updated = x + dt * f0
            }
            state[stateIndex] = updated
        }
    }

    private func decodeMethod(_ code: UInt16) -> MechanismSolveMethodIR {
        switch code {
        case 1: return .cnexp
        case 2: return .derivimplicit
        case 3: return .sparse
        case 4: return .afterCVode
        case 5: return .direct
        case 6: return .euler
        default: return .unknown
        }
    }

    private func ensureState(_ state: inout [Double]) throws {
        if state.count < Int(program.stateStride) { state.append(contentsOf: repeatElement(0, count: Int(program.stateStride) - state.count)) }
        if state.count > Int(program.stateStride) { throw MechanismVMError.stateSizeMismatch }
    }

    private func enforceBounds(state: inout [Double]) throws {
        for variable in program.variables {
            for offset in 0..<Int(variable.count) {
                let index = Int(variable.offset) + offset
                guard index < state.count else { throw MechanismVMError.invalidVariable(variable.offset) }
                state[index] = min(max(state[index], Double(variable.lowerBound)), Double(variable.upperBound))
            }
        }
    }

    private func ensureFinite(_ state: [Double]) throws {
        guard state.allSatisfy(\.isFinite) else { throw MechanismVMError.nonFiniteState }
    }

    private func assignIfPresent(_ name: String, value: Double, state: inout [Double]) {
        guard let variable = program.variables.first(where: { $0.name == name }), Int(variable.offset) < state.count else { return }
        state[Int(variable.offset)] = value
    }

    private func value(named name: String, state: [Double]) -> Double? {
        guard let variable = program.variables.first(where: { $0.name == name }), Int(variable.offset) < state.count else { return nil }
        return state[Int(variable.offset)]
    }

    private func load(_ offset: UInt32, state: [Double]) throws -> Double {
        guard Int(offset) < state.count else { throw MechanismVMError.invalidVariable(offset) }
        return state[Int(offset)]
    }

    private func store(_ offset: UInt32, value: Double, state: inout [Double]) throws {
        guard Int(offset) < state.count else { throw MechanismVMError.invalidVariable(offset) }
        guard value.isFinite else { throw MechanismVMError.nonFiniteState }
        state[Int(offset)] = value
    }

    private func pop(_ stack: inout [Double]) throws -> Double {
        guard let value = stack.popLast() else { throw MechanismVMError.stackUnderflow }
        return value
    }

    private func popArguments(count: Int, stack: inout [Double]) throws -> [Double] {
        guard count >= 0, stack.count >= count else { throw MechanismVMError.stackUnderflow }
        let start = stack.count - count
        let values = Array(stack[start...])
        stack.removeSubrange(start...)
        return values
    }

    private func binary(_ stack: inout [Double], _ operation: (Double, Double) -> Double) throws {
        let rhs = try pop(&stack)
        let lhs = try pop(&stack)
        stack.append(operation(lhs, rhs))
    }

    private func comparison(_ stack: inout [Double], _ operation: (Double, Double) -> Bool) throws {
        let rhs = try pop(&stack)
        let lhs = try pop(&stack)
        stack.append(operation(lhs, rhs) ? 1 : 0)
    }
}

public enum MechanismVMError: Error, Sendable, CustomStringConvertible {
    case stateSizeMismatch
    case invalidConstant(UInt32)
    case invalidVariable(UInt32)
    case invalidRoutine(Int)
    case invalidJump(UInt32)
    case stackUnderflow
    case callDepthExceeded
    case instructionBudgetExceeded
    case routineArity(String)
    case domain(String)
    case nonFiniteState
    case unsupportedOpcode(MechanismOpcode)

    public var description: String {
        switch self {
        case .stateSizeMismatch: return "Mechanism state size does not match compiled stride"
        case .invalidConstant(let value): return "Invalid mechanism constant \(value)"
        case .invalidVariable(let value): return "Invalid mechanism variable offset \(value)"
        case .invalidRoutine(let value): return "Invalid mechanism routine \(value)"
        case .invalidJump(let value): return "Invalid mechanism jump target \(value)"
        case .stackUnderflow: return "Mechanism stack underflow"
        case .callDepthExceeded: return "Mechanism call depth exceeded"
        case .instructionBudgetExceeded: return "Mechanism instruction budget exceeded"
        case .routineArity(let value): return "Mechanism routine \(value) received the wrong number of arguments"
        case .domain(let value): return "Mechanism numerical domain error: \(value)"
        case .nonFiniteState: return "Mechanism produced non-finite state"
        case .unsupportedOpcode(let value): return "CPU reference VM does not implement opcode \(value)"
        }
    }
}
