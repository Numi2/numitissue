import Foundation
import NumiTissueIO

public enum ScientificAssetVerificationStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case verified
    case missing
    case unpinned
    case byteCountMismatch
    case digestMismatch
    case unsafePath
    case ioFailure
}

public struct ScientificAssetVerification: Codable, Sendable, Hashable {
    public var entryID: String
    public var assetID: String
    public var relativePath: String
    public var status: ScientificAssetVerificationStatus
    public var expectedByteCount: UInt64?
    public var actualByteCount: UInt64?
    public var expectedSHA256: ScientificSHA256Digest?
    public var actualSHA256: ScientificSHA256Digest?
    public var message: String

    public init(
        entryID: String,
        assetID: String,
        relativePath: String,
        status: ScientificAssetVerificationStatus,
        expectedByteCount: UInt64?,
        actualByteCount: UInt64?,
        expectedSHA256: ScientificSHA256Digest?,
        actualSHA256: ScientificSHA256Digest?,
        message: String
    ) {
        self.entryID = entryID
        self.assetID = assetID
        self.relativePath = relativePath
        self.status = status
        self.expectedByteCount = expectedByteCount
        self.actualByteCount = actualByteCount
        self.expectedSHA256 = expectedSHA256
        self.actualSHA256 = actualSHA256
        self.message = message
    }

    public var passed: Bool { status == .verified }
}

