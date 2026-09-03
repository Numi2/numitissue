import Foundation
import NumiTissueIO

public enum ScientificCorpusEntryKind: String, Codable, Sendable, CaseIterable, Hashable {
    case electrophysiologyModel
    case networkModel
    case extracellularRecording
    case molecularModel
    case meaDataset
    case longitudinalOrganoidDataset
    case morphologyConnectivity
    case conformanceFixture
}

public enum ScientificCorpusReadiness: String, Codable, Sendable, CaseIterable, Hashable {
    case declared
    case sourcePinned
    case materialized
    case verified
}

public enum ScientificCorpusValidationMode: String, Codable, Sendable, CaseIterable, Hashable {
    case development
    case publishable
    case materialized
}

public struct ScientificCorpusPolicy: Codable, Sendable, Hashable {
    public var mode: ScientificCorpusValidationMode
    public var requireImmutableSources: Bool
    public var requireResolvedLicense: Bool
    public var requireSHA256ForEveryAsset: Bool
    public var requireEvidenceCases: Bool
    public var maximumEntries: Int
    public var maximumAssetsPerEntry: Int
    public var maximumDeclaredBytes: UInt64

    public init(
        mode: ScientificCorpusValidationMode,
        requireImmutableSources: Bool,
        requireResolvedLicense: Bool,
        requireSHA256ForEveryAsset: Bool,
        requireEvidenceCases: Bool,
        maximumEntries: Int = 10_000,
        maximumAssetsPerEntry: Int = 100_000,
        maximumDeclaredBytes: UInt64 = 1_125_899_906_842_624
    ) {
        self.mode = mode
        self.requireImmutableSources = requireImmutableSources
        self.requireResolvedLicense = requireResolvedLicense
        self.requireSHA256ForEveryAsset = requireSHA256ForEveryAsset
        self.requireEvidenceCases = requireEvidenceCases
        self.maximumEntries = maximumEntries
        self.maximumAssetsPerEntry = maximumAssetsPerEntry
        self.maximumDeclaredBytes = maximumDeclaredBytes
    }

    public static let development = Self(
        mode: .development,
        requireImmutableSources: false,
        requireResolvedLicense: false,
        requireSHA256ForEveryAsset: false,
        requireEvidenceCases: false
    )

    public static let publishable = Self(
        mode: .publishable,
        requireImmutableSources: true,
        requireResolvedLicense: true,
        requireSHA256ForEveryAsset: true,
        requireEvidenceCases: true
    )

    public static let materialized = Self(
        mode: .materialized,
        requireImmutableSources: true,
        requireResolvedLicense: true,
        requireSHA256ForEveryAsset: true,
        requireEvidenceCases: true
    )

    public func validated() throws -> Self {
        guard maximumEntries > 0,
              maximumEntries <= 1_000_000,
              maximumAssetsPerEntry > 0,
              maximumAssetsPerEntry <= 10_000_000,
              maximumDeclaredBytes > 0 else {
            throw ScientificCorpusError.invalidPolicy
        }
        return self
    }
}

public struct ScientificSelectionPin: Codable, Sendable, Equatable {
    public var queryLanguage: String
    public var canonicalQuery: String
    public var bounded: Bool
    public var expectedEntityCount: UInt64?
    public var assetPaths: [String]
    public var subjectIDs: [String]
    public var coordinateBounds: CoordinateBounds?
    public var metadata: [String: String]

    public init(
        queryLanguage: String,
        canonicalQuery: String,
        bounded: Bool,
        expectedEntityCount: UInt64? = nil,
        assetPaths: [String] = [],
        subjectIDs: [String] = [],
        coordinateBounds: CoordinateBounds? = nil,
        metadata: [String: String] = [:]
    ) {
        self.queryLanguage = queryLanguage
        self.canonicalQuery = canonicalQuery
        self.bounded = bounded
        self.expectedEntityCount = expectedEntityCount
        self.assetPaths = assetPaths
        self.subjectIDs = subjectIDs
        self.coordinateBounds = coordinateBounds
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !queryLanguage.isEmpty,
              !canonicalQuery.isEmpty,
              expectedEntityCount.map({ $0 > 0 }) ?? true,
              assetPaths.allSatisfy({ !$0.isEmpty }),
              subjectIDs.allSatisfy({ !$0.isEmpty }),
              Set(assetPaths).count == assetPaths.count,
              Set(subjectIDs).count == subjectIDs.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidSelection(canonicalQuery)
        }
        if let coordinateBounds { _ = try coordinateBounds.validated() }
        return self
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(validated())
        )
    }
}

