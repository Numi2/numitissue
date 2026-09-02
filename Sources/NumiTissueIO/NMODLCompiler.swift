import Foundation

/// Portable, deliberately bounded NMODL frontend. It accepts the mechanism subset that can execute
/// identically in the CPU reference VM and the Metal VM and rejects host-language escape hatches.
public enum NMODLCompiler {
    public static func load(url: URL) throws -> MechanismModelIR {
        try compile(String(contentsOf: url, encoding: .utf8), sourceName: url.lastPathComponent)
    }

    public static func compile(_ source: String, sourceName: String = "memory.mod") throws -> MechanismModelIR {
        let cleaned = try NMODLCleaner.clean(source)
        var scanner = NMODLBlockScanner(cleaned)
        let blocks = try scanner.scan()
        guard !blocks.isEmpty else { throw NMODLCompileError.noBlocks }

        var model = MechanismModelIR(
            name: sourceName.lowercased().hasSuffix(".mod") ? String(sourceName.dropLast(4)) : sourceName,
            sourceMetadata: ["format": "NMODL", "source": sourceName, "frontend": "NumiTissue portable"]
        )
        for block in blocks where block.keyword == "NEURON" { try parseNeuron(block.body, into: &model) }
        for block in blocks {
            switch block.keyword {
            case "PARAMETER": model.variables.append(contentsOf: try parseDeclarations(block.body, role: .parameter))
            case "STATE": model.variables.append(contentsOf: try parseDeclarations(block.body, role: .state))
            case "ASSIGNED": model.variables.append(contentsOf: try parseDeclarations(block.body, role: .assigned))
            default: break
            }
        }
        addImplicitVariables(to: &model)
        applyStorageRoles(to: &model)

        for block in blocks {
            switch block.keyword {
            case "INITIAL": model.initial = try NMODLBodyParser(block.body).parse().statements
            case "BREAKPOINT": model.breakpoint = try NMODLBodyParser(block.body).parse().statements
            case "BEFORE": model.beforeStep.append(contentsOf: try NMODLBodyParser(block.body).parse().statements)
            case "AFTER": model.afterStep.append(contentsOf: try NMODLBodyParser(block.body).parse().statements)
            case "PROCEDURE", "FUNCTION", "DERIVATIVE", "KINETIC", "LINEAR", "NONLINEAR", "DISCRETE", "NET_RECEIVE":
                model.routines.append(try parseRoutine(block))
            case "NEURON", "PARAMETER", "STATE", "ASSIGNED", "UNITS", "CONSTANT", "TITLE", "INDEPENDENT":
                break
            case "VERBATIM": throw NMODLCompileError.unsupported("VERBATIM")
            default:
                model.sourceMetadata["ignored.\(block.keyword.lowercased())"] = "true"
            }
        }
        normalizeFunctionReturns(in: &model)
        return try model.validated()
    }

