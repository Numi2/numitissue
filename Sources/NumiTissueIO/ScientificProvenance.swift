import Foundation

public struct ScientificSHA256Digest: Sendable, Hashable, Codable, CustomStringConvertible {
    public let hexadecimal: String

    public init(hexadecimal: String) throws {
        let normalized = hexadecimal.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw ScientificProvenanceError.invalidDigest
        }
        self.hexadecimal = normalized
    }

    public init(data: Data) {
        hexadecimal = ScientificSHA256.hash(data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public init(bytes: [UInt8]) {
        self.init(data: Data(bytes))
    }

    public var description: String { hexadecimal }
}

public enum ScientificArtifactRole: String, Sendable, Hashable, Codable {
    case model
    case morphology
    case circuit
    case mechanism
    case reactionNetwork
    case initialState
    case checkpoint
    case intervention
    case observation
    case calibration
    case output
    case log
    case executable
    case configuration
    case other
}

public struct ScientificArtifactProvenance: Sendable, Hashable, Codable {
    public var logicalName: String
    public var role: ScientificArtifactRole
    public var relativePath: String?
    public var mediaType: String?
    public var byteCount: UInt64
    public var sha256: ScientificSHA256Digest
    public var sourceURI: String?
    public var sourceVersion: String?
    public var licenseIdentifier: String?
    public var metadata: [String: String]

    public init(
        logicalName: String,
        role: ScientificArtifactRole,
        relativePath: String? = nil,
        mediaType: String? = nil,
        byteCount: UInt64,
        sha256: ScientificSHA256Digest,
        sourceURI: String? = nil,
        sourceVersion: String? = nil,
        licenseIdentifier: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.logicalName = logicalName
        self.role = role
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sourceURI = sourceURI
        self.sourceVersion = sourceVersion
        self.licenseIdentifier = licenseIdentifier
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !logicalName.isEmpty,
              relativePath.map({ !$0.hasPrefix("/") && !$0.contains("..") }) != false,
              sourceURI?.isEmpty != true,
              sourceVersion?.isEmpty != true,
              licenseIdentifier?.isEmpty != true else {
            throw ScientificProvenanceError.invalidArtifact(logicalName)
        }
        return self
    }

    public static func file(
        at url: URL,
        role: ScientificArtifactRole,
        logicalName: String? = nil,
        relativeTo root: URL? = nil,
        mediaType: String? = nil,
        sourceURI: String? = nil,
        sourceVersion: String? = nil,
        licenseIdentifier: String? = nil,
        metadata: [String: String] = [:]
    ) throws -> Self {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let relativePath: String?
        if let root {
            relativePath = try ScientificPath.relativePath(
                of: url,
                under: root
            )
        } else {
            relativePath = url.lastPathComponent
        }
        return try Self(
            logicalName: logicalName ?? url.lastPathComponent,
            role: role,
            relativePath: relativePath,
            mediaType: mediaType,
            byteCount: UInt64(data.count),
            sha256: ScientificSHA256Digest(data: data),
            sourceURI: sourceURI,
            sourceVersion: sourceVersion,
            licenseIdentifier: licenseIdentifier,
            metadata: metadata
        ).validated()
    }
}

public struct ScientificSoftwareProvenance: Sendable, Hashable, Codable {
    public var simulatorName: String
    public var simulatorVersion: String
    public var gitRepository: String?
    public var gitCommit: String?
    public var gitBranch: String?
    public var sourceTreeDirty: Bool?
    public var swiftVersion: String?
    public var metalLanguageVersion: String?
    public var operatingSystem: String
    public var processArchitecture: String
    public var buildConfiguration: String?
    public var compilerFlags: [String]
    public var linkedLibraries: [String: String]

    public init(
        simulatorName: String,
        simulatorVersion: String,
        gitRepository: String? = nil,
        gitCommit: String? = nil,
        gitBranch: String? = nil,
        sourceTreeDirty: Bool? = nil,
        swiftVersion: String? = nil,
        metalLanguageVersion: String? = nil,
        operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString,
        processArchitecture: String = ScientificRuntimeEnvironment.architecture,
        buildConfiguration: String? = nil,
        compilerFlags: [String] = [],
        linkedLibraries: [String: String] = [:]
    ) {
        self.simulatorName = simulatorName
        self.simulatorVersion = simulatorVersion
        self.gitRepository = gitRepository
        self.gitCommit = gitCommit
        self.gitBranch = gitBranch
        self.sourceTreeDirty = sourceTreeDirty
        self.swiftVersion = swiftVersion
        self.metalLanguageVersion = metalLanguageVersion
        self.operatingSystem = operatingSystem
        self.processArchitecture = processArchitecture
        self.buildConfiguration = buildConfiguration
        self.compilerFlags = compilerFlags
        self.linkedLibraries = linkedLibraries
    }

    public func validated() throws -> Self {
        guard !simulatorName.isEmpty,
              !simulatorVersion.isEmpty,
              !operatingSystem.isEmpty,
              !processArchitecture.isEmpty,
              gitRepository?.isEmpty != true,
              gitCommit?.isEmpty != true,
              gitBranch?.isEmpty != true,
              swiftVersion?.isEmpty != true,
              metalLanguageVersion?.isEmpty != true,
              buildConfiguration?.isEmpty != true else {
            throw ScientificProvenanceError.invalidSoftware
        }
        return self
    }
}

public struct ScientificDeviceProvenance: Sendable, Hashable, Codable {
    public var backend: String
    public var deviceName: String
    public var registryID: UInt64?
    public var unifiedMemoryBytes: UInt64?
    public var recommendedWorkingSetBytes: UInt64?
    public var maximumBufferLengthBytes: UInt64?
    public var processorCount: Int
    public var supportsUnifiedMemory: Bool?
    public var featureFlags: [String: Bool]
    public var metadata: [String: String]

    public init(
        backend: String,
        deviceName: String,
        registryID: UInt64? = nil,
        unifiedMemoryBytes: UInt64? = nil,
        recommendedWorkingSetBytes: UInt64? = nil,
        maximumBufferLengthBytes: UInt64? = nil,
        processorCount: Int = ProcessInfo.processInfo.processorCount,
        supportsUnifiedMemory: Bool? = nil,
        featureFlags: [String: Bool] = [:],
        metadata: [String: String] = [:]
    ) {
        self.backend = backend
        self.deviceName = deviceName
        self.registryID = registryID
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.maximumBufferLengthBytes = maximumBufferLengthBytes
        self.processorCount = processorCount
        self.supportsUnifiedMemory = supportsUnifiedMemory
        self.featureFlags = featureFlags
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !backend.isEmpty,
              !deviceName.isEmpty,
              processorCount > 0 else {
            throw ScientificProvenanceError.invalidDevice
        }
        return self
    }
}

public struct ScientificExecutionProvenance: Sendable, Hashable, Codable {
    public var deterministicMode: Bool
    public var authoritativePrecision: String
    public var fastTickNanoseconds: UInt64
    public var transactionTicks: UInt64
    public var randomSeed: UInt64
    public var replicaIndex: Int?
    public var workerIndex: Int?
    public var workerCount: Int?
    public var scheduler: String
    public var acceptedApproximationFlags: [String]
    public var metadata: [String: String]

    public init(
        deterministicMode: Bool,
        authoritativePrecision: String,
        fastTickNanoseconds: UInt64,
        transactionTicks: UInt64,
        randomSeed: UInt64,
        replicaIndex: Int? = nil,
        workerIndex: Int? = nil,
        workerCount: Int? = nil,
        scheduler: String,
        acceptedApproximationFlags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.deterministicMode = deterministicMode
        self.authoritativePrecision = authoritativePrecision
        self.fastTickNanoseconds = fastTickNanoseconds
        self.transactionTicks = transactionTicks
        self.randomSeed = randomSeed
        self.replicaIndex = replicaIndex
        self.workerIndex = workerIndex
        self.workerCount = workerCount
        self.scheduler = scheduler
        self.acceptedApproximationFlags = acceptedApproximationFlags
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !authoritativePrecision.isEmpty,
              fastTickNanoseconds > 0,
              transactionTicks > 0,
              scheduler.isEmpty == false,
              replicaIndex.map({ $0 >= 0 }) != false,
              workerIndex.map({ $0 >= 0 }) != false,
              workerCount.map({ $0 > 0 }) != false else {
            throw ScientificProvenanceError.invalidExecution
        }
        if let workerIndex, let workerCount, workerIndex >= workerCount {
            throw ScientificProvenanceError.invalidExecution
        }
        return self
    }
}

public enum ScientificRunStatus: String, Sendable, Hashable, Codable {
    case planned
    case running
    case completed
    case rejected
    case failed
    case cancelled
}

public struct ScientificRunProvenanceManifest: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var runID: UUID
    public var campaignID: UUID?
    public var trialID: UInt64?
    public var parentRunID: UUID?
    public var status: ScientificRunStatus
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public var software: ScientificSoftwareProvenance
    public var device: ScientificDeviceProvenance
    public var execution: ScientificExecutionProvenance
    public var modelDigest: ScientificSHA256Digest
    public var initialStateDigest: ScientificSHA256Digest?
    public var parentCheckpointDigest: ScientificSHA256Digest?
    public var inputs: [ScientificArtifactProvenance]
    public var outputs: [ScientificArtifactProvenance]
    public var validationProfile: String?
    public var validationPassed: Bool?
    public var failureDescription: String?
    public var tags: [String]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        runID: UUID = UUID(),
        campaignID: UUID? = nil,
        trialID: UInt64? = nil,
        parentRunID: UUID? = nil,
        status: ScientificRunStatus = .planned,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        software: ScientificSoftwareProvenance,
        device: ScientificDeviceProvenance,
        execution: ScientificExecutionProvenance,
        modelDigest: ScientificSHA256Digest,
        initialStateDigest: ScientificSHA256Digest? = nil,
        parentCheckpointDigest: ScientificSHA256Digest? = nil,
        inputs: [ScientificArtifactProvenance] = [],
        outputs: [ScientificArtifactProvenance] = [],
        validationProfile: String? = nil,
        validationPassed: Bool? = nil,
        failureDescription: String? = nil,
        tags: [String] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.campaignID = campaignID
        self.trialID = trialID
        self.parentRunID = parentRunID
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.software = software
        self.device = device
        self.execution = execution
        self.modelDigest = modelDigest
        self.initialStateDigest = initialStateDigest
        self.parentCheckpointDigest = parentCheckpointDigest
        self.inputs = inputs
        self.outputs = outputs
        self.validationProfile = validationProfile
        self.validationPassed = validationPassed
        self.failureDescription = failureDescription
        self.tags = tags
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              Set(inputs.map({ $0.logicalName })).count == inputs.count,
              Set(outputs.map({ $0.logicalName })).count == outputs.count,
              Set(tags).count == tags.count,
              validationProfile?.isEmpty != true,
              failureDescription?.isEmpty != true else {
            throw ScientificProvenanceError.invalidManifest
        }
        _ = try software.validated()
        _ = try device.validated()
        _ = try execution.validated()
        for artifact in inputs + outputs { _ = try artifact.validated() }
        if let startedAt, startedAt < createdAt {
            throw ScientificProvenanceError.invalidTimeline
        }
        if let completedAt {
            guard let startedAt, completedAt >= startedAt else {
                throw ScientificProvenanceError.invalidTimeline
            }
        }
        switch status {
        case .planned:
            guard startedAt == nil, completedAt == nil else {
                throw ScientificProvenanceError.invalidTimeline
            }
        case .running:
            guard startedAt != nil, completedAt == nil else {
                throw ScientificProvenanceError.invalidTimeline
            }
        case .completed, .rejected, .failed, .cancelled:
            guard startedAt != nil, completedAt != nil else {
                throw ScientificProvenanceError.invalidTimeline
            }
        }
        if status == .failed, failureDescription == nil {
            throw ScientificProvenanceError.missingFailureDescription
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(try validated())
    }

    public func manifestDigest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }

    public func writeAtomically(to url: URL) throws {
        let data = try canonicalData()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

public enum ScientificCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

public enum ScientificRuntimeEnvironment {
    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #elseif arch(i386)
        return "i386"
        #else
        return "unknown"
        #endif
    }
}

