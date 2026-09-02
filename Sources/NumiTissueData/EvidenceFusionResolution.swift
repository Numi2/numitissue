import Foundation

extension EvidenceFusionEngine {
    struct NumericCandidate {
        var record: EvidenceRecord
        var mean: Double
        var variance: Double
        var qualityWeight: Double
    }

    struct NumericFusion {
        var value: Double
        var standardError: Double
        var betweenSourceStandardDeviation: Double
        var effectiveSampleSize: Double
        var conflictScore: Double
        var confidence: Double
        var support: [EvidenceRecord]
        var rejected: [EvidenceRejection]
    }

    func fusionEntityKey(
        _ entity: BiologicalEntityKey,
        policy: EvidenceFusionPolicy
    ) -> String {
        let coordinateKey = entity.coordinate?
            .map { String($0.bitPattern, radix: 16) }
            .joined(separator: ",") ?? "-"
        var components = [
            entity.kind.rawValue,
            entity.identifier,
            entity.taxonomy?.cellClass?.curie ?? "-",
            entity.taxonomy?.cellSubclass?.curie ?? "-",
            entity.taxonomy?.transcriptomicType?.curie ?? "-",
            entity.taxonomy?.morphologicalType?.curie ?? "-",
            entity.taxonomy?.electrophysiologicalType?.curie ?? "-",
            entity.taxonomy?.brainRegion?.curie ?? "-",
            entity.coordinateFrameID ?? "-",
            coordinateKey
        ]
        if !policy.allowCrossSpecies {
            components.append(entity.taxonomy?.species.curie ?? "-")
        }
        if !policy.allowCrossSpecimen {
            components.append(entity.specimenID ?? "-")
        }
        return components.joined(separator: "\u{1f}")
    }

    func resolveScalar(
        _ records: [EvidenceRecord],
        anchor: EvidenceRecord,
        policy: EvidenceFusionPolicy,
        initialRejections: [EvidenceRejection]
    ) throws -> ResolvedEvidence {
        let unit = try targetUnit(for: records, policy: policy)
        var candidates: [NumericCandidate] = []
        var rejections = initialRejections

        for record in records {
            do {
                candidates.append(try numericCandidate(
                    from: record,
                    targetUnit: unit,
                    policy: policy
                ))
            } catch {
                rejections.append(EvidenceRejection(
                    recordID: record.id,
                    reason: .unsupportedValue,
                    detail: String(describing: error)
                ))
            }
        }
        guard candidates.count >= policy.minimumSupport else {
            throw EvidenceFusionError.insufficientSupport(
                required: policy.minimumSupport,
                actual: candidates.count
            )
        }

        let fusion = try fuse(
            candidates,
            policy: policy,
            initialRejections: rejections
        )
        try enforceConflict(fusion.conflictScore, policy: policy)

        return ResolvedEvidence(
            entity: anchor.entity,
            property: anchor.property,
            value: .scalar(fusion.value),
            unit: unit,
            confidence: fusion.confidence,
            conflictScore: fusion.conflictScore,
            uncertainty: ResolvedUncertainty(
                standardError: [fusion.standardError],
                lower95: [fusion.value - 1.96 * fusion.standardError],
                upper95: [fusion.value + 1.96 * fusion.standardError],
                betweenSourceStandardDeviation: [
                    fusion.betweenSourceStandardDeviation
                ],
                effectiveSampleSize: fusion.effectiveSampleSize
            ),
            supportingRecordIDs: fusion.support.map(\.id).sorted(),
            rejectedRecords: fusion.rejected.sorted { $0.recordID < $1.recordID },
            sourceDatasets: Array(Set(fusion.support.map(\.datasetReference))).sorted()
        )
    }

