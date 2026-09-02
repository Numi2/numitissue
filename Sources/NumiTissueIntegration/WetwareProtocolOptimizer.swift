import Foundation

public enum WetwareParameterScale: String, Sendable, Hashable, Codable {
    case linear
    case logarithmic
}

public struct WetwareProtocolParameter: Sendable, Hashable, Codable {
    public var name: String
    public var lowerBound: Double
    public var upperBound: Double
    public var scale: WetwareParameterScale
    public var quantizationStep: Double?

    public init(
        name: String,
        lowerBound: Double,
        upperBound: Double,
        scale: WetwareParameterScale = .linear,
        quantizationStep: Double? = nil
    ) {
        self.name = name
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.scale = scale
        self.quantizationStep = quantizationStep
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              lowerBound.isFinite,
              upperBound.isFinite,
              upperBound > lowerBound,
              quantizationStep?.isFinite != false,
              quantizationStep.map({ $0 > 0 }) != false else {
            throw WetwareOptimizationError.invalidParameter(name)
        }
        if scale == .logarithmic, lowerBound <= 0 {
            throw WetwareOptimizationError.invalidParameter(name)
        }
        return self
    }

    public func decode(normalized source: Double) -> Double {
        let normalized = min(max(source, 0), 1)
        let raw: Double
        switch scale {
        case .linear:
            raw = lowerBound + normalized * (upperBound - lowerBound)
        case .logarithmic:
            raw = exp(log(lowerBound) + normalized * (log(upperBound) - log(lowerBound)))
        }
        guard let step = quantizationStep else { return raw }
        let quantized = lowerBound + ((raw - lowerBound) / step).rounded() * step
        return min(max(quantized, lowerBound), upperBound)
    }
}

public struct WetwareProtocolParameterSpace: Sendable, Hashable, Codable {
    public var parameters: [WetwareProtocolParameter]

    public init(parameters: [WetwareProtocolParameter]) {
        self.parameters = parameters
    }

    public func validated() throws -> Self {
        guard !parameters.isEmpty,
              Set(parameters.map(\.name)).count == parameters.count else {
            throw WetwareOptimizationError.invalidParameterSpace
        }
        for parameter in parameters { _ = try parameter.validated() }
        return self
    }

    public func decode(_ genome: WetwareProtocolGenome) throws -> [String: Double] {
        guard genome.normalizedValues.count == parameters.count else {
            throw WetwareOptimizationError.genomeDimension
        }
        var values: [String: Double] = [:]
        values.reserveCapacity(parameters.count)
        for index in parameters.indices {
            values[parameters[index].name] = parameters[index].decode(
                normalized: genome.normalizedValues[index]
            )
        }
        return values
    }
}

public struct WetwareProtocolGenome: Sendable, Hashable, Codable {
    public var normalizedValues: [Double]

    public init(normalizedValues: [Double]) {
        self.normalizedValues = normalizedValues
    }

    public func validated(dimension: Int) throws -> Self {
        guard normalizedValues.count == dimension,
              normalizedValues.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw WetwareOptimizationError.invalidGenome
        }
        return self
    }
}

public enum WetwareObjectiveDirection: String, Sendable, Hashable, Codable {
    case minimize
    case maximize
}

public struct WetwareObjective: Sendable, Hashable, Codable {
    public var metric: String
    public var direction: WetwareObjectiveDirection
    public var epsilon: Double

    public init(
        metric: String,
        direction: WetwareObjectiveDirection,
        epsilon: Double = 0
    ) {
        self.metric = metric
        self.direction = direction
        self.epsilon = epsilon
    }

    public func validated() throws -> Self {
        guard !metric.isEmpty,
              epsilon.isFinite,
              epsilon >= 0 else {
            throw WetwareOptimizationError.invalidObjective(metric)
        }
        return self
    }
}

public struct WetwareMetricConstraint: Sendable, Hashable, Codable {
    public var metric: String
    public var minimum: Double?
    public var maximum: Double?
    public var normalizationScale: Double

    public init(
        metric: String,
        minimum: Double? = nil,
        maximum: Double? = nil,
        normalizationScale: Double = 1
    ) {
        self.metric = metric
        self.minimum = minimum
        self.maximum = maximum
        self.normalizationScale = normalizationScale
    }

