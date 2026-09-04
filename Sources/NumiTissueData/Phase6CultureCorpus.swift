import Foundation
import NumiTissueIO

public struct Phase6DANDIAssetPin: Sendable, Hashable, Codable {
    public var publishedVersion: String
    public var assetPath: String
    public var subjectID: String
    public var byteCount: UInt64
    public var sha256: ScientificSHA256Digest
    public var license: DatasetLicense

    public init(publishedVersion: String, assetPath: String, subjectID: String,
                byteCount: UInt64, sha256: ScientificSHA256Digest,
                license: DatasetLicense) {
        self.publishedVersion = publishedVersion; self.assetPath = assetPath
        self.subjectID = subjectID; self.byteCount = byteCount
        self.sha256 = sha256; self.license = license
    }

    public func validated() throws -> Self {
        guard !publishedVersion.isEmpty,
              publishedVersion.lowercased() != "draft",
              publishedVersion.lowercased() != "latest",
              !assetPath.isEmpty,
              !assetPath.hasPrefix("/"),
              !assetPath.split(separator: "/").contains(".."),
              assetPath.hasSuffix(".nwb"),
              !subjectID.isEmpty,
              byteCount > 0,
              license.identifier != DatasetLicense.unknown.identifier,
              license.identifier != "NOASSERTION" else {
            throw Phase6CultureCorpusError.invalidPin
        }
        return self
    }
}

public enum NumiTissuePhase6CultureCorpus {
    public static let feedbackOrganoidDandiset = "001268"
    public static let feedbackOrganoidPaperDOI = "10.1016/j.iot.2025.101671"

    /// Produces a publishable Phase 4 corpus entry only after the caller supplies an exact
    /// published DANDI version, NWB asset path, byte count, SHA-256 and resolved license.
    /// No draft/latest alias is accepted.
    public static func feedbackOrganoidEntry(
        pin sourcePin: Phase6DANDIAssetPin,
        nwbDecoder: ScientificDecoderPin = ScientificDecoderPin(
            identifier: "nwb-pynwb",
            version: "1",
            path: .sidecar,
            outputSchema: "numitissue.nwb-extract.v1",
            deterministic: true,
            configurationSHA256: ScientificSHA256Digest(data: Data("phase6-organoid-nwb-bounded-v1".utf8)),
            sidecarToolchain: NumiTissuePhase4Sidecars.nwb
        )
    ) throws -> ScientificCorpusEntry {
        let pin = try sourcePin.validated()
        let source = ScientificSourcePin(
            dataset: DatasetVersion(
                source: .dandi,
                datasetID: feedbackOrganoidDandiset,
                release: pin.publishedVersion,
                sourceURI: "https://dandiarchive.org/dandiset/\(feedbackOrganoidDandiset)/\(pin.publishedVersion)",
                stability: .immutableRelease,
                license: pin.license,
                metadata: [
                    "publicationState": "published",
                    "associatedPublicationDOI": feedbackOrganoidPaperDOI
                ]
            ),
            selection: ScientificSelectionPin(
                queryLanguage: "dandi-asset-path",
                canonicalQuery: "dandi://\(feedbackOrganoidDandiset)/\(pin.publishedVersion)/\(pin.assetPath)",
                bounded: true,
                expectedEntityCount: 1,
                assetPaths: [pin.assetPath],
                subjectIDs: [pin.subjectID],
                metadata: ["phase6Role": "neural-culture-heldout-candidate"]
            ),
            sourceSchemaVersion: "DANDI published version"
        )
        let asset = ScientificAssetPin(
            id: "organoid-nwb",
            role: "longitudinal-organoid-electrophysiology",
            relativePath: "DANDI/\(feedbackOrganoidDandiset)/\(pin.publishedVersion)/\(pin.assetPath)",
            locator: .dandi(
                dandiset: feedbackOrganoidDandiset,
                version: pin.publishedVersion,
                assetPath: pin.assetPath
            ),
            mediaType: "application/x-nwb",
            encoding: .nwb,
            byteCount: pin.byteCount,
            sha256: pin.sha256,
            decoder: nwbDecoder,
            metadata: [
                "phase": "6",
                "intendedUse": "recording-feature-and-heldout-validation"
            ]
        )
        let featureConfiguration = ScientificSHA256Digest(
            data: Data("phase6-culture-feature-contract-v1".utf8)
        )
        let entry = ScientificCorpusEntry(
            id: "dandi.001268.phase6-organoid",
            title: "Feedback-driven brain-organoid platform electrophysiology",
            kind: .longitudinalOrganoidDataset,
            readiness: .sourcePinned,
            source: source,
            assets: [asset],
            units: [
                ScientificUnitContract(
                    quantity: "extracellular-potential",
                    sourceUnit: "NWB ElectricalSeries declared unit",
                    canonicalUnit: "volt",
                    multiplier: 1,
                    authority: "NWB conversion/channel_conversion/offset metadata"
                )
            ],
            features: [
                ScientificFeatureContract(
                    identifier: "phase6-culture-network-features",
                    extractor: "CultureFeatureExtractor+CultureEvokedFeatureExtractor",
                    extractorVersion: "1",
                    configurationSHA256: featureConfiguration,
                    outputUnit: nil,
                    aggregation: "per-session then grouped by culture/donor/batch",
                    reference: feedbackOrganoidPaperDOI
                )
            ],
            tolerances: [
                ScientificToleranceContract(
                    identifier: "phase6-heldout-predictive-calibration",
                    metric: "absolute predictive interval coverage error",
                    absolute: 0.10,
                    confidenceLevel: 0.90,
                    minimumSampleCount: 24,
                    notes: "Final thresholds remain preregistered by the Phase 6 qualification evidence."
                )
            ],
            evidenceCaseIDs: [
                "phase6.nwb-recording-features",
                "phase6.heldout-culture-forecast"
            ],
            metadata: [
                "candidateOnlyUntilMaterialized": "true",
                "requiredHoldoutUse": "independent-culture-or-longitudinal",
                "associatedPublicationDOI": feedbackOrganoidPaperDOI
            ]
        )
        return try entry.validated(policy: .publishable)
    }
}

public enum Phase6CultureCorpusError: Error, Sendable, CustomStringConvertible {
    case invalidPin
    public var description: String {
        "Phase 6 DANDI pin must identify a published NWB asset with byte count, SHA-256 and resolved license."
    }
}
