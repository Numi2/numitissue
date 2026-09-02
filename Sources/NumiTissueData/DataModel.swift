import Foundation
import NumiTissueCore

public enum BiologicalDataSource: String, Codable, Sendable, CaseIterable, Hashable {
    case allenBrainCellAtlas = "allen-brain-cell-atlas"
    case allenCellTypes = "allen-cell-types"
    case microns = "microns"
    case h01 = "h01"
    case blueBrain = "blue-brain"
    case dandi = "dandi"
    case modelDB = "modeldb"
    case neuroMorpho = "neuromorpho"
    case ebrains = "ebrains"
    case brainImageLibrary = "brain-image-library"
    case custom = "custom"
}

public enum BiologicalDataModality: String, Codable, Sendable, CaseIterable, Hashable {
    case anatomy
    case cellDensity
    case connectome
    case electrophysiology
    case functionalImaging
    case glia
    case ionChannel
    case microscopy
    case molecularNetwork
    case morphology
    case physiology
    case simulationModel
    case spatialTranscriptomics
    case synapse
    case transcriptomics
    case ultrastructure
    case vasculature
}

public enum DatasetStability: String, Codable, Sendable, CaseIterable {
    case immutableRelease
    case materializedSnapshot
    case mutableLatest
    case localDerived
}

public struct DatasetLicense: Codable, Sendable, Equatable {
    public var identifier: String
    public var name: String
    public var licenseURI: String?
    public var attributionRequired: Bool
    public var redistributionAllowed: Bool?
    public var commercialUseAllowed: Bool?
    public var shareAlikeRequired: Bool
    public var notice: String?

    public init(
        identifier: String,
        name: String,
        licenseURI: String? = nil,
        attributionRequired: Bool,
        redistributionAllowed: Bool? = nil,
        commercialUseAllowed: Bool? = nil,
        shareAlikeRequired: Bool = false,
        notice: String? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.licenseURI = licenseURI
        self.attributionRequired = attributionRequired
        self.redistributionAllowed = redistributionAllowed
        self.commercialUseAllowed = commercialUseAllowed
        self.shareAlikeRequired = shareAlikeRequired
        self.notice = notice
    }

    public static let unknown = Self(
        identifier: "NOASSERTION",
        name: "Unknown or unverified license",
        attributionRequired: true,
        redistributionAllowed: nil,
        commercialUseAllowed: nil,
        notice: "Resolve the source license before distributing derived artifacts."
    )

    public func validated() throws -> Self {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BiologicalDataError.invalidLicense(identifier)
        }
        return self
    }
}

public struct DatasetVersion: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var source: BiologicalDataSource
    public var datasetID: String
    public var release: String
    public var materializationVersion: String?
    public var contentDigest: String?
    public var sourceURI: String?
    public var acquiredAt: Date?
    public var stability: DatasetStability
    public var license: DatasetLicense
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        source: BiologicalDataSource,
        datasetID: String,
        release: String,
        materializationVersion: String? = nil,
        contentDigest: String? = nil,
        sourceURI: String? = nil,
        acquiredAt: Date? = nil,
        stability: DatasetStability,
        license: DatasetLicense = .unknown,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.datasetID = datasetID
        self.release = release
        self.materializationVersion = materializationVersion
        self.contentDigest = contentDigest
        self.sourceURI = sourceURI
        self.acquiredAt = acquiredAt
        self.stability = stability
        self.license = license
        self.metadata = metadata
    }

    public var stableReference: String {
        [
            source.rawValue,
            datasetID,
            release,
            materializationVersion ?? "-",
            contentDigest ?? "-"
        ].joined(separator: ":")
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw BiologicalDataError.unsupportedSchema(schemaVersion)
        }
        guard !datasetID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !release.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BiologicalDataError.invalidDatasetReference(stableReference)
        }
        if stability == .materializedSnapshot,
           materializationVersion?.isEmpty != false {
            throw BiologicalDataError.missingMaterializationVersion(stableReference)
        }
        _ = try license.validated()
        return self
    }
}

public struct ByteRange: Codable, Sendable, Hashable {
    public var offset: UInt64
    public var length: UInt64

