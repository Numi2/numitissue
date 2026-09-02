import Foundation

extension EvidenceFusionEngine {
    func numericCandidate(
        from record: EvidenceRecord,
        targetUnit: BiologicalUnit,
        policy: EvidenceFusionPolicy
    ) throws -> NumericCandidate {
        let mean: Double
        let intrinsicVariance: Double?

        switch record.value {
        case .scalar(let source):
            mean = try convert(source, from: record.unit, to: targetUnit)
            intrinsicVariance = nil

        case .interval(let lower, let upper):
            let convertedLower = try convert(lower, from: record.unit, to: targetUnit)
            let convertedUpper = try convert(upper, from: record.unit, to: targetUnit)
            mean = 0.5 * (convertedLower + convertedUpper)
            let width = abs(convertedUpper - convertedLower)
            intrinsicVariance = pow(width / 3.92, 2)

        case .gaussian(let sourceMean, let standardDeviation, let sampleCount):
            mean = try convert(sourceMean, from: record.unit, to: targetUnit)
            let convertedSD = abs(try convertDelta(
                standardDeviation,
                from: record.unit,
                to: targetUnit
            ))
            let divisor = Double(sampleCount ?? 1)
            intrinsicVariance = convertedSD * convertedSD / divisor

        case .samples(let samples):
            let converted = try samples.map {
                try convert($0, from: record.unit, to: targetUnit)
            }
            mean = converted.reduce(0, +) / Double(converted.count)
            if converted.count > 1 {
                let sumSquares = converted.reduce(0) {
                    $0 + ($1 - mean) * ($1 - mean)
                }
                let sampleVariance = sumSquares / Double(converted.count - 1)
                intrinsicVariance = sampleVariance / Double(converted.count)
            } else {
                intrinsicVariance = nil
            }

        default:
            throw EvidenceFusionError.unsupportedNumericValue(record.id)
        }

        let variance = try intrinsicVariance ?? inferredVariance(
            record: record,
            convertedMean: mean,
            targetUnit: targetUnit,
            policy: policy
        )
        guard mean.isFinite, variance.isFinite, variance >= 0 else {
            throw EvidenceFusionError.nonFiniteCandidate(record.id)
        }
        return NumericCandidate(
            record: record,
            mean: mean,
            variance: max(
                variance,
                policy.fallbackAbsoluteStandardError *
                    policy.fallbackAbsoluteStandardError
            ),
            qualityWeight: qualityWeight(record)
        )
    }

    func inferredVariance(
        record: EvidenceRecord,
        convertedMean: Double,
        targetUnit: BiologicalUnit,
        policy: EvidenceFusionPolicy
    ) throws -> Double {
        if let standardError = record.quality.standardError {
            let converted = abs(try convertDelta(
                standardError.value,
                from: standardError.unit,
                to: targetUnit
            ))
            return converted * converted
        }
        let sampleDivisor = sqrt(Double(record.quality.sampleCount ?? 1))
        let fallback = max(
            abs(convertedMean) * policy.fallbackRelativeStandardError,
            policy.fallbackAbsoluteStandardError
        ) / sampleDivisor
        return fallback * fallback
    }

    func vectorStandardErrors(
        record: EvidenceRecord,
        values: [Double],
        targetUnit: BiologicalUnit,
        policy: EvidenceFusionPolicy
    ) throws -> [Double] {
        try values.map {
            sqrt(try inferredVariance(
                record: record,
                convertedMean: $0,
                targetUnit: targetUnit,
                policy: policy
            ))
        }
    }

    func targetUnit(
        for records: [EvidenceRecord],
        policy: EvidenceFusionPolicy
    ) throws -> BiologicalUnit {
        let first = records.first
        let selected = policy.targetUnit ?? first?.unit ?? .dimensionless
        if let expected = first?.property.expectedDimension,
           selected.dimension != expected {
            throw EvidenceFusionError.incompatibleUnit(
                expected: expected,
                actual: selected.dimension
            )
        }
        for record in records {
            let source = record.unit ?? .dimensionless
            guard source.dimension == selected.dimension else {
                throw EvidenceFusionError.incompatibleUnit(
                    expected: selected.dimension,
                    actual: source.dimension
                )
            }
        }
        return selected
    }

    func convert(
        _ value: Double,
        from source: BiologicalUnit?,
        to target: BiologicalUnit
    ) throws -> Double {
        try UnitConverter.convert(
            value,
            from: source ?? .dimensionless,
            to: target
        )
    }

    func convertDelta(
        _ value: Double,
        from source: BiologicalUnit?,
        to target: BiologicalUnit
    ) throws -> Double {
        let sourceUnit = source ?? .dimensionless
        guard sourceUnit.dimension == target.dimension else {
            throw UnitConversionError.incompatibleDimensions(
                source: sourceUnit.dimension,
                target: target.dimension
            )
        }
        return value * sourceUnit.scaleToSI / target.scaleToSI
    }

