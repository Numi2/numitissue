import Foundation
import NumiTissueIO

public struct DatasetStorageClassification: Codable, Sendable, Equatable {
    public var encoding: DataStorageEncoding
    public var compression: DataCompression
    public var mediaType: String

    public init(
        encoding: DataStorageEncoding,
        compression: DataCompression,
        mediaType: String
    ) {
        self.encoding = encoding
        self.compression = compression
        self.mediaType = mediaType
    }
}

public struct DatasetBiologicalClassification: Codable, Sendable, Equatable {
    public var modalities: Set<BiologicalDataModality>
    public var representations: Set<DatasetRepresentation>

    public init(
        modalities: Set<BiologicalDataModality>,
        representations: Set<DatasetRepresentation>
    ) {
        self.modalities = modalities
        self.representations = representations
    }
}

public enum ScientificDatasetClassifier {
    public static func storage(
        path sourcePath: String,
        declaredMediaType: String? = nil
    ) -> DatasetStorageClassification {
        let path = sourcePath.lowercased()
        let media = declaredMediaType?.split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let result: DatasetStorageClassification
        switch true {
        case path.hasSuffix(".json.zst"), path.hasSuffix(".json.zstd"):
            result = .init(
                encoding: .json,
                compression: .zstd,
                mediaType: "application/json"
            )
        case path.hasSuffix(".parquet.zst"), path.hasSuffix(".parquet.zstd"):
            result = .init(
                encoding: .parquet,
                compression: .zstd,
                mediaType: "application/vnd.apache.parquet"
            )
        case path.hasSuffix(".json.gz"):
            result = .init(
                encoding: .json,
                compression: .gzip,
                mediaType: "application/json"
            )
        case path.hasSuffix(".csv.gz"), path.hasSuffix(".tsv.gz"):
            result = .init(
                encoding: .csv,
                compression: .gzip,
                mediaType: "text/csv"
            )
        case path.hasSuffix(".swc.gz"):
            result = .init(
                encoding: .swc,
                compression: .gzip,
                mediaType: "text/plain"
            )
        case path.hasSuffix(".json"), path.hasSuffix(".jsonl"), path.hasSuffix(".ndjson"):
            result = .init(
                encoding: .json,
                compression: .none,
                mediaType: path.hasSuffix(".json")
                    ? "application/json"
                    : "application/x-ndjson"
            )
        case path.hasSuffix(".csv"), path.hasSuffix(".tsv"):
            result = .init(
                encoding: .csv,
                compression: .none,
                mediaType: path.hasSuffix(".tsv")
                    ? "text/tab-separated-values"
                    : "text/csv"
            )
        case path.hasSuffix(".parquet"), path.hasSuffix(".pq"):
            result = .init(
                encoding: .parquet,
                compression: .none,
                mediaType: "application/vnd.apache.parquet"
            )
        case path.hasSuffix(".arrow"), path.hasSuffix(".feather"):
            result = .init(
                encoding: .arrow,
                compression: .none,
                mediaType: "application/vnd.apache.arrow.file"
            )
        case path.hasSuffix(".nwb"):
            result = .init(
                encoding: .nwb,
                compression: .none,
                mediaType: "application/x-nwb"
            )
        case path.hasSuffix(".h5ad"), path.hasSuffix(".h5"), path.hasSuffix(".hdf5"):
            result = .init(
                encoding: .hdf5,
                compression: .none,
                mediaType: "application/x-hdf5"
            )
        case path.hasSuffix(".swc"):
            result = .init(
                encoding: .swc,
                compression: .none,
                mediaType: "text/plain"
            )
        case path.hasSuffix(".xml"), path.hasSuffix(".nml"),
             path.hasSuffix(".neuroml"), path.hasSuffix(".lems"):
            result = .init(
                encoding: .xml,
                compression: .none,
                mediaType: "application/xml"
            )
        case path.hasSuffix(".sonata"):
            result = .init(
                encoding: .sonata,
                compression: .none,
                mediaType: "application/octet-stream"
            )
        case path.hasSuffix(".zarr"), path.contains(".zarr/"):
            result = .init(
                encoding: .zarr,
                compression: .none,
                mediaType: "application/vnd.zarr"
            )
        case path.hasSuffix(".n5"), path.contains(".n5/"):
            result = .init(
                encoding: .n5,
                compression: .none,
                mediaType: "application/octet-stream"
            )
        case path.hasSuffix(".zip"):
            result = .init(
                encoding: .opaque,
                compression: .zip,
                mediaType: "application/zip"
            )
        case path.hasSuffix(".gz"):
            result = .init(
                encoding: .opaque,
                compression: .gzip,
                mediaType: "application/gzip"
            )
        case path.hasSuffix(".zst"), path.hasSuffix(".zstd"):
            result = .init(
                encoding: .opaque,
                compression: .zstd,
                mediaType: "application/zstd"
            )
        default:
            result = .init(
                encoding: encoding(fromMediaType: media) ?? .opaque,
                compression: .none,
                mediaType: media ?? "application/octet-stream"
            )
        }
        if let media, !media.isEmpty {
            return DatasetStorageClassification(
                encoding: result.encoding == .opaque
                    ? (encoding(fromMediaType: media) ?? .opaque)
                    : result.encoding,
                compression: result.compression,
                mediaType: media
            )
        }
        return result
    }

