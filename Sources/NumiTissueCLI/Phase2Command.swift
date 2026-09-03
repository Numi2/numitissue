import Foundation
import NumiTissue

struct Phase2Command {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw Phase2CLIError.usage
        }
        switch command {
        case "inspect":
            guard arguments.count == 2 else { throw Phase2CLIError.usage }
            try inspect(URL(fileURLWithPath: arguments[1]))
        case "verify":
            guard arguments.count == 2 else { throw Phase2CLIError.usage }
            try verify(URL(fileURLWithPath: arguments[1]))
        case "wrap":
            guard arguments.count == 4,
                  let kind = parseKind(arguments[1]) else {
                throw Phase2CLIError.usage
            }
            try wrap(
                kind: kind,
                input: URL(fileURLWithPath: arguments[2]),
                output: URL(fileURLWithPath: arguments[3])
            )
        case "contract":
            guard arguments.count == 2 else { throw Phase2CLIError.usage }
            try emitJSON(contract(named: arguments[1]))
        default:
            throw Phase2CLIError.unknownCommand(command)
        }
    }

    private static func inspect(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let probe = try RuntimeValidationArtifactInspector.probe(data: data)
        let artifactHash = ScientificSHA256Digest(data: data)
        let inspection = try inspectPayload(
            kind: probe.kind,
            data: data,
            path: url.path,
            artifactHash: artifactHash
        )
        try emitJSON(inspection)
    }

    private static func verify(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let probe = try RuntimeValidationArtifactInspector.probe(data: data)
        _ = try decodeArtifact(kind: probe.kind, data: data)
        try emitJSON(Phase2VerificationOutput(
            path: url.path,
            kind: probe.kind,
            valid: true,
            payloadSHA256: probe.payloadSHA256,
            artifactSHA256: ScientificSHA256Digest(data: data),
            metadata: probe.metadata
        ))
    }

    private static func wrap(
        kind: RuntimeValidationArtifactKind,
        input: URL,
        output: URL
    ) throws {
        let data = try Data(contentsOf: input, options: [.mappedIfSafe])
        let wrapped: Data
        switch kind {
        case .differentialTransaction:
            let report = try ScientificCanonicalJSON.decode(
                DifferentialTransactionReport.self,
                from: data
            )
            wrapped = try RuntimeValidationArtifactIO.encode(
                RuntimeValidationArtifact(
                    kind: kind,
                    payload: report,
                    metadata: sourceMetadata(input)
                )
            )
        case .rollbackCertificate:
            let report = try ScientificCanonicalJSON.decode(
                RuntimeRollbackCertificate.self,
                from: data
            )
            wrapped = try RuntimeValidationArtifactIO.encode(
                RuntimeValidationArtifact(
                    kind: kind,
                    payload: report,
                    metadata: sourceMetadata(input)
                )
            )
        case .reproducibilityCertificate:
            let report = try ScientificCanonicalJSON.decode(
                RuntimeReproducibilityCertificate.self,
                from: data
            )
            wrapped = try RuntimeValidationArtifactIO.encode(
                RuntimeValidationArtifact(
                    kind: kind,
                    payload: report,
                    metadata: sourceMetadata(input)
                )
            )
        case .benchmarkReport:
            let report = try ScientificCanonicalJSON.decode(
                RuntimeBenchmarkReport.self,
                from: data
            )
            wrapped = try RuntimeValidationArtifactIO.encode(
                RuntimeValidationArtifact(
                    kind: kind,
                    payload: report,
                    metadata: sourceMetadata(input)
                )
            )
        case .compactStateDigest:
            #if canImport(Metal)
            let report = try ScientificCanonicalJSON.decode(
                MetalStateDigestResult.self,
                from: data
            )
            wrapped = try RuntimeValidationArtifactIO.encode(
                RuntimeValidationArtifact(
                    kind: kind,
                    payload: report,
                    metadata: sourceMetadata(input)
                )
            )
            #else
            throw Phase2CLIError.metalUnavailable
            #endif
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw Phase2CLIError.destinationExists(output.path)
        }
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try wrapped.write(to: output, options: [.atomic])
        let probe = try RuntimeValidationArtifactInspector.probe(data: wrapped)
        try emitJSON(Phase2WrapOutput(
            input: input.path,
            output: output.path,
            kind: kind,
            payloadSHA256: probe.payloadSHA256,
            artifactSHA256: ScientificSHA256Digest(data: wrapped),
            byteCount: wrapped.count
        ))
    }

    private static func inspectPayload(
        kind: RuntimeValidationArtifactKind,
        data: Data,
        path: String,
        artifactHash: ScientificSHA256Digest
    ) throws -> Phase2ArtifactInspection {
        switch try decodeArtifact(kind: kind, data: data) {
        case .differential(let artifact):
            let report = artifact.payload
            return Phase2ArtifactInspection(
                path: path,
                kind: kind,
                createdAt: artifact.createdAt,
                payloadSHA256: artifact.payloadSHA256,
                artifactSHA256: artifactHash,
                passed: report.passed,
                backend: report.phaseReports.first?.referenceBackend,
                numericalProfile: report.phaseReports.first?.referenceProfile.rawValue,
                summary: [
                    "disposition": report.disposition.rawValue,
                    "phases": String(report.phaseReports.count),
                    "outputComparisons": String(report.outputReports.count),
                    "validationBackends": String(report.validationOutcomes.count),
                    "firstDivergentPhaseOrdinal": report.firstDivergentPhaseOrdinal.map(String.init) ?? "none"
                ],
                metadata: artifact.metadata
            )
        case .rollback(let artifact):
            let report = artifact.payload
            return Phase2ArtifactInspection(
                path: path,
                kind: kind,
                createdAt: artifact.createdAt,
                payloadSHA256: artifact.payloadSHA256,
                artifactSHA256: artifactHash,
                passed: report.passed,
                backend: report.backendName,
                numericalProfile: report.numericalProfile.rawValue,
                summary: [
                    "trigger": report.trigger.rawValue,
                    "stateIdentityPreserved": String(report.stateIdentityPreserved),
                    "checkpointIdentityPreserved": report.checkpointIdentityPreserved.map(String.init) ?? "not-required",
                    "triggeredFaults": String(report.triggeredFaults.count)
                ],
                metadata: artifact.metadata
            )
        case .reproducibility(let artifact):
            let report = artifact.payload
            return Phase2ArtifactInspection(
                path: path,
                kind: kind,
                createdAt: artifact.createdAt,
                payloadSHA256: artifact.payloadSHA256,
                artifactSHA256: artifactHash,
                passed: report.passed,
                backend: report.runs.first?.backendName,
                numericalProfile: report.runs.first?.numericalProfile.rawValue,
                summary: [
                    "runs": String(report.runs.count),
                    "transactionsPerRun": String(report.configuration.transactionsPerRun),
                    "mismatches": String(report.mismatches.count),
                    "omittedMismatches": String(report.omittedMismatchCount)
                ],
                metadata: artifact.metadata
            )
        case .benchmark(let artifact):
            let report = artifact.payload
            return Phase2ArtifactInspection(
                path: path,
                kind: kind,
                createdAt: artifact.createdAt,
                payloadSHA256: artifact.payloadSHA256,
                artifactSHA256: artifactHash,
                passed: report.samples.count == report.configuration.measuredTransactions,
                backend: report.backendName,
                numericalProfile: report.numericalProfile.rawValue,
                summary: [
                    "measuredTransactions": String(report.samples.count),
                    "medianNanoseconds": String(report.statistics.medianNanoseconds),
                    "p95Nanoseconds": String(report.statistics.p95Nanoseconds),
                    "simulatedMillisecondsPerWallSecond": String(report.simulatedMillisecondsPerWallSecond),
                    "energyJoules": report.telemetry?.energyJoules.map(String.init) ?? "not-measured"
                ],
                metadata: artifact.metadata
            )
        case .compactDigest(let artifact):
            let report = artifact.payload
            return Phase2ArtifactInspection(
                path: path,
                kind: kind,
                createdAt: artifact.createdAt,
                payloadSHA256: artifact.payloadSHA256,
                artifactSHA256: artifactHash,
                passed: true,
                backend: "NumiTissue Metal State Digest",
                numericalProfile: report.numericalProfile.rawValue,
                summary: [
                    "device": report.deviceName,
                    "deviceRegistryID": String(report.deviceRegistryID),
                    "combinedDigest": report.poolDigests.combined.description,
                    "stateReadbackBytes": String(report.telemetry.deviceToHostBytes)
                ],
                metadata: artifact.metadata
            )
        }
    }

    private static func decodeArtifact(
        kind: RuntimeValidationArtifactKind,
        data: Data
    ) throws -> Phase2DecodedArtifact {
        switch kind {
        case .differentialTransaction:
            return .differential(try RuntimeValidationArtifactIO.decode(
                DifferentialTransactionReport.self,
                from: data,
                expectedKind: kind
            ))
        case .rollbackCertificate:
            return .rollback(try RuntimeValidationArtifactIO.decode(
                RuntimeRollbackCertificate.self,
                from: data,
                expectedKind: kind
            ))
        case .reproducibilityCertificate:
            return .reproducibility(try RuntimeValidationArtifactIO.decode(
                RuntimeReproducibilityCertificate.self,
                from: data,
                expectedKind: kind
            ))
        case .benchmarkReport:
            return .benchmark(try RuntimeValidationArtifactIO.decode(
                RuntimeBenchmarkReport.self,
                from: data,
                expectedKind: kind
            ))
        case .compactStateDigest:
            #if canImport(Metal)
            return .compactDigest(try RuntimeValidationArtifactIO.decode(
                MetalStateDigestResult.self,
                from: data,
                expectedKind: kind
            ))
            #else
            throw Phase2CLIError.metalUnavailable
            #endif
        }
    }

    private static func contract(
        named source: String
    ) throws -> RuntimeDeterminismContract {
        switch source.lowercased() {
        case "bitwise": return .bitwise
        case "scientific32", "scientific": return .scientific32
        case "performance32", "performance": return .performance32
        default: throw Phase2CLIError.unknownContract(source)
        }
    }

    private static func parseKind(
        _ source: String
    ) -> RuntimeValidationArtifactKind? {
        switch source.lowercased() {
        case "differential", "differential-transaction":
            return .differentialTransaction
        case "rollback", "rollback-certificate":
            return .rollbackCertificate
        case "replay", "reproducibility", "reproducibility-certificate":
            return .reproducibilityCertificate
        case "benchmark", "benchmark-report":
            return .benchmarkReport
        case "compact-digest", "compact-state-digest":
            return .compactStateDigest
        default:
            return RuntimeValidationArtifactKind(rawValue: source)
        }
    }

    private static func sourceMetadata(_ url: URL) -> [String: String] {
        [
            "source.file": url.lastPathComponent,
            "source.sha256": ScientificSHA256Digest(
                data: (try? Data(contentsOf: url, options: [.mappedIfSafe])) ?? Data()
            ).description
        ]
    }

    private static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum Phase2DecodedArtifact {
    case differential(DifferentialTransactionArtifact)
    case rollback(RollbackCertificateArtifact)
    case reproducibility(ReproducibilityCertificateArtifact)
    case benchmark(RuntimeBenchmarkArtifact)
    #if canImport(Metal)
    case compactDigest(RuntimeValidationArtifact<MetalStateDigestResult>)
    #endif
}

