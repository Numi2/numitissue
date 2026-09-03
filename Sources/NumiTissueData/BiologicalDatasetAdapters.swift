import Foundation
import NumiTissueIO

public struct BiologicalDatasetAdapterCapabilities: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var source: BiologicalDataSource
    public var modalities: Set<BiologicalDataModality>
    public var representations: Set<DatasetRepresentation>
    public var supportsSpatialSelection: Bool
    public var supportsTemporalSelection: Bool
    public var supportsEntitySelection: Bool
    public var supportsSpecimenSelection: Bool
    public var supportsPagination: Bool
    public var requiresCredentials: Bool
    public var maximumPageSize: Int?

    public init(
        schemaVersion: UInt32 = 1,
        source: BiologicalDataSource,
        modalities: Set<BiologicalDataModality>,
        representations: Set<DatasetRepresentation>,
        supportsSpatialSelection: Bool = false,
        supportsTemporalSelection: Bool = false,
        supportsEntitySelection: Bool = true,
        supportsSpecimenSelection: Bool = false,
        supportsPagination: Bool = false,
        requiresCredentials: Bool = false,
        maximumPageSize: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.modalities = modalities
        self.representations = representations
        self.supportsSpatialSelection = supportsSpatialSelection
        self.supportsTemporalSelection = supportsTemporalSelection
        self.supportsEntitySelection = supportsEntitySelection
        self.supportsSpecimenSelection = supportsSpecimenSelection
        self.supportsPagination = supportsPagination
        self.requiresCredentials = requiresCredentials
        self.maximumPageSize = maximumPageSize
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !modalities.isEmpty,
              !representations.isEmpty,
              maximumPageSize.map({ $0 > 0 && $0 <= 1_000_000 }) ?? true else {
            throw BiologicalDatasetAdapterError.invalidCapabilities(source)
        }
        return self
    }

    public func validate(_ sourceSelection: DatasetSelection) throws {
        let selection = try sourceSelection.validated()
        let unsupportedModalities = selection.modalities.subtracting(modalities)
        guard unsupportedModalities.isEmpty else {
            throw BiologicalDatasetAdapterError.unsupportedModalities(
                source: source,
                values: unsupportedModalities.sorted { $0.rawValue < $1.rawValue }
            )
        }
        let unsupportedRepresentations = selection.representations
            .subtracting(representations)
        guard unsupportedRepresentations.isEmpty else {
            throw BiologicalDatasetAdapterError.unsupportedRepresentations(
                source: source,
                values: unsupportedRepresentations.sorted { $0.rawValue < $1.rawValue }
            )
        }
        if !supportsSpatialSelection, !selection.spatialWindows.isEmpty {
            throw BiologicalDatasetAdapterError.spatialSelectionUnsupported(source)
        }
        if !supportsTemporalSelection, selection.temporalWindow != nil {
            throw BiologicalDatasetAdapterError.temporalSelectionUnsupported(source)
        }
        if !supportsEntitySelection, !selection.entityIdentifiers.isEmpty {
            throw BiologicalDatasetAdapterError.entitySelectionUnsupported(source)
        }
        if !supportsSpecimenSelection, !selection.specimenIDs.isEmpty {
            throw BiologicalDatasetAdapterError.specimenSelectionUnsupported(source)
        }
    }
}

public protocol BiologicalDatasetAdapter: Sendable {
    var adapterID: String { get }
    var source: BiologicalDataSource { get }
    var capabilities: BiologicalDatasetAdapterCapabilities { get }

    func makeQueryPlan(
        dataset: DatasetVersion,
        selection: DatasetSelection
    ) throws -> DatasetQueryPlan
}

