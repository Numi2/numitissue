import Foundation
import NumiTissueIO

public enum CAVEQueryOperation: String, Codable, Sendable, CaseIterable {
    case datastackInfo
    case materializationVersions
    case materializationTable
}

public struct CAVEQueryDescriptor: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var operation: CAVEQueryOperation
    public var table: String?
    public var materializationVersion: Int?
    public var selectedColumns: [String]
    public var filterEqual: [String: String]
    public var filterIn: [String: [String]]
    public var spatialBounds: [CoordinateBounds]
    public var limit: Int?
    public var offset: Int
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        operation: CAVEQueryOperation,
        table: String? = nil,
        materializationVersion: Int? = nil,
        selectedColumns: [String] = [],
        filterEqual: [String: String] = [:],
        filterIn: [String: [String]] = [:],
        spatialBounds: [CoordinateBounds] = [],
        limit: Int? = nil,
        offset: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.table = table
        self.materializationVersion = materializationVersion
        self.selectedColumns = selectedColumns
        self.filterEqual = filterEqual
        self.filterIn = filterIn
        self.spatialBounds = spatialBounds
        self.limit = limit
        self.offset = offset
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              materializationVersion.map({ $0 >= 0 }) ?? true,
              Set(selectedColumns).count == selectedColumns.count,
              selectedColumns.allSatisfy({ !$0.isEmpty }),
              filterEqual.keys.allSatisfy({ !$0.isEmpty }),
              filterIn.keys.allSatisfy({ !$0.isEmpty }),
              filterIn.values.allSatisfy({ !$0.isEmpty }),
              limit.map({ $0 > 0 && $0 <= 1_000_000 }) ?? true,
              offset >= 0 else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration("cave-query")
        }
        switch operation {
        case .datastackInfo, .materializationVersions:
            guard table == nil else {
                throw BiologicalDatasetAdapterError.invalidAdapterConfiguration("cave-query")
            }
        case .materializationTable:
            guard table?.isEmpty == false, materializationVersion != nil else {
                throw BiologicalDatasetAdapterError.invalidAdapterConfiguration("cave-query")
            }
        }
        for bounds in spatialBounds { _ = try bounds.validated() }
        return self
    }

    public func canonicalString() throws -> String {
        let value = try validated()
        return String(decoding: try ScientificCanonicalJSON.encode(value), as: UTF8.self)
    }
}

public struct MICrONSCAVEAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var cellTable: String
    public var synapseTable: String
    public var pageSize: Int
    public var allowUnboundedTableQueries: Bool
    public var credentialScope: String?

    public init(
        adapterID: String = "microns-cave-v2",
        cellTable: String = "nucleus_detection_v0",
        synapseTable: String = "synapses_pni_2",
        pageSize: Int = 200_000,
        allowUnboundedTableQueries: Bool = false,
        credentialScope: String? = "cave.read"
    ) {
        self.adapterID = adapterID
        self.cellTable = cellTable
        self.synapseTable = synapseTable
        self.pageSize = pageSize
        self.allowUnboundedTableQueries = allowUnboundedTableQueries
        self.credentialScope = credentialScope
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !cellTable.isEmpty,
              !synapseTable.isEmpty,
              pageSize > 0,
              pageSize <= 1_000_000,
              credentialScope?.isEmpty != true else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(adapterID)
        }
        return self
    }
}

public struct MICrONSCAVEAdapter: BiologicalDatasetAdapter {
    public let configuration: MICrONSCAVEAdapterConfiguration

    public init(
        configuration: MICrONSCAVEAdapterConfiguration =
            MICrONSCAVEAdapterConfiguration()
    ) throws {
        self.configuration = try configuration.validated()
    }

    public var adapterID: String { configuration.adapterID }
    public var source: BiologicalDataSource { .microns }
    public var capabilities: BiologicalDatasetAdapterCapabilities {
        BiologicalDatasetAdapterCapabilities(
            source: source,
            modalities: [
                .anatomy,
                .connectome,
                .functionalImaging,
                .morphology,
                .synapse,
                .ultrastructure
            ],
            representations: [
                .annotations,
                .cellMetadata,
                .connectivityEdges,
                .spatialCoordinates,
                .synapseLocations
            ],
            supportsSpatialSelection: true,
            supportsEntitySelection: true,
            supportsPagination: true,
            requiresCredentials: configuration.credentialScope != nil,
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
        let materializationText = dataset.materializationVersion ?? dataset.release
        guard let materialization = Int(materializationText), materialization >= 0 else {
            throw BiologicalDatasetAdapterError.invalidMaterializationVersion(
                materializationText
            )
        }
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let infoID = BiologicalAdapterUtilities.requestID(
            planID: planID,
            role: "cave-info"
        )
        let versionID = BiologicalAdapterUtilities.requestID(
            planID: planID,
            role: "cave-version"
        )
        var requests = [
            try caveRequest(
                id: infoID,
                dataset: dataset,
                selection: selection,
                descriptor: CAVEQueryDescriptor(operation: .datastackInfo),
                decoderID: "cave-datastack-info-v2",
                dependencies: [],
                priority: .critical
            ),
            try caveRequest(
                id: versionID,
                dataset: dataset,
                selection: selection,
                descriptor: CAVEQueryDescriptor(operation: .materializationVersions),
                decoderID: "cave-materialization-versions-v2",
                dependencies: [infoID],
                priority: .critical
            )
        ]

        let tables = selectedTables(selection)
        for (tableOrdinal, table) in tables.enumerated() {
            let roles = entityRoles(table: table, selection: selection)
            for (roleOrdinal, role) in roles.enumerated() {
                let descriptor = try tableDescriptor(
                    table: table,
                    materialization: materialization,
                    selection: selection,
                    entityRole: role
                )
                requests.append(try caveRequest(
                    id: BiologicalAdapterUtilities.requestID(
                        planID: planID,
                        role: "cave-table-\(tableOrdinal)",
                        ordinal: roleOrdinal
                    ),
                    dataset: dataset,
                    selection: selection,
                    descriptor: descriptor,
                    decoderID: "cave-materialization-table-v2",
                    dependencies: [infoID, versionID],
                    priority: .high
                ))
            }
        }
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: requests,
            metadata: [
                "numitissue.adapter.family": "cave",
                "numitissue.adapter.version": "2",
                "numitissue.cave.materialization": String(materialization),
                "numitissue.pagination.page-size": String(configuration.pageSize)
            ]
        ).validated()
    }

