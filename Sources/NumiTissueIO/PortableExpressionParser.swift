import Foundation

public enum PortableExpressionParser {
    public static func parse(_ source: String) throws -> PortableExpressionIR {
        var parser = Parser(source: source)
        let expression = try parser.parseExpression()
        guard parser.current == .end else { throw PortableExpressionParseError.unexpectedToken(parser.current.description, offset: parser.offset) }
        return expression
    }

    private enum Token: Equatable {
        case number(Double)
        case identifier(String)
        case plus, minus, star, slash, caret
        case leftParen, rightParen, comma
        case less, lessEqual, greater, greaterEqual, equalEqual, notEqual
        case logicalAnd, logicalOr, bang
        case question, colon
        case end

        var description: String {
            switch self {
            case .number(let value): return String(value)
            case .identifier(let value): return value
            case .plus: return "+"
            case .minus: return "-"
            case .star: return "*"
            case .slash: return "/"
            case .caret: return "^"
            case .leftParen: return "("
            case .rightParen: return ")"
            case .comma: return ","
            case .less: return "<"
            case .lessEqual: return "<="
            case .greater: return ">"
            case .greaterEqual: return ">="
            case .equalEqual: return "=="
            case .notEqual: return "!="
            case .logicalAnd: return "&&"
            case .logicalOr: return "||"
            case .bang: return "!"
            case .question: return "?"
            case .colon: return ":"
            case .end: return "end of expression"
            }
        }
    }

    private struct Lexer {
        let characters: [Character]
        var index = 0

        init(source: String) { characters = Array(source) }

        var offset: Int { index }

        mutating func next() throws -> Token {
            skipWhitespace()
            guard index < characters.count else { return .end }
            let c = characters[index]
            if c.isNumber || c == "." { return try number() }
            if c.isLetter || c == "_" { return identifier() }
            index += 1
            switch c {
            case "+": return .plus
            case "-": return .minus
            case "*": return .star
            case "/": return .slash
            case "^": return .caret
            case "(": return .leftParen
            case ")": return .rightParen
            case ",": return .comma
            case "?": return .question
            case ":": return .colon
            case "<":
                if consume("=") { return .lessEqual }
                return .less
            case ">":
                if consume("=") { return .greaterEqual }
                return .greater
            case "=":
                guard consume("=") else { throw PortableExpressionParseError.invalidCharacter("=", offset: index - 1) }
                return .equalEqual
            case "!":
                if consume("=") { return .notEqual }
                return .bang
            case "&":
                guard consume("&") else { throw PortableExpressionParseError.invalidCharacter("&", offset: index - 1) }
                return .logicalAnd
            case "|":
                guard consume("|") else { throw PortableExpressionParseError.invalidCharacter("|", offset: index - 1) }
                return .logicalOr
            default: throw PortableExpressionParseError.invalidCharacter(c, offset: index - 1)
            }
        }

        private mutating func skipWhitespace() {
            while index < characters.count && characters[index].isWhitespace { index += 1 }
        }

        private mutating func consume(_ character: Character) -> Bool {
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }

        private mutating func identifier() -> Token {
            let start = index
            index += 1
            while index < characters.count {
                let c = characters[index]
                guard c.isLetter || c.isNumber || c == "_" || c == "." else { break }
                index += 1
            }
            return .identifier(String(characters[start..<index]))
        }

