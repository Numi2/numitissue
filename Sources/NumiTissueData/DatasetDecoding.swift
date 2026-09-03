import Foundation

public enum DatasetDecoderDiagnosticSeverity: String, Codable, Sendable, CaseIterable, Hashable {
    case information
    case warning
    case error
}

public struct DatasetDecoderDiagnostic: Codable, Sendable, Equatable {
    public var severity: DatasetDecoderDiagnosticSeverity
    public var code: String
    public var requestID: String
    public var path: String?
    public var message: String
    public var metadata: [String: String]

    public init(
        severity: DatasetDecoderDiagnosticSeverity,
        code: String,
        requestID: String,
        path: String? = nil,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.severity = severity
        self.code = code
        self.requestID = requestID
        self.path = path
        self.message = message
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetDecodingError.invalidDiagnostic(code)
        }
        return self
    }
}

public struct DatasetDecodeContext: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var adapterID: String
    public var acquisitionID: String
    public var dataset: DatasetVersion
    public var selection: DatasetSelection
    public var expansionDepth: Int
    public var acquisitionStartedAt: Date
    public var completedRequestIDs: Set<String>
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        adapterID: String,
        acquisitionID: String,
        dataset: DatasetVersion,
        selection: DatasetSelection,
        expansionDepth: Int,
        acquisitionStartedAt: Date,
        completedRequestIDs: Set<String> = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.adapterID = adapterID
        self.acquisitionID = acquisitionID
        self.dataset = dataset
        self.selection = selection
        self.expansionDepth = expansionDepth
        self.acquisitionStartedAt = acquisitionStartedAt
        self.completedRequestIDs = completedRequestIDs
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw DatasetDecodingError.unsupportedSchema(schemaVersion)
        }
        guard !adapterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !acquisitionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              expansionDepth >= 0,
              expansionDepth <= 64,
              completedRequestIDs.allSatisfy({ !$0.isEmpty }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetDecodingError.invalidContext(acquisitionID)
        }
        _ = try dataset.validated()
        _ = try selection.validated()
        return self
    }
}

public struct DatasetDecodeInput: Sendable, Equatable {
    public var request: DatasetQueryRequest
    public var response: BiologicalDataResponse
    public var context: DatasetDecodeContext

    public init(
        request: DatasetQueryRequest,
        response: BiologicalDataResponse,
        context: DatasetDecodeContext
    ) {
        self.request = request
        self.response = response
        self.context = context
    }

    public func validated() throws -> Self {
        _ = try request.validated()
        _ = try context.validated()
        guard response.requestID == request.id,
              response.isSuccess,
              request.method == .head || !response.data.isEmpty else {
            throw DatasetDecodingError.invalidInput(request.id)
        }
        return self
    }
}

public struct DatasetDecodedFragment: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var requestID: String
    public var decoderID: String
    public var assets: [DataAsset]
    public var partitions: [AssetPartition]
    public var records: [EvidenceRecord]
    public var ontology: OntologyRegistry
    public var provenance: ProvenanceGraph
    public var followUpRequests: [DatasetQueryRequest]
    public var diagnostics: [DatasetDecoderDiagnostic]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        requestID: String,
        decoderID: String,
        assets: [DataAsset] = [],
        partitions: [AssetPartition] = [],
        records: [EvidenceRecord] = [],
        ontology: OntologyRegistry = OntologyRegistry(),
        provenance: ProvenanceGraph = ProvenanceGraph(),
        followUpRequests: [DatasetQueryRequest] = [],
        diagnostics: [DatasetDecoderDiagnostic] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.decoderID = decoderID
        self.assets = assets
        self.partitions = partitions
        self.records = records
        self.ontology = ontology
        self.provenance = provenance
        self.followUpRequests = followUpRequests
        self.diagnostics = diagnostics
        self.metadata = metadata
    }

    public func validated(dataset: DatasetVersion) throws -> Self {
        guard schemaVersion == 1 else {
            throw DatasetDecodingError.unsupportedSchema(schemaVersion)
        }
        guard !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !decoderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(assets.map(\.id)).count == assets.count,
              Set(partitions.map(\.id)).count == partitions.count,
              Set(records.map(\.id)).count == records.count,
              Set(followUpRequests.map(\.id)).count == followUpRequests.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw DatasetDecodingError.invalidFragment(requestID)
        }

        let dataset = try dataset.validated()
        let datasetReference = dataset.stableReference
        _ = try ontology.validated()
        _ = try provenance.validated()

        for asset in assets {
            _ = try asset.validated()
            guard asset.dataset.stableReference == datasetReference else {
                throw DatasetDecodingError.datasetMismatch(asset.id)
            }
        }
        for partition in partitions {
            _ = try partition.validated()
        }
        for record in records {
            _ = try record.validated()
            guard record.source == dataset.source,
                  record.datasetReference == datasetReference else {
                throw DatasetDecodingError.datasetMismatch(record.id)
            }
        }
        for request in followUpRequests {
            _ = try request.validated()
            guard request.id != requestID else {
                throw DatasetDecodingError.selfExpandingRequest(requestID)
            }
        }
        for diagnostic in diagnostics {
            let diagnostic = try diagnostic.validated()
            guard diagnostic.requestID == requestID else {
                throw DatasetDecodingError.diagnosticRequestMismatch(
                    expected: requestID,
                    actual: diagnostic.requestID
                )
            }
        }
        return self
    }
}

