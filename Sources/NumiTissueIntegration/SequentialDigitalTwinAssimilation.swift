import Foundation

public enum TissueTwinParameterTransform: String, Sendable, Hashable, Codable {
    case identity
    case logarithmic
    case boundedLogit
}

public struct TissueTwinParameterDefinition: Sendable, Hashable, Codable {
    public var name: String
    public var lowerBound: Double
    public var upperBound: Double
    public var priorMean: Double
    public var priorStandardDeviation: Double
    public var processNoiseStandardDeviationLatent: Double
    public var transform: TissueTwinParameterTransform
    public var metadata: [String: String]

    public init(
        name: String,
        lowerBound: Double,
        upperBound: Double,
        priorMean: Double,
        priorStandardDeviation: Double,
        processNoiseStandardDeviationLatent: Double = 0,
        transform: TissueTwinParameterTransform = .identity,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.priorMean = priorMean
        self.priorStandardDeviation = priorStandardDeviation
        self.processNoiseStandardDeviationLatent = processNoiseStandardDeviationLatent
        self.transform = transform
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              lowerBound.isFinite,
              upperBound.isFinite,
              upperBound > lowerBound,
              priorMean.isFinite,
              priorMean >= lowerBound,
              priorMean <= upperBound,
              priorStandardDeviation.isFinite,
              priorStandardDeviation >= 0,
              processNoiseStandardDeviationLatent.isFinite,
              processNoiseStandardDeviationLatent >= 0 else {
            throw TissueTwinAssimilationError.invalidParameter(name)
        }
        if transform == .logarithmic, lowerBound <= 0 {
            throw TissueTwinAssimilationError.invalidParameter(name)
        }
        return self
    }

    public func encode(_ source: Double) throws -> Double {
        guard source.isFinite else {
            throw TissueTwinAssimilationError.nonFiniteParameter(name)
        }
        let epsilon = max((upperBound - lowerBound) * 1e-12, 1e-15)
        let value = min(max(source, lowerBound + epsilon), upperBound - epsilon)
        switch transform {
        case .identity:
            return min(max(source, lowerBound), upperBound)
        case .logarithmic:
            return log(max(source, lowerBound))
        case .boundedLogit:
            let probability = (value - lowerBound) / (upperBound - lowerBound)
            return log(probability / (1 - probability))
        }
    }

    public func decode(_ latent: Double) throws -> Double {
        guard latent.isFinite else {
            throw TissueTwinAssimilationError.nonFiniteParameter(name)
        }
        let raw: Double
        switch transform {
        case .identity:
            raw = latent
        case .logarithmic:
            raw = exp(min(latent, log(Double.greatestFiniteMagnitude)))
        case .boundedLogit:
            let sigmoid: Double
            if latent >= 0 {
                let decay = exp(-latent)
                sigmoid = 1 / (1 + decay)
            } else {
                let growth = exp(latent)
                sigmoid = growth / (1 + growth)
            }
            raw = lowerBound + sigmoid * (upperBound - lowerBound)
        }
        return min(max(raw, lowerBound), upperBound)
    }
}

public struct TissueTwinObservationBatch: Sendable, Hashable, Codable {
    public var id: UUID
    public var tick: UInt64
    public var names: [String]
    public var values: [Double]
    public var covarianceRowMajor: [Double]
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        tick: UInt64,
        names: [String],
        values: [Double],
        covarianceRowMajor: [Double],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.tick = tick
        self.names = names
        self.values = values
        self.covarianceRowMajor = covarianceRowMajor
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        let dimension = names.count
        guard dimension > 0,
              Set(names).count == dimension,
              names.allSatisfy({ !$0.isEmpty }),
              values.count == dimension,
              values.allSatisfy(\.isFinite),
              covarianceRowMajor.count == dimension * dimension,
              covarianceRowMajor.allSatisfy(\.isFinite) else {
            throw TissueTwinAssimilationError.invalidObservationBatch(id)
        }
        let tolerance = 1e-10
        for row in 0..<dimension {
            guard covarianceRowMajor[row * dimension + row] >= 0 else {
                throw TissueTwinAssimilationError.invalidObservationCovariance
            }
            for column in 0..<row {
                let lhs = covarianceRowMajor[row * dimension + column]
                let rhs = covarianceRowMajor[column * dimension + row]
                guard abs(lhs - rhs) <= tolerance * max(1, abs(lhs), abs(rhs)) else {
                    throw TissueTwinAssimilationError.invalidObservationCovariance
                }
            }
        }
        return self
    }
}

