import Foundation
import XCTest
import NumiTissueIO

final class Phase4SidecarProtocolTests: XCTestCase {
    func testEveryBuiltInToolchainPinValidates() throws {
        XCTAssertEqual(
            Set(NumiTissuePhase4Sidecars.all.map(\.sidecar)),
            Set(ScientificSidecarKind.allCases)
        )
        for pin in NumiTissuePhase4Sidecars.all {
            XCTAssertEqual(try pin.validated(), pin)
            XCTAssertEqual(
                try pin.sha256(),
                ScientificSHA256Digest(data: try pin.canonicalData())
            )
        }
    }

    func testRequestIdentityIsStableAcrossCanonicalRoundTrip() throws {
        let request = try makeNWBRequest().validated()
        let data = try request.canonicalData()
        let decoded = try ScientificCanonicalJSON.decode(
            ScientificSidecarRequest.self,
            from: data
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(try decoded.sha256(), try request.sha256())
    }

    func testUnsafeInputPathIsRejected() throws {
        var request = makeNWBRequest()
        request.inputs[0].relativePath = "../recording.nwb"
        XCTAssertThrowsError(try request.validated()) { error in
            guard case ScientificSidecarError.invalidInput("nwb") = error else {
                return XCTFail("Unexpected unsafe-path error: \(error)")
            }
        }
    }

    func testReferenceRequestRequiresFixedEngineIdentity() throws {
        let input = ScientificSidecarInput(
            id: "model",
            relativePath: "model.json",
            mediaType: "application/json",
            role: "model",
            sha256: ScientificSHA256Digest(data: Data("model".utf8)),
            byteCount: 5
        )
        let request = ScientificSidecarRequest(
            requestID: "reference-without-engine",
            sidecar: .reference,
            operation: .simulate,
            toolchain: NumiTissuePhase4Sidecars.reference,
            inputs: [input]
        )
        XCTAssertThrowsError(try request.validated()) { error in
            guard case ScientificSidecarError.referenceEngineNotPinned = error else {
                return XCTFail("Unexpected fixed-engine error: \(error)")
            }
        }
    }

    func testMatchingResponseValidatesAgainstRequest() throws {
        let request = try makeNWBRequest().validated()
        let artifact = ScientificSidecarArtifact(
            logicalName: "nwb-inspection",
            role: "inspection",
            relativePath: "nwb-inspection.json",
            mediaType: "application/json",
            byteCount: 128,
            sha256: ScientificSHA256Digest(data: Data("artifact".utf8)),
            metadata: ["nwbVersion": "2.10.0"]
        )
        let response = ScientificSidecarResponse(
            requestID: request.requestID,
            requestSHA256: try request.sha256(),
            sidecar: request.sidecar,
            operation: request.operation,
            status: .completed,
            toolchain: request.toolchain,
            artifacts: [artifact],
            metrics: ["artifactBytes": 128],
            metadata: ["implementation": "numitissue-nwb"]
        )
        XCTAssertEqual(try response.validated(for: request), response)
    }

    func testResponseRequestSubstitutionIsRejected() throws {
        let request = try makeNWBRequest().validated()
        var response = ScientificSidecarResponse(
            requestID: request.requestID,
            requestSHA256: try request.sha256(),
            sidecar: request.sidecar,
            operation: request.operation,
            status: .completed,
            toolchain: request.toolchain
        )
        response.requestSHA256 = ScientificSHA256Digest(
            data: Data("substituted".utf8)
        )
        XCTAssertThrowsError(try response.validated(for: request)) { error in
            guard case ScientificSidecarError.responseRequestMismatch = error else {
                return XCTFail("Unexpected substitution error: \(error)")
            }
        }
    }

    func testCompletedResponseCannotContainErrorDiagnostic() throws {
        let request = try makeNWBRequest().validated()
        let response = ScientificSidecarResponse(
            requestID: request.requestID,
            requestSHA256: try request.sha256(),
            sidecar: request.sidecar,
            operation: request.operation,
            status: .completed,
            toolchain: request.toolchain,
            diagnostics: [
                ScientificSidecarDiagnostic(
                    severity: .error,
                    code: "nwb.invalid",
                    message: "Invalid test payload"
                )
            ]
        )
        XCTAssertThrowsError(try response.validated(for: request)) { error in
            guard case ScientificSidecarError.completedResponseContainsError = error else {
                return XCTFail("Unexpected diagnostic-state error: \(error)")
            }
        }
    }

    func testNonFiniteResponseMetricIsRejected() throws {
        let request = try makeNWBRequest().validated()
        let response = ScientificSidecarResponse(
            requestID: request.requestID,
            requestSHA256: try request.sha256(),
            sidecar: request.sidecar,
            operation: request.operation,
            status: .completed,
            toolchain: request.toolchain,
            metrics: ["invalid": .infinity]
        )
        XCTAssertThrowsError(try response.validated(for: request)) { error in
            guard case ScientificSidecarError.invalidResponse = error else {
                return XCTFail("Unexpected finite-metric error: \(error)")
            }
        }
    }

    private func makeNWBRequest() -> ScientificSidecarRequest {
        ScientificSidecarRequest(
            requestID: "phase4-nwb-inspect",
            sidecar: .nwb,
            operation: .inspect,
            toolchain: NumiTissuePhase4Sidecars.nwb,
            inputs: [
                ScientificSidecarInput(
                    id: "nwb",
                    relativePath: "recordings/session.nwb",
                    mediaType: "application/x-nwb",
                    role: "electrophysiology-recording",
                    sha256: ScientificSHA256Digest(
                        data: Data("recording".utf8)
                    ),
                    byteCount: 9
                )
            ],
            selection: ScientificSidecarSelection(
                objectPaths: ["/session", "/units"],
                maximumRecords: 1_000,
                maximumSamplesPerSeries: 100_000,
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
        )
    }
}