    func resolveVector(
        _ records: [EvidenceRecord],
        anchor: EvidenceRecord,
        policy: EvidenceFusionPolicy,
        initialRejections: [EvidenceRejection]
    ) throws -> ResolvedEvidence {
        let unit = try targetUnit(for: records, policy: policy)
        let vectors = records.compactMap { record -> (EvidenceRecord, [Double])? in
            guard case .vector(let values) = record.value else { return nil }
            return (record, values)
        }
        let nonVectorRejections = records.compactMap { record -> EvidenceRejection? in
            guard case .vector = record.value else {
                return EvidenceRejection(
                    recordID: record.id,
                    reason: .unsupportedValue
                )
            }
            return nil
        }
        guard let dimension = vectors.first?.1.count,
              dimension > 0,
              vectors.allSatisfy({ $0.1.count == dimension }),
              vectors.count >= policy.minimumSupport else {
            throw EvidenceFusionError.incompatibleVectorDimensions
        }

        if policy.strategy == .authoritativeSource {
            let orderedVectors = vectors.sorted {
                authoritySort($0.0, $1.0, policy: policy)
            }
            let selected = orderedVectors[0]
            let converted = try selected.1.map {
                try convert($0, from: selected.0.unit, to: unit)
            }
            let standardError = try vectorStandardErrors(
                record: selected.0,
                values: converted,
                targetUnit: unit,
                policy: policy
            )
            let rejected = initialRejections + nonVectorRejections +
                orderedVectors.dropFirst().map {
                EvidenceRejection(
                    recordID: $0.0.id,
                    reason: .lowerAuthority
                )
            }
            return ResolvedEvidence(
                entity: anchor.entity,
                property: anchor.property,
                value: .vector(converted),
                unit: unit,
                confidence: qualityWeight(selected.0),
                conflictScore: 0,
                uncertainty: ResolvedUncertainty(
                    standardError: standardError,
                    lower95: zip(converted, standardError).map {
                        pair in pair.0 - 1.96 * pair.1
                    },
                    upper95: zip(converted, standardError).map {
                        pair in pair.0 + 1.96 * pair.1
                    },
                    betweenSourceStandardDeviation: [Double](
                        repeating: 0,
                        count: dimension
                    ),
                    effectiveSampleSize: 1
                ),
                supportingRecordIDs: [selected.0.id],
                rejectedRecords: rejected.sorted { $0.recordID < $1.recordID },
                sourceDatasets: [selected.0.datasetReference]
            )
        }

        var componentValues: [Double] = []
        var standardErrors: [Double] = []
        var between: [Double] = []
        var conflicts: [Double] = []
        var confidences: [Double] = []
        var effectiveSizes: [Double] = []
        var supportIDs = Set<String>()
        var allRejections = initialRejections + nonVectorRejections

        for component in 0..<dimension {
            var candidates: [NumericCandidate] = []
            for (record, sourceValues) in vectors {
                let value = try convert(
                    sourceValues[component],
                    from: record.unit,
                    to: unit
                )
                let variance = try inferredVariance(
                    record: record,
                    convertedMean: value,
                    targetUnit: unit,
                    policy: policy
                )
                candidates.append(NumericCandidate(
                    record: record,
                    mean: value,
                    variance: variance,
                    qualityWeight: qualityWeight(record)
                ))
            }
            let fusion = try fuse(
                candidates,
                policy: policy,
                initialRejections: []
            )
            componentValues.append(fusion.value)
            standardErrors.append(fusion.standardError)
            between.append(fusion.betweenSourceStandardDeviation)
            conflicts.append(fusion.conflictScore)
            confidences.append(fusion.confidence)
            effectiveSizes.append(fusion.effectiveSampleSize)
            supportIDs.formUnion(fusion.support.map(\.id))
            allRejections.append(contentsOf: fusion.rejected)
        }

        let conflict = conflicts.max() ?? 0
        try enforceConflict(conflict, policy: policy)
        let uniqueRejections = Dictionary(
            allRejections.map { ($0.recordID + "\u{1f}" + $0.reason.rawValue, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.recordID < $1.recordID }

        return ResolvedEvidence(
            entity: anchor.entity,
            property: anchor.property,
            value: .vector(componentValues),
            unit: unit,
            confidence: confidences.min() ?? 0,
            conflictScore: conflict,
            uncertainty: ResolvedUncertainty(
                standardError: standardErrors,
                lower95: zip(componentValues, standardErrors).map {
                    pair in pair.0 - 1.96 * pair.1
                },
                upper95: zip(componentValues, standardErrors).map {
                    pair in pair.0 + 1.96 * pair.1
                },
                betweenSourceStandardDeviation: between,
                effectiveSampleSize: effectiveSizes.min() ?? 0
            ),
            supportingRecordIDs: supportIDs.sorted(),
            rejectedRecords: uniqueRejections,
            sourceDatasets: Array(Set(
                vectors
                    .filter { supportIDs.contains($0.0.id) }
                    .map { $0.0.datasetReference }
            )).sorted()
        )
    }

    func resolveCategorical(
        _ records: [EvidenceRecord],
        anchor: EvidenceRecord,
        policy: EvidenceFusionPolicy,
        initialRejections: [EvidenceRejection]
    ) throws -> ResolvedEvidence {
        if policy.strategy == .authoritativeSource {
            let sorted = records.sorted {
                authoritySort($0, $1, policy: policy)
            }
            let selected = sorted[0]
            let rejected = initialRejections + sorted.dropFirst().map {
                EvidenceRejection(
                    recordID: $0.id,
                    reason: .lowerAuthority
                )
            }
            return ResolvedEvidence(
                entity: anchor.entity,
                property: anchor.property,
                value: selected.value,
                unit: nil,
                confidence: qualityWeight(selected),
                conflictScore: 0,
                uncertainty: ResolvedUncertainty(effectiveSampleSize: 1),
                supportingRecordIDs: [selected.id],
                rejectedRecords: rejected.sorted { $0.recordID < $1.recordID },
                sourceDatasets: [selected.datasetReference]
            )
        }

        var scores: [String: Double] = [:]
        var totalWeight = 0.0
        var support: [EvidenceRecord] = []
        var rejections = initialRejections

        for record in records {
            let weight = qualityWeight(record)
            switch record.value {
            case .category(let category), .text(let category):
                scores[category, default: 0] += weight
                totalWeight += weight
                support.append(record)
            case .boolean(let value):
                scores[value ? "true" : "false", default: 0] += weight
                totalWeight += weight
                support.append(record)
            case .categoryProbabilities(let probabilities):
                for item in probabilities {
                    scores[item.category, default: 0] += weight * item.probability
                }
                totalWeight += weight
                support.append(record)
            default:
                rejections.append(EvidenceRejection(
                    recordID: record.id,
                    reason: .unsupportedValue
                ))
            }
        }
        guard support.count >= policy.minimumSupport,
              totalWeight > 0,
              !scores.isEmpty else {
            throw EvidenceFusionError.insufficientSupport(
                required: policy.minimumSupport,
                actual: support.count
            )
        }

        var normalized = scores.map {
            CategoricalProbability(
                category: $0.key,
                probability: $0.value / totalWeight
            )
        }.sorted {
            if $0.probability != $1.probability {
                return $0.probability > $1.probability
            }
            return $0.category < $1.category
        }
        let normalization = normalized.reduce(0) { $0 + $1.probability }
        if normalization > 0 {
            normalized = normalized.map {
                CategoricalProbability(
                    category: $0.category,
                    probability: $0.probability / normalization
                )
            }
        }

        let topProbability = normalized.first?.probability ?? 0
        let conflict = max(0, min(1, 1 - topProbability))
        try enforceConflict(conflict, policy: policy)
        let entropy = normalized.reduce(0.0) { partial, item in
            guard item.probability > 0 else { return partial }
            return partial - item.probability * log(item.probability)
        }
        let normalizedEntropy = normalized.count > 1
            ? entropy / log(Double(normalized.count))
            : 0
        let combinedConfidence = combineConfidence(support) * topProbability

        return ResolvedEvidence(
            entity: anchor.entity,
            property: anchor.property,
            value: .categoryProbabilities(normalized),
            unit: nil,
            confidence: max(0, min(1, combinedConfidence)),
            conflictScore: conflict,
            uncertainty: ResolvedUncertainty(
                effectiveSampleSize: effectiveSampleSize(
                    support.map(qualityWeight)
                ),
                categoricalEntropy: normalizedEntropy
            ),
            supportingRecordIDs: support.map(\.id).sorted(),
            rejectedRecords: rejections.sorted { $0.recordID < $1.recordID },
            sourceDatasets: Array(Set(support.map(\.datasetReference))).sorted()
        )
    }
}
