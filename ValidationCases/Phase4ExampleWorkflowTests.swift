import Foundation
import XCTest
import NumiTissueIO

final class Phase4ExampleWorkflowTests: XCTestCase {
    func testReferenceExampleRequestBindsItsInput() throws {
        try verifyExample(
            directory: "reference",
            expectedSidecar: .reference,
            expectedOperation: .simulate,
            expectedImplementation: "numitissue-reference"
        )
    }

    func testEFELExampleRequestBindsItsInput() throws {
        try verifyExample(
            directory: "efel",
            expectedSidecar: .efel,
            expectedOperation: .featureExtract,
            expectedImplementation: "numitissue-efel"
        )
    }

    func testJaxleyExampleRequestBindsItsInput() throws {
        try verifyExample(
            directory: "jaxley",
            expectedSidecar: .jaxley,
            expectedOperation: .simulate,
            expectedImplementation: "numitissue-jaxley"
        )
    }

    private func verifyExample(
        directory: String,
        expectedSidecar: ScientificSidecarKind,
        expectedOperation: ScientificSidecarOperation,
        expectedImplementation: String
    ) throws {
        let root = repositoryRoot()
            .appendingPathComponent("Examples", isDirectory: true)
            .appendingPathComponent("Phase4", isDirectory: true)
            .appendingPathComponent(directory, isDirectory: true)
        let requestURL = root.appendingPathComponent("request.json")
        let request = try ScientificCanonicalJSON.decode(
            ScientificSidecarRequest.self,
            from: Data(contentsOf: requestURL, options: [.mappedIfSafe])
        ).validated()

        XCTAssertEqual(request.sidecar, expectedSidecar)
        XCTAssertEqual(request.operation, expectedOperation)
        XCTAssertEqual(request.toolchain.implementation, expectedImplementation)
        XCTAssertEqual(request.inputs.count, 1)
        let input = try XCTUnwrap(request.inputs.first)
        let inputURL = root.appendingPathComponent(input.relativePath)
        let digest = try ScientificFileDigester.sha256(at: inputURL)
        XCTAssertEqual(digest.sha256, input.sha256)
        XCTAssertEqual(digest.byteCount, input.byteCount)
        XCTAssertEqual(
            try request.sha256(),
            ScientificSHA256Digest(data: try request.canonicalData())
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
