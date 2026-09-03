import Foundation
import NumiTissueIO

public struct AllenBrainCellAtlasAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var bucket: String
    public var manifestPathTemplate: String
    public var decoderID: String

    public init(
        adapterID: String = "allen-abc-s3-v1",
        bucket: String = "allen-brain-cell-atlas",
        manifestPathTemplate: String = "releases/{release}/manifest.json",
        decoderID: String = "allen-abc-manifest-v1"
    ) {
        self.adapterID = adapterID
        self.bucket = bucket
        self.manifestPathTemplate = manifestPathTemplate
        self.decoderID = decoderID
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !bucket.isEmpty,
              manifestPathTemplate.contains("{release}"),
              !decoderID.isEmpty else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        _ = try BiologicalRepositoryPath.validateTemplate(manifestPathTemplate)
        return self
    }
}

public struct AllenBrainCellAtlasAdapter: BiologicalDatasetAdapter {
    public let configuration: AllenBrainCellAtlasAdapterConfiguration

    public init(
        configuration: AllenBrainCellAtlasAdapterConfiguration =
            AllenBrainCellAtlasAdapterConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var adapterID: String { configuration.adapterID }
    public var source: BiologicalDataSource { .allenBrainCellAtlas }
    public var capabilities: BiologicalDatasetAdapterCapabilities {
        BiologicalDatasetAdapterCapabilities(
            source: source,
            modalities: [
                .anatomy,
                .cellDensity,
                .spatialTranscriptomics,
                .transcriptomics
            ],
            representations: [
                .annotations,
                .cellMetadata,
                .expressionMatrix,
                .spatialCoordinates,
                .voxelField
            ],
            supportsSpatialSelection: true,
            supportsEntitySelection: true,
            supportsSpecimenSelection: true
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
        let release = try BiologicalRepositoryPath.component(dataset.release)
        let key = configuration.manifestPathTemplate.replacingOccurrences(
            of: "{release}",
            with: release
        )
        _ = try BiologicalRepositoryPath.validateObjectKey(key)
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let request = DatasetQueryRequest(
            id: BiologicalAdapterUtilities.requestID(
                planID: planID,
                role: "allen-manifest"
            ),
            locator: .s3(bucket: configuration.bucket, key: key, versionID: nil),
            headers: ["Accept": "application/json"],
            decoderID: configuration.decoderID,
            expectedEncoding: .json,
            expectedMediaType: "application/json",
            priority: .critical,
            cachePolicy: dataset.stability == .immutableRelease ? .immutable : .revalidate,
            metadata: BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: [
                    "numitissue.discovery-role": "release-manifest",
                    "numitissue.object-store": "s3",
                    "numitissue.object-key": key
                ]
            )
        )
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: [request],
            metadata: [
                "numitissue.adapter.family": "allen-abc",
                "numitissue.adapter.version": "1"
            ]
        ).validated()
    }
}

public struct DANDIDatasetAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var decoderID: String
    public var pageSize: Int
    public var maximumPages: Int

    public init(
        adapterID: String = "dandi-rest-v1",
        decoderID: String = "dandi-assets-page-v1",
        pageSize: Int = 100,
        maximumPages: Int = 10_000
    ) {
        self.adapterID = adapterID
        self.decoderID = decoderID
        self.pageSize = pageSize
        self.maximumPages = maximumPages
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !decoderID.isEmpty,
              pageSize > 0,
              pageSize <= 1_000,
              maximumPages > 0,
              maximumPages <= 1_000_000 else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        return self
    }
}

public struct DANDIDatasetAdapter: BiologicalDatasetAdapter {
    public let configuration: DANDIDatasetAdapterConfiguration

    public init(
        configuration: DANDIDatasetAdapterConfiguration =
            DANDIDatasetAdapterConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var adapterID: String { configuration.adapterID }
    public var source: BiologicalDataSource { .dandi }
    public var capabilities: BiologicalDatasetAdapterCapabilities {
        BiologicalDatasetAdapterCapabilities(
            source: source,
            modalities: [
                .electrophysiology,
                .functionalImaging,
                .microscopy,
                .physiology
            ],
            representations: [
                .annotations,
                .cellMetadata,
                .electrophysiologyFeatures,
                .electrophysiologyTraces,
                .tissueImage
            ],
            supportsTemporalSelection: true,
            supportsEntitySelection: true,
            supportsSpecimenSelection: true,
            supportsPagination: true,
            maximumPageSize: configuration.pageSize
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
        let dandiset = try BiologicalRepositoryPath.component(dataset.datasetID)
        let version = try BiologicalRepositoryPath.component(dataset.release)
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let paths: [String?] = selection.entityIdentifiers.isEmpty
            ? [nil]
            : selection.entityIdentifiers.sorted().map(Optional.some)
        let requests = paths.enumerated().map { ordinal, path in
            DatasetQueryRequest(
                id: BiologicalAdapterUtilities.requestID(
                    planID: planID,
                    role: path == nil ? "dandi-assets" : "dandi-path",
                    ordinal: ordinal
                ),
                locator: .dandi(
                    dandiset: dandiset,
                    version: version,
                    assetPath: path
                ),
                headers: ["Accept": "application/json"],
                decoderID: configuration.decoderID,
                expectedEncoding: .json,
                expectedMediaType: "application/json",
                priority: .high,
                cachePolicy: dataset.stability == .immutableRelease ? .immutable : .revalidate,
                metadata: BiologicalAdapterUtilities.canonicalMetadata(
                    source: source,
                    selection: selection,
                    additional: dandiMetadata(selection: selection, path: path)
                )
            )
        }
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: requests,
            metadata: [
                "numitissue.adapter.family": "dandi",
                "numitissue.adapter.version": "1",
                "numitissue.pagination.page-size": String(configuration.pageSize),
                "numitissue.pagination.maximum-pages": String(configuration.maximumPages)
            ]
        ).validated()
    }

    private func dandiMetadata(
        selection: DatasetSelection,
        path: String?
    ) -> [String: String] {
        var metadata: [String: String] = [
            "numitissue.discovery-role": "asset-page",
            "numitissue.pagination.page-size": String(configuration.pageSize),
            "numitissue.pagination.maximum-pages": String(configuration.maximumPages)
        ]
        if let path { metadata["dandi.path"] = path }
        if let specimens = BiologicalAdapterUtilities.commaSeparated(selection.specimenIDs) {
            metadata["dandi.specimen-ids"] = specimens
        }
        if let start = selection.temporalWindow?.start,
           let seconds = try? start.converted(to: .second).value {
            metadata["dandi.time-start-seconds"] = String(format: "%.17g", seconds)
        }
        if let end = selection.temporalWindow?.end,
           let seconds = try? end.converted(to: .second).value {
            metadata["dandi.time-end-seconds"] = String(format: "%.17g", seconds)
        }
        for key in selection.metadataPredicates.keys.sorted() {
            metadata["dandi.predicate.\(key)"] = selection.metadataPredicates[key]
        }
        return metadata
    }
}

enum BiologicalRepositoryPath {
    static func component(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0") else {
            throw BiologicalDatasetAdapterError.invalidDatasetIdentifier(value)
        }
        return trimmed
    }

    static func validateObjectKey(_ value: String) throws -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw BiologicalDatasetAdapterError.invalidDatasetIdentifier(value)
        }
        return value
    }

    static func validateTemplate(_ value: String) throws -> String {
        let substituted = value.replacingOccurrences(of: "{release}", with: "release")
        return try validateObjectKey(substituted)
    }
}
