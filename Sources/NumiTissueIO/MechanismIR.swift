import Foundation

public enum MechanismKindIR: String, Sendable, Hashable, Codable {
    case density
    case pointProcess
    case artificialCell
    case junction
}

public enum MechanismVariableRoleIR: String, Sendable, Hashable, Codable {
    case parameter
    case state
    case assigned
    case local
    case argument
    case range
    case global
    case ionRead
    case ionWrite
}

public struct MechanismVariableIR: Sendable, Hashable, Codable {
    public var name: String
    public var role: MechanismVariableRoleIR
    public var unit: String?
    public var defaultValue: Double?
    public var lowerBound: Double?
    public var upperBound: Double?
    public var arrayCount: Int

    public init(
        name: String,
        role: MechanismVariableRoleIR,
        unit: String? = nil,
        defaultValue: Double? = nil,
        lowerBound: Double? = nil,
        upperBound: Double? = nil,
        arrayCount: Int = 1
    ) {
        self.name = name
        self.role = role
        self.unit = unit
        self.defaultValue = defaultValue
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.arrayCount = arrayCount
    }
}

public struct MechanismIonAccessIR: Sendable, Hashable, Codable {
    public var ion: String
    public var readVariables: [String]
    public var writeVariables: [String]
    public var valence: Int?

    public init(ion: String, readVariables: [String] = [], writeVariables: [String] = [], valence: Int? = nil) {
        self.ion = ion
        self.readVariables = readVariables
        self.writeVariables = writeVariables
        self.valence = valence
    }
}

public enum MechanismSolveMethodIR: String, Sendable, Hashable, Codable {
    case cnexp
    case derivimplicit
    case sparse
    case afterCVode
    case direct
    case euler
    case unknown
}

public indirect enum MechanismExpressionIR: Sendable, Hashable, Codable {
    case constant(Double)
    case symbol(String)
    case indexedSymbol(String, MechanismExpressionIR)
    case unary(MechanismUnaryOperatorIR, MechanismExpressionIR)
    case binary(MechanismBinaryOperatorIR, MechanismExpressionIR, MechanismExpressionIR)
    case call(String, [MechanismExpressionIR])
    case conditional(condition: MechanismExpressionIR, then: MechanismExpressionIR, otherwise: MechanismExpressionIR)

    public func evaluate(symbols: [String: Double], functions: [String: MechanismRoutineIR] = [:]) throws -> Double {
        switch self {
        case .constant(let value): return value
        case .symbol(let name):
            guard let value = symbols[name] else { throw MechanismIRError.unknownSymbol(name) }
            return value
        case .indexedSymbol(let name, let index):
            let value = try index.evaluate(symbols: symbols, functions: functions)
            let key = "\(name)[\(Int(value))]"
            guard let result = symbols[key] else { throw MechanismIRError.unknownSymbol(key) }
            return result
        case .unary(let operation, let value):
            let evaluated = try value.evaluate(symbols: symbols, functions: functions)
            switch operation {
            case .plus: return evaluated
            case .negate: return -evaluated
            case .logicalNot: return evaluated == 0 ? 1 : 0
            }
        case .binary(let operation, let lhs, let rhs):
            let left = try lhs.evaluate(symbols: symbols, functions: functions)
            if operation == .logicalAnd && left == 0 { return 0 }
            if operation == .logicalOr && left != 0 { return 1 }
            let right = try rhs.evaluate(symbols: symbols, functions: functions)
            switch operation {
            case .add: return left + right
            case .subtract: return left - right
            case .multiply: return left * right
            case .divide:
                guard right != 0 else { throw MechanismIRError.expressionDomain("division by zero") }
                return left / right
            case .power: return Foundation.pow(left, right)
            case .less: return left < right ? 1 : 0
            case .lessOrEqual: return left <= right ? 1 : 0
            case .greater: return left > right ? 1 : 0
            case .greaterOrEqual: return left >= right ? 1 : 0
            case .equal: return left == right ? 1 : 0
            case .notEqual: return left != right ? 1 : 0
            case .logicalAnd: return right != 0 ? 1 : 0
            case .logicalOr: return right != 0 ? 1 : 0
            }
        case .call(let name, let arguments):
            let values = try arguments.map { try $0.evaluate(symbols: symbols, functions: functions) }
            if let result = try evaluateBuiltin(name: name, arguments: values) { return result }
            guard let routine = functions[name], routine.kind == .function else { throw MechanismIRError.unknownRoutine(name) }
            var scope = symbols
            for (argument, value) in zip(routine.arguments, values) { scope[argument] = value }
            return try MechanismInterpreter.executeFunction(routine, symbols: &scope, functions: functions)
        case .conditional(let condition, let thenValue, let otherwiseValue):
            return try condition.evaluate(symbols: symbols, functions: functions) != 0
                ? thenValue.evaluate(symbols: symbols, functions: functions)
                : otherwiseValue.evaluate(symbols: symbols, functions: functions)
        }
    }

    private func evaluateBuiltin(name: String, arguments: [Double]) throws -> Double? {
        switch name.lowercased() {
        case "exp": return try unary(arguments, name: name, Foundation.exp)
        case "log", "ln":
            return try unary(arguments, name: name) { value in
                guard value > 0 else { throw MechanismIRError.expressionDomain("logarithm of nonpositive value") }
                return Foundation.log(value)
            }
        case "sqrt":
            return try unary(arguments, name: name) { value in
                guard value >= 0 else { throw MechanismIRError.expressionDomain("square root of negative value") }
                return Foundation.sqrt(value)
            }
        case "fabs", "abs": return try unary(arguments, name: name, Swift.abs)
        case "sin": return try unary(arguments, name: name, Foundation.sin)
        case "cos": return try unary(arguments, name: name, Foundation.cos)
        case "tanh": return try unary(arguments, name: name, Foundation.tanh)
        case "floor": return try unary(arguments, name: name, Foundation.floor)
        case "ceil": return try unary(arguments, name: name, Foundation.ceil)
        case "pow": return try binary(arguments, name: name, Foundation.pow)
        case "min", "fmin": return try binary(arguments, name: name, Swift.min)
        case "max", "fmax": return try binary(arguments, name: name, Swift.max)
        case "expm1": return try unary(arguments, name: name, Foundation.expm1)
        default: return nil
        }
    }

    private func unary(_ values: [Double], name: String, _ function: (Double) throws -> Double) throws -> Double {
        guard values.count == 1 else { throw MechanismIRError.routineArity(name: name, expected: 1, actual: values.count) }
        return try function(values[0])
    }

    private func binary(_ values: [Double], name: String, _ function: (Double, Double) throws -> Double) throws -> Double {
        guard values.count == 2 else { throw MechanismIRError.routineArity(name: name, expected: 2, actual: values.count) }
        return try function(values[0], values[1])
    }
}

