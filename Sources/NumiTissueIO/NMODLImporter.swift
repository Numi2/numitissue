import Foundation

public enum NMODLImporter {
    public static func load(url: URL) throws -> MechanismModelIR {
        try parse(String(contentsOf: url, encoding: .utf8), sourceName: url.lastPathComponent)
    }

    public static func parse(_ source: String, sourceName: String = "memory.mod") throws -> MechanismModelIR {
        let sanitized = try NMODLPreprocessor.sanitize(source)
        let blocks = try NMODLTopLevelScanner(source: sanitized).scan()
        guard !blocks.isEmpty else { throw NMODLError.noBlocks }

        var model = MechanismModelIR(name: sourceName.replacingOccurrences(of: ".mod", with: ""))
        model.sourceMetadata = ["format": "NMODL", "source": sourceName]

        for block in blocks where block.keyword == "NEURON" {
            try parseNeuronBlock(block.body, into: &model)
        }
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
            case "INITIAL":
                model.initial = try NMODLStatementParser.parse(block.body).statements
            case "BREAKPOINT":
                model.breakpoint = try NMODLStatementParser.parse(block.body).statements
            case "BEFORE":
                model.beforeStep.append(contentsOf: try NMODLStatementParser.parse(block.body).statements)
            case "AFTER":
                model.afterStep.append(contentsOf: try NMODLStatementParser.parse(block.body).statements)
            case "DERIVATIVE", "KINETIC", "LINEAR", "NONLINEAR", "DISCRETE", "PROCEDURE", "FUNCTION", "NET_RECEIVE":
                model.routines.append(try parseRoutine(block))
            default: break
            }
        }
        model = normalizeFunctionReturns(model)
        return try model.validated()
    }

    private static func parseNeuronBlock(_ source: String, into model: inout MechanismModelIR) throws {
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let words = line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard let directive = words.first?.uppercased() else { continue }
            switch directive {
            case "SUFFIX":
                guard words.count >= 2 else { throw NMODLError.malformedDirective(line) }
                model.name = words[1]
                model.kind = .density
            case "POINT_PROCESS":
                guard words.count >= 2 else { throw NMODLError.malformedDirective(line) }
                model.name = words[1]
                model.kind = .pointProcess
            case "ARTIFICIAL_CELL":
                guard words.count >= 2 else { throw NMODLError.malformedDirective(line) }
                model.name = words[1]
                model.kind = .artificialCell
            case "JUNCTION":
                guard words.count >= 2 else { throw NMODLError.malformedDirective(line) }
                model.name = words[1]
                model.kind = .junction
            case "USEION":
                guard words.count >= 2 else { throw NMODLError.malformedDirective(line) }
                let ion = words[1]
                var reads: [String] = []
                var writes: [String] = []
                var valence: Int?
                var mode: String?
                for word in words.dropFirst(2) {
                    switch word.uppercased() {
                    case "READ", "WRITE", "VALENCE": mode = word.uppercased()
                    default:
                        switch mode {
                        case "READ": reads.append(word)
                        case "WRITE": writes.append(word)
                        case "VALENCE": valence = Int(word); mode = nil
                        default: break
                        }
                }
                model.ions.append(MechanismIonAccessIR(ion: ion, readVariables: reads, writeVariables: writes, valence: valence))
            case "RANGE": model.rangeVariables.append(contentsOf: words.dropFirst())
            case "GLOBAL": model.globalVariables.append(contentsOf: words.dropFirst())
            case "POINTER", "BBCOREPOINTER": model.pointerVariables.append(contentsOf: words.dropFirst())
            case "NONSPECIFIC_CURRENT", "ELECTRODE_CURRENT": model.nonspecificCurrents.append(contentsOf: words.dropFirst())
            default: break
            }
        }
    }

    private static func parseDeclarations(_ source: String, role: MechanismVariableRoleIR) throws -> [MechanismVariableIR] {
        var declarations: [MechanismVariableIR] = []
        for rawLine in source.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if let colon = line.firstIndex(of: ":") { line = String(line[..<colon]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }

            let bounds = extractDelimited(&line, opening: "<", closing: ">")
            let unit = extractTrailingUnit(&line)
            let parsedBounds: (Double?, Double?)
            if let bounds {
                let pieces = bounds.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pieces.count == 2 else { throw NMODLError.malformedDeclaration(String(rawLine)) }
                parsedBounds = (Double(pieces[0]), Double(pieces[1]))
            } else { parsedBounds = (nil, nil) }

            if let equals = topLevelIndex(of: "=", in: line) {
                let left = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let right = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                let (name, count) = try parseVariableName(left)
                guard let value = Double(right), value.isFinite else { throw NMODLError.malformedDeclaration(String(rawLine)) }
                declarations.append(MechanismVariableIR(
                    name: name,
                    role: role,
                    unit: unit,
                    defaultValue: value,
                    lowerBound: parsedBounds.0,
                    upperBound: parsedBounds.1,
                    arrayCount: count
                ))
            } else {
                let names = line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
                for token in names {
                    let (name, count) = try parseVariableName(token)
                    declarations.append(MechanismVariableIR(
                        name: name,
                        role: role,
                        unit: unit,
                        lowerBound: parsedBounds.0,
                        upperBound: parsedBounds.1,
                        arrayCount: count
                    ))
                }
            }
        }
        return declarations
    }

    private static func parseRoutine(_ block: NMODLBlock) throws -> MechanismRoutineIR {
        let kind: MechanismRoutineKindIR
        switch block.keyword {
        case "DERIVATIVE": kind = .derivative
        case "KINETIC": kind = .kinetic
        case "LINEAR": kind = .linear
        case "NONLINEAR": kind = .nonlinear
        case "DISCRETE": kind = .discrete
        case "FUNCTION": kind = .function
        case "NET_RECEIVE": kind = .netReceive
        default: kind = .procedure
        }
        let signature = try parseSignature(block.header, keyword: block.keyword)
        let parsed = try NMODLStatementParser.parse(block.body)
        return MechanismRoutineIR(
            name: block.keyword == "NET_RECEIVE" ? "NET_RECEIVE" : signature.name,
            kind: kind,
            arguments: signature.arguments,
            localVariables: parsed.locals,
            statements: parsed.statements
        )
    }

    private static func parseSignature(_ header: String, keyword: String) throws -> (name: String, arguments: [String]) {
        let remainder = header.dropFirst(keyword.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword == "NET_RECEIVE" {
            let arguments = try parseArguments(from: remainder)
            return ("NET_RECEIVE", arguments)
        }
        guard !remainder.isEmpty else { throw NMODLError.malformedRoutineHeader(header) }
        if let opening = remainder.firstIndex(of: "(") {
            let name = remainder[..<opening].trimmingCharacters(in: .whitespaces)
            return (name, try parseArguments(from: String(remainder[opening...])))
        }
        return (remainder.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? remainder, [])
    }

    private static func parseArguments(from source: String) throws -> [String] {
        guard let opening = source.firstIndex(of: "("), let closing = source.lastIndex(of: ")"), opening < closing else {
            return source.trimmingCharacters(in: .whitespaces).isEmpty ? [] : { throw NMODLError.malformedRoutineHeader(source) }()
        }
        return source[source.index(after: opening)..<closing]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func addImplicitVariables(to model: inout MechanismModelIR) {
        var known = Set(model.variables.map(\.name))
        func add(_ name: String, role: MechanismVariableRoleIR) {
            guard known.insert(name).inserted else { return }
            model.variables.append(MechanismVariableIR(name: name, role: role))
        }
        add("v", role: .assigned)
        add("dt", role: .assigned)
        add("t", role: .assigned)
        add("celsius", role: .assigned)
        for ion in model.ions {
            for name in ion.readVariables { add(name, role: .ionRead) }
            for name in ion.writeVariables { add(name, role: .ionWrite) }
        }
        for name in model.nonspecificCurrents { add(name, role: .assigned) }
        for name in model.pointerVariables { add(name, role: .assigned) }
    }

    private static func applyStorageRoles(to model: inout MechanismModelIR) {
        let ranges = Set(model.rangeVariables)
        let globals = Set(model.globalVariables)
        for index in model.variables.indices {
            if globals.contains(model.variables[index].name) { model.variables[index].role = .global }
            else if ranges.contains(model.variables[index].name), model.variables[index].role == .assigned { model.variables[index].role = .range }
        }
    }

    private static func normalizeFunctionReturns(_ input: MechanismModelIR) -> MechanismModelIR {
        var output = input
        for routineIndex in output.routines.indices where output.routines[routineIndex].kind == .function {
            let functionName = output.routines[routineIndex].name
            output.routines[routineIndex].statements = normalizeReturns(output.routines[routineIndex].statements, functionName: functionName)
            if !containsReturn(output.routines[routineIndex].statements) {
                output.routines[routineIndex].statements.append(.returnValue(.symbol(functionName)))
                if !output.routines[routineIndex].localVariables.contains(where: { $0.name == functionName }) {
                    output.routines[routineIndex].localVariables.append(MechanismVariableIR(name: functionName, role: .local, defaultValue: 0))
                }
            }
        }
        return output
    }

    private static func normalizeReturns(_ statements: [MechanismStatementIR], functionName: String) -> [MechanismStatementIR] {
        statements.map { statement in
            switch statement {
            case .assignment(let target, nil, let expression) where target == functionName:
                return .returnValue(expression)
            case .conditional(let condition, let thenStatements, let otherwiseStatements):
                return .conditional(
                    condition: condition,
                    then: normalizeReturns(thenStatements, functionName: functionName),
                    otherwise: normalizeReturns(otherwiseStatements, functionName: functionName)
                )
            default: return statement
            }
        }
    }

    private static func containsReturn(_ statements: [MechanismStatementIR]) -> Bool {
        statements.contains { statement in
            switch statement {
            case .returnValue: return true
            case .conditional(_, let lhs, let rhs): return containsReturn(lhs) || containsReturn(rhs)
            default: return false
            }
        }
    }

    private static func parseVariableName(_ source: String) throws -> (String, Int) {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if let opening = trimmed.firstIndex(of: "[") {
            guard let closing = trimmed.lastIndex(of: "]"), opening < closing,
                  let count = Int(trimmed[trimmed.index(after: opening)..<closing]), count > 0 else {
                throw NMODLError.malformedDeclaration(source)
            }
            return (String(trimmed[..<opening]), count)
        }
        guard !trimmed.isEmpty else { throw NMODLError.malformedDeclaration(source) }
        return (trimmed, 1)
    }

    private static func extractDelimited(_ line: inout String, opening: Character, closing: Character) -> String? {
        guard let start = line.lastIndex(of: opening), let end = line[start...].firstIndex(of: closing) else { return nil }
        let value = String(line[line.index(after: start)..<end])
        line.removeSubrange(start...end)
        line = line.trimmingCharacters(in: .whitespaces)
        return value
    }

    private static func extractTrailingUnit(_ line: inout String) -> String? {
        guard let end = line.lastIndex(of: ")"), end == line.index(before: line.endIndex) else { return nil }
        var depth = 0
        var index = end
        while true {
            let character = line[index]
            if character == ")" { depth += 1 }
            else if character == "(" {
                depth -= 1
                if depth == 0 {
                    let value = String(line[line.index(after: index)..<end]).trimmingCharacters(in: .whitespaces)
                    line.removeSubrange(index...end)
                    line = line.trimmingCharacters(in: .whitespaces)
                    return value
                }
            }
            guard index > line.startIndex else { return nil }
            index = line.index(before: index)
        }
    }

    private static func topLevelIndex(of character: Character, in source: String) -> String.Index? {
        var parentheses = 0
        var brackets = 0
        for index in source.indices {
            switch source[index] {
            case "(": parentheses += 1
            case ")": parentheses -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
            if source[index] == character && parentheses == 0 && brackets == 0 { return index }
        }
        return nil
    }
}

private struct NMODLBlock {
    var keyword: String
    var header: String
    var body: String
}

private enum NMODLPreprocessor {
    static func sanitize(_ source: String) throws -> String {
        var value = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        value = try removeDelimited(value, start: "COMMENT", end: "ENDCOMMENT", caseInsensitive: true)
        if value.range(of: "VERBATIM", options: .caseInsensitive) != nil {
            throw NMODLError.unsupported("VERBATIM blocks are not permitted in portable mechanisms")
        }
        var lines: [String] = []
        for line in value.split(whereSeparator: \.isNewline, omittingEmptySubsequences: false) {
            let text = String(line)
            var quoteDepth = 0
            var commentIndex: String.Index?
            for index in text.indices {
                let c = text[index]
                if c == "\"" { quoteDepth ^= 1 }
                if c == ":" && quoteDepth == 0 {
                    let previous = index > text.startIndex ? text[text.index(before: index)] : " "
                    if previous.isWhitespace || index == text.startIndex { commentIndex = index; break }
                }
            }
            lines.append(commentIndex.map { String(text[..<$0]) } ?? text)
        }
        return lines.joined(separator: "\n")
    }

    private static func removeDelimited(_ source: String, start: String, end: String, caseInsensitive: Bool) throws -> String {
        var value = source
        let options: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []
        while let startRange = value.range(of: start, options: options) {
            guard let endRange = value.range(of: end, options: options, range: startRange.upperBound..<value.endIndex) else {
                throw NMODLError.unterminatedBlock(start)
            }
            value.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
        }
        return value
    }
}

private struct NMODLTopLevelScanner {
    let characters: [Character]
    var index = 0

    init(source: String) { characters = Array(source) }

    mutating func scan() throws -> [NMODLBlock] {
        var blocks: [NMODLBlock] = []
        while index < characters.count {
            skipWhitespace()
            guard index < characters.count else { break }
            let headerStart = index
            var opening: Int?
            while index < characters.count {
                if characters[index] == "{" { opening = index; break }
                if characters[index] == "\n" {
                    index += 1
                    break
                }
                index += 1
            }
            guard let opening else { continue }
            let header = String(characters[headerStart..<opening]).trimmingCharacters(in: .whitespacesAndNewlines)
            index = opening + 1
            let bodyStart = index
            var depth = 1
            while index < characters.count && depth > 0 {
                if characters[index] == "{" { depth += 1 }
                else if characters[index] == "}" { depth -= 1 }
                index += 1
            }
            guard depth == 0 else { throw NMODLError.unterminatedBlock(header) }
            let bodyEnd = index - 1
            let keyword = header.split(whereSeparator: \.isWhitespace).first.map { $0.uppercased() } ?? ""
            guard !keyword.isEmpty else { continue }
            blocks.append(NMODLBlock(keyword: keyword, header: header, body: String(characters[bodyStart..<bodyEnd])))
        }
        return blocks
    }

    private mutating func skipWhitespace() {
        while index < characters.count && characters[index].isWhitespace { index += 1 }
    }
}

private struct NMODLStatementParseResult {
    var statements: [MechanismStatementIR]
    var locals: [MechanismVariableIR]
}

private struct NMODLStatementParser {
    let characters: [Character]
    var index = 0
    var locals: [MechanismVariableIR] = []

    static func parse(_ source: String) throws -> NMODLStatementParseResult {
        var parser = Self(characters: Array(source))
        let statements = try parser.parseStatements(untilClosingBrace: false)
        return NMODLStatementParseResult(statements: statements, locals: parser.locals)
    }

    mutating func parseStatements(untilClosingBrace: Bool) throws -> [MechanismStatementIR] {
        var statements: [MechanismStatementIR] = []
        while index < characters.count {
            skipSeparators()
            guard index < characters.count else { break }
            if untilClosingBrace && characters[index] == "}" { index += 1; break }
            if consumeKeyword("IF") {
                statements.append(try parseIf())
            } else if consumeKeyword("LOCAL") {
                let line = readLogicalLine()
                for name in line.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter({ !$0.isEmpty }) {
                    let base = name.split(separator: "[").first.map(String.init) ?? name
                    locals.append(MechanismVariableIR(name: base, role: .local))
                }
            } else if consumeKeyword("SOLVE") {
                statements.append(try parseSolve(readLogicalLine()))
            } else if consumeKeyword("CONSERVE") {
                statements.append(try parseConserve(readLogicalLine()))
            } else if consumeKeyword("WATCH") {
                statements.append(try parseWatch(readLogicalLine()))
            } else if consumeKeyword("NET_EVENT") {
                let content = readLogicalLine().trimmingCharacters(in: .whitespaces)
                let arguments = try parseCallArguments(content)
                guard arguments.count == 1 else { throw NMODLError.malformedStatement("NET_EVENT \(content)") }
                statements.append(.emitNetEvent(arguments[0]))
            } else if characters[index] == "~" {
                index += 1
                statements.append(try parseReaction(readLogicalLine()))
            } else {
                let line = readLogicalLine().trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { statements.append(try parseSimple(line)) }
            }
        }
        return statements
    }

    private mutating func parseIf() throws -> MechanismStatementIR {
        skipWhitespace()
        let conditionSource = try readParenthesized()
        skipWhitespace()
        guard consumeCharacter("{") else { throw NMODLError.malformedStatement("IF without body") }
        let thenStatements = try parseStatements(untilClosingBrace: true)
        skipSeparators()
        var otherwise: [MechanismStatementIR] = []
        if consumeKeyword("ELSE") {
            skipWhitespace()
            if consumeKeyword("IF") {
                otherwise = [try parseIf()]
            } else {
                guard consumeCharacter("{") else { throw NMODLError.malformedStatement("ELSE without body") }
                otherwise = try parseStatements(untilClosingBrace: true)
            }
        }
        return .conditional(condition: try NMODLExpressionParser.parse(conditionSource), then: thenStatements, otherwise: otherwise)
    }

    private func parseSolve(_ source: String) throws -> MechanismStatementIR {
        let tokens = source.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let block = tokens.first else { throw NMODLError.malformedStatement("SOLVE") }
        var method: MechanismSolveMethodIR = .direct
        if let methodIndex = tokens.firstIndex(where: { $0.uppercased() == "METHOD" }), methodIndex + 1 < tokens.count {
            method = MechanismSolveMethodIR(rawValue: tokens[methodIndex + 1].lowercased()) ?? .unknown
        }
        return .solve(block: block, method: method)
    }

    private func parseConserve(_ source: String) throws -> MechanismStatementIR {
        guard let equals = source.firstIndex(of: "=") else { throw NMODLError.malformedStatement("CONSERVE \(source)") }
        let lhs = source[..<equals]
        let rhs = source[source.index(after: equals)...]
        var terms: [MechanismConservationTermIR] = []
        for raw in lhs.split(separator: "+") {
            let value = raw.trimmingCharacters(in: .whitespaces)
            let pieces = value.split(whereSeparator: \.isWhitespace)
            if pieces.count == 1 { terms.append(MechanismConservationTermIR(variable: String(pieces[0]))) }
            else if pieces.count == 2, let coefficient = Double(pieces[0]) { terms.append(MechanismConservationTermIR(variable: String(pieces[1]), coefficient: coefficient)) }
            else { throw NMODLError.malformedStatement("CONSERVE \(source)") }
        }
        return .conserve(terms: terms, total: try NMODLExpressionParser.parse(String(rhs)))
    }

    private func parseWatch(_ source: String) throws -> MechanismStatementIR {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "(" else { throw NMODLError.malformedStatement("WATCH \(source)") }
        let chars = Array(trimmed)
        var depth = 0
        var closing: Int?
        for index in chars.indices {
            if chars[index] == "(" { depth += 1 }
            else if chars[index] == ")" {
                depth -= 1
                if depth == 0 { closing = index; break }
            }
        }
        guard let closing else { throw NMODLError.malformedStatement("WATCH \(source)") }
        let condition = String(chars[1..<closing])
        let flagText = String(chars[(closing + 1)...]).trimmingCharacters(in: .whitespaces)
        guard let flag = Int(flagText) else { throw NMODLError.malformedStatement("WATCH \(source)") }
        return .watch(condition: try NMODLExpressionParser.parse(condition), flag: flag)
    }

    private func parseReaction(_ source: String) throws -> MechanismStatementIR {
        let arrow: String
        if source.contains("<->") { arrow = "<->" }
        else if source.contains("->") { arrow = "->" }
        else { throw NMODLError.malformedReaction(source) }
        let sides = source.components(separatedBy: arrow)
        guard sides.count == 2 else { throw NMODLError.malformedReaction(source) }
        guard let rateOpen = sides[1].lastIndex(of: "("), let rateClose = sides[1].lastIndex(of: ")"), rateOpen < rateClose else {
            throw NMODLError.malformedReaction(source)
        }
        let productSource = String(sides[1][..<rateOpen])
        let rateSource = sides[1][sides[1].index(after: rateOpen)..<rateClose]
        let rates = splitTopLevel(String(rateSource), separator: ",")
        guard rates.count == 1 || rates.count == 2 else { throw NMODLError.malformedReaction(source) }
        return .reaction(
            reactants: try parseReactionTerms(sides[0]),
            products: try parseReactionTerms(productSource),
            forward: try NMODLExpressionParser.parse(rates[0]),
            reverse: rates.count == 2 ? try NMODLExpressionParser.parse(rates[1]) : nil
        )
    }

    private func parseReactionTerms(_ source: String) throws -> [MechanismReactionTermIR] {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "0" { return [] }
        return try trimmed.split(separator: "+").map { raw in
            let term = raw.trimmingCharacters(in: .whitespaces)
            let pieces = term.split(whereSeparator: \.isWhitespace)
            if pieces.count == 1 { return MechanismReactionTermIR(variable: String(pieces[0])) }
            if pieces.count == 2, let value = UInt8(pieces[0]) { return MechanismReactionTermIR(variable: String(pieces[1]), coefficient: value) }
            throw NMODLError.malformedReaction(source)
        }
    }

    private func parseSimple(_ source: String) throws -> MechanismStatementIR {
        if let derivative = source.range(of: "'=") ?? source.range(of: "' =") {
            let name = source[..<derivative.lowerBound].trimmingCharacters(in: .whitespaces)
            let rhs = source[derivative.upperBound...]
            return .derivative(state: name, expression: try NMODLExpressionParser.parse(String(rhs)))
        }
        if let equals = assignmentIndex(source) {
            let lhs = source[..<equals].trimmingCharacters(in: .whitespaces)
            let rhs = source[source.index(after: equals)...]
            let (name, index) = try parseTarget(lhs)
            return .assignment(target: name, index: index, expression: try NMODLExpressionParser.parse(String(rhs)))
        }
        if source.contains("(") {
            let name = source[..<(source.firstIndex(of: "(")!)].trimmingCharacters(in: .whitespaces)
            return .call(name: name, arguments: try parseCallArguments(String(source[source.firstIndex(of: "(")!... ])))
        }
        throw NMODLError.malformedStatement(source)
    }

    private func parseTarget(_ source: String) throws -> (String, MechanismExpressionIR?) {
        if let opening = source.firstIndex(of: "[") {
            guard let closing = source.lastIndex(of: "]"), opening < closing else { throw NMODLError.malformedStatement(source) }
            let name = String(source[..<opening]).trimmingCharacters(in: .whitespaces)
            let index = try NMODLExpressionParser.parse(String(source[source.index(after: opening)..<closing]))
            return (name, index)
        }
        return (source, nil)
    }

    private func assignmentIndex(_ source: String) -> String.Index? {
        var previous: Character?
        var parentheses = 0
        for index in source.indices {
            let current = source[index]
            if current == "(" { parentheses += 1 }
            if current == ")" { parentheses -= 1 }
            if current == "=" && parentheses == 0 && previous != "<" && previous != ">" && previous != "!" && previous != "=" {
                let next = source.index(after: index)
                if next == source.endIndex || source[next] != "=" { return index }
            }
            previous = current
        }
        return nil
    }

    private func parseCallArguments(_ source: String) throws -> [MechanismExpressionIR] {
        guard let opening = source.firstIndex(of: "("), let closing = source.lastIndex(of: ")"), opening < closing else {
            throw NMODLError.malformedStatement(source)
        }
        let body = String(source[source.index(after: opening)..<closing])
        if body.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return try splitTopLevel(body, separator: ",").map(NMODLExpressionParser.parse)
    }

    private mutating func readParenthesized() throws -> String {
        guard consumeCharacter("(") else { throw NMODLError.malformedStatement("Expected parenthesized expression") }
        let start = index
        var depth = 1
        while index < characters.count {
            if characters[index] == "(" { depth += 1 }
            else if characters[index] == ")" {
                depth -= 1
                if depth == 0 {
                    let result = String(characters[start..<index])
                    index += 1
                    return result
                }
            }
            index += 1
        }
        throw NMODLError.malformedStatement("Unterminated parenthesized expression")
    }

    private mutating func readLogicalLine() -> String {
        let start = index
        var parentheses = 0
        while index < characters.count {
            let character = characters[index]
            if character == "(" || character == "[" { parentheses += 1 }
            else if character == ")" || character == "]" { parentheses -= 1 }
            if parentheses == 0 && (character == "\n" || character == ";" || character == "}") { break }
            index += 1
        }
        let result = String(characters[start..<index])
        if index < characters.count && (characters[index] == "\n" || characters[index] == ";") { index += 1 }
        return result
    }

    private mutating func skipWhitespace() {
        while index < characters.count && characters[index].isWhitespace { index += 1 }
    }

    private mutating func skipSeparators() {
        while index < characters.count && (characters[index].isWhitespace || characters[index] == ";") { index += 1 }
    }

    private mutating func consumeKeyword(_ keyword: String) -> Bool {
        skipWhitespace()
        let upper = Array(keyword.uppercased())
        guard index + upper.count <= characters.count else { return false }
        for offset in upper.indices where String(characters[index + offset]).uppercased() != String(upper[offset]) { return false }
        let end = index + upper.count
        if end < characters.count && (characters[end].isLetter || characters[end].isNumber || characters[end] == "_") { return false }
        index = end
        return true
    }

    private mutating func consumeCharacter(_ character: Character) -> Bool {
        skipWhitespace()
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }
}

private enum NMODLExpressionParser {
    static func parse(_ source: String) throws -> MechanismExpressionIR {
        var parser = NMODLExpressionPrattParser(source: normalize(source))
        let result = try parser.parseExpression()
        guard parser.current == .end else { throw NMODLError.invalidExpression(source) }
        return result
    }

    private static func normalize(_ source: String) -> String {
        source
            .replacingOccurrences(of: ".gt.", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: ".ge.", with: ">=", options: .caseInsensitive)
            .replacingOccurrences(of: ".lt.", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: ".le.", with: "<=", options: .caseInsensitive)
            .replacingOccurrences(of: ".eq.", with: "==", options: .caseInsensitive)
            .replacingOccurrences(of: ".ne.", with: "!=", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum NMODLExpressionToken: Equatable {
    case number(Double), identifier(String)
    case plus, minus, star, slash, caret, bang
    case leftParen, rightParen, leftBracket, rightBracket, comma
    case less, lessEqual, greater, greaterEqual, equalEqual, notEqual, logicalAnd, logicalOr
    case question, colon, end
}

private struct NMODLExpressionLexer {
    let characters: [Character]
    var index = 0

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
        case "^": return .caret
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
        case "=": guard consume("=") else { throw NMODLError.invalidExpression("single =") }; return .equalEqual
        case "&": guard consume("&") else { throw NMODLError.invalidExpression("single &") }; return .logicalAnd
        case "|": guard consume("|") else { throw NMODLError.invalidExpression("single |") }; return .logicalOr
        default: throw NMODLError.invalidExpression("character \(c)")
        }
    }

    private mutating func consume(_ c: Character) -> Bool {
        guard index < characters.count, characters[index] == c else { return false }
        index += 1
        return true
    }

    private mutating func identifier() -> NMODLExpressionToken {
        let start = index
        index += 1
        while index < characters.count {
            let c = characters[index]
            guard c.isLetter || c.isNumber || c == "_" || c == "." else { break }
            index += 1
        }
        return .identifier(String(characters[start..<index]))
    }

    private mutating func number() throws -> NMODLExpressionToken {
        let start = index
        var dot = false
        var digit = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber { digit = true; index += 1 }
            else if c == "." && !dot { dot = true; index += 1 }
            else { break }
        }
        if index < characters.count && (characters[index] == "e" || characters[index] == "E") {
            index += 1
            if index < characters.count && (characters[index] == "+" || characters[index] == "-") { index += 1 }
            while index < characters.count && characters[index].isNumber { index += 1 }
        }
        let text = String(characters[start..<index])
        guard digit, let value = Double(text), value.isFinite else { throw NMODLError.invalidExpression(text) }
        return .number(value)
    }
}

private struct NMODLExpressionPrattParser {
    var lexer: NMODLExpressionLexer
    var current: NMODLExpressionToken

    init(source: String) {
        var lexer = NMODLExpressionLexer(source)
        current = (try? lexer.next()) ?? .end
        self.lexer = lexer
    }

    mutating func parseExpression() throws -> MechanismExpressionIR { try conditional() }

    private mutating func advance() throws { current = try lexer.next() }

    private mutating func conditional() throws -> MechanismExpressionIR {
        let condition = try logicalOr()
        guard current == .question else { return condition }
        try advance()
        let thenValue = try conditional()
        guard current == .colon else { throw NMODLError.invalidExpression("missing :") }
        try advance()
        return .conditional(condition: condition, then: thenValue, otherwise: try conditional())
    }

    private mutating func logicalOr() throws -> MechanismExpressionIR {
        var result = try logicalAnd()
        while current == .logicalOr { try advance(); result = .binary(.logicalOr, result, try logicalAnd()) }
        return result
    }

    private mutating func logicalAnd() throws -> MechanismExpressionIR {
        var result = try comparison()
        while current == .logicalAnd { try advance(); result = .binary(.logicalAnd, result, try comparison()) }
        return result
    }

    private mutating func comparison() throws -> MechanismExpressionIR {
        var result = try additive()
        while true {
            let operation: MechanismBinaryOperatorIR
            switch current {
            case .less: operation = .less
            case .lessEqual: operation = .lessOrEqual
            case .greater: operation = .greater
            case .greaterEqual: operation = .greaterOrEqual
            case .equalEqual: operation = .equal
            case .notEqual: operation = .notEqual
            default: return result
            }
            try advance()
            result = .binary(operation, result, try additive())
        }
    }

    private mutating func additive() throws -> MechanismExpressionIR {
        var result = try multiplicative()
        while current == .plus || current == .minus {
            let operation: MechanismBinaryOperatorIR = current == .plus ? .add : .subtract
            try advance()
            result = .binary(operation, result, try multiplicative())
        }
        return result
    }

    private mutating func multiplicative() throws -> MechanismExpressionIR {
        var result = try power()
        while current == .star || current == .slash {
            let operation: MechanismBinaryOperatorIR = current == .star ? .multiply : .divide
            try advance()
            result = .binary(operation, result, try power())
        }
        return result
    }

    private mutating func power() throws -> MechanismExpressionIR {
        let result = try unary()
        guard current == .caret else { return result }
        try advance()
        return .binary(.power, result, try power())
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
                try advance()
                var arguments: [MechanismExpressionIR] = []
                if current != .rightParen {
                    while true {
                        arguments.append(try conditional())
                        if current != .comma { break }
                        try advance()
                    }
                }
                guard current == .rightParen else { throw NMODLError.invalidExpression("missing )") }
                try advance()
                return .call(name, arguments)
            }
            if current == .leftBracket {
                try advance()
                let index = try conditional()
                guard current == .rightBracket else { throw NMODLError.invalidExpression("missing ]") }
                try advance()
                return .indexedSymbol(name, index)
            }
            return .symbol(name)
        case .leftParen:
            try advance()
            let result = try conditional()
            guard current == .rightParen else { throw NMODLError.invalidExpression("missing )") }
            try advance()
            return result
        default: throw NMODLError.invalidExpression("unexpected token")
        }
    }
}

private func splitTopLevel(_ source: String, separator: Character) -> [String] {
    var result: [String] = []
    var start = source.startIndex
    var depth = 0
    for index in source.indices {
        let character = source[index]
        if character == "(" || character == "[" { depth += 1 }
        else if character == ")" || character == "]" { depth -= 1 }
        else if character == separator && depth == 0 {
            result.append(String(source[start..<index]).trimmingCharacters(in: .whitespaces))
            start = source.index(after: index)
        }
    }
    result.append(String(source[start...]).trimmingCharacters(in: .whitespaces))
    return result
}

public enum NMODLError: Error, Sendable, CustomStringConvertible {
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
        case .unsupported(let value): return "Unsupported NMODL construct: \(value)"
        }
    }
}
