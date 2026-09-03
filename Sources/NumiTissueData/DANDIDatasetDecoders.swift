import Foundation
import NumiTissueIO

public struct DANDIDecoderConfiguration: Sendable, Equatable {
    public var apiBaseURL: String
    public var pageDecoderID: String
    public var assetInfoDecoderID: String
    public var maximumPages: Int
    public var preferredContentHostSuffixes: [String]
    public var JSONLimits: ScientificJSONLimits

    public init(
        apiBaseURL: String = "https://api.dandiarchive.org/api",
        pageDecoderID: String = "dandi-assets-page-v1",
        assetInfoDecoderID: String = "dandi-asset-info-v1",
        maximumPages: Int = 10_000,
        preferredContentHostSuffixes: [String] = [
            "amazonaws.com",
            "storage.googleapis.com"
        ],
        JSONLimits: ScientificJSONLimits = ScientificJSONLimits()
    ) {
        self.apiBaseURL = apiBaseURL
        self.pageDecoderID = pageDecoderID
        self.assetInfoDecoderID = assetInfoDecoderID
        self.maximumPages = maximumPages
        self.preferredContentHostSuffixes = preferredContentHostSuffixes
        self.JSONLimits = JSONLimits
    }

    public func validated() throws -> Self {
        _ = try BiologicalNativeURLBuilder.baseComponents(apiBaseURL)
        _ = try JSONLimits.validated()
        guard !pageDecoderID.isEmpty,
              !assetInfoDecoderID.isEmpty,
              maximumPages > 0,
              maximumPages <= 1_000_000,
              preferredContentHostSuffixes.allSatisfy({ !$0.isEmpty }) else {
            throw DANDIDecoderError.invalidConfiguration
        }
        return self
    }
}

public struct DANDIAssetPageDecoder: DatasetResponseDecoder {
    public let configuration: DANDIDecoderConfiguration

    public init(
        configuration: DANDIDecoderConfiguration = DANDIDecoderConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var id: String { configuration.pageDecoderID }

    public func decode(
        _ sourceInput: DatasetDecodeInput
    ) throws -> DatasetDecodedFragment {
        let input = try sourceInput.validated()
        guard input.context.dataset.source == .dandi else {
            throw DANDIDecoderError.sourceMismatch
        }
        let root = try ScientificJSONParser.decode(
            input.response.data,
            limits: configuration.JSONLimits
        )
        guard let object = root.objectValue,
              let rows = object["results"]?.arrayValue else {
            throw DANDIDecoderError.invalidPage
        }
        let currentPage = Int(input.request.metadata["dandi.page"] ?? "1") ?? 1
        guard currentPage > 0, currentPage <= configuration.maximumPages else {
            throw DatasetDecoderSupportError.pageBudgetExceeded(
                configuration.maximumPages
            )
        }
        let previouslyDiscovered = UInt64(
            input.request.metadata["dandi.assets-discovered"] ?? "0"
        ) ?? 0
        let (discovered, overflow) = previouslyDiscovered.addingReportingOverflow(
            UInt64(rows.count)
        )
        guard !overflow,
              discovered <= input.context.selection.budget.maximumAssets else {
            throw DatasetDecoderSupportError.assetBudgetExceeded(
                input.context.selection.budget.maximumAssets
            )
        }
        let (dandiset, version) = try datasetCoordinates(input)
        var followUps: [DatasetQueryRequest] = []
        followUps.reserveCapacity(rows.count + 1)
        var seenAssets = Set<String>()

        for (ordinal, row) in rows.enumerated() {
            guard let object = row.objectValue,
                  let assetIdentifier = object["asset_id"]?.stringValue,
                  !assetIdentifier.isEmpty,
                  seenAssets.insert(assetIdentifier).inserted,
                  let path = object["path"]?.stringValue,
                  !path.isEmpty else {
                throw DANDIDecoderError.invalidAssetRow(ordinal)
            }
            let size = object["size"]?.uint64Value
            if let size, size == 0 {
                throw DANDIDecoderError.invalidAssetRow(ordinal)
            }
            let infoURL = try assetInfoURL(
                dandiset: dandiset,
                version: version,
                assetIdentifier: assetIdentifier
            )
            var metadata = input.request.metadata
            metadata["dandi.dandiset"] = dandiset
            metadata["dandi.version"] = version
            metadata["dandi.asset-id"] = assetIdentifier
            metadata["dandi.path"] = path
            metadata["dandi.page"] = String(currentPage)
            if let size { metadata["dandi.size"] = String(size) }
            if let blob = object["blob"]?.stringValue {
                metadata["dandi.blob-id"] = blob
            }
            if let zarr = object["zarr"]?.stringValue {
                metadata["dandi.zarr-id"] = zarr
            }
            if let created = object["created"]?.stringValue {
                metadata["dandi.created"] = created
            }
            if let modified = object["modified"]?.stringValue {
                metadata["dandi.modified"] = modified
            }
            followUps.append(try DatasetQueryRequest(
                id: DatasetDecoderSupport.stableID(
                    prefix: "dandi-info",
                    components: [
                        input.context.acquisitionID,
                        dandiset,
                        version,
                        assetIdentifier
                    ]
                ),
                method: .get,
                locator: .https(url: infoURL),
                headers: ["Accept": "application/ld+json,application/json"],
                decoderID: configuration.assetInfoDecoderID,
                expectedEncoding: .json,
                expectedCompression: .none,
                expectedMediaType: "application/json",
                dependencies: [input.request.id],
                priority: .high,
                optional: false,
                cachePolicy: input.context.dataset.stability == .mutableLatest
                    ? .revalidate
                    : .immutable,
                metadata: metadata
            ).validated())
        }

        if let pagination = try paginationRequest(
            root: root,
            input: input,
            currentPage: currentPage,
            discovered: discovered
        ) {
            followUps.append(pagination)
        }
        let provenance = try DatasetDecoderSupport.provenance(
            input: input,
            decoderID: id,
            outputLabel: "DANDI asset page \(currentPage)",
            outputType: "numitissue:DANDIAssetPage"
        )
        return DatasetDecodedFragment(
            requestID: input.request.id,
            decoderID: id,
            provenance: provenance.graph,
            followUpRequests: followUps.sorted { $0.id < $1.id },
            metadata: [
                "dandi.page": String(currentPage),
                "dandi.page-assets": String(rows.count),
                "dandi.assets-discovered": String(discovered),
                "dandi.has-next-page": object["next"]?.stringValue == nil
                    ? "false"
                    : "true"
            ]
        )
    }
}

private extension DANDIAssetPageDecoder {
    func datasetCoordinates(
        _ input: DatasetDecodeInput
    ) throws -> (String, String) {
        if case .dandi(let dandiset, let version, _) = input.request.locator {
            return (dandiset, version)
        }
        guard let dandiset = input.request.metadata["dandi.dandiset"],
              !dandiset.isEmpty,
              let version = input.request.metadata["dandi.version"],
              !version.isEmpty else {
            throw DANDIDecoderError.missingDatasetCoordinates
        }
        return (dandiset, version)
    }