public struct TissueTwinPrediction: Sendable, Hashable, Codable {
    public var observables: [String: Double]
    public var nextOpaqueState: Data?
    public var metadata: [String: String]

    public init(
        observables: [String: Double],
        nextOpaqueState: Data? = nil,
        metadata: [String: String] = [:]
    ) {
        self.observables = observables
        self.nextOpaqueState = nextOpaqueState
        self.metadata = metadata
    }

    public func validated(requiredNames: Set<String>) throws -> Self {
        guard requiredNames.isSubset(of: Set(observables.keys)),
              observables.values.allSatisfy(\.isFinite) else {
            throw TissueTwinAssimilationError.invalidPrediction
        }
        return self
    }
}

public struct TissueTwinEnsembleMember: Sendable, Hashable, Codable {
    public var id: UInt64
    public var latentParameters: [Double]
    public var opaqueState: Data?
    public var metadata: [String: String]

    public init(
        id: UInt64,
        latentParameters: [Double],
        opaqueState: Data? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.latentParameters = latentParameters
        self.opaqueState = opaqueState
        self.metadata = metadata
    }
}

public enum TissueTwinOutlierPolicy: Sendable, Hashable, Codable {
    case reject
    case inflateObservationCovariance(maximumFactor: Double)
}

public struct TissueTwinAssimilationConfiguration: Sendable, Hashable, Codable {
    public var ensembleSize: Int
    public var maximumConcurrentForecasts: Int
    public var parameterInflation: Double
    public var observationPerturbationScale: Double
    public var covarianceJitter: Double
    public var maximumCholeskyAttempts: Int
    public var innovationMahalanobisLimit: Double
    public var outlierPolicy: TissueTwinOutlierPolicy
    public var localizationByParameterAndObservation: [String: [String: Double]]
    public var seed: UInt64

    public init(
        ensembleSize: Int = 64,
        maximumConcurrentForecasts: Int = 8,
        parameterInflation: Double = 1.02,
        observationPerturbationScale: Double = 1,
        covarianceJitter: Double = 1e-9,
        maximumCholeskyAttempts: Int = 8,
        innovationMahalanobisLimit: Double = 25,
        outlierPolicy: TissueTwinOutlierPolicy = .inflateObservationCovariance(
            maximumFactor: 100
        ),
        localizationByParameterAndObservation: [String: [String: Double]] = [:],
        seed: UInt64
    ) {
        self.ensembleSize = ensembleSize
        self.maximumConcurrentForecasts = maximumConcurrentForecasts
        self.parameterInflation = parameterInflation
        self.observationPerturbationScale = observationPerturbationScale
        self.covarianceJitter = covarianceJitter
        self.maximumCholeskyAttempts = maximumCholeskyAttempts
        self.innovationMahalanobisLimit = innovationMahalanobisLimit
        self.outlierPolicy = outlierPolicy
        self.localizationByParameterAndObservation = localizationByParameterAndObservation
        self.seed = seed
    }

    public func validated(
        parameters: [TissueTwinParameterDefinition]
    ) throws -> Self {
        guard ensembleSize >= 4,
              maximumConcurrentForecasts > 0,
              parameterInflation.isFinite,
              parameterInflation >= 1,
              observationPerturbationScale.isFinite,
              observationPerturbationScale >= 0,
              covarianceJitter.isFinite,
              covarianceJitter > 0,
              maximumCholeskyAttempts > 0,
              innovationMahalanobisLimit.isFinite,
              innovationMahalanobisLimit > 0 else {
            throw TissueTwinAssimilationError.invalidConfiguration
        }
        if case .inflateObservationCovariance(let maximumFactor) = outlierPolicy {
            guard maximumFactor.isFinite, maximumFactor >= 1 else {
                throw TissueTwinAssimilationError.invalidConfiguration
            }
        }
        let parameterNames = Set(parameters.map(\.name))
        guard Set(localizationByParameterAndObservation.keys)
            .isSubset(of: parameterNames) else {
            throw TissueTwinAssimilationError.invalidLocalization
        }
        for row in localizationByParameterAndObservation.values {
            guard row.keys.allSatisfy({ !$0.isEmpty }),
                  row.values.allSatisfy({
                      $0.isFinite && (0...1).contains($0)
                  }) else {
                throw TissueTwinAssimilationError.invalidLocalization
            }
        }
        return self
    }
}

public struct TissueTwinParameterSummary: Sendable, Hashable, Codable {
    public var name: String
    public var mean: Double
    public var standardDeviation: Double
    public var minimum: Double
    public var maximum: Double