        private mutating func number() throws -> Token {
            let start = index
            var sawDigit = false
            var sawDot = false
            while index < characters.count {
                let c = characters[index]
                if c.isNumber { sawDigit = true; index += 1; continue }
                if c == "." && !sawDot { sawDot = true; index += 1; continue }
                break
            }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                let exponentStart = index
                while index < characters.count, characters[index].isNumber { index += 1 }
                guard index > exponentStart else { throw PortableExpressionParseError.invalidNumber(String(characters[start..<index]), offset: start) }
            }
            let text = String(characters[start..<index])
            guard sawDigit, let value = Double(text), value.isFinite else { throw PortableExpressionParseError.invalidNumber(text, offset: start) }
            return .number(value)
        }
    }

    private struct Parser {
        var lexer: Lexer
        var current: Token
        var offset: Int

        init(source: String) {
            var lexer = Lexer(source: source)
            self.current = (try? lexer.next()) ?? .end
            self.offset = lexer.offset
            self.lexer = lexer
        }

        mutating func parseExpression() throws -> PortableExpressionIR { try conditional() }

        private mutating func advance() throws {
            current = try lexer.next()
            offset = lexer.offset
        }

        private mutating func conditional() throws -> PortableExpressionIR {
            let condition = try logicalOr()
            guard current == .question else { return condition }
            try advance()
            let thenValue = try conditional()
            guard current == .colon else { throw PortableExpressionParseError.expected(":", found: current.description, offset: offset) }
            try advance()
            let otherwiseValue = try conditional()
            return .conditional(condition: condition, then: thenValue, otherwise: otherwiseValue)
        }

        private mutating func logicalOr() throws -> PortableExpressionIR {
            var values = [try logicalAnd()]
            while current == .logicalOr {
                try advance()
                values.append(try logicalAnd())
            }
            return values.count == 1 ? values[0] : .logicalOr(values)
        }

        private mutating func logicalAnd() throws -> PortableExpressionIR {
            var values = [try comparison()]
            while current == .logicalAnd {
                try advance()
                values.append(try comparison())
            }
            return values.count == 1 ? values[0] : .logicalAnd(values)
        }

        private mutating func comparison() throws -> PortableExpressionIR {
            var lhs = try additive()
            while true {
                let operation = current
                switch operation {
                case .less, .lessEqual, .greater, .greaterEqual, .equalEqual, .notEqual:
                    try advance()
                    let rhs = try additive()
                    switch operation {
                    case .less: lhs = .less(lhs, rhs)
                    case .lessEqual: lhs = .lessOrEqual(lhs, rhs)
                    case .greater: lhs = .greater(lhs, rhs)
                    case .greaterEqual: lhs = .greaterOrEqual(lhs, rhs)
                    case .equalEqual: lhs = .equal(lhs, rhs)
                    case .notEqual: lhs = .logicalNot(.equal(lhs, rhs))
                    default: break
                    }
                default: return lhs
                }
            }
        }

        private mutating func additive() throws -> PortableExpressionIR {
            var result = try multiplicative()
            while current == .plus || current == .minus {
                let operation = current
                try advance()
                let rhs = try multiplicative()
                result = operation == .plus ? .add([result, rhs]) : .subtract(result, rhs)
            }
            return result
        }

        private mutating func multiplicative() throws -> PortableExpressionIR {
            var result = try power()
            while current == .star || current == .slash {
                let operation = current
                try advance()
                let rhs = try power()
                result = operation == .star ? .multiply([result, rhs]) : .divide(result, rhs)
            }
            return result
        }

        private mutating func power() throws -> PortableExpressionIR {
            let lhs = try unary()
            guard current == .caret else { return lhs }
            try advance()
            return .power(lhs, try power())
        }

        private mutating func unary() throws -> PortableExpressionIR {
            switch current {
            case .plus:
                try advance()
                return try unary()
            case .minus:
                try advance()
                return .subtract(.constant(0), try unary())
            case .bang:
                try advance()
                return .logicalNot(try unary())
            default: return try primary()
            }
        }

        private mutating func primary() throws -> PortableExpressionIR {
            switch current {
            case .number(let value):
                try advance()
                return .constant(value)
            case .identifier(let name):
                try advance()
                if current == .leftParen { return try function(name) }
                switch name.lowercased() {
                case "time", "t": return .time
                case "pi": return .constant(.pi)
                case "e": return .constant(Foundation.exp(1))
                case "true": return .constant(1)
                case "false": return .constant(0)
                default: return .symbol(name)
                }
            case .leftParen:
                try advance()
                let value = try conditional()
                guard current == .rightParen else { throw PortableExpressionParseError.expected(")", found: current.description, offset: offset) }
                try advance()
                return value
            default: throw PortableExpressionParseError.unexpectedToken(current.description, offset: offset)
            }
        }

        private mutating func function(_ name: String) throws -> PortableExpressionIR {
            try advance() // left parenthesis
            var arguments: [PortableExpressionIR] = []
            if current != .rightParen {
                while true {
                    arguments.append(try conditional())
                    guard current == .comma else { break }
                    try advance()
                }
            }
            guard current == .rightParen else { throw PortableExpressionParseError.expected(")", found: current.description, offset: offset) }
            try advance()
            switch name.lowercased() {
            case "exp": return try one(name, arguments, PortableExpressionIR.exponential)
            case "log", "ln": return try one(name, arguments, PortableExpressionIR.logarithm)
            case "abs", "fabs": return try one(name, arguments, PortableExpressionIR.absolute)
            case "sqrt": return try one(name, arguments) { .power($0, .constant(0.5)) }
            case "pow": return try two(name, arguments, PortableExpressionIR.power)
            case "min", "fmin": return .minimum(arguments)
            case "max", "fmax": return .maximum(arguments)
            case "clamp":
                guard arguments.count == 3 else { throw PortableExpressionParseError.invalidArity(name, expected: 3, actual: arguments.count) }
                return .maximum([arguments[1], .minimum([arguments[0], arguments[2]])])
            case "if", "select":
                guard arguments.count == 3 else { throw PortableExpressionParseError.invalidArity(name, expected: 3, actual: arguments.count) }
                return .conditional(condition: arguments[0], then: arguments[1], otherwise: arguments[2])
            default: throw PortableExpressionParseError.unsupportedFunction(name)
            }
        }

        private func one(_ name: String, _ values: [PortableExpressionIR], _ transform: (PortableExpressionIR) -> PortableExpressionIR) throws -> PortableExpressionIR {
            guard values.count == 1 else { throw PortableExpressionParseError.invalidArity(name, expected: 1, actual: values.count) }
            return transform(values[0])
        }

        private func two(_ name: String, _ values: [PortableExpressionIR], _ transform: (PortableExpressionIR, PortableExpressionIR) -> PortableExpressionIR) throws -> PortableExpressionIR {
            guard values.count == 2 else { throw PortableExpressionParseError.invalidArity(name, expected: 2, actual: values.count) }
            return transform(values[0], values[1])
        }
    }
}

public enum PortableExpressionParseError: Error, Sendable, CustomStringConvertible {
    case invalidCharacter(Character, offset: Int)
    case invalidNumber(String, offset: Int)
    case unexpectedToken(String, offset: Int)
    case expected(String, found: String, offset: Int)
    case invalidArity(String, expected: Int, actual: Int)
    case unsupportedFunction(String)

    public var description: String {
        switch self {
        case .invalidCharacter(let character, let offset): return "Invalid expression character \(character) at offset \(offset)"
        case .invalidNumber(let number, let offset): return "Invalid expression number \(number) at offset \(offset)"
        case .unexpectedToken(let token, let offset): return "Unexpected token \(token) at offset \(offset)"
        case .expected(let expected, let found, let offset): return "Expected \(expected), found \(found) at offset \(offset)"
        case .invalidArity(let function, let expected, let actual): return "Function \(function) expects \(expected) arguments, received \(actual)"
        case .unsupportedFunction(let function): return "Unsupported expression function \(function)"
        }
    }
}
