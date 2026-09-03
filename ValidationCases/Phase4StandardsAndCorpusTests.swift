import Foundation
import XCTest
import NumiTissueData
import NumiTissueIO

final class Phase4StandardsAndCorpusTests: XCTestCase {
    func testConformanceMatrixCoversEveryDeclaredStandard() throws {
        let matrix = try NumiTissueStandardConformance.phase4Baseline.validated()
        XCTAssertEqual(
            Set(matrix.standards.map(\.standard)),
            Set(ScientificInterchangeStandard.allCases)
        )
        XCTAssertEqual(matrix.coverage.total, matrix.features.count)
        XCTAssertGreaterThan(matrix.coverage.supported, 0)
        XCTAssertGreaterThan(matrix.coverage.preservedNotExecutable, 0)
        XCTAssertGreaterThan(matrix.coverage.rejected, 0)
        XCTAssertEqual(
            try matrix.sha256(),
            ScientificSHA256Digest(data: try matrix.canonicalData())
        )
    }

    func testSyntheticCorpusPinsMatchRepositoryBytes() throws {
        let manifest = try NumiTissuePhase4Corpus.conformanceFixtureManifest()
        let report = try ScientificCorpusVerifier.verify(
            manifest: manifest,
            root: repositoryRoot()
        )
        XCTAssertTrue(
            report.passed,
            report.failures.map(\.message).joined(separator: "\n")
        )
        XCTAssertEqual(report.assets.count, 9)
        XCTAssertTrue(report.assets.allSatisfy {
            $0.expectedSHA256 == $0.actualSHA256 &&
                $0.expectedByteCount == $0.actualByteCount
        })
    }

    func testStreamingDigestMatchesKnownSHA256Vector() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.bin")
        try Data("abc".utf8).write(to: file)

        let result = try ScientificFileDigester.sha256(
            at: file,
            chunkBytes: 4_096,
            maximumBytes: 3
        )
        XCTAssertEqual(result.byteCount, 3)
        XCTAssertEqual(
            result.sha256.description,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testSWCRoundTripPreservesTreeAndMetadata() throws {
        let source = try fixtureURL("minimal.swc")
        let morphology = try SWCImporter.load(
            url: source,
            requireSingleRoot: true
        )
        XCTAssertEqual(morphology.nodes.count, 3)
        XCTAssertEqual(morphology.metadata["name"], "phase4_minimal")
        XCTAssertEqual(morphology.roots.map(\.id), [1])
        XCTAssertEqual(morphology.nodes.last?.kind, .custom)
        XCTAssertEqual(morphology.nodes.last?.customKind, 7)

        let encoded = try SWCExporter.encode(morphology)
        let reparsed = try SWCImporter.parse(
            encoded,
            requireSingleRoot: true
        )
        XCTAssertEqual(reparsed, morphology)
    }

    func testNeuroMLPreservesNonExecutableBiophysicsAndLowersMorphology() throws {
        let document = try NeuroMLImporter.load(
            url: try fixtureURL("minimal-neuroml.xml")
        )
        XCTAssertEqual(document.id, "phase4_neuroml")
        XCTAssertEqual(document.includes, ["phase4-channels.xml"])
        XCTAssertEqual(document.cells.count, 1)
        let cell = try XCTUnwrap(document.cells.first)
        XCTAssertEqual(cell.segments.count, 2)
        XCTAssertEqual(cell.segmentGroups.count, 2)
        XCTAssertEqual(cell.specificCapacitance, "1 uF_per_cm2")
        XCTAssertEqual(cell.resistivity, "100 ohm_cm")
        XCTAssertEqual(cell.channelDensities.count, 1)
        XCTAssertEqual(cell.channelDensities.first?.ionChannel, "pas")

        let morphology = try cell.asSWC()
        XCTAssertEqual(morphology.nodes.count, 2)
        XCTAssertEqual(morphology.metadata["source"], "NeuroML")
        XCTAssertEqual(morphology.metadata["cell"], "phase4_cell")
    }

    func testLEMSPreservesUnitsAndContinuousEventDynamics() throws {
        let document = try LEMSXMLImporter.load(
            url: try fixtureURL("minimal-lems.xml")
        )
        _ = try document.validated()
        XCTAssertNotNil(document.dimensions["time"])
        XCTAssertNotNil(document.dimensions["voltage"])
        XCTAssertTrue(document.units.contains { $0.symbol == "ms" })
        XCTAssertTrue(document.units.contains { $0.symbol == "mV" })
        let component = try XCTUnwrap(
            document.componentTypes.first { $0.name == "Phase4Cell" }
        )
        let dynamics = try XCTUnwrap(component.dynamics)
        XCTAssertEqual(dynamics.stateVariables.map(\.name), ["v"])
        XCTAssertEqual(dynamics.derivatives.map(\.variable), ["v"])
        XCTAssertEqual(dynamics.onConditions.count, 1)
        XCTAssertEqual(dynamics.regimes.map(\.name), ["resting"])
        XCTAssertEqual(dynamics.regimes.first?.derivatives.map(\.variable), ["v"])
    }

    func testSBMLCoreLowersToMolecularProgram() throws {
        let document = try SBMLXMLImporter.load(
            url: try fixtureURL("minimal-sbml.xml")
        )
        XCTAssertEqual(document.id, "phase4_decay")
        XCTAssertEqual(document.level, 3)
        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.species.map(\.id), ["S"])
        XCTAssertEqual(document.reactions.map(\.id), ["decay"])

        let program = try SBMLToMolecularIRCompiler.compile(document)
        XCTAssertEqual(program.species.map(\.id), ["S"])
        XCTAssertEqual(program.reactions.map(\.id), ["decay"])
        let reaction = try XCTUnwrap(program.reactions.first)
        XCTAssertEqual(reaction.rateConstant, 0.1, accuracy: 1e-12)
        XCTAssertEqual(program.sourceMetadata["format"], "SBML")
    }

