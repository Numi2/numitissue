import Foundation
import NumiTissue

struct Phase4Command {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw Phase4CLIError.usage
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "status":
            guard tail.isEmpty else { throw Phase4CLIError.usage }
            try status()
        case "conformance":
            try conformance(tail)
        case "corpus":
            try corpus(tail)
        case "sidecar":
            try sidecar(tail)
        case "file":
            try file(tail)
        case "help", "--help", "-h":
            printUsage()
        default:
            throw Phase4CLIError.unknownCommand(command)
        }
    }

    private static func status() throws {
        let matrix = try NumiTissueStandardConformance.phase4Baseline.validated()
        let fixture = try NumiTissuePhase4Corpus
            .conformanceFixtureManifest()
            .validated(policy: .materialized)
        let candidates = try NumiTissuePhase4Corpus
            .candidateCatalog()
            .validated(policy: .development)
        let pins = try NumiTissuePhase4Sidecars.all.map {
            Phase4SidecarPinSummary(
                sidecar: $0.sidecar,
                implementation: $0.implementation,
                implementationVersion: $0.implementationVersion,
                runtime: $0.runtime,
                runtimeVersion: $0.runtimeVersion,
                packageVersions: $0.packageVersions,
                sha256: try $0.sha256()
            )
        }
        try emit(Phase4Status(
            schemaVersion: 1,
            phase: 4,
            implementationStatus: "source-complete-unqualified",
            conformanceCatalogVersion: matrix.catalogVersion,
            conformanceSHA256: try matrix.sha256(),
            conformanceCoverage: matrix.coverage,
            fixtureCorpusID: fixture.corpusID,
            fixtureCorpusVersion: fixture.version,
            fixtureCorpusSHA256: try fixture.sha256(policy: .materialized),
            fixtureAssetCount: fixture.entries.reduce(0) {
                $0 + $1.assets.count
            },
            candidateCorpusID: candidates.corpusID,
            candidateEntryCount: candidates.entries.count,
            sidecars: pins,
            validationBoundary: [
                "Swift sources, corpus contracts and sidecar protocols are implemented.",
                "No native build, sidecar environment, external dataset or reference simulator is implied to have passed.",
                "Publication requires publishable-policy validation plus materialized byte verification and executable evidence."
            ]
        ))
    }

    private static func conformance(_ arguments: [String]) throws {
        guard arguments.count <= 1 else { throw Phase4CLIError.usage }
        let matrix = try NumiTissueStandardConformance.phase4Baseline.validated()
        guard let source = arguments.first else {
            try emit(matrix)
            return
        }
        guard let standard = ScientificInterchangeStandard(rawValue: source.lowercased())
                ?? ScientificInterchangeStandard.allCases.first(where: {
                    $0.rawValue.lowercased() == source.lowercased()
                }) else {
            throw Phase4CLIError.unknownStandard(source)
        }
        let contract = try XCTUnwrapForCLI(
            matrix.standards.first { $0.standard == standard },
            error: Phase4CLIError.unknownStandard(source)
        )
        try emit(Phase4ConformanceSelection(
            schemaVersion: 1,
            catalogVersion: matrix.catalogVersion,
            matrixSHA256: try matrix.sha256(),
            standard: contract,
            features: matrix.features(for: standard)
        ))
    }

    private static func corpus(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw Phase4CLIError.usage
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "built-in":
            try emitOrWrite(
                NumiTissuePhase4Corpus.conformanceFixtureManifest(),
                arguments: tail,
                policy: .materialized
            )
        case "candidates":
            try emitOrWrite(
                NumiTissuePhase4Corpus.candidateCatalog(),
                arguments: tail,
                policy: .development
            )
        case "validate":
            guard (1...2).contains(tail.count) else {
                throw Phase4CLIError.usage
            }
            let policy = try parsePolicy(tail.count == 2 ? tail[1] : "development")
            let url = URL(fileURLWithPath: tail[0])
            let manifest = try ScientificCorpusManifest.read(
                from: url,
                policy: policy
            )
            try emit(Phase4CorpusValidationSummary(
                schemaVersion: 1,
                path: url.path,
                policy: policy.mode,
                corpusID: manifest.corpusID,
                version: manifest.version,
                entryCount: manifest.entries.count,
                assetCount: manifest.entries.reduce(0) {
                    $0 + $1.assets.count
                },
                sha256: try manifest.sha256(policy: policy),
                valid: true
            ))
        case "verify":
            guard (2...3).contains(tail.count) else {
                throw Phase4CLIError.usage
            }
            let manifestURL = URL(fileURLWithPath: tail[0])
            let root = URL(fileURLWithPath: tail[1], isDirectory: true)
            let manifest = try ScientificCorpusManifest.read(
                from: manifestURL,
                policy: .publishable
            )
            let report = try ScientificCorpusVerifier.verify(
                manifest: manifest,
                root: root
            )
            if tail.count == 3 {
                try write(report, to: URL(fileURLWithPath: tail[2]))
            }
            try emit(report)
            guard report.passed else {
                throw Phase4CLIError.corpusVerificationFailed(
                    report.failures.count
                )
            }
        case "seal":
            guard tail.count == 3 else { throw Phase4CLIError.usage }
            let source = URL(fileURLWithPath: tail[0])
            let root = URL(fileURLWithPath: tail[1], isDirectory: true)
            let destination = URL(fileURLWithPath: tail[2])
            let manifest = try ScientificCorpusManifest.read(
                from: source,
                policy: .development
            )
            let sealed = try ScientificCorpusSealer.sealLocalFiles(
                manifest: manifest,
                root: root
            )
            try sealed.write(
                to: destination,
                policy: .materialized,
                overwrite: false
            )
            try emit(Phase4CorpusSealSummary(
                schemaVersion: 1,
                inputPath: source.path,
                rootPath: root.path,
                outputPath: destination.path,
                corpusID: sealed.corpusID,
                corpusVersion: sealed.version,
                sha256: try sealed.sha256(policy: .materialized),
                assetCount: sealed.entries.reduce(0) {
                    $0 + $1.assets.count
                }
            ))
        default:
            throw Phase4CLIError.unknownCorpusCommand(command)
        }
    }

    private static func sidecar(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw Phase4CLIError.usage
        }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "pins":
            guard tail.isEmpty else { throw Phase4CLIError.usage }
            try emit(try NumiTissuePhase4Sidecars.all.map {
                Phase4SidecarPinSummary(
                    sidecar: $0.sidecar,
                    implementation: $0.implementation,
                    implementationVersion: $0.implementationVersion,
                    runtime: $0.runtime,
                    runtimeVersion: $0.runtimeVersion,
                    packageVersions: $0.packageVersions,
                    sha256: try $0.sha256()
                )
            })
        case "request-digest":
            guard tail.count == 1 else { throw Phase4CLIError.usage }
            let url = URL(fileURLWithPath: tail[0])
            let request: ScientificSidecarRequest = try read(url)
            let validated = try request.validated()
            try emit(Phase4SidecarRequestSummary(
                schemaVersion: 1,
                path: url.path,
                requestID: validated.requestID,
                sidecar: validated.sidecar,
                operation: validated.operation,
                inputCount: validated.inputs.count,
                toolchainSHA256: try validated.toolchain.sha256(),
                requestSHA256: try validated.sha256()
            ))
        case "verify-response":
            guard tail.count == 2 else { throw Phase4CLIError.usage }
            let requestURL = URL(fileURLWithPath: tail[0])
            let responseURL = URL(fileURLWithPath: tail[1])
            let request: ScientificSidecarRequest = try read(requestURL)
            let response: ScientificSidecarResponse = try read(responseURL)
            let validated = try response.validated(for: request)
            try emit(Phase4SidecarResponseSummary(
                schemaVersion: 1,
                requestPath: requestURL.path,
                responsePath: responseURL.path,
                requestID: validated.requestID,
                sidecar: validated.sidecar,
                operation: validated.operation,
                status: validated.status,
                artifactCount: validated.artifacts.count,
                errorDiagnosticCount: validated.diagnostics.filter {
                    $0.severity == .error
                }.count,
                responseSHA256: try validated.sha256(),
                valid: true
            ))
        default:
            throw Phase4CLIError.unknownSidecarCommand(command)
        }
    }

    private static func file(_ arguments: [String]) throws {
        guard arguments.count == 2,
              arguments[0] == "sha256" else {
            throw Phase4CLIError.usage
        }
        let url = URL(fileURLWithPath: arguments[1])
        let result = try ScientificFileDigester.sha256(at: url)
        try emit(Phase4FileDigestSummary(
            schemaVersion: 1,
            path: url.path,
            byteCount: result.byteCount,
            sha256: result.sha256
        ))
    }

    private static func emitOrWrite(
        _ manifest: ScientificCorpusManifest,
        arguments: [String],
        policy: ScientificCorpusPolicy
    ) throws {
        guard arguments.count <= 1 else { throw Phase4CLIError.usage }
        let validated = try manifest.validated(policy: policy)
        if let path = arguments.first {
            try validated.write(
                to: URL(fileURLWithPath: path),
                policy: policy,
                overwrite: false
            )
        }
        try emit(validated)
    }

    private static func parsePolicy(
        _ source: String
    ) throws -> ScientificCorpusPolicy {
        switch source.lowercased() {
        case "development": return .development
        case "publishable": return .publishable
        case "materialized": return .materialized
        default: throw Phase4CLIError.unknownPolicy(source)
        }
    }

    private static func read<T: Decodable>(_ url: URL) throws -> T {
        do {
            return try ScientificCanonicalJSON.decode(
                T.self,
                from: Data(contentsOf: url, options: [.mappedIfSafe])
            )
        } catch {
            throw Phase4CLIError.readFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
    }

    private static func write<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Phase4CLIError.destinationExists(url.path)
        }
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
        FileHandle.standardOutput.write(
            try ScientificCanonicalJSON.encode(value)
        )
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func printUsage() {
        print(
            """
            Phase 4 standards and scientific-corpus commands:
              numitissue phase4 status
              numitissue phase4 conformance [swc|neuroml|lems|sonata|sbml|nmodl|nwb]
              numitissue phase4 corpus built-in [output.json]
              numitissue phase4 corpus candidates [output.json]
              numitissue phase4 corpus validate <manifest.json> [development|publishable|materialized]
              numitissue phase4 corpus verify <manifest.json> <root-directory> [report.json]
              numitissue phase4 corpus seal <manifest.json> <root-directory> <output.json>
              numitissue phase4 sidecar pins
              numitissue phase4 sidecar request-digest <request.json>
              numitissue phase4 sidecar verify-response <request.json> <response.json>
              numitissue phase4 file sha256 <path>

            Commands are deterministic and emit canonical JSON. The CLI validates and verifies
            evidence; it does not install Python environments or execute sidecars implicitly.
            """
        )
    }
}

