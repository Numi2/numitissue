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
            throw NumiTissueCLIWorkflowError.unknownCommand(command)
        }
    }

    private static let campaignOptionNames: Set<String> = [
        "--shards",
        "--model-sha",
        "--artifact-sha",
        "--created-at",
        "--work-per-step",
        "--work-per-intervention",
        "--work-per-parameter"
    ]

    private static func campaign(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw NumiTissueCLIWorkflowError.missingArgument("campaign subcommand")
        }
        switch subcommand {
        case "compile":
            let parsed = try NumiTissueCLIArguments(
                Array(arguments.dropFirst()),
                allowedOptions: campaignOptionNames,
                repeatableOptions: ["--artifact-sha"]
            )
            guard parsed.positionals.count == 2 else {
                throw NumiTissueCLIWorkflowError.usage(
                    "campaign compile <experiment.json> <output-directory> [--shards N] [--model-sha HEX] [--artifact-sha HEX]"
                )
            }
            let definition: TissueExperimentDefinition = try readJSON(
                at: URL(fileURLWithPath: parsed.positionals[0])
            )
            let bundle = try TissueExperimentCampaignCompiler.compile(
                definition,
                options: try campaignOptions(parsed),
                createdAt: try parsed.date("--created-at") ?? Date()
            )
            let output = URL(
                fileURLWithPath: parsed.positionals[1],
                isDirectory: true
            )
            try bundle.writeAtomically(to: output)
            try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))

        case "inspect":
            let parsed = try NumiTissueCLIArguments(
                Array(arguments.dropFirst()),
                allowedOptions: []
            )
            guard parsed.positionals.count == 1 else {
                throw NumiTissueCLIWorkflowError.usage(
                    "campaign inspect <bundle-directory>"
                )
            }
            let input = URL(
                fileURLWithPath: parsed.positionals[0],
                isDirectory: true
            )
            let bundle = try TissueExperimentCampaignBundle.read(from: input)
            try emit(CampaignCommandSummary(bundle: bundle, outputPath: input.path))

        default:
            throw NumiTissueCLIWorkflowError.unknownSubcommand(
                "campaign \(subcommand)"
            )
        }
    }

    private static func screening(_ arguments: [String]) throws {
        guard arguments.first == "compile" else {
            throw NumiTissueCLIWorkflowError.usage(
                "screening compile <study.json> <output-directory> [--shards N]"
            )
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            allowedOptions: campaignOptionNames,
            repeatableOptions: ["--artifact-sha"]
        )
        guard parsed.positionals.count == 2 else {
            throw NumiTissueCLIWorkflowError.usage(
                "screening compile <study.json> <output-directory> [--shards N]"
            )
        }
        let study: TissueScreeningStudy = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        let bundle = try study.compileCampaign(
            options: try campaignOptions(parsed),
            createdAt: try parsed.date("--created-at") ?? Date()
        )
        let output = URL(
            fileURLWithPath: parsed.positionals[1],
            isDirectory: true
        )
        try bundle.writeAtomically(to: output)
        try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))
    }

    private static func organoid(_ arguments: [String]) throws {
        guard arguments.first == "compile" else {
            throw NumiTissueCLIWorkflowError.usage(
                "organoid compile <study.json> <output-directory> [--shards N]"
            )
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            allowedOptions: campaignOptionNames,
            repeatableOptions: ["--artifact-sha"]
        )
        guard parsed.positionals.count == 2 else {
            throw NumiTissueCLIWorkflowError.usage(
                "organoid compile <study.json> <output-directory> [--shards N]"
            )
        }
        let study: OrganoidFittingStudy = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        let bundle = try study.compileCampaign(
            options: try campaignOptions(parsed),
            createdAt: try parsed.date("--created-at") ?? Date()
        )
        let output = URL(
            fileURLWithPath: parsed.positionals[1],
            isDirectory: true
        )
        try bundle.writeAtomically(to: output)
        try emit(CampaignCommandSummary(bundle: bundle, outputPath: output.path))
    }

    private static func wetware(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw NumiTissueCLIWorkflowError.missingArgument("wetware subcommand")
        }
        let parsed = try NumiTissueCLIArguments(
            Array(arguments.dropFirst()),
            allowedOptions: []
        )
        switch subcommand {
        case "plan":
            guard parsed.positionals.count == 2 else {
                throw NumiTissueCLIWorkflowError.usage(
                    "wetware plan <study.json> <output.json>"
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
                throw NumiTissueCLIWorkflowError.usage(
                    "wetware validate <protocol.json> <safety.json> [report.json]"
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
                throw NumiTissueCLIWorkflowError.wetwareSafetyViolation(
                    count: report.violations.count
                )
            }

        default:
            throw NumiTissueCLIWorkflowError.unknownSubcommand(
                "wetware \(subcommand)"
            )
        }
    }

    private static func validateExperiment(_ arguments: [String]) throws {
        let parsed = try NumiTissueCLIArguments(
            arguments,
            allowedOptions: []
        )
        guard parsed.positionals.count == 1 else {
            throw NumiTissueCLIWorkflowError.usage(
                "validate-experiment <experiment.json>"
            )
        }
        let definition: TissueExperimentDefinition = try readJSON(
            at: URL(fileURLWithPath: parsed.positionals[0])
        )
        try emit(try ExperimentValidationSummary(definition: definition.validated()))
    }

    private static func campaignOptions(
        _ arguments: NumiTissueCLIArguments
    ) throws -> TissueExperimentCampaignOptions {
        let shardCount = try arguments.int("--shards") ?? 1
        let modelDigest = try arguments.one("--model-sha").map {
            try ScientificSHA256Digest(hexadecimal: $0)
        }
        let artifacts = try arguments.many("--artifact-sha").map {
            try ScientificSHA256Digest(hexadecimal: $0)
        }
        return try TissueExperimentCampaignOptions(
            shardCount: shardCount,
            workUnitsPerStep: try arguments.uint64("--work-per-step") ?? 1,
            workUnitsPerIntervention: try arguments.uint64("--work-per-intervention") ?? 100,
            workUnitsPerParameter: try arguments.uint64("--work-per-parameter") ?? 10,
            modelArtifactDigest: modelDigest,
            requiredArtifactDigests: artifacts,
            metadata: [
                "numitissue.cli": "campaign-compile",
                "numitissue.cli_version": "1"
            ]
        ).validated()
    }

    private static func readJSON<T: Decodable>(at url: URL) throws -> T {
        do {
            return try ScientificCanonicalJSON.decode(
                T.self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw NumiTissueCLIWorkflowError.readFailed(
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
        FileHandle.standardOutput.write(try ScientificCanonicalJSON.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func printUsage() {
        print(
            """
            Workflow commands:
              numitissue validate-experiment <experiment.json>
              numitissue campaign compile <experiment.json> <output-directory> [--shards N] [--model-sha HEX] [--artifact-sha HEX]
              numitissue campaign inspect <bundle-directory>
              numitissue screening compile <study.json> <output-directory> [--shards N]
              numitissue organoid compile <study.json> <output-directory> [--shards N]
              numitissue wetware plan <study.json> <output.json>
              numitissue wetware validate <protocol.json> <safety.json> [report.json]
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

    init(definition: TissueExperimentDefinition) throws {
        let count = UInt64(definition.trials.count)
        let steps = UInt64(definition.stepsPerTrial)
        let product = count.multipliedReportingOverflow(by: steps)
        guard !product.overflow else {
            throw NumiTissueCLIWorkflowError.numericOverflow("totalSteps")
        }
        id = definition.id
        name = definition.name
        modelDigest = definition.modelDigest
        trialCount = definition.trials.count
        stepsPerTrial = definition.stepsPerTrial
        totalSteps = product.partialValue
    }
}

private struct NumiTissueCLIArguments {
    var positionals: [String] = []
    private var options: [String: [String]] = [:]

    init(
        _ arguments: [String],
        allowedOptions: Set<String>,
        repeatableOptions: Set<String> = []
    ) throws {
        var index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value.hasPrefix("--") {
                guard allowedOptions.contains(value) else {
                    throw NumiTissueCLIWorkflowError.unknownOption(value)
                }
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--") else {
                    throw NumiTissueCLIWorkflowError.missingOptionValue(value)
                }
                if options[value] != nil,
                   !repeatableOptions.contains(value) {
                    throw NumiTissueCLIWorkflowError.duplicateOption(value)
                }
                options[value, default: []].append(arguments[index + 1])
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
            throw NumiTissueCLIWorkflowError.duplicateOption(key)
        }
        return values.first
    }

    func many(_ key: String) -> [String] {
        options[key] ?? []
    }

    func int(_ key: String) throws -> Int? {
        guard let value = try one(key) else { return nil }
        guard let parsed = Int(value) else {
            throw NumiTissueCLIWorkflowError.invalidOptionValue(key, value)
        }
        return parsed
    }

    func uint64(_ key: String) throws -> UInt64? {
        guard let value = try one(key) else { return nil }
        guard let parsed = UInt64(value) else {
            throw NumiTissueCLIWorkflowError.invalidOptionValue(key, value)
        }
        return parsed
    }

    func date(_ key: String) throws -> Date? {
        guard let value = try one(key) else { return nil }
        guard let parsed = ISO8601DateFormatter().date(from: value) else {
            throw NumiTissueCLIWorkflowError.invalidOptionValue(key, value)
        }
        return parsed
    }
}

private enum NumiTissueCLIWorkflowError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case unknownSubcommand(String)
    case unknownOption(String)
    case missingArgument(String)
    case usage(String)
    case missingOptionValue(String)
    case duplicateOption(String)
    case invalidOptionValue(String, String)
    case readFailed(path: String, reason: String)
    case wetwareSafetyViolation(count: Int)
    case numericOverflow(String)

    var description: String {
        switch self {
        case .unknownCommand(let value):
            return "unknown workflow command '\(value)'"
        case .unknownSubcommand(let value):
            return "unknown workflow subcommand '\(value)'"
        case .unknownOption(let value):
            return "unknown option '\(value)'"
        case .missingArgument(let value):
            return "missing argument: \(value)"
        case .usage(let value):
            return "usage: numitissue \(value)"
        case .missingOptionValue(let value):
            return "option \(value) requires a value"
        case .duplicateOption(let value):
            return "option \(value) may not be repeated"
        case .invalidOptionValue(let key, let value):
            return "option \(key) has invalid value '\(value)'"
        case .readFailed(let path, let reason):
            return "could not read \(path): \(reason)"
        case .wetwareSafetyViolation(let count):
            return "wetware protocol violates \(count) safety constraints"
        case .numericOverflow(let field):
            return "numeric overflow while computing \(field)"
        }
    }
}
