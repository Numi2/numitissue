import Foundation
import NumiTissue

struct Phase3Command {
    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw Phase3CLIError.usage
        }
        switch command {
        case "status":
            guard arguments.count == 1 else { throw Phase3CLIError.usage }
            try emit(status())
        case "support":
            guard arguments.count == 1 else { throw Phase3CLIError.usage }
            try emit(support())
        case "contract":
            guard arguments.count == 1 else { throw Phase3CLIError.usage }
            try emit(contract())
        case "verify":
            guard arguments.count == 2 else { throw Phase3CLIError.usage }
            try verifyManifest(URL(fileURLWithPath: arguments[1]))
        default:
            throw Phase3CLIError.unknownCommand(command)
        }
    }

    private static func status() -> [String: Any] {
        [
            "schemaVersion": 1,
            "component": "numitissue.phase3",
            "sourceStatus": "metal4-runtime-present",
            "hardwareQualification": "not-established-by-build",
            "productionAuthorized": false,
            "promotion": "blocked-until-bound-certificate-and-evidence-graph-are-verified",
            "numericalProfiles": RuntimeNumericalProfile.allCases.map(\.rawValue),
            "indirectDispatchQualifiedKernelNames": qualifiedIndirectKernels(),
            "metal4Support": support()
        ]
    }

    private static func support() -> [String: Any] {
        #if canImport(Metal)
        let report = Metal4Support.probe()
        var result: [String: Any] = [
            "sdkCompiled": report.sdkCompiled,
            "operatingSystemAvailable": report.operatingSystemAvailable,
            "gpuFamilyAvailable": report.gpuFamilyAvailable,
            "commandQueueAvailable": report.commandQueueAvailable,
            "supported": report.supported
        ]
        if let deviceName = report.deviceName {
            result["deviceName"] = deviceName
        }
        if let deviceRegistryID = report.deviceRegistryID {
            result["deviceRegistryID"] = deviceRegistryID
        }
        if let reason = report.reason {
            result["reason"] = reason
        }
        return result
        #else
        return [
            "sdkCompiled": false,
            "operatingSystemAvailable": false,
            "gpuFamilyAvailable": false,
            "commandQueueAvailable": false,
            "supported": false,
            "reason": "Metal is unavailable in this build"
        ]
        #endif
    }

    private static func contract() -> [String: Any] {
        [
            "schemaVersion": 1,
            "backend": "metal4",
            "maximumArgumentTableBufferBindings": 31,
            "scientificProfile": RuntimeNumericalProfile.scientific32.rawValue,
            "performanceProfile": RuntimeNumericalProfile.performance32.rawValue,
            "performanceAuthorization": "sealed-certificate-required",
            "indirectDispatchQualifiedKernelNames": qualifiedIndirectKernels(),
            "fallback": "explicit-only",
            "transaction": "shadow-execute-validate-atomic-commit"
        ]
    }

    private static func qualifiedIndirectKernels() -> [String] {
        #if canImport(Metal)
        return Metal4IndirectDispatchCatalog.supportedKernelNames.sorted()
        #else
        return []
        #endif
    }

    private static func verifyManifest(_ url: URL) throws {
        guard !isSymlink(url) else {
            throw Phase3CLIError.invalidManifest("manifest must not be a symlink")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let object = try jsonObject(data)
        guard let schemaVersion = object["schemaVersion"] as? Int,
              schemaVersion == 1,
              object["kind"] as? String == "numitissue.phase3.validation-run",
              object["executionPurpose"] as? String == "qualification" else {
            throw Phase3CLIError.invalidManifest("unsupported manifest identity")
        }
        guard let productionAuthorized = object["productionAuthorized"] as? Bool,
              !productionAuthorized,
              object["promotionCertificate"] is NSNull else {
            throw Phase3CLIError.invalidManifest(
                "production authorization and detached certificates are rejected"
            )
        }
        guard let repository = object["repository"] as? [String: Any],
              let revision = repository["revision"] as? String,
              revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit }) else {
            throw Phase3CLIError.invalidManifest("full repository revision is required")
        }

        let root = canonicalFileURL(
            url.standardizedFileURL.deletingLastPathComponent()
        )
        guard let artifacts = object["artifacts"] as? [[String: Any]] else {
            throw Phase3CLIError.invalidManifest("artifacts are required")
        }
        var artifactPaths = Set<String>()
        for artifact in artifacts {
            guard let path = artifact["path"] as? String,
                  artifactPaths.insert(path).inserted,
                  path != "manifest.json" else {
                throw Phase3CLIError.invalidManifest("duplicate or self-referential artifact")
            }
            let components = try safeComponents(path, field: "artifact path")
            let artifactURL = try safeURL(root: root, components: components)
            guard FileManager.default.fileExists(atPath: artifactURL.path),
                  !isSymlink(artifactURL) else {
                throw Phase3CLIError.invalidManifest("artifact is missing or a symlink: \(path)")
            }
            let artifactData = try Data(contentsOf: artifactURL, options: [.mappedIfSafe])
            guard let byteCount = artifact["byteCount"] as? Int,
                  byteCount == artifactData.count,
                  let expectedDigest = artifact["sha256"] as? String,
                  expectedDigest.count == 64,
                  expectedDigest.lowercased() == ScientificSHA256Digest(data: artifactData).hexadecimal else {
                throw Phase3CLIError.invalidManifest("artifact integrity mismatch: \(path)")
            }
        }

        let actualPaths = try regularFiles(root: root).filter { $0 != "manifest.json" }
        guard Set(actualPaths) == artifactPaths else {
            throw Phase3CLIError.invalidManifest("artifact inventory does not match the evidence directory")
        }
        try verifyPreflight(object["preflight"], artifactPaths: artifactPaths)
        try verifyCommands(object["commands"], artifactPaths: artifactPaths, expectedFailures: object["requiredCommandFailures"])
        try verifyGraph(object["evidenceGraph"])

        try emit([
            "schemaVersion": 1,
            "manifest": url.path,
            "valid": true,
            "qualificationStatus": object["qualificationStatus"] as? String ?? "unknown",
            "productionAuthorized": false,
            "verifiedArtifactCount": artifacts.count,
            "promotionEligible": false,
            "reason": "manifest is integrity-checked qualification evidence; promotion remains blocked"
        ])
    }

    private static func verifyPreflight(
        _ value: Any?,
        artifactPaths: Set<String>
    ) throws {
        guard let preflight = value as? [String: Any] else {
            throw Phase3CLIError.invalidManifest("preflight is required")
        }
        for key in ["sourceAudit", "appleSiliconDoctor"] {
            guard let record = preflight[key] as? [String: Any],
                  let path = record["path"] as? String,
                  artifactPaths.contains(path),
                  record["passing"] as? Bool != nil else {
                throw Phase3CLIError.invalidManifest("invalid preflight record: \(key)")
            }
            _ = try safeComponents(path, field: "preflight path")
        }
    }

    private static func verifyCommands(
        _ value: Any?,
        artifactPaths: Set<String>,
        expectedFailures: Any?
    ) throws {
        guard let commands = value as? [[String: Any]],
              let failures = expectedFailures as? [String] else {
            throw Phase3CLIError.invalidManifest("commands are required")
        }
        var identifiers = Set<String>()
        var actualFailures: [String] = []
        for command in commands {
            guard let identifier = command["id"] as? String,
                  !identifier.isEmpty,
                  identifiers.insert(identifier).inserted,
                  command["required"] as? Bool != nil,
                  let success = command["success"] as? Bool,
                  command["exitCode"] as? Int != nil,
                  let log = command["log"] as? String,
                  artifactPaths.contains(log) else {
                throw Phase3CLIError.invalidManifest("invalid command record")
            }
            _ = try safeComponents(log, field: "command log")
            if command["required"] as? Bool == true, !success {
                actualFailures.append(identifier)
            }
        }
        guard actualFailures == failures else {
            throw Phase3CLIError.invalidManifest("required command failures do not match records")
        }
    }

    private static func verifyGraph(_ value: Any?) throws {
        guard let graph = value as? [String: Any],
              let nodes = graph["nodes"] as? [[String: Any]],
              let edges = graph["edges"] as? [[String: Any]],
              let missing = graph["missingForProduction"] as? [String] else {
            throw Phase3CLIError.invalidManifest("evidence graph is incomplete")
        }
        let required = [
            "workload", "device", "execution-configuration", "pipeline-archive",
            "qualification-evidence", "qualification-bundle", "promotion-report",
            "promotion-certificate", "execution-identity", "checkpoint", "production-backend"
        ]
        var statuses: [String: String] = [:]
        for node in nodes {
            guard let id = node["id"] as? String,
                  !id.isEmpty,
                  statuses[id] == nil,
                  let status = node["status"] as? String,
                  !status.isEmpty else {
                throw Phase3CLIError.invalidManifest("invalid or duplicate evidence node")
            }
            statuses[id] = status
        }
        var adjacency: [String: [String]] = [:]
        var indegree: [String: Int] = [:]
        for id in statuses.keys {
            adjacency[id] = []
            indegree[id] = 0
        }
        var edgeSet = Set<String>()
        for edge in edges {
            guard let source = edge["from"] as? String,
                  let target = edge["to"] as? String,
                  source != target,
                  statuses[source] != nil,
                  statuses[target] != nil,
                  edgeSet.insert(source + "\u{1f}" + target).inserted else {
                throw Phase3CLIError.invalidManifest("invalid or duplicate evidence edge")
            }
            adjacency[source, default: []].append(target)
            indegree[target, default: 0] += 1
        }
        var queue = indegree.filter { $0.value == 0 }.map(\.key)
        var visited = 0
        while let source = queue.popLast() {
            visited += 1
            for target in adjacency[source, default: []] {
                indegree[target, default: 0] -= 1
                if indegree[target] == 0 { queue.append(target) }
            }
        }
        guard visited == statuses.count else {
            throw Phase3CLIError.invalidManifest("evidence graph contains a cycle")
        }
        for id in required {
            guard let status = statuses[id] else {
                throw Phase3CLIError.invalidManifest("evidence graph omits \(id)")
            }
            if status != "present", !missing.contains(id) {
                throw Phase3CLIError.invalidManifest("missing evidence node is not declared: \(id)")
            }
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data, options: [])
        guard let object = value as? [String: Any] else {
            throw Phase3CLIError.invalidManifest("manifest root is not an object")
        }
        return object
    }

    private static func safeComponents(
        _ path: String,
        field: String
    ) throws -> [String] {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw Phase3CLIError.invalidManifest("\(field) is not a portable relative path")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Phase3CLIError.invalidManifest("\(field) contains an unsafe component")
        }
        return components
    }

    private static func safeURL(root: URL, components: [String]) throws -> URL {
        var result = root
        for component in components {
            result.appendPathComponent(component, isDirectory: false)
            if isSymlink(result) {
                throw Phase3CLIError.invalidManifest("evidence path traverses a symlink")
            }
        }
        return result
    }

    /// URL.resolvingSymlinksInPath() does not canonicalize the /tmp alias on
    /// every Apple platform. Resolve each existing path component explicitly
    /// so enumerated evidence paths and the root use the same spelling.
    private static func canonicalFileURL(_ url: URL) -> URL {
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.standardizedFileURL.pathComponents where component != "/" {
            result.appendPathComponent(component, isDirectory: true)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: result.path
            ) {
                result = destination.hasPrefix("/")
                    ? URL(fileURLWithPath: destination, isDirectory: true)
                    : result.deletingLastPathComponent()
                        .appendingPathComponent(destination, isDirectory: true)
            }
        }
        return result
    }

    private static func isSymlink(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func regularFiles(root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw Phase3CLIError.invalidManifest("cannot enumerate evidence directory")
        }
        var paths: [String] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw Phase3CLIError.invalidManifest("evidence directory contains a symlink")
            }
            if values.isDirectory != true {
                let relative = item.path
                    .dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1))
                paths.append(String(relative))
            }
        }
        return paths.sorted()
    }

    private static func emit(_ value: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw Phase3CLIError.invalidManifest("output is not valid JSON")
        }
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum Phase3CLIError: Error, CustomStringConvertible {
    case usage
    case unknownCommand(String)
    case invalidManifest(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: numitissue phase3 <status|support|contract|verify <manifest.json>>"
        case .unknownCommand(let command):
            return "unknown phase3 command '\(command)'"
        case .invalidManifest(let reason):
            return "invalid Phase 3 manifest: \(reason)"
        }
    }
}
