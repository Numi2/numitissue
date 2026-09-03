import Foundation

public struct ScientificFileDigestResult: Codable, Sendable, Hashable {
    public var sha256: ScientificSHA256Digest
    public var byteCount: UInt64

    public init(sha256: ScientificSHA256Digest, byteCount: UInt64) {
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public enum ScientificFileDigester {
    public static func sha256(
        at url: URL,
        chunkBytes: Int = 4 * 1_024 * 1_024,
        maximumBytes: UInt64? = nil
    ) throws -> ScientificFileDigestResult {
        guard chunkBytes >= 4_096,
              chunkBytes <= 256 * 1_024 * 1_024 else {
            throw ScientificFileDigestError.invalidChunkSize(chunkBytes)
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ScientificFileDigestError.openFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }
        defer { try? handle.close() }

        var digest = IncrementalSHA256()
        var byteCount: UInt64 = 0
        do {
            while let data = try handle.read(upToCount: chunkBytes),
                  !data.isEmpty {
                let addition = byteCount.addingReportingOverflow(
                    UInt64(data.count)
                )
                guard !addition.overflow else {
                    throw ScientificFileDigestError.byteCountOverflow
                }
                byteCount = addition.partialValue
                if let maximumBytes, byteCount > maximumBytes {
                    throw ScientificFileDigestError.maximumBytesExceeded(
                        maximum: maximumBytes,
                        actual: byteCount
                    )
                }
                try digest.update(data)
            }
        } catch let error as ScientificFileDigestError {
            throw error
        } catch let error as IncrementalSHA256Error {
            throw ScientificFileDigestError.internalDigestFailure(
                error.description
            )
        } catch {
            throw ScientificFileDigestError.readFailed(
                path: url.path,
                reason: String(describing: error)
            )
        }

        do {
            return ScientificFileDigestResult(
                sha256: ScientificSHA256Digest(bytes: try digest.finalize()),
                byteCount: byteCount
            )
        } catch let error as IncrementalSHA256Error {
            throw ScientificFileDigestError.internalDigestFailure(
                error.description
            )
        }
    }
}

public enum ScientificFileDigestError: Error, Sendable, CustomStringConvertible {
    case invalidChunkSize(Int)
    case openFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case byteCountOverflow
    case maximumBytesExceeded(maximum: UInt64, actual: UInt64)
    case internalDigestFailure(String)

    public var description: String {
        switch self {
        case .invalidChunkSize(let size):
            return "Scientific digest chunk size \(size) is invalid."
        case .openFailed(let path, let reason):
            return "Unable to open \(path) for scientific hashing: \(reason)"
        case .readFailed(let path, let reason):
            return "Unable to read \(path) for scientific hashing: \(reason)"
        case .byteCountOverflow:
            return "Scientific file byte count overflowed UInt64."
        case .maximumBytesExceeded(let maximum, let actual):
            return "Scientific file has \(actual) bytes, above the \(maximum)-byte verification bound."
        case .internalDigestFailure(let reason):
            return "Scientific SHA-256 state is invalid: \(reason)"
        }
    }
}

private enum IncrementalSHA256Error: Error, CustomStringConvertible {
    case byteCountOverflow
    case invalidBlockLength(Int)
    case invalidFinalState(Int)

    var description: String {
        switch self {
        case .byteCountOverflow:
            return "input byte count overflowed UInt64"
        case .invalidBlockLength(let count):
            return "SHA-256 block contains \(count) bytes instead of 64"
        case .invalidFinalState(let count):
            return "SHA-256 final pending state contains \(count) bytes"
        }
    }
}

private struct IncrementalSHA256 {
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

    private var state = Self.initial
    private var pending = Data()
    private var totalBytes: UInt64 = 0
    private var finalized = false

    mutating func update(_ data: Data) throws {
        guard !finalized else {
            throw IncrementalSHA256Error.invalidFinalState(pending.count)
        }
        guard !data.isEmpty else { return }
        let addition = totalBytes.addingReportingOverflow(UInt64(data.count))
        guard !addition.overflow else {
            throw IncrementalSHA256Error.byteCountOverflow
        }
        totalBytes = addition.partialValue
        pending.append(data)
        while pending.count >= 64 {
            let block = Data(pending.prefix(64))
            try process(block)
            pending.removeFirst(64)
        }
    }

    mutating func finalize() throws -> [UInt8] {
        guard !finalized else {
            throw IncrementalSHA256Error.invalidFinalState(pending.count)
        }
        finalized = true
        let bitLength = totalBytes &* 8
        pending.append(0x80)
        while pending.count % 64 != 56 {
            pending.append(0)
        }
        var bigEndianLength = bitLength.bigEndian
        withUnsafeBytes(of: &bigEndianLength) {
            pending.append(contentsOf: $0)
        }
        while pending.count >= 64 {
            let block = Data(pending.prefix(64))
            try process(block)
            pending.removeFirst(64)
        }
        guard pending.isEmpty else {
            throw IncrementalSHA256Error.invalidFinalState(pending.count)
        }

        var output: [UInt8] = []
        output.reserveCapacity(32)
        for word in state {
            var bigEndian = word.bigEndian
            withUnsafeBytes(of: &bigEndian) {
                output.append(contentsOf: $0)
            }
        }
        return output
    }

    private mutating func process(_ block: Data) throws {
        guard block.count == 64 else {
            throw IncrementalSHA256Error.invalidBlockLength(block.count)
        }
        let bytes = [UInt8](block)
        var schedule = Array(repeating: UInt32(0), count: 64)
        for index in 0..<16 {
            let base = index * 4
            schedule[index] =
                UInt32(bytes[base]) << 24 |
                UInt32(bytes[base + 1]) << 16 |
                UInt32(bytes[base + 2]) << 8 |
                UInt32(bytes[base + 3])
        }
        for index in 16..<64 {
            let s0 = Self.rotateRight(schedule[index - 15], by: 7) ^
                Self.rotateRight(schedule[index - 15], by: 18) ^
                (schedule[index - 15] >> 3)
            let s1 = Self.rotateRight(schedule[index - 2], by: 17) ^
                Self.rotateRight(schedule[index - 2], by: 19) ^
                (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16] &+
                s0 &+
                schedule[index - 7] &+
                s1
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
            let upper1 = Self.rotateRight(e, by: 6) ^
                Self.rotateRight(e, by: 11) ^
                Self.rotateRight(e, by: 25)
            let choose = (e & f) ^ ((~e) & g)
            let temporary1 = h &+
                upper1 &+
                choose &+
                Self.constants[index] &+
                schedule[index]
            let upper0 = Self.rotateRight(a, by: 2) ^
                Self.rotateRight(a, by: 13) ^
                Self.rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = upper0 &+ majority

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

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