    public func validated() throws -> Self {
        guard !metric.isEmpty,
              minimum != nil || maximum != nil,
              minimum?.isFinite != false,
              maximum?.isFinite != false,
              normalizationScale.isFinite,
              normalizationScale > 0 else {
            throw WetwareOptimizationError.invalidConstraint(metric)
        }
        if let minimum, let maximum, minimum > maximum {
            throw WetwareOptimizationError.invalidConstraint(metric)
        }
        return self
    }

    public func violation(value: Double) -> Double {
        guard value.isFinite else { return Double.greatestFiniteMagnitude }
        var violation = 0.0
        if let minimum, value < minimum {
            violation += (minimum - value) / normalizationScale
        }
        if let maximum, value > maximum {
            violation += (value - maximum) / normalizationScale
        }
        return max(violation, 0)
    }
}

public struct WetwareProtocolMeasurement: Sendable, Hashable, Codable {
    public var metrics: [String: Double]
    public var trialCount: Int
    public var metadata: [String: String]

    public init(
        metrics: [String: Double],
        trialCount: Int,
        metadata: [String: String] = [:]
    ) {
        self.metrics = metrics
        self.trialCount = trialCount
        self.metadata = metadata
    }

    public func validated(requiredMetrics: Set<String>) throws -> Self {
        guard trialCount > 0,
              requiredMetrics.isSubset(of: Set(metrics.keys)),
              metrics.values.allSatisfy(\.isFinite) else {
            throw WetwareOptimizationError.invalidMeasurement
        }
        return self
    }
}

public struct WetwareProtocolOptimizationCandidate: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable {
        case evaluated
        case unsafe
        case invalid
        case failed
    }

    public var id: UInt64
    public var generation: Int
    public var genome: WetwareProtocolGenome
    public var parameters: [String: Double]
    public var protocolValue: WetwareExperimentProtocol?
    public var safetyReport: WetwareSafetyReport?
    public var measurement: WetwareProtocolMeasurement?
    public var status: Status
    public var totalConstraintViolation: Double
    public var paretoRank: Int
    public var crowdingDistance: Double
    public var errorDescription: String?

    public init(
        id: UInt64,
        generation: Int,
        genome: WetwareProtocolGenome,
        parameters: [String: Double],
        protocolValue: WetwareExperimentProtocol? = nil,
        safetyReport: WetwareSafetyReport? = nil,
        measurement: WetwareProtocolMeasurement? = nil,
        status: Status,
        totalConstraintViolation: Double,
        paretoRank: Int = Int.max,
        crowdingDistance: Double = 0,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.generation = generation
        self.genome = genome
        self.parameters = parameters
        self.protocolValue = protocolValue
        self.safetyReport = safetyReport
        self.measurement = measurement
        self.status = status
        self.totalConstraintViolation = totalConstraintViolation
        self.paretoRank = paretoRank
        self.crowdingDistance = crowdingDistance
        self.errorDescription = errorDescription
    }

    public var isFeasible: Bool {
        status == .evaluated && totalConstraintViolation <= 0
    }
}

public struct WetwareProtocolOptimizationGeneration: Sendable, Hashable, Codable {
    public var index: Int
    public var candidateIDs: [UInt64]
    public var feasibleCount: Int
    public var paretoFrontIDs: [UInt64]

    public init(
        index: Int,
        candidateIDs: [UInt64],
        feasibleCount: Int,
        paretoFrontIDs: [UInt64]
    ) {
        self.index = index
        self.candidateIDs = candidateIDs
        self.feasibleCount = feasibleCount
        self.paretoFrontIDs = paretoFrontIDs
    }
}

public struct WetwareProtocolOptimizationConfiguration: Sendable, Hashable, Codable {
    public var populationSize: Int
    public var generations: Int
    public var offspringPerGeneration: Int
    public var maximumConcurrentEvaluations: Int
    public var crossoverProbability: Double
    public var mutationProbabilityPerParameter: Double
    public var initialMutationStandardDeviation: Double
    public var finalMutationStandardDeviation: Double
    public var tournamentSize: Int
    public var seed: UInt64

