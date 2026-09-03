import Foundation
import NumiTissueIO

public struct ModelDBDatasetAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var apiBaseURL: String
    public var metadataDecoderID: String

    public init(
        adapterID: String = "modeldb-rest-v1",
        apiBaseURL: String = "https://modeldb.science/api/v1",
        metadataDecoderID: String = "modeldb-model-v1"
    ) {
        self.adapterID = adapterID
        self.apiBaseURL = apiBaseURL
        self.metadataDecoderID = metadataDecoderID
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !metadataDecoderID.isEmpty,
              let components = URLComponents(string: apiBaseURL),
              components.scheme == "https",
              components.host?.isEmpty == false else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        return self
    }
}

public struct ModelDBDatasetAdapter: BiologicalDatasetAdapter {
    public let configuration: ModelDBDatasetAdapterConfiguration

    public init(
        configuration: ModelDBDatasetAdapterConfiguration =
            ModelDBDatasetAdapterConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var adapterID: String { configuration.adapterID }
    public var source: BiologicalDataSource { .modelDB }
    public var capabilities: BiologicalDatasetAdapterCapabilities {
        BiologicalDatasetAdapterCapabilities(
            source: source,
            modalities: [
                .electrophysiology,
                .ionChannel,
                .molecularNetwork,
                .morphology,
                .physiology,
                .simulationModel,
                .synapse
            ],
            representations: [
                .annotations,
                .cellMetadata,
                .electrophysiologyFeatures,
                .morphologySkeleton
            ],
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
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let identifiers = selection.entityIdentifiers.isEmpty
            ? [dataset.datasetID]
            : selection.entityIdentifiers.sorted()
        let requests: [DatasetQueryRequest]
        if identifiers.count == 1,
           ["catalog", "all", "*"].contains(identifiers[0].lowercased()) {
            requests = [try catalogRequest(planID: planID, selection: selection)]
        } else {
            requests = try identifiers.enumerated().map { ordinal, value in
                guard let accession = Int(value), accession > 0 else {
                    throw BiologicalDatasetAdapterError.invalidDatasetIdentifier(value)
                }
                return DatasetQueryRequest(
                    id: BiologicalAdapterUtilities.requestID(
                        planID: planID,
                        role: "modeldb-model",
                        ordinal: ordinal
                    ),
                    locator: .modelDB(
                        accession: accession,
                        path: selection.metadataPredicates["modeldb.path"]
                    ),
                    headers: ["Accept": "application/json"],
                    decoderID: configuration.metadataDecoderID,
                    expectedEncoding: .json,
                    expectedMediaType: "application/json",
                    priority: .high,
                    cachePolicy: dataset.stability == .mutableLatest ? .revalidate : .immutable,
                    metadata: BiologicalAdapterUtilities.canonicalMetadata(
                        source: source,
                        selection: selection,
                        additional: [
                            "numitissue.discovery-role": "model-record",
                            "modeldb.accession": String(accession)
                        ]
                    )
                )
            }
        }
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: requests,
            metadata: [
                "numitissue.adapter.family": "modeldb",
                "numitissue.adapter.version": "1"
            ]
        ).validated()
    }

    private func catalogRequest(
        planID: String,
        selection: DatasetSelection
    ) throws -> DatasetQueryRequest {
        guard var components = URLComponents(string: configuration.apiBaseURL) else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + components.path + "/models"
        var queryItems: [URLQueryItem] = []
        for key in selection.metadataPredicates.keys.sorted()
            where !key.hasPrefix("modeldb.") {
            queryItems.append(URLQueryItem(
                name: key,
                value: selection.metadataPredicates[key]
            ))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url?.absoluteString else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        return DatasetQueryRequest(
            id: BiologicalAdapterUtilities.requestID(
                planID: planID,
                role: "modeldb-catalog"
            ),
            locator: .https(url: url),
            headers: ["Accept": "application/json"],
            decoderID: "modeldb-catalog-v1",
            expectedEncoding: .json,
            expectedMediaType: "application/json",
            priority: .normal,
            cachePolicy: .revalidate,
            metadata: BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: ["numitissue.discovery-role": "model-catalog"]
            )
        )
    }
}
