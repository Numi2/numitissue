import Foundation
import NumiTissueIO

public struct ManifestAssetSemantics: Codable, Sendable, Equatable {
    public var representations: Set<DatasetRepresentation>
    public var decoderID: String
    public var estimatedDecodedBytes: UInt64?
    public var optional: Bool
    public var completeGeometry: Bool?
    public var restricted: Bool
    public var metadata: [String: String]

    public init(
        representations: Set<DatasetRepresentation>,
        decoderID: String,
        estimatedDecodedBytes: UInt64? = nil,
        optional: Bool = false,
        completeGeometry: Bool? = nil,
        restricted: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.representations = representations
        self.decoderID = decoderID
        self.estimatedDecodedBytes = estimatedDecodedBytes
        self.optional = optional
        self.completeGeometry = completeGeometry
        self.restricted = restricted
        self.metadata = metadata
    }

    public func validated(assetID: String) throws -> Self {
        guard !representations.isEmpty,
              !decoderID.isEmpty,
              estimatedDecodedBytes.map({ $0 > 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw BiologicalDatasetAdapterError.invalidManifestSemantics(assetID)
        }
        return self
    }

    public static func inferred(from asset: DataAsset) -> Self {
        let representations = explicitRepresentations(asset.metadata) ??
            inferredRepresentations(asset)
        return Self(
            representations: representations.isEmpty ? [.annotations] : representations,
            decoderID: asset.metadata["numitissue.decoder"] ?? inferredDecoderID(asset),
            estimatedDecodedBytes: asset.metadata["numitissue.estimated-decoded-bytes"]
                .flatMap(UInt64.init),
            optional: parseBoolean(asset.metadata["numitissue.optional"]) ?? false,
            completeGeometry: parseBoolean(
                asset.metadata["numitissue.complete-geometry"]
            ),
            restricted: parseBoolean(asset.metadata["numitissue.restricted"]) ?? false,
            metadata: [:]
        )
    }

    private static func explicitRepresentations(
        _ metadata: [String: String]
    ) -> Set<DatasetRepresentation>? {
        guard let value = metadata["numitissue.representations"] else { return nil }
        let parsed = value.split(separator: ",").compactMap {
            DatasetRepresentation(
                rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return parsed.isEmpty ? nil : Set(parsed)
    }

    private static func inferredRepresentations(
        _ asset: DataAsset
    ) -> Set<DatasetRepresentation> {
        var result = Set<DatasetRepresentation>()
        switch asset.encoding {
        case .swc:
            result.insert(.morphologySkeleton)
        case .sonata:
            result.formUnion([.cellMetadata, .connectivityEdges])
        case .nwb:
            result.formUnion([
                .cellMetadata,
                .electrophysiologyFeatures,
                .electrophysiologyTraces
            ])
        case .neuroglancerPrecomputed, .n5, .tensorStore:
            result.formUnion([.segmentationLabels, .voxelField])
        case .zarr, .hdf5:
            if asset.modalities.contains(.transcriptomics) ||
                asset.modalities.contains(.spatialTranscriptomics) {
                result.insert(.expressionMatrix)
            }
            if asset.modalities.contains(.microscopy) ||
                asset.modalities.contains(.ultrastructure) {
                result.formUnion([.tissueImage, .voxelField])
            }
            if asset.modalities.contains(.electrophysiology) {
                result.insert(.electrophysiologyTraces)
            }
        case .arrow, .csv, .parquet:
            if asset.modalities.contains(.connectome) ||
                asset.modalities.contains(.synapse) {
                result.formUnion([.connectivityEdges, .synapseLocations])
            }
            if asset.modalities.contains(.spatialTranscriptomics) {
                result.formUnion([.cellMetadata, .spatialCoordinates])
            }
            if asset.modalities.contains(.transcriptomics) {
                result.formUnion([.cellMetadata, .expressionMatrix])
            }
        case .json, .xml:
            result.formUnion([.annotations, .cellMetadata])
        case .opaque:
            break
        }
        if asset.modalities.contains(.morphology) {
            result.insert(.morphologySkeleton)
        }
        if asset.modalities.contains(.vasculature) {
            result.insert(.vasculatureGraph)
        }
        return result
    }

    private static func inferredDecoderID(_ asset: DataAsset) -> String {
        switch asset.encoding {
        case .swc: return "swc-v1"
        case .sonata: return "sonata-v1"
        case .nwb: return "nwb-v2"
        case .neuroglancerPrecomputed: return "neuroglancer-precomputed-v1"
        case .n5: return "n5-v1"
        case .tensorStore: return "tensorstore-spec-v1"
        case .zarr: return "zarr-v2"
        case .hdf5: return "hdf5-v1"
        case .arrow: return "arrow-ipc-v1"
        case .csv: return "delimited-table-v1"
        case .parquet: return "parquet-v1"
        case .json: return "json-document-v1"
        case .xml: return "xml-document-v1"
        case .opaque: return "opaque-asset-v1"
        }
    }

    private static func parseBoolean(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
