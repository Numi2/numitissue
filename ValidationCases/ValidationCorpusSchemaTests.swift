import Foundation
import XCTest
@testable import NumiTissueReference
import NumiTissueCore
import NumiTissueIO

final class ValidationCorpusSchemaTests: XCTestCase {
    func testIndexAndAllDeclaredManifestsDecode() throws {
        let root = try casesRoot()
        let index = try ScientificValidationCorpusIO.loadIndex(
            from: root.appendingPathComponent("index.json")
        )
        let manifests = try ScientificValidationCorpusIO.loadManifests(
            index: index,
            root: root
        )

        XCTAssertEqual(manifests.count, index.entries.count)
        XCTAssertEqual(Set(manifests.map(\.id)), Set(index.entries.map(\.id)))
        XCTAssertTrue(manifests.allSatisfy { !$0.criteria.isEmpty })
        XCTAssertTrue(index.entries.allSatisfy { entry in
            manifests.contains { $0.id == entry.id && $0.tier == entry.tier }
        })
    }

    func testCanonicalDigestsAreStableAcrossDecodeEncodeCycles() throws {
        let root = try casesRoot()
        let first = try ScientificValidationCorpusIO.loadIndex(
            from: root.appendingPathComponent("index.json")
        )
        let firstDigest = try first.digest()
        let encoded = try first.canonicalData()
        let second = try JSONDecoder().decode(ScientificValidationCorpusIndex.self, from: encoded)
        XCTAssertEqual(firstDigest, try second.digest())
        XCTAssertEqual(first, second)
    }

    func testEveryReferencedArtifactExistsInsideItsCaseDirectory() throws {
        let root = try casesRoot()
        let index = try ScientificValidationCorpusIO.loadIndex(
            from: root.appendingPathComponent("index.json")
        )
        for entry in index.entries {
            let manifestURL = root.appendingPathComponent(entry.manifestPath)
            let manifest = try ScientificValidationCorpusIO.loadManifest(from: manifestURL)
            let directory = manifestURL.deletingLastPathComponent()
            for relativePath in [manifest.modelPath, manifest.inputPath, manifest.reference.artifactPath].compactMap({ $0 }) {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path),
                    "\(manifest.id) is missing \(relativePath)"
                )
            }
        }
    }

    func testPathValidationRejectsTraversalAndUnstableIdentifiers() {
        XCTAssertFalse(ValidationCorpusPath.isSafeRelativePath("../reference.json"))
        XCTAssertFalse(ValidationCorpusPath.isSafeRelativePath("/tmp/reference.json"))
        XCTAssertFalse(ValidationCorpusPath.isSafeRelativePath("Cases\\reference.json"))
        XCTAssertFalse(ValidationCorpusPath.isStableIdentifier("Passive RC"))
        XCTAssertFalse(ValidationCorpusPath.isStableIdentifier("passive_rc"))
        XCTAssertTrue(ValidationCorpusPath.isStableIdentifier("electrophysiology.passive-rc"))
    }

    private func casesRoot(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Cases", withExtension: nil) else {
            XCTFail("SwiftPM did not bundle ValidationCases/Cases", file: file, line: line)
            throw TestResourceError.missingCases
        }
        return url
    }
}

private enum TestResourceError: Error { case missingCases }
