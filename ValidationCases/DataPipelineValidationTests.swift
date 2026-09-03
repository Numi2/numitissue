import Foundation
import XCTest
import NumiTissue

private struct DataFixtureTransport: BiologicalDataTransport {
    let pagePayload: Data
    let infoPayload: Data
    let staticPayload: Data

    func execute(_ request: BiologicalDataRequest) async throws -> BiologicalDataResponse {
        let payload: Data
        switch request.locator {
        case .dandi:
            payload = pagePayload
        case .https(let url) where url.contains("/info/"):
            payload = infoPayload
        case .https:
            payload = staticPayload
        default:
            throw NSError(
                domain: "DataFixtureTransport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected fixture locator"]
            )
        }
        return BiologicalDataResponse(
            requestID: request.id,
            statusCode: 200,
            data: payload,
            headers: [
                "content-type": "application/json",
                "content-length": String(payload.count)
            ],
            finalLocator: request.locator,
            receivedAt: Date(timeIntervalSince1970: 1),
            transferDurationSeconds: 0.001
        )
    }
}

final class DataPipelineValidationTests: XCTestCase {
    func testDANDIAdapterDecoderAcquisitionAndProvenanceFixture() async throws {
        let pagePayload = Data(#"{"results":[{"asset_id":"asset-1","path":"sub-01/cells.nwb","size":3}],"next":null}"#.utf8)
        let infoPayload = Data(#"{"identifier":"asset-1","path":"sub-01/cells.nwb","contentSize":3,"digest":{"dandi:sha2-256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"contentUrl":["https://storage.googleapis.com/fixture/cells.nwb"],"encodingFormat":"application/x-nwb"}"#.utf8)
        let adapter = try DANDIDatasetAdapter()
        let dataset = DatasetVersion(
            source: .dandi,
            datasetID: "000001",
            release: "0.1.0",
            sourceURI: "https://api.dandiarchive.org/api/dandisets/000001/versions/0.1.0/",
            stability: .immutableRelease
        )
        let selection = DatasetSelection(
            modalities: [.electrophysiology],
            representations: [.electrophysiologyTraces],
            budget: DatasetSelectionBudget(
                maximumEntities: 16,
                maximumCells: 16,
                maximumSynapses: 16,
                maximumAssets: 16,
                maximumTransferredBytes: 1_048_576,
                maximumDecodedBytes: 1_048_576,
                maximumConcurrentRequests: 2
            )
        )

        let firstPlan = try adapter.makeQueryPlan(dataset: dataset, selection: selection)
        let secondPlan = try adapter.makeQueryPlan(dataset: dataset, selection: selection)
        XCTAssertEqual(firstPlan, secondPlan)
        XCTAssertEqual(firstPlan.requests.count, 1)
        XCTAssertEqual(firstPlan.requests[0].locator.canonicalDescription, "dandi://000001/0.1.0/")

        let registry = try DatasetDecoderRegistry(decoders: [
            try DANDIAssetPageDecoder(),
            try DANDIAssetInfoDecoder()
        ])
        let engine = try DatasetAcquisitionEngine(
            transport: DataFixtureTransport(
                pagePayload: pagePayload,
                infoPayload: infoPayload,
                staticPayload: Data()
            ),
            decoders: registry,
            configuration: DatasetAcquisitionConfiguration(
                maximumConcurrency: 2,
                maximumExpansionDepth: 4,
                maximumTotalRequests: 8,
                allowEmptyEvidenceBatch: false
            )
        )
        let result = try await engine.acquire(plan: firstPlan)

        XCTAssertEqual(result.fragments.count, 2)
        XCTAssertEqual(result.batch.assets.count, 1)
        XCTAssertEqual(result.batch.assets[0].id, "dandi:asset-1")
        XCTAssertEqual(result.batch.assets[0].encoding, .nwb)
        XCTAssertEqual(result.batch.assets[0].checksum, String(repeating: "a", count: 64))
        XCTAssertEqual(result.report.fragmentCount, 2)
        XCTAssertEqual(result.report.assetCount, 1)
        XCTAssertEqual(result.report.networkTransferredBytes, UInt64(pagePayload.count + infoPayload.count))
        XCTAssertGreaterThan(result.batch.provenance.nodes.count, 0)
        XCTAssertGreaterThan(result.batch.provenance.edges.count, 0)
        XCTAssertNoThrow(try result.batch.provenance.validated())
        let decodedFragment = try XCTUnwrap(result.fragments.last)
        let outputNode = try XCTUnwrap(decodedFragment.provenance.nodes.first { $0.label.contains("DANDI asset") })
        let sourceNode = try XCTUnwrap(decodedFragment.provenance.nodes.first { $0.type == "numitissue:ExternalDatasetResponse" })
        let lineage = try decodedFragment.provenance.lineage(of: outputNode.id)
        XCTAssertTrue(lineage.contains { $0.id == sourceNode.id })
    }

    func testChecksumAndResponseContractsFailClosed() async throws {
        let payload = Data("fixture-payload".utf8)
        let adapter = try SourceURIDatasetAdapter(
            adapterID: "fixture-source-v1",
            source: .custom,
            capabilities: BiologicalDatasetAdapterCapabilities(
                source: .custom,
                modalities: [.anatomy],
                representations: [.annotations]
            ),
            decoderID: "empty-fixture",
            expectedEncoding: .json,
            expectedMediaType: "application/json"
        )
        let dataset = DatasetVersion(
            source: .custom,
            datasetID: "fixture",
            release: "1",
            sourceURI: "https://fixture.example/source.json",
            stability: .immutableRelease
        )
        let selection = DatasetSelection(
            modalities: [.anatomy],
            representations: [.annotations],
            budget: DatasetSelectionBudget(
                maximumEntities: 4,
                maximumCells: 4,
                maximumSynapses: 4,
                maximumAssets: 4,
                maximumTransferredBytes: 1_048_576,
                maximumDecodedBytes: 1_048_576,
                maximumConcurrentRequests: 1
            )
        )
        var plan = try adapter.makeQueryPlan(dataset: dataset, selection: selection)
        plan.requests[0].expectedChecksum = ScientificSHA256Digest(data: payload)
        plan.requests[0].expectedByteCount = UInt64(payload.count)
        plan = try plan.validated()

        let registry = try DatasetDecoderRegistry(
            decoders: [try EmptyDatasetResponseDecoder(id: "empty-fixture")]
        )
        let engine = try DatasetAcquisitionEngine(
            transport: DataFixtureTransport(
                pagePayload: Data(),
                infoPayload: Data(),
                staticPayload: payload
            ),
            decoders: registry,
            configuration: DatasetAcquisitionConfiguration(
                requireDeclaredChecksum: true,
                allowEmptyEvidenceBatch: true
            )
        )
        let result = try await engine.acquire(plan: plan)
        XCTAssertEqual(result.report.requestReports[0].contentDigest, ScientificSHA256Digest(data: payload).hexadecimal)

        var mismatchedPlan = plan
        mismatchedPlan.requests[0].expectedChecksum = ScientificSHA256Digest(data: Data("different".utf8))
        do {
            _ = try await engine.acquire(plan: mismatchedPlan)
            XCTFail("A checksum mismatch must reject the required request")
        } catch {
            XCTAssertTrue(String(describing: error).contains("checksum mismatch"))
        }
    }

    func testEvidenceFusionAndDeterministicEvidenceBuild() throws {
        let entity = BiologicalEntityKey(kind: .cell, identifier: "cell-1")
        let property = BiologicalProperty.restingPotential
        let firstDataset = DatasetVersion(
            source: .dandi,
            datasetID: "dandi-fixture",
            release: "1",
            stability: .immutableRelease
        )
        let secondDataset = DatasetVersion(
            source: .h01,
            datasetID: "h01-fixture",
            release: "1",
            stability: .immutableRelease
        )
        func record(
            id: String,
            value: Double,
            source: BiologicalDataSource,
            dataset: DatasetVersion
        ) -> EvidenceRecord {
            EvidenceRecord(
                id: id,
                entity: entity,
                property: property,
                value: .scalar(value),
                unit: .millivolt,
                source: source,
                modalities: [.electrophysiology],
                datasetReference: dataset.stableReference,
                quality: EvidenceQuality(
                    confidence: 0.95,
                    method: .patchClamp,
                    curation: .independentlyReplicated,
                    sampleCount: 3
                )
            )
        }
        let records = [
            record(id: "record-b", value: -65.0, source: .dandi, dataset: firstDataset),
            record(id: "record-a", value: -64.5, source: .h01, dataset: secondDataset)
        ]
        let policy = EvidenceFusionPolicy(
            strategy: .robustHuber,
            minimumSupport: 2,
            targetUnit: .millivolt,
            agreementAbsoluteTolerance: 0.1
        )
        let fusion = EvidenceFusionEngine()
        let resolved = try fusion.resolve(records, policy: policy)
        XCTAssertEqual(resolved.supportingRecordIDs, ["record-a", "record-b"])
        XCTAssertTrue(resolved.confidence.isFinite)
        XCTAssertTrue(resolved.conflictScore.isFinite)
        XCTAssertEqual(
            fusion.resolveAll(records.reversed(), policy: policy),
            fusion.resolveAll(records, policy: policy)
        )

        let blueprint = CanonicalTissueBlueprint(
            name: "deterministic-empty-fixture",
            sourceDatasets: [firstDataset, secondDataset],
            evidence: records
        )
        let compiler = TissueEvidenceCompiler()
        let first = try compiler.compileExecutable(
            blueprint,
            fusionReport: fusion.resolveAll(records, policy: policy),
            runtimeConfiguration: .scientific
        )
        let second = try compiler.compileExecutable(
            blueprint,
            fusionReport: fusion.resolveAll(records.reversed(), policy: policy),
            runtimeConfiguration: .scientific
        )
        XCTAssertEqual(first.source.report.blueprintDigest, second.source.report.blueprintDigest)
        XCTAssertEqual(
            try ScientificCanonicalJSON.encode(first.source.model),
            try ScientificCanonicalJSON.encode(second.source.model)
        )
        XCTAssertEqual(first.executable.manifest, second.executable.manifest)
        XCTAssertEqual(first.executable.allocation, second.executable.allocation)
    }

    func testNMODLBytecodeKeepsUnboundedLimitsFinite() throws {
        let source = """
        NEURON {
            SUFFIX fixture
        }
        PARAMETER {
            g = 0.1
        }
        STATE {
            m = 0
        }
        BREAKPOINT {
            SOLVE state METHOD derivimplicit
        }
        DERIVATIVE state {
            m' = -m / 5
        }
        """
        let model = try NMODLCompiler.compile(source, sourceName: "fixture.mod")
        let bytecode = try MechanismBytecodeCompiler.compile(model)
        XCTAssertTrue(bytecode.variables.allSatisfy {
            $0.defaultValue.isFinite &&
            $0.lowerBound.isFinite &&
            $0.upperBound.isFinite
        })
        XCTAssertNoThrow(try ScientificCanonicalJSON.encode(bytecode))
    }

    func testNeuroMLSegmentGroupIncludesRemainExecutable() throws {
        let xml = Data(
            """
            <neuroml id="fixture">
              <include href="common.xml"/>
              <cell id="cell">
                <segment id="0">
                  <distal x="0" y="0" z="0" diameter="1"/>
                </segment>
                <segmentGroup id="base">
                  <member segment="0"/>
                </segmentGroup>
                <segmentGroup id="all">
                  <include segmentGroup="base"/>
                </segmentGroup>
              </cell>
            </neuroml>
            """.utf8
        )
        let document = try NeuroMLImporter.parse(data: xml)
        XCTAssertEqual(document.includes, ["common.xml"])
        let cell = try XCTUnwrap(document.cells.first)
        XCTAssertEqual(try cell.expandedMembers(of: "all"), [0])
    }

    func testBuiltInAdapterRegistryIsDeterministicAndComplete() async throws {
        let adapters = try BuiltInBiologicalDatasetAdapters.productionDefaults()
        let registry = try BuiltInBiologicalDatasetAdapters.registry()
        let adapterIDs = adapters.map(\.adapterID).sorted()
        XCTAssertEqual(adapterIDs, [
            "allen-abc-s3-v1",
            "dandi-rest-v1",
            "h01-release-index-v1",
            "microns-cave-v3",
            "modeldb-rest-v1"
        ])
        let registeredIDs = await registry.adapterIDs()
        XCTAssertEqual(registeredIDs, adapterIDs)
        for adapter in adapters {
            XCTAssertEqual(adapter.capabilities.source, adapter.source)
            XCTAssertNoThrow(try adapter.capabilities.validated())
        }
    }
}