private enum XCTUnwrapForCLI {
    static func call<T>(_ value: T?, error: Error) throws -> T {
        guard let value else { throw error }
        return value
    }
}

private extension XCTUnwrapForCLI {
    static func invoke<T>(_ value: T?, error: Error) throws -> T {
        try call(value, error: error)
    }
}

private func XCTUnwrapForCLI<T>(
    _ value: T?,
    error: Error
) throws -> T {
    try XCTUnwrapForCLI.call(value, error: error)
}

private struct Phase4Status: Encodable {
    var schemaVersion: UInt32
    var phase: Int
    var implementationStatus: String
    var conformanceCatalogVersion: String
    var conformanceSHA256: ScientificSHA256Digest
    var conformanceCoverage: StandardConformanceCoverage
    var fixtureCorpusID: String
    var fixtureCorpusVersion: String
    var fixtureCorpusSHA256: ScientificSHA256Digest
    var fixtureAssetCount: Int
    var candidateCorpusID: String
    var candidateEntryCount: Int
    var sidecars: [Phase4SidecarPinSummary]
    var validationBoundary: [String]
}

private struct Phase4ConformanceSelection: Encodable {
    var schemaVersion: UInt32
    var catalogVersion: String
    var matrixSHA256: ScientificSHA256Digest
    var standard: StandardVersionContract
    var features: [StandardFeatureConformance]
}

