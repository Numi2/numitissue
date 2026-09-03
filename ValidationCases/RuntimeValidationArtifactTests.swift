import Foundation
import XCTest
import NumiTissue

final class RuntimeValidationArtifactTests: XCTestCase {
    func testBenchmarkArtifactRoundTripsAndVerifiesPayloadHash() throws {
        let report = makeBenchmarkReport()
        let artifact = try RuntimeValidationArtifactIO.makeBenchmark(
            report,
            metadata: [
                "git.commit": "test-commit",
                "validation.case": "phase2.artifact-roundtrip"
            ]
        )
        let data = try RuntimeValidationArtifactIO.encode(artifact)
        let decoded = try RuntimeValidationArtifactIO.decode(
            RuntimeBenchmarkReport.self,
            from: data,
            expectedKind: .benchmarkReport
        )

        XCTAssertEqual(decoded.kind, .benchmarkReport)
        XCTAssertEqual(decoded.payloadSHA256, artifact.payloadSHA256)
        XCTAssertEqual(decoded.payload.backendName, "test-backend")
        XCTAssertEqual(
            decoded.metadata["validation.case"],
            "phase2.artifact-roundtrip"
        )
        XCTAssertEqual(
            try decoded.artifactSHA256(),
            ScientificSHA256Digest(data: data)
        )
        let probe = try RuntimeValidationArtifactInspector.verify(data: data)
        XCTAssertEqual(probe.kind, .benchmarkReport)
        XCTAssertEqual(probe.payloadSHA256, artifact.payloadSHA256)
    }

    func testTamperedPayloadIsRejected() throws {
        let artifact = try RuntimeValidationArtifactIO.makeBenchmark(
            makeBenchmarkReport()
        )
        let data = try RuntimeValidationArtifactIO.encode(artifact)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["backendName"] = "tampered-backend"
        object["payload"] = payload
        let tampered = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        XCTAssertThrowsError(
            try RuntimeValidationArtifactIO.decode(
                RuntimeBenchmarkReport.self,
                from: tampered,
                expectedKind: .benchmarkReport
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("SHA-256 mismatch")
            )
        }
    }

    func testArtifactWriterRefusesSilentOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("benchmark.json")
        let artifact = try RuntimeValidationArtifactIO.makeBenchmark(
            makeBenchmarkReport()
        )

        try RuntimeValidationArtifactIO.write(
            artifact,
            to: destination
        )
        XCTAssertThrowsError(
            try RuntimeValidationArtifactIO.write(
                artifact,
                to: destination
            )
        )
        try RuntimeValidationArtifactIO.write(
            artifact,
            to: destination,
            overwrite: true
        )
        let decoded = try RuntimeValidationArtifactIO.read(
            RuntimeBenchmarkReport.self,
            from: destination,
            expectedKind: .benchmarkReport
        )
        XCTAssertEqual(decoded.payload.backendName, "test-backend")
    }

    private func makeBenchmarkReport() -> RuntimeBenchmarkReport {
        let sample = RuntimeBenchmarkSample(
            ordinal: 0,
            transaction: TransactionID(rawValue: 1),
            startTick: 0,
            endTick: 200,
            wallNanoseconds: 1_000_000,
            counters: RuntimeCounters(),
            validationIssueCount: 0
        )
        return RuntimeBenchmarkReport(
            backendName: "test-backend",
            numericalProfile: .scientific32,
            configuration: RuntimeBenchmarkConfiguration(
                warmupTransactions: 0,
                measuredTransactions: 1
            ),
            samples: [sample],
            statistics: RuntimeBenchmarkStatistics(
                samples: [sample.wallNanoseconds]
            ),
            simulatedMilliseconds: 5,
            wallSeconds: 0.001,
            footprint: RuntimeStateFootprintEstimator.estimate(
                ValidationFixtures.passiveState()
            ),
            telemetry: nil,
            finalStateDigest: RuntimeStateDigestBuilder.make(
                state: ValidationFixtures.passiveState()
            ).combined,
            metadata: ["case": "phase2.artifact"]
        )
    }
}