    public init(offset: UInt64, length: UInt64) {
        self.offset = offset
        self.length = length
    }

    public var endOffset: UInt64? {
        let (value, overflow) = offset.addingReportingOverflow(length)
        return overflow ? nil : value
    }

    public func validated() throws -> Self {
        guard length > 0, endOffset != nil else {
            throw BiologicalDataError.invalidByteRange(offset: offset, length: length)
        }
        return self
    }
}

public enum DataLocator: Codable, Sendable, Equatable {
    case https(url: String)
    case s3(bucket: String, key: String, versionID: String?)
    case gcs(bucket: String, key: String, generation: String?)
    case cave(
        datastack: String,
        table: String?,
        materializationVersion: Int?,
        query: String?
    )
    case dandi(dandiset: String, version: String, assetPath: String?)
    case modelDB(accession: Int, path: String?)
    case local(path: String)

    public var canonicalDescription: String {
        switch self {
        case .https(let url):
            return url
        case .s3(let bucket, let key, let versionID):
            return "s3://\(bucket)/\(key)#\(versionID ?? "-")"
        case .gcs(let bucket, let key, let generation):
            return "gs://\(bucket)/\(key)#\(generation ?? "-")"
        case .cave(let datastack, let table, let version, let query):
            return "cave://\(datastack)/\(table ?? "-")/\(version.map { String($0) } ?? "-")?\(query ?? "")"
        case .dandi(let dandiset, let version, let path):
            return "dandi://\(dandiset)/\(version)/\(path ?? "")"
        case .modelDB(let accession, let path):
            return "modeldb://\(accession)/\(path ?? "")"
        case .local(let path):
            return "file://\(path)"
        }
    }

    public func validated() throws -> Self {
        switch self {
        case .https(let url):
            guard let components = URLComponents(string: url),
                  components.scheme == "https",
                  components.host?.isEmpty == false else {
                throw BiologicalDataError.invalidLocator(url)
            }
        case .s3(let bucket, let key, _), .gcs(let bucket, let key, _):
            guard !bucket.isEmpty, !key.isEmpty else {
                throw BiologicalDataError.invalidLocator(canonicalDescription)
            }
        case .cave(let datastack, _, let materializationVersion, _):
            guard !datastack.isEmpty,
                  materializationVersion.map({ $0 >= 0 }) ?? true else {
                throw BiologicalDataError.invalidLocator(canonicalDescription)
            }
        case .dandi(let dandiset, let version, _):
            guard !dandiset.isEmpty, !version.isEmpty else {
                throw BiologicalDataError.invalidLocator(canonicalDescription)
            }
        case .modelDB(let accession, _):
            guard accession > 0 else {
                throw BiologicalDataError.invalidLocator(canonicalDescription)
            }
        case .local(let path):
            guard !path.isEmpty else {
                throw BiologicalDataError.invalidLocator(canonicalDescription)
            }
        }
        return self
    }
}

public enum DataCompression: String, Codable, Sendable, CaseIterable {
    case none
    case gzip
    case zstd
    case blosc
    case lzf
    case zip
    case custom
}

public enum DataStorageEncoding: String, Codable, Sendable, CaseIterable {
    case arrow
    case csv
    case hdf5
    case json
    case n5
    case neuroglancerPrecomputed
    case nwb
    case parquet
    case sonata
    case swc
    case tensorStore
    case xml
    case zarr
    case opaque
}

public enum CoordinateHandedness: String, Codable, Sendable, CaseIterable {
    case rightHanded
    case leftHanded
    case unspecified
}

public enum CoordinateAxisDirection: String, Codable, Sendable, CaseIterable {
    case leftToRight
    case rightToLeft
    case posteriorToAnterior
    case anteriorToPosterior
    case inferiorToSuperior
    case superiorToInferior
    case depthPositive
    case depthNegative
    case unspecified
}

public struct CoordinateFrame: Codable, Sendable, Equatable {
    public var identifier: String
    public var unit: BiologicalUnit
    public var axes: [CoordinateAxisDirection]
    public var handedness: CoordinateHandedness
    public var affineToCanonical: [Double]
    public var voxelSize: [Double]?
    public var metadata: [String: String]

