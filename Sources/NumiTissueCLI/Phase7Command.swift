import Foundation
import NumiTissueIntegration
import NumiTissueIO

struct Phase7Command {
    static func run(_ arguments: [String]) async throws {
        guard let command = arguments.first else { help(); return }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "help", "--help": help()
        case "status":
            guard tail.isEmpty else { throw CLIError.usage }
            try emit([
                "phase": "7",
                "implementation": "closed-loop-and-prepared-suite-source-implemented-uncompiled",
                "executionQualification": "not-established",
                "physicalBackend": "requires-device-local-watchdog-and-external-operator-admission",
                "automaticLiveStimulation": "disabled-no-default-live-adapter",
                "suiteRecovery": "idempotent-process-local-prepared-commit; durable-journal-replay",
                "processRestartRecovery": "requires-native-participant-prepared-state-restoration",
                "performance32": "not-authorized-by-phase7",
                "legacyVirtualBackend": "not-admitted-to-guarded-loop-without-a-reviewed-adapter"
            ])
        case "replay-example":
            guard tail.isEmpty else { throw CLIError.usage }
            try emit(await ClosedLoopReplayExample.run())
        case "safety-example":
            guard tail.isEmpty else { throw CLIError.usage }
            let configuration = ClosedLoopReplayExample.configuration()
            guard let id = UUID(uuidString: "00000000-0000-4000-8000-000000000070") else { throw CLIError.usage }
            try emit(SafetyRequest(request: .init(id: id, plan: ClosedLoopReplayExample.plan(),
                scheduledTimeNanoseconds: 10_000_000, deadlineNanoseconds: 20_000_000),
                configuration: configuration, destinations: [Destination(electrode: .init(rawValue: 1), destination: 0)],
                envelope: ClosedLoopReplayExample.envelope(), deviceNowNanoseconds: 1_000_000,
                minimumLeadTimeNanoseconds: 0, timestampResolutionNanoseconds: 1_000, history: []))
        case "safety-check":
            guard tail.count == 1 else { throw CLIError.usage }
            let request: SafetyRequest = try read(tail[0])
            guard Set(request.destinations.map(\.electrode)).count == request.destinations.count else {
                throw CLIError.invalid("duplicate electrode destination")
            }
            try emit(ClosedLoopSafetyEvaluator.evaluate(request: request.request,
                configuration: request.configuration,
                destinations: Dictionary(uniqueKeysWithValues: request.destinations.map { ($0.electrode, $0.destination) }),
                envelope: request.envelope, deviceNowNanoseconds: request.deviceNowNanoseconds,
                deviceMinimumLeadNanoseconds: request.minimumLeadTimeNanoseconds,
                timestampResolutionNanoseconds: request.timestampResolutionNanoseconds, history: request.history))
        case "journal-verify":
            guard tail.count == 2, let runID = UUID(uuidString: tail[1]) else { throw CLIError.usage }
            let bytes = try readBytes(tail[0])
            guard bytes.last == 10 else { throw CLIError.invalid("incomplete journal tail") }
            let records = try bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast().map {
                try ScientificCanonicalJSON.decode(ClosedLoopAuditRecord.self, from: Data($0))
            }
            let digest = try ClosedLoopJournalVerifier.verify(records, expectedRunID: runID)
            try emit(["runID": runID.uuidString, "records": String(records.count), "terminalSHA256": digest.hexadecimal,
                      "qualification": "integrity-only-not-proof-of-hardware-execution"])
        case "suite-recovery-inspect":
            guard tail.count == 2, let runID = UUID(uuidString: tail[1]) else { throw CLIError.usage }
            let journal = try DurableSuiteTransactionJournal(url: URL(fileURLWithPath: tail[0]), runID: runID, reopenExisting: true)
            try emit(await journal.recoveryDecisions())
        default: throw CLIError.usage
        }
    }
    private struct Destination: Codable { var electrode: ElectrodeID; var destination: UInt64 }
    private struct SafetyRequest: Codable {
        var request: NeuralStimulationRequest
        var configuration: MEAConfiguration
        var destinations: [Destination]
        var envelope: ClosedLoopSafetyEnvelope
        var deviceNowNanoseconds: UInt64
        var minimumLeadTimeNanoseconds: UInt64
        var timestampResolutionNanoseconds: UInt64
        var history: [ClosedLoopExposure]
    }
    private static func readBytes(_ path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        var current = url
        while current.path != "/" {
            let attributes = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard attributes.isSymbolicLink != true else { throw CLIError.invalid("symlink input") }
            current.deleteLastPathComponent()
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 67_108_864 else {
            throw CLIError.invalid("input must be a bounded nonempty regular file")
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 67_108_864 else { throw CLIError.invalid("input grew beyond limit") }
        return bytes
    }
    private static func read<T: Decodable>(_ path: String) throws -> T {
        try ScientificCanonicalJSON.decode(T.self, from: readBytes(path))
    }
    private static func emit<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try ScientificCanonicalJSON.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }
    private static func help() {
        print("""
        numitissue phase7 status
        numitissue phase7 replay-example
        numitissue phase7 safety-example
        numitissue phase7 safety-check <safety-request.json>
        numitissue phase7 journal-verify <records.jsonl> <run-uuid>
        numitissue phase7 suite-recovery-inspect <suite.jsonl> <run-uuid>

        All output except help is JSON. Replay and safety-example are synthetic software fixtures.
        No command connects to living cultures, arms hardware, or issues biological qualification.
        A passing safety-check does not authorize dispatch; the session recomputes all checks.
        """)
    }
    private enum CLIError: Error, CustomStringConvertible {
        case usage, invalid(String)
        var description: String {
            switch self {
            case .usage: return "usage: numitissue phase7 help"
            case .invalid(let reason): return "Phase 7: \(reason)"
            }
        }
    }
}