public enum MechanismUnaryOperatorIR: String, Sendable, Hashable, Codable {
    case plus
    case negate
    case logicalNot
}

public enum MechanismBinaryOperatorIR: String, Sendable, Hashable, Codable {
    case add
    case subtract
    case multiply
    case divide
    case power
    case less
    case lessOrEqual
    case greater
    case greaterOrEqual
    case equal
    case notEqual
    case logicalAnd
    case logicalOr
}

public indirect enum MechanismStatementIR: Sendable, Hashable, Codable {
    case assignment(target: String, index: MechanismExpressionIR?, expression: MechanismExpressionIR)
    case derivative(state: String, expression: MechanismExpressionIR)
    case call(name: String, arguments: [MechanismExpressionIR])
    case conditional(condition: MechanismExpressionIR, then: [MechanismStatementIR], otherwise: [MechanismStatementIR])
    case solve(block: String, method: MechanismSolveMethodIR)
    case conserve(terms: [MechanismConservationTermIR], total: MechanismExpressionIR)
    case reaction(reactants: [MechanismReactionTermIR], products: [MechanismReactionTermIR], forward: MechanismExpressionIR, reverse: MechanismExpressionIR?)
    case emitNetEvent(MechanismExpressionIR)
    case watch(condition: MechanismExpressionIR, flag: Int)
    case returnValue(MechanismExpressionIR)
}

public struct MechanismConservationTermIR: Sendable, Hashable, Codable {
    public var variable: String
    public var coefficient: Double
    public init(variable: String, coefficient: Double = 1) { self.variable = variable; self.coefficient = coefficient }
}

public struct MechanismReactionTermIR: Sendable, Hashable, Codable {
    public var variable: String
    public var coefficient: UInt8
    public init(variable: String, coefficient: UInt8 = 1) { self.variable = variable; self.coefficient = coefficient }
}

public enum MechanismRoutineKindIR: String, Sendable, Hashable, Codable {
    case procedure
    case function
    case derivative
    case kinetic
    case linear
    case nonlinear
    case discrete
    case netReceive
}

