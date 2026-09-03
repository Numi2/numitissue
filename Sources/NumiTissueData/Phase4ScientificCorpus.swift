import Foundation
import NumiTissueIO

public enum NumiTissuePhase4Corpus {
    public static func conformanceFixtureManifest() throws -> ScientificCorpusManifest {
        let conformance = try NumiTissueStandardConformance.phase4Baseline.sha256()
        let license = DatasetLicense(
            identifier: "CC0-1.0",
            name: "CC0 1.0 Universal",
            licenseURI: "https://creativecommons.org/publicdomain/zero/1.0/",
            attributionRequired: false,
            redistributionAllowed: true,
            commercialUseAllowed: true,
            shareAlikeRequired: false,
            notice: "Applies only to synthetic files in ValidationCases/Cases/Phase4."
        )
        let paths = [
            "ValidationCases/Cases/Phase4/minimal.swc",
            "ValidationCases/Cases/Phase4/minimal-neuroml.xml",
            "ValidationCases/Cases/Phase4/minimal-lems.xml",
            "ValidationCases/Cases/Phase4/minimal-sbml.xml",
            "ValidationCases/Cases/Phase4/minimal.mod",
            "ValidationCases/Cases/Phase4/sonata-config.json",
            "ValidationCases/Cases/Phase4/node_types.csv",
            "ValidationCases/Cases/Phase4/edge_types.csv",
            "ValidationCases/Cases/Phase4/LICENSE-CC0-1.0.txt"
        ]
        let source = ScientificSourcePin(
            dataset: DatasetVersion(
                source: .custom,
                datasetID: "numitissue-phase4-conformance-fixtures",
                release: "1",
                materializationVersion: "repository",
                sourceURI: "https://github.com/Numi2/numitissue/tree/main/ValidationCases/Cases/Phase4",
                stability: .localDerived,
                license: license,
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
            assets: [
                asset(
                    id: "swc",
                    path: paths[0],
                    role: "morphology",
                    mediaType: "text/plain",
                    encoding: .swc,
                    bytes: 117,
                    sha256: "c48ddf6756de428067595103ba6837135d8e8ae0282f2ea29ad5566cbba85f84",
                    decoder: nativeDecoder("swc-v1", version: "1", schema: "numitissue.swc.v1")
                ),
                asset(
                    id: "neuroml",
                    path: paths[1],
                    role: "cell-model",
                    mediaType: "application/xml",
                    encoding: .xml,
                    bytes: 1_197,
                    sha256: "59082888e5f2dc613cc3d70533238e9a890ef80c941c0418f4852b3c361f9025",
                    decoder: nativeDecoder("neuroml", version: "2.3", schema: "numitissue.neuroml.document.v1")
                ),
                asset(
                    id: "lems",
                    path: paths[2],
                    role: "component-model",
                    mediaType: "application/xml",
                    encoding: .xml,
                    bytes: 790,
                    sha256: "d98d2afaafc5afc709110b924de91350f530117a52f384a72959e9f629055d01",
                    decoder: nativeDecoder("lems", version: "0.7.6", schema: "numitissue.lems.document.v1")
                ),
                asset(
                    id: "sbml",
                    path: paths[3],
                    role: "reaction-network",
                    mediaType: "application/sbml+xml",
                    encoding: .xml,
                    bytes: 974,
                    sha256: "0fd9b1c13dc567e146a9dddd35c453b67ca2c160317f2b874ea44087db101772",
                    decoder: nativeDecoder("sbml-core", version: "l3v2r2", schema: "numitissue.molecular-ir.v1")
                ),
                asset(
                    id: "nmodl",
                    path: paths[4],
                    role: "mechanism",
                    mediaType: "text/x-nmodl",
                    encoding: .opaque,
                    bytes: 204,
                    sha256: "8ab80d8ab3041adcfa9530599d83834741874d8b885497d44131db76e6cd9301",
                    decoder: nativeDecoder("nmodl-restricted", version: "1", schema: "numitissue.mechanism-bytecode.v1")
                ),
                asset(
                    id: "sonata-config",
                    path: paths[5],
                    role: "circuit-configuration",
                    mediaType: "application/json",
                    encoding: .json,
                    bytes: 396,
                    sha256: "00c013c44bc2995259ffd6ab2b4821656b8c7e8e33fb6396c6ec5c0f7c20ab51",
                    decoder: nativeDecoder("sonata-configuration", version: "1", schema: "numitissue.sonata.configuration.v1")
                ),
                asset(
                    id: "sonata-node-types",
                    path: paths[6],
                    role: "node-types",
                    mediaType: "text/csv",
                    encoding: .csv,
                    bytes: 92,
                    sha256: "c63a802299d533e534d06887589fa86686b1453e1994d6cef0d05110a845955c",
                    decoder: nativeDecoder("sonata-node-types-csv", version: "1", schema: "numitissue.sonata.node-types.v1")
                ),
                asset(
                    id: "sonata-edge-types",
                    path: paths[7],
                    role: "edge-types",
                    mediaType: "text/csv",
                    encoding: .csv,
                    bytes: 74,
                    sha256: "4d4bbb9d48b898b9e2e9e76244ea052596af0b81d4a0ef543e17688e281619fd",
                    decoder: nativeDecoder("sonata-edge-types-csv", version: "1", schema: "numitissue.sonata.edge-types.v1")
                ),
                asset(
                    id: "fixture-license",
                    path: paths[8],
                    role: "license",
                    mediaType: "text/plain",
                    encoding: .opaque,
                    bytes: 402,
                    sha256: "fe5163ff415295bdca68179ec7314d9bb989eaaf5fb6520a4ffd3a230561340f",
                    decoder: nativeDecoder("identity-text", version: "1", schema: "text/plain")
                )
            ],
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
            conformanceMatrixSHA256: conformance,
            entries: [entry],
            metadata: [
                "authority": "NumiTissueData",
                "fixtureRoot": "ValidationCases/Cases/Phase4"
            ]
        ).validated(policy: .materialized)
    }

    /// Source selections for the next public validation corpus. Entries intentionally remain
    /// source-pinned: asset content hashes, licenses, feature contracts, and tolerances must be
    /// populated from a completed materialization before publication.
    public static func candidateCatalog() throws -> ScientificCorpusManifest {
        let conformance = try NumiTissueStandardConformance.phase4Baseline.sha256()
        return try ScientificCorpusManifest(
            corpusID: "numitissue.phase4.candidates",
            title: "NumiTissue Phase 4 public corpus candidates",
            version: "2026.09",
            conformanceMatrixSHA256: conformance,
            entries: [
                dandiEntry(
                    id: "dandi.000003.yuta-mouse20",
                    title: "Published extracellular electrophysiology example",
                    dandiset: "000003",
                    version: "0.260218.2052",
                    path: "sub-YutaMouse20/sub-YutaMouse20_ses-YutaMouse20-140327_behavior+ecephys.nwb",
                    subject: "YutaMouse20",
                    kind: .extracellularRecording
                ),
                dandiEntry(
                    id: "dandi.000023.subject-541516760",
                    title: "Published NWB subject selection",
                    dandiset: "000023",
                    version: "0.210914.1900",
                    path: "sub-541516760",
                    subject: "541516760",
                    kind: .extracellularRecording
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
                    path: "specification.md",
                    kind: .morphologyConnectivity
                )
            ],
            metadata: [
                "status": "source-pinned-not-materialized",
                "publicationRule": "materialize, resolve license, hash bytes, declare features and tolerances, then validate"
            ]
        ).validated(policy: .development)
    }

    private static func dandiEntry(
        id: String,
        title: String,
        dandiset: String,
        version: String,
        path: String,
        subject: String,
        kind: ScientificCorpusEntryKind
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
        let decoder = ScientificDecoderPin(
            identifier: "nwb-pynwb",
            version: "1",
            path: .sidecar,
            outputSchema: "numitissue.nwb-extract.v1",
            deterministic: true,
            configurationSHA256: digest("nwb-default-bounded-v1"),
            sidecarToolchain: NumiTissuePhase4Sidecars.nwb
        )
        return ScientificCorpusEntry(
            id: id,
            title: title,
            kind: kind,
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
                    decoder: decoder
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
        let rawURL = "https://raw.githubusercontent.com/\(repository)/\(commit)/\(path)"
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
                    locator: .https(url: rawURL),
                    mediaType: path.hasSuffix(".md") ? "text/markdown" : "application/xml",
                    encoding: path.hasSuffix(".md") ? .opaque : .xml,
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

    private static func asset(
        id: String,
        path: String,
        role: String,
        mediaType: String,
        encoding: DataStorageEncoding,
        bytes: UInt64,
        sha256: String,
        decoder: ScientificDecoderPin
    ) -> ScientificAssetPin {
        ScientificAssetPin(
            id: id,
            role: role,
            relativePath: path,
            locator: .local(path: path),
            mediaType: mediaType,
            encoding: encoding,
            byteCount: bytes,
            sha256: try? ScientificSHA256Digest(hexadecimal: sha256),
            decoder: decoder
        )
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
