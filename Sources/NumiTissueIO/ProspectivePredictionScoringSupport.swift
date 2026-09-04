import Foundation

struct SeriesScoreResult {
    var validCount: Int
    var matchedCount: Int
    var score: Double
}

struct WeightedAccumulator {
    private var weightedTotal = 0.0
    private var weightTotal = 0.0

    mutating func add(value: Double, weight: Double) {
        weightedTotal += value * weight
        weightTotal += weight
    }

    func mean() throws -> Double {
        guard weightTotal > 0 else {
            throw ProspectiveScoringError.zeroAggregateWeight
        }
        return weightedTotal / weightTotal
    }
}

struct CoverageAccumulator {
    struct Bucket {
        var sampleCount = 0
        var coveredCount = 0
        var widthTotal = 0.0
    }

    var levels: [Double]
    var buckets: [Double: Bucket]

    init(levels: [Double]) {
        self.levels = levels
        self.buckets = Dictionary(uniqueKeysWithValues: levels.map { ($0, Bucket()) })
    }

    mutating func add(
        quantiles: [ProspectiveQuantile],
        observation: Double
    ) {
        for level in levels {
            let alpha = 1 - level
            let lowerProbability = alpha / 2
            let upperProbability = 1 - alpha / 2
            guard let lower = quantiles.first(where: {
                abs($0.probability - lowerProbability) <= 1e-12
            }), let upper = quantiles.first(where: {
                abs($0.probability - upperProbability) <= 1e-12
            }) else {
                continue
            }
            var bucket = buckets[level] ?? Bucket()
            bucket.sampleCount += 1
            if observation >= lower.value && observation <= upper.value {
                bucket.coveredCount += 1
            }
            bucket.widthTotal += upper.value - lower.value
            buckets[level] = bucket
        }
    }

    func reports() -> [ProspectiveCoverageReport] {
        levels.compactMap { level in
            guard let bucket = buckets[level], bucket.sampleCount > 0 else {
                return nil
            }
            let empirical = Double(bucket.coveredCount) / Double(bucket.sampleCount)
            return ProspectiveCoverageReport(
                nominalLevel: level,
                sampleCount: bucket.sampleCount,
                coveredCount: bucket.coveredCount,
                empiricalCoverage: empirical,
                absoluteCoverageError: abs(empirical - level),
                meanIntervalWidth: bucket.widthTotal / Double(bucket.sampleCount)
            )
        }
    }
}

struct ProspectiveBootstrapRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

enum ScientificSeed {
    static func hash(_ value: String) -> UInt64 {
        let digest = ScientificSHA256Digest(data: Data(value.utf8)).hexadecimal
        return UInt64(digest.prefix(16), radix: 16) ?? 0
    }
}

extension ProspectiveIdentifier {
    static func isCompositeKey(_ value: String) -> Bool {
        let parts = value.components(separatedBy: "::")
        return parts.count >= 2 && parts.allSatisfy(isStable)
    }
}

public enum ProspectiveScoringError: Error, Sendable, CustomStringConvertible {
    case invalidCoverageReport
    case invalidSeriesScore
    case invalidForecasterScore(String)
    case invalidBaselineComparison(String)
    case invalidCompliance
    case invalidScoreReport
    case candidateAuthorityRequired
    case invalidScoringTimeline
    case invalidBaselineBundle
    case missingRequiredBaseline
    case unknownObservationSeries
    case duplicateForecastSeries(String)
    case missingForecastSeries(String)
    case noMatchedObservations(String)
    case nonFiniteScore(String)
    case missingCentralIntervals
    case missingQuantile(Double)
    case noForecasterScores(String)
    case noPrimaryScores(String)
    case insufficientPairedReplicates(String, Int)
    case unknownScoringRule(String)
    case zeroAggregateWeight

    public var description: String {
        switch self {
        case .invalidCoverageReport: return "Prospective coverage report is invalid."
        case .invalidSeriesScore: return "Prospective series score is invalid."
        case .invalidForecasterScore(let id): return "Prospective forecaster score \(id) is invalid."
        case .invalidBaselineComparison(let id): return "Prospective baseline comparison \(id) is invalid."
        case .invalidCompliance: return "Prospective protocol-compliance report is invalid."
        case .invalidScoreReport: return "Prospective score report is invalid."
        case .candidateAuthorityRequired: return "Prospective scoring requires a frozen-model candidate forecast."
        case .invalidScoringTimeline: return "Prospective scoring timeline is invalid."
        case .invalidBaselineBundle: return "Prospective baseline forecast bundle is invalid or duplicated."
        case .missingRequiredBaseline: return "A preregistered required baseline forecast is missing."
        case .unknownObservationSeries: return "Prospective observation references an unknown target or blinded condition."
        case .duplicateForecastSeries(let key): return "Duplicate prospective forecast series \(key)."
        case .missingForecastSeries(let key): return "Missing prospective forecast series \(key)."
        case .noMatchedObservations(let key): return "No observations could be aligned for \(key)."
        case .nonFiniteScore(let id): return "Prospective score \(id) is non-finite."
        case .missingCentralIntervals: return "Weighted interval scoring requires at least one central prediction interval."
        case .missingQuantile(let value): return "Prospective forecast is missing quantile \(value)."
        case .noForecasterScores(let id): return "No prospective scores were produced for \(id)."
        case .noPrimaryScores(let id): return "No prospective primary scores were produced for \(id)."
        case .insufficientPairedReplicates(let id, let count): return "Baseline \(id) has only \(count) paired replicates."
        case .unknownScoringRule(let id): return "Unknown prospective scoring rule \(id)."
        case .zeroAggregateWeight: return "Prospective score aggregation has zero weight."
        }
    }
}
