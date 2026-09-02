import Foundation

public enum CalibrationParameterTransform: String, Sendable, Hashable, Codable {
    case linear
    case logarithmic
    case logistic

    public func encode(value: Double, bounds: ClosedRange<Double>) throws -> Double {
        guard bounds.contains(value), bounds.lowerBound < bounds.upperBound else { throw CalibrationError.parameterOutOfBounds(value) }
        switch self {
        case .linear: return (value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        case .logarithmic:
            guard bounds.lowerBound > 0, value > 0 else { throw CalibrationError.invalidLogarithmicBounds }
            return (log(value) - log(bounds.lowerBound)) / (log(bounds.upperBound) - log(bounds.lowerBound))
        case .logistic:
            let p = min(max((value - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound), 1e-12), 1 - 1e-12)
            return log(p / (1 - p))
        }
    }

    public func decode(value: Double, bounds: ClosedRange<Double>) throws -> Double {
        guard bounds.lowerBound < bounds.upperBound else { throw CalibrationError.invalidBounds }
        switch self {
        case .linear: return bounds.lowerBound + min(max(value, 0), 1) * (bounds.upperBound - bounds.lowerBound)
        case .logarithmic:
            guard bounds.lowerBound > 0 else { throw CalibrationError.invalidLogarithmicBounds }
            let p = min(max(value, 0), 1)
            return exp(log(bounds.lowerBound) + p * (log(bounds.upperBound) - log(bounds.lowerBound)))
        case .logistic:
            let p = 1 / (1 + exp(-value))
            return bounds.lowerBound + p * (bounds.upperBound - bounds.lowerBound)
        }
    }
}

public struct CalibrationParameter: Sendable, Hashable, Codable {
    public var path: String
    public var value: Double
    public var bounds: ClosedRange<Double>
    public var transform: CalibrationParameterTransform
    public var priorMean: Double?
    public var priorStandardDeviation: Double?
    public var group: String?

    public init(
        path: String,
        value: Double,
        bounds: ClosedRange<Double>,
        transform: CalibrationParameterTransform = .linear,
        priorMean: Double? = nil,
        priorStandardDeviation: Double? = nil,
        group: String? = nil
    ) {
        self.path = path
        self.value = value
        self.bounds = bounds
        self.transform = transform
        self.priorMean = priorMean
        self.priorStandardDeviation = priorStandardDeviation
        self.group = group
    }
}

public struct CalibrationParameterSet: Sendable, Hashable, Codable {
    public var parameters: [CalibrationParameter]

    public init(parameters: [CalibrationParameter]) { self.parameters = parameters }

    public func validated() throws -> Self {
        guard !parameters.isEmpty else { throw CalibrationError.noParameters }
        guard Set(parameters.map(\.path)).count == parameters.count else { throw CalibrationError.duplicateParameter }
        for parameter in parameters {
            guard parameter.value.isFinite, parameter.bounds.lowerBound.isFinite, parameter.bounds.upperBound.isFinite else { throw CalibrationError.nonFiniteParameter(parameter.path) }
            guard parameter.bounds.lowerBound < parameter.bounds.upperBound else { throw CalibrationError.invalidBounds }
            guard parameter.bounds.contains(parameter.value) else { throw CalibrationError.parameterOutOfBounds(parameter.value) }
            if let sd = parameter.priorStandardDeviation, sd <= 0 { throw CalibrationError.invalidPrior(parameter.path) }
        }
        return self
    }

    public func encodedVector() throws -> [Double] {
        try validated().parameters.map { try $0.transform.encode(value: $0.value, bounds: $0.bounds) }
    }

    public func replacingEncodedVector(_ vector: [Double]) throws -> Self {
        guard vector.count == parameters.count else { throw CalibrationError.dimensionMismatch }
        var copy = self
        for index in parameters.indices {
            copy.parameters[index].value = try parameters[index].transform.decode(value: vector[index], bounds: parameters[index].bounds)
        }
        return copy
    }

    public subscript(path: String) -> Double? { parameters.first(where: { $0.path == path })?.value }
}

public struct CalibrationFeature: Sendable, Hashable, Codable {
    public var name: String
    public var value: Double
    public var uncertainty: Double
    public var weight: Double

    public init(name: String, value: Double, uncertainty: Double = 1, weight: Double = 1) {
        self.name = name
        self.value = value
        self.uncertainty = uncertainty
        self.weight = weight
    }
}

public struct CalibrationFeatureVector: Sendable, Hashable, Codable {
    public var features: [CalibrationFeature]
    public init(features: [CalibrationFeature]) { self.features = features }