public struct ScientificSourcePin: Codable, Sendable, Equatable {
    public var dataset: DatasetVersion
    public var selection: ScientificSelectionPin
    public var upstreamCommit: String?
    public var upstreamTag: String?
    public var sourceSchemaVersion: String?
    public var metadata: [String: String]

    public init(
        dataset: DatasetVersion,
        selection: ScientificSelectionPin,
        upstreamCommit: String? = nil,
        upstreamTag: String? = nil,
        sourceSchemaVersion: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.dataset = dataset
        self.selection = selection
        self.upstreamCommit = upstreamCommit
        self.upstreamTag = upstreamTag
        self.sourceSchemaVersion = sourceSchemaVersion
        self.metadata = metadata
    }

    public func validated(policy: ScientificCorpusPolicy) throws -> Self {
        _ = try dataset.validated()
        _ = try selection.validated()
        guard upstreamCommit?.isEmpty != true,
              upstreamTag?.isEmpty != true,
              sourceSchemaVersion?.isEmpty != true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidSource(dataset.stableReference)
        }
        if policy.requireImmutableSources {
            let release = dataset.release.lowercased()
            guard dataset.stability != .mutableLatest,
                  release != "latest",
                  release != "draft",
                  selection.bounded else {
                throw ScientificCorpusError.mutableSource(dataset.stableReference)
            }
        }
        if policy.requireResolvedLicense {
            guard dataset.license.identifier != DatasetLicense.unknown.identifier,
                  dataset.license.identifier != "NOASSERTION" else {
                throw ScientificCorpusError.unresolvedLicense(
                    dataset.stableReference
                )
            }
        }
        return self
    }
}

public enum ScientificDecoderPath: String, Codable, Sendable, CaseIterable, Hashable {
    case native
    case sidecar
}

public struct ScientificDecoderPin: Codable, Sendable, Hashable {
    public var identifier: String
    public var version: String
    public var path: ScientificDecoderPath
    public var outputSchema: String
    public var deterministic: Bool
    public var configurationSHA256: ScientificSHA256Digest
    public var sidecarToolchain: ScientificSidecarToolchainPin?
    public var metadata: [String: String]

    public init(
        identifier: String,
        version: String,
        path: ScientificDecoderPath,
        outputSchema: String,
        deterministic: Bool,
        configurationSHA256: ScientificSHA256Digest,
        sidecarToolchain: ScientificSidecarToolchainPin? = nil,
        metadata: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.version = version
        self.path = path
        self.outputSchema = outputSchema
        self.deterministic = deterministic
        self.configurationSHA256 = configurationSHA256
        self.sidecarToolchain = sidecarToolchain
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty,
              !version.isEmpty,
              !outputSchema.isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidDecoder(identifier)
        }
        switch path {
        case .native:
            guard sidecarToolchain == nil else {
                throw ScientificCorpusError.invalidDecoder(identifier)
            }
        case .sidecar:
            guard let sidecarToolchain else {
                throw ScientificCorpusError.invalidDecoder(identifier)
            }
            _ = try sidecarToolchain.validated()
        }
        return self
    }
}

public struct ScientificAssetPin: Codable, Sendable, Equatable {
    public var id: String
    public var role: String
    public var relativePath: String
    public var locator: DataLocator
    public var mediaType: String
    public var encoding: DataStorageEncoding
    public var compression: DataCompression
    public var byteCount: UInt64?
    public var sha256: ScientificSHA256Digest?
    public var sourceChecksum: String?
    public var decoder: ScientificDecoderPin
    public var dependencies: [String]
    public var metadata: [String: String]

    public init(
        id: String,
        role: String,
        relativePath: String,
        locator: DataLocator,
        mediaType: String,
        encoding: DataStorageEncoding,
        compression: DataCompression = .none,
        byteCount: UInt64? = nil,
        sha256: ScientificSHA256Digest? = nil,
        sourceChecksum: String? = nil,
        decoder: ScientificDecoderPin,
        dependencies: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.role = role
        self.relativePath = relativePath
        self.locator = locator
        self.mediaType = mediaType
        self.encoding = encoding
        self.compression = compression
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sourceChecksum = sourceChecksum
        self.decoder = decoder
        self.dependencies = dependencies
        self.metadata = metadata
    }

