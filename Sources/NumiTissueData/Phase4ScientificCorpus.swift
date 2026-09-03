import Foundation
import NumiTissueIO

public enum NumiTissuePhase4Corpus {
    private static let fixtureRoot = "ValidationCases/Cases/Phase4"

    public static func conformanceFixtureManifest() throws -> ScientificCorpusManifest {
        let paths = Fixture.allCases.map { "\(fixtureRoot)/\($0.fileName)" }
        let source = ScientificSourcePin(
            dataset: DatasetVersion(
                source: .custom,
                datasetID: "numitissue-phase4-conformance-fixtures",
                release: "1",
                materializationVersion: "repository",
                sourceURI: "https://github.com/Numi2/numitissue/tree/main/\(fixtureRoot)",
                stability: .localDerived,
                license: DatasetLicense(
                    identifier: "CC0-1.0",
                    name: "CC0 1.0 Universal",
                    licenseURI: "https://creativecommons.org/publicdomain/zero/1.0/",
                    attributionRequired: false,
                    redistributionAllowed: true,
                    commercialUseAllowed: true,
                    shareAlikeRequired: false,
                    notice: "Applies only to synthetic files in \(fixtureRoot)."
                ),
                metadata: [
                    "content": "synthetic-interoperability-fixtures",
                    "scientificMeasurement": "false"
                ]
            ),
            selection: ScientificSelectionPin(
                queryLanguage: "explicit-path-list",
                canonicalQuery: paths.joined(separator: "\n"),
                bounded: true,
                expectedEntityCount: UInt64(paths.count),
                assetPaths: paths
            ),
            upstreamTag: "phase4-fixture-v1",
            sourceSchemaVersion: "1"
        )
        let entry = ScientificCorpusEntry(
            id: "phase4.conformance-fixtures",
            title: "NumiTissue Phase 4 synthetic interchange fixtures",
            kind: .conformanceFixture,
            readiness: .materialized,
            source: source,
            assets: Fixture.allCases.map(\.asset),
            units: [
                ScientificUnitContract(
                    quantity: "morphology-position",
                    sourceUnit: "micrometer",
                    canonicalUnit: "micrometer",
                    multiplier: 1,
                    authority: "SWC and NeuroML source declarations"
                )
            ],
            evidenceCaseIDs: NumiTissueStandardConformance.phase4Baseline.features
                .flatMap(\.evidenceCaseIDs)
                .filter { !$0.hasPrefix("phase4.nwb") }
                .sorted(),
            metadata: [
                "purpose": "parser-lowering-and-round-trip-conformance",
                "measurementData": "false"
            ]
        )
        return try ScientificCorpusManifest(
            corpusID: "numitissue.phase4.conformance",
            title: "NumiTissue Phase 4 conformance corpus",
            version: "1",
            conformanceMatrixSHA256: try NumiTissueStandardConformance
                .phase4Baseline.sha256(),
            entries: [entry],
            metadata: [
                "authority": "NumiTissueData",
                "fixtureRoot": fixtureRoot
            ]
        ).validated(policy: .materialized)
    }

    /// These entries are immutable selections, not publishable evidence. Publication requires
    /// resolving the upstream license, materializing exact bytes, hashing every asset, and adding
    /// feature/tolerance contracts plus executable evidence cases.
    public static func candidateCatalog() throws -> ScientificCorpusManifest {
        let entries = [
            dandiEntry(
                id: "dandi.000003.yuta-mouse20",
                title: "Published extracellular electrophysiology example",
                dandiset: "000003",
                version: "0.260218.2052",
                path: "sub-YutaMouse20/sub-YutaMouse20_ses-YutaMouse20-140327_behavior+ecephys.nwb",
                subject: "YutaMouse20"
            ),
            dandiEntry(
                id: "dandi.000023.subject-541516760",
                title: "Published NWB subject selection",
                dandiset: "000023",
                version: "0.210914.1900",
                path: "sub-541516760",
                subject: "541516760"
            ),
            repositoryEntry(
                id: "standard.neuroml2",
                title: "Pinned NeuroML 2 reference source",
                repository: "NeuroML/NeuroML2",
                commit: "a5f5dadccd23606e683eaa0dd58dd2c3b2a7ed58",
                path: "Schemas/NeuroML2/NeuroML_v2.3.xsd",
                kind: .electrophysiologyModel
            ),
            repositoryEntry(
                id: "standard.sonata",
                title: "Pinned SONATA developer specification",
                repository: "AllenInstitute/sonata",
                commit: "51f247bb58bec6264f5d20d31b25ddf40d5c6eb6",
                path: "docs/SONATA_DEVELOPER_GUIDE.md",
                kind: .networkModel
            ),
            repositoryEntry(
                id: "standard.swc",
                title: "Pinned INCF SWC specification source",
                repository: "INCF/swc-specification",
                commit: "67a18f96db524d03430f15936755a79ce68c23be",
                path: "docs/source/swc.rst",
                kind: .morphologyConnectivity
            )
        ]
        return try ScientificCorpusManifest(
            corpusID: "numitissue.phase4.candidates",
            title: "NumiTissue Phase 4 public corpus candidates",
            version: "2026.09",
            conformanceMatrixSHA256: try NumiTissueStandardConformance
                .phase4Baseline.sha256(),
            entries: entries,
            metadata: [
                "status": "source-pinned-not-materialized",
                "publicationRule": "resolve license, materialize, hash, declare features and tolerances, then validate"
            ]
        ).validated(policy: .development)
    }

