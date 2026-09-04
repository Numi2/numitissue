import Foundation

public struct CultureBiologicalGroup: Sendable, Hashable, Codable {
    public var cultureID: String
    public var donorID: String
    public var batchID: String
    public var preparationID: String

    public init(cultureID: String, donorID: String, batchID: String, preparationID: String) {
        self.cultureID = cultureID; self.donorID = donorID
        self.batchID = batchID; self.preparationID = preparationID
    }

    public func validated() throws -> Self {
        guard !cultureID.isEmpty, !donorID.isEmpty, !batchID.isEmpty, !preparationID.isEmpty else {
            throw CultureTwinError.invalid("biological grouping")
        }
        return self
    }
}

public struct CultureHeldOutObservation: Sendable, Hashable, Codable {
    public var sessionID: String
    public var group: CultureBiologicalGroup
    public var values: [String: Double]

    public init(sessionID: String, group: CultureBiologicalGroup, values: [String: Double]) {
        self.sessionID = sessionID; self.group = group; self.values = values
    }
}

public struct CultureBaselineForecast: Sendable, Hashable, Codable {
    public var id: String
    public var sessionID: String
    public var values: [String: Double]
    public init(id: String, sessionID: String, values: [String: Double]) {
        self.id = id; self.sessionID = sessionID; self.values = values
    }
}

public struct CultureGroupedScore: Sendable, Hashable, Codable {
    public var groupID: String
    public var featureID: String
    public var candidateMAE: Double
    public var baselineMAE: [String: Double]
    public var replicateCount: Int
}

public struct CultureHierarchicalEvaluationReport: Sendable, Codable {
    public var groupedScores: [CultureGroupedScore]
    public var donorMeanCandidateMAE: [String: Double]
    public var batchMeanCandidateMAE: [String: Double]
    public var candidateOutperformedRequiredBaselines: Bool
    public var minimumRelativeImprovement: Double
    public var failureReasons: [String]
}

public enum CultureHierarchicalEvaluator {
    public static func evaluate(
        forecasts: [CultureHeldOutForecast],
        observations sourceObservations: [CultureHeldOutObservation],
        baselines: [CultureBaselineForecast],
        requiredBaselineIDs: Set<String>,
        featureScales: [String: Double],
        minimumRelativeImprovement: Double = 0.05
    ) throws -> CultureHierarchicalEvaluationReport {
        guard !forecasts.isEmpty, !sourceObservations.isEmpty,
              !requiredBaselineIDs.isEmpty,
              minimumRelativeImprovement.isFinite,
              minimumRelativeImprovement >= 0,
              featureScales.values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw CultureTwinError.invalid("hierarchical evaluation request")
        }
        let observations = try sourceObservations.map { value -> CultureHeldOutObservation in
            _ = try value.group.validated()
            guard !value.sessionID.isEmpty, !value.values.isEmpty,
                  value.values.values.allSatisfy(\.isFinite) else {
                throw CultureTwinError.invalid("held-out observation")
            }
            return value
        }
        let observationBySession = Dictionary(uniqueKeysWithValues: observations.map { ($0.sessionID, $0) })
        let forecastBySession = Dictionary(uniqueKeysWithValues: forecasts.map { ($0.sessionID, $0) })
        guard forecastBySession.count == forecasts.count,
              Set(forecastBySession.keys) == Set(observationBySession.keys) else {
            throw CultureTwinError.invalid("forecast/observation session coverage")
        }
        let baselineGroups = Dictionary(grouping: baselines, by: \.sessionID)
        guard baselines.allSatisfy({ !$0.id.isEmpty && !$0.sessionID.isEmpty && $0.values.values.allSatisfy(\.isFinite) }),
              observationBySession.keys.allSatisfy({ session in
                  requiredBaselineIDs.isSubset(of: Set((baselineGroups[session] ?? []).map(\.id)))
              }) else {
            throw CultureTwinError.invalid("required baseline coverage")
        }

        var rows: [CultureGroupedScore] = []
        var donorAccumulator: [String: [Double]] = [:]
        var batchAccumulator: [String: [Double]] = [:]
        var allRequiredPass = true
        var failures: [String] = []

        for sessionID in observationBySession.keys.sorted() {
            guard let observation = observationBySession[sessionID],
                  let forecast = forecastBySession[sessionID] else { continue }
            let baselineByID = Dictionary(uniqueKeysWithValues: (baselineGroups[sessionID] ?? []).map { ($0.id, $0) })
            let featureIDs = Set(observation.values.keys)
            guard featureIDs.isSubset(of: Set(featureScales.keys)) else {
                throw CultureTwinError.invalid("missing feature scale")
            }
            for featureID in featureIDs.sorted() {
                guard let observed = observation.values[featureID],
                      let scale = featureScales[featureID] else { continue }
                let candidateValues = forecast.members.compactMap { $0.values[featureID] }
                guard !candidateValues.isEmpty else {
                    throw CultureTwinError.invalid("candidate feature missing")
                }
                let candidatePoint = median(candidateValues)
                let candidateMAE = abs(candidatePoint - observed) / scale
                var baselineMAE: [String: Double] = [:]
                for id in requiredBaselineIDs.sorted() {
                    guard let value = baselineByID[id]?.values[featureID] else {
                        throw CultureTwinError.invalid("baseline feature missing")
                    }
                    let error = abs(value - observed) / scale
                    baselineMAE[id] = error
                    let improvement = (error - candidateMAE) / max(error, 1e-12)
                    if improvement < minimumRelativeImprovement {
                        allRequiredPass = false
                        failures.append("\(sessionID):\(featureID):\(id)")
                    }
                }
                rows.append(CultureGroupedScore(
                    groupID: observation.group.cultureID,
                    featureID: featureID,
                    candidateMAE: candidateMAE,
                    baselineMAE: baselineMAE,
                    replicateCount: candidateValues.count
                ))
                donorAccumulator[observation.group.donorID, default: []].append(candidateMAE)
                batchAccumulator[observation.group.batchID, default: []].append(candidateMAE)
            }
        }
        return CultureHierarchicalEvaluationReport(
            groupedScores: rows,
            donorMeanCandidateMAE: donorAccumulator.mapValues(mean),
            batchMeanCandidateMAE: batchAccumulator.mapValues(mean),
            candidateOutperformedRequiredBaselines: allRequiredPass,
            minimumRelativeImprovement: minimumRelativeImprovement,
            failureReasons: Array(Set(failures)).sorted()
        )
    }

    private static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let values = values.sorted()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? 0.5 * (values[middle - 1] + values[middle])
            : values[middle]
    }
}