    public init(
        identifier: String,
        unit: BiologicalUnit,
        axes: [CoordinateAxisDirection] = [
            .leftToRight,
            .posteriorToAnterior,
            .inferiorToSuperior
        ],
        handedness: CoordinateHandedness = .rightHanded,
        affineToCanonical: [Double] = CoordinateFrame.identityAffine,
        voxelSize: [Double]? = nil,
        metadata: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.unit = unit
        self.axes = axes
        self.handedness = handedness
        self.affineToCanonical = affineToCanonical
        self.voxelSize = voxelSize
        self.metadata = metadata
    }

    public static let identityAffine: [Double] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ]

    public static let canonicalMicrometers = Self(
        identifier: "numitissue-canonical-micrometers",
        unit: .micrometer
    )

    public func validated() throws -> Self {
        guard !identifier.isEmpty,
              unit.dimension == .length,
              axes.count == 3,
              affineToCanonical.count == 16,
              affineToCanonical.allSatisfy(\.isFinite) else {
            throw BiologicalDataError.invalidCoordinateFrame(identifier)
        }
        if let voxelSize {
            guard voxelSize.count == 3,
                  voxelSize.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw BiologicalDataError.invalidCoordinateFrame(identifier)
            }
        }
        return self
    }

    public func transformToCanonical(_ point: SIMD3<Double>) throws -> SIMD3<Double> {
        _ = try validated()
        let scale = try UnitConverter.multiplier(from: unit, to: .micrometer)
        let x = point.x * scale
        let y = point.y * scale
        let z = point.z * scale
        let m = affineToCanonical
        let tx = m[0] * x + m[1] * y + m[2] * z + m[3]
        let ty = m[4] * x + m[5] * y + m[6] * z + m[7]
        let tz = m[8] * x + m[9] * y + m[10] * z + m[11]
        let tw = m[12] * x + m[13] * y + m[14] * z + m[15]
        guard tx.isFinite, ty.isFinite, tz.isFinite, tw.isFinite, abs(tw) > 1e-15 else {
            throw BiologicalDataError.nonFiniteCoordinate(identifier)
        }
        return SIMD3<Double>(tx / tw, ty / tw, tz / tw)
    }
}

public struct CoordinateBounds: Codable, Sendable, Equatable {
    public var minimum: [Double]
    public var maximum: [Double]
    public var frameID: String

    public init(minimum: [Double], maximum: [Double], frameID: String) {
        self.minimum = minimum
        self.maximum = maximum
        self.frameID = frameID
    }

    public func validated() throws -> Self {
        guard minimum.count == 3,
              maximum.count == 3,
              !frameID.isEmpty,
              minimum.allSatisfy(\.isFinite),
              maximum.allSatisfy(\.isFinite),
              zip(minimum, maximum).allSatisfy({ pair in pair.0 <= pair.1 }) else {
            throw BiologicalDataError.invalidCoordinateBounds(frameID)
        }
        return self
    }

    public func contains(_ point: SIMD3<Double>) -> Bool {
        guard minimum.count == 3, maximum.count == 3 else { return false }
        return point.x >= minimum[0] && point.x <= maximum[0] &&
            point.y >= minimum[1] && point.y <= maximum[1] &&
            point.z >= minimum[2] && point.z <= maximum[2]
    }
}

public enum BiologicalSex: String, Codable, Sendable, CaseIterable {
    case female
    case male
    case mixed
    case intersex
    case unknown
    case notApplicable
}

public struct SpecimenIdentity: Codable, Sendable, Equatable {
    public var species: OntologyTerm
    public var strain: String?
    public var biologicalSex: BiologicalSex
    public var age: UnitValue?
    public var developmentalStage: OntologyTerm?
    public var donorID: String?
    public var specimenID: String?
    public var sampleID: String?
    public var brainRegion: OntologyTerm?
    public var hemisphere: String?
    public var preparation: String?
    public var metadata: [String: String]

