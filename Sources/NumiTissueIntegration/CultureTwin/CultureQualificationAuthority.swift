import Foundation
import NumiTissueIO

public enum CultureQualificationArtifactRole: String, Sendable, Hashable, Codable, CaseIterable {
    case phase4CorpusEvidence = "phase4-corpus-evidence"
    case phase5InferenceEvidence = "phase5-inference-evidence"
    case cpuMetalObservationEvidence = "cpu-metal-observation-evidence"
    case syntheticRecoveryEvidence = "synthetic-recovery-evidence"
    case intervalCalibrationEvidence = "interval-calibration-evidence"
    case hierarchicalEvaluationEvidence = "hierarchical-evaluation-evidence"
    case heldOutForecastEvidence = "heldout-forecast-evidence"
}

public struct CultureQualificationArtifact: Sendable, Hashable, Codable {
    public var role: CultureQualificationArtifactRole
    public var relativePath: String
    public var sha256: ScientificSHA256Digest
    public var byteCount: UInt64

    public init(role: CultureQualificationArtifactRole, relativePath: String,
                sha256: ScientificSHA256Digest, byteCount: UInt64) {
        self.role = role; self.relativePath = relativePath
        self.sha256 = sha256; self.byteCount = byteCount
    }
}

public struct CultureQualificationAuthorityManifest: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var evidenceSHA256: ScientificSHA256Digest
    public var artifacts: [CultureQualificationArtifact]

    public init(evidenceSHA256: ScientificSHA256Digest,
                artifacts: [CultureQualificationArtifact]) {
        self.schemaVersion = 1; self.evidenceSHA256 = evidenceSHA256
        self.artifacts = artifacts
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1, !artifacts.isEmpty,
              Set(artifacts.map(\.role)) == Set(CultureQualificationArtifactRole.allCases),
              Set(artifacts.map(\.relativePath)).count == artifacts.count,
              artifacts.allSatisfy({ $0.byteCount > 0 && CultureQualificationPath.safe($0.relativePath) }) else {
            throw CultureTwinError.invalid("qualification authority manifest")
        }
        return self
    }

    public func digest() throws -> ScientificSHA256Digest {
        _ = try validated()
        return ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

public struct CultureQualificationAuthorityVerification: Sendable, Codable {
    public var schemaVersion: UInt32
    public var manifestSHA256: ScientificSHA256Digest
    public var evidenceSHA256: ScientificSHA256Digest
    public var checkedAt: Date
    public var verifiedRoles: [CultureQualificationArtifactRole]
    public var passed: Bool
}

public enum CultureQualificationAuthorityVerifier {
    public static func verify(
        manifest sourceManifest: CultureQualificationAuthorityManifest,
        evidence sourceEvidence: CultureTwinQualificationEvidence,
        rootURL: URL,
        checkedAt: Date,
        maximumArtifactBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
    ) throws -> CultureQualificationAuthorityVerification {
        let manifest = try sourceManifest.validated()
        let evidence = try sourceEvidence.validated()
        let evidenceDigest = try evidence.digest()
        guard manifest.evidenceSHA256 == evidenceDigest,
              rootURL.isFileURL,
              maximumArtifactBytes > 0 else {
            throw CultureTwinError.invalid("qualification authority identity")
        }
        var roles: [CultureQualificationArtifactRole] = []
        for artifact in manifest.artifacts.sorted(by: { $0.role.rawValue < $1.role.rawValue }) {
            let url = try CultureQualificationPath.resolve(
                rootURL: rootURL,
                relativePath: artifact.relativePath
            )
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CultureTwinError.invalid("qualification artifact file")
            }
            let result = try ScientificFileDigester.sha256(
                at: url,
                maximumBytes: maximumArtifactBytes
            )
            guard result.sha256 == artifact.sha256,
                  result.byteCount == artifact.byteCount else {
                throw CultureTwinError.invalid("qualification artifact digest")
            }
            roles.append(artifact.role)
        }
        let verification = CultureQualificationAuthorityVerification(
            schemaVersion: 1,
            manifestSHA256: try manifest.digest(),
            evidenceSHA256: evidenceDigest,
            checkedAt: checkedAt,
            verifiedRoles: roles,
            passed: Set(roles) == Set(CultureQualificationArtifactRole.allCases)
        )
        guard verification.passed else {
            throw CultureTwinError.invalid("qualification artifact coverage")
        }
        return verification
    }
}

enum CultureQualificationPath {
    static func safe(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func resolve(rootURL: URL, relativePath: String) throws -> URL {
        guard safe(relativePath) else {
            throw CultureTwinError.invalid("unsafe qualification path")
        }
        let root = rootURL.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CultureTwinError.invalid("unsafe qualification root")
        }
        var current = root
        let components = relativePath.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: index < components.count - 1)
            let values = try current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CultureTwinError.invalid("qualification path contains symlink")
            }
            if index < components.count - 1, values.isDirectory != true {
                throw CultureTwinError.invalid("qualification path parent is not directory")
            }
        }
        let candidate = current.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix) else {
            throw CultureTwinError.invalid("qualification path escapes root")
        }
        return candidate
    }
}
