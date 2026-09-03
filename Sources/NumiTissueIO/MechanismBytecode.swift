import Foundation

public enum MechanismOpcode: UInt16, Sendable, Hashable, Codable, CaseIterable {
    case noOperation = 0
    case pushConstant
    case loadVariable
    case loadIndexedVariable
    case storeVariable
    case storeIndexedVariable
    case storeDerivative
    case add
    case subtract
    case multiply
    case divide
    case power
    case negate
    case logicalNot
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual
    case equal
    case notEqual
    case logicalAnd
    case logicalOr
    case exponential
    case logarithm
    case squareRoot
    case absolute
    case sine
    case cosine
    case hyperbolicTangent
    case floor
    case ceiling
    case minimum
    case maximum
    case jump
    case jumpIfZero
    case call
    case returnValue
    case returnVoid
    case solve
    case conserve
    case reaction
    case emitNetEvent
    case watch
    case end
}

@frozen
public struct MechanismInstruction: Sendable, Hashable, Codable {
    public var opcode: MechanismOpcode
    public var flags: UInt16
    public var operandA: UInt32
    public var operandB: UInt32
    public var immediate: Float

    public init(_ opcode: MechanismOpcode, flags: UInt16 = 0, operandA: UInt32 = 0, operandB: UInt32 = 0, immediate: Float = 0) {
        self.opcode = opcode
        self.flags = flags
        self.operandA = operandA
        self.operandB = operandB
        self.immediate = immediate
    }
}

public struct MechanismVariableLayout: Sendable, Hashable, Codable {
    public var name: String
    public var offset: UInt32
    public var count: UInt16
    public var role: MechanismVariableRoleIR
    public var defaultValue: Float
    public var lowerBound: Float
    public var upperBound: Float