private struct Phase4CorpusValidationSummary: Encodable {
    var schemaVersion: UInt32
    var path: String
    var policy: ScientificCorpusValidationMode
    var corpusID: String
    var version: String
    var entryCount: Int
    var assetCount: Int
    var sha256: ScientificSHA256Digest
    var valid: Bool
}

private struct Phase4CorpusSealSummary: Encodable {
    var schemaVersion: UInt32
    var inputPath: String
    var rootPath: String
    var outputPath: String
    var corpusID: String
    var corpusVersion: String
    var sha256: ScientificSHA256Digest
    var assetCount: Int
}

private struct Phase4SidecarPinSummary: Encodable {
    var sidecar: ScientificSidecarKind
    var implementation: String
    var implementationVersion: String
    var runtime: String
    var runtimeVersion: String
    var packageVersions: [String: String]
    var sha256: ScientificSHA256Digest
}

private struct Phase4SidecarRequestSummary: Encodable {
    var schemaVersion: UInt32
    var path: String
    var requestID: String
    var sidecar: ScientificSidecarKind
    var operation: ScientificSidecarOperation
    var inputCount: Int
    var toolchainSHA256: ScientificSHA256Digest
    var requestSHA256: ScientificSHA256Digest
}

private struct Phase4SidecarResponseSummary: Encodable {
    var schemaVersion: UInt32
    var requestPath: String
    var responsePath: String
    var requestID: String
    var sidecar: ScientificSidecarKind
    var operation: ScientificSidecarOperation
    var status: ScientificSidecarResponseStatus
    var artifactCount: Int
    var errorDiagnosticCount: Int
    var responseSHA256: ScientificSHA256Digest
    var valid: Bool
}

private struct Phase4FileDigestSummary: Encodable {
    var schemaVersion: UInt32
    var path: String
    var byteCount: UInt64
    var sha256: ScientificSHA256Digest
}

private enum Phase4CLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case unknownStandard(String)
    case unknownCorpusCommand(String)
    case unknownSidecarCommand(String)
    case unknownPolicy(String)
    case readFailed(path: String, reason: String)
    case destinationExists(String)
    case corpusVerificationFailed(Int)

    var description: String {
        switch self {
        case .usage:
            return "usage: numitissue phase4 help"
        case .unknownCommand(let command):
            return "unknown Phase 4 command '\(command)'"
        case .unknownStandard(let standard):
            return "unknown scientific interchange standard '\(standard)'"
        case .unknownCorpusCommand(let command):
            return "unknown Phase 4 corpus command '\(command)'"
        case .unknownSidecarCommand(let command):
            return "unknown Phase 4 sidecar command '\(command)'"
        case .unknownPolicy(let policy):
            return "unknown scientific corpus policy '\(policy)'"
        case .readFailed(let path, let reason):
            return "unable to read \(path): \(reason)"
        case .destinationExists(let path):
            return "destination already exists: \(path)"
        case .corpusVerificationFailed(let count):
            return "scientific corpus verification failed for \(count) asset(s)"
        }
    }
}
