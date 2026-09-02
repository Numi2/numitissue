import Foundation

@frozen
public struct SemanticVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: UInt16
    public let minor: UInt16
    public let patch: UInt16
    public let prerelease: String?

    public init(_ major: UInt16, _ minor: UInt16, _ patch: UInt16, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard let prerelease, !prerelease.isEmpty else { return base }
        return "\(base)-\(prerelease)"
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?): return left < right
        }
    }
}

public enum NumiTissueBuild {
    public static let version = SemanticVersion(0, 1, 0, prerelease: "development")
    public static let modelSchemaVersion: UInt32 = 1
    public static let snapshotSchemaVersion: UInt32 = 1
    public static let gpuABIVersion: UInt32 = 1
}
import Foundation

public protocol TissueIdentifier: RawRepresentable, Codable, Hashable, Sendable, Comparable, CustomStringConvertible where RawValue == UInt64 {
    init(rawValue: UInt64)
}

public extension TissueIdentifier {
    var description: String { String(rawValue) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

@frozen public struct TileID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct CellID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct LineageID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct SegmentID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct CompartmentID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct SynapseID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct RouteID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct PopulationID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct MicrodomainID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct ElectrodeID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }
@frozen public struct TransactionID: TissueIdentifier { public let rawValue: UInt64; public init(rawValue: UInt64) { self.rawValue = rawValue } }

/// Deterministically allocates stable identifiers from a namespace and monotonic local index.
public struct IdentifierAllocator<ID: TissueIdentifier>: Sendable {
    private let namespace: UInt32
    private var nextLocal: UInt32

    public init(namespace: UInt32, startingAt: UInt32 = 0) {
        self.namespace = namespace
        self.nextLocal = startingAt
    }

    public mutating func next() -> ID {
        let raw = (UInt64(namespace) << 32) | UInt64(nextLocal)
        nextLocal &+= 1
        return ID(rawValue: raw)
    }
}
import Foundation

public typealias Float4 = SIMD4<Float>
public typealias UInt4 = SIMD4<UInt32>
public typealias Int4 = SIMD4<Int32>

@frozen
public struct TileCoordinate: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var x: Int32
    public var y: Int32
    public var z: Int32

    public init(x: Int32, y: Int32, z: Int32) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.z != rhs.z { return lhs.z < rhs.z }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.x < rhs.x
    }

    public var description: String { "(\(x), \(y), \(z))" }
    public var packed: Int4 { Int4(x, y, z, 0) }

    public func neighbor(dx: Int32, dy: Int32, dz: Int32) -> Self {
        Self(x: x + dx, y: y + dy, z: z + dz)
    }
}

@frozen
public struct AxisAlignedBoundingBox: Sendable, Hashable {
    public var minimum: Float4
    public var maximum: Float4

    public init(minimum: Float4, maximum: Float4) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var extent: Float4 { maximum - minimum }

    public func contains(_ point: Float4) -> Bool {
        point.x >= minimum.x && point.x <= maximum.x &&
        point.y >= minimum.y && point.y <= maximum.y &&
        point.z >= minimum.z && point.z <= maximum.z
    }
}

@inlinable
public func squaredDistance(_ a: Float4, _ b: Float4) -> Float {
    let d = a - b
    return d.x * d.x + d.y * d.y + d.z * d.z
}

@inlinable
public func length3(_ value: Float4) -> Float {
    sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
}

@inlinable
public func normalize3(_ value: Float4, fallback: Float4 = Float4(1, 0, 0, 0)) -> Float4 {
    let magnitude = length3(value)
    guard magnitude > 1e-12 else { return fallback }
    return Float4(value.x / magnitude, value.y / magnitude, value.z / magnitude, 0)
}
import Foundation

/// Time is represented as integer 25-microsecond ticks to avoid cross-device drift.
@frozen
public struct TissueTime: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let quantumMicroseconds: UInt64 = 25
    public var tick: UInt64

    public init(tick: UInt64 = 0) { self.tick = tick }

    public init(microseconds: UInt64) {
        precondition(microseconds.isMultiple(of: Self.quantumMicroseconds))
        self.tick = microseconds / Self.quantumMicroseconds
    }

    public var microseconds: UInt64 { tick * Self.quantumMicroseconds }
    public var milliseconds: Double { Double(microseconds) / 1_000 }
    public var seconds: Double { Double(microseconds) / 1_000_000 }
    public var description: String { "\(milliseconds) ms" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.tick < rhs.tick }
    public static func + (lhs: Self, rhs: UInt64) -> Self { Self(tick: lhs.tick &+ rhs) }
}