    private static func parseNeuron(_ source: String, into model: inout MechanismModelIR) throws {
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let words = line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard let directive = words.first?.uppercased() else { continue }
            switch directive {
            case "SUFFIX":
                guard words.count == 2 else { throw NMODLCompileError.malformedDirective(line) }
                model.name = words[1]; model.kind = .density
            case "POINT_PROCESS":
                guard words.count == 2 else { throw NMODLCompileError.malformedDirective(line) }
                model.name = words[1]; model.kind = .pointProcess
            case "ARTIFICIAL_CELL":
                guard words.count == 2 else { throw NMODLCompileError.malformedDirective(line) }
                model.name = words[1]; model.kind = .artificialCell
            case "JUNCTION":
                guard words.count == 2 else { throw NMODLCompileError.malformedDirective(line) }
                model.name = words[1]; model.kind = .junction
            case "RANGE": model.rangeVariables.append(contentsOf: words.dropFirst())
            case "GLOBAL": model.globalVariables.append(contentsOf: words.dropFirst())
            case "POINTER", "BBCOREPOINTER": model.pointerVariables.append(contentsOf: words.dropFirst())
            case "NONSPECIFIC_CURRENT", "ELECTRODE_CURRENT": model.nonspecificCurrents.append(contentsOf: words.dropFirst())
            case "USEION": try parseUseIon(words, into: &model)
            case "THREADSAFE": model.sourceMetadata["threadsafe"] = "true"
            default: break
            }
        }
    }

    private static func parseUseIon(_ words: [String], into model: inout MechanismModelIR) throws {
        guard words.count >= 2 else { throw NMODLCompileError.malformedDirective(words.joined(separator: " ")) }
        var reads: [String] = []
        var writes: [String] = []
        var valence: Int?
        var mode = ""
        var index = 2
        while index < words.count {
            let word = words[index]
            switch word.uppercased() {
            case "READ", "WRITE", "VALENCE": mode = word.uppercased()
            default:
                switch mode {
                case "READ": reads.append(word)
                case "WRITE": writes.append(word)
                case "VALENCE": valence = Int(word); mode = ""
                default: break
                }
            }
            index += 1
        }
        model.ions.append(MechanismIonAccessIR(ion: words[1], readVariables: reads, writeVariables: writes, valence: valence))
    }

    private static func parseDeclarations(_ source: String, role: MechanismVariableRoleIR) throws -> [MechanismVariableIR] {
        var output: [MechanismVariableIR] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            var bounds: (Double?, Double?) = (nil, nil)
            if let opening = line.lastIndex(of: "<"), let closing = line[opening...].firstIndex(of: ">") {
                let values = line[line.index(after: opening)..<closing].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard values.count == 2 else { throw NMODLCompileError.malformedDeclaration(line) }
                bounds = (Double(values[0]), Double(values[1]))
                line.removeSubrange(opening...closing)
            }
            var unit: String?
            if line.last == ")", let opening = matchingOpeningParenthesis(in: line) {
                unit = String(line[line.index(after: opening)..<line.index(before: line.endIndex)]).trimmingCharacters(in: .whitespaces)
                line.removeSubrange(opening..<line.endIndex)
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if let equals = assignmentIndex(line) {
                let left = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let right = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                let variable = try parseVariableToken(left)
                guard let defaultValue = Double(right), defaultValue.isFinite else { throw NMODLCompileError.malformedDeclaration(String(raw)) }
                output.append(MechanismVariableIR(name: variable.name, role: role, unit: unit, defaultValue: defaultValue, lowerBound: bounds.0, upperBound: bounds.1, arrayCount: variable.count))
            } else {
                for token in line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) {
                    let variable = try parseVariableToken(token)
                    output.append(MechanismVariableIR(name: variable.name, role: role, unit: unit, lowerBound: bounds.0, upperBound: bounds.1, arrayCount: variable.count))
                }
            }
        }
        return output
    }

    private static func parseRoutine(_ block: NMODLSourceBlock) throws -> MechanismRoutineIR {
        let signature = try parseSignature(block.header, keyword: block.keyword)
        let parsed = try NMODLBodyParser(block.body).parse()
        let kind: MechanismRoutineKindIR
        switch block.keyword {
        case "FUNCTION": kind = .function
        case "DERIVATIVE": kind = .derivative
        case "KINETIC": kind = .kinetic
        case "LINEAR": kind = .linear
        case "NONLINEAR": kind = .nonlinear
        case "DISCRETE": kind = .discrete
        case "NET_RECEIVE": kind = .netReceive
        default: kind = .procedure
        }
        return MechanismRoutineIR(
            name: block.keyword == "NET_RECEIVE" ? "NET_RECEIVE" : signature.name,
            kind: kind,
            arguments: signature.arguments,
            localVariables: parsed.locals,
            statements: parsed.statements
        )
    }

    private static func parseSignature(_ header: String, keyword: String) throws -> (name: String, arguments: [String]) {
        let remainder = String(header.dropFirst(keyword.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword == "NET_RECEIVE" { return ("NET_RECEIVE", try arguments(in: remainder)) }
        guard !remainder.isEmpty else { throw NMODLCompileError.malformedRoutineHeader(header) }
        guard let opening = remainder.firstIndex(of: "(") else {
            return (remainder.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? remainder, [])
        }
        let name = String(remainder[..<opening]).trimmingCharacters(in: .whitespaces)
        return (name, try arguments(in: String(remainder[opening...])))
    }

    private static func arguments(in source: String) throws -> [String] {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let opening = trimmed.firstIndex(of: "("), let closing = trimmed.lastIndex(of: ")"), opening < closing else {
            throw NMODLCompileError.malformedRoutineHeader(source)
        }
        return trimmed[trimmed.index(after: opening)..<closing].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func addImplicitVariables(to model: inout MechanismModelIR) {
        var known = Set(model.variables.map(\.name))
        func add(_ name: String, role: MechanismVariableRoleIR) {
            guard known.insert(name).inserted else { return }
            model.variables.append(MechanismVariableIR(name: name, role: role))
        }
        add("v", role: .assigned); add("dt", role: .assigned); add("t", role: .assigned); add("celsius", role: .assigned)
        for ion in model.ions {
            ion.readVariables.forEach { add($0, role: .ionRead) }
            ion.writeVariables.forEach { add($0, role: .ionWrite) }
        }
        model.nonspecificCurrents.forEach { add($0, role: .assigned) }
        model.pointerVariables.forEach { add($0, role: .assigned) }
    }

    private static func applyStorageRoles(to model: inout MechanismModelIR) {
        let ranges = Set(model.rangeVariables)
        let globals = Set(model.globalVariables)
        for index in model.variables.indices {
            if globals.contains(model.variables[index].name) { model.variables[index].role = .global }
            else if ranges.contains(model.variables[index].name), model.variables[index].role == .assigned { model.variables[index].role = .range }
        }
    }

    private static func normalizeFunctionReturns(in model: inout MechanismModelIR) {
        for index in model.routines.indices where model.routines[index].kind == .function {
            let name = model.routines[index].name
            model.routines[index].statements = rewriteReturnAssignments(model.routines[index].statements, functionName: name)
            if !containsReturn(model.routines[index].statements) {
                if !model.routines[index].localVariables.contains(where: { $0.name == name }) {
                    model.routines[index].localVariables.append(MechanismVariableIR(name: name, role: .local, defaultValue: 0))
                }
                model.routines[index].statements.append(.returnValue(.symbol(name)))
            }
        }
    }

    private static func rewriteReturnAssignments(_ statements: [MechanismStatementIR], functionName: String) -> [MechanismStatementIR] {
        statements.map {
            switch $0 {
            case .assignment(let target, nil, let expression) where target == functionName: return .returnValue(expression)
            case .conditional(let condition, let thenStatements, let otherwiseStatements):
                return .conditional(condition: condition, then: rewriteReturnAssignments(thenStatements, functionName: functionName), otherwise: rewriteReturnAssignments(otherwiseStatements, functionName: functionName))
            default: return $0
            }
        }
    }

    private static func containsReturn(_ statements: [MechanismStatementIR]) -> Bool {
        statements.contains {
            switch $0 {
            case .returnValue: return true
            case .conditional(_, let lhs, let rhs): return containsReturn(lhs) || containsReturn(rhs)
            default: return false
            }
        }
    }

    private static func parseVariableToken(_ source: String) throws -> (name: String, count: Int) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw NMODLCompileError.malformedDeclaration(source) }
        if let opening = trimmed.firstIndex(of: "[") {
            guard let closing = trimmed.lastIndex(of: "]"), opening < closing,
                  let count = Int(trimmed[trimmed.index(after: opening)..<closing]), count > 0 else {
                throw NMODLCompileError.malformedDeclaration(source)
            }
            return (String(trimmed[..<opening]), count)
        }
        return (trimmed, 1)
    }

    private static func matchingOpeningParenthesis(in line: String) -> String.Index? {
        var depth = 0
        var index = line.index(before: line.endIndex)
        while true {
            if line[index] == ")" { depth += 1 }
            else if line[index] == "(" {
                depth -= 1
                if depth == 0 { return index }
            }
            if index == line.startIndex { break }
            index = line.index(before: index)
        }
        return nil
    }

    private static func assignmentIndex(_ source: String) -> String.Index? {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case "=" where depth == 0:
                let previous = index > source.startIndex ? source[source.index(before: index)] : " "
                let nextIndex = source.index(after: index)
                let next = nextIndex < source.endIndex ? source[nextIndex] : " "
                if previous != "<" && previous != ">" && previous != "!" && previous != "=" && next != "=" { return index }
            default: break
            }
        }
        return nil
    }
}