    func fuse(
        _ sourceCandidates: [NumericCandidate],
        policy: EvidenceFusionPolicy,
        initialRejections: [EvidenceRejection]
    ) throws -> NumericFusion {
        if policy.strategy == .authoritativeSource {
            let sorted = sourceCandidates.sorted {
                authoritySort($0.record, $1.record, policy: policy)
            }
            let selected = sorted[0]
            let rejected = initialRejections + sorted.dropFirst().map {
                EvidenceRejection(
                    recordID: $0.record.id,
                    reason: .lowerAuthority
                )
            }
            return NumericFusion(
                value: selected.mean,
                standardError: sqrt(selected.variance),
                betweenSourceStandardDeviation: 0,
                effectiveSampleSize: 1,
                conflictScore: 0,
                confidence: selected.qualityWeight,
                support: [selected.record],
                rejected: rejected
            )
        }

        var candidates = sourceCandidates
        var rejected = initialRejections
        if candidates.count >= 4 {
            let center = median(candidates.map(\.mean))
            let deviations = candidates.map { abs($0.mean - center) }
            let mad = median(deviations)
            if mad > policy.fallbackAbsoluteStandardError {
                let robustScale = 1.4826 * mad
                let retained = candidates.filter {
                    abs($0.mean - center) / robustScale <= policy.outlierZScore
                }
                let outliers = candidates.filter {
                    abs($0.mean - center) / robustScale > policy.outlierZScore
                }
                if retained.count >= policy.minimumSupport {
                    candidates = retained
                    rejected.append(contentsOf: outliers.map {
                        EvidenceRejection(
                            recordID: $0.record.id,
                            reason: .outlier
                        )
                    })
                }
            }
        }
        guard candidates.count >= policy.minimumSupport else {
            throw EvidenceFusionError.insufficientSupport(
                required: policy.minimumSupport,
                actual: candidates.count
            )
        }

        if policy.strategy == .requireAgreement {
            let minimum = candidates.map(\.mean).min() ?? 0
            let maximum = candidates.map(\.mean).max() ?? 0
            let scale = max(
                abs(candidates.map(\.mean).reduce(0, +) / Double(candidates.count)),
                policy.fallbackAbsoluteStandardError
            )
            let allowed = policy.agreementAbsoluteTolerance +
                policy.agreementRelativeTolerance * scale
            guard maximum - minimum <= allowed else {
                throw EvidenceFusionError.requiredAgreementFailed(
                    spread: maximum - minimum,
                    allowed: allowed
                )
            }
        }

        let baseWeights = candidates.map {
            inverseVarianceWeight($0, policy: policy)
        }
        var weights = baseWeights
        var value: Double

        switch policy.strategy {
        case .weightedMedian:
            value = weightedMedian(
                values: candidates.map(\.mean),
                weights: weights
            )
        case .robustHuber:
            value = weightedMean(values: candidates.map(\.mean), weights: weights)
            for _ in 0..<policy.maximumIterations {
                let residualScale = max(
                    1.4826 * median(candidates.map { abs($0.mean - value) }),
                    policy.fallbackAbsoluteStandardError
                )
                let nextWeights = zip(candidates, baseWeights).map { pair in
                    let candidate = pair.0
                    let baseWeight = pair.1
                    let residual = abs(candidate.mean - value) / residualScale
                    let huber = residual <= policy.huberDelta
                        ? 1
                        : policy.huberDelta / residual
                    return baseWeight * huber
                }
                let next = weightedMean(
                    values: candidates.map(\.mean),
                    weights: nextWeights
                )
                weights = nextWeights
                if abs(next - value) <=
                    policy.fallbackAbsoluteStandardError +
                    abs(value) * 1e-10 {
                    value = next
                    break
                }
                value = next
            }
        case .inverseVariance, .requireAgreement:
            value = weightedMean(values: candidates.map(\.mean), weights: weights)
        case .authoritativeSource:
            preconditionFailure("Handled before numeric aggregation.")
        }

        let sumWeight = weights.reduce(0, +)
        let withinVariance = zip(candidates, weights).reduce(0.0) {
            $0 + $1.0.variance * $1.1
        } / max(sumWeight, Double.leastNonzeroMagnitude)
        let betweenVariance = zip(candidates, weights).reduce(0.0) {
            let delta = $1.0.mean - value
            return $0 + $1.1 * delta * delta
        } / max(sumWeight, Double.leastNonzeroMagnitude)
        let effective = effectiveSampleSize(weights)
        let samplingVariance = 1 / max(sumWeight, Double.leastNonzeroMagnitude)
        let standardError = sqrt(max(
            samplingVariance + betweenVariance / max(effective, 1),
            0
        ))
        let conflict = betweenVariance /
            max(betweenVariance + withinVariance, Double.leastNonzeroMagnitude)
        let confidence = combineConfidence(candidates.map(\.record)) *
            (1 - max(0, min(1, conflict)))

        return NumericFusion(
            value: value,
            standardError: standardError,
            betweenSourceStandardDeviation: sqrt(max(betweenVariance, 0)),
            effectiveSampleSize: effective,
            conflictScore: max(0, min(1, conflict)),
            confidence: max(0, min(1, confidence)),
            support: candidates.map(\.record),
            rejected: rejected
        )
    }

