import Foundation
import NumiTissueIO

public struct ManifestBackedDatasetAdapter: BiologicalDatasetAdapter {
    public let adapterID: String
    public let manifest: DatasetManifest
    public let semanticsByAssetID: [String: ManifestAssetSemantics]
    public let capabilities: BiologicalDatasetAdapterCapabilities

    public init(
        adapterID: String? = nil,
        manifest sourceManifest: DatasetManifest,
        semanticsByAssetID sourceSemantics: [String: ManifestAssetSemantics] = [:]
    ) throws {
        let manifest = try sourceManifest.validated()
        let identifier = adapterID ??
            "manifest-\(manifest.dataset.source.rawValue)-v1"
        guard !identifier.isEmpty else {
            throw BiologicalDatasetAdapterError.invalidAdapter(identifier)
        }
        let assetIDs = Set(manifest.assets.map(\.id))
        guard Set(sourceSemantics.keys).isSubset(of: assetIDs) else {
            let unknown = Set(sourceSemantics.keys).subtracting(assetIDs).sorted()
            throw BiologicalDatasetAdapterError.unknownManifestAssets(unknown)
        }
        var semantics: [String: ManifestAssetSemantics] = [:]
        for asset in manifest.assets {
            let value = sourceSemantics[asset.id] ?? .inferred(from: asset)
            semantics[asset.id] = try value.validated(assetID: asset.id)
        }
        let modalities = manifest.assets.reduce(into: Set<BiologicalDataModality>()) {
            $0.formUnion($1.modalities)
        }
        let representations = semantics.values.reduce(
            into: Set<DatasetRepresentation>()
        ) {
            $0.formUnion($1.representations)
        }
        self.adapterID = identifier
        self.manifest = manifest
        self.semanticsByAssetID = semantics
        capabilities = try BiologicalDatasetAdapterCapabilities(
            source: manifest.dataset.source,
            modalities: modalities,
            representations: representations,
            supportsSpatialSelection: manifest.assets.contains {
                $0.coordinateFrame != nil
            } || manifest.partitions.contains { $0.bounds != nil },
            supportsTemporalSelection: manifest.assets.contains {
                $0.metadata["numitissue.temporal"] == "true"
            },
            supportsEntitySelection: true,
            supportsSpecimenSelection: manifest.assets.contains { $0.specimen != nil }
        ).validated()
    }

