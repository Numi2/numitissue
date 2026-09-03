import Foundation
import NumiTissue

internal enum NumiTissueCommandLine {
    static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "inspect-checkpoint":
            try inspectCheckpoint(tail)
        case "compile-nmodl":
            try compileNMODL(tail)
        case "eval-expr":
            try evaluateExpression(tail)
        case "campaign":
            try campaign(tail)
        case "screening":
            try screening(tail)
        case "organoid":
            try organoid(tail)
        case "wetware":
            try wetware(tail)
        case "validate-experiment":
            try validateExperiment(tail)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw NumiTissueCLIError.unknownCommand(command)
        }
    }

    private static func campaign(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw NumiTissueCLIError.missingArgument("campaign subcommand")
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            repeatableOptions: ["--artifact-sha"]
        )
        switch subcommand {
        case "compile":
            guard parsed.positionals.count == 2 else {
                throw NumiTissueCLIError.usage(
                    "numitissue campaign compile <experiment.json> <output-directory> [--shards N] [--model-sha HEX] [--artifact-sha HEX]"
                )
            }
            let definition: TissueExperimentDefinition = try readJSON(
                at: URL(fileURLWithPath: parsed.positionals[0])
            )
            let options = try campaignOptions(parsed)
            let bundle = try TissueExperimentCampaignCompiler.compile(
                definition,
                options: options,
                createdAt: try parsed.date("--created-at") ?? Date()
            )
            let output = URL(fileURLWithPath: parsed.positionals[1], isDirectory: true)
            try bundle.writeAtomically(to: output)
            try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))

        case "inspect":
            guard parsed.positionals.count == 1 else {
                throw NumiTissueCLIError.usage(
                    "numitissue campaign inspect <bundle-directory>"
                )
            }
            let input = URL(fileURLWithPath: parsed.positionals[0], isDirectory: true)
            let bundle = try TissueExperimentCampaignBundle.read(from: input)
            try emit(CampaignCommandSummary(bundle: bundle, outputPath: input.path))

        default:
            throw NumiTissueCLIError.unknownSubcommand("campaign \(subcommand)")
        }
    }

    private static func screening(_ arguments: [String]) throws {
        guard arguments.first == "compile" else {
            throw NumiTissueCLIError.usage(
                "numitissue screening compile <study.json> <output-directory> [--shards N]"
            )
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            repeatableOptions: ["--artifact-sha"]
        )
        guard parsed.positionals.count == 2 else {
            throw NumiTissueCLIError.usage(
                "numitissue screening compile <study.json> <output-directory> [--shards N]"
            )
        }
        let study: TissueScreeningStudy = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        let bundle = try study.compileCampaign(
            options: campaignOptions(parsed),
            createdAt: try parsed.date("--created-at") ?? Date()
        )
        let output = URL(fileURLWithPath: parsed.positionals[1], isDirectory: true)
        try bundle.writeAtomically(to: output)
        try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))
    }

    private static func organoid(_ arguments: [String]) throws {
        guard arguments.first == "compile" else {
            throw NumiTissueCLIError.usage(
                "numitissue organoid compile <study.json> <output-directory> [--shards N]"
            )
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            repeatableOptions: ["--artifact-sha"]
        )
        guard parsed.positionals.count == 2 else {
            throw NumiTissueCLIError.usage(
                "numitissue organoid compile <study.json> <output-directory> [--shards N]"
            )
        }
        let study: OrganoidFittingStudy = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        let bundle = try study.compileCampaign(
            options: campaignOptions(parsed),
            createdAt: try parsed.date("--created-at") ?? Date()
        )
        let output = URL(fileURLWithPath: parsed.positionals[1], isDirectory: true)
        try bundle.writeAtomically(to: output)
        try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))
    }

    private static func wetware(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw NumiTissueCLIError.missingArgument("wetware subcommand")
        }
        let parsed = try NumiTissueCLIArguments(Array(arguments.dropFirst()))
        switch subcommand {
        case "plan":
            guard parsed.positionals.count == 2 else {
                throw NumiTissueCLIError.usage(
                    "numitissue wetware plan <study.json> <output.json>"
                )
            }
            let study: WetwareOptimizationStudy = try readJSON(
                at: URL(fileURLWithPath: parsed.positionals[0])
            )
            let plan = try study.initialPlan()
            let output = URL(fileURLWithPath: parsed.positionals[1])
            try plan.writeAtomically(to: output)
            try emit(WetwarePlanSummary(plan: plan, outputPath: output.path))

        case "validate":
            guard (2...3).contains(parsed.positionals.count) else {
                throw NumiTissueCLIError.usage(
                    "numitissue wetware validate <protocol.json> <safety.json> [report.json]"
                )
            }
            let protocolValue: WetwareExperimentProtocol = try readJSON(
                at: URL(fileURLWithPath: parsed.positionals[0])
            )
            let envelope: WetwareStimulationSafetyEnvelope = try readJSON(
                at: URL(fileURLWithPath: parsed.positionals[1])
            )
            let report = try WetwareProtocolSafetyValidator.validate(
                protocolValue,
                envelope: envelope
            )
            if parsed.positionals.count == 3 {
                try writeJSON(
                    report,
                    to: URL(fileURLWithPath: parsed.positionals[2])
                )
            }
            try emit(report)
            if !report.passed {
                throw NumiTissueCLIError.wetwareSafetyViolation(
                    count: report.violations.count
                )
            }

        default:
            throw NumiTissueCLIError.unknownSubcommand("wetware \(subcommand)")
        }
    }

    private static func validateExperiment(_ arguments: [String]) throws {
        let parsed = try NumiTissueCLIArguments(arguments)
        guard parsed.positionals.count == 1 else {
            throw NumiTissueCLIError.usage(
                "numitissue validate-experiment <experiment.json>"
            )
        }
        let definition: TissueExperimentDefinition = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        let valid = try definition.validated()
        try emit(ExperimentValidationSummary(definition: valid))
    }

    private static func campaignOptions(
        _ arguments: NumiTissueCLIArguments
    ) throws -> TissueExperimentCampaignOptions {
        let shardCount = try arguments.int("--shards") ?? 1
        let workPerStep = try arguments.uint64("--work-per-step") ?? 1
        let workPerIntervention = try arguments.uint64("--work-per-intervention") ?? 100
        let workPerParameter = try arguments.uint64("--work-per-parameter") ?? 10
        let modelDigest = try arguments.one("--model-sha").map {
            try ScientificSHA256Digest(hexadecimal: $0)
        }
        let artifacts = try arguments.many("--artifact-sha").map {
            try ScientificSHA256Digest(hexadecimal: $0)
        }
        return try TissueExperimentCampaignOptions(
            shardCount: shardCount,
            workUnitsPerStep: workPerStep,
            workUnitsPerIntervention: workPerIntervention,
            workUnitsPerParameter: workPerParameter,
            modelArtifactDigest: modelDigest,
            requiredArtifactDigests: artifacts,
            metadata: [
                "numitissue.cli": "campaign-compile",
                "numitissue.cli_version": "1"
            ]
        ).validated()
    }

    private static func inspectCheckpoint(_ arguments: [String]) throws {
        let parsed = try NumiTissueCLIArguments(arguments)
        guard parsed.positionals.count == 1 else {
            throw NumiTissueCLIError.usage(
                "numitissue inspect-checkpoint <path>"
            )
        }
        let url = URL(fileURLWithPath: parsed.positionals[0])
        let checkpoint = try TissueCheckpointReader.read(from: url)
        let manifest = checkpoint.manifest
        print("checkpoint: \(url.path)")
        print("version: \(manifest.formatVersion)")
        print("epoch: \(manifest.epoch)")
        print("tick: \(manifest.time.tick)")
        print("digest: \(manifest.modelDigest)")
        print("arrays:")
        for descriptor in manifest.arrays.sorted(by: { $0.name < $1.name }) {
            print(
                "  \(descriptor.name): count=\(descriptor.count) stride=\(descriptor.stride) bytes=\(descriptor.byteCount) offset=\(descriptor.byteOffset)"
            )
        }
    }

    private static func compileNMODL(_ arguments: [String]) throws {
        let parsed = try NumiTissueCLIArguments(arguments)
        guard (1...2).contains(parsed.positionals.count) else {
            throw NumiTissueCLIError.usage(
                "numitissue compile-nmodl <path> [artifact-directory]"
            )
        }
        let sourceURL = URL(fileURLWithPath: parsed.positionals[0])
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let options = NMODLCompilerOptions(
            namespace: sourceURL.deletingPathExtension().lastPathComponent
        )
        let result = try NMODLCompiler.compile(source, options: options)
        print("mechanism: \(result.mechanism.name)")
        print("digest: \(result.sourceDigest)")
        print("bytecode words: \(result.artifact.instructions.count)")
        print("constants: \(result.artifact.constants.count)")
        print("state slots: \(result.artifact.stateCount)")
        print("parameter slots: \(result.artifact.parameterCount)")
        print("assigned slots: \(result.artifact.assignedCount)")
        if !result.diagnostics.isEmpty {
            print("diagnostics:")
            for diagnostic in result.diagnostics {
                print("  line \(diagnostic.line): \(diagnostic.message)")
            }
        }
        if parsed.positionals.count == 2 {
            let output = URL(
                fileURLWithPath: parsed.positionals[1],
                isDirectory: true
            )
            let artifactURL = try MechanismArtifactWriter.write(
                artifact: result.artifact,
                name: result.mechanism.name,
                sourceDigest: result.sourceDigest,
                diagnostics: result.diagnostics,
                to: output
            )
            print("artifact: \(artifactURL.path)")
        }
    }

    private static func evaluateExpression(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw NumiTissueCLIError.usage(
                "numitissue eval-expr <expression>"
            )
        }
        let source = arguments.joined(separator: " ")
        let tokens = try NumiTissueExpressionLexer(source: source).tokenize()
        let node = try NumiTissueExpressionParser(tokens: tokens).parse()
        print(try NumiTissueExpressionEvaluator.evaluate(node))
    }

    private static func readJSON<T: Decodable>(at url: URL) throws -> T {
        do {
            return try ScientificCanonicalJSON.decode(
                T.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw NumiTissueCLIError.readFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ScientificCanonicalJSON.encode(value).write(
            to: url,
            options: [.atomic]
        )
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let data = try ScientificCanonicalJSON.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func printUsage() {
        print(
            """
            numitissue commands:
              inspect-checkpoint <path>
              compile-nmodl <path> [artifact-directory]
              eval-expr <expression>
              validate-experiment <experiment.json>
              campaign compile <experiment.json> <output-directory> [--shards N] [--model-sha HEX] [--artifact-sha HEX]
              campaign inspect <bundle-directory>
              screening compile <study.json> <output-directory> [--shards N]
              organoid compile <study.json> <output-directory> [--shards N]
              wetware plan <study.json> <output.json>
              wetware validate <protocol.json> <safety.json> [report.json]
            """
        )
    }
}

private struct CampaignCommandSummary: Encodable {
    var experimentID: UUID
    var name: String
    var trialCount: Int
    var shardCount: Int
    var totalWorkUnits: UInt64
    var campaignDigest: String
    var bundleDigest: String
    var outputPath: String

    init(bundle: TissueExperimentCampaignBundle, outputPath: String) {
        experimentID = bundle.experimentID
        name = bundle.experimentName
        trialCount = bundle.trialSpecifications.count
        shardCount = bundle.manifest.shards.count
        totalWorkUnits = bundle.manifest.totalEstimatedWorkUnits
        campaignDigest = bundle.manifest.campaignDigest.hexadecimal
        bundleDigest = bundle.bundleDigest.hexadecimal
        self.outputPath = outputPath
    }
}

private struct WetwarePlanSummary: Encodable {
    var studyID: UUID
    var name: String
    var acceptedCandidateCount: Int
    var rejectedCandidateCount: Int
    var planDigest: String
    var outputPath: String

    init(plan: WetwareOptimizationPlan, outputPath: String) {
        studyID = plan.study.id
        name = plan.study.name
        acceptedCandidateCount = plan.candidates.count
        rejectedCandidateCount = plan.rejected.count
        planDigest = plan.planDigest.hexadecimal
        self.outputPath = outputPath
    }
}

private struct ExperimentValidationSummary: Encodable {
    var id: UUID
    var name: String
    var modelDigest: UInt64
    var trialCount: Int
    var stepsPerTrial: Int
    var totalSteps: UInt64

    init(definition: TissueExperimentDefinition) {
        id = definition.id
        name = definition.name
        modelDigest = definition.modelDigest
        trialCount = definition.trials.count
        stepsPerTrial = definition.stepsPerTrial
        totalSteps = UInt64(definition.trials.count)
            * UInt64(definition.stepsPerTrial)
    }
}

private struct NumiTissueCLIArguments {
    var positionals: [String] = []
    private var options: [String: [String]] = [:]

    init(
        _ arguments: [String],
        repeatableOptions: Set<String> = []
    ) throws {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value.hasPrefix("--") {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else {
                    throw NumiTissueCLIError.missingOptionValue(value)
                }
                let next = arguments[index + 1]
                if options[value] != nil,
                   !repeatableOptions.contains(value) {
                    throw NumiTissueCLIError.duplicateOption(value)
                }
                options[value, default: []].append(next)
                index += 2
            } else {
                positionals.append(value)
                index += 1
            }
        }
    }

    func one(_ key: String) throws -> String? {
        let values = options[key] ?? []
        guard values.count <= 1 else {
            throw NumiTissueCLIError.duplicateOption(key)
        }
        return values.first
    }

    func many(_ key: String) -> [String] {
        options[key] ?? []
    }

    func int(_ key: String) throws -> Int? {
        guard let value = try one(key) else { return nil }
        guard let parsed = Int(value) else {
            throw NumiTissueCLIError.invalidOptionValue(key, value)
        }
        return parsed
    }

    func uint64(_ key: String) throws -> UInt64? {
        guard let value = try one(key) else { return nil }
        guard let parsed = UInt64(value) else {
            throw NumiTissueCLIError.invalidOptionValue(key, value)
        }
        return parsed
    }

    func date(_ key: String) throws -> Date? {
        guard let value = try one(key) else { return nil }
        guard let parsed = ISO8601DateFormatter().date(from: value) else {
            throw NumiTissueCLIError.invalidOptionValue(key, value)
        }
        return parsed
    }
}

private enum NumiTissueCLIError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownSubcommand(String)
    case missingArgument(String)
    case usage(String)
    case missingOptionValue(String)
    case duplicateOption(String)
    case invalidOptionValue(String, String)
    case readFailed(path: String, reason: String)
    case wetwareSafetyViolation(count: Int)

    var description: String {
        switch self {
        case .unknownCommand(let value):
            return "Unknown command: \(value)"
        case .unknownSubcommand(let value):
            return "Unknown subcommand: \(value)"
        case .missingArgument(let value):
            return "Missing argument: \(value)"
        case .usage(let value):
            return "Usage: \(value)"
        case .missingOptionValue(let value):
            return "Option \(value) requires a value"
        case .duplicateOption(let value):
            return "Option \(value) may not be repeated"
        case .invalidOptionValue(let key, let value):
            return "Option \(key) has invalid value \(value)"
        case .readFailed(let path, let reason):
            return "Could not read \(path): \(reason)"
        case .wetwareSafetyViolation(let count):
            return "Wetware protocol violates \(count) safety constraints"
        }
    }
}

