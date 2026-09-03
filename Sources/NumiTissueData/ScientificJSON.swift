import CoreFoundation
import Foundation

/// Finite, deterministic, Sendable JSON used at external data boundaries.
public indirect enum ScientificJSONValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case string(String)
    case array([ScientificJSONValue])
    case object([String: ScientificJSONValue])

    public var objectValue: [String: ScientificJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [ScientificJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .signedInteger(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .number(let value): return String(format: "%.17g", value)
        case .boolean(let value): return value ? "true" : "false"
        case .null, .array, .object: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .signedInteger(let value): return Double(value)
        case .unsignedInteger(let value): return Double(value)
        case .number(let value): return value
        case .string(let value):
            let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            return parsed?.isFinite == true ? parsed : nil
        case .boolean, .null, .array, .object: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .signedInteger(let value): return value
        case .unsignedInteger(let value):
            return value <= UInt64(Int64.max) ? Int64(value) : nil
        case .number(let value):
            guard value.isFinite,
                  value >= Double(Int64.min),
                  value < Double(Int64.max),
                  value.rounded(.towardZero) == value else {
                return nil
            }
            return Int64(value)
        case .string(let value):
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .boolean, .null, .array, .object: return nil
        }
    }

    public var uint64Value: UInt64? {
        switch self {
        case .unsignedInteger(let value): return value
        case .signedInteger(let value): return value >= 0 ? UInt64(value) : nil
        case .number(let value):
            guard value.isFinite,
                  value >= 0,
                  value < 18_446_744_073_709_551_616.0,
                  value.rounded(.towardZero) == value else {
                return nil
            }
            return UInt64(value)
        case .string(let value):
            return UInt64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .boolean, .null, .array, .object: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .boolean(let value): return value
        case .signedInteger(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .unsignedInteger(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .number(let value):
            return value == 0 ? false : (value == 1 ? true : nil)
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "t", "yes", "y", "1": return true
            case "false", "f", "no", "n", "0": return false
            default: return nil
            }
        case .null, .array, .object: return nil
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public subscript(key: String) -> ScientificJSONValue? {
        objectValue?[key]
    }

    public func firstValue(forKeys keys: [String]) -> ScientificJSONValue? {
        guard let object = objectValue else { return nil }
        for key in keys {
            if let value = object[key], !value.isNull { return value }
        }
        return nil
    }

    public func value(at path: [ScientificJSONPathComponent]) -> ScientificJSONValue? {
        var current = self
        for component in path {
            switch (component, current) {
            case (.key(let key), .object(let object)):
                guard let next = object[key] else { return nil }
                current = next
            case (.index(let index), .array(let array)):
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    public func recursivelyCollectedStrings(
        forKeys keys: Set<String>,
        maximumResults: Int = 10_000
    ) -> [String] {
        guard maximumResults > 0 else { return [] }
        var result: [String] = []
        var stack: [ScientificJSONValue] = [self]
        while let current = stack.popLast(), result.count < maximumResults {
            switch current {
            case .object(let object):
                for key in object.keys.sorted().reversed() {
                    guard let value = object[key] else { continue }
                    if keys.contains(key), let string = value.stringValue {
                        result.append(string)
                    }
                    stack.append(value)
                }
            case .array(let values):
                stack.append(contentsOf: values.reversed())
            default:
                break
            }
        }
        return result
    }
}

public enum ScientificJSONPathComponent: Sendable, Equatable, Hashable {
    case key(String)
    case index(Int)
}

public struct ScientificJSONLimits: Codable, Sendable, Equatable {
    public var maximumBytes: UInt64
    public var maximumDepth: Int
    public var maximumNodes: Int
    public var maximumArrayElements: Int
    public var maximumObjectMembers: Int
    public var maximumStringBytes: Int

    public init(
        maximumBytes: UInt64 = 512 * 1_024 * 1_024,
        maximumDepth: Int = 128,
        maximumNodes: Int = 10_000_000,
        maximumArrayElements: Int = 5_000_000,
        maximumObjectMembers: Int = 1_000_000,
        maximumStringBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumArrayElements = maximumArrayElements
        self.maximumObjectMembers = maximumObjectMembers
        self.maximumStringBytes = maximumStringBytes
    }

    public func validated() throws -> Self {
        guard maximumBytes > 0,
              maximumDepth > 0,
              maximumDepth <= 1_024,
              maximumNodes > 0,
              maximumArrayElements > 0,
              maximumObjectMembers > 0,
              maximumStringBytes > 0 else {
            throw ScientificJSONError.invalidLimits
        }
        return self
    }
}

public enum ScientificJSONParser {
    public static func decode(
        _ data: Data,
        limits sourceLimits: ScientificJSONLimits = ScientificJSONLimits()
    ) throws -> ScientificJSONValue {
        let limits = try sourceLimits.validated()
        guard !data.isEmpty,
              UInt64(data.count) <= limits.maximumBytes else {
            throw ScientificJSONError.payloadTooLarge(
                actual: UInt64(data.count),
                maximum: limits.maximumBytes
            )
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw ScientificJSONError.invalidJSON(String(describing: error))
        }
        var nodeCount = 0
        return try convert(
            root,
            depth: 0,
            nodeCount: &nodeCount,
            limits: limits
        )
    }

    private static func convert(
        _ source: Any,
        depth: Int,
        nodeCount: inout Int,
        limits: ScientificJSONLimits
    ) throws -> ScientificJSONValue {
        guard depth <= limits.maximumDepth else {
            throw ScientificJSONError.maximumDepthExceeded(limits.maximumDepth)
        }
        nodeCount += 1
        guard nodeCount <= limits.maximumNodes else {
            throw ScientificJSONError.maximumNodesExceeded(limits.maximumNodes)
        }
        if source is NSNull { return .null }
        if let string = source as? String {
            guard string.utf8.count <= limits.maximumStringBytes else {
                throw ScientificJSONError.stringTooLarge(string.utf8.count)
            }
            return .string(string)
        }
        if let number = source as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            switch String(cString: number.objCType) {
            case "c", "s", "i", "l", "q":
                return .signedInteger(number.int64Value)
            case "C", "S", "I", "L", "Q":
                return .unsignedInteger(number.uint64Value)
            default:
                let value = number.doubleValue
                guard value.isFinite else {
                    throw ScientificJSONError.nonFiniteNumber
                }
                return .number(value)
            }
        }
        if let array = source as? [Any] {
            guard array.count <= limits.maximumArrayElements else {
                throw ScientificJSONError.arrayTooLarge(array.count)
            }
            return .array(try array.map {
                try convert(
                    $0,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    limits: limits
                )
            })
        }
        if let object = source as? [String: Any] {
            guard object.count <= limits.maximumObjectMembers else {
                throw ScientificJSONError.objectTooLarge(object.count)
            }
            var result: [String: ScientificJSONValue] = [:]
            result.reserveCapacity(object.count)
            for key in object.keys.sorted() {
                guard !key.isEmpty,
                      key.utf8.count <= limits.maximumStringBytes,
                      let value = object[key] else {
                    throw ScientificJSONError.invalidObjectKey
                }
                result[key] = try convert(
                    value,
                    depth: depth + 1,
                    nodeCount: &nodeCount,
                    limits: limits
                )
            }
            return .object(result)
        }
        throw ScientificJSONError.unsupportedFoundationType(
            String(describing: type(of: source))
        )
    }
}

public enum ScientificJSONError: Error, Sendable, CustomStringConvertible {
    case invalidLimits
    case payloadTooLarge(actual: UInt64, maximum: UInt64)
    case invalidJSON(String)
    case maximumDepthExceeded(Int)
    case maximumNodesExceeded(Int)
    case stringTooLarge(Int)
    case nonFiniteNumber
    case arrayTooLarge(Int)
    case objectTooLarge(Int)
    case invalidObjectKey
    case unsupportedFoundationType(String)

    public var description: String {
        switch self {
        case .invalidLimits:
            return "Scientific JSON limits are invalid."
        case .payloadTooLarge(let actual, let maximum):
            return "Scientific JSON uses \(actual) bytes; maximum is \(maximum)."
        case .invalidJSON(let detail):
            return "Scientific payload is not valid JSON: \(detail)"
        case .maximumDepthExceeded(let maximum):
            return "Scientific JSON exceeds maximum depth \(maximum)."
        case .maximumNodesExceeded(let maximum):
            return "Scientific JSON exceeds maximum node count \(maximum)."
        case .stringTooLarge(let bytes):
            return "Scientific JSON contains a string using \(bytes) bytes."
        case .nonFiniteNumber:
            return "Scientific JSON contains a non-finite number."
        case .arrayTooLarge(let count):
            return "Scientific JSON array has \(count) elements."
        case .objectTooLarge(let count):
            return "Scientific JSON object has \(count) members."
        case .invalidObjectKey:
            return "Scientific JSON contains an invalid object key."
        case .unsupportedFoundationType(let type):
            return "Scientific JSON parser received unsupported Foundation type \(type)."
        }
    }
}
