import Foundation

public enum CanonicalMergeConflictStrategy: String, Codable, Sendable, CaseIterable {
    case reject
    case preferHigherConfidence
    case preferLexicographicallyFirstDataset
}

public struct CanonicalTissueMergePolicy: Codable, Sendable, Equatable {
    public var conflictStrategy: CanonicalMergeConflictStrategy
    public var metadataConflictStrategy: CanonicalMergeConflictStrategy
    public var validateEachInput: Bool
    public var validateOutput: Bool

    public init(
        conflictStrategy: CanonicalMergeConflictStrategy = .reject,
        metadataConflictStrategy: CanonicalMergeConflictStrategy =
            .preferLexicographicallyFirstDataset,
        validateEachInput: Bool = true,
        validateOutput: Bool = true
    ) {
        self.conflictStrategy = conflictStrategy
        self.metadataConflictStrategy = metadataConflictStrategy
        self.validateEachInput = validateEachInput
        self.validateOutput = validateOutput
    }
}

public struct CanonicalMergeDecision: Codable, Sendable, Equatable {
    public var path: String
    public var selectedDigest: String
    public var discardedDigests: [String]
    public var reason: String

    public init(
        path: String,
        selectedDigest: String,
        discardedDigests: [String],
        reason: String
    ) {
        self.path = path
        self.selectedDigest = selectedDigest
        self.discardedDigests = discardedDigests
        self.reason = reason
    }
}

public struct CanonicalTissueMergeResult: Sendable {
    public var blueprint: CanonicalTissueBlueprint
    public var inputDigests: [String]
    public var decisions: [CanonicalMergeDecision]

    public init(
        blueprint: CanonicalTissueBlueprint,
        inputDigests: [String],
        decisions: [CanonicalMergeDecision]
    ) {
        self.blueprint = blueprint
        self.inputDigests = inputDigests
        self.decisions = decisions
    }
}

public struct CanonicalTissueMerger: Sendable {
    public let policy: CanonicalTissueMergePolicy

    public init(policy: CanonicalTissueMergePolicy = CanonicalTissueMergePolicy()) {
        self.policy = policy
    }