private enum NMODLCleaner {
    static func clean(_ source: String) throws -> String {
        var value = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = try removeDelimited(value, start: "COMMENT", end: "ENDCOMMENT")
        if value.range(of: "VERBATIM", options: .caseInsensitive) != nil { throw NMODLCompileError.unsupported("VERBATIM") }
        var output: [String] = []
        for raw in value.split(whereSeparator: \.isNewline, omittingEmptySubsequences: false) {
            let line = String(raw)
            var comment: String.Index?
            var parentheses = 0
            for index in line.indices {
                let c = line[index]
                if c == "(" { parentheses += 1 }
                else if c == ")" { parentheses -= 1 }
                else if c == ":" && parentheses == 0 {
                    let previous = index > line.startIndex ? line[line.index(before: index)] : " "
                    if previous.isWhitespace || index == line.startIndex { comment = index; break }
                }
            }
            output.append(comment.map { String(line[..<$0]) } ?? line)
        }
        return output.joined(separator: "\n")
    }

    private static func removeDelimited(_ source: String, start: String, end: String) throws -> String {
        var result = source
        while let startRange = result.range(of: start, options: .caseInsensitive) {
            guard let endRange = result.range(of: end, options: .caseInsensitive, range: startRange.upperBound..<result.endIndex) else {
                throw NMODLCompileError.unterminatedBlock(start)
            }
            result.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        }
        return result
    }
}