    private enum Fixture: String, CaseIterable {
        case swc
        case neuroML
        case lems
        case sbml
        case nmodl
        case sonataConfiguration
        case sonataNodeTypes
        case sonataEdgeTypes
        case license

        var fileName: String {
            switch self {
            case .swc: return "minimal.swc"
            case .neuroML: return "minimal-neuroml.xml"
            case .lems: return "minimal-lems.xml"
            case .sbml: return "minimal-sbml.xml"
            case .nmodl: return "minimal.mod"
            case .sonataConfiguration: return "sonata-config.json"
            case .sonataNodeTypes: return "node_types.csv"
            case .sonataEdgeTypes: return "edge_types.csv"
            case .license: return "LICENSE-CC0-1.0.txt"
            }
        }

        var role: String {
            switch self {
            case .swc: return "morphology"
            case .neuroML: return "cell-model"
            case .lems: return "component-model"
            case .sbml: return "reaction-network"
            case .nmodl: return "mechanism"
            case .sonataConfiguration: return "circuit-configuration"
            case .sonataNodeTypes: return "node-types"
            case .sonataEdgeTypes: return "edge-types"
            case .license: return "license"
            }
        }

        var mediaType: String {
            switch self {
            case .swc, .license: return "text/plain"
            case .neuroML, .lems: return "application/xml"
            case .sbml: return "application/sbml+xml"
            case .nmodl: return "text/x-nmodl"
            case .sonataConfiguration: return "application/json"
            case .sonataNodeTypes, .sonataEdgeTypes: return "text/csv"
            }
        }

        var encoding: DataStorageEncoding {
            switch self {
            case .swc: return .swc
            case .neuroML, .lems, .sbml: return .xml
            case .nmodl, .license: return .opaque
            case .sonataConfiguration: return .json
            case .sonataNodeTypes, .sonataEdgeTypes: return .csv
            }
        }

        var byteCount: UInt64 {
            switch self {
            case .swc: return 117
            case .neuroML: return 1_197
            case .lems: return 792
            case .sbml: return 974
            case .nmodl: return 204
            case .sonataConfiguration: return 396
            case .sonataNodeTypes: return 92
            case .sonataEdgeTypes: return 74
            case .license: return 402
            }
        }

        var sha256: String {
            switch self {
            case .swc:
                return "c48ddf6756de428067595103ba6837135d8e8ae0282f2ea29ad5566cbba85f84"
            case .neuroML:
                return "59082888e5f2dc613cc3d70533238e9a890ef80c941c0418f4852b3c361f9025"
            case .lems:
                return "1c8f7d80282e9b8e1eb44df74e9f70d5dd3080b9a75228ff782eeb95ce498711"
            case .sbml:
                return "0fd9b1c13dc567e146a9dddd35c453b67ca2c160317f2b874ea44087db101772"
            case .nmodl:
                return "8ab80d8ab3041adcfa9530599d83834741874d8b885497d44131db76e6cd9301"
            case .sonataConfiguration:
                return "00c013c44bc2995259ffd6ab2b4821656b8c7e8e33fb6396c6ec5c0f7c20ab51"
            case .sonataNodeTypes:
                return "c63a802299d533e534d06887589fa86686b1453e1994d6cef0d05110a845955c"
            case .sonataEdgeTypes:
                return "4d4bbb9d48b898b9e2e9e76244ea052596af0b81d4a0ef543e17688e281619fd"
            case .license:
                return "fe5163ff415295bdca68179ec7314d9bb989eaaf5fb6520a4ffd3a230561340f"
            }
        }

        var decoder: ScientificDecoderPin {
            switch self {
            case .swc:
                return nativeDecoder("swc-v1", version: "1", schema: "numitissue.swc.v1")
            case .neuroML:
                return nativeDecoder("neuroml", version: "2.3", schema: "numitissue.neuroml.document.v1")
            case .lems:
                return nativeDecoder("lems", version: "0.7.6", schema: "numitissue.lems.document.v1")
            case .sbml:
                return nativeDecoder("sbml-core", version: "l3v2r2", schema: "numitissue.molecular-ir.v1")
            case .nmodl:
                return nativeDecoder("nmodl-restricted", version: "1", schema: "numitissue.mechanism-bytecode.v1")
            case .sonataConfiguration:
                return nativeDecoder("sonata-configuration", version: "1", schema: "numitissue.sonata.configuration.v1")
            case .sonataNodeTypes:
                return nativeDecoder("sonata-node-types-csv", version: "1", schema: "numitissue.sonata.node-types.v1")
            case .sonataEdgeTypes:
                return nativeDecoder("sonata-edge-types-csv", version: "1", schema: "numitissue.sonata.edge-types.v1")
            case .license:
                return nativeDecoder("identity-text", version: "1", schema: "text/plain")
            }
        }

