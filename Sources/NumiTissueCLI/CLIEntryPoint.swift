import Foundation
import NumiTissue

@main
struct NumiTissueCLIEntryPoint {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("numitissue: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { printHelp(); return }
        switch command {
        case "--help", "-h", "help": printHelp()
        case "--version", "version": print(NumiTissueBuild.semanticVersion)
        case "checkpoint": try checkpoint(Array(arguments.dropFirst()))
        case "nmodl": try nmodl(Array(arguments.dropFirst()))
        case "expression": try expression(Array(arguments.dropFirst()))
        case "phase2": try Phase2Command.run(Array(arguments.dropFirst()))
        case "phase3": try Phase3Command.run(Array(arguments.dropFirst()))
        case "phase4": try Phase4Command.run(Array(arguments.dropFirst()))
        case "phase6": try Phase6Command.run(Array(arguments.dropFirst()))
        case "phase7": try await Phase7Command.run(Array(arguments.dropFirst()))
        case "validate-experiment", "campaign", "screening", "organoid", "wetware":
            try NumiTissueCommandLine.run(arguments: arguments)
        default: throw CLIError.unknownCommand(command)
        }
    }

    private static func checkpoint(_ arguments: [String]) throws {
        guard arguments.first == "inspect", arguments.count == 2 else { throw CLIError.usage("checkpoint inspect <file.ntissue>") }
        let url = URL(fileURLWithPath: arguments[1])
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let header = try TissueCheckpointArchive.inspect(data)
        let checkpoint = try TissueCheckpointArchive.decode(data)
        try emitJSON(CheckpointInspection(
            path: url.path,
            formatVersion: header.version,
            compression: String(describing: header.compression),
            payloadBytes: header.payloadBytes,
            uncompressedBytes: header.uncompressedBytes,
            simulatorVersion: checkpoint.manifest.simulatorVersion,
            createdAt: checkpoint.manifest.createdAt,
            epoch: checkpoint.manifest.epoch,
            timeTick: checkpoint.manifest.timeTick,
            simulatedMilliseconds: Double(checkpoint.manifest.timeTick) * 0.025,
            modelDigest: String(format: "%016llx", checkpoint.manifest.modelDigest),
            stateDigest: String(format: "%016llx", checkpoint.manifest.stateDigest),
            tiles: checkpoint.state.tiles.count,
            cells: checkpoint.state.cells.count,
            segments: checkpoint.state.segments.count,
            compartments: checkpoint.state.compartments.count,
            synapses: checkpoint.state.synapses.count,
            microdomains: checkpoint.state.microdomains.count
        ))
    }

    private static func nmodl(_ arguments: [String]) throws {
        guard arguments.first == "compile", arguments.count >= 2 else { throw CLIError.usage("nmodl compile <mechanism.mod> [output.json]") }
        let sourceURL = URL(fileURLWithPath: arguments[1])
        let model = try NMODLCompiler.load(url: sourceURL)
        let bytecode = try MechanismBytecodeCompiler.compile(model)
        let output = NMODLInspection(
            source: sourceURL.path,
            name: bytecode.name,
            kind: bytecode.kind.rawValue,
            variables: bytecode.variables.count,
            stateStride: bytecode.stateStride,
            routines: bytecode.routines.count,
            instructions: bytecode.instructions.count,
            constants: bytecode.constants.count,
            integrators: bytecode.integrators.count,
            maximumStackDepth: bytecode.maximumStackDepth,
            maximumCallDepth: bytecode.maximumCallDepth,
            sourceHash: String(format: "%016llx", bytecode.sourceHash)
        )
        if arguments.count >= 3 {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(bytecode).write(to: URL(fileURLWithPath: arguments[2]), options: [.atomic])
        }
        try emitJSON(output)
    }

    private static func expression(_ arguments: [String]) throws {
        guard arguments.first == "parse", arguments.count >= 2 else { throw CLIError.usage("expression parse '<formula>'") }
        let formula = arguments.dropFirst().joined(separator: " ")
        let expression = try PortableExpressionParser.parse(formula)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(expression))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printHelp() {
        print("""
        NumiTissue \(NumiTissueBuild.semanticVersion)

        Usage:
          numitissue version
          numitissue checkpoint inspect <file.ntissue>
          numitissue nmodl compile <mechanism.mod> [output.json]
          numitissue expression parse '<formula>'
          numitissue validate-experiment <experiment.json>
          numitissue campaign compile <experiment.json> <output-directory> [--shards N]
          numitissue campaign inspect <bundle-directory>
          numitissue screening compile <study.json> <output-directory> [--shards N]
          numitissue organoid compile <study.json> <output-directory> [--shards N]
          numitissue wetware plan <study.json> <output.json>
          numitissue wetware validate <protocol.json> <safety.json> [report.json]

          numitissue phase2 contract <bitwise|scientific32|performance32>
          numitissue phase2 wrap <differential|rollback|replay|benchmark|compact-digest> <input.json> <artifact.json>
          numitissue phase2 verify <artifact.json>
          numitissue phase2 inspect <artifact.json>

          numitissue phase3 status
          numitissue phase3 support
          numitissue phase3 contract
          numitissue phase3 verify <manifest.json>

          numitissue phase4 status
          numitissue phase4 conformance [standard]
          numitissue phase4 corpus <built-in|candidates|validate|verify|seal> ...
          numitissue phase4 sidecar <pins|request-digest|verify-response> ...
          numitissue phase4 file sha256 <path>

          numitissue phase6 help
          numitissue phase6 status
          numitissue phase6 features <recording.json> <configuration.json>
          numitissue phase6 study-validate <study.json>
          numitissue phase6 score <score-request.json>

          numitissue phase7 help
          numitissue phase7 status
          numitissue phase7 replay-example
          numitissue phase7 safety-example
          numitissue phase7 safety-check <safety-request.json>
          numitissue phase7 journal-verify <records.jsonl> <run-uuid>
          numitissue phase7 suite-recovery-inspect <suite.jsonl> <run-uuid>

        Commands write machine-readable JSON except help/version.
        Phase 7 replay is a software fixture, not a live-culture or hardware command.
        The Swift API exposes reference and Metal execution backends, transactional suite coupling,
        adaptive fidelity, calibration, screening, standards conformance and wetware optimization.
        """)
    }
}

private struct CheckpointInspection: Encodable {
    var path: String
    var formatVersion: UInt32
    var compression: String
    var payloadBytes: UInt64
    var uncompressedBytes: UInt64
    var simulatorVersion: String
    var createdAt: Date
    var epoch: UInt64
    var timeTick: UInt64
    var simulatedMilliseconds: Double
    var modelDigest: String
    var stateDigest: String
    var tiles: Int
    var cells: Int
    var segments: Int
    var compartments: Int
    var synapses: Int
    var microdomains: Int
}

private struct NMODLInspection: Encodable {
    var source: String
    var name: String
    var kind: String
    var variables: Int
    var stateStride: UInt32
    var routines: Int
    var instructions: Int
    var constants: Int
    var integrators: Int
    var maximumStackDepth: UInt16
    var maximumCallDepth: UInt8
    var sourceHash: String
}

private enum CLIError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case usage(String)

    var description: String {
        switch self {
        case .unknownCommand(let command): return "unknown command '\(command)'; run 'numitissue help'"
        case .usage(let value): return "usage: numitissue \(value)"
        }
    }
}