private struct NMODLSourceBlock {
    var keyword: String
    var header: String
    var body: String
}

private struct NMODLBlockScanner {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) { characters = Array(source) }

    mutating func scan() throws -> [NMODLSourceBlock] {
        var result: [NMODLSourceBlock] = []
        while index < characters.count {
            skipWhitespace()
            guard index < characters.count else { break }
            let headerStart = index
            while index < characters.count && characters[index] != "{" && characters[index] != "\n" { index += 1 }
            if index >= characters.count || characters[index] == "\n" { index += index < characters.count ? 1 : 0; continue }
            let header = String(characters[headerStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            index += 1
            let bodyStart = index
            var depth = 1
            while index < characters.count && depth > 0 {
                if characters[index] == "{" { depth += 1 }
                else if characters[index] == "}" { depth -= 1 }
                index += 1
            }
            guard depth == 0 else { throw NMODLCompileError.unterminatedBlock(header) }
            let body = String(characters[bodyStart..<(index - 1)])
            let keyword = header.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() } ?? ""
            if !keyword.isEmpty { result.append(NMODLSourceBlock(keyword: keyword, header: header, body: body)) }
        }
        return result
    }

    private mutating func skipWhitespace() {
        while index < characters.count && characters[index].isWhitespace { index += 1 }
    }
}

private struct NMODLParsedBody {
    var statements: [MechanismStatementIR]
    var locals: [MechanismVariableIR]
}

private struct NMODLBodyParser {
    private let characters: [Character]
    private var index = 0
    private var locals: [MechanismVariableIR] = []

    init(_ source: String) { characters = Array(source) }

    mutating func parse() throws -> NMODLParsedBody {
        NMODLParsedBody(statements: try statements(untilBrace: false), locals: locals)
    }

    private mutating func statements(untilBrace: Bool) throws -> [MechanismStatementIR] {
        var output: [MechanismStatementIR] = []
        while index < characters.count {
            skipSeparators()
            guard index < characters.count else { break }
            if untilBrace && characters[index] == "}" { index += 1; break }
            if keyword("IF") { output.append(try parseIf()) }
            else if keyword("LOCAL") { try parseLocal(readLine()) }
            else if keyword("SOLVE") { output.append(try parseSolve(readLine())) }
            else if keyword("CONSERVE") { output.append(try parseConserve(readLine())) }
            else if keyword("WATCH") { output.append(try parseWatch(readLine())) }
            else if keyword("NET_EVENT") { output.append(try parseNetEvent(readLine())) }
            else if characters[index] == "~" { index += 1; output.append(try parseReaction(readLine())) }
            else {
                let line = readLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { output.append(try parseSimple(line)) }
            }
        }
        return output
    }

    private mutating func parseIf() throws -> MechanismStatementIR {
        skipWhitespace()
        let condition = try parenthesized()
        skipWhitespace()
        guard character("{") else { throw NMODLCompileError.malformedStatement("IF without body") }
        let thenStatements = try statements(untilBrace: true)
        skipSeparators()
        var otherwise: [MechanismStatementIR] = []
        if keyword("ELSE") {
            skipWhitespace()
            if keyword("IF") { otherwise = [try parseIf()] }
            else {
                guard character("{") else { throw NMODLCompileError.malformedStatement("ELSE without body") }
                otherwise = try statements(untilBrace: true)
            }
        }
        return .conditional(condition: try NMODLMechanismExpressionParser.parse(condition), then: thenStatements, otherwise: otherwise)
    }