    public var source: BiologicalDataSource { manifest.dataset.source }

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
        guard dataset.stableReference == manifest.dataset.stableReference else {
            throw BiologicalDatasetAdapterError.manifestDatasetMismatch(
                expected: manifest.dataset.stableReference,
                actual: dataset.stableReference
            )
        }
        let planID = try BiologicalAdapterUtilities.planID(
            adapterID: adapterID,
            dataset: dataset,
            selection: selection
        )
        let assetByID = Dictionary(uniqueKeysWithValues: manifest.assets.map {
            ($0.id, $0)
        })
        let direct = Set(manifest.assets.filter {
            assetMatches($0, selection: selection)
        }.map(\.id))
        guard !direct.isEmpty else {
            throw BiologicalDatasetAdapterError.emptyManifestSelection(
                manifest.dataset.stableReference
            )
        }
        let selected = try dependencyClosure(
            direct,
            assetByID: assetByID
        )
        let requestSpecs = try makeRequestSpecifications(
            selectedAssetIDs: selected,
            directAssetIDs: direct,
            assetByID: assetByID,
            selection: selection,
            planID: planID
        )
        let requestIDsByAsset = Dictionary(grouping: requestSpecs, by: \.assetID)
            .mapValues { $0.map(\.requestID).sorted() }
        let requests = try requestSpecs.sorted(by: requestSpecificationOrder).map { spec in
            guard let asset = assetByID[spec.assetID],
                  let semantics = semanticsByAssetID[asset.id] else {
                throw BiologicalDatasetAdapterError.invalidManifestSemantics(spec.assetID)
            }
            let dependencies = try asset.dependencies.flatMap { dependency in
                guard let identifiers = requestIDsByAsset[dependency] else {
                    throw BiologicalDatasetAdapterError.unknownManifestDependency(
                        assetID: asset.id,
                        dependencyID: dependency
                    )
                }
                return identifiers
            }.sorted()
            let checksum: ScientificSHA256Digest?
            if spec.byteRange == nil, let value = asset.checksum {
                checksum = try ScientificSHA256Digest(hexadecimal: value)
            } else {
                checksum = nil
            }
            var metadata = BiologicalAdapterUtilities.canonicalMetadata(
                source: source,
                selection: selection,
                additional: asset.metadata
            )
            for key in semantics.metadata.keys.sorted() {
                metadata[key] = semantics.metadata[key]
            }
            metadata["numitissue.asset-id"] = asset.id
            metadata["numitissue.asset-direct-selection"] =
                direct.contains(asset.id) ? "true" : "false"
            if let partitionID = spec.partitionID {
                metadata["numitissue.partition-id"] = partitionID
            }
            if spec.requiresClientFiltering {
                metadata["numitissue.client-filter-required"] = "true"
            }
            return DatasetQueryRequest(
                id: spec.requestID,
                assetID: asset.id,
                locator: asset.locator,
                byteRange: spec.byteRange,
                decoderID: semantics.decoderID,
                expectedEncoding: asset.encoding,
                expectedCompression: asset.compression,
                expectedMediaType: asset.mediaType,
                expectedChecksum: checksum,
                expectedByteCount: spec.byteRange?.length ?? asset.byteCount,
                estimatedDecodedBytes: scaledDecodedBytes(
                    semantics.estimatedDecodedBytes,
                    assetByteCount: asset.byteCount,
                    selectedByteCount: spec.byteRange?.length
                ),
                dependencies: dependencies,
                priority: direct.contains(asset.id) ? .high : .normal,
                optional: semantics.optional,
                cachePolicy: cachePolicy(dataset.stability),
                metadata: metadata
            )
        }
        return try DatasetQueryPlan(
            id: planID,
            adapterID: adapterID,
            dataset: dataset,
            selection: selection,
            requests: requests,
            metadata: [
                "numitissue.adapter.family": "manifest",
                "numitissue.adapter.version": "1",
                "numitissue.manifest.assets-selected": String(selected.count),
                "numitissue.manifest.assets-direct": String(direct.count)
            ]
        ).validated()
    }
}

private extension ManifestBackedDatasetAdapter {
    struct RequestSpecification: Sendable {
        var assetID: String
        var partitionID: String?
        var byteRange: ByteRange?
        var requestID: String
        var requiresClientFiltering: Bool
    }

    func assetMatches(
        _ asset: DataAsset,
        selection: DatasetSelection
    ) -> Bool {
        guard !asset.modalities.isDisjoint(with: selection.modalities),
              let semantics = semanticsByAssetID[asset.id],
              !semantics.representations.isDisjoint(
                with: selection.representations
              ) else {
            return false
        }
        if semantics.restricted && !selection.includeRestrictedAssets {
            return false
        }
        if selection.requireCompleteGeometry && semantics.completeGeometry != true {
            return false
        }
        if !selection.specimenIDs.isEmpty {
            guard let specimen = asset.specimen else { return false }
            let identifiers = Set([
                specimen.donorID,
                specimen.specimenID,
                specimen.sampleID
            ].compactMap { $0 })
            guard !identifiers.isDisjoint(with: selection.specimenIDs) else {
                return false
            }
        }
        for key in selection.metadataPredicates.keys.sorted() {
            if key.hasPrefix("numitissue.") { continue }
            guard asset.metadata[key] == selection.metadataPredicates[key] else {
                return false
            }
        }
        return true
    }

    func dependencyClosure(
        _ roots: Set<String>,
        assetByID: [String: DataAsset]
    ) throws -> Set<String> {
        var result = roots
        var stack = roots.sorted()
        while let identifier = stack.popLast() {
            guard let asset = assetByID[identifier] else {
                throw BiologicalDatasetAdapterError.unknownManifestAssets([identifier])
            }
            for dependency in asset.dependencies.sorted() {
                guard assetByID[dependency] != nil else {
                    throw BiologicalDatasetAdapterError.unknownManifestDependency(
                        assetID: identifier,
                        dependencyID: dependency
                    )
                }
                if result.insert(dependency).inserted {
                    stack.append(dependency)
                }
            }
        }
        return result
    }

