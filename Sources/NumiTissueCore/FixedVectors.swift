import Foundation

/// Small fixed-width value vectors not provided by the Swift standard library. They intentionally
/// expose only deterministic storage and indexing rather than pretending to be hardware SIMD types.
@frozen
public struct SIMD6<Scalar: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public var x0: Scalar
    public var x1: Scalar
    public var x2: Scalar
    public var x3: Scalar
    public var x4: Scalar
    public var x5: Scalar

    public init(_ x0: Scalar, _ x1: Scalar, _ x2: Scalar, _ x3: Scalar, _ x4: Scalar, _ x5: Scalar) {
        self.x0 = x0; self.x1 = x1; self.x2 = x2; self.x3 = x3; self.x4 = x4; self.x5 = x5
    }

    public subscript(index: Int) -> Scalar {
        get {
            switch index {
            case 0: return x0
            case 1: return x1
            case 2: return x2
            case 3: return x3
            case 4: return x4
            case 5: return x5
            default: preconditionFailure("SIMD6 index \(index) is outside 0..<6")
            }
        }
        set {
            switch index {
            case 0: x0 = newValue
            case 1: x1 = newValue
            case 2: x2 = newValue
            case 3: x3 = newValue
            case 4: x4 = newValue
            case 5: x5 = newValue
            default: preconditionFailure("SIMD6 index \(index) is outside 0..<6")
            }
        }
    }

    public var array: [Scalar] { [x0, x1, x2, x3, x4, x5] }
}

public extension SIMD6 where Scalar: AdditiveArithmetic {
    static var zero: Self { Self(.zero, .zero, .zero, .zero, .zero, .zero) }
}

@frozen
public struct SIMD12<Scalar: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public var x0: Scalar
    public var x1: Scalar
    public var x2: Scalar
    public var x3: Scalar
    public var x4: Scalar
    public var x5: Scalar
    public var x6: Scalar
    public var x7: Scalar
    public var x8: Scalar
    public var x9: Scalar
    public var x10: Scalar
    public var x11: Scalar

    public init(
        _ x0: Scalar, _ x1: Scalar, _ x2: Scalar, _ x3: Scalar,
        _ x4: Scalar, _ x5: Scalar, _ x6: Scalar, _ x7: Scalar,
        _ x8: Scalar, _ x9: Scalar, _ x10: Scalar, _ x11: Scalar
    ) {
        self.x0 = x0; self.x1 = x1; self.x2 = x2; self.x3 = x3
        self.x4 = x4; self.x5 = x5; self.x6 = x6; self.x7 = x7
        self.x8 = x8; self.x9 = x9; self.x10 = x10; self.x11 = x11
    }

    public subscript(index: Int) -> Scalar {
        get {
            switch index {
            case 0: return x0
            case 1: return x1
            case 2: return x2
            case 3: return x3
            case 4: return x4
            case 5: return x5
            case 6: return x6
            case 7: return x7
            case 8: return x8
            case 9: return x9
            case 10: return x10
            case 11: return x11
            default: preconditionFailure("SIMD12 index \(index) is outside 0..<12")
            }
        }
        set {
            switch index {
            case 0: x0 = newValue
            case 1: x1 = newValue
            case 2: x2 = newValue
            case 3: x3 = newValue
            case 4: x4 = newValue
            case 5: x5 = newValue
            case 6: x6 = newValue
            case 7: x7 = newValue
            case 8: x8 = newValue
            case 9: x9 = newValue
            case 10: x10 = newValue
            case 11: x11 = newValue
            default: preconditionFailure("SIMD12 index \(index) is outside 0..<12")
            }
        }
    }

    public var array: [Scalar] { [x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11] }
}

public extension SIMD12 where Scalar: AdditiveArithmetic {
    static var zero: Self { Self(.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero) }
}