    public func validated() throws -> Self {
        guard !features.isEmpty else { throw CalibrationError.noFeatures }
        guard Set(features.map(\.name)).count == features.count else { throw CalibrationError.duplicateFeature }
        for feature in features {
            guard feature.value.isFinite, feature.uncertainty.isFinite, feature.uncertainty > 0, feature.weight.isFinite, feature.weight >= 0 else {
                throw CalibrationError.invalidFeature(feature.name)
            }
        }
        return self
    }
}

public struct CalibrationObjective: Sendable, Hashable, Codable {
    public var target: CalibrationFeatureVector
    public var robustScale: Double
    public var priorWeight: Double

    public init(target: CalibrationFeatureVector, robustScale: Double = 2, priorWeight: Double = 0.01) {
        self.target = target
        self.robustScale = robustScale
        self.priorWeight = priorWeight
    }

    public func loss(predicted: CalibrationFeatureVector, parameters: CalibrationParameterSet) throws -> Double {
        let target = try target.validated()
        let predicted = try predicted.validated()
        let predictedByName = Dictionary(uniqueKeysWithValues: predicted.features.map { ($0.name, $0) })
        var total = 0.0
        var totalWeight = 0.0
        for feature in target.features {
            guard let candidate = predictedByName[feature.name] else { throw CalibrationError.missingFeature(feature.name) }
            let sigma = max(hypot(feature.uncertainty, candidate.uncertainty), 1e-12)
            let residual = (candidate.value - feature.value) / sigma
            let robust = robustScale * robustScale * (sqrt(1 + (residual / robustScale) * (residual / robustScale)) - 1)
            total += feature.weight * robust
            totalWeight += feature.weight
        }
        if priorWeight > 0 {
            for parameter in parameters.parameters {
                if let mean = parameter.priorMean, let sd = parameter.priorStandardDeviation {
                    let z = (parameter.value - mean) / sd
                    total += priorWeight * 0.5 * z * z
                    totalWeight += priorWeight
                }
            }
        }
        return total / max(totalWeight, 1e-12)
    }
}

public protocol TissueCalibrationEvaluator: Sendable {
    func evaluate(parameters: CalibrationParameterSet, seed: UInt64) async throws -> CalibrationFeatureVector
}

public struct CalibrationCandidate: Sendable, Hashable, Codable {
    public var generation: Int
    public var member: Int
    public var parameters: CalibrationParameterSet
    public var loss: Double
    public var seed: UInt64

    public init(generation: Int, member: Int, parameters: CalibrationParameterSet, loss: Double, seed: UInt64) {
        self.generation = generation
        self.member = member
        self.parameters = parameters
        self.loss = loss
        self.seed = seed
    }
}

public struct CalibrationConfiguration: Sendable, Hashable, Codable {
    public var populationSize: Int
    public var eliteFraction: Double
    public var maximumGenerations: Int
    public var initialStepSize: Double
    public var minimumStepSize: Double
    public var targetLoss: Double
    public var seedsPerCandidate: Int
    public var stagnationGenerations: Int

    public init(
        populationSize: Int = 32,
        eliteFraction: Double = 0.25,
        maximumGenerations: Int = 100,
        initialStepSize: Double = 0.2,
        minimumStepSize: Double = 1e-4,
        targetLoss: Double = 1e-4,
        seedsPerCandidate: Int = 3,
        stagnationGenerations: Int = 12
    ) {
        self.populationSize = populationSize
        self.eliteFraction = eliteFraction
        self.maximumGenerations = maximumGenerations
        self.initialStepSize = initialStepSize
        self.minimumStepSize = minimumStepSize
        self.targetLoss = targetLoss
        self.seedsPerCandidate = seedsPerCandidate
        self.stagnationGenerations = stagnationGenerations
    }

    public func validated() throws -> Self {
        guard populationSize >= 4, populationSize <= 4_096 else { throw CalibrationError.invalidConfiguration }
        guard eliteFraction > 0, eliteFraction <= 0.5 else { throw CalibrationError.invalidConfiguration }
        guard maximumGenerations > 0, initialStepSize > 0, minimumStepSize > 0, seedsPerCandidate > 0 else { throw CalibrationError.invalidConfiguration }
        return self
    }
}

public struct DigitalTwinCalibrationResult: Sendable, Codable {
    public var best: CalibrationCandidate
    public var history: [CalibrationCandidate]
    public var generations: Int
    public var converged: Bool
    public var finalStepSize: Double
    public var startedAt: Date
    public var completedAt: Date