    public static func biology(
        path sourcePath: String,
        storage: DatasetStorageClassification,
        fallbackModalities: Set<BiologicalDataModality>,
        fallbackRepresentations: Set<DatasetRepresentation>
    ) -> DatasetBiologicalClassification {
        let path = sourcePath.lowercased()
        var modalities = Set<BiologicalDataModality>()
        var representations = Set<DatasetRepresentation>()

        switch storage.encoding {
        case .nwb:
            modalities.formUnion([.electrophysiology, .physiology])
            representations.formUnion([
                .cellMetadata,
                .electrophysiologyFeatures,
                .electrophysiologyTraces
            ])
        case .swc:
            modalities.insert(.morphology)
            representations.insert(.morphologySkeleton)
        case .sonata:
            modalities.formUnion([.connectome, .synapse, .simulationModel])
            representations.formUnion([.cellMetadata, .connectivityEdges])
        case .hdf5:
            if path.hasSuffix(".h5ad") || path.contains("expression") ||
                path.contains("transcript") {
                modalities.insert(
                    path.contains("spatial")
                        ? .spatialTranscriptomics
                        : .transcriptomics
                )
                representations.formUnion([.cellMetadata, .expressionMatrix])
            }
        case .parquet, .arrow, .csv:
            if path.contains("synapse") || path.contains("connect") ||
                path.contains("edge") {
                modalities.formUnion([.connectome, .synapse])
                representations.formUnion([
                    .connectivityEdges,
                    .synapseLocations
                ])
            }
            if path.contains("cell") || path.contains("metadata") ||
                path.contains("annotation") {
                modalities.insert(.anatomy)
                representations.formUnion([.annotations, .cellMetadata])
            }
            if path.contains("expression") || path.contains("transcript") {
                modalities.insert(
                    path.contains("spatial")
                        ? .spatialTranscriptomics
                        : .transcriptomics
                )
                representations.insert(.expressionMatrix)
            }
        case .zarr, .n5, .neuroglancerPrecomputed, .tensorStore:
            if path.contains("seg") || path.contains("label") {
                modalities.formUnion([.anatomy, .ultrastructure])
                representations.insert(.segmentationLabels)
            } else if path.contains("expression") || path.contains("transcript") {
                modalities.insert(.spatialTranscriptomics)
                representations.formUnion([
                    .expressionMatrix,
                    .spatialCoordinates
                ])
            } else {
                modalities.formUnion([.microscopy, .ultrastructure])
                representations.formUnion([.tissueImage, .voxelField])
            }
        case .json, .xml:
            modalities.insert(.anatomy)
            representations.formUnion([.annotations, .cellMetadata])
        case .opaque:
            break
        }

        if path.contains("morpholog") || path.contains("skeleton") {
            modalities.insert(.morphology)
            representations.insert(.morphologySkeleton)
        }
        if path.contains("mesh") || path.hasSuffix(".obj") ||
            path.hasSuffix(".ply") {
            modalities.formUnion([.anatomy, .ultrastructure])
            representations.insert(.surfaceMesh)
        }
        if path.contains("vascul") || path.contains("vessel") {
            modalities.insert(.vasculature)
            representations.insert(.vasculatureGraph)
        }
        if path.contains("glia") || path.contains("astrocy") ||
            path.contains("microglia") || path.contains("oligodend") {
            modalities.insert(.glia)
        }
        if path.contains("image") || path.contains("microscopy") ||
            path.hasSuffix(".tif") || path.hasSuffix(".tiff") ||
            path.hasSuffix(".ome.tif") || path.hasSuffix(".ome.tiff") {
            modalities.insert(.microscopy)
            representations.insert(.tissueImage)
        }
        if path.contains("electrophys") || path.contains("patch") ||
            path.contains("ephys") {
            modalities.insert(.electrophysiology)
            representations.formUnion([
                .electrophysiologyFeatures,
                .electrophysiologyTraces
            ])
        }
        if path.contains("density") {
            modalities.insert(.cellDensity)
            representations.insert(.voxelField)
        }
        if path.contains("coordinate") || path.contains("position") {
            representations.insert(.spatialCoordinates)
        }

        if modalities.isEmpty { modalities = fallbackModalities }
        if representations.isEmpty { representations = fallbackRepresentations }
        return DatasetBiologicalClassification(
            modalities: modalities,
            representations: representations
        )
    }