@frozen
public struct MultiRateClock: Sendable {
    public private(set) var time: TissueTime
    public private(set) var transactionIndex: UInt64
    public let schedule: SchedulerConfiguration

    public init(
        schedule: SchedulerConfiguration,
        start: TissueTime = .init(),
        transactionIndex: UInt64 = 0
    ) {
        self.schedule = schedule
        self.time = start
        self.transactionIndex = transactionIndex
    }

    public mutating func advanceCommittedTransaction() {
        let ticks = UInt64(schedule.transactionMicroseconds) / TissueTime.quantumMicroseconds
        time = time + ticks
        transactionIndex &+= 1
    }

    public func isDue(periodMicroseconds: UInt64) -> Bool {
        time.microseconds.isMultiple(of: periodMicroseconds)
    }

    public var cellMechanicsDue: Bool { isDue(periodMicroseconds: UInt64(schedule.cellMechanicsMicroseconds)) }
    public var regulatoryDue: Bool { isDue(periodMicroseconds: UInt64(schedule.regulatoryMicroseconds)) }
    public var structuralDue: Bool { isDue(periodMicroseconds: UInt64(schedule.structuralMicroseconds)) }
}
import Foundation

/// Philox-4x32-10 counter-based random number generator.
/// The matching Metal implementation uses the same constants and round order.
@frozen
public struct PhiloxCounter: Sendable, Hashable {
    public var x: UInt32
    public var y: UInt32
    public var z: UInt32
    public var w: UInt32

    public init(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ w: UInt32) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }
}

@frozen
public struct PhiloxKey: Sendable, Hashable {
    public var x: UInt32
    public var y: UInt32

    public init(seed: UInt64) {
        self.x = UInt32(truncatingIfNeeded: seed)
        self.y = UInt32(truncatingIfNeeded: seed >> 32)
    }
}

public enum CounterRandom {
    @usableFromInline static let multiplier0: UInt32 = 0xD251_1F53
    @usableFromInline static let multiplier1: UInt32 = 0xCD9E_8D57
    @usableFromInline static let Weyl0: UInt32 = 0x9E37_79B9
    @usableFromInline static let Weyl1: UInt32 = 0xBB67_AE85

    @inlinable
    public static func generate(counter: PhiloxCounter, key initialKey: PhiloxKey) -> PhiloxCounter {
        var value = counter
        var key = initialKey
        for _ in 0..<10 {
            value = round(value, key: key)
            key.x &+= Weyl0
            key.y &+= Weyl1
        }
        return value
    }

    @inlinable
    static func round(_ counter: PhiloxCounter, key: PhiloxKey) -> PhiloxCounter {
        let product0 = multiplier0.multipliedFullWidth(by: counter.x)
        let product1 = multiplier1.multipliedFullWidth(by: counter.z)
        return PhiloxCounter(
            product1.high ^ counter.y ^ key.x,
            product1.low,
            product0.high ^ counter.w ^ key.y,
            product0.low
        )
    }

    @inlinable
    public static func uniform01(_ value: UInt32) -> Float {
        // Open interval (0, 1); 24 high-quality mantissa bits.
        let mantissa = (value >> 8) | 1
        return Float(mantissa) * (1.0 / 16_777_217.0)
    }

    @inlinable
    public static func normalPair(_ a: UInt32, _ b: UInt32) -> SIMD2<Float> {
        let u1 = max(uniform01(a), 1e-7)
        let u2 = uniform01(b)
        let radius = sqrt(-2 * log(u1))
        let angle = 2 * Float.pi * u2
        return SIMD2<Float>(radius * cos(angle), radius * sin(angle))
    }
}

@frozen
public struct RandomAddress: Sendable, Hashable {
    public var transaction: UInt64
    public var entity: UInt64
    public var stream: UInt32
    public var sample: UInt32

    public init(transaction: UInt64, entity: UInt64, stream: UInt32, sample: UInt32 = 0) {
        self.transaction = transaction
        self.entity = entity
        self.stream = stream
        self.sample = sample
    }

    public func counter() -> PhiloxCounter {
        PhiloxCounter(
            UInt32(truncatingIfNeeded: transaction),
            UInt32(truncatingIfNeeded: transaction >> 32) ^ stream,
            UInt32(truncatingIfNeeded: entity),
            UInt32(truncatingIfNeeded: entity >> 32) ^ sample
        )
    }
}
