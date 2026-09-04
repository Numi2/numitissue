import Foundation

public enum ProspectiveFrozenArtifactRole: String, Sendable, Hashable, Codable, CaseIterable {
    case sourceTreeManifest = "source-tree-manifest"
    case model
    case parameters
    case checkpoint
    case executionConfiguration = "execution-configuration"
}

public struct ProspectiveFrozenArtifact: Sendable, Hashable, Codable {
    public var role: ProspectiveFrozenArtifactRole
    public var relativePath: String
    public var mediaType: String
    public var sha256: ScientificSHA256Digest
    public var byteCount: UInt64
    public var readOnly: Bool

    public init(
        role: ProspectiveFrozenArtifactRole,
        relativePath: String,
        mediaType: String,
        sha256: ScientificSHA256Digest,
        byteCount: UInt64,
        readOnly: Bool
    ) {
        self.role = role
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.sha256 = sha256
        self.byteCount = byteCount
        self.readOnly = readOnly
    }

    public func validated() throws -> Self {
        guard ProspectiveFreezePath.isSafeRelative(relativePath),
              !mediaType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              byteCount > 0,
              readOnly else {
            throw ProspectiveModelFreezeError.invalidArtifact(role)
        }
        return self
    }
}

public struct ProspectiveModelFreezeBundle: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var certificate: ProspectiveModelFreezeCertificate
    public var artifacts: [ProspectiveFrozenArtifact]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        certificate: ProspectiveModelFreezeCertificate,
        artifacts: [ProspectiveFrozenArtifact],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.certificate = certificate
        self.artifacts = artifacts
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        let certificate = try certificate.validated()
        guard schemaVersion == 1,
              artifacts.count == ProspectiveFrozenArtifactRole.allCases.count,
              Set(artifacts.map(\.role)).count == artifacts.count,
              Set(artifacts.map(\.relativePath)).count == artifacts.count,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveModelFreezeError.invalidBundle
        }
        for artifact in artifacts { _ = try artifact.validated() }
        let byRole = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.role, $0) })
        guard byRole[.sourceTreeManifest]?.sha256 == certificate.sourceTreeSHA256,
              byRole[.model]?.sha256 == certificate.modelSHA256,
              byRole[.parameters]?.sha256 == certificate.parametersSHA256,
              byRole[.checkpoint]?.sha256 == certificate.checkpointSHA256,
              byRole[.executionConfiguration]?.sha256 == certificate.executionConfigurationSHA256 else {
            throw ProspectiveModelFreezeError.bundleCertificateMismatch
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public struct ProspectiveModelFreezeRequest: Sendable {
    public var rootURL: URL
    public var name: String
    public var frozenAt: Date
    public var calibrationDataCutoff: Date
    public var sourceRepository: String
    public var sourceCommit: String
    public var simulatorVersion: String
    public var numericalProfile: String
    public var backend: String
    public var sourceTreeManifestPath: String
    public var modelPath: String
    public var parametersPath: String
    public var checkpointPath: String
    public var executionConfigurationPath: String
    public var trainingCorpusSHA256: [ScientificSHA256Digest]
    public var calibrationEvidenceSHA256: [ScientificSHA256Digest]
    public var validationEvidenceSHA256: [ScientificSHA256Digest]
    public var sourceTreeDirty: Bool
    public var maximumArtifactBytes: UInt64
    public var metadata: [String: String]

    public init(
        rootURL: URL,
        name: String,
        frozenAt: Date,
        calibrationDataCutoff: Date,
        sourceRepository: String,
        sourceCommit: String,
        simulatorVersion: String,
        numericalProfile: String,
        backend: String,
        sourceTreeManifestPath: String,
        modelPath: String,
        parametersPath: String,
        checkpointPath: String,
        executionConfigurationPath: String,
        trainingCorpusSHA256: [ScientificSHA256Digest],
        calibrationEvidenceSHA256: [ScientificSHA256Digest],
        validationEvidenceSHA256: [ScientificSHA256Digest],
        sourceTreeDirty: Bool,
        maximumArtifactBytes: UInt64 = 1_099_511_627_776,
        metadata: [String: String] = [:]
    ) {
        self.rootURL = rootURL
        self.name = name
        self.frozenAt = frozenAt
        self.calibrationDataCutoff = calibrationDataCutoff
        self.sourceRepository = sourceRepository
        self.sourceCommit = sourceCommit
        self.simulatorVersion = simulatorVersion
        self.numericalProfile = numericalProfile
        self.backend = backend
        self.sourceTreeManifestPath = sourceTreeManifestPath
        self.modelPath = modelPath
        self.parametersPath = parametersPath
        self.checkpointPath = checkpointPath
        self.executionConfigurationPath = executionConfigurationPath
        self.trainingCorpusSHA256 = trainingCorpusSHA256
        self.calibrationEvidenceSHA256 = calibrationEvidenceSHA256
        self.validationEvidenceSHA256 = validationEvidenceSHA256
        self.sourceTreeDirty = sourceTreeDirty
        self.maximumArtifactBytes = maximumArtifactBytes
        self.metadata = metadata
    }
}

public enum ProspectiveModelFreezeBuilder {
    public static func build(
        _ request: ProspectiveModelFreezeRequest
    ) throws -> ProspectiveModelFreezeBundle {
        guard request.rootURL.isFileURL,
              !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.maximumArtifactBytes > 0,
              request.maximumArtifactBytes <= 1_099_511_627_776,
              request.metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveModelFreezeError.invalidRequest
        }
        let paths: [(ProspectiveFrozenArtifactRole, String, String)] = [
            (.sourceTreeManifest, request.sourceTreeManifestPath, "application/json"),
            (.model, request.modelPath, "application/octet-stream"),
            (.parameters, request.parametersPath, "application/json"),
            (.checkpoint, request.checkpointPath, "application/x-numitissue-checkpoint"),
            (.executionConfiguration, request.executionConfigurationPath, "application/json")
        ]
        let artifacts = try paths.map { role, path, mediaType in
            try inspect(
                role: role,
                relativePath: path,
                mediaType: mediaType,
                rootURL: request.rootURL,
                maximumBytes: request.maximumArtifactBytes
            )
        }
        let byRole = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.role, $0) })
        guard let sourceTree = byRole[.sourceTreeManifest],
              let model = byRole[.model],
              let parameters = byRole[.parameters],
              let checkpoint = byRole[.checkpoint],
              let configuration = byRole[.executionConfiguration] else {
            throw ProspectiveModelFreezeError.invalidBundle
        }
        let certificate = ProspectiveModelFreezeCertificate(
            name: request.name,
            frozenAt: request.frozenAt,
            calibrationDataCutoff: request.calibrationDataCutoff,
            sourceRepository: request.sourceRepository,
            sourceCommit: request.sourceCommit,
            sourceTreeSHA256: sourceTree.sha256,
            simulatorVersion: request.simulatorVersion,
            numericalProfile: request.numericalProfile,
            backend: request.backend,
            modelSHA256: model.sha256,
            parametersSHA256: parameters.sha256,
            checkpointSHA256: checkpoint.sha256,
            executionConfigurationSHA256: configuration.sha256,
            trainingCorpusSHA256: request.trainingCorpusSHA256,
            calibrationEvidenceSHA256: request.calibrationEvidenceSHA256,
            validationEvidenceSHA256: request.validationEvidenceSHA256,
            sourceTreeDirty: request.sourceTreeDirty,
            prohibitsPostFreezeParameterChanges: true,
            metadata: request.metadata.merging([
                "freeze-builder": "filesystem-sha256-v1",
                "artifact-permissions": "read-only"
            ], uniquingKeysWith: { explicit, _ in explicit })
        )
        return try ProspectiveModelFreezeBundle(
            certificate: try certificate.validated(),
            artifacts: artifacts.sorted { $0.role.rawValue < $1.role.rawValue },
            metadata: ["root-not-authoritative": "true"]
        ).validated()
    }

    static func inspect(
        role: ProspectiveFrozenArtifactRole,
        relativePath: String,
        mediaType: String,
        rootURL: URL,
        maximumBytes: UInt64
    ) throws -> ProspectiveFrozenArtifact {
        let url = try ProspectiveFreezePath.secureFileURL(
            root: rootURL,
            relativePath: relativePath
        )
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw ProspectiveModelFreezeError.notRegularFile(relativePath)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        let readOnly = permissions.map { $0 & 0o222 == 0 } ?? false
        guard readOnly else {
            throw ProspectiveModelFreezeError.artifactWritable(relativePath)
        }
        let digest = try ScientificFileDigester.sha256(
            at: url,
            maximumBytes: maximumBytes
        )
        return try ProspectiveFrozenArtifact(
            role: role,
            relativePath: relativePath,
            mediaType: mediaType,
            sha256: digest.sha256,
            byteCount: digest.byteCount,
            readOnly: true
        ).validated()
    }
}