    public func validated(policy: ScientificCorpusPolicy) throws -> Self {
        guard !id.isEmpty,
              !role.isEmpty,
              ScientificCorpusFileSystem.isSafeRelative(relativePath),
              !mediaType.isEmpty,
              byteCount.map({ $0 > 0 }) ?? true,
              sourceChecksum?.isEmpty != true,
              dependencies.allSatisfy({ !$0.isEmpty }),
              Set(dependencies).count == dependencies.count,
              !dependencies.contains(id),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidAsset(id)
        }
        _ = try locator.validated()
        _ = try decoder.validated()
        if policy.requireSHA256ForEveryAsset, sha256 == nil {
            throw ScientificCorpusError.missingSHA256(id)
        }
        if policy.mode == .materialized, byteCount == nil {
            throw ScientificCorpusError.missingByteCount(id)
        }
        return self
    }
}

public struct ScientificTransformationPin: Codable, Sendable, Hashable {
    public var ordinal: Int
    public var identifier: String
    public var implementation: String
    public var implementationVersion: String
    public var configurationSHA256: ScientificSHA256Digest
    public var inputAssetIDs: [String]
    public var outputAssetIDs: [String]
    public var declaredApproximation: String?
    public var metadata: [String: String]

    public init(
        ordinal: Int,
        identifier: String,
        implementation: String,
        implementationVersion: String,
        configurationSHA256: ScientificSHA256Digest,
        inputAssetIDs: [String],
        outputAssetIDs: [String],
        declaredApproximation: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.ordinal = ordinal
        self.identifier = identifier
        self.implementation = implementation
        self.implementationVersion = implementationVersion
        self.configurationSHA256 = configurationSHA256
        self.inputAssetIDs = inputAssetIDs
        self.outputAssetIDs = outputAssetIDs
        self.declaredApproximation = declaredApproximation
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ordinal >= 0,
              !identifier.isEmpty,
              !implementation.isEmpty,
              !implementationVersion.isEmpty,
              !inputAssetIDs.isEmpty,
              !outputAssetIDs.isEmpty,
              inputAssetIDs.allSatisfy({ !$0.isEmpty }),
              outputAssetIDs.allSatisfy({ !$0.isEmpty }),
              Set(inputAssetIDs).count == inputAssetIDs.count,
              Set(outputAssetIDs).count == outputAssetIDs.count,
              declaredApproximation?.isEmpty != true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidTransformation(identifier)
        }
        return self
    }
}

public struct ScientificExclusionPin: Codable, Sendable, Hashable {
    public var identifier: String
    public var selector: String
    public var reason: String
    public var affectedAssetIDs: [String]
    public var metadata: [String: String]

    public init(
        identifier: String,
        selector: String,
        reason: String,
        affectedAssetIDs: [String],
        metadata: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.selector = selector
        self.reason = reason
        self.affectedAssetIDs = affectedAssetIDs
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty,
              !selector.isEmpty,
              !reason.isEmpty,
              !affectedAssetIDs.isEmpty,
              affectedAssetIDs.allSatisfy({ !$0.isEmpty }),
              Set(affectedAssetIDs).count == affectedAssetIDs.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidExclusion(identifier)
        }
        return self
    }
}

public struct ScientificUnitContract: Codable, Sendable, Hashable {
    public var quantity: String
    public var sourceUnit: String
    public var canonicalUnit: String
    public var multiplier: Double
    public var offset: Double
    public var authority: String
    public var metadata: [String: String]

    public init(
        quantity: String,
        sourceUnit: String,
        canonicalUnit: String,
        multiplier: Double,
        offset: Double = 0,
        authority: String,
        metadata: [String: String] = [:]
    ) {
        self.quantity = quantity
        self.sourceUnit = sourceUnit
        self.canonicalUnit = canonicalUnit
        self.multiplier = multiplier
        self.offset = offset
        self.authority = authority
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !quantity.isEmpty,
              !sourceUnit.isEmpty,
              !canonicalUnit.isEmpty,
              multiplier.isFinite,
              multiplier != 0,
              offset.isFinite,
              !authority.isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidUnitContract(quantity)
        }
        return self
    }
}

public struct ScientificFeatureContract: Codable, Sendable, Hashable {
    public var identifier: String
    public var extractor: String
    public var extractorVersion: String
    public var configurationSHA256: ScientificSHA256Digest
    public var outputUnit: String?
    public var aggregation: String
    public var reference: String?
    public var metadata: [String: String]

