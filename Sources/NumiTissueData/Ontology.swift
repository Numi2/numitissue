import Foundation

public struct OntologyTerm: Codable, Sendable, Hashable, Comparable {
    public var curie: String
    public var label: String
    public var definition: String?
    public var synonyms: [String]

    public init(
        curie: String,
        label: String,
        definition: String? = nil,
        synonyms: [String] = []
    ) {
        self.curie = curie
        self.label = label
        self.definition = definition
        self.synonyms = synonyms
    }

    public var namespace: String {
        curie.split(separator: ":", maxSplits: 1).first.map(String.init) ?? curie
    }

    public func validated() throws -> Self {
        let components = curie.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OntologyError.invalidTerm(curie)
        }
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.curie == rhs.curie ? lhs.label < rhs.label : lhs.curie < rhs.curie
    }

    public static let mouse = Self(curie: "NCBITaxon:10090", label: "Mus musculus")
    public static let human = Self(curie: "NCBITaxon:9606", label: "Homo sapiens")
    public static let drosophila = Self(
        curie: "NCBITaxon:7227",
        label: "Drosophila melanogaster"
    )
}

public enum OntologyRelation: String, Codable, Sendable, CaseIterable, Hashable {
    case exact
    case broader
    case narrower
    case related
    case partOf
    case developsFrom
    case locatedIn
    case hasPhenotype
}

public struct OntologyMapping: Codable, Sendable, Hashable {
    public var source: OntologyTerm
    public var target: OntologyTerm
    public var relation: OntologyRelation
    public var confidence: Double
    public var evidenceRecordIDs: [String]

    public init(
        source: OntologyTerm,
        target: OntologyTerm,
        relation: OntologyRelation,
        confidence: Double = 1,
        evidenceRecordIDs: [String] = []
    ) {
        self.source = source
        self.target = target
        self.relation = relation
        self.confidence = confidence
        self.evidenceRecordIDs = evidenceRecordIDs
    }

    public func validated() throws -> Self {
        _ = try source.validated()
        _ = try target.validated()
        guard source.curie != target.curie,
              confidence.isFinite,
              (0...1).contains(confidence) else {
            throw OntologyError.invalidMapping(source.curie, target.curie)
        }
        return self
    }
}

public struct CellTaxonomyIdentity: Codable, Sendable, Hashable {
    public var species: OntologyTerm
    public var cellClass: OntologyTerm?
    public var cellSubclass: OntologyTerm?
    public var transcriptomicType: OntologyTerm?
    public var morphologicalType: OntologyTerm?
    public var electrophysiologicalType: OntologyTerm?
    public var neurotransmitterType: OntologyTerm?
    public var brainRegion: OntologyTerm?
    public var corticalLayer: OntologyTerm?
    public var developmentalStage: OntologyTerm?

    public init(
        species: OntologyTerm,
        cellClass: OntologyTerm? = nil,
        cellSubclass: OntologyTerm? = nil,
        transcriptomicType: OntologyTerm? = nil,
        morphologicalType: OntologyTerm? = nil,
        electrophysiologicalType: OntologyTerm? = nil,
        neurotransmitterType: OntologyTerm? = nil,
        brainRegion: OntologyTerm? = nil,
        corticalLayer: OntologyTerm? = nil,
        developmentalStage: OntologyTerm? = nil
    ) {
        self.species = species
        self.cellClass = cellClass
        self.cellSubclass = cellSubclass
        self.transcriptomicType = transcriptomicType
        self.morphologicalType = morphologicalType
        self.electrophysiologicalType = electrophysiologicalType
        self.neurotransmitterType = neurotransmitterType
        self.brainRegion = brainRegion
        self.corticalLayer = corticalLayer
        self.developmentalStage = developmentalStage
    }

    public var terms: [OntologyTerm] {
        [
            species,
            cellClass,
            cellSubclass,
            transcriptomicType,
            morphologicalType,
            electrophysiologicalType,
            neurotransmitterType,
            brainRegion,
            corticalLayer,
            developmentalStage
        ].compactMap { $0 }
    }