public struct MechanismRoutineIR: Sendable, Hashable, Codable {
    public var name: String
    public var kind: MechanismRoutineKindIR
    public var arguments: [String]
    public var localVariables: [MechanismVariableIR]
    public var statements: [MechanismStatementIR]

    public init(name: String, kind: MechanismRoutineKindIR, arguments: [String] = [], localVariables: [MechanismVariableIR] = [], statements: [MechanismStatementIR] = []) {
        self.name = name
        self.kind = kind
        self.arguments = arguments
        self.localVariables = localVariables
        self.statements = statements
    }
}

public struct MechanismModelIR: Sendable, Hashable, Codable {
    public var name: String
    public var kind: MechanismKindIR
    public var ions: [MechanismIonAccessIR]
    public var variables: [MechanismVariableIR]
    public var rangeVariables: [String]
    public var globalVariables: [String]
    public var pointerVariables: [String]
    public var nonspecificCurrents: [String]
    public var initial: [MechanismStatementIR]
    public var breakpoint: [MechanismStatementIR]
    public var beforeStep: [MechanismStatementIR]
    public var afterStep: [MechanismStatementIR]
    public var routines: [MechanismRoutineIR]
    public var sourceMetadata: [String: String]

    public init(
        name: String,
        kind: MechanismKindIR = .density,
        ions: [MechanismIonAccessIR] = [],
        variables: [MechanismVariableIR] = [],
        rangeVariables: [String] = [],
        globalVariables: [String] = [],
        pointerVariables: [String] = [],
        nonspecificCurrents: [String] = [],
        initial: [MechanismStatementIR] = [],
        breakpoint: [MechanismStatementIR] = [],
        beforeStep: [MechanismStatementIR] = [],
        afterStep: [MechanismStatementIR] = [],
        routines: [MechanismRoutineIR] = [],
        sourceMetadata: [String: String] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.ions = ions
        self.variables = variables
        self.rangeVariables = rangeVariables
        self.globalVariables = globalVariables
        self.pointerVariables = pointerVariables
        self.nonspecificCurrents = nonspecificCurrents
        self.initial = initial
        self.breakpoint = breakpoint
        self.beforeStep = beforeStep
        self.afterStep = afterStep
        self.routines = routines
        self.sourceMetadata = sourceMetadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty else { throw MechanismIRError.missingName }
        let variableNames = variables.map(\.name)
        guard Set(variableNames).count == variableNames.count else { throw MechanismIRError.duplicateVariable }
        let routineNames = routines.map(\.name)
        guard Set(routineNames).count == routineNames.count else { throw MechanismIRError.duplicateRoutine }
        let knownVariables = Set(variableNames)
        let knownRoutines = Set(routineNames)
        for variable in variables {
            guard variable.arrayCount > 0 else { throw MechanismIRError.invalidArrayCount(variable.name) }
            if let lower = variable.lowerBound, let upper = variable.upperBound, lower > upper { throw MechanismIRError.invalidBounds(variable.name) }
        }
        for name in rangeVariables where !knownVariables.contains(name) { throw MechanismIRError.unknownSymbol(name) }
        for routine in routines {
            let locals = Set(routine.localVariables.map(\.name)).union(routine.arguments)
            try validate(statements: routine.statements, knownVariables: knownVariables.union(locals), knownRoutines: knownRoutines)
        }
        try validate(statements: initial, knownVariables: knownVariables, knownRoutines: knownRoutines)
        try validate(statements: breakpoint, knownVariables: knownVariables, knownRoutines: knownRoutines)
        return self
    }

    public var routineMap: [String: MechanismRoutineIR] { Dictionary(uniqueKeysWithValues: routines.map { ($0.name, $0) }) }

    private func validate(statements: [MechanismStatementIR], knownVariables: Set<String>, knownRoutines: Set<String>) throws {
        for statement in statements {
            switch statement {
            case .assignment(let target, _, _), .derivative(let target, _):
                if !knownVariables.contains(target) && !["v", "celsius", "dt", "t"].contains(target) { throw MechanismIRError.unknownSymbol(target) }
            case .call(let name, _):
                if !knownRoutines.contains(name) && !MechanismInterpreter.builtinProcedureNames.contains(name.lowercased()) { throw MechanismIRError.unknownRoutine(name) }
            case .conditional(_, let thenStatements, let otherwiseStatements):
                try validate(statements: thenStatements, knownVariables: knownVariables, knownRoutines: knownRoutines)
                try validate(statements: otherwiseStatements, knownVariables: knownVariables, knownRoutines: knownRoutines)
            case .solve(let block, _):
                if !knownRoutines.contains(block) { throw MechanismIRError.unknownRoutine(block) }
            case .conserve(let terms, _):
                for term in terms where !knownVariables.contains(term.variable) { throw MechanismIRError.unknownSymbol(term.variable) }
            case .reaction(let reactants, let products, _, _):
                for term in reactants + products where !knownVariables.contains(term.variable) { throw MechanismIRError.unknownSymbol(term.variable) }
            case .emitNetEvent, .watch, .returnValue: break
            }
        }
    }
}