    func makeRequestSpecifications(
        selectedAssetIDs: Set<String>,
        directAssetIDs: Set<String>,
        assetByID: [String: DataAsset],
        selection: DatasetSelection,
        planID: String
    ) throws -> [RequestSpecification] {
        let partitionsByAsset = Dictionary(grouping: manifest.partitions, by: \.assetID)
        var result: [RequestSpecification] = []
        for assetID in selectedAssetIDs.sorted() {
            guard let asset = assetByID[assetID] else {
                throw BiologicalDatasetAdapterError.unknownManifestAssets([assetID])
            }
            let direct = directAssetIDs.contains(assetID)
            let assetRole = "asset-" + StableTextHash.hexadecimal(
                StableTextHash.fnv1a64(assetID)
            )
            let allPartitions = (partitionsByAsset[assetID] ?? []).sorted {
                $0.id < $1.id
            }
            let requiresPartitionFiltering = direct && (
                !selection.entityIdentifiers.isEmpty ||
                !selection.spatialWindows.isEmpty
            )
            let matchedPartitions = requiresPartitionFiltering
                ? allPartitions.filter { partitionMatches($0, selection: selection) }
                : []
            if requiresPartitionFiltering && !matchedPartitions.isEmpty {
                for (ordinal, partition) in matchedPartitions.enumerated() {
                    result.append(RequestSpecification(
                        assetID: assetID,
                        partitionID: partition.id,
                        byteRange: partition.byteRange ?? asset.byteRange,
                        requestID: BiologicalAdapterUtilities.requestID(
                            planID: planID,
                            role: assetRole,
                            ordinal: ordinal
                        ),
                        requiresClientFiltering: partition.byteRange == nil &&
                            asset.byteRange == nil
                    ))
                }
            } else {
                result.append(RequestSpecification(
                    assetID: assetID,
                    partitionID: nil,
                    byteRange: asset.byteRange,
                    requestID: BiologicalAdapterUtilities.requestID(
                        planID: planID,
                        role: assetRole
                    ),
                    requiresClientFiltering: requiresPartitionFiltering
                ))
            }
        }
        return result
    }

    func partitionMatches(
        _ partition: AssetPartition,
        selection: DatasetSelection
    ) -> Bool {
        if !selection.entityIdentifiers.isEmpty,
           !partition.entityIDs.isEmpty,
           Set(partition.entityIDs).isDisjoint(
                with: selection.entityIdentifiers
           ) {
            return false
        }
        if !selection.spatialWindows.isEmpty,
           let bounds = partition.bounds {
            let intersects = selection.spatialWindows.contains {
                Self.intersects(bounds, $0.bounds)
            }
            if !intersects { return false }
        }
        return true
    }

    static func intersects(
        _ lhs: CoordinateBounds,
        _ rhs: CoordinateBounds
    ) -> Bool {
        guard lhs.frameID == rhs.frameID,
              lhs.minimum.count == 3,
              lhs.maximum.count == 3,
              rhs.minimum.count == 3,
              rhs.maximum.count == 3 else {
            return false
        }
        for axis in 0..<3 where
            lhs.maximum[axis] < rhs.minimum[axis] ||
                rhs.maximum[axis] < lhs.minimum[axis] {
            return false
        }
        return true
    }

    func cachePolicy(_ stability: DatasetStability) -> DatasetRequestCachePolicy {
        switch stability {
        case .immutableRelease, .materializedSnapshot:
            return .immutable
        case .mutableLatest:
            return .revalidate
        case .localDerived:
            return .transient
        }
    }

    func scaledDecodedBytes(
        _ decoded: UInt64?,
        assetByteCount: UInt64?,
        selectedByteCount: UInt64?
    ) -> UInt64? {
        guard let decoded else { return nil }
        guard let total = assetByteCount,
              let selected = selectedByteCount,
              total > 0,
              selected < total else {
            return decoded
        }
        let numerator = decoded.multipliedReportingOverflow(by: selected)
        guard !numerator.overflow else { return decoded }
        return max(1, numerator.partialValue / total)
    }

    func requestSpecificationOrder(
        _ lhs: RequestSpecification,
        _ rhs: RequestSpecification
    ) -> Bool {
        if lhs.assetID != rhs.assetID { return lhs.assetID < rhs.assetID }
        return (lhs.partitionID ?? "") < (rhs.partitionID ?? "")
    }
}