public struct ScientificCorpusVerificationReport: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var corpusID: String
    public var corpusVersion: String
    public var corpusSHA256: ScientificSHA256Digest
    public var verifiedAt: Date
    public var assets: [ScientificAssetVerification]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        corpusID: String,
        corpusVersion: String,
        corpusSHA256: ScientificSHA256Digest,
        verifiedAt: Date = Date(),
        assets: [ScientificAssetVerification],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.corpusVersion = corpusVersion
        self.corpusSHA256 = corpusSHA256
        self.verifiedAt = verifiedAt
        self.assets = assets
        self.metadata = metadata
    }

    public var passed: Bool {
        !assets.isEmpty && assets.allSatisfy(\.passed)
    }

    public var failures: [ScientificAssetVerification] {
        assets.filter { !$0.passed }
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !corpusID.isEmpty,
              !corpusVersion.isEmpty,
              !assets.isEmpty,
              Set(assets.map { "\($0.entryID):\($0.assetID)" }).count == assets.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusMaterializationError.invalidReport
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public struct ScientificCorpusVerificationConfiguration: Codable, Sendable, Hashable {
    public var digestChunkBytes: Int
    public var maximumAssetBytes: UInt64
    public var maximumTotalBytes: UInt64
    public var stopAtFirstFailure: Bool

    public init(
        digestChunkBytes: Int = 4 * 1_024 * 1_024,
        maximumAssetBytes: UInt64 = 1_099_511_627_776,
        maximumTotalBytes: UInt64 = 17_592_186_044_416,
        stopAtFirstFailure: Bool = false
    ) {
        self.digestChunkBytes = digestChunkBytes
        self.maximumAssetBytes = maximumAssetBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.stopAtFirstFailure = stopAtFirstFailure
    }

    public func validated() throws -> Self {
        guard digestChunkBytes >= 4_096,
              digestChunkBytes <= 256 * 1_024 * 1_024,
              maximumAssetBytes > 0,
              maximumTotalBytes >= maximumAssetBytes else {
            throw ScientificCorpusMaterializationError.invalidConfiguration
        }
        return self
    }
}

public enum ScientificCorpusVerifier {
    public static func verify(
        manifest source: ScientificCorpusManifest,
        root: URL,
        configuration sourceConfiguration: ScientificCorpusVerificationConfiguration = .init()
    ) throws -> ScientificCorpusVerificationReport {
        let configuration = try sourceConfiguration.validated()
        let manifest = try source.validated(policy: .publishable)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var records: [ScientificAssetVerification] = []
        records.reserveCapacity(manifest.entries.reduce(0) { $0 + $1.assets.count })
        var totalBytes: UInt64 = 0

        outer: for entry in manifest.entries.sorted(by: { $0.id < $1.id }) {
            for asset in entry.assets.sorted(by: { $0.id < $1.id }) {
                let record: ScientificAssetVerification
                do {
                    guard let expectedDigest = asset.sha256 else {
                        record = failure(
                            entry: entry,
                            asset: asset,
                            status: .unpinned,
                            message: "Asset has no SHA-256 pin."
                        )
                        records.append(record)
                        if configuration.stopAtFirstFailure { break outer }
                        continue
                    }
                    let candidate = try ScientificCorpusFileSystem.resolve(
                        asset.relativePath,
                        under: canonicalRoot
                    )
                    guard FileManager.default.fileExists(atPath: candidate.path) else {
                        record = failure(
                            entry: entry,
                            asset: asset,
                            status: .missing,
                            message: "Materialized file is missing."
                        )
                        records.append(record)
                        if configuration.stopAtFirstFailure { break outer }
                        continue
                    }
                    let resolved = candidate.resolvingSymlinksInPath()
                    guard contains(resolved, root: canonicalRoot) else {
                        record = failure(
                            entry: entry,
                            asset: asset,
                            status: .unsafePath,
                            message: "Materialized path escapes the corpus root through a symlink."
                        )
                        records.append(record)
                        if configuration.stopAtFirstFailure { break outer }
                        continue
                    }

                    let digest = try ScientificFileDigester.sha256(
                        at: resolved,
                        chunkBytes: configuration.digestChunkBytes,
                        maximumBytes: configuration.maximumAssetBytes
                    )
                    let addition = totalBytes.addingReportingOverflow(digest.byteCount)
                    guard !addition.overflow,
                          addition.partialValue <= configuration.maximumTotalBytes else {
                        throw ScientificCorpusMaterializationError.totalByteLimitExceeded
                    }
                    totalBytes = addition.partialValue

                    if let expectedBytes = asset.byteCount,
                       expectedBytes != digest.byteCount {
                        record = ScientificAssetVerification(
                            entryID: entry.id,
                            assetID: asset.id,
                            relativePath: asset.relativePath,
                            status: .byteCountMismatch,
                            expectedByteCount: expectedBytes,
                            actualByteCount: digest.byteCount,
                            expectedSHA256: expectedDigest,
                            actualSHA256: digest.sha256,
                            message: "Materialized byte count differs from the pin."
                        )
                    } else if expectedDigest != digest.sha256 {
                        record = ScientificAssetVerification(
                            entryID: entry.id,
                            assetID: asset.id,
                            relativePath: asset.relativePath,
                            status: .digestMismatch,
                            expectedByteCount: asset.byteCount,
                            actualByteCount: digest.byteCount,
                            expectedSHA256: expectedDigest,
                            actualSHA256: digest.sha256,
                            message: "Materialized SHA-256 differs from the pin."
                        )
                    } else {
                        record = ScientificAssetVerification(
                            entryID: entry.id,
                            assetID: asset.id,
                            relativePath: asset.relativePath,
                            status: .verified,
                            expectedByteCount: asset.byteCount,
                            actualByteCount: digest.byteCount,
                            expectedSHA256: expectedDigest,
                            actualSHA256: digest.sha256,
                            message: "Materialized bytes match the corpus pin."
                        )
                    }
                } catch let error as ScientificCorpusMaterializationError {
                    throw error
                } catch let error as ScientificCorpusError {
                    record = failure(
                        entry: entry,
                        asset: asset,
                        status: .unsafePath,
                        message: error.description
                    )
                } catch {
                    record = failure(
                        entry: entry,
                        asset: asset,
                        status: .ioFailure,
                        message: String(describing: error)
                    )
                }
                records.append(record)
                if configuration.stopAtFirstFailure, !record.passed { break outer }
            }
        }

        return try ScientificCorpusVerificationReport(
            corpusID: manifest.corpusID,
            corpusVersion: manifest.version,
            corpusSHA256: try manifest.sha256(policy: .publishable),
            assets: records,
            metadata: [
                "root": canonicalRoot.path,
                "verifiedBytes": String(totalBytes),
                "digestAlgorithm": "sha256"
            ]
        ).validated()
    }

    private static func failure(
        entry: ScientificCorpusEntry,
        asset: ScientificAssetPin,
        status: ScientificAssetVerificationStatus,
        message: String
    ) -> ScientificAssetVerification {
        ScientificAssetVerification(
            entryID: entry.id,
            assetID: asset.id,
            relativePath: asset.relativePath,
            status: status,
            expectedByteCount: asset.byteCount,
            actualByteCount: nil,
            expectedSHA256: asset.sha256,
            actualSHA256: nil,
            message: message
        )
    }

    private static func contains(_ file: URL, root: URL) -> Bool {
        file.path == root.path || file.path.hasPrefix(root.path + "/")
    }
}

public enum ScientificCorpusSealer {
    /// Computes local byte identities. Existing pins are never overwritten unless they match the
    /// materialized bytes, preventing an accidental re-pin of a corrupted or substituted asset.
    public static func sealLocalFiles(
        manifest source: ScientificCorpusManifest,
        root: URL,
        configuration sourceConfiguration: ScientificCorpusVerificationConfiguration = .init()
    ) throws -> ScientificCorpusManifest {
        let configuration = try sourceConfiguration.validated()
        var manifest = try source.validated(policy: .development)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var totalBytes: UInt64 = 0

        for entryIndex in manifest.entries.indices {
            for assetIndex in manifest.entries[entryIndex].assets.indices {
                let asset = manifest.entries[entryIndex].assets[assetIndex]
                let candidate = try ScientificCorpusFileSystem.resolve(
                    asset.relativePath,
                    under: canonicalRoot
                )
                guard FileManager.default.fileExists(atPath: candidate.path) else {
                    throw ScientificCorpusMaterializationError.missingFile(
                        asset.relativePath
                    )
                }
                let resolved = candidate.resolvingSymlinksInPath()
                guard resolved.path == canonicalRoot.path ||
                        resolved.path.hasPrefix(canonicalRoot.path + "/") else {
                    throw ScientificCorpusMaterializationError.pathEscapesRoot(
                        asset.relativePath
                    )
                }
                let digest = try ScientificFileDigester.sha256(
                    at: resolved,
                    chunkBytes: configuration.digestChunkBytes,
                    maximumBytes: configuration.maximumAssetBytes
                )
                let addition = totalBytes.addingReportingOverflow(digest.byteCount)
                guard !addition.overflow,
                      addition.partialValue <= configuration.maximumTotalBytes else {
                    throw ScientificCorpusMaterializationError.totalByteLimitExceeded
                }
                totalBytes = addition.partialValue
                if let expected = asset.sha256, expected != digest.sha256 {
                    throw ScientificCorpusMaterializationError.existingDigestMismatch(
                        asset.id
                    )
                }
                if let expected = asset.byteCount, expected != digest.byteCount {
                    throw ScientificCorpusMaterializationError.existingByteCountMismatch(
                        asset.id
                    )
                }
                manifest.entries[entryIndex].assets[assetIndex].sha256 = digest.sha256
                manifest.entries[entryIndex].assets[assetIndex].byteCount = digest.byteCount
            }
            manifest.entries[entryIndex].readiness = .materialized
        }
        manifest.metadata["materializedBytes"] = String(totalBytes)
        manifest.metadata["materializationDigestAlgorithm"] = "sha256"
        return try manifest.validated(policy: .materialized)
    }
}

/// Converts the existing adapter manifest into the stricter corpus vocabulary. The result remains
/// `sourcePinned` until files, scientific features, tolerances, and executable evidence are added.
public enum ScientificCorpusDatasetBridge {
    public static func makeEntry(
        manifest source: DatasetManifest,
        id: String,
        title: String,
        kind: ScientificCorpusEntryKind,
        selection: ScientificSelectionPin,
        evidenceCaseIDs: [String] = [],
        metadata: [String: String] = [:]
    ) throws -> ScientificCorpusEntry {
        let manifest = try source.validated()
        let selection = try selection.validated()
        let assets = try manifest.assets.map { asset in
            let semantics = try ManifestAssetSemantics
                .inferred(from: asset)
                .validated(assetID: asset.id)
            let decoderData = try ScientificCanonicalJSON.encode(semantics)
            let sidecar: ScientificSidecarToolchainPin?
            let path: ScientificDecoderPath
            switch asset.encoding {
            case .nwb:
                sidecar = NumiTissuePhase4Sidecars.nwb
                path = .sidecar
            case .hdf5:
                sidecar = NumiTissuePhase4Sidecars.reference
                path = .sidecar
            default:
                sidecar = nil
                path = .native
            }
            return ScientificAssetPin(
                id: asset.id,
                role: semantics.representations
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ","),
                relativePath: safeRelativePath(for: asset),
                locator: asset.locator,
                mediaType: asset.mediaType,
                encoding: asset.encoding,
                compression: asset.compression,
                byteCount: asset.byteCount,
                sha256: sha256(from: asset.checksum),
                sourceChecksum: asset.checksum,
                decoder: ScientificDecoderPin(
                    identifier: semantics.decoderID,
                    version: "1",
                    path: path,
                    outputSchema: "numitissue.canonical-fragment.v1",
                    deterministic: true,
                    configurationSHA256: ScientificSHA256Digest(data: decoderData),
                    sidecarToolchain: sidecar,
                    metadata: semantics.metadata
                ),
                dependencies: asset.dependencies,
                metadata: asset.metadata
            )
        }
        return try ScientificCorpusEntry(
            id: id,
            title: title,
            kind: kind,
            readiness: .sourcePinned,
            source: ScientificSourcePin(
                dataset: manifest.dataset,
                selection: selection,
                sourceSchemaVersion: String(manifest.schemaVersion),
                metadata: manifest.metadata
            ),
            assets: assets,
            evidenceCaseIDs: evidenceCaseIDs,
            metadata: metadata
        ).validated(policy: .development)
    }

    private static func sha256(
        from checksum: String?
    ) -> ScientificSHA256Digest? {
        guard let checksum else { return nil }
        let normalized = checksum
            .lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .replacingOccurrences(of: "sha2-256:", with: "")
        return try? ScientificSHA256Digest(hexadecimal: normalized)
    }

    private static func safeRelativePath(for asset: DataAsset) -> String {
        let candidate: String
        if let explicit = asset.metadata["numitissue.relative-path"] {
            candidate = explicit
        } else {
            switch asset.locator {
            case .local(let path): candidate = path
            case .https(let value): candidate = URL(string: value)?.path ?? asset.id
            case .s3(_, let key, _): candidate = key
            case .gcs(_, let key, _): candidate = key
            case .dandi(_, _, let path): candidate = path ?? asset.id
            case .modelDB(_, let path): candidate = path ?? asset.id
            case .cave: candidate = asset.id + ".json"
            }
        }
        let stripped = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if ScientificCorpusFileSystem.isSafeRelative(stripped) { return stripped }
        let fallback = asset.id.map { character -> Character in
            character.isLetter || character.isNumber || character == "." ||
                character == "-" || character == "_" ? character : "_"
        }
        return String(fallback) + ".asset"
    }
}

public enum ScientificCorpusMaterializationError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case invalidReport
    case totalByteLimitExceeded
    case missingFile(String)
    case pathEscapesRoot(String)
    case existingDigestMismatch(String)
    case existingByteCountMismatch(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "Scientific corpus verification configuration is invalid."
        case .invalidReport:
            return "Scientific corpus verification report is invalid."
        case .totalByteLimitExceeded:
            return "Scientific corpus verification exceeded its total-byte limit."
        case .missingFile(let path):
            return "Scientific corpus file is missing: \(path)."
        case .pathEscapesRoot(let path):
            return "Scientific corpus file escapes the root: \(path)."
        case .existingDigestMismatch(let asset):
            return "Existing SHA-256 pin does not match materialized asset \(asset)."
        case .existingByteCountMismatch(let asset):
            return "Existing byte-count pin does not match materialized asset \(asset)."
        }
    }
}
