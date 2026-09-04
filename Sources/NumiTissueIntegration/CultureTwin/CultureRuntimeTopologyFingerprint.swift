import Foundation
import NumiTissueRuntime

public enum CultureRuntimeTopologyFingerprint {
    /// Deterministic 64-bit FNV-1a over compartment topology and source geometry. This is a cache
    /// key, not a cryptographic evidence identity; scientific artifacts continue to use SHA-256.
    public static func value(_ state: TissueRuntimeState) throws -> UInt64 {
        guard !state.compartments.isEmpty else {
            throw CultureTwinError.invalid("cannot fingerprint empty electrical topology")
        }
        var hash: UInt64 = 0xcbf29ce484222325
        func mixByte(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        func mix<T>(_ value: T) {
            var copy = value
            withUnsafeBytes(of: &copy) { bytes in
                for byte in bytes { mixByte(byte) }
            }
        }
        mix(UInt64(state.compartments.count))
        mix(UInt64(state.segments.count))
        for compartment in state.compartments {
            mix(compartment.id.rawValue)
            mix(compartment.neuronIndex)
            mix(compartment.parentIndex)
        }
        for segment in state.segments {
            mix(segment.id.rawValue)
            mix(segment.cellIndex)
            mix(segment.parentSegmentIndex)
            mix(segment.compartmentIndex)
            mix(segment.type)
            mix(segment.start.x.bitPattern); mix(segment.start.y.bitPattern); mix(segment.start.z.bitPattern)
            mix(segment.end.x.bitPattern); mix(segment.end.y.bitPattern); mix(segment.end.z.bitPattern)
            mix(segment.radiusMicrometers.bitPattern)
        }
        return hash
    }
}
