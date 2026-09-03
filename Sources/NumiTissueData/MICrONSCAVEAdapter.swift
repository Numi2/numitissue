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
              offset >= 0,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(
                "cave-query"
            )
        }
        switch operation {
        case .datastackInfo, .materializationVersions:
            guard table == nil else {
                throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(
                    "cave-query"
                )
            }
        case .materializationTable:
            guard table?.isEmpty == false, materializationVersion != nil else {
                throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(
                    "cave-query"
                )
            }
        }
        for bounds in spatialBounds { _ = try bounds.validated() }
        return self
    }

    public func canonicalString() throws -> String {
        let value = try validated()
        return String(
            decoding: try ScientificCanonicalJSON.encode(value),
            as: UTF8.self
        )
    }
}

public struct MICrONSCAVEAdapterConfiguration: Codable, Sendable, Equatable {
    public var adapterID: String
    public var cellTable: String
    public var synapseTable: String
    public var pageSize: Int
    public var allowUnboundedTableQueries: Bool
    public var cellSpatialColumn: String
    public var synapseSpatialColumn: String
    public var voxelCoordinateFrameID: String
    public var credentialScope: String?

    public init(
        adapterID: String = "microns-cave-v3",
        cellTable: String = "nucleus_detection_v0",
        synapseTable: String = "synapses_pni_2",
        pageSize: Int = 200_000,
        allowUnboundedTableQueries: Bool = false,
        cellSpatialColumn: String = "pt_position",
        synapseSpatialColumn: String = "ctr_pt_position",
        voxelCoordinateFrameID: String = "cave-voxel",
        credentialScope: String? = "cave.read"
    ) {
        self.adapterID = adapterID
        self.cellTable = cellTable
        self.synapseTable = synapseTable
        self.pageSize = pageSize
        self.allowUnboundedTableQueries = allowUnboundedTableQueries
        self.cellSpatialColumn = cellSpatialColumn
        self.synapseSpatialColumn = synapseSpatialColumn
        self.voxelCoordinateFrameID = voxelCoordinateFrameID
        self.credentialScope = credentialScope
    }

