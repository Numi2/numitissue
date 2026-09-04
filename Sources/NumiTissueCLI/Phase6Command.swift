import Foundation
import NumiTissueIntegration
import NumiTissueIO

struct Phase6Command {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { help(); return }
        let tail = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h": help()
        case "status":
            guard tail.isEmpty else { throw CommandError.usage }
            try emit(["phase": "6", "scope": "neural-culture observation and held-out prediction",
                "implementation": "partial-uncompiled", "scientificQualification": "not-established",
                "simulationProvider": "required-user-supplied-isolated-provider",
                "metalObserver": "scientific32-source-only-not-performance32-authority"])
        case "demo-recording":
            guard tail.isEmpty else { throw CommandError.usage }
            try emit(demoRecording())
        case "demo-config":
            guard tail.isEmpty else { throw CommandError.usage }
            try emit(CultureFeatureConfiguration())
        case "features":
            guard tail.count == 2 else { throw CommandError.usage }
            let recording: CultureRecording = try read(tail[0])
            let configuration: CultureFeatureConfiguration = try read(tail[1])
            try emit(CultureFeatureExtractor.extract(recording, configuration: configuration))
        case "lead-field":
            guard tail.count == 1 else { throw CommandError.usage }
            let request: LeadFieldRequest = try read(tail[0])
            try emit(CultureLeadFieldBuilder.build(sources: request.sources, electrodes: request.electrodes,
                conductor: request.conductor, reference: request.reference,
                contactQuadraturePoints: request.contactQuadraturePoints,
                maximumCoefficients: request.maximumCoefficients))
        case "study-validate":
            guard tail.count == 1 else { throw CommandError.usage }
            let source: CultureStudyDesign = try read(tail[0])
            let design = try source.validated()
            try emit(StudyInspection(studySHA256: try design.digest(), sessionCount: design.sessions.count,
                                    missingHoldouts: design.missingHoldoutPartitions))
        case "score":
            guard tail.count == 1 else { throw CommandError.usage }
            let request: ScoreRequest = try read(tail[0])
            try emit(CulturePredictiveScorer.score(forecast: request.forecast, observations: request.observations,
                design: request.design, expectedModelSHA256: request.expectedModelSHA256,
                expectedPosteriorSHA256: request.expectedPosteriorSHA256))
        default: throw CommandError.usage
        }
    }

    private static func demoRecording() throws -> CultureRecording {
        let channels = [ElectrodeID(rawValue: 1), ElectrodeID(rawValue: 2)]
        var samples = [Double](repeating: 0, count: 2000)
        for sample in 0..<1000 {
            samples[sample * 2] = 2e-6 * sin(Double(sample) * 0.71)
            samples[sample * 2 + 1] = 2e-6 * cos(Double(sample) * 0.59)
        }
        for sample in [100, 120, 140, 160, 500, 520, 540, 560] {
            samples[sample * 2] -= 60e-6
            samples[(sample + 3) * 2 + 1] -= 50e-6
        }
        return try CultureRecording(recordingID: "synthetic-phase6-example", startSeconds: 0,
            sampleRateHertz: 1000, electrodeIDs: channels, volts: samples,
            sourceSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(samples)),
            measurementModelID: "synthetic-unfiltered-fixture-v1").validated()
    }

    private static func read<T: Decodable>(_ path: String) throws -> T {
        let url = URL(fileURLWithPath: path)
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
            throw CommandError.inputTooLarge
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw CommandError.inputTooLarge }
        return try ScientificCanonicalJSON.decode(T.self, from: data)
    }
    private static func emit<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try ScientificCanonicalJSON.encode(value))
        FileHandle.standardOutput.write(Data([10]))
    }
    private static func help() {
        print("""
        numitissue phase6 status
        numitissue phase6 demo-recording
        numitissue phase6 demo-config
        numitissue phase6 features <recording.json> <configuration.json>
        numitissue phase6 lead-field <geometry-request.json>
        numitissue phase6 study-validate <study.json>
        numitissue phase6 score <score-request.json>

        Output is JSON. The demo is synthetic, not laboratory data or a biological validation.
        No command runs a wetware system, installs dependencies, or authorizes performance32.
        """)
    }
    private struct LeadFieldRequest: Decodable {
        var sources: [CultureCurrentSource]
        var electrodes: [MEAElectrode]
        var conductor: CultureConductor
        var reference: CultureVoltageReference
        var contactQuadraturePoints: Int
        var maximumCoefficients: Int
    }
    private struct StudyInspection: Encodable {
        var studySHA256: ScientificSHA256Digest
        var sessionCount: Int
        var missingHoldouts: [CultureStudyPartition]
    }
    private struct ScoreRequest: Decodable {
        var design: CultureStudyDesign
        var forecast: CultureHeldOutForecast
        var observations: CultureFeatureReport
        var expectedModelSHA256: ScientificSHA256Digest
        var expectedPosteriorSHA256: ScientificSHA256Digest
    }
    private enum CommandError: Error, CustomStringConvertible {
        case usage, inputTooLarge
        var description: String {
            switch self {
            case .usage: return "usage: numitissue phase6 help"
            case .inputTooLarge: return "Phase 6 requires a nonempty regular JSON file no larger than 128 MiB."
            }
        }
    }
}
