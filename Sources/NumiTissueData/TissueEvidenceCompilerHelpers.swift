import Foundation
import NumiTissueCore
import NumiTissueModels

extension TissueEvidenceCompiler {
    func validateAttributionThresholds(
        _ blueprint: CanonicalTissueBlueprint,
        diagnostics: inout [TissueEvidenceDiagnostic]
    ) throws {
        let attributed: [(String, BiologicalAttribution)] =
            blueprint.populations.map { ("populations[\($0.id)]", $0.attribution) } +
            blueprint.morphologies.map { ("morphologies[\($0.id)]", $0.attribution) } +
            blueprint.mechanismSets.map { ("mechanismSets[\($0.id)]", $0.attribution) } +
            blueprint.regulatoryPrograms.map {
                ("regulatoryPrograms[\($0.id)]", $0.attribution)
            } +
            blueprint.glialPrograms.map { ("glialPrograms[\($0.id)]", $0.attribution) } +
            blueprint.cellTypes.map { ("cellTypes[\($0.id)]", $0.attribution) } +
            blueprint.cells.map { ("cells[\($0.id)]", $0.attribution) } +
            blueprint.synapseTypes.map { ("synapseTypes[\($0.id)]", $0.attribution) } +
            blueprint.synapses.map { ("synapses[\($0.id)]", $0.attribution) } +
            blueprint.fieldSpecies.map { ("fieldSpecies[\($0.id)]", $0.attribution) } +
            blueprint.molecularNetworks.map {
                ("molecularNetworks[\($0.id)]", $0.attribution)
            } +
            blueprint.molecularDomains.map {
                ("molecularDomains[\($0.id)]", $0.attribution)
            }

        for (path, attribution) in attributed.sorted(by: { $0.0 < $1.0 }) {
            guard attribution.confidence >= configuration.minimumObjectConfidence else {
                throw TissueEvidenceCompilerError.lowConfidence(
                    path: path,
                    confidence: attribution.confidence
                )
            }
            if attribution.evidenceRecordIDs.isEmpty {
                diagnostics.append(TissueEvidenceDiagnostic(
                    severity: .information,
                    code: "data.attribution.no-evidence-record",
                    path: path,
                    message: "Object has no direct evidence-record attribution."
                ))
            }
        }
    }

    func validateCompilationPolicies(
        _ blueprint: CanonicalTissueBlueprint,
        diagnostics: inout [TissueEvidenceDiagnostic]
    ) throws {
        if blueprint.sourceDatasets.isEmpty {
            diagnostics.append(TissueEvidenceDiagnostic(
                severity: .warning,
                code: "data.sources.empty",
                path: "sourceDatasets",
                message: "Blueprint declares no source dataset release."
            ))
        }
        if blueprint.evidence.isEmpty {
            diagnostics.append(TissueEvidenceDiagnostic(
                severity: .warning,
                code: "data.evidence.empty",
                path: "evidence",
                message: "Blueprint contains no source evidence records."
            ))
        }
        if blueprint.cells.isEmpty {
            diagnostics.append(TissueEvidenceDiagnostic(
                severity: .warning,
                code: "model.cells.empty",
                path: "cells",
                message: "Blueprint contains no instantiated cells."
            ))
        }

        for morphology in blueprint.morphologies where !morphology.isComplete {
            if configuration.rejectIncompleteMorphologies {
                throw TissueEvidenceCompilerError.incompleteMorphology(morphology.id)
            }
            diagnostics.append(TissueEvidenceDiagnostic(
                severity: .warning,
                code: "morphology.incomplete",
                path: "morphologies[\(morphology.id)]",
                message: "Morphology is explicitly partial or truncated.",
                evidenceRecordIDs: morphology.attribution.evidenceRecordIDs
            ))
        }

        for type in blueprint.cellTypes {
            let isNeuron = type.kind == .excitatoryNeuron ||
                type.kind == .inhibitoryInterneuron
            guard isNeuron else { continue }
            if type.morphologyID == nil,
               type.defaultFidelity.rawValue >= FidelityLevel.reducedNeuron.rawValue {
                diagnostics.append(TissueEvidenceDiagnostic(
                    severity: .warning,
                    code: "neuron.morphology.missing",
                    path: "cellTypes[\(type.id)].morphologyID",
                    message: "Neuron requests compartmental fidelity without an explicit morphology; the runtime compiler will synthesize a soma-only morphology.",
                    evidenceRecordIDs: type.attribution.evidenceRecordIDs
                ))
            }
            if type.mechanismSetID == nil,
               type.defaultFidelity.rawValue >= FidelityLevel.reducedNeuron.rawValue {
                diagnostics.append(TissueEvidenceDiagnostic(
                    severity: .warning,
                    code: "neuron.mechanism.missing",
                    path: "cellTypes[\(type.id)].mechanismSetID",
                    message: "Neuron requests electrophysiological fidelity without a channel mechanism set.",
                    evidenceRecordIDs: type.attribution.evidenceRecordIDs
                ))
            }
        }
    }