public actor BiologicalDatasetAdapterRegistry {
    private var adaptersByID: [String: any BiologicalDatasetAdapter] = [:]
    private var adapterIDsBySource: [BiologicalDataSource: [String]] = [:]

    public init(adapters: [any BiologicalDatasetAdapter] = []) throws {
        for adapter in adapters {
            try Self.validate(adapter)
            guard self.adaptersByID[adapter.adapterID] == nil else {
                throw BiologicalDatasetAdapterError.duplicateAdapter(adapter.adapterID)
            }
            self.adaptersByID[adapter.adapterID] = adapter
            self.adapterIDsBySource[adapter.source, default: []].append(adapter.adapterID)
        }
        for source in self.adapterIDsBySource.keys {
            self.adapterIDsBySource[source]?.sort()
        }
    }

    public func register(
        _ adapter: any BiologicalDatasetAdapter,
        replacingExisting: Bool = false
    ) throws {
        try Self.validate(adapter)
        if let previous = adaptersByID[adapter.adapterID], !replacingExisting {
            throw BiologicalDatasetAdapterError.duplicateAdapter(previous.adapterID)
        }
        if let previous = adaptersByID[adapter.adapterID] {
            adapterIDsBySource[previous.source]?.removeAll {
                $0 == previous.adapterID
            }
        }
        adaptersByID[adapter.adapterID] = adapter
        adapterIDsBySource[adapter.source, default: []].append(adapter.adapterID)
        adapterIDsBySource[adapter.source] = Array(
            Set(adapterIDsBySource[adapter.source] ?? [])
        ).sorted()
    }

    @discardableResult
    public func remove(adapterID: String) -> Bool {
        guard let adapter = adaptersByID.removeValue(forKey: adapterID) else {
            return false
        }
        adapterIDsBySource[adapter.source]?.removeAll { $0 == adapterID }
        return true
    }

    public func adapterIDs(for source: BiologicalDataSource? = nil) -> [String] {
        if let source { return adapterIDsBySource[source] ?? [] }
        return adaptersByID.keys.sorted()
    }

    public func makeQueryPlan(
        adapterID: String,
        dataset: DatasetVersion,
        selection: DatasetSelection
    ) throws -> DatasetQueryPlan {
        guard let adapter = adaptersByID[adapterID] else {
            throw BiologicalDatasetAdapterError.unknownAdapter(adapterID)
        }
        return try adapter.makeQueryPlan(dataset: dataset, selection: selection)
    }

    public func makeQueryPlan(
        source: BiologicalDataSource,
        dataset: DatasetVersion,
        selection: DatasetSelection
    ) throws -> DatasetQueryPlan {
        let candidates = adapterIDsBySource[source] ?? []
        guard candidates.count == 1, let identifier = candidates.first else {
            if candidates.isEmpty {
                throw BiologicalDatasetAdapterError.missingAdapter(source)
            }
            throw BiologicalDatasetAdapterError.ambiguousAdapter(
                source: source,
                adapterIDs: candidates
            )
        }
        return try makeQueryPlan(
            adapterID: identifier,
            dataset: dataset,
            selection: selection
        )
    }

    private static func validate(_ adapter: any BiologicalDatasetAdapter) throws {
        guard !adapter.adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              adapter.capabilities.source == adapter.source else {
            throw BiologicalDatasetAdapterError.invalidAdapter(adapter.adapterID)
        }
        _ = try adapter.capabilities.validated()
    }
}

public enum BiologicalDatasetAdapterError: Error, Sendable, CustomStringConvertible {
    case invalidAdapter(String)
    case invalidCapabilities(BiologicalDataSource)
    case duplicateAdapter(String)
    case unknownAdapter(String)
    case missingAdapter(BiologicalDataSource)
    case ambiguousAdapter(source: BiologicalDataSource, adapterIDs: [String])
    case datasetSourceMismatch(expected: BiologicalDataSource, actual: BiologicalDataSource)
    case unsupportedModalities(
        source: BiologicalDataSource,
        values: [BiologicalDataModality]
    )
    case unsupportedRepresentations(
        source: BiologicalDataSource,
        values: [DatasetRepresentation]
    )
    case spatialSelectionUnsupported(BiologicalDataSource)
    case temporalSelectionUnsupported(BiologicalDataSource)
    case entitySelectionUnsupported(BiologicalDataSource)
    case specimenSelectionUnsupported(BiologicalDataSource)
    case missingDatasetSourceURI(String)
    case invalidDatasetIdentifier(String)
    case invalidMaterializationVersion(String)
    case invalidAdapterConfiguration(String)
    case unboundedQuery(source: BiologicalDataSource, resource: String)
    case emptyManifestSelection(String)
    case invalidManifestSemantics(String)
    case unknownManifestAssets([String])
    case manifestDatasetMismatch(expected: String, actual: String)
    case unknownManifestDependency(assetID: String, dependencyID: String)