    func inverseVarianceWeight(
        _ candidate: NumericCandidate,
        policy: EvidenceFusionPolicy
    ) -> Double {
        let floor = policy.fallbackAbsoluteStandardError *
            policy.fallbackAbsoluteStandardError
        return candidate.qualityWeight / max(candidate.variance, floor)
    }

    func qualityWeight(_ record: EvidenceRecord) -> Double {
        let curation: Double
        switch record.quality.curation {
        case .raw: curation = 0.8
        case .automaticallyNormalized: curation = 0.9
        case .manuallyReviewed: curation = 1
        case .independentlyReplicated: curation = 1
        case .deprecated: curation = 0.05
        }

        let method: Double
        switch record.quality.method {
        case .directMeasurement, .patchClamp, .electronMicroscopy:
            method = 1
        case .manualReconstruction, .opticalImaging, .spatialAssay, .sequencing:
            method = 0.95
        case .automatedSegmentation, .modelFit:
            method = 0.85
        case .expertCuration:
            method = 0.9
        case .statisticalInference:
            method = 0.75
        case .simulation:
            method = 0.65
        case .literatureExtraction:
            method = 0.7
        case .generatedPrior:
            method = 0.4
        case .unknown:
            method = 0.5
        }

        var flagPenalty = 1.0
        for flag in record.quality.flags {
            switch flag {
            case .alignmentUncertain: flagPenalty *= 0.75
            case .estimated: flagPenalty *= 0.75
            case .incompleteMetadata: flagPenalty *= 0.8
            case .licenseRestricted: flagPenalty *= 0.95
            case .lowSignal: flagPenalty *= 0.5
            case .modelDerived: flagPenalty *= 0.7
            case .outlier: flagPenalty *= 0.25
            case .reconstructionGap: flagPenalty *= 0.6
            case .truncated: flagPenalty *= 0.6
            case .duplicated, .failedQualityControl, .superseded:
                flagPenalty *= 0.01
            }
        }
        return max(
            1e-9,
            min(1, record.quality.confidence * curation * method * flagPenalty)
        )
    }

    func authoritySort(
        _ lhs: EvidenceRecord,
        _ rhs: EvidenceRecord,
        policy: EvidenceFusionPolicy
    ) -> Bool {
        let lhsRank = policy.sourceRank(lhs.source)
        let rhsRank = policy.sourceRank(rhs.source)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        let lhsQuality = qualityWeight(lhs)
        let rhsQuality = qualityWeight(rhs)
        if lhsQuality != rhsQuality { return lhsQuality > rhsQuality }
        return lhs.id < rhs.id
    }

    func combineConfidence(_ records: [EvidenceRecord]) -> Double {
        1 - records.reduce(1.0) {
            $0 * (1 - max(0, min(0.999_999, qualityWeight($1))))
        }
    }

    func enforceConflict(
        _ conflict: Double,
        policy: EvidenceFusionPolicy
    ) throws {
        guard conflict <= policy.maximumConflictScore else {
            throw EvidenceFusionError.conflictExceeded(
                conflict: conflict,
                maximum: policy.maximumConflictScore
            )
        }
    }

    func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return 0.5 * (sorted[middle - 1] + sorted[middle])
        }
        return sorted[middle]
    }

    func weightedMedian(values: [Double], weights: [Double]) -> Double {
        let ordered = zip(values, weights).sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1 < $1.1
        }
        let threshold = 0.5 * weights.reduce(0, +)
        var cumulative = 0.0
        for (value, weight) in ordered {
            cumulative += weight
            if cumulative >= threshold { return value }
        }
        return ordered.last?.0 ?? 0
    }

    func weightedMean(values: [Double], weights: [Double]) -> Double {
        let denominator = weights.reduce(0, +)
        guard denominator > 0 else {
            return values.reduce(0, +) / Double(max(values.count, 1))
        }
        return zip(values, weights).reduce(0.0) {
            $0 + $1.0 * $1.1
        } / denominator
    }

    func effectiveSampleSize(_ weights: [Double]) -> Double {
        let sum = weights.reduce(0, +)
        let sumSquares = weights.reduce(0) { $0 + $1 * $1 }
        guard sumSquares > 0 else { return 0 }
        return sum * sum / sumSquares
    }
}