private enum NumiTissueExpressionToken: Equatable {
    case number(Double)
    case plus
    case minus
    case star
    case slash
    case leftParenthesis
    case rightParenthesis
    case end
}

private struct NumiTissueExpressionLexer {
    let source: String

    func tokenize() throws -> [NumiTissueExpressionToken] {
        let characters = Array(source)
        var tokens: [NumiTissueExpressionToken] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            switch character {
            case "+": tokens.append(.plus); index += 1
            case "-": tokens.append(.minus); index += 1
            case "*": tokens.append(.star); index += 1
            case "/": tokens.append(.slash); index += 1
            case "(": tokens.append(.leftParenthesis); index += 1
            case ")": tokens.append(.rightParenthesis); index += 1
            default:
                guard character.isNumber || character == "." else {
                    throw NumiTissueExpressionError.invalidCharacter(character)
                }
                let start = index
                var seenExponent = false
                index += 1
                while index < characters.count {
                    let next = characters[index]
                    if next.isNumber || next == "." {
                        index += 1
                    } else if (next == "e" || next == "E") && !seenExponent {
                        seenExponent = true
                        index += 1
                        if index < characters.count,
                           characters[index] == "+" || characters[index] == "-" {
                            index += 1
                        }
                    } else {
                        break
                    }
                }
                let text = String(characters[start..<index])
                guard let value = Double(text), value.isFinite else {
                    throw NumiTissueExpressionError.invalidNumber(text)
                }
                tokens.append(.number(value))
            }
        }
        tokens.append(.end)
        return tokens
    }
}