    public func validated() throws -> Self {
        for term in terms { _ = try term.validated() }
        return self
    }
}

public struct OntologyRegistry: Codable, Sendable, Equatable {
    public var schemaVersion: UInt32
    public var terms: [OntologyTerm]
    public var mappings: [OntologyMapping]
    public var preferredNamespaces: [String]

    public init(
        schemaVersion: UInt32 = 1,
        terms: [OntologyTerm] = [],
        mappings: [OntologyMapping] = [],
        preferredNamespaces: [String] = [
            "NCBITaxon",
            "UBERON",
            "CL",
            "PCL",
            "GO",
            "CHEBI",
            "NCIT",
            "NUMI"
        ]
    ) {
        self.schemaVersion = schemaVersion
        self.terms = terms
        self.mappings = mappings
        self.preferredNamespaces = preferredNamespaces
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1 else {
            throw OntologyError.unsupportedSchema(schemaVersion)
        }
        for term in terms { _ = try term.validated() }
        for mapping in mappings { _ = try mapping.validated() }

        let grouped = Dictionary(grouping: terms, by: \.curie)
        for (curie, values) in grouped where values.count != 1 {
            throw OntologyError.conflictingTermDefinitions(curie)
        }

        let known = Set(terms.map(\.curie))
            .union(mappings.flatMap { [$0.source.curie, $0.target.curie] })
        guard mappings.allSatisfy({
            known.contains($0.source.curie) && known.contains($0.target.curie)
        }) else {
            throw OntologyError.unknownMappingEndpoint
        }

        let exactEdges = mappings.filter { $0.relation == .exact }
        var exactPairs = Set<String>()
        for mapping in exactEdges {
            let pair = [mapping.source.curie, mapping.target.curie]
                .sorted()
                .joined(separator: "\u{0}")
            guard exactPairs.insert(pair).inserted else {
                throw OntologyError.duplicateMapping(pair)
            }
        }
        return self
    }

    public func term(for curie: String) -> OntologyTerm? {
        let direct = terms.first { $0.curie == curie }
        if let direct { return direct }
        for mapping in mappings {
            if mapping.source.curie == curie { return mapping.source }
            if mapping.target.curie == curie { return mapping.target }
        }
        return nil
    }

    public func canonicalTerm(
        for input: OntologyTerm,
        minimumMappingConfidence: Double = 0.8
    ) -> OntologyTerm {
        let candidates = exactEquivalenceClass(
            of: input,
            minimumMappingConfidence: minimumMappingConfidence
        )
        return candidates.min { lhs, rhs in
            let lhsRank = preferredNamespaces.firstIndex(of: lhs.namespace) ?? Int.max
            let rhsRank = preferredNamespaces.firstIndex(of: rhs.namespace) ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.curie < rhs.curie
        } ?? input
    }