    public init(
        name: String,
        mean: Double,
        standardDeviation: Double,
        minimum: Double,
        maximum: Double
    ) {
        self.name = name
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct TissueTwinAssimilationReport: Sendable, Hashable, Codable {
    public var observationID: UUID
    public var tick: UInt64
    public var accepted: Bool
    public var priorParameterSummary: [TissueTwinParameterSummary]
    public var posteriorParameterSummary: [TissueTwinParameterSummary]
    public var predictedObservationMean: [String: Double]
    public var innovation: [String: Double]
    public var innovationMahalanobisSquared: Double
    public var observationCovarianceInflation: Double
    public var choleskyJitterUsed: Double
    public var ensembleSize: Int
    public var metadata: [String: String]

    public init(
        observationID: UUID,
        tick: UInt64,
        accepted: Bool,
        priorParameterSummary: [TissueTwinParameterSummary],
        posteriorParameterSummary: [TissueTwinParameterSummary],
        predictedObservationMean: [String: Double],
        innovation: [String: Double],
        innovationMahalanobisSquared: Double,
        observationCovarianceInflation: Double,
        choleskyJitterUsed: Double,
        ensembleSize: Int,
        metadata: [String: String] = [:]
    ) {
        self.observationID = observationID
        self.tick = tick
        self.accepted = accepted
        self.priorParameterSummary = priorParameterSummary
        self.posteriorParameterSummary = posteriorParameterSummary
        self.predictedObservationMean = predictedObservationMean
        self.innovation = innovation
        self.innovationMahalanobisSquared = innovationMahalanobisSquared
        self.observationCovarianceInflation = observationCovarianceInflation
        self.choleskyJitterUsed = choleskyJitterUsed
        self.ensembleSize = ensembleSize
        self.metadata = metadata
    }
}

public struct TissueTwinAssimilationCheckpoint: Sendable, Hashable, Codable {
    public var formatVersion: UInt32
    public var parameters: [TissueTwinParameterDefinition]
    public var configuration: TissueTwinAssimilationConfiguration
    public var members: [TissueTwinEnsembleMember]
    public var lastTick: UInt64?
    public var randomState: UInt64
    public var randomSpareNormal: Double?

    public init(
        formatVersion: UInt32 = 1,
        parameters: [TissueTwinParameterDefinition],
        configuration: TissueTwinAssimilationConfiguration,
        members: [TissueTwinEnsembleMember],
        lastTick: UInt64?,
        randomState: UInt64,
        randomSpareNormal: Double?
    ) {
        self.formatVersion = formatVersion
        self.parameters = parameters
        self.configuration = configuration
        self.members = members
        self.lastTick = lastTick
        self.randomState = randomState
        self.randomSpareNormal = randomSpareNormal
    }
}

public typealias TissueTwinForwardModel = @Sendable (
    _ memberID: UInt64,
    _ physicalParameters: [String: Double],
    _ priorOpaqueState: Data?,
    _ observation: TissueTwinObservationBatch
) async throws -> TissueTwinPrediction

public actor SequentialTissueTwinAssimilator {
    public let parameters: [TissueTwinParameterDefinition]
    public let configuration: TissueTwinAssimilationConfiguration
    private let forwardModel: TissueTwinForwardModel
    private var members: [TissueTwinEnsembleMember]
    private var random: TissueTwinSplitMix64
    private var lastTick: UInt64?

    public init(
        parameters sourceParameters: [TissueTwinParameterDefinition],
        configuration sourceConfiguration: TissueTwinAssimilationConfiguration,
        initialOpaqueState: Data? = nil,
        forwardModel: @escaping TissueTwinForwardModel
    ) throws {
        guard !sourceParameters.isEmpty,
              Set(sourceParameters.map(\.name)).count == sourceParameters.count else {
            throw TissueTwinAssimilationError.invalidParameters
        }
        let parameters = try sourceParameters.map { try $0.validated() }
        let configuration = try sourceConfiguration.validated(
            parameters: parameters
        )
        self.parameters = parameters
        self.configuration = configuration
        self.forwardModel = forwardModel
        var generator = TissueTwinSplitMix64(seed: configuration.seed)
        members = try Self.makePriorMembers(
            parameters: parameters,
            count: configuration.ensembleSize,
            initialOpaqueState: initialOpaqueState,
            random: &generator
        )
        random = generator
        lastTick = nil
    }

    public init(
        checkpoint: TissueTwinAssimilationCheckpoint,
        forwardModel: @escaping TissueTwinForwardModel
    ) throws {
        guard checkpoint.formatVersion == 1,
              !checkpoint.parameters.isEmpty,
              checkpoint.members.count == checkpoint.configuration.ensembleSize else {
            throw TissueTwinAssimilationError.invalidCheckpoint
        }
        let parameters = try checkpoint.parameters.map { try $0.validated() }
        let configuration = try checkpoint.configuration.validated(
            parameters: parameters
        )
        try Self.validateMembers(
            checkpoint.members,
            parameterCount: parameters.count
        )
        self.parameters = parameters
        self.configuration = configuration
        self.forwardModel = forwardModel
        members = checkpoint.members.sorted { $0.id < $1.id }
        random = TissueTwinSplitMix64(
            state: checkpoint.randomState,
            spareNormal: checkpoint.randomSpareNormal
        )
        lastTick = checkpoint.lastTick
    }

    public func assimilate(
        _ sourceObservation: TissueTwinObservationBatch
    ) async throws -> TissueTwinAssimilationReport {
        let observation = try sourceObservation.validated()
        if let lastTick, observation.tick <= lastTick {
            throw TissueTwinAssimilationError.nonMonotonicObservation
        }

        var forecastMembers = members
        for memberIndex in forecastMembers.indices {
            for parameterIndex in parameters.indices {
                let sigma = parameters[parameterIndex]
                    .processNoiseStandardDeviationLatent
                if sigma > 0 {
                    forecastMembers[memberIndex]
                        .latentParameters[parameterIndex]
                        += sigma * random.standardNormal()
                }
            }
        }
        let priorSummary = try Self.summarize(
            members: forecastMembers,
            parameters: parameters
        )
        let predictions = try await forecast(
            members: forecastMembers,
            observation: observation
        )
        let observationNames = observation.names
        let observationCount = observationNames.count
        let parameterCount = parameters.count
        let ensembleCount = forecastMembers.count
        let divisor = Double(ensembleCount - 1)

        var x = forecastMembers.map(\.latentParameters)
        let y = predictions.map { prediction in
            observationNames.map { prediction.observables[$0]! }
        }
        let xMean = TissueTwinLinearAlgebra.columnMean(x)
        let yMean = TissueTwinLinearAlgebra.columnMean(y)
        let xAnomalies = x.map { TissueTwinLinearAlgebra.subtract($0, xMean) }
        let yAnomalies = y.map { TissueTwinLinearAlgebra.subtract($0, yMean) }

        var crossCovariance = Array(
            repeating: 0.0,
            count: parameterCount * observationCount
        )
        var predictedCovariance = Array(
            repeating: 0.0,
            count: observationCount * observationCount
        )
        for memberIndex in 0..<ensembleCount {
            for parameterIndex in 0..<parameterCount {
                for observationIndex in 0..<observationCount {
                    crossCovariance[
                        parameterIndex * observationCount + observationIndex
                    ] += xAnomalies[memberIndex][parameterIndex]
                        * yAnomalies[memberIndex][observationIndex]
                        / divisor
                }
            }
            for row in 0..<observationCount {
                for column in 0..<observationCount {
                    predictedCovariance[row * observationCount + column]
                        += yAnomalies[memberIndex][row]
                            * yAnomalies[memberIndex][column]
                            / divisor
                }
            }
        }
        applyLocalization(
            to: &crossCovariance,
            observationNames: observationNames
        )

        let innovation = TissueTwinLinearAlgebra.subtract(
            observation.values,
            yMean
        )
        var covarianceInflation = 1.0
        var innovationCovariance = TissueTwinLinearAlgebra.add(
            predictedCovariance,
            observation.covarianceRowMajor,
            observationScale: covarianceInflation
        )
        var factorization = try TissueTwinLinearAlgebra.cholesky(
            innovationCovariance,
            dimension: observationCount,
            baseJitter: configuration.covarianceJitter,
            maximumAttempts: configuration.maximumCholeskyAttempts
        )
        var mahalanobis = try TissueTwinLinearAlgebra.quadraticFormInverse(
            vector: innovation,
            cholesky: factorization.lower,
            dimension: observationCount
        )

        if mahalanobis > configuration.innovationMahalanobisLimit {
            switch configuration.outlierPolicy {
            case .reject:
                for index in forecastMembers.indices {
                    forecastMembers[index].opaqueState
                        = predictions[index].nextOpaqueState
                }
                members = forecastMembers
                lastTick = observation.tick
                return TissueTwinAssimilationReport(
                    observationID: observation.id,
                    tick: observation.tick,
                    accepted: false,
                    priorParameterSummary: priorSummary,
                    posteriorParameterSummary: priorSummary,
                    predictedObservationMean: Dictionary(
                        uniqueKeysWithValues: zip(observationNames, yMean)
                    ),
                    innovation: Dictionary(
                        uniqueKeysWithValues: zip(observationNames, innovation)
                    ),
                    innovationMahalanobisSquared: mahalanobis,
                    observationCovarianceInflation: covarianceInflation,
                    choleskyJitterUsed: factorization.jitter,
                    ensembleSize: ensembleCount,
                    metadata: ["outlier_policy": "reject"]
                )
            case .inflateObservationCovariance(let maximumFactor):
                covarianceInflation = min(
                    max(
                        mahalanobis
                            / configuration.innovationMahalanobisLimit,
                        1
                    ),
                    maximumFactor
                )
                innovationCovariance = TissueTwinLinearAlgebra.add(
                    predictedCovariance,
                    observation.covarianceRowMajor,
                    observationScale: covarianceInflation
                )
                factorization = try TissueTwinLinearAlgebra.cholesky(
                    innovationCovariance,
                    dimension: observationCount,
                    baseJitter: configuration.covarianceJitter,
                    maximumAttempts: configuration.maximumCholeskyAttempts
                )
                mahalanobis = try TissueTwinLinearAlgebra.quadraticFormInverse(
                    vector: innovation,
                    cholesky: factorization.lower,
                    dimension: observationCount
                )
            }
        }

        let gain = try TissueTwinLinearAlgebra.rightSolveSPD(
            rows: crossCovariance,
            rowCount: parameterCount,
            dimension: observationCount,
            cholesky: factorization.lower
        )
        let observationNoiseCovariance = observation.covarianceRowMajor.map {
            $0 * covarianceInflation
        }
        let observationNoiseFactor = try TissueTwinLinearAlgebra.cholesky(
            observationNoiseCovariance,
            dimension: observationCount,
            baseJitter: configuration.covarianceJitter,
            maximumAttempts: configuration.maximumCholeskyAttempts
        ).lower

        for memberIndex in 0..<ensembleCount {
            let noise = TissueTwinLinearAlgebra.multivariateNormal(
                cholesky: observationNoiseFactor,
                dimension: observationCount,
                scale: configuration.observationPerturbationScale,
                random: &random
            )
            let perturbedObservation = zip(observation.values, noise).map(+)
            let memberInnovation = TissueTwinLinearAlgebra.subtract(
                perturbedObservation,
                y[memberIndex]
            )
            for parameterIndex in 0..<parameterCount {
                var correction = 0.0
                for observationIndex in 0..<observationCount {
                    correction += gain[
                        parameterIndex * observationCount + observationIndex
                    ] * memberInnovation[observationIndex]
                }
                x[memberIndex][parameterIndex] += correction
            }
        }

        let updatedMean = TissueTwinLinearAlgebra.columnMean(x)
        for memberIndex in x.indices {
            for parameterIndex in x[memberIndex].indices {
                x[memberIndex][parameterIndex] = updatedMean[parameterIndex]
                    + configuration.parameterInflation
                        * (x[memberIndex][parameterIndex]
                            - updatedMean[parameterIndex])
                let physical = try parameters[parameterIndex].decode(
                    x[memberIndex][parameterIndex]
                )
                x[memberIndex][parameterIndex] = try parameters[parameterIndex]
                    .encode(physical)
            }
            forecastMembers[memberIndex].latentParameters = x[memberIndex]
            forecastMembers[memberIndex].opaqueState
                = predictions[memberIndex].nextOpaqueState
        }
        try Self.validateMembers(
            forecastMembers,
            parameterCount: parameterCount
        )
        members = forecastMembers
        lastTick = observation.tick
        let posteriorSummary = try Self.summarize(
            members: members,
            parameters: parameters
        )
        return TissueTwinAssimilationReport(
            observationID: observation.id,
            tick: observation.tick,
            accepted: true,
            priorParameterSummary: priorSummary,
            posteriorParameterSummary: posteriorSummary,
            predictedObservationMean: Dictionary(
                uniqueKeysWithValues: zip(observationNames, yMean)
            ),
            innovation: Dictionary(
                uniqueKeysWithValues: zip(observationNames, innovation)
            ),
            innovationMahalanobisSquared: mahalanobis,
            observationCovarianceInflation: covarianceInflation,
            choleskyJitterUsed: factorization.jitter,
            ensembleSize: ensembleCount,
            metadata: ["outlier_policy": "assimilated"]
        )
    }

    public func physicalEnsemble() throws -> [[String: Double]] {
        try members.map { try Self.physicalParameters(
            member: $0,
            parameters: parameters
        ) }
    }

    public func ensembleMembers() -> [TissueTwinEnsembleMember] {
        members
    }

    public func checkpoint() -> TissueTwinAssimilationCheckpoint {
        TissueTwinAssimilationCheckpoint(
            parameters: parameters,
            configuration: configuration,
            members: members,
            lastTick: lastTick,
            randomState: random.state,
            randomSpareNormal: random.spareNormal
        )
    }

    private func forecast(
        members: [TissueTwinEnsembleMember],
        observation: TissueTwinObservationBatch
    ) async throws -> [TissueTwinPrediction] {
        let parameters = self.parameters
        let model = self.forwardModel
        let requiredNames = Set(observation.names)
        let concurrency = configuration.maximumConcurrentForecasts
        var results: [(Int, Result<TissueTwinPrediction, Error>)] = []
        results.reserveCapacity(members.count)
        var cursor = 0

        while cursor < members.count {
            let upper = min(cursor + concurrency, members.count)
            let indexedBatch = Array(members[cursor..<upper].enumerated()).map {
                (cursor + $0.offset, $0.element)
            }
            let batchResults = await withTaskGroup(
                of: (Int, Result<TissueTwinPrediction, Error>).self
            ) { group in
                for (index, member) in indexedBatch {
                    group.addTask {
                        do {
                            let physical = try Self.physicalParameters(
                                member: member,
                                parameters: parameters
                            )
                            let prediction = try await model(
                                member.id,
                                physical,
                                member.opaqueState,
                                observation
                            ).validated(requiredNames: requiredNames)
                            return (index, .success(prediction))
                        } catch {
                            return (index, .failure(error))
                        }
                    }
                }
                var values: [(Int, Result<TissueTwinPrediction, Error>)] = []
                for await value in group { values.append(value) }
                return values
            }
            results.append(contentsOf: batchResults)
            cursor = upper
        }
        results.sort { $0.0 < $1.0 }
        var predictions: [TissueTwinPrediction] = []
        predictions.reserveCapacity(results.count)
        var failures: [UInt64: String] = [:]
        for (index, result) in results {
            switch result {
            case .success(let prediction):
                predictions.append(prediction)
            case .failure(let error):
                failures[members[index].id] = String(describing: error)
            }
        }
        guard failures.isEmpty else {
            throw TissueTwinAssimilationError.forwardModelFailures(failures)
        }
        return predictions
    }

    private func applyLocalization(
        to covariance: inout [Double],
        observationNames: [String]
    ) {
        let observationCount = observationNames.count
        for parameterIndex in parameters.indices {
            let row = configuration
                .localizationByParameterAndObservation[parameters[parameterIndex].name]
            for observationIndex in observationNames.indices {
                let coefficient = row?[observationNames[observationIndex]] ?? 1
                covariance[parameterIndex * observationCount + observationIndex]
                    *= coefficient
            }
        }
    }

    private static func makePriorMembers(
        parameters: [TissueTwinParameterDefinition],
        count: Int,
        initialOpaqueState: Data?,
        random: inout TissueTwinSplitMix64
    ) throws -> [TissueTwinEnsembleMember] {
        var members: [TissueTwinEnsembleMember] = []
        members.reserveCapacity(count)
        for memberIndex in 0..<count {
            var latent: [Double] = []
            latent.reserveCapacity(parameters.count)
            for parameter in parameters {
                let physical = min(max(
                    parameter.priorMean
                        + parameter.priorStandardDeviation
                            * random.standardNormal(),
                    parameter.lowerBound
                ), parameter.upperBound)
                latent.append(try parameter.encode(physical))
            }
            members.append(TissueTwinEnsembleMember(
                id: UInt64(memberIndex + 1),
                latentParameters: latent,
                opaqueState: initialOpaqueState
            ))
        }
        return members
    }

    private static func physicalParameters(
        member: TissueTwinEnsembleMember,
        parameters: [TissueTwinParameterDefinition]
    ) throws -> [String: Double] {
        guard member.latentParameters.count == parameters.count else {
            throw TissueTwinAssimilationError.invalidMember(member.id)
        }
        var values: [String: Double] = [:]
        values.reserveCapacity(parameters.count)
        for index in parameters.indices {
            values[parameters[index].name] = try parameters[index].decode(
                member.latentParameters[index]
            )
        }
        return values
    }

    private static func summarize(
        members: [TissueTwinEnsembleMember],
        parameters: [TissueTwinParameterDefinition]
    ) throws -> [TissueTwinParameterSummary] {
        let physical = try members.map {
            try physicalParameters(member: $0, parameters: parameters)
        }
        return parameters.map { parameter in
            let values = physical.compactMap { $0[parameter.name] }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.count > 1
                ? values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                    / Double(values.count - 1)
                : 0
            return TissueTwinParameterSummary(
                name: parameter.name,
                mean: mean,
                standardDeviation: sqrt(max(variance, 0)),
                minimum: values.min() ?? mean,
                maximum: values.max() ?? mean
            )
        }
    }

    private static func validateMembers(
        _ members: [TissueTwinEnsembleMember],
        parameterCount: Int
    ) throws {
        guard !members.isEmpty,
              Set(members.map(\.id)).count == members.count else {
            throw TissueTwinAssimilationError.invalidMembers
        }
        for member in members {
            guard member.latentParameters.count == parameterCount,
                  member.latentParameters.allSatisfy(\.isFinite) else {
                throw TissueTwinAssimilationError.invalidMember(member.id)
            }
        }
    }
}

private enum TissueTwinLinearAlgebra {
    struct CholeskyResult {
        var lower: [Double]
        var jitter: Double
    }

    static func columnMean(_ matrix: [[Double]]) -> [Double] {
        guard let first = matrix.first else { return [] }
        var mean = Array(repeating: 0.0, count: first.count)
        for row in matrix {
            for column in mean.indices { mean[column] += row[column] }
        }
        let divisor = Double(matrix.count)
        for column in mean.indices { mean[column] /= divisor }
        return mean
    }

    static func subtract(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        zip(lhs, rhs).map(-)
    }

    static func add(
        _ predicted: [Double],
        _ observation: [Double],
        observationScale: Double
    ) -> [Double] {
        zip(predicted, observation).map { $0 + observationScale * $1 }
    }

    static func cholesky(
        _ matrix: [Double],
        dimension: Int,
        baseJitter: Double,
        maximumAttempts: Int
    ) throws -> CholeskyResult {
        guard dimension > 0,
              matrix.count == dimension * dimension else {
            throw TissueTwinAssimilationError.matrixDimension
        }
        var jitter = 0.0
        for attempt in 0..<maximumAttempts {
            if attempt == 0 {
                jitter = 0
            } else {
                jitter = baseJitter * pow(10, Double(attempt - 1))
            }
            var lower = Array(repeating: 0.0, count: matrix.count)
            var succeeded = true
            for row in 0..<dimension {
                for column in 0...row {
                    var sum = matrix[row * dimension + column]
                    if row == column { sum += jitter }
                    for inner in 0..<column {
                        sum -= lower[row * dimension + inner]
                            * lower[column * dimension + inner]
                    }
                    if row == column {
                        if !sum.isFinite || sum <= 0 {
                            succeeded = false
                            break
                        }
                        lower[row * dimension + column] = sqrt(sum)
                    } else {
                        let diagonal = lower[column * dimension + column]
                        if diagonal <= 0 || !diagonal.isFinite {
                            succeeded = false
                            break
                        }
                        lower[row * dimension + column] = sum / diagonal
                    }
                }
                if !succeeded { break }
            }
            if succeeded { return CholeskyResult(lower: lower, jitter: jitter) }
        }
        throw TissueTwinAssimilationError.covarianceNotPositiveDefinite
    }

    static func solveSPD(
        vector: [Double],
        cholesky lower: [Double],
        dimension: Int
    ) throws -> [Double] {
        guard vector.count == dimension,
              lower.count == dimension * dimension else {
            throw TissueTwinAssimilationError.matrixDimension
        }
        var intermediate = Array(repeating: 0.0, count: dimension)
        for row in 0..<dimension {
            var value = vector[row]
            for column in 0..<row {
                value -= lower[row * dimension + column] * intermediate[column]
            }
            let diagonal = lower[row * dimension + row]
            guard diagonal > 0 else {
                throw TissueTwinAssimilationError.covarianceNotPositiveDefinite
            }
            intermediate[row] = value / diagonal
        }
        var solution = Array(repeating: 0.0, count: dimension)
        for row in stride(from: dimension - 1, through: 0, by: -1) {
            var value = intermediate[row]
            for column in (row + 1)..<dimension {
                value -= lower[column * dimension + row] * solution[column]
            }
            solution[row] = value / lower[row * dimension + row]
        }
        return solution
    }

    static func rightSolveSPD(
        rows: [Double],
        rowCount: Int,
        dimension: Int,
        cholesky: [Double]
    ) throws -> [Double] {
        guard rows.count == rowCount * dimension else {
            throw TissueTwinAssimilationError.matrixDimension
        }
        var result = Array(repeating: 0.0, count: rows.count)
        for row in 0..<rowCount {
            let start = row * dimension
            let solution = try solveSPD(
                vector: Array(rows[start..<(start + dimension)]),
                cholesky: cholesky,
                dimension: dimension
            )
            result.replaceSubrange(start..<(start + dimension), with: solution)
        }
        return result
    }

    static func quadraticFormInverse(
        vector: [Double],
        cholesky: [Double],
        dimension: Int
    ) throws -> Double {
        let solution = try solveSPD(
            vector: vector,
            cholesky: cholesky,
            dimension: dimension
        )
        let value = zip(vector, solution).reduce(0) { $0 + $1.0 * $1.1 }
        guard value.isFinite else {
            throw TissueTwinAssimilationError.nonFiniteLinearAlgebra
        }
        return max(value, 0)
    }

    static func multivariateNormal(
        cholesky: [Double],
        dimension: Int,
        scale: Double,
        random: inout TissueTwinSplitMix64
    ) -> [Double] {
        guard scale > 0 else { return Array(repeating: 0, count: dimension) }
        let standard = (0..<dimension).map { _ in random.standardNormal() }
        var output = Array(repeating: 0.0, count: dimension)
        for row in 0..<dimension {
            for column in 0...row {
                output[row] += cholesky[row * dimension + column]
                    * standard[column]
                    * scale
            }
        }
        return output
    }
}

private struct TissueTwinSplitMix64: Sendable {
    var state: UInt64
    var spareNormal: Double?

    init(seed: UInt64) {
        state = seed
        spareNormal = nil
    }

    init(state: UInt64, spareNormal: Double?) {
        self.state = state
        self.spareNormal = spareNormal
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    mutating func standardNormal() -> Double {
        if let spareNormal {
            self.spareNormal = nil
            return spareNormal
        }
        let first = max(unit(), Double.leastNonzeroMagnitude)
        let second = unit()
        let radius = sqrt(-2 * log(first))
        let angle = 2 * Double.pi * second
        spareNormal = radius * sin(angle)
        return radius * cos(angle)
    }
}

public enum TissueTwinAssimilationError: Error, Sendable, CustomStringConvertible {
    case invalidParameter(String)
    case invalidParameters
    case nonFiniteParameter(String)
    case invalidObservationBatch(UUID)
    case invalidObservationCovariance
    case invalidPrediction
    case invalidConfiguration
    case invalidLocalization
    case invalidCheckpoint
    case invalidMembers
    case invalidMember(UInt64)
    case nonMonotonicObservation
    case forwardModelFailures([UInt64: String])
    case matrixDimension
    case covarianceNotPositiveDefinite
    case nonFiniteLinearAlgebra

    public var description: String {
        switch self {
        case .invalidParameter(let name):
            return "Tissue twin parameter \(name) is invalid"
        case .invalidParameters:
            return "Tissue twin parameter definitions are invalid"
        case .nonFiniteParameter(let name):
            return "Tissue twin parameter \(name) is non-finite"
        case .invalidObservationBatch(let id):
            return "Tissue twin observation batch \(id) is invalid"
        case .invalidObservationCovariance:
            return "Tissue twin observation covariance is invalid"
        case .invalidPrediction:
            return "Tissue twin forecast prediction is invalid"
        case .invalidConfiguration:
            return "Tissue twin assimilation configuration is invalid"
        case .invalidLocalization:
            return "Tissue twin covariance localization is invalid"
        case .invalidCheckpoint:
            return "Tissue twin assimilation checkpoint is invalid"
        case .invalidMembers:
            return "Tissue twin ensemble members are invalid"
        case .invalidMember(let id):
            return "Tissue twin ensemble member \(id) is invalid"
        case .nonMonotonicObservation:
            return "Tissue twin observation time is not strictly increasing"
        case .forwardModelFailures(let failures):
            return "Tissue twin forward-model failures: \(failures)"
        case .matrixDimension:
            return "Tissue twin matrix dimensions are inconsistent"
        case .covarianceNotPositiveDefinite:
            return "Tissue twin covariance could not be Cholesky factored"
        case .nonFiniteLinearAlgebra:
            return "Tissue twin linear algebra produced a non-finite result"
        }
    }
}