    private mutating func parseLocal(_ source: String) throws {
        for token in source.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) where !token.isEmpty {
            let variable = try localVariable(token)
            if !locals.contains(where: { $0.name == variable.name }) {
                locals.append(MechanismVariableIR(name: variable.name, role: .local, defaultValue: 0, arrayCount: variable.count))
            }
        }
    }

    private func localVariable(_ source: String) throws -> (name: String, count: Int) {
        if let opening = source.firstIndex(of: "[") {
            guard let closing = source.lastIndex(of: "]"), let count = Int(source[source.index(after: opening)..<closing]), count > 0 else {
                throw NMODLCompileError.malformedStatement("LOCAL \(source)")
            }
            return (String(source[..<opening]), count)
        }
        return (source, 1)
    }

    private func parseSolve(_ source: String) throws -> MechanismStatementIR {
        let words = source.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let block = words.first else { throw NMODLCompileError.malformedStatement("SOLVE") }
        let method: MechanismSolveMethodIR
        if let methodIndex = words.firstIndex(where: { $0.uppercased() == "METHOD" }), methodIndex + 1 < words.count {
            method = MechanismSolveMethodIR(rawValue: words[methodIndex + 1].lowercased()) ?? .unknown
        } else { method = .direct }
        return .solve(block: block, method: method)
    }

    private func parseConserve(_ source: String) throws -> MechanismStatementIR {
        guard let equals = assignmentIndex(source) else { throw NMODLCompileError.malformedStatement("CONSERVE \(source)") }
        let lhs = source[..<equals]
        let rhs = String(source[source.index(after: equals)...])
        var terms: [MechanismConservationTermIR] = []
        for raw in lhs.split(separator: "+") {
            let words = raw.split(whereSeparator: \.isWhitespace)
            if words.count == 1 { terms.append(.init(variable: String(words[0]))) }
            else if words.count == 2, let coefficient = Double(words[0]) { terms.append(.init(variable: String(words[1]), coefficient: coefficient)) }
            else { throw NMODLCompileError.malformedStatement("CONSERVE \(source)") }
        }
        return .conserve(terms: terms, total: try NMODLMechanismExpressionParser.parse(rhs))
    }

    private func parseWatch(_ source: String) throws -> MechanismStatementIR {
        guard let opening = source.firstIndex(of: "(") else { throw NMODLCompileError.malformedStatement("WATCH \(source)") }
        var depth = 0
        var closing: String.Index?
        for index in source[opening...].indices {
            if source[index] == "(" { depth += 1 }
            else if source[index] == ")" { depth -= 1; if depth == 0 { closing = index; break } }
        }
        guard let closing else { throw NMODLCompileError.malformedStatement("WATCH \(source)") }
        let condition = String(source[source.index(after: opening)..<closing])
        let flagText = String(source[source.index(after: closing)...]).trimmingCharacters(in: .whitespaces)
        guard let flag = Int(flagText) else { throw NMODLCompileError.malformedStatement("WATCH \(source)") }
        return .watch(condition: try NMODLMechanismExpressionParser.parse(condition), flag: flag)
    }

    private func parseNetEvent(_ source: String) throws -> MechanismStatementIR {
        let arguments = try callArguments(source)
        guard arguments.count == 1 else { throw NMODLCompileError.malformedStatement("NET_EVENT \(source)") }
        return .emitNetEvent(arguments[0])
    }

    private func parseReaction(_ source: String) throws -> MechanismStatementIR {
        let arrow = source.contains("<->") ? "<->" : (source.contains("->") ? "->" : nil)
        guard let arrow else { throw NMODLCompileError.malformedReaction(source) }
        let sides = source.components(separatedBy: arrow)
        guard sides.count == 2, let rateOpen = sides[1].lastIndex(of: "("), let rateClose = sides[1].lastIndex(of: ")"), rateOpen < rateClose else {
            throw NMODLCompileError.malformedReaction(source)
        }
        let rates = splitTopLevel(String(sides[1][sides[1].index(after: rateOpen)..<rateClose]), separator: ",")
        guard rates.count == 1 || rates.count == 2 else { throw NMODLCompileError.malformedReaction(source) }
        return .reaction(
            reactants: try reactionTerms(sides[0]),
            products: try reactionTerms(String(sides[1][..<rateOpen])),
            forward: try NMODLMechanismExpressionParser.parse(rates[0]),
            reverse: rates.count == 2 ? try NMODLMechanismExpressionParser.parse(rates[1]) : nil
        )
    }

    private func reactionTerms(_ source: String) throws -> [MechanismReactionTermIR] {
        let source = source.trimmingCharacters(in: .whitespaces)
        if source.isEmpty || source == "0" { return [] }
        return try source.split(separator: "+").map {
            let words = $0.split(whereSeparator: \.isWhitespace)
            if words.count == 1 { return .init(variable: String(words[0])) }
            if words.count == 2, let coefficient = UInt8(words[0]) { return .init(variable: String(words[1]), coefficient: coefficient) }
            throw NMODLCompileError.malformedReaction(source)
        }
    }

    private func parseSimple(_ source: String) throws -> MechanismStatementIR {
        if let range = derivativeAssignmentRange(source) {
            return .derivative(state: String(source[..<range.lowerBound]).trimmingCharacters(in: .whitespaces), expression: try NMODLMechanismExpressionParser.parse(String(source[range.upperBound...])))
        }
        if let equals = assignmentIndex(source) {
            let target = String(source[..<equals]).trimmingCharacters(in: .whitespaces)
            let expression = try NMODLMechanismExpressionParser.parse(String(source[source.index(after: equals)...]))
            if let opening = target.firstIndex(of: "[") {
                guard let closing = target.lastIndex(of: "]") else { throw NMODLCompileError.malformedStatement(source) }
                return .assignment(target: String(target[..<opening]), index: try NMODLMechanismExpressionParser.parse(String(target[target.index(after: opening)..<closing])), expression: expression)
            }
            return .assignment(target: target, index: nil, expression: expression)
        }
        if source.contains("(") {
            let name = String(source[..<(source.firstIndex(of: "(")!)]).trimmingCharacters(in: .whitespaces)
            return .call(name: name, arguments: try callArguments(source))
        }
        throw NMODLCompileError.malformedStatement(source)
    }

    private func callArguments(_ source: String) throws -> [MechanismExpressionIR] {
        guard let opening = source.firstIndex(of: "("), let closing = source.lastIndex(of: ")"), opening < closing else { throw NMODLCompileError.malformedStatement(source) }
        let body = String(source[source.index(after: opening)..<closing]).trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return [] }
        return try splitTopLevel(body, separator: ",").map(NMODLMechanismExpressionParser.parse)
    }

    private mutating func parenthesized() throws -> String {
        guard character("(") else { throw NMODLCompileError.malformedStatement("Expected (") }
        let start = index
        var depth = 1
        while index < characters.count {
            if characters[index] == "(" { depth += 1 }
            else if characters[index] == ")" {
                depth -= 1
                if depth == 0 { let value = String(characters[start..<index]); index += 1; return value }
            }
            index += 1
        }
        throw NMODLCompileError.malformedStatement("Unterminated expression")
    }

    private mutating func readLine() -> String {
        let start = index
        var depth = 0
        while index < characters.count {
            let c = characters[index]
            if c == "(" || c == "[" { depth += 1 }
            else if c == ")" || c == "]" { depth -= 1 }
            if depth == 0 && (c == "\n" || c == ";" || c == "}") { break }
            index += 1
        }
        let value = String(characters[start..<index])
        if index < characters.count && (characters[index] == "\n" || characters[index] == ";") { index += 1 }
        return value
    }

    private mutating func skipWhitespace() { while index < characters.count && characters[index].isWhitespace { index += 1 } }
    private mutating func skipSeparators() { while index < characters.count && (characters[index].isWhitespace || characters[index] == ";") { index += 1 } }

    private mutating func keyword(_ value: String) -> Bool {
        skipWhitespace()
        let token = Array(value.uppercased())
        guard index + token.count <= characters.count else { return false }
        for offset in token.indices where String(characters[index + offset]).uppercased() != String(token[offset]) { return false }
        let end = index + token.count
        if end < characters.count && (characters[end].isLetter || characters[end].isNumber || characters[end] == "_") { return false }
        index = end
        return true
    }

    private mutating func character(_ value: Character) -> Bool {
        skipWhitespace(); guard index < characters.count && characters[index] == value else { return false }; index += 1; return true
    }

    private func derivativeAssignmentRange(_ source: String) -> Range<String.Index>? {
        source.range(of: "'=") ?? source.range(of: "' =")
    }

    private func assignmentIndex(_ source: String) -> String.Index? {
        var depth = 0
        for index in source.indices {
            switch source[index] {
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case "=" where depth == 0:
                let previous = index > source.startIndex ? source[source.index(before: index)] : " "
                let nextIndex = source.index(after: index)
                let next = nextIndex < source.endIndex ? source[nextIndex] : " "
                if previous != "<" && previous != ">" && previous != "!" && previous != "=" && next != "=" { return index }
            default: break
            }
        }
        return nil
    }
}

