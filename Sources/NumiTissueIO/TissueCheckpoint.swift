import Foundation
import NumiTissueCore
import NumiTissueRuntime
#if canImport(Compression)
import Compression
#endif

public enum TissueCheckpointCompression: UInt32, Sendable, Hashable, Codable {
    case none = 0
    case lzfse = 1
}

public struct TissueCheckpointManifest: Sendable, Hashable, Codable {
    public var formatVersion: UInt32
    public var simulatorVersion: String
    public var createdAt: Date
    public var epoch: UInt64
    public var timeTick: UInt64
    public var randomSeed: UInt64
    public var modelDigest: UInt64
    public var stateDigest: UInt64
    public var metadata: [String: String]

    public init(
        formatVersion: UInt32 = 1,
        simulatorVersion: String,
        createdAt: Date = Date(),
        epoch: UInt64,
        timeTick: UInt64,
        randomSeed: UInt64,
        modelDigest: UInt64,
        stateDigest: UInt64,
        metadata: [String: String] = [:]
    ) {
        self.formatVersion = formatVersion
        self.simulatorVersion = simulatorVersion
        self.createdAt = createdAt
        self.epoch = epoch
        self.timeTick = timeTick
        self.randomSeed = randomSeed
        self.modelDigest = modelDigest
        self.stateDigest = stateDigest
        self.metadata = metadata
    }
}

public struct TissueCheckpoint: Sendable, Codable {
    public var manifest: TissueCheckpointManifest
    public var state: TissueRuntimeState
    public var opaqueModelState: Data?
    public var suiteParticipantState: [String: Data]

    public init(
        manifest: TissueCheckpointManifest,
        state: TissueRuntimeState,
        opaqueModelState: Data? = nil,
        suiteParticipantState: [String: Data] = [:]
    ) {
        self.manifest = manifest
        self.state = state
        self.opaqueModelState = opaqueModelState
        self.suiteParticipantState = suiteParticipantState
    }

    public static func make(
        state: TissueRuntimeState,
        simulatorVersion: String,
        randomSeed: UInt64,
        modelDigest: UInt64,
        metadata: [String: String] = [:],
        opaqueModelState: Data? = nil,
        suiteParticipantState: [String: Data] = [:]
    ) throws -> Self {
        try state.validateCapacity()
        let digest = try TissueStateDigest.compute(state)
        let manifest = TissueCheckpointManifest(
            simulatorVersion: simulatorVersion,
            epoch: state.epoch,
            timeTick: state.time.tick,
            randomSeed: randomSeed,
            modelDigest: modelDigest,
            stateDigest: digest,
            metadata: metadata
        )
        return Self(
            manifest: manifest,
            state: state,
            opaqueModelState: opaqueModelState,
            suiteParticipantState: suiteParticipantState
        )
    }

    public func validated(expectedModelDigest: UInt64? = nil) throws -> Self {
        guard manifest.formatVersion == 1 else { throw TissueCheckpointError.unsupportedVersion(manifest.formatVersion) }
        guard manifest.epoch == state.epoch, manifest.timeTick == state.time.tick else { throw TissueCheckpointError.manifestStateMismatch }
        if let expectedModelDigest, expectedModelDigest != manifest.modelDigest { throw TissueCheckpointError.modelDigestMismatch }
        try state.validateCapacity()
        let digest = try TissueStateDigest.compute(state)
        guard digest == manifest.stateDigest else { throw TissueCheckpointError.stateDigestMismatch(expected: manifest.stateDigest, actual: digest) }
        return self
    }
}

public enum TissueCheckpointArchive {
    private static let magic = Data([0x4e, 0x54, 0x49, 0x53, 0x53, 0x55, 0x45, 0x01]) // NTISSUE + binary format 1
    private static let headerSize = 48