    public init(best: CalibrationCandidate, history: [CalibrationCandidate], generations: Int, converged: Bool, finalStepSize: Double, startedAt: Date, completedAt: Date) {
        self.best = best
        self.history = history
        self.generations = generations
        self.converged = converged
        self.finalStepSize = finalStepSize
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Diagonal natural-evolution strategy with mirrored sampling, rank-based recombination and
/// deterministic common random numbers. It is robust to stochastic tissue simulations and can run
/// candidate evaluations concurrently without changing the generated population.
public actor DigitalTwinCalibrator {
    private let evaluator: any TissueCalibrationEvaluator
    private let objective: CalibrationObjective
    private let configuration: CalibrationConfiguration

    public init(evaluator: any TissueCalibrationEvaluator, objective: CalibrationObjective, configuration: CalibrationConfiguration = CalibrationConfiguration()) throws {
        self.evaluator = evaluator
        self.objective = objective
        self.configuration = try configuration.validated()
    }

    public func calibrate(initial: CalibrationParameterSet, randomSeed: UInt64) async throws -> DigitalTwinCalibrationResult {
        let started = Date()
        let initial = try initial.validated()
        var mean = try initial.encodedVector()
        var variance = Array(repeating: 1.0, count: mean.count)
        var step = configuration.initialStepSize
        var history: [CalibrationCandidate] = []
        var best: CalibrationCandidate?
        var bestGeneration = 0
        let eliteCount = max(Int(Double(configuration.populationSize) * configuration.eliteFraction), 2)
        let mirroredCount = (configuration.populationSize + 1) / 2

        for generation in 0..<configuration.maximumGenerations {
            var generator = CalibrationRandom(seed: randomSeed ^ UInt64(generation) &* 0x9E37_79B9_7F4A_7C15)
            var vectors: [[Double]] = []
            vectors.reserveCapacity(configuration.populationSize)
            for _ in 0..<mirroredCount {
                let direction = variance.map { sqrt(max($0, 1e-12)) * generator.gaussian() }
                vectors.append(zip(mean, direction).map { clampEncoded($0 + step * $1) })
                if vectors.count < configuration.populationSize {
                    vectors.append(zip(mean, direction).map { clampEncoded($0 - step * $1) })
                }
            }

            let evaluated = try await withThrowingTaskGroup(of: CalibrationCandidate.self) { group in
                for (member, vector) in vectors.enumerated() {
                    let parameters = try initial.replacingEncodedVector(vector)
                    group.addTask { [evaluator, objective, configuration] in
                        var loss = 0.0
                        for replicate in 0..<configuration.seedsPerCandidate {
                            let seed = randomSeed ^ UInt64(generation) << 40 ^ UInt64(member) << 16 ^ UInt64(replicate)
                            let prediction = try await evaluator.evaluate(parameters: parameters, seed: seed)
                            loss += try objective.loss(predicted: prediction, parameters: parameters)
                        }
                        loss /= Double(configuration.seedsPerCandidate)
                        return CalibrationCandidate(generation: generation, member: member, parameters: parameters, loss: loss, seed: randomSeed)
                    }
                }
                var values: [CalibrationCandidate] = []
                for try await candidate in group { values.append(candidate) }
                return values.sorted { ($0.loss, $0.member) < ($1.loss, $1.member) }
            }

            guard let generationBest = evaluated.first else { throw CalibrationError.noCandidates }
            history.append(generationBest)
            if best == nil || generationBest.loss < best!.loss {
                best = generationBest
                bestGeneration = generation
            }
            if generationBest.loss <= configuration.targetLoss {
                return DigitalTwinCalibrationResult(best: generationBest, history: history, generations: generation + 1, converged: true, finalStepSize: step, startedAt: started, completedAt: Date())
            }

            let elites = Array(evaluated.prefix(eliteCount))
            let eliteVectors = try elites.map { try $0.parameters.encodedVector() }
            let weights = rankWeights(eliteCount)
            let oldMean = mean
            for dimension in mean.indices {
                mean[dimension] = zip(eliteVectors, weights).reduce(0) { $0 + $1.0[dimension] * $1.1 }
                let weightedVariance = zip(eliteVectors, weights).reduce(0) { partial, pair in
                    let delta = pair.0[dimension] - mean[dimension]
                    return partial + pair.1 * delta * delta
                }
                variance[dimension] = 0.8 * variance[dimension] + 0.2 * max(weightedVariance / max(step * step, 1e-12), 1e-6)
            }
            let movement = sqrt(zip(mean, oldMean).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(mean.count))
            if generation - bestGeneration >= configuration.stagnationGenerations {
                step = min(step * 1.5, 0.5)
                bestGeneration = generation
            } else if movement < 0.05 * step {
                step = max(step * 0.82, configuration.minimumStepSize)
            } else {
                step = max(step * 0.97, configuration.minimumStepSize)
            }
        }
        guard let best else { throw CalibrationError.noCandidates }
        return DigitalTwinCalibrationResult(best: best, history: history, generations: configuration.maximumGenerations, converged: false, finalStepSize: step, startedAt: started, completedAt: Date())
    }

    private func rankWeights(_ count: Int) -> [Double] {
        let raw = (0..<count).map { max(log(Double(count) + 0.5) - log(Double($0 + 1)), 0) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / max(sum, 1e-12) }
    }

    private func clampEncoded(_ value: Double) -> Double { min(max(value, -8), 8) }
}

public enum MEACalibrationFeatureExtractor {
    public static func extract(recording: NeuralRecording, frequencyBands: [ClosedRange<Double>] = [1...4, 4...8, 8...13, 13...30, 30...80, 80...300]) -> CalibrationFeatureVector {
        var features: [CalibrationFeature] = []
        let duration = Double(recording.frame.sampleCount) / recording.frame.sampleRateHertz
        for (channel, electrode) in recording.frame.electrodeOrder.enumerated() where channel < recording.frame.samplesByElectrode.count {
            let samples = recording.frame.samplesByElectrode[channel].map(Double.init)
            guard !samples.isEmpty else { continue }
            let mean = samples.reduce(0, +) / Double(samples.count)
            let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(samples.count - 1, 1))
            let prefix = "electrode.\(electrode.rawValue)"
            features.append(CalibrationFeature(name: "\(prefix).mean", value: mean, uncertainty: sqrt(max(variance, 1e-24) / Double(samples.count))))
            features.append(CalibrationFeature(name: "\(prefix).rms", value: sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))))
            let spikeCount = recording.spikes.filter { $0.electrode == electrode }.count
            features.append(CalibrationFeature(name: "\(prefix).spike_rate", value: duration > 0 ? Double(spikeCount) / duration : 0, uncertainty: duration > 0 ? sqrt(Double(max(spikeCount, 1))) / duration : 1))
            for band in frequencyBands {
                features.append(CalibrationFeature(name: "\(prefix).band.\(band.lowerBound)-\(band.upperBound)", value: bandPower(samples: samples, sampleRate: recording.frame.sampleRateHertz, band: band), uncertainty: 1e-12))
            }
        }
        return CalibrationFeatureVector(features: features)
    }