    func assetInfoURL(
        dandiset: String,
        version: String,
        assetIdentifier: String
    ) throws -> String {
        let source = try BiologicalNativeURLBuilder.url(
            baseURL: configuration.apiBaseURL,
            pathComponents: [
                "dandisets",
                dandiset,
                "versions",
                version,
                "assets",
                assetIdentifier,
                "info"
            ]
        )
        return try trailingSlash(source)
    }

    func paginationRequest(
        root: ScientificJSONValue,
        input: DatasetDecodeInput,
        currentPage: Int,
        discovered: UInt64
    ) throws -> DatasetQueryRequest? {
        guard let next = root["next"]?.stringValue,
              !next.isEmpty else {
            return nil
        }
        guard currentPage < configuration.maximumPages else {
            throw DatasetDecoderSupportError.pageBudgetExceeded(
                configuration.maximumPages
            )
        }
        guard let nextComponents = URLComponents(string: next),
              nextComponents.scheme?.lowercased() == "https",
              let nextHost = nextComponents.host?.lowercased(),
              let baseHost = URLComponents(string: configuration.apiBaseURL)?
                .host?.lowercased(),
              nextHost == baseHost else {
            throw DatasetDecoderSupportError.invalidURL(next)
        }
        var metadata = input.request.metadata
        metadata["dandi.page"] = String(currentPage + 1)
        metadata["dandi.assets-discovered"] = String(discovered)
        return try DatasetQueryRequest(
            id: DatasetDecoderSupport.stableID(
                prefix: "dandi-page",
                components: [input.context.acquisitionID, next]
            ),
            method: .get,
            locator: .https(url: next),
            headers: ["Accept": "application/json"],
            credentialScope: input.request.credentialScope,
            decoderID: id,
            expectedEncoding: .json,
            expectedCompression: .none,
            expectedMediaType: "application/json",
            dependencies: [input.request.id],
            priority: input.request.priority,
            optional: false,
            cachePolicy: input.request.cachePolicy,
            metadata: metadata
        ).validated()
    }

    func trailingSlash(_ source: String) throws -> String {
        guard var components = URLComponents(string: source) else {
            throw DatasetDecoderSupportError.invalidURL(source)
        }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let result = components.url?.absoluteString else {
            throw DatasetDecoderSupportError.invalidURL(source)
        }
        return result
    }
}

public struct DANDIAssetInfoDecoder: DatasetResponseDecoder {
    public let configuration: DANDIDecoderConfiguration