private enum NMODLExpressionToken: Equatable {
    case number(Double), identifier(String)
    case plus, minus, star, slash, power, bang
    case leftParen, rightParen, leftBracket, rightBracket, comma, question, colon
    case less, lessEqual, greater, greaterEqual, equal, notEqual, logicalAnd, logicalOr
    case end
}

private struct NMODLExpressionLexer {
    private let characters: [Character]
    private var index = 0

    init(_ source: String) { characters = Array(source) }

    mutating func next() throws -> NMODLExpressionToken {
        while index < characters.count && characters[index].isWhitespace { index += 1 }
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
        case "^": return .power
        case "(": return .leftParen
        case ")": return .rightParen
        case "[": return .leftBracket
        case "]": return .rightBracket
        case ",": return .comma
        case "?": return .question
        case ":": return .colon
        case "!": return consume("=") ? .notEqual : .bang
        case "<": return consume("=") ? .lessEqual : .less
        case ">": return consume("=") ? .greaterEqual : .greater
        case "=": guard consume("=") else { throw NMODLCompileError.invalidExpression("single =") }; return .equal
        case "&": guard consume("&") else { throw NMODLCompileError.invalidExpression("single &") }; return .logicalAnd
        case "|": guard consume("|") else { throw NMODLCompileError.invalidExpression("single |") }; return .logicalOr
        default: throw NMODLCompileError.invalidExpression("character \(c)")
        }
    }

    private mutating func consume(_ value: Character) -> Bool { guard index < characters.count, characters[index] == value else { return false }; index += 1; return true }

    private mutating func identifier() -> NMODLExpressionToken {
        let start = index; index += 1
        while index < characters.count && (characters[index].isLetter || characters[index].isNumber || characters[index] == "_" || characters[index] == ".") { index += 1 }
        return .identifier(String(characters[start..<index]))
    }

    private mutating func number() throws -> NMODLExpressionToken {
        let start = index
        var digit = false
        var decimal = false
        while index < characters.count {
            if characters[index].isNumber { digit = true; index += 1 }
            else if characters[index] == "." && !decimal { decimal = true; index += 1 }
            else { break }
        }
        if index < characters.count && (characters[index] == "e" || characters[index] == "E") {
            index += 1
            if index < characters.count && (characters[index] == "+" || characters[index] == "-") { index += 1 }
            while index < characters.count && characters[index].isNumber { index += 1 }
        }
        let text = String(characters[start..<index])
        guard digit, let value = Double(text), value.isFinite else { throw NMODLCompileError.invalidExpression(text) }
        return .number(value)
    }
}