    private static func bandPower(samples: [Double], sampleRate: Double, band: ClosedRange<Double>) -> Double {
        guard samples.count > 1 else { return 0 }
        let count = min(samples.count, 4_096)
        let mean = samples.prefix(count).reduce(0, +) / Double(count)
        var power = 0.0
        let minimumBin = max(Int(ceil(band.lowerBound * Double(count) / sampleRate)), 1)
        let maximumBin = min(Int(floor(band.upperBound * Double(count) / sampleRate)), count / 2)
        guard minimumBin <= maximumBin else { return 0 }
        for bin in minimumBin...maximumBin {
            var real = 0.0
            var imaginary = 0.0
            for index in 0..<count {
                let angle = -2 * Double.pi * Double(bin * index) / Double(count)
                let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(max(count - 1, 1)))
                let value = (samples[index] - mean) * window
                real += value * cos(angle)
                imaginary += value * sin(angle)
            }
            power += (real * real + imaginary * imaginary) / Double(count * count)
        }
        return power
    }
}

private struct CalibrationRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func uniform() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return Double(value >> 11) / 9_007_199_254_740_992
    }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-15)
        let u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

public enum CalibrationError: Error, Sendable, CustomStringConvertible {
    case noParameters
    case duplicateParameter
    case nonFiniteParameter(String)
    case invalidBounds
    case invalidLogarithmicBounds
    case parameterOutOfBounds(Double)
    case invalidPrior(String)
    case dimensionMismatch
    case noFeatures
    case duplicateFeature
    case invalidFeature(String)
    case missingFeature(String)
    case invalidConfiguration
    case noCandidates

    public var description: String {
        switch self {
        case .noParameters: return "Calibration parameter set is empty"
        case .duplicateParameter: return "Calibration parameter paths are not unique"
        case .nonFiniteParameter(let path): return "Calibration parameter \(path) is non-finite"
        case .invalidBounds: return "Calibration bounds are invalid"
        case .invalidLogarithmicBounds: return "Logarithmic calibration requires positive bounds"
        case .parameterOutOfBounds(let value): return "Calibration value \(value) lies outside its bounds"
        case .invalidPrior(let path): return "Calibration prior for \(path) is invalid"
        case .dimensionMismatch: return "Calibration vector dimension mismatch"
        case .noFeatures: return "Calibration feature vector is empty"
        case .duplicateFeature: return "Calibration feature names are not unique"
        case .invalidFeature(let name): return "Calibration feature \(name) is invalid"
        case .missingFeature(let name): return "Predicted calibration output is missing \(name)"
        case .invalidConfiguration: return "Calibration configuration is invalid"
        case .noCandidates: return "Calibration produced no candidates"
        }
    }
}
