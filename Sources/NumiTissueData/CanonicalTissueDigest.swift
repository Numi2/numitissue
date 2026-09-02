import Foundation
import NumiTissueCore
import NumiTissueIO
import NumiTissueModels

public enum CanonicalTissueDigest {
    public static func sha256(
        _ source: CanonicalTissueBlueprint
    ) throws -> ScientificSHA256Digest {
        let blueprint = try source.validated()
        var lines: [String] = []
        lines.reserveCapacity(
            32 +
                blueprint.evidence.count +
                blueprint.resolvedEvidence.count +
                blueprint.cells.count +
                blueprint.synapses.count
        )

        append(&lines, "schema", String(blueprint.schemaVersion))
        append(&lines, "name", blueprint.name)
        appendDictionary(&lines, prefix: "metadata", blueprint.metadata)

        for dataset in blueprint.sourceDatasets.sorted(by: {
            $0.stableReference < $1.stableReference
        }) {
            append(&lines, "dataset.reference", dataset.stableReference)
            append(&lines, "dataset.source", dataset.source.rawValue)
            append(&lines, "dataset.uri", dataset.sourceURI ?? "-")
            append(&lines, "dataset.license", dataset.license.identifier)
            append(&lines, "dataset.stability", dataset.stability.rawValue)
            appendDictionary(
                &lines,
                prefix: "dataset.metadata.\(dataset.stableReference)",
                dataset.metadata
            )
        }

        for term in blueprint.ontology.terms.sorted() {
            append(
                &lines,
                "ontology.term",
                joined([
                    term.curie,
                    term.label,
                    term.definition ?? "-",
                    term.synonyms.sorted().joined(separator: "\u{1d}")
                ])
            )
        }
        for mapping in blueprint.ontology.mappings.sorted(by: {
            let lhs = $0.source.curie + $0.relation.rawValue + $0.target.curie
            let rhs = $1.source.curie + $1.relation.rawValue + $1.target.curie
            return lhs < rhs
        }) {
            append(
                &lines,
                "ontology.mapping",
                joined([
                    mapping.source.curie,
                    mapping.relation.rawValue,
                    mapping.target.curie,
                    bits(mapping.confidence),
                    mapping.evidenceRecordIDs.sorted().joined(separator: "\u{1d}")
                ])
            )
        }

        for node in blueprint.provenance.nodes.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "provenance.node",
                joined([
                    node.id,
                    node.kind.rawValue,
                    node.label,
                    node.type,
                    node.timestamp.map { iso8601($0) } ?? "-",
                    node.datasetReference ?? "-",
                    node.checksum ?? "-",
                    node.softwareVersion ?? "-"
                ])
            )
            appendDictionary(
                &lines,
                prefix: "provenance.node.metadata.\(node.id)",
                node.metadata
            )
        }
        for edge in blueprint.provenance.edges.sorted(by: {
            joined([$0.from, $0.kind.rawValue, $0.to, $0.role ?? "-"]) <
                joined([$1.from, $1.kind.rawValue, $1.to, $1.role ?? "-"])
        }) {
            append(
                &lines,
                "provenance.edge",
                joined([edge.from, edge.kind.rawValue, edge.to, edge.role ?? "-"])
            )
        }

        for record in blueprint.evidence.sorted(by: { $0.id < $1.id }) {
            append(&lines, "evidence", evidenceLine(record))
            appendDictionary(
                &lines,
                prefix: "evidence.metadata.\(record.id)",
                record.metadata
            )
        }
        for resolved in blueprint.resolvedEvidence.sorted(by: {
            joined([$0.entity.semanticKey, $0.property.path]) <
                joined([$1.entity.semanticKey, $1.property.path])
        }) {
            append(&lines, "evidence.resolved", resolvedEvidenceLine(resolved))
        }

        for population in blueprint.populations.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "population",
                joined([
                    population.id,
                    population.name,
                    population.region?.curie ?? "-",
                    population.regionLabel,
                    population.tags.sorted().joined(separator: "\u{1d}"),
                    attributionLine(population.attribution)
                ])
            )
        }

        for morphology in blueprint.morphologies.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "morphology",
                joined([
                    morphology.id,
                    morphology.morphology.name,
                    morphology.coordinateFrame.identifier,
                    morphology.isComplete ? "1" : "0",
                    attributionLine(morphology.attribution)
                ])
            )
            for node in morphology.morphology.nodes.sorted(by: { $0.id < $1.id }) {
                append(
                    &lines,
                    "morphology.node.\(morphology.id)",
                    joined([
                        String(node.id),
                        node.parent.map(String.init) ?? "-",
                        String(node.kind.rawValue),
                        floatBits(node.positionMicrometers.x),
                        floatBits(node.positionMicrometers.y),
                        floatBits(node.positionMicrometers.z),
                        floatBits(node.positionMicrometers.w),
                        floatBits(node.radiusMicrometers)
                    ])
                )
            }
        }

        for mechanism in blueprint.mechanismSets.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "mechanism",
                joined([
                    mechanism.id,
                    mechanism.mechanism.name,
                    floatBits(mechanism.mechanism.temperatureCelsius),
                    floatBits(mechanism.mechanism.q10),
                    mechanism.ontologyTerms.map(\.curie).sorted().joined(separator: "\u{1d}"),
                    attributionLine(mechanism.attribution)
                ])
            )
            for channel in mechanism.mechanism.channels.sorted(by: { $0.name < $1.name }) {
                append(
                    &lines,
                    "mechanism.channel.\(mechanism.id)",
                    joined([
                        channel.name,
                        String(channel.kind.rawValue),
                        floatBits(channel.maximumConductance),
                        floatBits(channel.reversalPotentialMillivolts),
                        String(channel.activationPower),
                        String(channel.inactivationPower),
                        gateLine(channel.activationGate),
                        gateLine(channel.inactivationGate)
                    ])
                )
            }
        }

        for item in blueprint.regulatoryPrograms.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "regulatory",
                joined([
                    item.id,
                    item.program.name,
                    vectorLine(item.program.timeConstantsSeconds0),
                    vectorLine(item.program.timeConstantsSeconds1),
                    item.program.recurrentRows.map(vectorLine).joined(separator: "\u{1c}"),
                    item.program.biases.map(floatBits).joined(separator: "\u{1d}"),
                    floatBits(item.program.divisionHazardPerSecond),
                    floatBits(item.program.apoptosisHazardPerSecond),
                    attributionLine(item.attribution)
                ])
            )
        }

        for item in blueprint.glialPrograms.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "glial",
                joined([
                    item.id,
                    item.program.name,
                    String(item.program.kind.rawValue),
                    vectorLine(item.program.uptakeRates),
                    vectorLine(item.program.releaseRates),
                    vectorLine(item.program.activationThresholds),
                    floatBits(item.program.spatialRadiusMicrometers),
                    attributionLine(item.attribution)
                ])
            )
        }

        for type in blueprint.cellTypes.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "cell.type",
                joined([
                    type.id,
                    type.name,
                    taxonomyLine(type.taxonomy),
                    String(type.kind.rawValue),
                    String(type.defaultFidelity.rawValue),
                    type.morphologyID ?? "-",
                    type.mechanismSetID ?? "-",
                    type.regulatoryProgramID ?? "-",
                    type.glialProgramID ?? "-",
                    bits(type.radiusMicrometers),
                    bits(type.membraneCapacitance),
                    bits(type.leakConductance),
                    bits(type.leakReversalMillivolts),
                    attributionLine(type.attribution)
                ])
            )
            appendDictionary(&lines, prefix: "cell.type.metadata.\(type.id)", type.metadata)
        }

        for cell in blueprint.cells.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "cell",
                joined([
                    cell.id,
                    cell.lineageID,
                    cell.cellTypeID,
                    cell.populationID,
                    cell.positionMicrometers.map(bits).joined(separator: "\u{1d}"),
                    cell.orientationQuaternion.map(bits).joined(separator: "\u{1d}"),
                    cell.fidelityOverride.map { String($0.rawValue) } ?? "-",
                    attributionLine(cell.attribution)
                ])
            )
            appendDictionary(&lines, prefix: "cell.metadata.\(cell.id)", cell.metadata)
        }

        for type in blueprint.synapseTypes.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "synapse.type",
                joined([
                    type.id,
                    type.name,
                    String(type.receptor.rawValue),
                    bits(type.riseMilliseconds),
                    bits(type.decayMilliseconds),
                    bits(type.reversalPotentialMillivolts),
                    bits(type.defaultWeight),
                    type.shortTermPlasticity.map(shortTermLine) ?? "-",
                    type.stdp.map(stdpLine) ?? "-",
                    attributionLine(type.attribution)
                ])
            )
        }

        for synapse in blueprint.synapses.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "synapse",
                joined([
                    synapse.id,
                    synapse.synapseTypeID,
                    synapse.presynapticCellID,
                    synapse.postsynapticCellID,
                    synapse.postsynapticMorphologyNode.map(String.init) ?? "-",
                    synapse.weight.map(bits) ?? "-",
                    bits(synapse.delayMilliseconds),
                    synapse.positionMicrometers?.map(bits).joined(separator: "\u{1d}") ?? "-",
                    attributionLine(synapse.attribution)
                ])
            )
            appendDictionary(
                &lines,
                prefix: "synapse.metadata.\(synapse.id)",
                synapse.metadata
            )
        }

        for field in blueprint.fieldSpecies.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "field",
                joined([
                    field.id,
                    String(field.descriptor.channel.rawValue),
                    field.descriptor.name,
                    floatBits(field.descriptor.diffusionMicrometersSquaredPerMillisecond),
                    floatBits(field.descriptor.decayPerMillisecond),
                    floatBits(field.descriptor.baseline),
                    floatBits(field.descriptor.minimum),
                    floatBits(field.descriptor.maximum),
                    field.ontologyTerm?.curie ?? "-",
                    attributionLine(field.attribution)
                ])
            )
        }

        for item in blueprint.molecularNetworks.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "molecular.network",
                joined([
                    item.id,
                    item.network.name,
                    String(item.network.solver.rawValue),
                    String(item.network.voxelCount),
                    item.ontologyTerms.map(\.curie).sorted().joined(separator: "\u{1d}"),
                    attributionLine(item.attribution)
                ])
            )
            for species in item.network.species.sorted(by: { $0.name < $1.name }) {
                append(
                    &lines,
                    "molecular.species.\(item.id)",
                    joined([
                        species.name,
                        floatBits(species.initialAmount),
                        floatBits(species.diffusionCoefficient),
                        floatBits(species.minimumAmount)
                    ])
                )
            }
            for reaction in item.network.reactions.sorted(by: { $0.name < $1.name }) {
                let reactants = reaction.reactants
                    .map { joined([$0.species, floatBits($0.stoichiometry)]) }
                    .sorted()
                    .joined(separator: "\u{1c}")
                let products = reaction.products
                    .map { joined([$0.species, floatBits($0.stoichiometry)]) }
                    .sorted()
                    .joined(separator: "\u{1c}")
                append(
                    &lines,
                    "molecular.reaction.\(item.id)",
                    joined([
                        reaction.name,
                        reactants,
                        products,
                        floatBits(reaction.forwardRate),
                        reaction.reverseRate.map(floatBits) ?? "-"
                    ])
                )
            }
        }

        for domain in blueprint.molecularDomains.sorted(by: { $0.id < $1.id }) {
            append(
                &lines,
                "molecular.domain",
                joined([
                    domain.id,
                    domain.networkID,
                    domain.cellID,
                    domain.morphologyNode.map(String.init) ?? "-",
                    domain.fieldVoxel.map(String.init) ?? "-",
                    attributionLine(domain.attribution)
                ])
            )
        }

        return ScientificSHA256Digest(
            data: Data(lines.joined(separator: "\n").utf8)
        )
    }

    private static func evidenceLine(_ record: EvidenceRecord) -> String {
        joined([
            record.id,
            record.entity.stableKey,
            record.property.path,
            evidenceValueLine(record.value),
            record.unit?.rawValue ?? "-",
            record.source.rawValue,
            record.modalities.map(\.rawValue).sorted().joined(separator: "\u{1d}"),
            record.datasetReference,
            record.assetID ?? "-",
            record.coordinateFrameID ?? "-",
            bits(record.quality.confidence),
            record.quality.method.rawValue,
            record.quality.curation.rawValue,
            record.quality.sampleCount.map(String.init) ?? "-",
            record.quality.flags.map(\.rawValue).sorted().joined(separator: "\u{1d}"),
            record.provenanceNodeIDs.sorted().joined(separator: "\u{1d}")
        ])
    }

    private static func resolvedEvidenceLine(_ value: ResolvedEvidence) -> String {
        joined([
            value.entity.semanticKey,
            value.property.path,
            evidenceValueLine(value.value),
            value.unit?.rawValue ?? "-",
            bits(value.confidence),
            bits(value.conflictScore),
            value.uncertainty.standardError.map(bits).joined(separator: "\u{1d}"),
            value.uncertainty.lower95.map(bits).joined(separator: "\u{1d}"),
            value.uncertainty.upper95.map(bits).joined(separator: "\u{1d}"),
            value.uncertainty.betweenSourceStandardDeviation.map(bits).joined(separator: "\u{1d}"),
            bits(value.uncertainty.effectiveSampleSize),
            value.uncertainty.categoricalEntropy.map(bits) ?? "-",
            value.supportingRecordIDs.sorted().joined(separator: "\u{1d}"),
            value.sourceDatasets.sorted().joined(separator: "\u{1d}")
        ])
    }

    private static func evidenceValueLine(_ value: EvidenceValue) -> String {
        switch value {
        case .scalar(let scalar):
            return joined(["scalar", bits(scalar)])
        case .interval(let lower, let upper):
            return joined(["interval", bits(lower), bits(upper)])
        case .gaussian(let mean, let standardDeviation, let sampleCount):
            return joined([
                "gaussian",
                bits(mean),
                bits(standardDeviation),
                sampleCount.map(String.init) ?? "-"
            ])
        case .samples(let values):
            return joined(["samples", values.map(bits).joined(separator: "\u{1d}")])
        case .vector(let values):
            return joined(["vector", values.map(bits).joined(separator: "\u{1d}")])
        case .category(let category):
            return joined(["category", category])
        case .categoryProbabilities(let values):
            return joined([
                "categories",
                values
                    .map { joined([$0.category, bits($0.probability)]) }
                    .sorted()
                    .joined(separator: "\u{1d}")
            ])
        case .boolean(let value):
            return joined(["boolean", value ? "1" : "0"])
        case .text(let value):
            return joined(["text", value])
        }
    }

    private static func taxonomyLine(_ taxonomy: CellTaxonomyIdentity) -> String {
        taxonomy.terms.map(\.curie).joined(separator: "\u{1d}")
    }

    private static func attributionLine(_ value: BiologicalAttribution) -> String {
        joined([
            bits(value.confidence),
            value.evidenceRecordIDs.sorted().joined(separator: "\u{1d}"),
            value.provenanceNodeIDs.sorted().joined(separator: "\u{1d}"),
            value.datasetReferences.sorted().joined(separator: "\u{1d}"),
            value.notes ?? "-"
        ])
    }

    private static func gateLine(_ gate: GateKinetics) -> String {
        joined([String(gate.kind.rawValue), vectorLine(gate.parameters)])
    }

    private static func shortTermLine(_ value: ShortTermPlasticity) -> String {
        joined([
            floatBits(value.utilization),
            floatBits(value.recoveryMilliseconds),
            floatBits(value.facilitationMilliseconds)
        ])
    }

    private static func stdpLine(_ value: STDPParameters) -> String {
        joined([
            floatBits(value.positiveAmplitude),
            floatBits(value.negativeAmplitude),
            floatBits(value.positiveTimeConstantMilliseconds),
            floatBits(value.negativeTimeConstantMilliseconds),
            floatBits(value.eligibilityTimeConstantMilliseconds),
            floatBits(value.learningRate),
            floatBits(value.minimumWeight),
            floatBits(value.maximumWeight)
        ])
    }

    private static func vectorLine(_ value: Float4) -> String {
        joined([
            floatBits(value.x),
            floatBits(value.y),
            floatBits(value.z),
            floatBits(value.w)
        ])
    }

    private static func bits(_ value: Double) -> String {
        String(value.bitPattern, radix: 16)
    }

    private static func floatBits(_ value: Float) -> String {
        String(value.bitPattern, radix: 16)
    }

    private static func append(_ lines: inout [String], _ key: String, _ value: String) {
        lines.append(joined([key, value]))
    }

    private static func appendDictionary(
        _ lines: inout [String],
        prefix: String,
        _ dictionary: [String: String]
    ) {
        for key in dictionary.keys.sorted() {
            append(&lines, prefix, joined([key, dictionary[key] ?? ""]))
        }
    }

    private static func joined(_ values: [String]) -> String {
        values.map(escaped).joined(separator: "\u{1f}")
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{1c}", with: "\\u001c")
            .replacingOccurrences(of: "\u{1d}", with: "\\u001d")
            .replacingOccurrences(of: "\u{1e}", with: "\\u001e")
            .replacingOccurrences(of: "\u{1f}", with: "\\u001f")
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