    public init(
        species: OntologyTerm,
        strain: String? = nil,
        biologicalSex: BiologicalSex = .unknown,
        age: UnitValue? = nil,
        developmentalStage: OntologyTerm? = nil,
        donorID: String? = nil,
        specimenID: String? = nil,
        sampleID: String? = nil,
        brainRegion: OntologyTerm? = nil,
        hemisphere: String? = nil,
        preparation: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.species = species
        self.strain = strain
        self.biologicalSex = biologicalSex
        self.age = age
        self.developmentalStage = developmentalStage
        self.donorID = donorID
        self.specimenID = specimenID
        self.sampleID = sampleID
        self.brainRegion = brainRegion
        self.hemisphere = hemisphere
        self.preparation = preparation
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        _ = try species.validated()
        if let age {
            guard age.unit.dimension == .time, age.value >= 0 else {
                throw BiologicalDataError.invalidSpecimen(specimenID ?? sampleID ?? species.curie)
            }
            _ = try age.validated()
        }
        if let developmentalStage { _ = try developmentalStage.validated() }
        if let brainRegion { _ = try brainRegion.validated() }
        return self
    }
}

public struct DataAsset: Codable, Sendable, Equatable {
    public var id: String
    public var dataset: DatasetVersion
    public var modalities: Set<BiologicalDataModality>
    public var locator: DataLocator
    public var byteRange: ByteRange?
    public var mediaType: String
    public var encoding: DataStorageEncoding
    public var compression: DataCompression
    public var byteCount: UInt64?
    public var checksum: String?
    public var coordinateFrame: CoordinateFrame?
    public var specimen: SpecimenIdentity?
    public var dependencies: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        dataset: DatasetVersion,
        modalities: Set<BiologicalDataModality>,
        locator: DataLocator,
        byteRange: ByteRange? = nil,
        mediaType: String,
        encoding: DataStorageEncoding,
        compression: DataCompression = .none,
        byteCount: UInt64? = nil,
        checksum: String? = nil,
        coordinateFrame: CoordinateFrame? = nil,
        specimen: SpecimenIdentity? = nil,
        dependencies: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.dataset = dataset
        self.modalities = modalities
        self.locator = locator
        self.byteRange = byteRange
        self.mediaType = mediaType
        self.encoding = encoding
        self.compression = compression
        self.byteCount = byteCount
        self.checksum = checksum
        self.coordinateFrame = coordinateFrame
        self.specimen = specimen
        self.dependencies = dependencies
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty,
              !modalities.isEmpty,
              !mediaType.isEmpty,
              byteCount.map({ $0 > 0 }) ?? true else {
            throw BiologicalDataError.invalidAsset(id)
        }
        _ = try dataset.validated()
        _ = try locator.validated()
        if let byteRange { _ = try byteRange.validated() }
        if let coordinateFrame { _ = try coordinateFrame.validated() }
        if let specimen { _ = try specimen.validated() }
        guard !dependencies.contains(id) else {
            throw BiologicalDataError.selfReferentialAsset(id)
        }
        return self
    }
}

public struct AssetPartition: Codable, Sendable, Equatable {
    public var id: String
    public var assetID: String
    public var byteRange: ByteRange?
    public var bounds: CoordinateBounds?
    public var rowOffset: UInt64?
    public var rowCount: UInt64?
    public var chunkCoordinates: [Int64]?
    public var entityIDs: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        assetID: String,
        byteRange: ByteRange? = nil,
        bounds: CoordinateBounds? = nil,
        rowOffset: UInt64? = nil,
        rowCount: UInt64? = nil,
        chunkCoordinates: [Int64]? = nil,
        entityIDs: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.assetID = assetID
        self.byteRange = byteRange
        self.bounds = bounds
        self.rowOffset = rowOffset
        self.rowCount = rowCount
        self.chunkCoordinates = chunkCoordinates
        self.entityIDs = entityIDs
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty, !assetID.isEmpty else {
            throw BiologicalDataError.invalidPartition(id)
        }
        if let byteRange { _ = try byteRange.validated() }
        if let bounds { _ = try bounds.validated() }
        if let rowCount, rowCount == 0 {
            throw BiologicalDataError.invalidPartition(id)
        }
        return self
    }
}