    public init(
        configuration: DANDIDecoderConfiguration = DANDIDecoderConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var id: String { configuration.assetInfoDecoderID }

    public func decode(
        _ sourceInput: DatasetDecodeInput
    ) throws -> DatasetDecodedFragment {
        let input = try sourceInput.validated()
        guard input.context.dataset.source == .dandi else {
            throw DANDIDecoderError.sourceMismatch
        }
        let root = try ScientificJSONParser.decode(
            input.response.data,
            limits: configuration.JSONLimits
        )
        guard let object = root.objectValue else {
            throw DANDIDecoderError.invalidAssetInfo
        }
        let assetIdentifier = object["identifier"]?.stringValue ??
            input.request.metadata["dandi.asset-id"]
        let path = object["path"]?.stringValue ??
            input.request.metadata["dandi.path"]
        guard let assetIdentifier,
              !assetIdentifier.isEmpty,
              let path,
              !path.isEmpty else {
            throw DANDIDecoderError.invalidAssetInfo
        }
        let size = object["contentSize"]?.uint64Value ??
            input.request.metadata["dandi.size"].flatMap(UInt64.init)
        if let size, size == 0 {
            throw DANDIDecoderError.invalidAssetInfo
        }
        guard let contentURL = DatasetDecoderSupport.firstPreferredURL(
            in: object["contentUrl"],
            preferredHostSuffixes: configuration.preferredContentHostSuffixes
        ) else {
            throw DANDIDecoderError.missingContentURL(assetIdentifier)
        }
        let locator = try DatasetDecoderSupport.locator(from: contentURL)
        let declaredMediaType = object["encodingFormat"]?.stringValue
        var storage = ScientificDatasetClassifier.storage(
            path: path,
            declaredMediaType: declaredMediaType
        )
        if declaredMediaType?.lowercased().contains("zarr") == true ||
            input.request.metadata["dandi.zarr-id"] != nil {
            storage = DatasetStorageClassification(
                encoding: .zarr,
                compression: .none,
                mediaType: declaredMediaType ?? "application/x-zarr"
            )
        }
        let classification = ScientificDatasetClassifier.biology(
            path: path,
            storage: storage,
            fallbackModalities: input.context.selection.modalities,
            fallbackRepresentations: input.context.selection.representations
        )
        let selectedModalities = classification.modalities.intersection(
            input.context.selection.modalities
        )
        let modalities = selectedModalities.isEmpty
            ? input.context.selection.modalities
            : selectedModalities
        let selectedRepresentations = classification.representations.intersection(
            input.context.selection.representations
        )
        let representations = selectedRepresentations.isEmpty
            ? input.context.selection.representations
            : selectedRepresentations
        let sha256 = DatasetDecoderSupport.sha256(from: object["digest"])
        var metadata = DatasetDecoderSupport.scalarMetadata(
            from: root,
            prefix: "dandi",
            maximumEntries: 512
        )
        metadata["numitissue.representations"] = representations
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        metadata["dandi.asset-id"] = assetIdentifier
        metadata["dandi.path"] = path
        metadata["dandi.content-url"] = contentURL
        if let dandiset = input.request.metadata["dandi.dandiset"] {
            metadata["dandi.dandiset"] = dandiset
        }
        if let version = input.request.metadata["dandi.version"] {
            metadata["dandi.version"] = version
        }
        let asset = try DataAsset(
            id: "dandi:\(assetIdentifier)",
            dataset: input.context.dataset,
            modalities: modalities,
            locator: locator,
            mediaType: storage.mediaType,
            encoding: storage.encoding,
            compression: storage.compression,
            byteCount: size,
            checksum: sha256?.hexadecimal,
            metadata: metadata
        ).validated()
        let provenance = try DatasetDecoderSupport.provenance(
            input: input,
            decoderID: id,
            outputLabel: "DANDI asset \(path)",
            outputType: "numitissue:DANDIAsset"
        )
        return DatasetDecodedFragment(
            requestID: input.request.id,
            decoderID: id,
            assets: [asset],
            provenance: provenance.graph,
            metadata: [
                "dandi.asset-id": assetIdentifier,
                "dandi.path": path,
                "dandi.storage-encoding": storage.encoding.rawValue,
                "dandi.storage-compression": storage.compression.rawValue
            ]
        )
    }
}

public enum DANDIDecoderError: Error, Sendable, CustomStringConvertible {
    case invalidConfiguration
    case sourceMismatch
    case invalidPage
    case invalidAssetRow(Int)
    case missingDatasetCoordinates
    case invalidAssetInfo
    case missingContentURL(String)

    public var description: String {
        switch self {
        case .invalidConfiguration:
            return "DANDI decoder configuration is invalid."
        case .sourceMismatch:
            return "DANDI decoder received a non-DANDI dataset."
        case .invalidPage:
            return "DANDI asset page is malformed."
        case .invalidAssetRow(let ordinal):
            return "DANDI asset row \(ordinal) is malformed."
        case .missingDatasetCoordinates:
            return "DANDI asset page is missing dandiset and version coordinates."
        case .invalidAssetInfo:
            return "DANDI asset-info response is malformed."
        case .missingContentURL(let asset):
            return "DANDI asset \(asset) has no usable content URL."
        }
    }
}