enum ProspectiveFreezePath {
    static func isSafeRelative(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func secureFileURL(
        root: URL,
        relativePath: String
    ) throws -> URL {
        guard root.isFileURL, isSafeRelative(relativePath) else {
            throw ProspectiveModelFreezeError.unsafePath(relativePath)
        }
        let root = root.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw ProspectiveModelFreezeError.unsafePath(relativePath)
        }
        var current = root
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let values = try current.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                throw ProspectiveModelFreezeError.symbolicLink(relativePath)
            }
            if index < components.count - 1, values.isDirectory != true {
                throw ProspectiveModelFreezeError.unsafePath(relativePath)
            }
        }
        let candidate = current.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw ProspectiveModelFreezeError.unsafePath(relativePath)
        }
        return candidate
    }
}

public enum ProspectiveModelFreezeError: Error, Sendable, CustomStringConvertible {
    case invalidRequest
    case invalidArtifact(ProspectiveFrozenArtifactRole)
    case invalidBundle
    case bundleCertificateMismatch
    case unsafePath(String)
    case symbolicLink(String)
    case notRegularFile(String)
    case artifactWritable(String)

    public var description: String {
        switch self {
        case .invalidRequest:
            return "Prospective model-freeze request is invalid."
        case .invalidArtifact(let role):
            return "Frozen artifact \(role.rawValue) is invalid."
        case .invalidBundle:
            return "Prospective model-freeze bundle is invalid."
        case .bundleCertificateMismatch:
            return "Frozen artifacts do not match the model-freeze certificate."
        case .unsafePath(let path):
            return "Prospective freeze path \(path) is unsafe."
        case .symbolicLink(let path):
            return "Prospective freeze path \(path) contains a symbolic link."
        case .notRegularFile(let path):
            return "Prospective freeze artifact \(path) is not a regular file."
        case .artifactWritable(let path):
            return "Prospective freeze artifact \(path) must be read-only before certification."
        }
    }
}