    public static func write(
        _ checkpoint: TissueCheckpoint,
        to url: URL,
        compression: TissueCheckpointCompression = .lzfse,
        atomically: Bool = true
    ) throws {
        let checkpoint = try checkpoint.validated()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plain = try encoder.encode(checkpoint)
        let payload: Data
        let actualCompression: TissueCheckpointCompression
        switch compression {
        case .none:
            payload = plain
            actualCompression = .none
        case .lzfse:
            #if canImport(Compression)
            payload = try compress(plain, algorithm: COMPRESSION_LZFSE)
            actualCompression = .lzfse
            #else
            payload = plain
            actualCompression = .none
            #endif
        }
        var archive = Data(capacity: headerSize + payload.count)
        archive.append(magic)
        append(UInt32(1), to: &archive)
        append(actualCompression.rawValue, to: &archive)
        append(UInt64(payload.count), to: &archive)
        append(UInt64(plain.count), to: &archive)
        append(CRC64.ecma(payload), to: &archive)
        append(checkpoint.manifest.modelDigest, to: &archive)
        archive.append(payload)
        guard archive.count == headerSize + payload.count else { throw TissueCheckpointError.headerEncoding }

        if atomically {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            do {
                try archive.write(to: temporary, options: [.atomic])
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: temporary, to: url)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } else {
            try archive.write(to: url)
        }
    }

    public static func read(from url: URL, expectedModelDigest: UInt64? = nil) throws -> TissueCheckpoint {
        try decode(Data(contentsOf: url, options: [.mappedIfSafe]), expectedModelDigest: expectedModelDigest)
    }

    public static func decode(_ archive: Data, expectedModelDigest: UInt64? = nil) throws -> TissueCheckpoint {
        guard archive.count >= headerSize else { throw TissueCheckpointError.truncated }
        guard archive.prefix(magic.count) == magic else { throw TissueCheckpointError.invalidMagic }
        var cursor = magic.count
        let version: UInt32 = try read(from: archive, cursor: &cursor)
        guard version == 1 else { throw TissueCheckpointError.unsupportedVersion(version) }
        let compressionRaw: UInt32 = try read(from: archive, cursor: &cursor)
        guard let compression = TissueCheckpointCompression(rawValue: compressionRaw) else { throw TissueCheckpointError.unsupportedCompression(compressionRaw) }
        let payloadLength: UInt64 = try read(from: archive, cursor: &cursor)
        let plainLength: UInt64 = try read(from: archive, cursor: &cursor)
        let checksum: UInt64 = try read(from: archive, cursor: &cursor)
        let modelDigest: UInt64 = try read(from: archive, cursor: &cursor)
        guard payloadLength <= UInt64(Int.max), plainLength <= UInt64(Int.max), cursor + Int(payloadLength) == archive.count else { throw TissueCheckpointError.invalidLength }
        let payload = Data(archive[cursor...])
        guard CRC64.ecma(payload) == checksum else { throw TissueCheckpointError.checksum }
        let plain: Data
        switch compression {
        case .none:
            plain = payload
        case .lzfse:
            #if canImport(Compression)
            plain = try decompress(payload, outputCount: Int(plainLength), algorithm: COMPRESSION_LZFSE)
            #else
            throw TissueCheckpointError.compressionUnavailable
            #endif
        }
        guard plain.count == Int(plainLength) else { throw TissueCheckpointError.invalidLength }
        let checkpoint = try PropertyListDecoder().decode(TissueCheckpoint.self, from: plain)
        guard checkpoint.manifest.modelDigest == modelDigest else { throw TissueCheckpointError.modelDigestMismatch }
        return try checkpoint.validated(expectedModelDigest: expectedModelDigest)
    }

    public static func inspect(_ archive: Data) throws -> (version: UInt32, compression: TissueCheckpointCompression, payloadBytes: UInt64, uncompressedBytes: UInt64, modelDigest: UInt64) {
        guard archive.count >= headerSize, archive.prefix(magic.count) == magic else { throw TissueCheckpointError.invalidMagic }
        var cursor = magic.count
        let version: UInt32 = try read(from: archive, cursor: &cursor)
        let compressionRaw: UInt32 = try read(from: archive, cursor: &cursor)
        guard let compression = TissueCheckpointCompression(rawValue: compressionRaw) else { throw TissueCheckpointError.unsupportedCompression(compressionRaw) }
        let payload: UInt64 = try read(from: archive, cursor: &cursor)
        let plain: UInt64 = try read(from: archive, cursor: &cursor)
        let _: UInt64 = try read(from: archive, cursor: &cursor)
        let model: UInt64 = try read(from: archive, cursor: &cursor)
        return (version, compression, payload, plain, model)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(from data: Data, cursor: inout Int) throws -> T {
        let size = MemoryLayout<T>.size
        guard cursor + size <= data.count else { throw TissueCheckpointError.truncated }
        let value = data[cursor..<(cursor + size)].withUnsafeBytes { bytes -> T in
            bytes.loadUnaligned(as: T.self)
        }
        cursor += size
        return T(littleEndian: value)
    }

    #if canImport(Compression)
    private static func compress(_ input: Data, algorithm: compression_algorithm) throws -> Data {
        guard !input.isEmpty else { return input }
        var capacity = max(input.count / 2, 1_024)
        while capacity <= max(input.count * 2, 1_024) {
            var output = Data(count: capacity)
            let written = input.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        algorithm
                    )
                }
            }
            if written > 0 { output.count = written; return output }
            capacity *= 2
        }
        throw TissueCheckpointError.compressionFailed
    }

    private static func decompress(_ input: Data, outputCount: Int, algorithm: compression_algorithm) throws -> Data {
        var output = Data(count: outputCount)
        let written = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    outputCount,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    algorithm
                )
            }
        }
        guard written == outputCount else { throw TissueCheckpointError.decompressionFailed }
        return output
    }
    #endif
}