    public init(
        populationSize: Int = 64,
        generations: Int = 40,
        offspringPerGeneration: Int = 64,
        maximumConcurrentEvaluations: Int = 8,
        crossoverProbability: Double = 0.9,
        mutationProbabilityPerParameter: Double = 0.15,
        initialMutationStandardDeviation: Double = 0.15,
        finalMutationStandardDeviation: Double = 0.02,
        tournamentSize: Int = 2,
        seed: UInt64
    ) {
        self.populationSize = populationSize
        self.generations = generations
        self.offspringPerGeneration = offspringPerGeneration
        self.maximumConcurrentEvaluations = maximumConcurrentEvaluations
        self.crossoverProbability = crossoverProbability
        self.mutationProbabilityPerParameter = mutationProbabilityPerParameter
        self.initialMutationStandardDeviation = initialMutationStandardDeviation
        self.finalMutationStandardDeviation = finalMutationStandardDeviation
        self.tournamentSize = tournamentSize
        self.seed = seed
    }

    public func validated() throws -> Self {
        guard populationSize >= 4,
              generations >= 1,
              offspringPerGeneration >= 1,
              maximumConcurrentEvaluations >= 1,
              crossoverProbability.isFinite,
              (0...1).contains(crossoverProbability),
              mutationProbabilityPerParameter.isFinite,
              (0...1).contains(mutationProbabilityPerParameter),
              initialMutationStandardDeviation.isFinite,
              initialMutationStandardDeviation >= 0,
              finalMutationStandardDeviation.isFinite,
              finalMutationStandardDeviation >= 0,
              tournamentSize >= 2,
              tournamentSize <= populationSize else {
            throw WetwareOptimizationError.invalidConfiguration
        }
        return self
    }
}

public struct WetwareProtocolOptimizationResult: Sendable, Codable {
    public var parameterSpace: WetwareProtocolParameterSpace
    public var objectives: [WetwareObjective]
    public var constraints: [WetwareMetricConstraint]
    public var configuration: WetwareProtocolOptimizationConfiguration
    public var candidates: [WetwareProtocolOptimizationCandidate]
    public var generations: [WetwareProtocolOptimizationGeneration]
    public var paretoFront: [WetwareProtocolOptimizationCandidate]
    public var startedAt: Date
    public var completedAt: Date

