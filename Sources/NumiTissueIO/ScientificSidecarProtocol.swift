import Foundation

public enum ScientificSidecarKind: String, Codable, Sendable, CaseIterable, Hashable {
    case nwb
    case efel
    case jaxley
    case reference
}

public enum ScientificSidecarOperation: String, Codable, Sendable, CaseIterable, Hashable {
    case inspect
    case validate
    case extract
    case featureExtract
    case simulate
    case fit
    case compare
}

public struct ScientificSidecarToolchainPin: Codable, Sendable, Hashable {
    public var sidecar: ScientificSidecarKind
    public var implementation: String
    public var implementationVersion: String
    public var runtime: String
    public var runtimeVersion: String
    public var sourceCommit: String?
    public var containerImageDigest: ScientificSHA256Digest?
    public var packageVersions: [String: String]
    public var standardVersions: [String: String]
    public var metadata: [String: String]

    public init(
        sidecar: ScientificSidecarKind,
        implementation: String,
        implementationVersion: String,
        runtime: String,
        runtimeVersion: String,
        sourceCommit: String? = nil,
        containerImageDigest: ScientificSHA256Digest? = nil,
        packageVersions: [String: String] = [:],
        standardVersions: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.sidecar = sidecar
        self.implementation = implementation
        self.implementationVersion = implementationVersion
        self.runtime = runtime
        self.runtimeVersion = runtimeVersion
        self.sourceCommit = sourceCommit
        self.containerImageDigest = containerImageDigest
        self.packageVersions = packageVersions
        self.standardVersions = standardVersions
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !implementation.isEmpty,
              !implementationVersion.isEmpty,
              !runtime.isEmpty,
              !runtimeVersion.isEmpty,
              sourceCommit?.isEmpty != true,
              packageVersions.keys.allSatisfy({ !$0.isEmpty }),
              packageVersions.values.allSatisfy({ !$0.isEmpty }),
              standardVersions.keys.allSatisfy({ !$0.isEmpty }),
              standardVersions.values.allSatisfy({ !$0.isEmpty }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificSidecarError.invalidToolchain(sidecar)
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

public struct ScientificSidecarInput: Codable, Sendable, Hashable {
    public var id: String
    public var relativePath: String
    public var mediaType: String
    public var role: String
    public var sha256: ScientificSHA256Digest
    public var byteCount: UInt64?
    public var metadata: [String: String]

    public init(
        id: String,
        relativePath: String,
        mediaType: String,
        role: String,
        sha256: ScientificSHA256Digest,
        byteCount: UInt64? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.role = role
        self.sha256 = sha256
        self.byteCount = byteCount
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty,
              !mediaType.isEmpty,
              !role.isEmpty,
              byteCount.map({ $0 > 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }),
              ScientificSidecarPath.isSafeRelative(relativePath) else {
            throw ScientificSidecarError.invalidInput(id)
        }
        return self
    }
}

public struct ScientificSidecarSelection: Codable, Sendable, Hashable {
    public var objectPaths: [String]
    public var subjectIDs: [String]
    public var electrodeIDs: [String]
    public var featureNames: [String]
    public var startTimeSeconds: Double?
    public var endTimeSeconds: Double?
    public var maximumRecords: Int
    public var maximumSamplesPerSeries: Int
    public var maximumOutputBytes: UInt64
    public var metadata: [String: String]

    public init(
        objectPaths: [String] = [],
        subjectIDs: [String] = [],
        electrodeIDs: [String] = [],
        featureNames: [String] = [],
        startTimeSeconds: Double? = nil,
        endTimeSeconds: Double? = nil,
        maximumRecords: Int = 100_000,
        maximumSamplesPerSeries: Int = 1_000_000,
        maximumOutputBytes: UInt64 = 1_073_741_824,
        metadata: [String: String] = [:]
    ) {
        self.objectPaths = objectPaths
        self.subjectIDs = subjectIDs
        self.electrodeIDs = electrodeIDs
        self.featureNames = featureNames
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.maximumRecords = maximumRecords
        self.maximumSamplesPerSeries = maximumSamplesPerSeries
        self.maximumOutputBytes = maximumOutputBytes
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        let lists = [objectPaths, subjectIDs, electrodeIDs, featureNames]
        guard lists.allSatisfy({ values in
                  values.allSatisfy({ !$0.isEmpty }) &&
                      Set(values).count == values.count
              }),
              maximumRecords > 0,
              maximumRecords <= 100_000_000,
              maximumSamplesPerSeries > 0,
              maximumSamplesPerSeries <= 1_000_000_000,
              maximumOutputBytes > 0,
              maximumOutputBytes <= 1_099_511_627_776,
              startTimeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              endTimeSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificSidecarError.invalidSelection
        }
        if let startTimeSeconds, let endTimeSeconds,
           endTimeSeconds < startTimeSeconds {
            throw ScientificSidecarError.invalidSelection
        }
        return self
    }
}

public struct ScientificSidecarRequest: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var requestID: String
    public var sidecar: ScientificSidecarKind
    public var operation: ScientificSidecarOperation
    public var toolchain: ScientificSidecarToolchainPin
    public var inputs: [ScientificSidecarInput]
    public var selection: ScientificSidecarSelection
    public var randomSeed: UInt64?
    public var parameters: [String: String]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        requestID: String,
        sidecar: ScientificSidecarKind,
        operation: ScientificSidecarOperation,
        toolchain: ScientificSidecarToolchainPin,
        inputs: [ScientificSidecarInput],
        selection: ScientificSidecarSelection = .init(),
        randomSeed: UInt64? = nil,
        parameters: [String: String] = [:],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sidecar = sidecar
        self.operation = operation
        self.toolchain = toolchain
        self.inputs = inputs
        self.selection = selection
        self.randomSeed = randomSeed
        self.parameters = parameters
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !requestID.isEmpty,
              !inputs.isEmpty,
              Set(inputs.map(\.id)).count == inputs.count,
              parameters.keys.allSatisfy({ !$0.isEmpty }),
              parameters.values.allSatisfy({ !$0.isEmpty }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificSidecarError.invalidRequest(requestID)
        }
        let pin = try toolchain.validated()
        guard pin.sidecar == sidecar else {
            throw ScientificSidecarError.toolchainSidecarMismatch(
                request: sidecar,
                toolchain: pin.sidecar
            )
        }
        for input in inputs { _ = try input.validated() }
        _ = try selection.validated()

        let allowed: Set<ScientificSidecarOperation>
        switch sidecar {
        case .nwb:
            allowed = [.inspect, .validate, .extract]
        case .efel:
            allowed = [.featureExtract, .validate]
        case .jaxley:
            allowed = [.simulate, .fit, .validate]
        case .reference:
            allowed = [.simulate, .compare, .validate]
            guard parameters["engine"]?.isEmpty == false,
                  parameters["engineVersion"]?.isEmpty == false,
                  parameters["engineSource"]?.isEmpty == false else {
                throw ScientificSidecarError.referenceEngineNotPinned
            }
        }
        guard allowed.contains(operation) else {
            throw ScientificSidecarError.unsupportedOperation(
                sidecar: sidecar,
                operation: operation
            )
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

public enum ScientificSidecarResponseStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case completed
    case rejected
    case failed
}

public enum ScientificSidecarDiagnosticSeverity: String, Codable, Sendable, CaseIterable, Hashable {
    case info
    case warning
    case error
}

public struct ScientificSidecarDiagnostic: Codable, Sendable, Hashable {
    public var severity: ScientificSidecarDiagnosticSeverity
    public var code: String
    public var message: String
    public var objectPath: String?

    public init(
        severity: ScientificSidecarDiagnosticSeverity,
        code: String,
        message: String,
        objectPath: String? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.objectPath = objectPath
    }

    public func validated() throws -> Self {
        guard !code.isEmpty,
              !message.isEmpty,
              objectPath?.isEmpty != true else {
            throw ScientificSidecarError.invalidDiagnostic(code)
        }
        return self
    }
}

public struct ScientificSidecarArtifact: Codable, Sendable, Hashable {
    public var logicalName: String
    public var role: String
    public var relativePath: String
    public var mediaType: String
    public var byteCount: UInt64
    public var sha256: ScientificSHA256Digest
    public var metadata: [String: String]

    public init(
        logicalName: String,
        role: String,
        relativePath: String,
        mediaType: String,
        byteCount: UInt64,
        sha256: ScientificSHA256Digest,
        metadata: [String: String] = [:]
    ) {
        self.logicalName = logicalName
        self.role = role
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !logicalName.isEmpty,
              !role.isEmpty,
              !mediaType.isEmpty,
              byteCount > 0,
              metadata.keys.allSatisfy({ !$0.isEmpty }),
              ScientificSidecarPath.isSafeRelative(relativePath) else {
            throw ScientificSidecarError.invalidArtifact(logicalName)
        }
        return self
    }
}

public struct ScientificSidecarResponse: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var requestID: String
    public var requestSHA256: ScientificSHA256Digest
    public var sidecar: ScientificSidecarKind
    public var operation: ScientificSidecarOperation
    public var status: ScientificSidecarResponseStatus
    public var toolchain: ScientificSidecarToolchainPin
    public var artifacts: [ScientificSidecarArtifact]
    public var diagnostics: [ScientificSidecarDiagnostic]
    public var metrics: [String: Double]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        requestID: String,
        requestSHA256: ScientificSHA256Digest,
        sidecar: ScientificSidecarKind,
        operation: ScientificSidecarOperation,
        status: ScientificSidecarResponseStatus,
        toolchain: ScientificSidecarToolchainPin,
        artifacts: [ScientificSidecarArtifact] = [],
        diagnostics: [ScientificSidecarDiagnostic] = [],
        metrics: [String: Double] = [:],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.requestSHA256 = requestSHA256
        self.sidecar = sidecar
        self.operation = operation
        self.status = status
        self.toolchain = toolchain
        self.artifacts = artifacts
        self.diagnostics = diagnostics
        self.metrics = metrics
        self.metadata = metadata
    }