    public init(
        identifier: String,
        extractor: String,
        extractorVersion: String,
        configurationSHA256: ScientificSHA256Digest,
        outputUnit: String? = nil,
        aggregation: String,
        reference: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.extractor = extractor
        self.extractorVersion = extractorVersion
        self.configurationSHA256 = configurationSHA256
        self.outputUnit = outputUnit
        self.aggregation = aggregation
        self.reference = reference
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty,
              !extractor.isEmpty,
              !extractorVersion.isEmpty,
              outputUnit?.isEmpty != true,
              !aggregation.isEmpty,
              reference?.isEmpty != true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidFeatureContract(identifier)
        }
        return self
    }
}

public struct ScientificToleranceContract: Codable, Sendable, Hashable {
    public var identifier: String
    public var metric: String
    public var absolute: Double?
    public var relative: Double?
    public var maximumULPDistance: UInt64?
    public var confidenceLevel: Double?
    public var minimumSampleCount: Int?
    public var distributionTest: String?
    public var notes: String?

    public init(
        identifier: String,
        metric: String,
        absolute: Double? = nil,
        relative: Double? = nil,
        maximumULPDistance: UInt64? = nil,
        confidenceLevel: Double? = nil,
        minimumSampleCount: Int? = nil,
        distributionTest: String? = nil,
        notes: String? = nil
    ) {
        self.identifier = identifier
        self.metric = metric
        self.absolute = absolute
        self.relative = relative
        self.maximumULPDistance = maximumULPDistance
        self.confidenceLevel = confidenceLevel
        self.minimumSampleCount = minimumSampleCount
        self.distributionTest = distributionTest
        self.notes = notes
    }

    public func validated() throws -> Self {
        guard !identifier.isEmpty,
              !metric.isEmpty,
              absolute.map({ $0.isFinite && $0 >= 0 }) ?? true,
              relative.map({ $0.isFinite && $0 >= 0 }) ?? true,
              confidenceLevel.map({ $0.isFinite && $0 > 0 && $0 < 1 }) ?? true,
              minimumSampleCount.map({ $0 > 0 }) ?? true,
              distributionTest?.isEmpty != true,
              notes?.isEmpty != true,
              absolute != nil || relative != nil ||
                maximumULPDistance != nil || distributionTest != nil else {
            throw ScientificCorpusError.invalidTolerance(identifier)
        }
        return self
    }
}

public struct ScientificCorpusEntry: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var id: String
    public var title: String
    public var kind: ScientificCorpusEntryKind
    public var readiness: ScientificCorpusReadiness
    public var source: ScientificSourcePin
    public var assets: [ScientificAssetPin]
    public var transformations: [ScientificTransformationPin]
    public var exclusions: [ScientificExclusionPin]
    public var units: [ScientificUnitContract]
    public var features: [ScientificFeatureContract]
    public var tolerances: [ScientificToleranceContract]
    public var evidenceCaseIDs: [String]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        id: String,
        title: String,
        kind: ScientificCorpusEntryKind,
        readiness: ScientificCorpusReadiness,
        source: ScientificSourcePin,
        assets: [ScientificAssetPin],
        transformations: [ScientificTransformationPin] = [],
        exclusions: [ScientificExclusionPin] = [],
        units: [ScientificUnitContract] = [],
        features: [ScientificFeatureContract] = [],
        tolerances: [ScientificToleranceContract] = [],
        evidenceCaseIDs: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.kind = kind
        self.readiness = readiness
        self.source = source
        self.assets = assets
        self.transformations = transformations
        self.exclusions = exclusions
        self.units = units
        self.features = features
        self.tolerances = tolerances
        self.evidenceCaseIDs = evidenceCaseIDs
        self.metadata = metadata
    }

    public func validated(
        policy sourcePolicy: ScientificCorpusPolicy = .development
    ) throws -> Self {
        let policy = try sourcePolicy.validated()
        guard schemaVersion == 1,
              !id.isEmpty,
              !title.isEmpty,
              !assets.isEmpty,
              assets.count <= policy.maximumAssetsPerEntry,
              evidenceCaseIDs.allSatisfy({ !$0.isEmpty }),
              Set(evidenceCaseIDs).count == evidenceCaseIDs.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidEntry(id)
        }
        _ = try source.validated(policy: policy)
        for asset in assets { _ = try asset.validated(policy: policy) }
        let assetIDs = Set(assets.map(\.id))
        guard assetIDs.count == assets.count else {
            throw ScientificCorpusError.duplicateAsset(id)
        }
        for asset in assets where !asset.dependencies.allSatisfy(assetIDs.contains) {
            throw ScientificCorpusError.unknownAssetDependency(asset.id)
        }

        let ordinals = transformations.map(\.ordinal)
        guard Set(ordinals).count == ordinals.count else {
            throw ScientificCorpusError.duplicateTransformationOrdinal(id)
        }
        for transformation in transformations {
            _ = try transformation.validated()
            guard transformation.inputAssetIDs.allSatisfy(assetIDs.contains),
                  transformation.outputAssetIDs.allSatisfy(assetIDs.contains) else {
                throw ScientificCorpusError.unknownTransformationAsset(
                    transformation.identifier
                )
            }
        }
        for exclusion in exclusions {
            _ = try exclusion.validated()
            guard exclusion.affectedAssetIDs.allSatisfy(assetIDs.contains) else {
                throw ScientificCorpusError.unknownExclusionAsset(
                    exclusion.identifier
                )
            }
        }
        for unit in units { _ = try unit.validated() }
        for feature in features { _ = try feature.validated() }
        for tolerance in tolerances { _ = try tolerance.validated() }
        guard Set(features.map(\.identifier)).count == features.count,
              Set(tolerances.map(\.identifier)).count == tolerances.count else {
            throw ScientificCorpusError.duplicateScientificContract(id)
        }
        if policy.requireEvidenceCases, evidenceCaseIDs.isEmpty {
            throw ScientificCorpusError.missingEvidence(id)
        }

        switch readiness {
        case .declared:
            guard policy.mode == .development else {
                throw ScientificCorpusError.readinessTooLow(id)
            }
        case .sourcePinned:
            guard policy.mode != .materialized else {
                throw ScientificCorpusError.readinessTooLow(id)
            }
        case .materialized:
            guard policy.mode != .materialized || assets.allSatisfy({
                $0.sha256 != nil && $0.byteCount != nil
            }) else {
                throw ScientificCorpusError.readinessTooLow(id)
            }
        case .verified:
            break
        }
        return self
    }

    public func sha256(
        policy: ScientificCorpusPolicy = .development
    ) throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                validated(policy: policy)
            )
        )
    }
}