public protocol DatasetResponseDecoder: Sendable {
    var id: String { get }
    func decode(_ input: DatasetDecodeInput) throws -> DatasetDecodedFragment
}

public struct EmptyDatasetResponseDecoder: DatasetResponseDecoder {
    public let id: String

    public init(id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetDecodingError.invalidDecoderIdentifier
        }
        self.id = id
    }

    public func decode(_ input: DatasetDecodeInput) throws -> DatasetDecodedFragment {
        let input = try input.validated()
        return DatasetDecodedFragment(
            requestID: input.request.id,
            decoderID: id,
            metadata: ["numitissue.decoder.empty": "true"]
        )
    }
}

public actor DatasetDecoderRegistry {
    private var decodersByID: [String: any DatasetResponseDecoder] = [:]

    public init(decoders: [any DatasetResponseDecoder] = []) throws {
        for decoder in decoders {
            try Self.validate(decoder)
            guard decodersByID[decoder.id] == nil else {
                throw DatasetDecodingError.duplicateDecoder(decoder.id)
            }
            decodersByID[decoder.id] = decoder
        }
    }

    public func register(
        _ decoder: any DatasetResponseDecoder,
        replacingExisting: Bool = false
    ) throws {
        try Self.validate(decoder)
        if decodersByID[decoder.id] != nil, !replacingExisting {
            throw DatasetDecodingError.duplicateDecoder(decoder.id)
        }
        decodersByID[decoder.id] = decoder
    }

    public func register(
        contentsOf decoders: [any DatasetResponseDecoder],
        replacingExisting: Bool = false
    ) throws {
        var staged = decodersByID
        for decoder in decoders {
            try Self.validate(decoder)
            if staged[decoder.id] != nil, !replacingExisting {
                throw DatasetDecodingError.duplicateDecoder(decoder.id)
            }
            staged[decoder.id] = decoder
        }
        decodersByID = staged
    }

    @discardableResult
    public func remove(_ identifier: String) -> Bool {
        decodersByID.removeValue(forKey: identifier) != nil
    }

    public func identifiers() -> [String] {
        decodersByID.keys.sorted()
    }

    public func contains(_ identifier: String) -> Bool {
        decodersByID[identifier] != nil
    }

    public func decode(_ sourceInput: DatasetDecodeInput) throws -> DatasetDecodedFragment {
        let input = try sourceInput.validated()
        guard let decoder = decodersByID[input.request.decoderID] else {
            throw DatasetDecodingError.missingDecoder(input.request.decoderID)
        }
        let fragment = try decoder.decode(input)
        guard fragment.decoderID == decoder.id,
              fragment.requestID == input.request.id else {
            throw DatasetDecodingError.decoderIdentityMismatch(decoder.id)
        }
        return try fragment.validated(dataset: input.context.dataset)
    }

    private static func validate(_ decoder: any DatasetResponseDecoder) throws {
        guard !decoder.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatasetDecodingError.invalidDecoderIdentifier
        }
    }
}

public struct DatasetEvidenceAssembler: Sendable {
    public init() {}