    private static func encoding(
        fromMediaType mediaType: String?
    ) -> DataStorageEncoding? {
        guard let mediaType else { return nil }
        switch mediaType {
        case "application/json", "application/ld+json", "application/x-ndjson":
            return .json
        case "text/csv", "text/tab-separated-values":
            return .csv
        case "application/vnd.apache.parquet", "application/x-parquet":
            return .parquet
        case "application/vnd.apache.arrow.file", "application/vnd.apache.arrow.stream":
            return .arrow
        case "application/x-hdf5", "application/x-nwb":
            return mediaType == "application/x-nwb" ? .nwb : .hdf5
        case "application/xml", "text/xml":
            return .xml
        case "application/vnd.zarr":
            return .zarr
        default:
            return nil
        }
    }
}

public enum DatasetDecoderSupport {
    public static func stableID(
        prefix: String,
        components: [String]
    ) -> String {
        prefix + "-" + StableTextHash.hexadecimal(
            StableTextHash.fnv1a64(
                components.joined(separator: "\u{1f}")
            )
        )
    }

    public static func locator(from source: String) throws -> DataLocator {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("s3://") {
            let remainder = String(value.dropFirst(5))
            guard let slash = remainder.firstIndex(of: "/"),
                  slash > remainder.startIndex else {
                throw DatasetDecoderSupportError.invalidURL(value)
            }
            return try DataLocator.s3(
                bucket: String(remainder[..<slash]),
                key: String(remainder[remainder.index(after: slash)...]),
                versionID: nil
            ).validated()
        }
        if value.lowercased().hasPrefix("gs://") {
            let remainder = String(value.dropFirst(5))
            guard let slash = remainder.firstIndex(of: "/"),
                  slash > remainder.startIndex else {
                throw DatasetDecoderSupportError.invalidURL(value)
            }
            return try DataLocator.gcs(
                bucket: String(remainder[..<slash]),
                key: String(remainder[remainder.index(after: slash)...]),
                generation: nil
            ).validated()
        }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw DatasetDecoderSupportError.invalidURL(value)
        }
        return try DataLocator.https(url: value).validated()
    }

    public static func firstPreferredURL(
        in value: ScientificJSONValue?,
        preferredHostSuffixes: [String] = []
    ) -> String? {
        guard let value else { return nil }
        var candidates: [String] = []
        collectURLStrings(value, into: &candidates, maximum: 10_000)
        var seen = Set<String>()
        candidates = candidates.filter { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  (trimmed.lowercased().hasPrefix("https://") ||
                    trimmed.lowercased().hasPrefix("s3://") ||
                    trimmed.lowercased().hasPrefix("gs://")),
                  seen.insert(trimmed).inserted else {
                return false
            }
            return true
        }
        if !preferredHostSuffixes.isEmpty,
           let preferred = candidates.first(where: { candidate in
               guard let host = URL(string: candidate)?.host?.lowercased() else {
                   return false
               }
               return preferredHostSuffixes.contains {
                   host.hasSuffix($0.lowercased())
               }
           }) {
            return preferred
        }
        return candidates.first
    }

    public static func sha256(
        from value: ScientificJSONValue?
    ) -> ScientificSHA256Digest? {
        guard let value else { return nil }
        let candidates: [String]
        switch value {
        case .string(let string):
            candidates = [string]
        case .object(let object):
            let preferredKeys = [
                "sha256",
                "sha-256",
                "sha2-256",
                "dandi:sha2-256",
                "checksum"
            ]
            candidates = preferredKeys.compactMap {
                object[$0]?.stringValue
            } + object.keys.sorted().compactMap { object[$0]?.stringValue }
        case .array(let array):
            candidates = array.compactMap(\.stringValue)
        default:
            candidates = []
        }
        for source in candidates {
            var normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in ["sha256:", "sha-256:", "sha2-256:", "dandi:sha2-256:"]
                where normalized.lowercased().hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
            }
            if let digest = try? ScientificSHA256Digest(hexadecimal: normalized) {
                return digest
            }
        }
        return nil
    }

    public static func date(from value: ScientificJSONValue?) -> Date? {
        guard let source = value?.stringValue else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        if let date = parser.date(from: source) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: source)
    }

    public static func scalarMetadata(
        from value: ScientificJSONValue?,
        prefix: String = "",
        maximumEntries: Int = 256,
        maximumDepth: Int = 8
    ) -> [String: String] {
        guard let value, maximumEntries > 0, maximumDepth >= 0 else {
            return [:]
        }
        var result: [String: String] = [:]
        var stack: [(String, ScientificJSONValue, Int)] = [(prefix, value, 0)]
        while let (path, current, depth) = stack.popLast(),
              result.count < maximumEntries {
            switch current {
            case .null:
                break
            case .string(let value):
                if !path.isEmpty { result[path] = value }
            case .boolean(let value):
                if !path.isEmpty { result[path] = value ? "true" : "false" }
            case .signedInteger(let value):
                if !path.isEmpty { result[path] = String(value) }
            case .unsignedInteger(let value):
                if !path.isEmpty { result[path] = String(value) }
            case .number(let value):
                if !path.isEmpty { result[path] = String(format: "%.17g", value) }
            case .array(let values):
                guard depth < maximumDepth else { continue }
                if values.allSatisfy({ $0.stringValue != nil }),
                   values.count <= 128 {
                    if !path.isEmpty {
                        result[path] = values.compactMap(\.stringValue)
                            .joined(separator: ",")
                    }
                } else {
                    for index in values.indices.reversed() {
                        stack.append((
                            joinedMetadataPath(path, String(index)),
                            values[index],
                            depth + 1
                        ))
                    }
                }
            case .object(let object):
                guard depth < maximumDepth else { continue }
                for key in object.keys.sorted().reversed() {
                    if let child = object[key] {
                        stack.append((
                            joinedMetadataPath(path, key),
                            child,
                            depth + 1
                        ))
                    }
                }
            }
        }
        return result
    }

    public static func rows(
        from root: ScientificJSONValue,
        candidateKeys: [String]
    ) -> [ScientificJSONValue] {
        if let values = root.arrayValue { return values }
        guard let object = root.objectValue else { return [] }
        for key in candidateKeys {
            if let values = object[key]?.arrayValue { return values }
        }
        return [root]
    }

    public static func provenance(
        input: DatasetDecodeInput,
        decoderID: String,
        outputLabel: String,
        outputType: String
    ) throws -> DatasetDecodeProvenance {
        let digest = ScientificSHA256Digest(data: input.response.data).hexadecimal
        let outputNodeID = stableID(
            prefix: "prov-decoded",
            components: [
                input.context.acquisitionID,
                input.request.id,
                decoderID,
                digest
            ]
        )
        let activityNodeID = stableID(
            prefix: "prov-decode",
            components: [
                input.context.acquisitionID,
                input.request.id,
                decoderID
            ]
        )
        let sourceNodeID = stableID(
            prefix: "prov-source",
            components: [
                input.context.dataset.stableReference,
                input.response.finalLocator.canonicalDescription,
                digest
            ]
        )
        let agentNodeID = stableID(
            prefix: "prov-agent",
            components: [decoderID]
        )
        let graph = try ProvenanceGraph(
            nodes: [
                ProvenanceNode(
                    id: outputNodeID,
                    kind: .entity,
                    label: outputLabel,
                    type: outputType,
                    timestamp: input.response.receivedAt,
                    datasetReference: input.context.dataset.stableReference,
                    checksum: digest,
                    metadata: ["request-id": input.request.id]
                ),
                ProvenanceNode(
                    id: activityNodeID,
                    kind: .activity,
                    label: "Decode \(input.request.id)",
                    type: "numitissue:DatasetDecode",
                    timestamp: input.response.receivedAt,
                    softwareVersion: "1",
                    metadata: ["decoder-id": decoderID]
                ),
                ProvenanceNode(
                    id: sourceNodeID,
                    kind: .entity,
                    label: input.response.finalLocator.canonicalDescription,
                    type: "numitissue:ExternalDatasetResponse",
                    datasetReference: input.context.dataset.stableReference,
                    checksum: digest,
                    metadata: [
                        "status-code": String(input.response.statusCode),
                        "request-id": input.request.id
                    ]
                ),
                ProvenanceNode(
                    id: agentNodeID,
                    kind: .agent,
                    label: decoderID,
                    type: "numitissue:DatasetResponseDecoder",
                    softwareVersion: "1"
                )
            ],
            edges: [
                ProvenanceEdge(
                    from: outputNodeID,
                    to: activityNodeID,
                    kind: .generatedBy
                ),
                ProvenanceEdge(
                    from: activityNodeID,
                    to: sourceNodeID,
                    kind: .used
                ),
                ProvenanceEdge(
                    from: activityNodeID,
                    to: agentNodeID,
                    kind: .implementedBy
                )
            ]
        ).validated()
        return DatasetDecodeProvenance(
            graph: graph,
            outputNodeID: outputNodeID,
            sourceNodeID: sourceNodeID,
            activityNodeID: activityNodeID,
            agentNodeID: agentNodeID
        )
    }

    private static func collectURLStrings(
        _ value: ScientificJSONValue,
        into result: inout [String],
        maximum: Int
    ) {
        guard result.count < maximum else { return }
        switch value {
        case .string(let string):
            result.append(string)
        case .array(let values):
            for value in values {
                collectURLStrings(value, into: &result, maximum: maximum)
                if result.count >= maximum { break }
            }
        case .object(let object):
            for key in object.keys.sorted() {
                if let value = object[key] {
                    collectURLStrings(value, into: &result, maximum: maximum)
                }
                if result.count >= maximum { break }
            }
        default:
            break
        }
    }

    private static func joinedMetadataPath(
        _ prefix: String,
        _ component: String
    ) -> String {
        let safe = component
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
        return prefix.isEmpty ? safe : prefix + "." + safe
    }
}

