import Foundation

extension ProspectivePredictionScorer {
    static func forecastMap(
        _ bundle: ProspectiveForecastBundle
    ) throws -> [String: ProspectiveForecastSeries] {
        var result: [String: ProspectiveForecastSeries] = [:]
        for series in bundle.series {
            let value = try series.validated()
            let key = forecastKey(
                blindedID: value.blindedID,
                targetID: value.targetID
            )
            guard result.updateValue(value, forKey: key) == nil else {
                throw ProspectiveScoringError.duplicateForecastSeries(key)
            }
        }
        return result
    }

    static func scoreSeries(
        forecast: ProspectiveForecastSeries,
        observation: ProspectiveObservationSeries,
        target: ProspectivePredictionTarget,
        rule: ProspectiveScoringRule,
        coverage: inout CoverageAccumulator
    ) throws -> SeriesScoreResult {
        var pointScores: [Double] = []
        var squaredErrors: [Double] = []
        var absoluteErrors: [Double] = []
        var validCount = 0
        var matchedCount = 0
        var finalAbsoluteError: Double?

        for observed in observation.points where observed.valid && rule.timeWindow.contains(observed.timeSeconds) {
            validCount += 1
            guard let quantiles = try alignedQuantiles(
                in: forecast,
                at: observed.timeSeconds,
                target: target
            ) else {
                continue
            }
            matchedCount += 1
            let transformedObservation = try target.transform.apply(observed.value)
            let transformedQuantiles = try quantiles.map {
                ProspectiveQuantile(
                    probability: $0.probability,
                    value: try target.transform.apply($0.value)
                )
            }
            let median = try quantileValue(
                transformedQuantiles,
                probability: 0.5
            )
            let error = median - transformedObservation
            squaredErrors.append(error * error)
            absoluteErrors.append(abs(error))
            finalAbsoluteError = abs(error)
            switch rule.metric {
            case .quantileCRPS:
                pointScores.append(
                    quantileCRPS(
                        quantiles: transformedQuantiles,
                        observation: transformedObservation
                    )
                )
            case .weightedIntervalScore:
                pointScores.append(try weightedIntervalScore(
                    quantiles: transformedQuantiles,
                    observation: transformedObservation
                ))
            case .rootMeanSquaredError,
                 .meanAbsoluteError,
                 .absoluteEndpointError:
                break
            }
            coverage.add(
                quantiles: transformedQuantiles,
                observation: transformedObservation
            )
        }
        guard validCount > 0,
              matchedCount > 0 else {
            throw ProspectiveScoringError.noMatchedObservations(
                "\(observation.blindedID)::\(observation.targetID)::\(observation.replicateID)::\(rule.id)"
            )
        }
        let value: Double
        switch rule.metric {
        case .quantileCRPS, .weightedIntervalScore:
            value = pointScores.reduce(0, +) / Double(pointScores.count)
        case .rootMeanSquaredError:
            value = sqrt(squaredErrors.reduce(0, +) / Double(squaredErrors.count))
        case .meanAbsoluteError:
            value = absoluteErrors.reduce(0, +) / Double(absoluteErrors.count)
        case .absoluteEndpointError:
            guard let finalAbsoluteError else {
                throw ProspectiveScoringError.noMatchedObservations(rule.id)
            }
            value = finalAbsoluteError
        }
        guard value.isFinite, value >= 0 else {
            throw ProspectiveScoringError.nonFiniteScore(rule.id)
        }
        return SeriesScoreResult(
            validCount: validCount,
            matchedCount: matchedCount,
            score: value
        )
    }

    static func scoreSeriesWithoutCoverage(
        forecast: ProspectiveForecastSeries,
        observation: ProspectiveObservationSeries,
        target: ProspectivePredictionTarget,
        rule: ProspectiveScoringRule
    ) throws -> SeriesScoreResult {
        var ignored = CoverageAccumulator(levels: [])
        return try scoreSeries(
            forecast: forecast,
            observation: observation,
            target: target,
            rule: rule,
            coverage: &ignored
        )
    }