public struct ScientificCorpusManifest: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var corpusID: String
    public var title: String
    public var version: String
    public var conformanceMatrixSHA256: ScientificSHA256Digest
    public var entries: [ScientificCorpusEntry]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        corpusID: String,
        title: String,
        version: String,
        conformanceMatrixSHA256: ScientificSHA256Digest,
        entries: [ScientificCorpusEntry],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.corpusID = corpusID
        self.title = title
        self.version = version
        self.conformanceMatrixSHA256 = conformanceMatrixSHA256
        self.entries = entries
        self.metadata = metadata
    }

    public func validated(
        policy sourcePolicy: ScientificCorpusPolicy = .development
    ) throws -> Self {
        let policy = try sourcePolicy.validated()
        guard schemaVersion == 1,
              !corpusID.isEmpty,
              !title.isEmpty,
              !version.isEmpty,
              !entries.isEmpty,
              entries.count <= policy.maximumEntries,
              Set(entries.map(\.id)).count == entries.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificCorpusError.invalidManifest(corpusID)
        }
        var totalBytes: UInt64 = 0
        for entry in entries {
            _ = try entry.validated(policy: policy)
            for asset in entry.assets {
                guard let byteCount = asset.byteCount else { continue }
                let addition = totalBytes.addingReportingOverflow(byteCount)
                guard !addition.overflow,
                      addition.partialValue <= policy.maximumDeclaredBytes else {
                    throw ScientificCorpusError.declaredBytesExceeded
                }
                totalBytes = addition.partialValue
            }
        }
        return self
    }

    public func canonicalData(
        policy: ScientificCorpusPolicy = .development
    ) throws -> Data {
        try ScientificCanonicalJSON.encode(validated(policy: policy))
    }

    public func sha256(
        policy: ScientificCorpusPolicy = .development
    ) throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData(policy: policy))
    }

    public static func read(
        from url: URL,
        policy: ScientificCorpusPolicy = .development
    ) throws -> Self {
        let value = try ScientificCanonicalJSON.decode(
            Self.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe])
        )
        return try value.validated(policy: policy)
    }

    public func write(
        to url: URL,
        policy: ScientificCorpusPolicy = .development,
        overwrite: Bool = false
    ) throws {
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw ScientificCorpusError.destinationExists(url.path)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try canonicalData(policy: policy).write(to: url, options: [.atomic])
    }
}

