import Foundation

public struct CultureBaselineTrainingSession: Sendable, Hashable, Codable {
    public var sessionID: String
    public var cultureID: String
    public var donorID: String
    public var batchID: String
    public var simulationTick: UInt64
    public var stimulusID: String
    public var values: [String: Double]

    public init(sessionID: String, cultureID: String, donorID: String, batchID: String,
                simulationTick: UInt64, stimulusID: String, values: [String: Double]) {
        self.sessionID = sessionID; self.cultureID = cultureID; self.donorID = donorID
        self.batchID = batchID; self.simulationTick = simulationTick; self.stimulusID = stimulusID
        self.values = values
    }

    public func validated() throws -> Self {
        guard !sessionID.isEmpty, !cultureID.isEmpty, !donorID.isEmpty, !batchID.isEmpty,
              !stimulusID.isEmpty, !values.isEmpty,
              values.keys.allSatisfy({ !$0.isEmpty }), values.values.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("baseline training session")
        }
        return self
    }
}

public enum CultureBaselineKind: String, Sendable, Hashable, Codable, CaseIterable {
    case persistence
    case historicalMean
    case stimulusMatchedMean
    case linearTrend
}

public struct CultureBaselineRequest: Sendable, Hashable, Codable {
    public var kind: CultureBaselineKind
    public var id: String
    public var holdoutSessionID: String
    public var holdoutCultureID: String
    public var holdoutDonorID: String
    public var holdoutBatchID: String
    public var holdoutTick: UInt64
    public var stimulusID: String
    public var requiredFeatures: [String]
    public var independentCulture: Bool

    public init(kind: CultureBaselineKind, id: String, holdoutSessionID: String,
                holdoutCultureID: String, holdoutDonorID: String, holdoutBatchID: String,
                holdoutTick: UInt64, stimulusID: String, requiredFeatures: [String],
                independentCulture: Bool) {
        self.kind = kind; self.id = id; self.holdoutSessionID = holdoutSessionID
        self.holdoutCultureID = holdoutCultureID; self.holdoutDonorID = holdoutDonorID
        self.holdoutBatchID = holdoutBatchID; self.holdoutTick = holdoutTick
        self.stimulusID = stimulusID; self.requiredFeatures = requiredFeatures
        self.independentCulture = independentCulture
    }
}

public enum CultureBaselineForecaster {
    public static func forecast(
        request: CultureBaselineRequest,
        training sourceTraining: [CultureBaselineTrainingSession]
    ) throws -> CultureBaselineForecast {
        guard !request.id.isEmpty, !request.holdoutSessionID.isEmpty,
              !request.holdoutCultureID.isEmpty, !request.holdoutDonorID.isEmpty,
              !request.holdoutBatchID.isEmpty, !request.stimulusID.isEmpty,
              !request.requiredFeatures.isEmpty,
              Set(request.requiredFeatures).count == request.requiredFeatures.count else {
            throw CultureTwinError.invalid("baseline forecast request")
        }
        let training = try sourceTraining.map { try $0.validated() }
        guard !training.isEmpty, Set(training.map(\.sessionID)).count == training.count,
              training.allSatisfy({ $0.sessionID != request.holdoutSessionID && $0.simulationTick < request.holdoutTick }) else {
            throw CultureTwinError.leakage("baseline uses held-out or future observation")
        }
        if request.independentCulture {
            guard training.allSatisfy({
                $0.cultureID != request.holdoutCultureID &&
                $0.donorID != request.holdoutDonorID &&
                $0.batchID != request.holdoutBatchID
            }) else {
                throw CultureTwinError.leakage("independent-culture baseline shares biological group")
            }
        }
        let values: [String: Double]
        switch request.kind {
        case .persistence:
            let eligible = training.filter { $0.cultureID == request.holdoutCultureID }
                .sorted { ($0.simulationTick, $0.sessionID) < ($1.simulationTick, $1.sessionID) }
            guard let last = eligible.last else {
                throw CultureTwinError.invalid("persistence baseline lacks prior same-culture observation")
            }
            values = try select(last.values, required: request.requiredFeatures)
        case .historicalMean:
            values = try means(training: training, required: request.requiredFeatures)
        case .stimulusMatchedMean:
            let matched = training.filter { $0.stimulusID == request.stimulusID }
            guard !matched.isEmpty else {
                throw CultureTwinError.invalid("stimulus-matched baseline has no training examples")
            }
            values = try means(training: matched, required: request.requiredFeatures)
        case .linearTrend:
            let sameCulture = training.filter { $0.cultureID == request.holdoutCultureID }
                .sorted { ($0.simulationTick, $0.sessionID) < ($1.simulationTick, $1.sessionID) }
            guard sameCulture.count >= 2 else {
                throw CultureTwinError.invalid("linear baseline requires two prior same-culture sessions")
            }
            values = try request.requiredFeatures.reduce(into: [String: Double]()) { output, feature in
                let pairs = try sameCulture.map { session -> (Double, Double) in
                    guard let value = session.values[feature] else {
                        throw CultureTwinError.invalid("baseline feature missing: \(feature)")
                    }
                    return (Double(session.simulationTick), value)
                }
                output[feature] = leastSquaresPrediction(pairs, x: Double(request.holdoutTick))
            }
        }
        return CultureBaselineForecast(id: request.id, sessionID: request.holdoutSessionID, values: values)
    }

    private static func select(_ values: [String: Double], required: [String]) throws -> [String: Double] {
        try required.reduce(into: [String: Double]()) { output, feature in
            guard let value = values[feature], value.isFinite else {
                throw CultureTwinError.invalid("baseline feature missing: \(feature)")
            }
            output[feature] = value
        }
    }

    private static func means(training: [CultureBaselineTrainingSession], required: [String]) throws -> [String: Double] {
        try required.reduce(into: [String: Double]()) { output, feature in
            let values = try training.map { session -> Double in
                guard let value = session.values[feature], value.isFinite else {
                    throw CultureTwinError.invalid("baseline feature missing: \(feature)")
                }
                return value
            }
            output[feature] = values.reduce(0, +) / Double(values.count)
        }
    }

    private static func leastSquaresPrediction(_ pairs: [(Double, Double)], x: Double) -> Double {
        let meanX = pairs.map(\.0).reduce(0, +) / Double(pairs.count)
        let meanY = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
        var numerator = 0.0; var denominator = 0.0
        for pair in pairs {
            numerator += (pair.0 - meanX) * (pair.1 - meanY)
            denominator += (pair.0 - meanX) * (pair.0 - meanX)
        }
        guard denominator > 0 else { return meanY }
        let slope = numerator / denominator
        return meanY + slope * (x - meanX)
    }
}