public actor TissueCheckpointStore {
    public let directory: URL
    public let retainedCheckpointCount: Int

    public init(directory: URL, retainedCheckpointCount: Int = 5) {
        self.directory = directory
        self.retainedCheckpointCount = max(retainedCheckpointCount, 1)
    }

    @discardableResult
    public func save(_ checkpoint: TissueCheckpoint, compression: TissueCheckpointCompression = .lzfse) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "epoch-%020llu-tick-%020llu.ntissue", checkpoint.manifest.epoch, checkpoint.manifest.timeTick)
        let url = directory.appendingPathComponent(name)
        try TissueCheckpointArchive.write(checkpoint, to: url, compression: compression)
        try prune()
        return url
    }

    public func latest(expectedModelDigest: UInt64? = nil) throws -> TissueCheckpoint? {
        guard let url = try checkpointURLs().last else { return nil }
        return try TissueCheckpointArchive.read(from: url, expectedModelDigest: expectedModelDigest)
    }

    public func checkpointURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ntissue" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func prune() throws {
        let urls = try checkpointURLs()
        guard urls.count > retainedCheckpointCount else { return }
        for url in urls.prefix(urls.count - retainedCheckpointCount) { try FileManager.default.removeItem(at: url) }
    }
}

public enum TissueStateDigest {
    public static func compute(_ state: TissueRuntimeState) throws -> UInt64 {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return CRC64.ecma(try encoder.encode(state))
    }
}

private enum CRC64 {
    private static let polynomial: UInt64 = 0x42F0_E1EB_A9EA_3693

    static func ecma(_ data: Data) -> UInt64 {
        var crc: UInt64 = 0
        for byte in data {
            crc ^= UInt64(byte) << 56
            for _ in 0..<8 {
                crc = crc & 0x8000_0000_0000_0000 != 0 ? (crc << 1) ^ polynomial : crc << 1
            }
        }
        return crc
    }
}

public enum TissueCheckpointError: Error, Sendable, CustomStringConvertible {
    case invalidMagic
    case truncated
    case invalidLength
    case unsupportedVersion(UInt32)
    case unsupportedCompression(UInt32)
    case compressionUnavailable
    case compressionFailed
    case decompressionFailed
    case checksum
    case headerEncoding
    case manifestStateMismatch
    case modelDigestMismatch
    case stateDigestMismatch(expected: UInt64, actual: UInt64)

    public var description: String {
        switch self {
        case .invalidMagic: return "File is not a NumiTissue checkpoint"
        case .truncated: return "NumiTissue checkpoint is truncated"
        case .invalidLength: return "NumiTissue checkpoint has invalid lengths"
        case .unsupportedVersion(let value): return "Unsupported NumiTissue checkpoint version \(value)"
        case .unsupportedCompression(let value): return "Unsupported NumiTissue checkpoint compression \(value)"
        case .compressionUnavailable: return "Checkpoint compression is unavailable on this platform"
        case .compressionFailed: return "Checkpoint compression failed"
        case .decompressionFailed: return "Checkpoint decompression failed"
        case .checksum: return "Checkpoint checksum failed"
        case .headerEncoding: return "Checkpoint header encoding failed"
        case .manifestStateMismatch: return "Checkpoint manifest and state epoch/time disagree"
        case .modelDigestMismatch: return "Checkpoint model digest does not match"
        case .stateDigestMismatch(let expected, let actual): return "Checkpoint state digest mismatch: expected \(expected), received \(actual)"
        }
    }
}