public struct DatasetDecodeProvenance: Sendable, Equatable {
    public var graph: ProvenanceGraph
    public var outputNodeID: String
    public var sourceNodeID: String
    public var activityNodeID: String
    public var agentNodeID: String

    public init(
        graph: ProvenanceGraph,
        outputNodeID: String,
        sourceNodeID: String,
        activityNodeID: String,
        agentNodeID: String
    ) {
        self.graph = graph
        self.outputNodeID = outputNodeID
        self.sourceNodeID = sourceNodeID
        self.activityNodeID = activityNodeID
        self.agentNodeID = agentNodeID
    }
}

public enum DatasetDecoderSupportError: Error, Sendable, CustomStringConvertible {
    case invalidURL(String)
    case invalidAssetIdentifier(String)
    case missingField(String)
    case malformedField(String)
    case pageBudgetExceeded(Int)
    case assetBudgetExceeded(UInt64)

    public var description: String {
        switch self {
        case .invalidURL(let value):
            return "Dataset decoder received an invalid URL: \(value)."
        case .invalidAssetIdentifier(let value):
            return "Dataset decoder received an invalid asset identifier: \(value)."
        case .missingField(let path):
            return "Dataset decoder requires field \(path)."
        case .malformedField(let path):
            return "Dataset decoder received malformed field \(path)."
        case .pageBudgetExceeded(let maximum):
            return "Dataset decoder exceeded maximum page count \(maximum)."
        case .assetBudgetExceeded(let maximum):
            return "Dataset decoder exceeded maximum asset count \(maximum)."
        }
    }
}