private indirect enum NumiTissueExpressionNode {
    case number(Double)
    case unaryMinus(NumiTissueExpressionNode)
    case add(NumiTissueExpressionNode, NumiTissueExpressionNode)
    case subtract(NumiTissueExpressionNode, NumiTissueExpressionNode)
    case multiply(NumiTissueExpressionNode, NumiTissueExpressionNode)
    case divide(NumiTissueExpressionNode, NumiTissueExpressionNode)
}

private struct NumiTissueExpressionParser {
    let tokens: [NumiTissueExpressionToken]
    private var index = 0

    init(tokens: [NumiTissueExpressionToken]) {
        self.tokens = tokens
    }

    mutating func parse() throws -> NumiTissueExpressionNode {
        let result = try parseExpression()
        guard current == .end else {
            throw NumiTissueExpressionError.trailingInput
        }
        return result
    }

    private var current: NumiTissueExpressionToken {
        tokens[min(index, tokens.count - 1)]
    }

    private mutating func advance() {
        index = min(index + 1, tokens.count - 1)
    }

    private mutating func parseExpression() throws -> NumiTissueExpressionNode {
        var node = try parseTerm()
        while true {
            switch current {
            case .plus:
                advance()
                node = .add(node, try parseTerm())
            case .minus:
                advance()
                node = .subtract(node, try parseTerm())
            default:
                return node
            }
        }
    }