    public func validated(
        for request: ScientificSidecarRequest? = nil
    ) throws -> Self {
        guard schemaVersion == 1,
              !requestID.isEmpty,
              Set(artifacts.map(\.relativePath)).count == artifacts.count,
              metrics.keys.allSatisfy({ !$0.isEmpty }),
              metrics.values.allSatisfy({ $0.isFinite }),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw ScientificSidecarError.invalidResponse(requestID)
        }
        _ = try toolchain.validated()
        guard toolchain.sidecar == sidecar else {
            throw ScientificSidecarError.toolchainSidecarMismatch(
                request: sidecar,
                toolchain: toolchain.sidecar
            )
        }
        for artifact in artifacts { _ = try artifact.validated() }
        for diagnostic in diagnostics { _ = try diagnostic.validated() }
        if status == .completed,
           diagnostics.contains(where: { $0.severity == .error }) {
            throw ScientificSidecarError.completedResponseContainsError
        }
        if let request {
            let validatedRequest = try request.validated()
            guard requestID == validatedRequest.requestID,
                  sidecar == validatedRequest.sidecar,
                  operation == validatedRequest.operation,
                  requestSHA256 == (try validatedRequest.sha256()),
                  toolchain == validatedRequest.toolchain else {
                throw ScientificSidecarError.responseRequestMismatch
            }
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

public enum NumiTissuePhase4Sidecars {
    public static let nwb = ScientificSidecarToolchainPin(
        sidecar: .nwb,
        implementation: "numitissue-nwb",
        implementationVersion: "1",
        runtime: "python",
        runtimeVersion: ">=3.11,<3.15",
        packageVersions: ["pynwb": "4.1.0"],
        standardVersions: ["nwb-core": "2.10.0"],
        metadata: ["entrypoint": "Tools/numitissue-nwb/numitissue_nwb.py"]
    )

    public static let efel = ScientificSidecarToolchainPin(
        sidecar: .efel,
        implementation: "numitissue-efel",
        implementationVersion: "1",
        runtime: "python",
        runtimeVersion: ">=3.10,<3.15",
        packageVersions: ["efel": "5.7.34"],
        metadata: ["entrypoint": "Tools/numitissue-efel/numitissue_efel.py"]
    )

    public static let jaxley = ScientificSidecarToolchainPin(
        sidecar: .jaxley,
        implementation: "numitissue-jaxley",
        implementationVersion: "1",
        runtime: "python",
        runtimeVersion: ">=3.10,<3.14",
        packageVersions: ["jaxley": "0.13.0"],
        metadata: [
            "entrypoint": "Tools/numitissue-jaxley/numitissue_jaxley.py",
            "default-platform": "cpu",
            "accelerator-policy": "explicit"
        ]
    )

    public static let reference = ScientificSidecarToolchainPin(
        sidecar: .reference,
        implementation: "numitissue-reference",
        implementationVersion: "1",
        runtime: "python",
        runtimeVersion: ">=3.11,<3.15",
        metadata: [
            "entrypoint": "Tools/numitissue-reference/numitissue_reference.py",
            "engine-policy": "request-pinned"
        ]
    )

    public static var all: [ScientificSidecarToolchainPin] {
        [nwb, efel, jaxley, reference]
    }
}

enum ScientificSidecarPath {
    static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

public enum ScientificSidecarError: Error, Sendable, CustomStringConvertible {
    case invalidToolchain(ScientificSidecarKind)
    case invalidInput(String)
    case invalidSelection
    case invalidRequest(String)
    case invalidDiagnostic(String)
    case invalidArtifact(String)
    case invalidResponse(String)
    case toolchainSidecarMismatch(
        request: ScientificSidecarKind,
        toolchain: ScientificSidecarKind
    )
    case unsupportedOperation(
        sidecar: ScientificSidecarKind,
        operation: ScientificSidecarOperation
    )
    case referenceEngineNotPinned
    case completedResponseContainsError
    case responseRequestMismatch

    public var description: String {
        switch self {
        case .invalidToolchain(let sidecar):
            return "Invalid \(sidecar.rawValue) sidecar toolchain pin."
        case .invalidInput(let identifier):
            return "Invalid sidecar input \(identifier)."
        case .invalidSelection:
            return "Invalid or unbounded sidecar selection."
        case .invalidRequest(let identifier):
            return "Invalid sidecar request \(identifier)."
        case .invalidDiagnostic(let code):
            return "Invalid sidecar diagnostic \(code)."
        case .invalidArtifact(let name):
            return "Invalid sidecar artifact \(name)."
        case .invalidResponse(let identifier):
            return "Invalid sidecar response \(identifier)."
        case .toolchainSidecarMismatch(let request, let toolchain):
            return "Sidecar request \(request.rawValue) does not match toolchain \(toolchain.rawValue)."
        case .unsupportedOperation(let sidecar, let operation):
            return "\(operation.rawValue) is not supported by the \(sidecar.rawValue) sidecar."
        case .referenceEngineNotPinned:
            return "Reference sidecar requests must pin engine, engineVersion and engineSource."
        case .completedResponseContainsError:
            return "A completed sidecar response contains an error diagnostic."
        case .responseRequestMismatch:
            return "The sidecar response does not match its request identity."
        }
    }
}