    public func merge(
        _ sourceBlueprints: [CanonicalTissueBlueprint],
        name: String,
        metadata: [String: String] = [:]
    ) throws -> CanonicalTissueMergeResult {
        guard !sourceBlueprints.isEmpty else {
            throw CanonicalMergeError.emptyInput
        }

        var inputs: [(digest: String, blueprint: CanonicalTissueBlueprint)] = []
        for source in sourceBlueprints {
            let blueprint = policy.validateEachInput ? try source.validated() : source
            let digest = try CanonicalTissueDigest.sha256(blueprint).hexadecimal
            inputs.append((digest, blueprint))
        }
        inputs.sort { $0.digest < $1.digest }
        let inputDigests = inputs.map { $0.digest }
        guard Set(inputDigests).count == inputDigests.count else {
            throw CanonicalMergeError.duplicateInputDigest
        }

        var result = CanonicalTissueBlueprint(name: name, metadata: metadata)
        var decisions: [CanonicalMergeDecision] = []
        var originByPath = Dictionary(
            uniqueKeysWithValues: metadata.keys.map {
                ("metadata[\($0)]", "output-metadata")
            }
        )
        var ontology = OntologyRegistry()
        var provenance = ProvenanceGraph()

        for input in inputs {
            let blueprint = input.blueprint
            result.metadata = try mergeMetadata(
                existing: result.metadata,
                incoming: blueprint.metadata,
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.sourceDatasets = try mergeExact(
                result.sourceDatasets,
                blueprint.sourceDatasets,
                key: \.stableReference,
                path: "sourceDatasets",
                inputDigest: input.digest
            )
            ontology = try ontology.merging(blueprint.ontology)
            provenance = try provenance.merging(blueprint.provenance)
            result.evidence = try mergeExact(
                result.evidence,
                blueprint.evidence,
                key: \.id,
                path: "evidence",
                inputDigest: input.digest
            )
            result.resolvedEvidence = try mergeResolved(
                existing: result.resolvedEvidence,
                incoming: blueprint.resolvedEvidence,
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.populations = try mergeAttributed(
                result.populations,
                blueprint.populations,
                key: \.id,
                attribution: \.attribution,
                path: "populations",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.morphologies = try mergeAttributed(
                result.morphologies,
                blueprint.morphologies,
                key: \.id,
                attribution: \.attribution,
                path: "morphologies",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.mechanismSets = try mergeAttributed(
                result.mechanismSets,
                blueprint.mechanismSets,
                key: \.id,
                attribution: \.attribution,
                path: "mechanismSets",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.regulatoryPrograms = try mergeAttributed(
                result.regulatoryPrograms,
                blueprint.regulatoryPrograms,
                key: \.id,
                attribution: \.attribution,
                path: "regulatoryPrograms",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.glialPrograms = try mergeAttributed(
                result.glialPrograms,
                blueprint.glialPrograms,
                key: \.id,
                attribution: \.attribution,
                path: "glialPrograms",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.cellTypes = try mergeAttributed(
                result.cellTypes,
                blueprint.cellTypes,
                key: \.id,
                attribution: \.attribution,
                path: "cellTypes",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.cells = try mergeAttributed(
                result.cells,
                blueprint.cells,
                key: \.id,
                attribution: \.attribution,
                path: "cells",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.synapseTypes = try mergeAttributed(
                result.synapseTypes,
                blueprint.synapseTypes,
                key: \.id,
                attribution: \.attribution,
                path: "synapseTypes",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.synapses = try mergeAttributed(
                result.synapses,
                blueprint.synapses,
                key: \.id,
                attribution: \.attribution,
                path: "synapses",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.fieldSpecies = try mergeAttributed(
                result.fieldSpecies,
                blueprint.fieldSpecies,
                key: \.id,
                attribution: \.attribution,
                path: "fieldSpecies",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.molecularNetworks = try mergeAttributed(
                result.molecularNetworks,
                blueprint.molecularNetworks,
                key: \.id,
                attribution: \.attribution,
                path: "molecularNetworks",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
            result.molecularDomains = try mergeAttributed(
                result.molecularDomains,
                blueprint.molecularDomains,
                key: \.id,
                attribution: \.attribution,
                path: "molecularDomains",
                inputDigest: input.digest,
                origins: &originByPath,
                decisions: &decisions
            )
        }

        result.ontology = ontology
        result.provenance = provenance
        result.metadata["numitissue.data.merge.inputs"] = inputDigests
            .joined(separator: "\n")
        if policy.validateOutput { result = try result.validated() }
        return CanonicalTissueMergeResult(
            blueprint: result,
            inputDigests: inputDigests,
            decisions: decisions.sorted {
                if $0.path != $1.path { return $0.path < $1.path }
                return $0.selectedDigest < $1.selectedDigest
            }
        )
    }
}

private extension CanonicalTissueMerger {
    func mergeExact<Value: Equatable>(
        _ existing: [Value],
        _ incoming: [Value],
        key: KeyPath<Value, String>,
        path: String,
        inputDigest: String
    ) throws -> [Value] {
        var values: [String: Value] = [:]
        for value in existing { values[value[keyPath: key]] = value }
        for value in incoming {
            let identifier = value[keyPath: key]
            if let current = values[identifier], current != value {
                throw CanonicalMergeError.conflict(
                    path: "\(path)[\(identifier)]",
                    inputDigest: inputDigest
                )
            }
            values[identifier] = value
        }
        return values.keys.sorted().compactMap { values[$0] }
    }

    func mergeAttributed<Value: Equatable>(
        _ existing: [Value],
        _ incoming: [Value],
        key: KeyPath<Value, String>,
        attribution: KeyPath<Value, BiologicalAttribution>,
        path: String,
        inputDigest: String,
        origins: inout [String: String],
        decisions: inout [CanonicalMergeDecision]
    ) throws -> [Value] {
        var values = Dictionary(
            uniqueKeysWithValues: existing.map { ($0[keyPath: key], $0) }
        )

        for value in incoming {
            let identifier = value[keyPath: key]
            let fullPath = "\(path)[\(identifier)]"
            guard let current = values[identifier] else {
                values[identifier] = value
                origins[fullPath] = inputDigest
                continue
            }
            guard current != value else { continue }

            let currentDigest = origins[fullPath] ?? "unknown-earlier-input"
            let selectIncoming: Bool
            let reason: String
            switch policy.conflictStrategy {
            case .reject:
                throw CanonicalMergeError.conflict(
                    path: fullPath,
                    inputDigest: inputDigest
                )
            case .preferHigherConfidence:
                let currentConfidence = current[keyPath: attribution].confidence
                let incomingConfidence = value[keyPath: attribution].confidence
                selectIncoming = incomingConfidence > currentConfidence ||
                    (incomingConfidence == currentConfidence &&
                        inputDigest < currentDigest)
                reason = "selected higher-confidence value; digest breaks exact ties"
            case .preferLexicographicallyFirstDataset:
                selectIncoming = inputDigest < currentDigest
                reason = "selected lexicographically first canonical input digest"
            }

            let selectedDigest = selectIncoming ? inputDigest : currentDigest
            let discardedDigest = selectIncoming ? currentDigest : inputDigest
            if selectIncoming {
                values[identifier] = value
                origins[fullPath] = inputDigest
            }
            decisions.append(CanonicalMergeDecision(
                path: fullPath,
                selectedDigest: selectedDigest,
                discardedDigests: [discardedDigest],
                reason: reason
            ))
        }
        return values.keys.sorted().compactMap { values[$0] }
    }

    func mergeResolved(
        existing: [ResolvedEvidence],
        incoming: [ResolvedEvidence],
        inputDigest: String,
        origins: inout [String: String],
        decisions: inout [CanonicalMergeDecision]
    ) throws -> [ResolvedEvidence] {
        var values = Dictionary(
            uniqueKeysWithValues: existing.map { (resolvedKey($0), $0) }
        )
        for value in incoming {
            let key = resolvedKey(value)
            let fullPath = "resolvedEvidence[\(key)]"
            guard let current = values[key] else {
                values[key] = value
                origins[fullPath] = inputDigest
                continue
            }
            guard current != value else { continue }

            if policy.conflictStrategy == .reject {
                throw CanonicalMergeError.conflict(
                    path: fullPath,
                    inputDigest: inputDigest
                )
            }
            let currentDigest = origins[fullPath] ?? "unknown-earlier-input"
            let selectIncoming = value.conflictScore < current.conflictScore ||
                (value.conflictScore == current.conflictScore &&
                    value.confidence > current.confidence) ||
                (value.conflictScore == current.conflictScore &&
                    value.confidence == current.confidence &&
                    inputDigest < currentDigest)
            let selectedDigest = selectIncoming ? inputDigest : currentDigest
            let discardedDigest = selectIncoming ? currentDigest : inputDigest
            if selectIncoming {
                values[key] = value
                origins[fullPath] = inputDigest
            }
            decisions.append(CanonicalMergeDecision(
                path: fullPath,
                selectedDigest: selectedDigest,
                discardedDigests: [discardedDigest],
                reason: "selected lower-conflict, then higher-confidence resolved evidence"
            ))
        }
        return values.keys.sorted().compactMap { values[$0] }
    }

    func mergeMetadata(
        existing: [String: String],
        incoming: [String: String],
        inputDigest: String,
        origins: inout [String: String],
        decisions: inout [CanonicalMergeDecision]
    ) throws -> [String: String] {
        var result = existing
        for key in incoming.keys.sorted() {
            let value = incoming[key] ?? ""
            let fullPath = "metadata[\(key)]"
            guard let current = result[key] else {
                result[key] = value
                origins[fullPath] = inputDigest
                continue
            }
            guard current != value else { continue }

            switch policy.metadataConflictStrategy {
            case .reject:
                throw CanonicalMergeError.conflict(
                    path: fullPath,
                    inputDigest: inputDigest
                )
            case .preferHigherConfidence,
                 .preferLexicographicallyFirstDataset:
                let currentDigest = origins[fullPath] ?? "output-metadata"
                let selectIncoming = currentDigest != "output-metadata" &&
                    inputDigest < currentDigest
                let selectedDigest = selectIncoming ? inputDigest : currentDigest
                let discardedDigest = selectIncoming ? currentDigest : inputDigest
                if selectIncoming {
                    result[key] = value
                    origins[fullPath] = inputDigest
                }
                decisions.append(CanonicalMergeDecision(
                    path: fullPath,
                    selectedDigest: selectedDigest,
                    discardedDigests: [discardedDigest],
                    reason: "selected explicit output metadata, otherwise earliest input digest"
                ))
            }
        }
        return result
    }

    func resolvedKey(_ value: ResolvedEvidence) -> String {
        value.entity.semanticKey + "\u{1e}" + value.property.path
    }
}

public enum CanonicalMergeError: Error, Sendable, CustomStringConvertible {
    case emptyInput
    case duplicateInputDigest
    case conflict(path: String, inputDigest: String)

    public var description: String {
        switch self {
        case .emptyInput:
            return "Canonical tissue merge requires at least one input."
        case .duplicateInputDigest:
            return "Canonical tissue merge received duplicate inputs."
        case .conflict(let path, let digest):
            return "Canonical tissue merge conflict at \(path) from input \(digest)."
        }
    }
}