public enum ScientificCorpusFileSystem {
    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    public static func resolve(
        _ relativePath: String,
        under root: URL,
        requireExistingParent: Bool = true
    ) throws -> URL {
        guard isSafeRelative(relativePath) else {
            throw ScientificCorpusError.unsafePath(relativePath)
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        let canonicalParent = requireExistingParent
            ? parent.resolvingSymlinksInPath()
            : parent.standardizedFileURL
        guard canonicalParent.path == canonicalRoot.path ||
                canonicalParent.path.hasPrefix(canonicalRoot.path + "/") else {
            throw ScientificCorpusError.unsafePath(relativePath)
        }
        return candidate
    }
}

public enum ScientificCorpusError: Error, Sendable, CustomStringConvertible {
    case invalidPolicy
    case invalidSelection(String)
    case invalidSource(String)
    case mutableSource(String)
    case unresolvedLicense(String)
    case invalidDecoder(String)
    case invalidAsset(String)
    case missingSHA256(String)
    case missingByteCount(String)
    case invalidTransformation(String)
    case invalidExclusion(String)
    case invalidUnitContract(String)
    case invalidFeatureContract(String)
    case invalidTolerance(String)
    case invalidEntry(String)
    case duplicateAsset(String)
    case unknownAssetDependency(String)
    case duplicateTransformationOrdinal(String)
    case unknownTransformationAsset(String)
    case unknownExclusionAsset(String)
    case duplicateScientificContract(String)
    case missingEvidence(String)
    case readinessTooLow(String)
    case invalidManifest(String)
    case declaredBytesExceeded
    case unsafePath(String)
    case destinationExists(String)

    public var description: String {
        switch self {
        case .invalidPolicy:
            return "The scientific corpus policy is invalid."
        case .invalidSelection(let query):
            return "The scientific selection is invalid: \(query)."
        case .invalidSource(let reference):
            return "The scientific source pin is invalid: \(reference)."
        case .mutableSource(let reference):
            return "The scientific source is mutable or unbounded: \(reference)."
        case .unresolvedLicense(let reference):
            return "The scientific source license is unresolved: \(reference)."
        case .invalidDecoder(let identifier):
            return "The scientific decoder pin is invalid: \(identifier)."
        case .invalidAsset(let identifier):
            return "The scientific asset pin is invalid: \(identifier)."
        case .missingSHA256(let identifier):
            return "Scientific asset \(identifier) has no SHA-256 pin."
        case .missingByteCount(let identifier):
            return "Materialized scientific asset \(identifier) has no byte count."
        case .invalidTransformation(let identifier):
            return "Scientific transformation \(identifier) is invalid."
        case .invalidExclusion(let identifier):
            return "Scientific exclusion \(identifier) is invalid."
        case .invalidUnitContract(let quantity):
            return "Scientific unit contract \(quantity) is invalid."
        case .invalidFeatureContract(let identifier):
            return "Scientific feature contract \(identifier) is invalid."
        case .invalidTolerance(let identifier):
            return "Scientific tolerance \(identifier) is invalid."
        case .invalidEntry(let identifier):
            return "Scientific corpus entry \(identifier) is invalid."
        case .duplicateAsset(let entry):
            return "Scientific corpus entry \(entry) contains duplicate assets."
        case .unknownAssetDependency(let asset):
            return "Scientific asset \(asset) has an unknown dependency."
        case .duplicateTransformationOrdinal(let entry):
            return "Scientific corpus entry \(entry) has duplicate transformation ordinals."
        case .unknownTransformationAsset(let transformation):
            return "Scientific transformation \(transformation) references an unknown asset."
        case .unknownExclusionAsset(let exclusion):
            return "Scientific exclusion \(exclusion) references an unknown asset."
        case .duplicateScientificContract(let entry):
            return "Scientific corpus entry \(entry) has duplicate feature or tolerance contracts."
        case .missingEvidence(let entry):
            return "Scientific corpus entry \(entry) has no executable evidence case."
        case .readinessTooLow(let entry):
            return "Scientific corpus entry \(entry) is not ready for the requested validation mode."
        case .invalidManifest(let identifier):
            return "Scientific corpus manifest \(identifier) is invalid."
        case .declaredBytesExceeded:
            return "Scientific corpus declared bytes exceed the configured bound."
        case .unsafePath(let path):
            return "Scientific corpus path is unsafe: \(path)."
        case .destinationExists(let path):
            return "Scientific corpus destination already exists: \(path)."
        }
    }
}