    func normalizedTags(_ population: CanonicalPopulation) -> [String] {
        var tags = Set(population.tags)
        if let region = population.region {
            tags.insert("ontology:\(region.curie)")
        }
        for dataset in population.attribution.datasetReferences {
            tags.insert("dataset:\(dataset)")
        }
        return tags.sorted()
    }

    func optionalReference<Value>(
        _ identifier: String?,
        in values: [String: Value],
        owner: String
    ) throws -> Value? {
        guard let identifier else { return nil }
        guard let value = values[identifier] else {
            throw TissueEvidenceCompilerError.missingReference(
                "\(owner): \(identifier)"
            )
        }
        return value
    }

    func finiteFloat(_ value: Double, path: String) throws -> Float {
        guard value.isFinite else {
            throw TissueEvidenceCompilerError.nonRepresentableFloat(
                path: path,
                value: value
            )
        }
        let converted = Float(value)
        guard converted.isFinite,
              value == 0 || converted != 0 else {
            throw TissueEvidenceCompilerError.nonRepresentableFloat(
                path: path,
                value: value
            )
        }
        return converted
    }

    func position(_ cell: CanonicalCell) throws -> Float4 {
        Float4(
            try finiteFloat(
                cell.positionMicrometers[0],
                path: "cells[\(cell.id)].position.x"
            ),
            try finiteFloat(
                cell.positionMicrometers[1],
                path: "cells[\(cell.id)].position.y"
            ),
            try finiteFloat(
                cell.positionMicrometers[2],
                path: "cells[\(cell.id)].position.z"
            ),
            0
        )
    }

    func orientation(_ cell: CanonicalCell) throws -> Float4 {
        var values = cell.orientationQuaternion
        let magnitudeSquared = values.reduce(0) { $0 + $1 * $1 }
        guard magnitudeSquared.isFinite, magnitudeSquared > 1e-20 else {
            throw TissueEvidenceCompilerError.invalidOrientation(cell.id)
        }
        if configuration.normalizeOrientations {
            let inverseMagnitude = 1 / sqrt(magnitudeSquared)
            values = values.map { $0 * inverseMagnitude }
        }
        let result = Float4(
            try finiteFloat(values[0], path: "cells[\(cell.id)].orientation.x"),
            try finiteFloat(values[1], path: "cells[\(cell.id)].orientation.y"),
            try finiteFloat(values[2], path: "cells[\(cell.id)].orientation.z"),
            try finiteFloat(values[3], path: "cells[\(cell.id)].orientation.w")
        )
        let floatMagnitudeSquared = result.x * result.x +
            result.y * result.y +
            result.z * result.z +
            result.w * result.w
        guard floatMagnitudeSquared.isFinite, floatMagnitudeSquared > 1e-12 else {
            throw TissueEvidenceCompilerError.invalidOrientation(cell.id)
        }
        return result
    }

    func validateMetadata(_ metadata: [String: String]) throws {
        for key in metadata.keys.sorted() {
            guard !key.isEmpty else {
                throw TissueEvidenceCompilerError.missingReference("empty metadata key")
            }
            let byteCount = metadata[key]?.utf8.count ?? 0
            guard byteCount <= configuration.metadataValueByteLimit else {
                throw TissueEvidenceCompilerError.metadataValueTooLarge(
                    key: key,
                    bytes: byteCount
                )
            }
        }
    }

    func mergeResolvedEvidence(
        _ embedded: [ResolvedEvidence],
        _ supplied: [ResolvedEvidence]
    ) -> [ResolvedEvidence] {
        var byKey: [String: ResolvedEvidence] = [:]
        for item in embedded + supplied {
            let key = item.entity.semanticKey + "\u{1e}" + item.property.path
            guard let existing = byKey[key] else {
                byKey[key] = item
                continue
            }
            let shouldReplace: Bool
            if item.conflictScore != existing.conflictScore {
                shouldReplace = item.conflictScore < existing.conflictScore
            } else if item.confidence != existing.confidence {
                shouldReplace = item.confidence > existing.confidence
            } else {
                shouldReplace = item.supportingRecordIDs.sorted()
                    .lexicographicallyPrecedes(existing.supportingRecordIDs.sorted())
            }
            if shouldReplace { byKey[key] = item }
        }
        return byKey.keys.sorted().compactMap { byKey[$0] }
    }

    func diagnosticOrder(
        _ lhs: TissueEvidenceDiagnostic,
        _ rhs: TissueEvidenceDiagnostic
    ) -> Bool {
        if lhs.severity != rhs.severity {
            return severityRank(lhs.severity) > severityRank(rhs.severity)
        }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.code < rhs.code
    }

    private func severityRank(_ value: TissueEvidenceDiagnosticSeverity) -> Int {
        switch value {
        case .information: return 0
        case .warning: return 1
        case .error: return 2
        }
    }
}