    public func assemble(
        plan sourcePlan: DatasetQueryPlan,
        fragments sourceFragments: [DatasetDecodedFragment]
    ) throws -> EvidenceBatch {
        let plan = try sourcePlan.validated()

        var assetsByID: [String: DataAsset] = [:]
        var recordsByID: [String: EvidenceRecord] = [:]
        var partitionsByID: [String: AssetPartition] = [:]
        var ontology = OntologyRegistry()
        var provenance = ProvenanceGraph()
        var metadata = plan.metadata
        var diagnosticCounts: [DatasetDecoderDiagnosticSeverity: Int] = [:]

        for fragment in sourceFragments.sorted(by: { $0.requestID < $1.requestID }) {
            let fragment = try fragment.validated(dataset: plan.dataset)
            try merge(fragment.assets, into: &assetsByID, key: \.id, kind: "asset")
            try merge(fragment.records, into: &recordsByID, key: \.id, kind: "record")
            try merge(
                fragment.partitions,
                into: &partitionsByID,
                key: \.id,
                kind: "partition"
            )
            ontology = try ontology.merging(fragment.ontology)
            provenance = try provenance.merging(fragment.provenance)
            for diagnostic in fragment.diagnostics {
                diagnosticCounts[diagnostic.severity, default: 0] += 1
            }
            for key in fragment.metadata.keys.sorted() {
                metadata[
                    "numitissue.data.fragment.\(fragment.requestID).\(key)"
                ] = fragment.metadata[key]
            }
        }

        let knownAssets = Set(assetsByID.keys)
        for partition in partitionsByID.values {
            guard knownAssets.contains(partition.assetID) else {
                throw DatasetDecodingError.unknownPartitionAsset(
                    partition: partition.id,
                    asset: partition.assetID
                )
            }
        }
        let knownProvenance = Set(provenance.nodes.map(\.id))
        for record in recordsByID.values {
            if let assetID = record.assetID, !knownAssets.contains(assetID) {
                throw DatasetDecodingError.unknownRecordAsset(
                    record: record.id,
                    asset: assetID
                )
            }
            guard record.provenanceNodeIDs.allSatisfy(knownProvenance.contains) else {
                throw DatasetDecodingError.unknownRecordProvenance(record.id)
            }
        }

        metadata["numitissue.data.adapter"] = plan.adapterID
        metadata["numitissue.data.acquisition"] = plan.id
        metadata["numitissue.data.assets"] = String(assetsByID.count)
        metadata["numitissue.data.partitions"] = String(partitionsByID.count)
        metadata["numitissue.data.records"] = String(recordsByID.count)
        for severity in DatasetDecoderDiagnosticSeverity.allCases {
            metadata[
                "numitissue.data.diagnostics.\(severity.rawValue)"
            ] = String(diagnosticCounts[severity, default: 0])
        }

        return try EvidenceBatch(
            dataset: plan.dataset,
            assets: assetsByID.values.sorted { $0.id < $1.id },
            records: recordsByID.values.sorted { $0.id < $1.id },
            ontology: ontology,
            provenance: provenance,
            metadata: metadata
        ).validated()
    }

    private func merge<Value: Equatable>(
        _ incoming: [Value],
        into destination: inout [String: Value],
        key: KeyPath<Value, String>,
        kind: String
    ) throws {
        for value in incoming {
            let identifier = value[keyPath: key]
            if let existing = destination[identifier], existing != value {
                throw DatasetDecodingError.conflictingDecodedObject(
                    kind: kind,
                    identifier: identifier
                )
            }
            destination[identifier] = value
        }
    }
}

public enum DatasetDecodingError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidDiagnostic(String)
    case invalidContext(String)
    case invalidInput(String)
    case invalidFragment(String)
    case datasetMismatch(String)
    case unknownPartitionAsset(partition: String, asset: String)
    case unknownRecordAsset(record: String, asset: String)
    case unknownRecordProvenance(String)
    case selfExpandingRequest(String)
    case diagnosticRequestMismatch(expected: String, actual: String)
    case invalidDecoderIdentifier
    case duplicateDecoder(String)
    case missingDecoder(String)
    case decoderIdentityMismatch(String)
    case conflictingDecodedObject(kind: String, identifier: String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported dataset-decoding schema \(version)."
        case .invalidDiagnostic(let code):
            return "Dataset decoder diagnostic \(code) is invalid."
        case .invalidContext(let identifier):
            return "Dataset decode context \(identifier) is invalid."
        case .invalidInput(let request):
            return "Dataset decode input for request \(request) is invalid."
        case .invalidFragment(let request):
            return "Decoded dataset fragment for request \(request) is invalid."
        case .datasetMismatch(let identifier):
            return "Decoded object \(identifier) belongs to a different dataset."
        case .unknownPartitionAsset(let partition, let asset):
            return "Partition \(partition) references unknown asset \(asset)."
        case .unknownRecordAsset(let record, let asset):
            return "Evidence record \(record) references unknown asset \(asset)."
        case .unknownRecordProvenance(let record):
            return "Evidence record \(record) references unknown provenance."
        case .selfExpandingRequest(let request):
            return "Dataset request \(request) expands to itself."
        case .diagnosticRequestMismatch(let expected, let actual):
            return "Dataset diagnostic identifies request \(actual); expected \(expected)."
        case .invalidDecoderIdentifier:
            return "Dataset decoder identifier is empty."
        case .duplicateDecoder(let identifier):
            return "Dataset decoder \(identifier) is already registered."
        case .missingDecoder(let identifier):
            return "Dataset decoder \(identifier) is not registered."
        case .decoderIdentityMismatch(let identifier):
            return "Dataset decoder \(identifier) returned a mismatched fragment identity."
        case .conflictingDecodedObject(let kind, let identifier):
            return "Decoded \(kind) \(identifier) has conflicting definitions."
        }
    }
}
