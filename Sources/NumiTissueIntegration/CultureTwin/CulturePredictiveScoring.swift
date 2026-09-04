import Foundation
import NumiTissueIO

public struct CulturePredictionIntervalScore: Sendable, Codable {
    public var level: Double
    public var lower: Double
    public var upper: Double
    public var covered: Bool
}

public struct CulturePredictiveFeatureScore: Sendable, Codable {
    public var featureID: String
    public var unit: String
    public var observed: Double
    public var predictedMedian: Double
    public var absoluteError: Double
    public var empiricalCRPS: Double
    public var normalizedCRPS: Double
    public var intervals: [CulturePredictionIntervalScore]
}

public struct CulturePredictiveScoreReport: Sendable, Codable {
    public var schemaVersion: UInt32
    public var sessionID: String
    public var cultureID: String
    public var donorID: String
    public var batchID: String
    public var partition: CultureStudyPartition
    public var studySHA256: ScientificSHA256Digest
    public var forecastSHA256: ScientificSHA256Digest
    public var observationSHA256: ScientificSHA256Digest
    public var features: [CulturePredictiveFeatureScore]
    /// A descriptive score. Neither a biological-validation certificate nor a significance test.
    public var meanNormalizedCRPS: Double
}

public enum CulturePredictiveScorer {
    /// Exact CRPS of an equally weighted finite empirical distribution, O(N log N).
    /// Scores the predictive samples as supplied; observation noise is not added a second time.
    public static func empiricalCRPS(samples: [Double], observed: Double) throws -> Double {
        guard !samples.isEmpty, samples.count <= 1_000_000,
              samples.allSatisfy(\.isFinite), observed.isFinite else {
            throw CultureTwinError.invalid("predictive distribution")
        }
        let sorted = samples.sorted()
        let n = Double(sorted.count)
        let absoluteTerm = sorted.reduce(0.0) { $0 + abs($1 - observed) / n }
        var pairTerm = 0.0
        for index in sorted.indices {
            pairTerm += (2 * Double(index) - n + 1) * sorted[index] / n / n
        }
        let result = absoluteTerm - pairTerm
        guard result.isFinite, result >= -1e-10 * max(1, absoluteTerm) else {
            throw CultureTwinError.invalid("predictive score overflow or cancellation")
        }
        return max(0, result)
    }

    public static func score(forecast: CultureHeldOutForecast, observations: CultureFeatureReport,
                             design sourceDesign: CultureStudyDesign,
                             expectedModelSHA256: ScientificSHA256Digest,
                             expectedPosteriorSHA256: ScientificSHA256Digest) throws -> CulturePredictiveScoreReport {
        let design = try sourceDesign.validated()
        guard forecast.schemaVersion == 1, forecast.studySHA256 == (try design.digest()),
              forecast.modelSHA256 == expectedModelSHA256, forecast.posteriorSHA256 == expectedPosteriorSHA256,
              forecast.members.count >= 4, forecast.members.count <= 4096,
              Set(forecast.members.map(\.id)).count == forecast.members.count,
              observations.recordingID == forecast.sessionID,
              observations.measurementModelID == design.measurementModelID,
              observations.extractionSHA256 == ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(design.featureConfiguration)),
              let session = design.sessions.first(where: { $0.id == forecast.sessionID }),
              session.partition != .calibration,
              Set(observations.features.map(\.id)).count == observations.features.count else {
            throw CultureTwinError.invalid("held-out evidence binding")
        }
        let expectedFeatures = Set(design.features.map(\.id))
        guard forecast.members.allSatisfy({ Set($0.values.keys) == expectedFeatures && $0.values.values.allSatisfy(\.isFinite) }) else {
            throw CultureTwinError.invalid("incomplete predictive ensemble")
        }
        let measured = Dictionary(uniqueKeysWithValues: observations.features.map { ($0.id, $0) })
        let rows = try design.features.sorted { $0.id < $1.id }.map { contract in
            guard let observation = measured[contract.id], observation.unit == contract.unit,
                  observation.value.isFinite else { throw CultureTwinError.invalid("missing held-out observation") }
            let values = try forecast.members.map { member -> Double in
                guard let value = member.values[contract.id] else { throw CultureTwinError.invalid("missing prediction") }
                return value
            }.sorted()
            let median = quantile(values, probability: 0.5)
            let crps = try empiricalCRPS(samples: values, observed: observation.value)
            let normalized = crps / contract.scale
            guard normalized.isFinite else { throw CultureTwinError.invalid("normalized score overflow") }
            let intervals = [0.5, 0.8, 0.9, 0.95].map { level in
                let tail = (1 - level) / 2
                let lower = quantile(values, probability: tail)
                let upper = quantile(values, probability: 1 - tail)
                return CulturePredictionIntervalScore(level: level, lower: lower, upper: upper,
                                                       covered: lower <= observation.value && observation.value <= upper)
            }
            return CulturePredictiveFeatureScore(featureID: contract.id, unit: contract.unit,
                observed: observation.value, predictedMedian: median, absoluteError: abs(median - observation.value),
                empiricalCRPS: crps, normalizedCRPS: normalized, intervals: intervals)
        }
        let mean = rows.reduce(0.0) { $0 + $1.normalizedCRPS / Double(rows.count) }
        guard mean.isFinite else { throw CultureTwinError.invalid("aggregate score overflow") }
        return CulturePredictiveScoreReport(schemaVersion: 1, sessionID: session.id, cultureID: session.cultureID,
            donorID: session.donorID, batchID: session.batchID, partition: session.partition,
            studySHA256: try design.digest(), forecastSHA256: try forecast.digest(),
            observationSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(observations)),
            features: rows, meanNormalizedCRPS: mean)
    }

    private static func quantile(_ sorted: [Double], probability: Double) -> Double {
        let position = probability * Double(sorted.count - 1)
        let lower = Int(floor(position)); let upper = Int(ceil(position))
        let fraction = position - Double(lower)
        return (1 - fraction) * sorted[lower] + fraction * sorted[upper]
    }
}