public enum MechanismInterpreter {
    public static let builtinProcedureNames: Set<String> = ["setpointer", "net_send", "net_event", "state_discontinuity"]

    public static func execute(
        _ statements: [MechanismStatementIR],
        symbols: inout [String: Double],
        functions: [String: MechanismRoutineIR]
    ) throws -> Double? {
        for statement in statements {
            switch statement {
            case .assignment(let target, let index, let expression):
                let value = try expression.evaluate(symbols: symbols, functions: functions)
                if let index {
                    let evaluated = Int(try index.evaluate(symbols: symbols, functions: functions))
                    symbols["\(target)[\(evaluated)]"] = value
                } else { symbols[target] = value }
            case .derivative(let state, let expression):
                symbols["D_\(state)"] = try expression.evaluate(symbols: symbols, functions: functions)
            case .call(let name, let arguments):
                guard let routine = functions[name] else {
                    if builtinProcedureNames.contains(name.lowercased()) { continue }
                    throw MechanismIRError.unknownRoutine(name)
                }
                let values = try arguments.map { try $0.evaluate(symbols: symbols, functions: functions) }
                var scope = symbols
                for (argument, value) in zip(routine.arguments, values) { scope[argument] = value }
                _ = try execute(routine.statements, symbols: &scope, functions: functions)
                for key in symbols.keys where routine.arguments.contains(key) == false { symbols[key] = scope[key] }
            case .conditional(let condition, let thenStatements, let otherwiseStatements):
                let selected = try condition.evaluate(symbols: symbols, functions: functions) != 0 ? thenStatements : otherwiseStatements
                if let result = try execute(selected, symbols: &symbols, functions: functions) { return result }
            case .solve(let block, _):
                guard let routine = functions[block] else { throw MechanismIRError.unknownRoutine(block) }
                _ = try execute(routine.statements, symbols: &symbols, functions: functions)
            case .conserve(let terms, let total):
                let target = try total.evaluate(symbols: symbols, functions: functions)
                let current = terms.reduce(0) { $0 + $1.coefficient * (symbols[$1.variable] ?? 0) }
                if let last = terms.last, last.coefficient != 0 {
                    symbols[last.variable, default: 0] += (target - current) / last.coefficient
                }
            case .reaction, .emitNetEvent, .watch: continue
            case .returnValue(let expression): return try expression.evaluate(symbols: symbols, functions: functions)
            }
        }
        return nil
    }

    public static func executeFunction(_ routine: MechanismRoutineIR, symbols: inout [String: Double], functions: [String: MechanismRoutineIR]) throws -> Double {
        guard let result = try execute(routine.statements, symbols: &symbols, functions: functions) else {
            throw MechanismIRError.functionWithoutReturn(routine.name)
        }
        return result
    }
}

public enum MechanismIRError: Error, Sendable, CustomStringConvertible {
    case missingName
    case duplicateVariable
    case duplicateRoutine
    case invalidArrayCount(String)
    case invalidBounds(String)
    case unknownSymbol(String)
    case unknownRoutine(String)
    case functionWithoutReturn(String)
    case routineArity(name: String, expected: Int, actual: Int)
    case expressionDomain(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .missingName: return "Mechanism has no name"
        case .duplicateVariable: return "Mechanism contains duplicate variables"
        case .duplicateRoutine: return "Mechanism contains duplicate routines"
        case .invalidArrayCount(let name): return "Mechanism variable \(name) has an invalid array count"
        case .invalidBounds(let name): return "Mechanism variable \(name) has invalid bounds"
        case .unknownSymbol(let name): return "Unknown mechanism symbol \(name)"
        case .unknownRoutine(let name): return "Unknown mechanism routine \(name)"
        case .functionWithoutReturn(let name): return "Mechanism function \(name) completed without a return value"
        case .routineArity(let name, let expected, let actual): return "Routine \(name) expects \(expected) arguments, received \(actual)"
        case .expressionDomain(let reason): return "Mechanism expression domain error: \(reason)"
        case .unsupported(let reason): return "Unsupported mechanism construct: \(reason)"
        }
    }
}