    public func validated() throws -> Self {
        guard !adapterID.isEmpty,
              !cellTable.isEmpty,
              !synapseTable.isEmpty,
              !cellSpatialColumn.isEmpty,
              !synapseSpatialColumn.isEmpty,
              !voxelCoordinateFrameID.isEmpty,
              pageSize > 0,
              pageSize <= 1_000_000,
              credentialScope?.isEmpty != true else {
            throw BiologicalDatasetAdapterError.invalidAdapterConfiguration(
                adapterID
            )
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
        let serverBaseURL = try caveServiceBaseURL(dataset)
        let materializationText = dataset.materializationVersion ?? dataset.release
        guard let materialization = Int(materializationText),
              materialization >= 0 else {
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
                descriptor: CAVEQueryDescriptor(
                    operation: .datastackInfo,
                    metadata: ["cave.server-base-url": serverBaseURL]
                ),
                decoderID: "cave-datastack-info-v3",
                dependencies: [],
                priority: .critical
            ),
            try caveRequest(
                id: versionID,
                dataset: dataset,
                selection: selection,
                descriptor: CAVEQueryDescriptor(
                    operation: .materializationVersions,
                    metadata: ["cave.server-base-url": serverBaseURL]
                ),
                decoderID: "cave-materialization-versions-v3",
                dependencies: [infoID],
                priority: .critical
            )
        ]

        let tables = selectedTables(selection)
        let windows: [DatasetSpatialWindow?] = selection.spatialWindows.isEmpty
            ? [nil]
            : selection.spatialWindows.map(Optional.some)
        for (tableOrdinal, table) in tables.enumerated() {
            let roles = entityRoles(table: table, selection: selection)
            for (roleOrdinal, role) in roles.enumerated() {
                for (windowOrdinal, window) in windows.enumerated() {
                    let descriptor = try tableDescriptor(
                        table: table,
                        materialization: materialization,
                        selection: selection,
                        entityRole: role,
                        spatialWindow: window,
                        serverBaseURL: serverBaseURL
                    )
                    requests.append(try caveRequest(
                        id: BiologicalAdapterUtilities.requestID(
                            planID: planID,
                            role: "cave-table-\(tableOrdinal)",
                            ordinal: roleOrdinal * windows.count + windowOrdinal
                        ),
                        dataset: dataset,
                        selection: selection,
                        descriptor: descriptor,
                        decoderID: "cave-materialization-table-v3",
                        dependencies: [infoID, versionID],
                        priority: .high
                    ))
                }
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
                "numitissue.adapter.version": "3",
                "numitissue.cave.server-base-url": serverBaseURL,
                "numitissue.cave.voxel-frame":
                    configuration.voxelCoordinateFrameID,
                "numitissue.cave.materialization": String(materialization),
                "numitissue.pagination.page-size":
                    String(configuration.pageSize)
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
        entityRole: String?,
        spatialWindow: DatasetSpatialWindow?,
        serverBaseURL: String
    ) throws -> CAVEQueryDescriptor {
        let serverPredicateCount = selection.metadataPredicates.keys.filter {
            !$0.hasPrefix("cave.")
        }.count
        let hasBoundingConstraint = !selection.entityIdentifiers.isEmpty ||
            spatialWindow != nil ||
            selection.sampling.targetCount != nil ||
            serverPredicateCount > 0
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
            let column = selection.metadataPredicates["cave.cell-id-column"] ??
                "pt_root_id"
            filterIn[column] = selection.entityIdentifiers.sorted()
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
        if let spatialWindow,
           spatialWindow.bounds.frameID !=
            configuration.voxelCoordinateFrameID {
            throw MICrONSCAVEAdapterError.spatialFrameMismatch(
                expected: configuration.voxelCoordinateFrameID,
                actual: spatialWindow.bounds.frameID
            )
        }
        var metadata: [String: String] = [
            "cave.server-base-url": serverBaseURL,
            "cave.spatial-column": table == configuration.synapseTable
                ? configuration.synapseSpatialColumn
                : configuration.cellSpatialColumn,
            "cave.voxel-frame": configuration.voxelCoordinateFrameID
        ]
        if let entityRole { metadata["cave.entity-role"] = entityRole }
        return try CAVEQueryDescriptor(
            operation: .materializationTable,
            table: table,
            materializationVersion: materialization,
            selectedColumns: caveColumns(
                table: table,
                selection: selection
            ),
            filterEqual: filterEqual,
            filterIn: filterIn,
            spatialBounds: spatialWindow.map { [$0.bounds] } ?? [],
            limit: max(1, limit),
            metadata: metadata
        ).validated()
    }

    private func caveColumns(
        table: String,
        selection: DatasetSelection
    ) -> [String] {
        if let columns = selection.metadataPredicates["cave.select-columns"] {
            var seen = Set<String>()
            return columns.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        if table == configuration.synapseTable {
            return [
                "id",
                "pre_pt_root_id",
                "post_pt_root_id",
                configuration.synapseSpatialColumn,
                "size"
            ]
        }
        return ["id", "pt_root_id", configuration.cellSpatialColumn]
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
            method: descriptor.operation == .materializationTable
                ? .post
                : .get,
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
            cachePolicy: dataset.stability == .mutableLatest
                ? .revalidate
                : .immutable,
            metadata: BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: [
                    "numitissue.discovery-role":
                        descriptor.operation.rawValue,
                    "numitissue.cave.operation":
                        descriptor.operation.rawValue
                ]
            )
        )
    }

    private func caveServiceBaseURL(_ dataset: DatasetVersion) throws -> String {
        guard let sourceURI = dataset.sourceURI,
              let components = URLComponents(string: sourceURI),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else {
            throw BiologicalDatasetAdapterError.missingDatasetSourceURI(
                dataset.stableReference
            )
        }
        var normalized = components
        normalized.query = nil
        normalized.fragment = nil
        guard let value = normalized.url?.absoluteString else {
            throw BiologicalDatasetAdapterError.missingDatasetSourceURI(
                dataset.stableReference
            )
        }
        return value.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
    }
}

public enum MICrONSCAVEAdapterError: Error, Sendable, CustomStringConvertible {
    case spatialFrameMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .spatialFrameMismatch(let expected, let actual):
            return "CAVE spatial selection uses frame \(actual); expected voxel frame \(expected)."
        }
    }
}
