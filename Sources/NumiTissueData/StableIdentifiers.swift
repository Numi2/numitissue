import Foundation

public enum StableIdentifierDomain: UInt32, Codable, Sendable, CaseIterable {
    case population = 0x4E54_0001
    case cell = 0x4E54_0002
    case lineage = 0x4E54_0003
    case synapse = 0x4E54_0004
    case molecularDomain = 0x4E54_0005
    case provenance = 0x4E54_0006
}

public struct StableIdentifierBinding: Codable, Sendable, Hashable {
    public var sourceIdentifier: String
    public var rawValue: UInt64

    public init(sourceIdentifier: String, rawValue: UInt64) {
        self.sourceIdentifier = sourceIdentifier
        self.rawValue = rawValue
    }
}

public enum StableTextHash {
    private static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    public static func fnv1a64(_ text: String) -> UInt64 {
        fnv1a64(bytes: text.utf8)
    }

    public static func fnv1a64<Bytes: Sequence>(bytes: Bytes) -> UInt64
        where Bytes.Element == UInt8 {
        var hash = fnvOffset
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        return hash
    }

    public static func hexadecimal(_ value: UInt64) -> String {
        String(format: "%016llx", value)
    }
}

public struct StableIdentifierMap: Codable, Sendable, Equatable {
    public var domain: StableIdentifierDomain
    public var bindings: [StableIdentifierBinding]

    public init(
        domain: StableIdentifierDomain,
        sourceIdentifiers: [String]
    ) throws {
        guard Set(sourceIdentifiers).count == sourceIdentifiers.count,
              sourceIdentifiers.allSatisfy({ !$0.isEmpty }) else {
            throw StableIdentifierError.invalidSourceIdentifiers
        }
        self.domain = domain

        var occupied = Set<UInt64>()
        var result: [StableIdentifierBinding] = []
        result.reserveCapacity(sourceIdentifiers.count)

        for source in sourceIdentifiers.sorted() {
            var probe: UInt32 = 0
            var selected: UInt64?
            while selected == nil {
                let key = probe == 0 ? source : "\(source)#\(probe)"
                let hash = StableTextHash.fnv1a64(key)
                let local = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
                let raw = (UInt64(domain.rawValue) << 32) | UInt64(local)
                if occupied.insert(raw).inserted {
                    selected = raw
                } else {
                    let (next, overflow) = probe.addingReportingOverflow(1)
                    guard !overflow else {
                        throw StableIdentifierError.exhaustedDomain(domain)
                    }
                    probe = next
                }
            }
            guard let selected else {
                throw StableIdentifierError.exhaustedDomain(domain)
            }
            result.append(StableIdentifierBinding(
                sourceIdentifier: source,
                rawValue: selected
            ))
        }
        bindings = result
    }

    public func rawValue(for sourceIdentifier: String) -> UInt64? {
        bindings.first { $0.sourceIdentifier == sourceIdentifier }?.rawValue
    }

    public func requireRawValue(for sourceIdentifier: String) throws -> UInt64 {
        guard let value = rawValue(for: sourceIdentifier) else {
            throw StableIdentifierError.unknownSourceIdentifier(sourceIdentifier)
        }
        return value
    }
}

public struct StableIdentifierRegistry: Codable, Sendable, Equatable {
    public var populations: StableIdentifierMap
    public var cells: StableIdentifierMap
    public var lineages: StableIdentifierMap
    public var synapses: StableIdentifierMap
    public var molecularDomains: StableIdentifierMap

    public init(blueprint: CanonicalTissueBlueprint) throws {
        populations = try StableIdentifierMap(
            domain: .population,
            sourceIdentifiers: blueprint.populations.map(\.id)
        )
        cells = try StableIdentifierMap(
            domain: .cell,
            sourceIdentifiers: blueprint.cells.map(\.id)
        )
        lineages = try StableIdentifierMap(
            domain: .lineage,
            sourceIdentifiers: Array(Set(blueprint.cells.map(\.lineageID)))
        )
        synapses = try StableIdentifierMap(
            domain: .synapse,
            sourceIdentifiers: blueprint.synapses.map(\.id)
        )
        molecularDomains = try StableIdentifierMap(
            domain: .molecularDomain,
            sourceIdentifiers: blueprint.molecularDomains.map(\.id)
        )
    }
}

public enum StableIdentifierError: Error, Sendable, CustomStringConvertible {
    case invalidSourceIdentifiers
    case exhaustedDomain(StableIdentifierDomain)
    case unknownSourceIdentifier(String)

    public var description: String {
        switch self {
        case .invalidSourceIdentifiers:
            return "Stable identifier source values must be unique and non-empty."
        case .exhaustedDomain(let domain):
            return "Stable identifier domain \(domain) is exhausted."
        case .unknownSourceIdentifier(let identifier):
            return "Stable identifier \(identifier) is not registered."
        }
    }
}