private struct Phase2ArtifactInspection: Encodable {
    var path: String
    var kind: RuntimeValidationArtifactKind
    var createdAt: Date
    var payloadSHA256: ScientificSHA256Digest
    var artifactSHA256: ScientificSHA256Digest
    var passed: Bool
    var backend: String?
    var numericalProfile: String?
    var summary: [String: String]
    var metadata: [String: String]
}

private struct Phase2VerificationOutput: Encodable {
    var path: String
    var kind: RuntimeValidationArtifactKind
    var valid: Bool
    var payloadSHA256: ScientificSHA256Digest
    var artifactSHA256: ScientificSHA256Digest
    var metadata: [String: String]
}

private struct Phase2WrapOutput: Encodable {
    var input: String
    var output: String
    var kind: RuntimeValidationArtifactKind
    var payloadSHA256: ScientificSHA256Digest
    var artifactSHA256: ScientificSHA256Digest
    var byteCount: Int
}

private enum Phase2CLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case unknownContract(String)
    case destinationExists(String)
    case metalUnavailable

    var description: String {
        switch self {
        case .usage:
            return "usage: numitissue phase2 <inspect|verify|wrap|contract> ..."
        case .unknownCommand(let command):
            return "unknown Phase 2 command '\(command)'"
        case .unknownContract(let contract):
            return "unknown determinism contract '\(contract)'"
        case .destinationExists(let path):
            return "destination already exists: \(path)"
        case .metalUnavailable:
            return "compact Metal digest artifacts are unavailable on this platform"
        }
    }
}