private enum ScientificPath {
    static func relativePath(of url: URL, under root: URL) throws -> String {
        let rootURL = root.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = rootURL.pathComponents
        let fileComponents = fileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ScientificProvenanceError.pathOutsideRoot(url.path)
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}

private enum ScientificSHA256 {
    private static let initial: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        var bigEndianLength = bitLength.bigEndian
        withUnsafeBytes(of: &bigEndianLength) {
            message.append(contentsOf: $0)
        }

        var state = initial
        var schedule = Array(repeating: UInt32(0), count: 64)
        for offset in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let start = offset + index * 4
                schedule[index] = UInt32(message[start]) << 24
                    | UInt32(message[start + 1]) << 16
                    | UInt32(message[start + 2]) << 8
                    | UInt32(message[start + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], by: 7)
                    ^ rotateRight(schedule[index - 15], by: 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], by: 17)
                    ^ rotateRight(schedule[index - 2], by: 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16]
                    &+ s0
                    &+ schedule[index - 7]
                    &+ s1
            }

            var a = state[0]
            var b = state[1]
            var c = state[2]
            var d = state[3]
            var e = state[4]
            var f = state[5]
            var g = state[6]
            var h = state[7]
            for index in 0..<64 {
                let upperSigma1 = rotateRight(e, by: 6)
                    ^ rotateRight(e, by: 11)
                    ^ rotateRight(e, by: 25)
                let choose = (e & f) ^ ((~e) & g)
                let temporary1 = h
                    &+ upperSigma1
                    &+ choose
                    &+ constants[index]
                    &+ schedule[index]
                let upperSigma0 = rotateRight(a, by: 2)
                    ^ rotateRight(a, by: 13)
                    ^ rotateRight(a, by: 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temporary2 = upperSigma0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temporary1
                d = c
                c = b
                b = a
                a = temporary1 &+ temporary2
            }
            state[0] &+= a
            state[1] &+= b
            state[2] &+= c
            state[3] &+= d
            state[4] &+= e
            state[5] &+= f
            state[6] &+= g
            state[7] &+= h
        }
        return state.flatMap { value in
            let bigEndian = value.bigEndian
            return withUnsafeBytes(of: bigEndian) { Array($0) }
        }
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

public enum ScientificProvenanceError: Error, Sendable, CustomStringConvertible {
    case invalidDigest
    case invalidArtifact(String)
    case invalidSoftware
    case invalidDevice
    case invalidExecution
    case invalidManifest
    case invalidTimeline
    case missingFailureDescription
    case pathOutsideRoot(String)

    public var description: String {
        switch self {
        case .invalidDigest:
            return "Scientific SHA-256 digest is invalid"
        case .invalidArtifact(let name):
            return "Scientific artifact provenance \(name) is invalid"
        case .invalidSoftware:
            return "Scientific software provenance is invalid"
        case .invalidDevice:
            return "Scientific device provenance is invalid"
        case .invalidExecution:
            return "Scientific execution provenance is invalid"
        case .invalidManifest:
            return "Scientific run provenance manifest is invalid"
        case .invalidTimeline:
            return "Scientific run provenance timeline is invalid"
        case .missingFailureDescription:
            return "Failed scientific run has no failure description"
        case .pathOutsideRoot(let path):
            return "Scientific artifact path is outside provenance root: \(path)"
        }
    }
}