private struct NMODLMechanismExpressionParser {
    private var lexer: NMODLExpressionLexer
    private var current: NMODLExpressionToken

    init(_ source: String) throws {
        var lexer = NMODLExpressionLexer(source)
        current = try lexer.next()
        self.lexer = lexer
    }

    static func parse(_ source: String) throws -> MechanismExpressionIR {
        let normalized = source
            .replacingOccurrences(of: ".gt.", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: ".ge.", with: ">=", options: .caseInsensitive)
            .replacingOccurrences(of: ".lt.", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: ".le.", with: "<=", options: .caseInsensitive)
            .replacingOccurrences(of: ".eq.", with: "==", options: .caseInsensitive)
            .replacingOccurrences(of: ".ne.", with: "!=", options: .caseInsensitive)
        var parser = try Self(normalized)
        let result = try parser.conditional()
        guard parser.current == .end else { throw NMODLCompileError.invalidExpression(source) }
        return result
    }

    private mutating func advance() throws { current = try lexer.next() }

    private mutating func conditional() throws -> MechanismExpressionIR {
        let condition = try logicalOr()
        guard current == .question else { return condition }
        try advance(); let thenValue = try conditional()
        guard current == .colon else { throw NMODLCompileError.invalidExpression("missing :") }
        try advance(); return .conditional(condition: condition, then: thenValue, otherwise: try conditional())
    }

    private mutating func logicalOr() throws -> MechanismExpressionIR {
        var value = try logicalAnd()
        while current == .logicalOr { try advance(); value = .binary(.logicalOr, value, try logicalAnd()) }
        return value
    }