    public func exactEquivalenceClass(
        of input: OntologyTerm,
        minimumMappingConfidence: Double = 0.8
    ) -> Set<OntologyTerm> {
        var byCurie: [String: OntologyTerm] = [:]
        for term in terms { byCurie[term.curie] = term }
        byCurie[input.curie] = input
        for mapping in mappings {
            byCurie[mapping.source.curie] = mapping.source
            byCurie[mapping.target.curie] = mapping.target
        }

        let eligible = mappings.filter {
            $0.relation == .exact && $0.confidence >= minimumMappingConfidence
        }
        var visited: Set<String> = [input.curie]
        var queue: [String] = [input.curie]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            let neighbors = eligible.compactMap { mapping -> String? in
                if mapping.source.curie == current { return mapping.target.curie }
                if mapping.target.curie == current { return mapping.source.curie }
                return nil
            }.sorted()
            for neighbor in neighbors where visited.insert(neighbor).inserted {
                queue.append(neighbor)
            }
        }
        return Set(visited.compactMap { byCurie[$0] })
    }

    public func relatedTerms(
        to input: OntologyTerm,
        relations: Set<OntologyRelation>,
        minimumConfidence: Double = 0
    ) -> [OntologyTerm] {
        var result: [OntologyTerm] = []
        for mapping in mappings where
            relations.contains(mapping.relation) &&
            mapping.confidence >= minimumConfidence {
            if mapping.source.curie == input.curie {
                result.append(mapping.target)
            } else if mapping.target.curie == input.curie,
                      mapping.relation == .exact || mapping.relation == .related {
                result.append(mapping.source)
            }
        }
        return Array(Set(result)).sorted()
    }

    public func semanticDistance(
        from source: OntologyTerm,
        to target: OntologyTerm,
        relations: Set<OntologyRelation> = Set(OntologyRelation.allCases),
        maximumDepth: Int = 32,
        minimumConfidence: Double = 0
    ) -> Int? {
        guard maximumDepth >= 0 else { return nil }
        if source.curie == target.curie { return 0 }

        let eligible = mappings.filter {
            relations.contains($0.relation) && $0.confidence >= minimumConfidence
        }
        var queue: [(String, Int)] = [(source.curie, 0)]
        var visited: Set<String> = [source.curie]
        var cursor = 0

        while cursor < queue.count {
            let (current, depth) = queue[cursor]
            cursor += 1
            guard depth < maximumDepth else { continue }
            let neighbors = eligible.flatMap { mapping -> [String] in
                if mapping.source.curie == current { return [mapping.target.curie] }
                if mapping.target.curie == current,
                   mapping.relation == .exact || mapping.relation == .related {
                    return [mapping.source.curie]
                }
                return []
            }.sorted()

            for neighbor in neighbors {
                if neighbor == target.curie { return depth + 1 }
                if visited.insert(neighbor).inserted {
                    queue.append((neighbor, depth + 1))
                }
            }
        }
        return nil
    }

    public func merging(_ other: OntologyRegistry) throws -> OntologyRegistry {
        var termByCurie: [String: OntologyTerm] = [:]
        for term in terms {
            if let existing = termByCurie[term.curie], existing != term {
                throw OntologyError.conflictingTermDefinitions(term.curie)
            }
            termByCurie[term.curie] = term
        }
        for term in other.terms {
            if let existing = termByCurie[term.curie], existing != term {
                throw OntologyError.conflictingTermDefinitions(term.curie)
            }
            termByCurie[term.curie] = term
        }

        let mergedMappings = Array(Set(mappings).union(other.mappings)).sorted {
            if $0.source.curie != $1.source.curie {
                return $0.source.curie < $1.source.curie
            }
            if $0.target.curie != $1.target.curie {
                return $0.target.curie < $1.target.curie
            }
            return $0.relation.rawValue < $1.relation.rawValue
        }
        var namespaces = preferredNamespaces
        for namespace in other.preferredNamespaces where !namespaces.contains(namespace) {
            namespaces.append(namespace)
        }
        return try OntologyRegistry(
            terms: termByCurie.values.sorted(),
            mappings: mergedMappings,
            preferredNamespaces: namespaces
        ).validated()
    }
}

public enum OntologyError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidTerm(String)
    case invalidMapping(String, String)
    case conflictingTermDefinitions(String)
    case unknownMappingEndpoint
    case duplicateMapping(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "Unsupported ontology registry schema \(version)."
        case .invalidTerm(let curie):
            return "Ontology term \(curie) is invalid."
        case .invalidMapping(let source, let target):
            return "Ontology mapping \(source) -> \(target) is invalid."
        case .conflictingTermDefinitions(let curie):
            return "Ontology term \(curie) has conflicting definitions."
        case .unknownMappingEndpoint:
            return "Ontology mapping references an unknown endpoint."
        case .duplicateMapping(let pair):
            return "Ontology mapping \(pair) is duplicated."
        }
    }
}