        var asset: ScientificAssetPin {
            let path = "\(fixtureRoot)/\(fileName)"
            return ScientificAssetPin(
                id: rawValue,
                role: role,
                relativePath: path,
                locator: .local(path: path),
                mediaType: mediaType,
                encoding: encoding,
                byteCount: byteCount,
                sha256: try? ScientificSHA256Digest(hexadecimal: sha256),
                decoder: decoder
            )
        }
    }

    private static func dandiEntry(
        id: String,
        title: String,
        dandiset: String,
        version: String,
        path: String,
        subject: String
    ) -> ScientificCorpusEntry {
        let dataset = DatasetVersion(
            source: .dandi,
            datasetID: dandiset,
            release: version,
            sourceURI: "https://dandiarchive.org/dandiset/\(dandiset)/\(version)",
            stability: .immutableRelease,
            license: .unknown,
            metadata: ["publicationState": "published"]
        )
        return ScientificCorpusEntry(
            id: id,
            title: title,
            kind: .extracellularRecording,
            readiness: .sourcePinned,
            source: ScientificSourcePin(
                dataset: dataset,
                selection: ScientificSelectionPin(
                    queryLanguage: "dandi-asset-path",
                    canonicalQuery: "dandi://\(dandiset)/\(version)/\(path)",
                    bounded: true,
                    expectedEntityCount: 1,
                    assetPaths: [path],
                    subjectIDs: [subject]
                ),
                sourceSchemaVersion: "DANDI published version"
            ),
            assets: [
                ScientificAssetPin(
                    id: "nwb",
                    role: "electrophysiology-recording",
                    relativePath: "DANDI/\(dandiset)/\(version)/\(path)",
                    locator: .dandi(
                        dandiset: dandiset,
                        version: version,
                        assetPath: path
                    ),
                    mediaType: "application/x-nwb",
                    encoding: .nwb,
                    decoder: ScientificDecoderPin(
                        identifier: "nwb-pynwb",
                        version: "1",
                        path: .sidecar,
                        outputSchema: "numitissue.nwb-extract.v1",
                        deterministic: true,
                        configurationSHA256: digest("nwb-default-bounded-v1"),
                        sidecarToolchain: NumiTissuePhase4Sidecars.nwb
                    )
                )
            ],
            metadata: [
                "candidateOnly": "true",
                "licenseStatus": "must-be-read-from-published-Dandiset-metadata"
            ]
        )
    }

    private static func repositoryEntry(
        id: String,
        title: String,
        repository: String,
        commit: String,
        path: String,
        kind: ScientificCorpusEntryKind
    ) -> ScientificCorpusEntry {
        let sourceFormat = format(for: path)
        return ScientificCorpusEntry(
            id: id,
            title: title,
            kind: kind,
            readiness: .sourcePinned,
            source: ScientificSourcePin(
                dataset: DatasetVersion(
                    source: .custom,
                    datasetID: repository,
                    release: commit,
                    sourceURI: "https://github.com/\(repository)/tree/\(commit)",
                    stability: .immutableRelease,
                    license: .unknown
                ),
                selection: ScientificSelectionPin(
                    queryLanguage: "git-path",
                    canonicalQuery: "\(commit):\(path)",
                    bounded: true,
                    expectedEntityCount: 1,
                    assetPaths: [path]
                ),
                upstreamCommit: commit,
                sourceSchemaVersion: "git-object"
            ),
            assets: [
                ScientificAssetPin(
                    id: "source",
                    role: "reference-specification",
                    relativePath: "Standards/\(repository)/\(commit)/\(path)",
                    locator: .https(
                        url: "https://raw.githubusercontent.com/\(repository)/\(commit)/\(path)"
                    ),
                    mediaType: sourceFormat.mediaType,
                    encoding: sourceFormat.encoding,
                    decoder: nativeDecoder(
                        "identity-reference-source",
                        version: "1",
                        schema: "source-bytes"
                    )
                )
            ],
            metadata: ["candidateOnly": "true"]
        )
    }

    private static func format(
        for path: String
    ) -> (mediaType: String, encoding: DataStorageEncoding) {
        if path.hasSuffix(".xml") || path.hasSuffix(".xsd") {
            return ("application/xml", .xml)
        }
        if path.hasSuffix(".json") { return ("application/json", .json) }
        if path.hasSuffix(".md") { return ("text/markdown", .opaque) }
        if path.hasSuffix(".rst") { return ("text/x-rst", .opaque) }
        return ("text/plain", .opaque)
    }

    private static func nativeDecoder(
        _ identifier: String,
        version: String,
        schema: String
    ) -> ScientificDecoderPin {
        ScientificDecoderPin(
            identifier: identifier,
            version: version,
            path: .native,
            outputSchema: schema,
            deterministic: true,
            configurationSHA256: digest("\(identifier):\(version):\(schema)")
        )
    }

    private static func digest(_ value: String) -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: Data(value.utf8))
    }
}