    private func selectedTables(_ selection: DatasetSelection) -> [String] {
        var result = Set<String>()
        if !selection.representations.intersection([
            .cellMetadata,
            .annotations,
            .spatialCoordinates
        ]).isEmpty {
            result.insert(configuration.cellTable)
        }
        if !selection.representations.intersection([
            .connectivityEdges,
            .synapseLocations
        ]).isEmpty {
            result.insert(configuration.synapseTable)
        }
        return result.sorted()
    }

    private func entityRoles(
        table: String,
        selection: DatasetSelection
    ) -> [String?] {
        guard table == configuration.synapseTable,
              !selection.entityIdentifiers.isEmpty else {
            return [nil]
        }
        return ["pre_pt_root_id", "post_pt_root_id"]
    }

    private func tableDescriptor(
        table: String,
        materialization: Int,
        selection: DatasetSelection,
        entityRole: String?
    ) throws -> CAVEQueryDescriptor {
        let hasBoundingConstraint = !selection.entityIdentifiers.isEmpty ||
            !selection.spatialWindows.isEmpty ||
            selection.sampling.targetCount != nil ||
            !selection.metadataPredicates.isEmpty
        guard configuration.allowUnboundedTableQueries || hasBoundingConstraint else {
            throw BiologicalDatasetAdapterError.unboundedQuery(
                source: source,
                resource: table
            )
        }
        var filterEqual: [String: String] = [:]
        for key in selection.metadataPredicates.keys.sorted()
            where !key.hasPrefix("cave.") {
            filterEqual[key] = selection.metadataPredicates[key]
        }
        var filterIn: [String: [String]] = [:]
        if let entityRole {
            filterIn[entityRole] = selection.entityIdentifiers.sorted()
        } else if table == configuration.cellTable,
                  !selection.entityIdentifiers.isEmpty {
            filterIn[selection.metadataPredicates["cave.cell-id-column"] ?? "pt_root_id"] =
                selection.entityIdentifiers.sorted()
        }
        let requested = selection.sampling.targetCount.map {
            min($0, UInt64(Int.max))
        }
        let budgetBound = min(
            selection.budget.maximumEntities,
            table == configuration.synapseTable
                ? selection.budget.maximumSynapses
                : selection.budget.maximumCells
        )
        let limit = Int(min(
            UInt64(configuration.pageSize),
            requested ?? budgetBound
        ))
        return try CAVEQueryDescriptor(
            operation: .materializationTable,
            table: table,
            materializationVersion: materialization,
            selectedColumns: caveColumns(table: table, selection: selection),
            filterEqual: filterEqual,
            filterIn: filterIn,
            spatialBounds: selection.spatialWindows.map(\.bounds),
            limit: max(1, limit),
            metadata: entityRole.map { ["entity-role": $0] } ?? [:]
        ).validated()
    }

    private func caveColumns(
        table: String,
        selection: DatasetSelection
    ) -> [String] {
        if let columns = selection.metadataPredicates["cave.select-columns"] {
            return columns.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if table == configuration.synapseTable {
            return [
                "id",
                "pre_pt_root_id",
                "post_pt_root_id",
                "ctr_pt_position",
                "size"
            ]
        }
        return ["id", "pt_root_id", "pt_position"]
    }

    private func caveRequest(
        id: String,
        dataset: DatasetVersion,
        selection: DatasetSelection,
        descriptor: CAVEQueryDescriptor,
        decoderID: String,
        dependencies: [String],
        priority: DatasetRequestPriority
    ) throws -> DatasetQueryRequest {
        let descriptor = try descriptor.validated()
        let query = try descriptor.canonicalString()
        return DatasetQueryRequest(
            id: id,
            method: descriptor.operation == .materializationTable ? .post : .get,
            locator: .cave(
                datastack: dataset.datasetID,
                table: descriptor.table,
                materializationVersion: descriptor.materializationVersion,
                query: query
            ),
            headers: ["Accept": "application/json"],
            body: descriptor.operation == .materializationTable
                ? try ScientificCanonicalJSON.encode(descriptor)
                : nil,
            credentialScope: configuration.credentialScope,
            decoderID: decoderID,
            expectedEncoding: .json,
            expectedMediaType: "application/json",
            dependencies: dependencies,
            priority: priority,
            cachePolicy: dataset.stability == .materializedSnapshot ? .immutable : .revalidate,
            metadata: BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: [
                    "numitissue.discovery-role": descriptor.operation.rawValue,
                    "numitissue.cave.operation": descriptor.operation.rawValue
                ]
            )
        )
    }
}
