import Foundation
import NumiTissueIO

public struct H01DatasetAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var defaultIndexURL: String
    public var decoderID: String

    public init(
        adapterID: String = "h01-release-index-v1",
        defaultIndexURL: String = "https://h01-release.storage.googleapis.com/data.html",
        decoderID: String = "h01-release-index-v1"
    ) {
        self.adapterID = adapterID
        self.defaultIndexURL = defaultIndexURL
        self.decoderID = decoderID
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !decoderID.isEmpty,
              let components = URLComponents(string: defaultIndexURL),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        return self
    }
}

public struct H01DatasetAdapter: BiologicalDatasetAdapter {
    public let configuration: H01DatasetAdapterConfiguration

    public init(
        configuration: H01DatasetAdapterConfiguration = H01DatasetAdapterConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var adapterID: String { configuration.adapterID }
    public var source: BiologicalDataSource { .h01 }
    public var capabilities: BiologicalDatasetAdapterCapabilities {
        BiologicalDatasetAdapterCapabilities(
            source: source,
            modalities: [
                .anatomy,
                .connectome,
                .glia,
                .microscopy,
                .morphology,
                .synapse,
                .ultrastructure,
                .vasculature
            ],
            representations: [
                .annotations,
                .cellMetadata,
                .connectivityEdges,
                .morphologySkeleton,
                .segmentationLabels,
                .spatialCoordinates,
                .surfaceMesh,
                .synapseLocations,
                .tissueImage,
                .vasculatureGraph,
                .voxelField
            ],
            supportsSpatialSelection: true,
            supportsEntitySelection: true
        )
    }

    public func makeQueryPlan(
        dataset sourceDataset: DatasetVersion,
        selection sourceSelection: DatasetSelection
    ) throws -> DatasetQueryPlan {
        let (dataset, selection) = try BiologicalAdapterUtilities.validate(
            adapterID: adapterID,
            source: source,
            capabilities: capabilities,
            dataset: sourceDataset,
            selection: sourceSelection
        )
        let url = dataset.sourceURI ?? configuration.defaultIndexURL
        guard let components = URLComponents(string: url),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            throw BiologicalDatasetAdapterError.missingDatasetSourceURI(
                dataset.stableReference
            )
        }
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let request = DatasetQueryRequest(
            id: BiologicalAdapterUtilities.requestID(
                planID: planID,
                role: "h01-index"
            ),
            locator: .https(url: url),
            headers: ["Accept": "text/html,application/json;q=0.9"],
            decoderID: configuration.decoderID,
            expectedEncoding: .opaque,
            priority: .critical,
            cachePolicy: dataset.stability == .immutableRelease ? .immutable : .revalidate,
            metadata: BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: ["numitissue.discovery-role": "release-index"]
            )
        )
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: [request],
            metadata: [
                "numitissue.adapter.family": "h01",
                "numitissue.adapter.version": "1"
            ]
        ).validated()
    }
}

public struct SourceURIDatasetAdapter: BiologicalDatasetAdapter {
    public var adapterID: String
    public var source: BiologicalDataSource
    public var capabilities: BiologicalDatasetAdapterCapabilities
    public var decoderID: String
    public var expectedEncoding: DataStorageEncoding
    public var expectedMediaType: String?

    public init(
        adapterID: String,
        source: BiologicalDataSource,
        capabilities: BiologicalDatasetAdapterCapabilities,
        decoderID: String,
        expectedEncoding: DataStorageEncoding = .json,
        expectedMediaType: String? = "application/json"
    ) throws {
        guard !adapterID.isEmpty,
              !decoderID.isEmpty,
              capabilities.source == source else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        self.adapterID = adapterID
        self.source = source
        self.capabilities = try capabilities.validated()
        self.decoderID = decoderID
        self.expectedEncoding = expectedEncoding
        self.expectedMediaType = expectedMediaType
    }

    public func makeQueryPlan(
        dataset sourceDataset: DatasetVersion,
        selection sourceSelection: DatasetSelection
    ) throws -> DatasetQueryPlan {
        let (dataset, selection) = try BiologicalAdapterUtilities.validate(
            adapterID: adapterID,
            source: source,
            capabilities: capabilities,
            dataset: sourceDataset,
            selection: sourceSelection
        )
        guard let url = dataset.sourceURI else {
            throw BiologicalDatasetAdapterError.missingDatasetSourceURI(
                dataset.stableReference
            )
        }
        _ = try DataLocator.https(url: url).validated()
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: [
                DatasetQueryRequest(
                    id: BiologicalAdapterUtilities.requestID(
                        planID: planID,
                        role: "source-index"
                    ),
                    locator: .https(url: url),
                    decoderID: decoderID,
                    expectedEncoding: expectedEncoding,
                    expectedMediaType: expectedMediaType,
                    priority: .critical,
                    cachePolicy: dataset.stability == .immutableRelease
                        ? .immutable
                        : .revalidate,
                    metadata: BiologicalAdapterUtilities.canonicalMetadata(
                        source: source,
                        selection: selection,
                        additional: ["numitissue.discovery-role": "source-index"]
                    )
                )
            ],
            metadata: [
                "numitissue.adapter.family": "source-uri",
                "numitissue.adapter.version": "1"
            ]
        ).validated()
    }
}

public enum BuiltInBiologicalDatasetAdapters {
    public static func productionDefaults() throws -> [any BiologicalDatasetAdapter] {
        [
            try AllenBrainCellAtlasAdapter(),
            try DANDIDatasetAdapter(),
            try ModelDBDatasetAdapter(),
            try MICrONSCAVEAdapter(),
            try H01DatasetAdapter()
        ]
    }

    public static func registry() throws -> BiologicalDatasetAdapterRegistry {
        try BiologicalDatasetAdapterRegistry(adapters: productionDefaults())
    }
}