    private mutating func logicalAnd() throws -> MechanismExpressionIR {
        var value = try comparison()
        while current == .logicalAnd { try advance(); value = .binary(.logicalAnd, value, try comparison()) }
        return value
    }

    private mutating func comparison() throws -> MechanismExpressionIR {
        var value = try additive()
        while true {
            let operation: MechanismBinaryOperatorIR
            switch current {
            case .less: operation = .less
            case .lessEqual: operation = .lessOrEqual
            case .greater: operation = .greater
            case .greaterEqual: operation = .greaterOrEqual
            case .equal: operation = .equal
            case .notEqual: operation = .notEqual
            default: return value
            }
            try advance(); value = .binary(operation, value, try additive())
        }
    }

    private mutating func additive() throws -> MechanismExpressionIR {
        var value = try multiplicative()
        while current == .plus || current == .minus {
            let operation: MechanismBinaryOperatorIR = current == .plus ? .add : .subtract
            try advance(); value = .binary(operation, value, try multiplicative())
        }
        return value
    }

    private mutating func multiplicative() throws -> MechanismExpressionIR {
        var value = try exponentiation()
        while current == .star || current == .slash {
            let operation: MechanismBinaryOperatorIR = current == .star ? .multiply : .divide
            try advance(); value = .binary(operation, value, try exponentiation())
        }
        return value
    }

    private mutating func exponentiation() throws -> MechanismExpressionIR {
        let value = try unary()
        guard current == .power else { return value }
        try advance(); return .binary(.power, value, try exponentiation())
    }

    private mutating func unary() throws -> MechanismExpressionIR {
        switch current {
        case .plus: try advance(); return .unary(.plus, try unary())
        case .minus: try advance(); return .unary(.negate, try unary())
        case .bang: try advance(); return .unary(.logicalNot, try unary())
        default: return try primary()
        }
    }

    private mutating func primary() throws -> MechanismExpressionIR {
        switch current {
        case .number(let value): try advance(); return .constant(value)
        case .identifier(let name):
            try advance()
            if current == .leftParen {
                try advance(); var arguments: [MechanismExpressionIR] = []
                if current != .rightParen {
                    while true { arguments.append(try conditional()); if current != .comma { break }; try advance() }
                }
                guard current == .rightParen else { throw NMODLCompileError.invalidExpression("missing )") }
                try advance(); return .call(name, arguments)
            }
            if current == .leftBracket {
                try advance(); let index = try conditional()
                guard current == .rightBracket else { throw NMODLCompileError.invalidExpression("missing ]") }
                try advance(); return .indexedSymbol(name, index)
            }
            return .symbol(name)
        case .leftParen:
            try advance(); let value = try conditional()
            guard current == .rightParen else { throw NMODLCompileError.invalidExpression("missing )") }
            try advance(); return value
        default: throw NMODLCompileError.invalidExpression("unexpected token")
        }
    }
}

private func splitTopLevel(_ source: String, separator: Character) -> [String] {
    var output: [String] = []
    var start = source.startIndex
    var depth = 0
    for index in source.indices {
        let c = source[index]
        if c == "(" || c == "[" { depth += 1 }
        else if c == ")" || c == "]" { depth -= 1 }
        else if c == separator && depth == 0 { output.append(String(source[start..<index]).trimmingCharacters(in: .whitespaces)); start = source.index(after: index) }
    }
    output.append(String(source[start...]).trimmingCharacters(in: .whitespaces))
    return output
}

public enum NMODLCompileError: Error, Sendable, CustomStringConvertible {
    case noBlocks
    case unterminatedBlock(String)
    case malformedDirective(String)
    case malformedDeclaration(String)
    case malformedRoutineHeader(String)
    case malformedStatement(String)
    case malformedReaction(String)
    case invalidExpression(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .noBlocks: return "NMODL source contains no blocks"
        case .unterminatedBlock(let value): return "Unterminated NMODL block \(value)"
        case .malformedDirective(let value): return "Malformed NMODL directive: \(value)"
        case .malformedDeclaration(let value): return "Malformed NMODL declaration: \(value)"
        case .malformedRoutineHeader(let value): return "Malformed NMODL routine header: \(value)"
        case .malformedStatement(let value): return "Malformed NMODL statement: \(value)"
        case .malformedReaction(let value): return "Malformed NMODL reaction: \(value)"
        case .invalidExpression(let value): return "Invalid NMODL expression: \(value)"
        case .unsupported(let value): return "NMODL construct \(value) is outside the portable subset"
        }
    }
}