    public init(
        parameterSpace: WetwareProtocolParameterSpace,
        objectives: [WetwareObjective],
        constraints: [WetwareMetricConstraint],
        configuration: WetwareProtocolOptimizationConfiguration,
        candidates: [WetwareProtocolOptimizationCandidate],
        generations: [WetwareProtocolOptimizationGeneration],
        paretoFront: [WetwareProtocolOptimizationCandidate],
        startedAt: Date,
        completedAt: Date
    ) {
        self.parameterSpace = parameterSpace
        self.objectives = objectives
        self.constraints = constraints
        self.configuration = configuration
        self.candidates = candidates
        self.generations = generations
        self.paretoFront = paretoFront
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public typealias WetwareProtocolDecoder = @Sendable (
    _ parameters: [String: Double],
    _ candidateID: UInt64
) throws -> WetwareExperimentProtocol

public typealias WetwareProtocolEvaluator = @Sendable (
    _ protocolValue: WetwareExperimentProtocol,
    _ candidateID: UInt64
) async throws -> WetwareProtocolMeasurement

public actor WetwareProtocolOptimizer {
    public let parameterSpace: WetwareProtocolParameterSpace
    public let objectives: [WetwareObjective]
    public let constraints: [WetwareMetricConstraint]
    public let safetyEnvelope: WetwareStimulationSafetyEnvelope
    public let configuration: WetwareProtocolOptimizationConfiguration
    private let decoder: WetwareProtocolDecoder
    private let evaluator: WetwareProtocolEvaluator

    public init(
        parameterSpace: WetwareProtocolParameterSpace,
        objectives: [WetwareObjective],
        constraints: [WetwareMetricConstraint] = [],
        safetyEnvelope: WetwareStimulationSafetyEnvelope,
        configuration: WetwareProtocolOptimizationConfiguration,
        decoder: @escaping WetwareProtocolDecoder,
        evaluator: @escaping WetwareProtocolEvaluator
    ) throws {
        self.parameterSpace = try parameterSpace.validated()
        guard !objectives.isEmpty,
              Set(objectives.map(\.metric)).count == objectives.count else {
            throw WetwareOptimizationError.invalidObjectives
        }
        self.objectives = try objectives.map { try $0.validated() }
        guard Set(constraints.map(\.metric)).count == constraints.count else {
            throw WetwareOptimizationError.invalidConstraints
        }
        self.constraints = try constraints.map { try $0.validated() }
        self.safetyEnvelope = try safetyEnvelope.validated()
        self.configuration = try configuration.validated()
        self.decoder = decoder
        self.evaluator = evaluator
    }

    public func optimize() async -> WetwareProtocolOptimizationResult {
        let started = Date()
        let requiredMetrics = Set(objectives.map(\.metric) + constraints.map(\.metric))
        var random = WetwareSplitMix64(seed: configuration.seed)
        var nextCandidateID: UInt64 = 1
        var allCandidates: [WetwareProtocolOptimizationCandidate] = []
        var generationReports: [WetwareProtocolOptimizationGeneration] = []

        let initialGenomes = initialPopulation(
            count: configuration.populationSize,
            dimension: parameterSpace.parameters.count,
            seed: configuration.seed
        )
        var population = await evaluate(
            genomes: initialGenomes,
            generation: 0,
            nextCandidateID: &nextCandidateID,
            requiredMetrics: requiredMetrics
        )
        rank(&population)
        allCandidates.append(contentsOf: population)
        generationReports.append(report(generation: 0, population: population))

        if configuration.generations > 1 {
            for generation in 1..<configuration.generations {
                let fraction = Double(generation) / Double(configuration.generations - 1)
                let mutationSigma = configuration.initialMutationStandardDeviation
                    + fraction
                        * (configuration.finalMutationStandardDeviation
                            - configuration.initialMutationStandardDeviation)
                let offspringGenomes = makeOffspring(
                    population: population,
                    count: configuration.offspringPerGeneration,
                    mutationSigma: mutationSigma,
                    random: &random
                )
                var offspring = await evaluate(
                    genomes: offspringGenomes,
                    generation: generation,
                    nextCandidateID: &nextCandidateID,
                    requiredMetrics: requiredMetrics
                )
                rank(&offspring)
                allCandidates.append(contentsOf: offspring)

                var combined = population + offspring
                rank(&combined)
                population = environmentalSelection(
                    combined,
                    count: configuration.populationSize
                )
                rank(&population)
                generationReports.append(report(
                    generation: generation,
                    population: population
                ))
            }
        }

        var finalPopulation = population
        rank(&finalPopulation)
        let pareto = finalPopulation
            .filter { $0.isFeasible && $0.paretoRank == 0 }
            .sorted(by: candidateOrdering)
        return WetwareProtocolOptimizationResult(
            parameterSpace: parameterSpace,
            objectives: objectives,
            constraints: constraints,
            configuration: configuration,
            candidates: allCandidates.sorted { $0.id < $1.id },
            generations: generationReports,
            paretoFront: pareto,
            startedAt: started,
            completedAt: Date()
        )
    }

    private func evaluate(
        genomes: [WetwareProtocolGenome],
        generation: Int,
        nextCandidateID: inout UInt64,
        requiredMetrics: Set<String>
    ) async -> [WetwareProtocolOptimizationCandidate] {
        let assignments = genomes.map { genome -> (UInt64, WetwareProtocolGenome) in
            defer { nextCandidateID &+= 1 }
            return (nextCandidateID, genome)
        }
        var results: [WetwareProtocolOptimizationCandidate] = []
        results.reserveCapacity(assignments.count)
        var cursor = 0

        while cursor < assignments.count {
            let upper = min(
                cursor + configuration.maximumConcurrentEvaluations,
                assignments.count
            )
            let batch = Array(assignments[cursor..<upper])
            let values = await withTaskGroup(
                of: WetwareProtocolOptimizationCandidate.self
            ) { group in
                for (candidateID, genome) in batch {
                    group.addTask {
                        await Self.evaluateOne(
                            id: candidateID,
                            generation: generation,
                            genome: genome,
                            parameterSpace: self.parameterSpace,
                            objectives: self.objectives,
                            constraints: self.constraints,
                            safetyEnvelope: self.safetyEnvelope,
                            requiredMetrics: requiredMetrics,
                            decoder: self.decoder,
                            evaluator: self.evaluator
                        )
                    }
                }
                var output: [WetwareProtocolOptimizationCandidate] = []
                for await value in group { output.append(value) }
                return output
            }
            results.append(contentsOf: values)
            cursor = upper
        }
        return results.sorted { $0.id < $1.id }
    }

    private static func evaluateOne(
        id: UInt64,
        generation: Int,
        genome: WetwareProtocolGenome,
        parameterSpace: WetwareProtocolParameterSpace,
        objectives: [WetwareObjective],
        constraints: [WetwareMetricConstraint],
        safetyEnvelope: WetwareStimulationSafetyEnvelope,
        requiredMetrics: Set<String>,
        decoder: WetwareProtocolDecoder,
        evaluator: WetwareProtocolEvaluator
    ) async -> WetwareProtocolOptimizationCandidate {
        do {
            _ = try genome.validated(dimension: parameterSpace.parameters.count)
            let parameters = try parameterSpace.decode(genome)
            let protocolValue = try decoder(parameters, id).validated()
            let safety = try WetwareProtocolSafetyValidator.validate(
                protocolValue,
                envelope: safetyEnvelope
            )
            guard safety.passed else {
                return WetwareProtocolOptimizationCandidate(
                    id: id,
                    generation: generation,
                    genome: genome,
                    parameters: parameters,
                    protocolValue: protocolValue,
                    safetyReport: safety,
                    status: .unsafe,
                    totalConstraintViolation: Double(safety.violations.count)
                )
            }
            let measurement = try await evaluator(protocolValue, id)
                .validated(requiredMetrics: requiredMetrics)
            let violation = constraints.reduce(0) { partial, constraint in
                partial + constraint.violation(
                    value: measurement.metrics[constraint.metric]
                        ?? Double.greatestFiniteMagnitude
                )
            }
            return WetwareProtocolOptimizationCandidate(
                id: id,
                generation: generation,
                genome: genome,
                parameters: parameters,
                protocolValue: protocolValue,
                safetyReport: safety,
                measurement: measurement,
                status: .evaluated,
                totalConstraintViolation: violation
            )
        } catch let error as WetwareOptimizationError {
            return WetwareProtocolOptimizationCandidate(
                id: id,
                generation: generation,
                genome: genome,
                parameters: [:],
                status: .invalid,
                totalConstraintViolation: Double.greatestFiniteMagnitude,
                errorDescription: error.description
            )
        } catch {
            return WetwareProtocolOptimizationCandidate(
                id: id,
                generation: generation,
                genome: genome,
                parameters: [:],
                status: .failed,
                totalConstraintViolation: Double.greatestFiniteMagnitude,
                errorDescription: String(describing: error)
            )
        }
    }

    private func makeOffspring(
        population: [WetwareProtocolOptimizationCandidate],
        count: Int,
        mutationSigma: Double,
        random: inout WetwareSplitMix64
    ) -> [WetwareProtocolGenome] {
        var genomes: [WetwareProtocolGenome] = []
        genomes.reserveCapacity(count)
        while genomes.count < count {
            let first = tournament(population, random: &random)
            let second = tournament(population, random: &random)
            var values = first.genome.normalizedValues
            if random.unit() < configuration.crossoverProbability {
                for index in values.indices {
                    let alpha = -0.25 + 1.5 * random.unit()
                    values[index] = alpha * first.genome.normalizedValues[index]
                        + (1 - alpha) * second.genome.normalizedValues[index]
                }
            }
            for index in values.indices {
                if random.unit() < configuration.mutationProbabilityPerParameter {
                    values[index] += mutationSigma * random.standardNormal()
                }
                values[index] = min(max(values[index], 0), 1)
            }
            genomes.append(WetwareProtocolGenome(normalizedValues: values))
        }
        return genomes
    }

    private func tournament(
        _ population: [WetwareProtocolOptimizationCandidate],
        random: inout WetwareSplitMix64
    ) -> WetwareProtocolOptimizationCandidate {
        var best = population[random.index(upperBound: population.count)]
        for _ in 1..<configuration.tournamentSize {
            let candidate = population[random.index(upperBound: population.count)]
            if candidateOrdering(candidate, best) { best = candidate }
        }
        return best
    }

    private func environmentalSelection(
        _ candidates: [WetwareProtocolOptimizationCandidate],
        count: Int
    ) -> [WetwareProtocolOptimizationCandidate] {
        candidates.sorted(by: candidateOrdering).prefix(count).map { $0 }
    }

    private func candidateOrdering(
        _ lhs: WetwareProtocolOptimizationCandidate,
        _ rhs: WetwareProtocolOptimizationCandidate
    ) -> Bool {
        if lhs.isFeasible != rhs.isFeasible { return lhs.isFeasible }
        if lhs.totalConstraintViolation != rhs.totalConstraintViolation {
            return lhs.totalConstraintViolation < rhs.totalConstraintViolation
        }
        if lhs.paretoRank != rhs.paretoRank { return lhs.paretoRank < rhs.paretoRank }
        if lhs.crowdingDistance != rhs.crowdingDistance {
            return lhs.crowdingDistance > rhs.crowdingDistance
        }
        return lhs.id < rhs.id
    }

    private func report(
        generation: Int,
        population: [WetwareProtocolOptimizationCandidate]
    ) -> WetwareProtocolOptimizationGeneration {
        WetwareProtocolOptimizationGeneration(
            index: generation,
            candidateIDs: population.map(\.id).sorted(),
            feasibleCount: population.filter(\.isFeasible).count,
            paretoFrontIDs: population
                .filter { $0.isFeasible && $0.paretoRank == 0 }
                .map(\.id)
                .sorted()
        )
    }

    private func rank(
        _ candidates: inout [WetwareProtocolOptimizationCandidate]
    ) {
        guard !candidates.isEmpty else { return }
        var dominated: [[Int]] = Array(repeating: [], count: candidates.count)
        var dominationCount = Array(repeating: 0, count: candidates.count)
        var fronts: [[Int]] = [[]]

        for lhs in candidates.indices {
            for rhs in candidates.indices where lhs != rhs {
                if dominates(candidates[lhs], candidates[rhs]) {
                    dominated[lhs].append(rhs)
                } else if dominates(candidates[rhs], candidates[lhs]) {
                    dominationCount[lhs] += 1
                }
            }
            if dominationCount[lhs] == 0 {
                candidates[lhs].paretoRank = 0
                fronts[0].append(lhs)
            }
        }

        var frontIndex = 0
        while frontIndex < fronts.count, !fronts[frontIndex].isEmpty {
            var next: [Int] = []
            for lhs in fronts[frontIndex] {
                for rhs in dominated[lhs] {
                    dominationCount[rhs] -= 1
                    if dominationCount[rhs] == 0 {
                        candidates[rhs].paretoRank = frontIndex + 1
                        next.append(rhs)
                    }
                }
            }
            if !next.isEmpty { fronts.append(next) }
            frontIndex += 1
        }

        for front in fronts where !front.isEmpty {
            assignCrowding(front: front, candidates: &candidates)
        }
    }

    private func dominates(
        _ lhs: WetwareProtocolOptimizationCandidate,
        _ rhs: WetwareProtocolOptimizationCandidate
    ) -> Bool {
        if lhs.isFeasible != rhs.isFeasible { return lhs.isFeasible }
        if !lhs.isFeasible {
            return lhs.totalConstraintViolation < rhs.totalConstraintViolation
        }
        guard let lhsMetrics = lhs.measurement?.metrics,
              let rhsMetrics = rhs.measurement?.metrics else {
            return false
        }
        var strictlyBetter = false
        for objective in objectives {
            guard let lhsValue = lhsMetrics[objective.metric],
                  let rhsValue = rhsMetrics[objective.metric] else {
                return false
            }
            switch objective.direction {
            case .minimize:
                if lhsValue > rhsValue + objective.epsilon { return false }
                if lhsValue + objective.epsilon < rhsValue { strictlyBetter = true }
            case .maximize:
                if lhsValue + objective.epsilon < rhsValue { return false }
                if lhsValue > rhsValue + objective.epsilon { strictlyBetter = true }
            }
        }
        return strictlyBetter
    }

    private func assignCrowding(
        front: [Int],
        candidates: inout [WetwareProtocolOptimizationCandidate]
    ) {
        for index in front { candidates[index].crowdingDistance = 0 }
        guard front.count > 2 else {
            for index in front { candidates[index].crowdingDistance = Double.infinity }
            return
        }
        for objective in objectives {
            let ordered = front.sorted { lhs, rhs in
                let lhsValue = candidates[lhs].measurement?.metrics[objective.metric]
                    ?? objective.direction.worstValue
                let rhsValue = candidates[rhs].measurement?.metrics[objective.metric]
                    ?? objective.direction.worstValue
                return lhsValue < rhsValue
            }
            guard let first = ordered.first, let last = ordered.last else { continue }
            candidates[first].crowdingDistance = Double.infinity
            candidates[last].crowdingDistance = Double.infinity
            let minimum = candidates[first].measurement?.metrics[objective.metric] ?? 0
            let maximum = candidates[last].measurement?.metrics[objective.metric] ?? 0
            let range = maximum - minimum
            guard range > 0 else { continue }
            for position in 1..<(ordered.count - 1) {
                let previous = candidates[ordered[position - 1]]
                    .measurement?.metrics[objective.metric] ?? minimum
                let next = candidates[ordered[position + 1]]
                    .measurement?.metrics[objective.metric] ?? maximum
                if candidates[ordered[position]].crowdingDistance.isFinite {
                    candidates[ordered[position]].crowdingDistance += (next - previous) / range
                }
            }
        }
    }

    private func initialPopulation(
        count: Int,
        dimension: Int,
        seed: UInt64
    ) -> [WetwareProtocolGenome] {
        let primes = firstPrimes(count: max(dimension, 1))
        let offset = Int(seed % 10_000) + 1
        return (0..<count).map { sampleIndex in
            WetwareProtocolGenome(normalizedValues: (0..<dimension).map { dimensionIndex in
                halton(index: offset + sampleIndex, base: primes[dimensionIndex])
            })
        }
    }

    private func halton(index: Int, base: Int) -> Double {
        var index = max(index, 1)
        var factor = 1.0
        var result = 0.0
        while index > 0 {
            factor /= Double(base)
            result += factor * Double(index % base)
            index /= base
        }
        return result
    }

    private func firstPrimes(count: Int) -> [Int] {
        var values: [Int] = []
        var candidate = 2
        while values.count < count {
            let isPrime = values
                .filter { $0 * $0 <= candidate }
                .allSatisfy { candidate % $0 != 0 }
            if isPrime { values.append(candidate) }
            candidate += 1
        }
        return values
    }
}

private extension WetwareObjectiveDirection {
    var worstValue: Double {
        switch self {
        case .minimize: return Double.greatestFiniteMagnitude
        case .maximize: return -Double.greatestFiniteMagnitude
        }
    }
}

private struct WetwareSplitMix64: Sendable {
    private var state: UInt64
    private var spareNormal: Double?

    init(seed: UInt64) {
        state = seed
        spareNormal = nil
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

    mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(next() % UInt64(upperBound))
    }

    mutating func standardNormal() -> Double {
        if let spareNormal {
            self.spareNormal = nil
            return spareNormal
        }
        let u1 = max(unit(), Double.leastNonzeroMagnitude)
        let u2 = unit()
        let radius = sqrt(-2 * log(u1))
        let angle = 2 * Double.pi * u2
        spareNormal = radius * sin(angle)
        return radius * cos(angle)
    }
}

public enum WetwareOptimizationError: Error, Sendable, CustomStringConvertible {
    case invalidParameter(String)
    case invalidParameterSpace
    case genomeDimension
    case invalidGenome
    case invalidObjective(String)
    case invalidObjectives
    case invalidConstraint(String)
    case invalidConstraints
    case invalidMeasurement
    case invalidConfiguration

    public var description: String {
        switch self {
        case .invalidParameter(let name): return "Wetware optimization parameter \(name) is invalid"
        case .invalidParameterSpace: return "Wetware optimization parameter space is invalid"
        case .genomeDimension: return "Wetware protocol genome has the wrong dimension"
        case .invalidGenome: return "Wetware protocol genome is invalid"
        case .invalidObjective(let name): return "Wetware optimization objective \(name) is invalid"
        case .invalidObjectives: return "Wetware optimization objectives are invalid"
        case .invalidConstraint(let name): return "Wetware optimization constraint \(name) is invalid"
        case .invalidConstraints: return "Wetware optimization constraints are invalid"
        case .invalidMeasurement: return "Wetware protocol measurement is invalid"
        case .invalidConfiguration: return "Wetware protocol optimizer configuration is invalid"
        }
    }
}