    public init(name: String, offset: UInt32, count: UInt16, role: MechanismVariableRoleIR, defaultValue: Float, lowerBound: Float, upperBound: Float) {
        self.name = name
        self.offset = offset
        self.count = count
        self.role = role
        self.defaultValue = defaultValue
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct MechanismRoutineBytecode: Sendable, Hashable, Codable {
    public var name: String
    public var kind: MechanismRoutineKindIR
    public var instructionOffset: UInt32
    public var instructionCount: UInt32
    public var argumentOffsets: [UInt32]
    public var localOffsets: [UInt32]
    public var maximumStackDepth: UInt16

    public init(name: String, kind: MechanismRoutineKindIR, instructionOffset: UInt32, instructionCount: UInt32, argumentOffsets: [UInt32], localOffsets: [UInt32], maximumStackDepth: UInt16) {
        self.name = name
        self.kind = kind
        self.instructionOffset = instructionOffset
        self.instructionCount = instructionCount
        self.argumentOffsets = argumentOffsets
        self.localOffsets = localOffsets
        self.maximumStackDepth = maximumStackDepth
    }
}

public struct MechanismEntryPoints: Sendable, Hashable, Codable {
    public var initial: Range<UInt32>
    public var breakpoint: Range<UInt32>
    public var beforeStep: Range<UInt32>
    public var afterStep: Range<UInt32>

    public init(initial: Range<UInt32>, breakpoint: Range<UInt32>, beforeStep: Range<UInt32>, afterStep: Range<UInt32>) {
        self.initial = initial
        self.breakpoint = breakpoint
        self.beforeStep = beforeStep
        self.afterStep = afterStep
    }
}

public struct MechanismStateIntegrator: Sendable, Hashable, Codable {
    public var stateOffset: UInt32
    public var derivativeOffset: UInt32
    public var method: MechanismSolveMethodIR
    public var derivativeRoutineIndex: UInt16

    public init(stateOffset: UInt32, derivativeOffset: UInt32, method: MechanismSolveMethodIR, derivativeRoutineIndex: UInt16) {
        self.stateOffset = stateOffset
        self.derivativeOffset = derivativeOffset
        self.method = method
        self.derivativeRoutineIndex = derivativeRoutineIndex
    }
}

public struct CompiledMechanismProgramIR: Sendable, Hashable, Codable {
    public var name: String
    public var kind: MechanismKindIR
    public var instructions: [MechanismInstruction]
    public var constants: [Float]
    public var variables: [MechanismVariableLayout]
    public var routines: [MechanismRoutineBytecode]
    public var entries: MechanismEntryPoints
    public var integrators: [MechanismStateIntegrator]
    public var ions: [MechanismIonAccessIR]
    public var nonspecificCurrents: [String]
    public var stateStride: UInt32
    public var maximumStackDepth: UInt16
    public var maximumCallDepth: UInt8
    public var sourceHash: UInt64

    public init(
        name: String,
        kind: MechanismKindIR,
        instructions: [MechanismInstruction],
        constants: [Float],
        variables: [MechanismVariableLayout],
        routines: [MechanismRoutineBytecode],
        entries: MechanismEntryPoints,
        integrators: [MechanismStateIntegrator],
        ions: [MechanismIonAccessIR],
        nonspecificCurrents: [String],
        stateStride: UInt32,
        maximumStackDepth: UInt16,
        maximumCallDepth: UInt8,
        sourceHash: UInt64
    ) {
        self.name = name
        self.kind = kind
        self.instructions = instructions
        self.constants = constants
        self.variables = variables
        self.routines = routines
        self.entries = entries
        self.integrators = integrators
        self.ions = ions
        self.nonspecificCurrents = nonspecificCurrents
        self.stateStride = stateStride
        self.maximumStackDepth = maximumStackDepth
        self.maximumCallDepth = maximumCallDepth
        self.sourceHash = sourceHash
    }

    public func validated() throws -> Self {
        guard stateStride <= 4_096 else { throw MechanismBytecodeError.stateStrideExceeded(Int(stateStride)) }
        guard maximumStackDepth <= 128 else { throw MechanismBytecodeError.stackDepthExceeded(Int(maximumStackDepth)) }
        guard maximumCallDepth <= 8 else { throw MechanismBytecodeError.callDepthExceeded(Int(maximumCallDepth)) }
        for (index, constant) in constants.enumerated() where !constant.isFinite {
            throw MechanismBytecodeError.nonFiniteValue("constant[\(index)]")
        }
        for variable in variables {
            guard variable.defaultValue.isFinite,
                  variable.lowerBound.isFinite,
                  variable.upperBound.isFinite,
                  variable.lowerBound <= variable.upperBound else {
                throw MechanismBytecodeError.nonFiniteValue(variable.name)
            }
        }
        for instruction in instructions {
            guard instruction.immediate.isFinite else {
                throw MechanismBytecodeError.nonFiniteValue("instruction")
            }
            switch instruction.opcode {
            case .pushConstant where Int(instruction.operandA) >= constants.count:
                throw MechanismBytecodeError.invalidConstant(instruction.operandA)
            case .loadVariable where instruction.operandA >= stateStride,
                 .storeVariable where instruction.operandA >= stateStride,
                 .storeDerivative where instruction.operandA >= stateStride:
                throw MechanismBytecodeError.invalidVariable(instruction.operandA)
            case .call where Int(instruction.operandA) >= routines.count,
                 .solve where Int(instruction.operandA) >= routines.count:
                throw MechanismBytecodeError.invalidRoutine(instruction.operandA)
            case .jump where Int(instruction.operandA) > instructions.count,
                 .jumpIfZero where Int(instruction.operandA) > instructions.count:
                throw MechanismBytecodeError.invalidJump(instruction.operandA)
            default: break
            }
        }
        return self
    }
}

public enum MechanismBytecodeCompiler {
    public static func compile(_ source: MechanismModelIR) throws -> CompiledMechanismProgramIR {
        let source = try source.validated()
        var compiler = Compiler(source: source)
        return try compiler.compile().validated()
    }

    private struct Compiler {
        let source: MechanismModelIR
        var instructions: [MechanismInstruction] = []
        var constants: [Float] = []
        var constantMap: [UInt32: UInt32] = [:]
        var variableLayouts: [MechanismVariableLayout] = []
        var globalSlots: [String: UInt32] = [:]
        var routineSlots: [[String: UInt32]] = []
        var routineIndices: [String: UInt16] = [:]
        var routineBytecode: [MechanismRoutineBytecode] = []
        var pendingIntegrators: [(state: String, method: MechanismSolveMethodIR, routine: String)] = []
        var stackDepth = 0
        var maxStackDepth = 0
        var currentScope = -1

        init(source: MechanismModelIR) {
            self.source = source
        }

        mutating func compile() throws -> CompiledMechanismProgramIR {
            try layoutVariables()
            for (index, routine) in source.routines.enumerated() { routineIndices[routine.name] = UInt16(clamping: index) }
            routineSlots = Array(repeating: [:], count: source.routines.count)
            try layoutRoutineLocals()

            let initial = try compileEntry(source.initial)
            let breakpoint = try compileEntry(source.breakpoint)
            let before = try compileEntry(source.beforeStep)
            let after = try compileEntry(source.afterStep)

            for (index, routine) in source.routines.enumerated() {
                currentScope = index
                let start = instructions.count
                stackDepth = 0
                maxStackDepth = 0
                try compileStatements(routine.statements)
                if routine.kind == .function { instructions.append(MechanismInstruction(.returnValue)) }
                else { instructions.append(MechanismInstruction(.returnVoid)) }
                routineBytecode.append(MechanismRoutineBytecode(
                    name: routine.name,
                    kind: routine.kind,
                    instructionOffset: UInt32(clamping: start),
                    instructionCount: UInt32(clamping: instructions.count - start),
                    argumentOffsets: routine.arguments.compactMap { routineSlots[index][$0] },
                    localOffsets: routine.localVariables.compactMap { routineSlots[index][$0.name] },
                    maximumStackDepth: UInt16(clamping: maxStackDepth)
                ))
            }
            currentScope = -1

            let integrators = try pendingIntegrators.compactMap { pending -> MechanismStateIntegrator? in
                guard let state = globalSlots[pending.state] else { throw MechanismBytecodeError.unknownVariable(pending.state) }
                guard let routine = routineIndices[pending.routine] else { throw MechanismBytecodeError.unknownRoutine(pending.routine) }
                return MechanismStateIntegrator(
                    stateOffset: state,
                    derivativeOffset: state + UInt32(source.variables.reduce(0) { $0 + max($1.arrayCount, 1) }),
                    method: pending.method,
                    derivativeRoutineIndex: routine
                )
            }
            let maximumStack = max(
                Int(initial.maximumStack), Int(breakpoint.maximumStack), Int(before.maximumStack), Int(after.maximumStack),
                routineBytecode.map { Int($0.maximumStackDepth) }.max() ?? 0
            )
            let sourceHash = stableHash(source)
            return CompiledMechanismProgramIR(
                name: source.name,
                kind: source.kind,
                instructions: instructions,
                constants: constants,
                variables: variableLayouts,
                routines: routineBytecode,
                entries: MechanismEntryPoints(
                    initial: initial.range,
                    breakpoint: breakpoint.range,
                    beforeStep: before.range,
                    afterStep: after.range
                ),
                integrators: integrators,
                ions: source.ions,
                nonspecificCurrents: source.nonspecificCurrents,
                stateStride: UInt32(clamping: variableLayouts.reduce(0) { max($0, Int($1.offset) + Int($1.count)) } + source.variables.reduce(0) { $0 + max($1.arrayCount, 1) }),
                maximumStackDepth: UInt16(clamping: maximumStack),
                maximumCallDepth: UInt8(clamping: try maximumCallDepth()),
                sourceHash: sourceHash
            )
        }

        mutating func layoutVariables() throws {
            var offset: UInt32 = 0
            for variable in source.variables {
                guard globalSlots[variable.name] == nil else { throw MechanismBytecodeError.duplicateVariable(variable.name) }
                globalSlots[variable.name] = offset
                let count = UInt16(clamping: variable.arrayCount)
                let defaultValue = try representable(
                    variable.defaultValue ?? 0,
                    path: variable.name + ".defaultValue"
                )
                let lowerBound = try representable(
                    variable.lowerBound ?? -Double(Float.greatestFiniteMagnitude),
                    path: variable.name + ".lowerBound"
                )
                let upperBound = try representable(
                    variable.upperBound ?? Double(Float.greatestFiniteMagnitude),
                    path: variable.name + ".upperBound"
                )
                variableLayouts.append(MechanismVariableLayout(
                    name: variable.name,
                    offset: offset,
                    count: count,
                    role: variable.role,
                    defaultValue: defaultValue,
                    lowerBound: lowerBound,
                    upperBound: upperBound
                ))
                offset += UInt32(count)
            }
            let derivativeBase = offset
            for variable in source.variables where variable.role == .state {
                globalSlots["D_\(variable.name)"] = derivativeBase + (globalSlots[variable.name] ?? 0)
            }
        }

        mutating func layoutRoutineLocals() throws {
            var offset = UInt32(variableLayouts.reduce(0) { max($0, Int($1.offset) + Int($1.count)) } + source.variables.reduce(0) { $0 + max($1.arrayCount, 1) })
            for (routineIndex, routine) in source.routines.enumerated() {
                for argument in routine.arguments {
                    guard routineSlots[routineIndex][argument] == nil else { throw MechanismBytecodeError.duplicateVariable(argument) }
                    routineSlots[routineIndex][argument] = offset
                    offset += 1
                }
                for local in routine.localVariables {
                    guard routineSlots[routineIndex][local.name] == nil else { continue }
                    routineSlots[routineIndex][local.name] = offset
                    offset += UInt32(max(local.arrayCount, 1))
                }
            }
            guard offset <= 4_096 else { throw MechanismBytecodeError.stateStrideExceeded(Int(offset)) }
        }

        mutating func compileEntry(_ statements: [MechanismStatementIR]) throws -> (range: Range<UInt32>, maximumStack: UInt16) {
            currentScope = -1
            stackDepth = 0
            maxStackDepth = 0
            let start = UInt32(clamping: instructions.count)
            try compileStatements(statements)
            instructions.append(MechanismInstruction(.end))
            let end = UInt32(clamping: instructions.count)
            return (start..<end, UInt16(clamping: maxStackDepth))
        }

        mutating func compileStatements(_ statements: [MechanismStatementIR]) throws {
            for statement in statements { try compileStatement(statement) }
        }

        mutating func compileStatement(_ statement: MechanismStatementIR) throws {
            switch statement {
            case .assignment(let target, let index, let expression):
                try compileExpression(expression)
                if let index {
                    try compileExpression(index)
                    emit(.storeIndexedVariable, a: try slot(target))
                    pop(2)
                } else {
                    emit(.storeVariable, a: try slot(target))
                    pop()
                }
            case .derivative(let state, let expression):
                try compileExpression(expression)
                emit(.storeDerivative, a: try derivativeSlot(state))
                pop()
            case .call(let name, let arguments):
                for argument in arguments { try compileExpression(argument) }
                emit(.call, a: UInt32(try routineIndex(name)), b: UInt32(clamping: arguments.count))
                pop(arguments.count)
            case .conditional(let condition, let thenStatements, let otherwiseStatements):
                try compileExpression(condition)
                let branch = instructions.count
                emit(.jumpIfZero)
                pop()
                try compileStatements(thenStatements)
                let endJump = instructions.count
                emit(.jump)
                instructions[branch].operandA = UInt32(clamping: instructions.count)
                try compileStatements(otherwiseStatements)
                instructions[endJump].operandA = UInt32(clamping: instructions.count)
            case .solve(let block, let method):
                let index = try routineIndex(block)
                emit(.solve, flags: solveMethodCode(method), a: UInt32(index))
                if let routine = source.routines.first(where: { $0.name == block }) {
                    for statement in routine.statements {
                        if case .derivative(let state, _) = statement { pendingIntegrators.append((state, method, block)) }
                    }
                }
            case .conserve(let terms, let total):
                for term in terms {
                    emit(.loadVariable, a: try slot(term.variable)); push()
                    let constant = constant(Float(term.coefficient)); emit(.pushConstant, a: constant); push()
                    emit(.multiply); pop()
                }
                try compileExpression(total)
                emit(.conserve, a: UInt32(clamping: terms.count))
                pop(terms.count + 1)
            case .reaction(let reactants, let products, let forward, let reverse):
                try compileExpression(forward)
                if let reverse { try compileExpression(reverse) } else { emit(.pushConstant, a: constant(0)); push() }
                emit(.reaction, flags: UInt16(clamping: reactants.count), a: UInt32(clamping: products.count))
                pop(2)
            case .emitNetEvent(let expression):
                try compileExpression(expression)
                emit(.emitNetEvent)
                pop()
            case .watch(let condition, let flag):
                try compileExpression(condition)
                emit(.watch, a: UInt32(bitPattern: Int32(flag)))
                pop()
            case .returnValue(let expression):
                try compileExpression(expression)
                emit(.returnValue)
                pop()
            }
        }

        mutating func compileExpression(_ expression: MechanismExpressionIR) throws {
            switch expression {
            case .constant(let value):
                emit(
                    .pushConstant,
                    a: constant(try representable(value, path: "expression constant"))
                )
                push()
            case .symbol(let name): emit(.loadVariable, a: try slot(name)); push()
            case .indexedSymbol(let name, let index):
                try compileExpression(index)
                emit(.loadIndexedVariable, a: try slot(name))
            case .unary(let operation, let value):
                try compileExpression(value)
                switch operation {
                case .plus: break
                case .negate: emit(.negate)
                case .logicalNot: emit(.logicalNot)
                }
            case .binary(let operation, let lhs, let rhs):
                try compileExpression(lhs)
                try compileExpression(rhs)
                let opcode: MechanismOpcode
                switch operation {
                case .add: opcode = .add
                case .subtract: opcode = .subtract
                case .multiply: opcode = .multiply
                case .divide: opcode = .divide
                case .power: opcode = .power
                case .less: opcode = .less
                case .lessOrEqual: opcode = .lessOrEqual
                case .greater: opcode = .greater
                case .greaterOrEqual: opcode = .greaterOrEqual
                case .equal: opcode = .equal
                case .notEqual: opcode = .notEqual
                case .logicalAnd: opcode = .logicalAnd
                case .logicalOr: opcode = .logicalOr
                }
                emit(opcode)
                pop()
            case .call(let name, let arguments):
                for argument in arguments { try compileExpression(argument) }
                if let builtin = builtinOpcode(name) {
                    emit(builtin, a: UInt32(clamping: arguments.count))
                    if arguments.count > 1 { pop(arguments.count - 1) }
                } else {
                    emit(.call, flags: 1, a: UInt32(try routineIndex(name)), b: UInt32(clamping: arguments.count))
                    if arguments.count == 0 { push() }
                    else if arguments.count > 1 { pop(arguments.count - 1) }
                }
            case .conditional(let condition, let thenValue, let otherwiseValue):
                try compileExpression(condition)
                let branch = instructions.count
                emit(.jumpIfZero)
                pop()
                try compileExpression(thenValue)
                let endJump = instructions.count
                emit(.jump)
                instructions[branch].operandA = UInt32(clamping: instructions.count)
                try compileExpression(otherwiseValue)
                instructions[endJump].operandA = UInt32(clamping: instructions.count)
            }
        }

        mutating func emit(_ opcode: MechanismOpcode, flags: UInt16 = 0, a: UInt32 = 0, b: UInt32 = 0, immediate: Float = 0) {
            instructions.append(MechanismInstruction(opcode, flags: flags, operandA: a, operandB: b, immediate: immediate))
        }

        mutating func push(_ count: Int = 1) {
            stackDepth += count
            maxStackDepth = max(maxStackDepth, stackDepth)
        }

        mutating func pop(_ count: Int = 1) { stackDepth = max(0, stackDepth - count) }

        mutating func constant(_ value: Float) -> UInt32 {
            let bits = value.bitPattern
            if let existing = constantMap[bits] { return existing }
            let index = UInt32(clamping: constants.count)
            constants.append(value)
            constantMap[bits] = index
            return index
        }

        func slot(_ name: String) throws -> UInt32 {
            if currentScope >= 0, let value = routineSlots[currentScope][name] { return value }
            if let value = globalSlots[name] { return value }
            throw MechanismBytecodeError.unknownVariable(name)
        }

        func derivativeSlot(_ name: String) throws -> UInt32 {
            guard let value = globalSlots["D_\(name)"] else { throw MechanismBytecodeError.unknownVariable(name) }
            return value
        }

        func routineIndex(_ name: String) throws -> UInt16 {
            guard let value = routineIndices[name] else { throw MechanismBytecodeError.unknownRoutine(name) }
            return value
        }

        func builtinOpcode(_ name: String) -> MechanismOpcode? {
            switch name.lowercased() {
            case "exp": return .exponential
            case "log", "ln": return .logarithm
            case "sqrt": return .squareRoot
            case "abs", "fabs": return .absolute
            case "sin": return .sine
            case "cos": return .cosine
            case "tanh": return .hyperbolicTangent
            case "floor": return .floor
            case "ceil": return .ceiling
            case "min", "fmin": return .minimum
            case "max", "fmax": return .maximum
            case "pow": return .power
            default: return nil
            }
        }

        func solveMethodCode(_ method: MechanismSolveMethodIR) -> UInt16 {
            switch method {
            case .cnexp: return 1
            case .derivimplicit: return 2
            case .sparse: return 3
            case .afterCVode: return 4
            case .direct: return 5
            case .euler: return 6
            case .unknown: return 0
            }
        }

        func maximumCallDepth() throws -> Int {
            let graph: [String: Set<String>] = Dictionary(uniqueKeysWithValues: source.routines.map { routine in
                (routine.name, collectCalls(routine.statements))
            })
            var active = Set<String>()
            var cache: [String: Int] = [:]
            func depth(_ name: String) throws -> Int {
                if let value = cache[name] { return value }
                guard active.insert(name).inserted else { throw MechanismBytecodeError.recursiveRoutine(name) }
                defer { active.remove(name) }
                let result = 1 + (try graph[name, default: []].map(depth).max() ?? 0)
                cache[name] = result
                return result
            }
            return try graph.keys.map(depth).max() ?? 0
        }

        func collectCalls(_ statements: [MechanismStatementIR]) -> Set<String> {
            var result = Set<String>()
            func expression(_ value: MechanismExpressionIR) {
                switch value {
                case .call(let name, let arguments): result.insert(name); arguments.forEach(expression)
                case .indexedSymbol(_, let index), .unary(_, let index): expression(index)
                case .binary(_, let lhs, let rhs): expression(lhs); expression(rhs)
                case .conditional(let condition, let thenValue, let otherwiseValue): expression(condition); expression(thenValue); expression(otherwiseValue)
                case .constant, .symbol: break
                }
            }
            for statement in statements {
                switch statement {
                case .assignment(_, let index, let value): index.map(expression); expression(value)
                case .derivative(_, let value), .emitNetEvent(let value), .returnValue(let value): expression(value)
                case .call(let name, let arguments): result.insert(name); arguments.forEach(expression)
                case .conditional(let condition, let thenStatements, let otherwiseStatements): expression(condition); result.formUnion(collectCalls(thenStatements)); result.formUnion(collectCalls(otherwiseStatements))
                case .solve(let block, _): result.insert(block)
                case .conserve(_, let total): expression(total)
                case .reaction(_, _, let forward, let reverse): expression(forward); reverse.map(expression)
                case .watch(let condition, _): expression(condition)
                }
            }
            return result.filter { routineIndices[$0] != nil }
        }

        func stableHash(_ model: MechanismModelIR) -> UInt64 {
            let data = (try? JSONEncoder().encode(model)) ?? Data(model.name.utf8)
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return hash
        }
    }
}

private func representable(_ value: Double, path: String) throws -> Float {
    guard value.isFinite,
          value <= Double(Float.greatestFiniteMagnitude),
          value >= -Double(Float.greatestFiniteMagnitude) else {
        throw MechanismBytecodeError.nonRepresentableFloat(path, value)
    }
    let result = Float(value)
    guard result.isFinite else {
        throw MechanismBytecodeError.nonRepresentableFloat(path, value)
    }
    return result
}

public enum MechanismBytecodeError: Error, Sendable, CustomStringConvertible {
    case duplicateVariable(String)
    case unknownVariable(String)
    case unknownRoutine(String)
    case recursiveRoutine(String)
    case stateStrideExceeded(Int)
    case stackDepthExceeded(Int)
    case callDepthExceeded(Int)
    case invalidConstant(UInt32)
    case invalidVariable(UInt32)
    case invalidRoutine(UInt32)
    case invalidJump(UInt32)
    case unsupportedStatement(String)
    case nonFiniteValue(String)
    case nonRepresentableFloat(String, Double)

    public var description: String {
        switch self {
        case .duplicateVariable(let value): return "Duplicate bytecode variable \(value)"
        case .unknownVariable(let value): return "Unknown bytecode variable \(value)"
        case .unknownRoutine(let value): return "Unknown bytecode routine \(value)"
        case .recursiveRoutine(let value): return "Recursive mechanism routine \(value) is not supported"
        case .stateStrideExceeded(let value): return "Mechanism state stride \(value) exceeds 4096 values"
        case .stackDepthExceeded(let value): return "Mechanism stack depth \(value) exceeds 128 values"
        case .callDepthExceeded(let value): return "Mechanism call depth \(value) exceeds 8"
        case .invalidConstant(let value): return "Bytecode references invalid constant \(value)"
        case .invalidVariable(let value): return "Bytecode references invalid variable \(value)"
        case .invalidRoutine(let value): return "Bytecode references invalid routine \(value)"
        case .invalidJump(let value): return "Bytecode references invalid jump target \(value)"
        case .unsupportedStatement(let value): return "Unsupported bytecode statement \(value)"
        case .nonFiniteValue(let value): return "Bytecode contains a non-finite value at \(value)"
        case .nonRepresentableFloat(let path, let value):
            return "Bytecode value " + String(value) + " at " + path + " is not representable as Float32"
        }
    }
}

private func max(_ values: Int...) -> Int { values.max() ?? 0 }