    public var description: String {
        switch self {
        case .invalidAdapter(let identifier):
            return "Biological dataset adapter \(identifier) is invalid."
        case .invalidCapabilities(let source):
            return "Biological dataset adapter capabilities for \(source.rawValue) are invalid."
        case .duplicateAdapter(let identifier):
            return "Biological dataset adapter \(identifier) is already registered."
        case .unknownAdapter(let identifier):
            return "Biological dataset adapter \(identifier) is not registered."
        case .missingAdapter(let source):
            return "No biological dataset adapter is registered for \(source.rawValue)."
        case .ambiguousAdapter(let source, let adapterIDs):
            return "Multiple biological dataset adapters are registered for \(source.rawValue): \(adapterIDs.joined(separator: ", "))."
        case .datasetSourceMismatch(let expected, let actual):
            return "Dataset source \(actual.rawValue) does not match adapter source \(expected.rawValue)."
        case .unsupportedModalities(let source, let values):
            return "Dataset source \(source.rawValue) does not support requested modalities: \(values.map(\.rawValue).joined(separator: ", "))."
        case .unsupportedRepresentations(let source, let values):
            return "Dataset source \(source.rawValue) does not support requested representations: \(values.map(\.rawValue).joined(separator: ", "))."
        case .spatialSelectionUnsupported(let source):
            return "Dataset source \(source.rawValue) does not support spatial selection."
        case .temporalSelectionUnsupported(let source):
            return "Dataset source \(source.rawValue) does not support temporal selection."
        case .entitySelectionUnsupported(let source):
            return "Dataset source \(source.rawValue) does not support entity selection."
        case .specimenSelectionUnsupported(let source):
            return "Dataset source \(source.rawValue) does not support specimen selection."
        case .missingDatasetSourceURI(let identifier):
            return "Dataset \(identifier) has no source URI."
        case .invalidDatasetIdentifier(let identifier):
            return "Dataset identifier \(identifier) is invalid for its source adapter."
        case .invalidMaterializationVersion(let value):
            return "Materialization version \(value) is invalid."
        case .invalidAdapterConfiguration(let identifier):
            return "Biological dataset adapter configuration \(identifier) is invalid."
        case .unboundedQuery(let source, let resource):
            return "Dataset source \(source.rawValue) query for \(resource) is unbounded."
        case .emptyManifestSelection(let identifier):
            return "Dataset manifest \(identifier) contains no assets matching the selection."
        case .invalidManifestSemantics(let identifier):
            return "Dataset asset \(identifier) has invalid manifest semantics."
        case .unknownManifestAssets(let identifiers):
            return "Dataset manifest references unknown assets: \(identifiers.joined(separator: ", "))."
        case .manifestDatasetMismatch(let expected, let actual):
            return "Dataset manifest identifies \(expected), but the requested dataset is \(actual)."
        case .unknownManifestDependency(let assetID, let dependencyID):
            return "Dataset asset \(assetID) depends on unselected asset \(dependencyID)."
        }
    }
}

public enum BiologicalAdapterUtilities {
    public static func validate(
        adapterID: String,
        source: BiologicalDataSource,
        capabilities: BiologicalDatasetAdapterCapabilities,
        dataset sourceDataset: DatasetVersion,
        selection sourceSelection: DatasetSelection
    ) throws -> (DatasetVersion, DatasetSelection) {
        guard !adapterID.isEmpty else {
            throw BiologicalDatasetAdapterError.invalidAdapter(adapterID)
        }
        let dataset = try sourceDataset.validated()
        let selection = try sourceSelection.validated()
        guard dataset.source == source else {
            throw BiologicalDatasetAdapterError.datasetSourceMismatch(
                expected: source,
                actual: dataset.source
            )
        }
        try capabilities.validate(selection)
        return (dataset, selection)
    }

    public static func planID(
        adapterID: String,
        dataset: DatasetVersion,
        selection: DatasetSelection
    ) throws -> String {
        let payload = try ScientificCanonicalJSON.encode(selection)
        let digest = ScientificSHA256Digest(data: payload).hexadecimal
        return "\(adapterID):\(dataset.datasetID):\(dataset.release):\(digest.prefix(16))"
    }

    public static func requestID(
        planID: String,
        role: String,
        ordinal: Int = 0
    ) -> String {
        let hash = StableTextHash.fnv1a64("\(planID)|\(role)|\(ordinal)")
        return "\(role)-\(StableTextHash.hexadecimal(hash))"
    }

    public static func canonicalMetadata(
        source: BiologicalDataSource,
        selection: DatasetSelection,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata = additional
        metadata["numitissue.source"] = source.rawValue
        metadata["numitissue.modalities"] = selection.modalities
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        metadata["numitissue.representations"] = selection.representations
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        metadata["numitissue.minimum-confidence"] = String(
            format: "%.17g",
            selection.minimumConfidence
        )
        metadata["numitissue.require-complete-geometry"] =
            selection.requireCompleteGeometry ? "true" : "false"
        metadata["numitissue.include-restricted-assets"] =
            selection.includeRestrictedAssets ? "true" : "false"
        return metadata
    }

    public static func percentEncodedPathComponent(_ value: String) throws -> String {
        let forbidden = CharacterSet(charactersIn: "/?#[]@!$&'()*+,;=:%\n\r\t")
        let allowed = CharacterSet.urlPathAllowed.subtracting(forbidden)
        guard !value.isEmpty,
              let result = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !result.isEmpty else {
            throw BiologicalDatasetAdapterError.invalidDatasetIdentifier(value)
        }
        return result
    }

    public static func commaSeparated(_ values: [String]) -> String? {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return normalized.isEmpty ? nil : normalized.joined(separator: ",")
    }
}