public struct DatasetManifest: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var dataset: DatasetVersion
    public var coordinateFrames: [CoordinateFrame]
    public var assets: [DataAsset]
    public var partitions: [AssetPartition]
    public var provenance: ProvenanceGraph
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        dataset: DatasetVersion,
        coordinateFrames: [CoordinateFrame] = [],
        assets: [DataAsset],
        partitions: [AssetPartition] = [],
        provenance: ProvenanceGraph = ProvenanceGraph(),
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.dataset = dataset
        self.coordinateFrames = coordinateFrames
        self.assets = assets
        self.partitions = partitions
        self.provenance = provenance
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw BiologicalDataError.unsupportedSchema(schemaVersion)
        }
        _ = try dataset.validated()
        guard Set(assets.map(\.id)).count == assets.count,
              Set(coordinateFrames.map(\.identifier)).count == coordinateFrames.count,
              Set(partitions.map(\.id)).count == partitions.count else {
            throw BiologicalDataError.duplicateManifestIdentifier
        }
        let assetIDs = Set(assets.map(\.id))
        for frame in coordinateFrames { _ = try frame.validated() }
        for asset in assets {
            _ = try asset.validated()
            guard asset.dataset.stableReference == dataset.stableReference else {
                throw BiologicalDataError.mixedDatasetManifest(asset.id)
            }
            if let frameID = asset.coordinateFrame?.identifier,
               !coordinateFrames.contains(where: { $0.identifier == frameID }) {
                throw BiologicalDataError.unknownCoordinateFrame(frameID)
            }
            guard asset.dependencies.allSatisfy(assetIDs.contains) else {
                throw BiologicalDataError.unknownAssetDependency(asset.id)
            }
        }
        for partition in partitions {
            _ = try partition.validated()
            guard assetIDs.contains(partition.assetID) else {
                throw BiologicalDataError.unknownAssetDependency(partition.assetID)
            }
        }
        _ = try provenance.validated()
        return self
    }
}

public enum BiologicalDataError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidLicense(String)
    case invalidDatasetReference(String)
    case missingMaterializationVersion(String)
    case invalidByteRange(offset: UInt64, length: UInt64)
    case invalidLocator(String)
    case invalidCoordinateFrame(String)
    case nonFiniteCoordinate(String)
    case invalidCoordinateBounds(String)
    case invalidSpecimen(String)
    case invalidAsset(String)
    case selfReferentialAsset(String)
    case invalidPartition(String)
    case duplicateManifestIdentifier
    case mixedDatasetManifest(String)
    case unknownCoordinateFrame(String)
    case unknownAssetDependency(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let value):
            return "Unsupported biological data schema \(value)."
        case .invalidLicense(let identifier):
            return "Dataset license \(identifier) is invalid."
        case .invalidDatasetReference(let reference):
            return "Dataset reference \(reference) is invalid."
        case .missingMaterializationVersion(let reference):
            return "Materialized dataset \(reference) has no materialization version."
        case .invalidByteRange(let offset, let length):
            return "Byte range \(offset)..<\(offset &+ length) is invalid."
        case .invalidLocator(let value):
            return "Data locator \(value) is invalid."
        case .invalidCoordinateFrame(let identifier):
            return "Coordinate frame \(identifier) is invalid."
        case .nonFiniteCoordinate(let identifier):
            return "Coordinate frame \(identifier) produced a non-finite coordinate."
        case .invalidCoordinateBounds(let identifier):
            return "Coordinate bounds in frame \(identifier) are invalid."
        case .invalidSpecimen(let identifier):
            return "Specimen \(identifier) is invalid."
        case .invalidAsset(let identifier):
            return "Data asset \(identifier) is invalid."
        case .selfReferentialAsset(let identifier):
            return "Data asset \(identifier) depends on itself."
        case .invalidPartition(let identifier):
            return "Asset partition \(identifier) is invalid."
        case .duplicateManifestIdentifier:
            return "Dataset manifest contains duplicate identifiers."
        case .mixedDatasetManifest(let identifier):
            return "Asset \(identifier) belongs to a different dataset release."
        case .unknownCoordinateFrame(let identifier):
            return "Coordinate frame \(identifier) is not declared by the manifest."
        case .unknownAssetDependency(let identifier):
            return "Asset dependency \(identifier) is not declared by the manifest."
        }
    }
}