    private mutating func parseTerm() throws -> NumiTissueExpressionNode {
        var node = try parseFactor()
        while true {
            switch current {
            case .star:
                advance()
                node = .multiply(node, try parseFactor())
            case .slash:
                advance()
                node = .divide(node, try parseFactor())
            default:
                return node
            }
        }
    }

    private mutating func parseFactor() throws -> NumiTissueExpressionNode {
        switch current {
        case .number(let value):
            advance()
            return .number(value)
        case .minus:
            advance()
            return .unaryMinus(try parseFactor())
        case .leftParenthesis:
            advance()
            let node = try parseExpression()
            guard current == .rightParenthesis else {
                throw NumiTissueExpressionError.missingRightParenthesis
            }
            advance()
            return node
        default:
            throw NumiTissueExpressionError.expectedExpression
        }
    }
}

private enum NumiTissueExpressionEvaluator {
    static func evaluate(_ node: NumiTissueExpressionNode) throws -> Double {
        switch node {
        case .number(let value):
            return value
        case .unaryMinus(let value):
            return -(try evaluate(value))
        case .add(let lhs, let rhs):
            return try evaluate(lhs) + evaluate(rhs)
        case .subtract(let lhs, let rhs):
            return try evaluate(lhs) - evaluate(rhs)
        case .multiply(let lhs, let rhs):
            return try evaluate(lhs) * evaluate(rhs)
        case .divide(let lhs, let rhs):
            let denominator = try evaluate(rhs)
            guard denominator != 0 else {
                throw NumiTissueExpressionError.divisionByZero
            }
            return try evaluate(lhs) / denominator
        }
    }
}

private enum NumiTissueExpressionError: Error, CustomStringConvertible {
    case invalidCharacter(Character)
    case invalidNumber(String)
    case expectedExpression
    case missingRightParenthesis
    case trailingInput
    case divisionByZero

    var description: String {
        switch self {
        case .invalidCharacter(let character):
            return "Invalid expression character: \(character)"
        case .invalidNumber(let text):
            return "Invalid number: \(text)"
        case .expectedExpression:
            return "Expected an expression"
        case .missingRightParenthesis:
            return "Missing right parenthesis"
        case .trailingInput:
            return "Unexpected trailing input"
        case .divisionByZero:
            return "Division by zero"
        }
    }
}