    func testRestrictedNMODLCompilesToPortableBytecode() throws {
        let model = try NMODLCompiler.load(
            url: try fixtureURL("minimal.mod")
        )
        XCTAssertEqual(model.name, "phase4_pas")
        XCTAssertTrue(model.nonspecificCurrents.contains("i"))
        XCTAssertTrue(model.rangeVariables.contains("g"))
        XCTAssertTrue(model.rangeVariables.contains("e"))

        let bytecode = try MechanismBytecodeCompiler.compile(model)
        XCTAssertEqual(bytecode.name, "phase4_pas")
        XCTAssertGreaterThan(bytecode.variables.count, 0)
        XCTAssertGreaterThan(bytecode.instructions.count, 0)
    }

    func testSONATAConfigurationAndTypeTablesAreDeterministic() throws {
        let configurationURL = try fixtureURL("sonata-config.json")
        let configuration = try SONATAConfigurationLoader.loadCanonical(
            url: configurationURL
        )
        XCTAssertEqual(configuration.networks.count, 2)
        XCTAssertEqual(configuration.manifest["BASE_DIR"], ".")
        XCTAssertEqual(
            configuration.components["morphologies_dir"],
            "$BASE_DIR"
        )
        let nodesReference = try XCTUnwrap(
            configuration.networks.first { $0.nodesFile != nil }
        )
        XCTAssertEqual(
            try configuration.resolve(
                path: try XCTUnwrap(nodesReference.nodesFile),
                relativeTo: configurationURL
            ).lastPathComponent,
            "nodes.h5"
        )

        let nodeTypes = try SONATACSVReader.readNodeTypes(
            url: try fixtureURL("node_types.csv")
        )
        let edgeTypes = try SONATACSVReader.readEdgeTypes(
            url: try fixtureURL("edge_types.csv")
        )
        XCTAssertEqual(nodeTypes.keys.sorted(), [1])
        XCTAssertEqual(edgeTypes.keys.sorted(), [1])
        XCTAssertEqual(
            nodeTypes[1]?["model_type"]?.stringValue,
            "biophysical"
        )
        XCTAssertEqual(
            edgeTypes[1]?["model_template"]?.stringValue,
            "exp2syn"
        )
    }

    func testCandidateCatalogCannotBecomePublishableWithoutLicensesAndHashes() throws {
        let catalog = try NumiTissuePhase4Corpus.candidateCatalog()
        XCTAssertEqual(catalog.entries.count, 5)
        XCTAssertTrue(catalog.entries.allSatisfy {
            $0.readiness == .sourcePinned
        })
        XCTAssertThrowsError(
            try catalog.validated(policy: .publishable)
        ) { error in
            guard case ScientificCorpusError.unresolvedLicense = error else {
                return XCTFail("Unexpected publication-gate error: \(error)")
            }
        }
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let root = try casesRoot()
        let url = root
            .appendingPathComponent("Phase4", isDirectory: true)
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Phase4TestError.missingFixture(name)
        }
        return url
    }

    private func casesRoot(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Cases",
            withExtension: nil
        ) else {
            XCTFail(
                "SwiftPM did not bundle ValidationCases/Cases",
                file: file,
                line: line
            )
            throw Phase4TestError.missingCases
        }
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private enum Phase4TestError: Error {
    case missingCases
    case missingFixture(String)
}