    static func alignedQuantiles(
        in series: ProspectiveForecastSeries,
        at time: Double,
        target: ProspectivePredictionTarget
    ) throws -> [ProspectiveQuantile]? {
        let tolerance = target.alignmentToleranceSeconds
        switch target.alignment {
        case .exact:
            return series.points.first {
                abs($0.timeSeconds - time) <= tolerance
            }?.quantiles
        case .nearest:
            guard let point = series.points.min(by: {
                abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
            }), abs(point.timeSeconds - time) <= tolerance else {
                return nil
            }
            return point.quantiles
        case .linear:
            if let exact = series.points.first(where: {
                abs($0.timeSeconds - time) <= min(tolerance, 1e-12)
            }) {
                return exact.quantiles
            }
            guard let upperIndex = series.points.firstIndex(where: {
                $0.timeSeconds > time
            }), upperIndex > 0 else {
                guard let edge = series.points.min(by: {
                    abs($0.timeSeconds - time) < abs($1.timeSeconds - time)
                }), abs(edge.timeSeconds - time) <= tolerance else {
                    return nil
                }
                return edge.quantiles
            }
            let lower = series.points[upperIndex - 1]
            let upper = series.points[upperIndex]
            guard time - lower.timeSeconds <= tolerance,
                  upper.timeSeconds - time <= tolerance,
                  lower.quantiles.map(\.probability) == upper.quantiles.map(\.probability) else {
                return nil
            }
            let span = upper.timeSeconds - lower.timeSeconds
            guard span > 0 else { return lower.quantiles }
            let fraction = (time - lower.timeSeconds) / span
            return zip(lower.quantiles, upper.quantiles).map { lowerValue, upperValue in
                ProspectiveQuantile(
                    probability: lowerValue.probability,
                    value: lowerValue.value + fraction * (upperValue.value - lowerValue.value)
                )
            }
        }
    }

    static func quantileCRPS(
        quantiles: [ProspectiveQuantile],
        observation: Double
    ) -> Double {
        let total = quantiles.reduce(0.0) { partial, quantile in
            let residual = observation - quantile.value
            let pinball = residual >= 0
                ? quantile.probability * residual
                : (quantile.probability - 1) * residual
            return partial + pinball
        }
        return 2 * total / Double(quantiles.count)
    }

    static func weightedIntervalScore(
        quantiles: [ProspectiveQuantile],
        observation: Double
    ) throws -> Double {
        let median = try quantileValue(quantiles, probability: 0.5)
        let lower = quantiles.filter { $0.probability < 0.5 }
        var weightedTotal = 0.5 * abs(observation - median)
        var normalization = 0.5
        var intervals = 0
        for lowerQuantile in lower {
            let upperProbability = 1 - lowerQuantile.probability
            guard let upper = quantiles.first(where: {
                abs($0.probability - upperProbability) <= 1e-12
            }) else { continue }
            let alpha = 2 * lowerQuantile.probability
            let width = upper.value - lowerQuantile.value
            var intervalScore = width
            if observation < lowerQuantile.value {
                intervalScore += 2 / alpha * (lowerQuantile.value - observation)
            } else if observation > upper.value {
                intervalScore += 2 / alpha * (observation - upper.value)
            }
            let weight = alpha / 2
            weightedTotal += weight * intervalScore
            normalization += weight
            intervals += 1
        }
        guard intervals > 0,
              normalization > 0 else {
            throw ProspectiveScoringError.missingCentralIntervals
        }
        return weightedTotal / normalization
    }

    static func quantileValue(
        _ quantiles: [ProspectiveQuantile],
        probability: Double
    ) throws -> Double {
        guard let value = quantiles.first(where: {
            abs($0.probability - probability) <= 1e-12
        })?.value else {
            throw ProspectiveScoringError.missingQuantile(probability)
        }
        return value
    }

}
