import Foundation

@frozen
public struct NTMolecularSpeciesDefinition: Codable, Hashable, Sendable {
    public var id: UInt16
    public var name: String
    public var initialAmount: Float
    public var diffusionSquareMicrometersPerSecond: Float
    public var minimumAmount: Float
    public var maximumAmount: Float
    public var isDiscrete: Bool

    public init(
        id: UInt16,
        name: String,
        initialAmount: Float,
        diffusionSquareMicrometersPerSecond: Float = 0,
        minimumAmount: Float = 0,
        maximumAmount: Float = .greatestFiniteMagnitude,
        isDiscrete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.initialAmount = initialAmount
        self.diffusionSquareMicrometersPerSecond = diffusionSquareMicrometersPerSecond
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
        self.isDiscrete = isDiscrete
    }
}

@frozen
public struct NTStoichiometricTerm: Codable, Hashable, Sendable {
    public var species: UInt16
    public var coefficient: Int16

    public init(species: UInt16, coefficient: Int16) {
        self.species = species
        self.coefficient = coefficient
    }
}

public enum NTReactionRateLaw: Codable, Hashable, Sendable {
    case massAction(rate: Float)
    case reversibleMassAction(forward: Float, reverse: Float)
    case michaelisMenten(maximum: Float, halfSaturation: Float, substrate: UInt16)
    case hill(maximum: Float, halfActivation: Float, exponent: Float, regulator: UInt16)
    case inhibited(maximum: Float, halfSaturation: Float, inhibitorConstant: Float, substrate: UInt16, inhibitor: UInt16)
    case voltageDependent(base: Float, halfActivationMillivolts: Float, slopeMillivolts: Float)
    case calciumDependent(maximum: Float, halfActivationMicromolar: Float, exponent: Float)
    case affine(constant: Float, coefficients: [UInt16: Float])
}

@frozen
public struct NTReactionDefinition: Codable, Hashable, Sendable {
    public var id: UInt16
    public var name: String
    public var reactants: [NTStoichiometricTerm]
    public var products: [NTStoichiometricTerm]
    public var rateLaw: NTReactionRateLaw
    public var enabled: Bool

    public init(
        id: UInt16,
        name: String,
        reactants: [NTStoichiometricTerm],
        products: [NTStoichiometricTerm],
        rateLaw: NTReactionRateLaw,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.reactants = reactants
        self.products = products
        self.rateLaw = rateLaw
        self.enabled = enabled
    }
}

@frozen
public struct NTCompiledReaction: Codable, Hashable, Sendable {
    public var id: UInt16
    public var name: String
    public var reactantSpecies: [UInt16]
    public var reactantOrders: [UInt16]
    public var netSpecies: [UInt16]
    public var netCoefficients: [Int16]
    public var rateLaw: NTReactionRateLaw

    public init(definition: NTReactionDefinition, speciesCount: Int) throws {
        var reactants: [UInt16: Int] = [:]
        var net: [UInt16: Int] = [:]
        for term in definition.reactants {
            guard Int(term.species) < speciesCount, term.coefficient < 0 else {
                throw NTRuntimeError.invalidModel("Reaction \(definition.name) has invalid reactant stoichiometry.")
            }
            reactants[term.species, default: 0] += Int(-term.coefficient)
            net[term.species, default: 0] += Int(term.coefficient)
        }
        for term in definition.products {
            guard Int(term.species) < speciesCount, term.coefficient > 0 else {
                throw NTRuntimeError.invalidModel("Reaction \(definition.name) has invalid product stoichiometry.")
            }
            net[term.species, default: 0] += Int(term.coefficient)
        }
        self.id = definition.id
        self.name = definition.name
        self.reactantSpecies = reactants.keys.sorted()
        self.reactantOrders = reactantSpecies.map { UInt16(clamping: reactants[$0, default: 0]) }
        self.netSpecies = net.keys.sorted()
        self.netCoefficients = netSpecies.map { Int16(clamping: net[$0, default: 0]) }
        self.rateLaw = definition.rateLaw
    }
}

@frozen
public struct NTCompiledReactionNetwork: Codable, Hashable, Sendable {
    public var id: UInt32
    public var name: String
    public var species: [NTMolecularSpeciesDefinition]
    public var reactions: [NTCompiledReaction]
    public var checksum: UInt64

    public init(id: UInt32, name: String, species: [NTMolecularSpeciesDefinition], reactions: [NTReactionDefinition]) throws {
        guard !species.isEmpty, species.count <= 64 else {
            throw NTRuntimeError.invalidModel("A molecular network must define 1...64 species.")
        }
        guard reactions.count <= 128 else {
            throw NTRuntimeError.invalidModel("A molecular network may define at most 128 reactions.")
        }
        let sortedSpecies = species.sorted { $0.id < $1.id }
        for (index, item) in sortedSpecies.enumerated() where item.id != UInt16(index) {
            throw NTRuntimeError.invalidModel("Molecular species identifiers must be dense and zero-based.")
        }
        self.id = id
        self.name = name
        self.species = sortedSpecies
        self.reactions = try reactions.filter(\.enabled).map {
            try NTCompiledReaction(definition: $0, speciesCount: species.count)
        }.sorted { $0.id < $1.id }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3 }
        hash = (hash ^ UInt64(species.count)) &* 0x1000_0000_01b3
        hash = (hash ^ UInt64(reactions.count)) &* 0x1000_0000_01b3
        self.checksum = hash
    }
}

@frozen
public struct NTMicrodomainCoupling: Codable, Hashable, Sendable {
    public var microdomain: MicrodomainID
    public var species: UInt16
    public var compartment: CompartmentID?
    public var extracellularSpecies: NTExtracellularSpecies?
    public var membraneFluxScale: Float
    public var extracellularFluxScale: Float
    public var clampToCompartmentCalcium: Bool
    public var voltageSensitive: Bool

    public init(
        microdomain: MicrodomainID,
        species: UInt16,
        compartment: CompartmentID? = nil,
        extracellularSpecies: NTExtracellularSpecies? = nil,
        membraneFluxScale: Float = 0,
        extracellularFluxScale: Float = 0,
        clampToCompartmentCalcium: Bool = false,
        voltageSensitive: Bool = false
    ) {
        self.microdomain = microdomain
        self.species = species
        self.compartment = compartment
        self.extracellularSpecies = extracellularSpecies
        self.membraneFluxScale = membraneFluxScale
        self.extracellularFluxScale = extracellularFluxScale
        self.clampToCompartmentCalcium = clampToCompartmentCalcium
        self.voltageSensitive = voltageSensitive
    }
}

@frozen
public struct NTSpatialMicrodomainState: Codable, Hashable, Sendable {
    public var microdomain: MicrodomainID
    public var dimensions: SIMD3<UInt16>
    public var voxelEdgeMicrometers: Float
    public var speciesCount: UInt16
    public var amounts: [Float]
    public var boundaryLeakPerSecond: Float

    public init(
        microdomain: MicrodomainID,
        dimensions: SIMD3<UInt16>,
        voxelEdgeMicrometers: Float,
        speciesCount: Int,
        initialAmounts: [Float],
        boundaryLeakPerSecond: Float = 0
    ) throws {
        let voxelCount = Int(dimensions.x) * Int(dimensions.y) * Int(dimensions.z)
        guard voxelCount > 0, voxelCount <= 64, speciesCount > 0, speciesCount <= 64,
              initialAmounts.count == speciesCount else {
            throw NTRuntimeError.invalidModel("Spatial microdomain dimensions or initial amounts are invalid.")
        }
        self.microdomain = microdomain
        self.dimensions = dimensions
        self.voxelEdgeMicrometers = voxelEdgeMicrometers
        self.speciesCount = UInt16(clamping: speciesCount)
        self.amounts = []
        self.amounts.reserveCapacity(voxelCount * speciesCount)
        for _ in 0..<voxelCount { self.amounts.append(contentsOf: initialAmounts) }
        self.boundaryLeakPerSecond = boundaryLeakPerSecond
    }

    public var voxelCount: Int { Int(dimensions.x) * Int(dimensions.y) * Int(dimensions.z) }

    @inlinable
    public func index(x: Int, y: Int, z: Int, species: Int) -> Int {
        ((((z * Int(dimensions.y)) + y) * Int(dimensions.x)) + x) * Int(speciesCount) + species
    }
}

@frozen
public struct NTMolecularAuxiliaryState: Codable, Sendable {
    public var networks: [NTCompiledReactionNetwork]
    public var couplings: [NTMicrodomainCoupling]
    public var spatialDomains: [NTSpatialMicrodomainState]

    public init(
        networks: [NTCompiledReactionNetwork] = [],
        couplings: [NTMicrodomainCoupling] = [],
        spatialDomains: [NTSpatialMicrodomainState] = []
    ) {
        self.networks = networks
        self.couplings = couplings
        self.spatialDomains = spatialDomains
    }
}

@frozen
public struct NTMolecularStepResult: Sendable {
    public var exactReactionEvents: UInt64
    public var tauLeapReactionEvents: UInt64
    public var deterministicEvaluations: UInt64
    public var diffusionSubsteps: UInt32
    public var promotedSolvers: UInt32
    public var diagnostics: [NTDiagnostic]

    public init() {
        exactReactionEvents = 0
        tauLeapReactionEvents = 0
        deterministicEvaluations = 0
        diffusionSubsteps = 0
        promotedSolvers = 0
        diagnostics = []
    }
}

public struct NTMolecularMicrodomainEngine: Sendable {
    public var fieldEngine: NTExtracellularFieldEngine
    public var relativeTolerance: Float
    public var absoluteTolerance: Float
    public var maximumExactEventsPerStep: Int
    public var maximumTauLeapEventsPerReaction: Int

    public init(
        fieldEngine: NTExtracellularFieldEngine = .init(),
        relativeTolerance: Float = 1.0e-4,
        absoluteTolerance: Float = 1.0e-7,
        maximumExactEventsPerStep: Int = 100_000,
        maximumTauLeapEventsPerReaction: Int = 1_000_000
    ) {
        self.fieldEngine = fieldEngine
        self.relativeTolerance = relativeTolerance
        self.absoluteTolerance = absoluteTolerance
        self.maximumExactEventsPerStep = maximumExactEventsPerStep
        self.maximumTauLeapEventsPerReaction = maximumTauLeapEventsPerReaction
    }

    public func step(
        state: inout NTProductionState,
        auxiliary: inout NTMolecularAuxiliaryState,
        deltaTicks: UInt64,
        transaction: TransactionID
    ) -> NTMolecularStepResult {
        var result = NTMolecularStepResult()
        let dt = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        guard dt > 0 else { return result }
        let networkByID = Dictionary(uniqueKeysWithValues: auxiliary.networks.map { ($0.id, $0) })

        applyInboundCoupling(state: &state, auxiliary: auxiliary, dt: dt)
        for index in state.microdomains.indices {
            var domain = state.microdomains[index]
            guard let network = networkByID[domain.networkIndex] else {
                result.diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidReference,
                    message: "Microdomain references absent reaction network \(domain.networkIndex).",
                    entity: domain.id.rawValue,
                    tile: domain.tile
                ))
                continue
            }
            guard domain.speciesAmounts.count == network.species.count else {
                result.diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidReference,
                    message: "Microdomain species state does not match its reaction network.",
                    entity: domain.id.rawValue,
                    tile: domain.tile
                ))
                continue
            }

            let selected = selectSolver(domain: domain, network: network)
            if selected != domain.solver {
                domain.solver = selected
                result.promotedSolvers &+= 1
            }
            let voltage = coupledVoltage(domain: domain, state: state, couplings: auxiliary.couplings)
            let calcium = coupledCalcium(domain: domain, state: state, couplings: auxiliary.couplings)
            switch domain.solver {
            case .exactSSA:
                exactSSA(
                    domain: &domain,
                    network: network,
                    duration: dt,
                    voltage: voltage,
                    calcium: calcium,
                    seed: state.configuration.seed,
                    transaction: transaction,
                    result: &result
                )
            case .tauLeaping:
                tauLeap(
                    domain: &domain,
                    network: network,
                    duration: dt,
                    voltage: voltage,
                    calcium: calcium,
                    seed: state.configuration.seed,
                    transaction: transaction,
                    result: &result
                )
            case .deterministicODE:
                deterministicAdaptive(
                    domain: &domain,
                    network: network,
                    duration: dt,
                    voltage: voltage,
                    calcium: calcium,
                    result: &result
                )
            case .reactionDiffusion:
                deterministicAdaptive(
                    domain: &domain,
                    network: network,
                    duration: dt,
                    voltage: voltage,
                    calcium: calcium,
                    result: &result
                )
            }
            clamp(domain: &domain, network: network, result: &result)
            state.microdomains[index] = domain
        }

        for index in auxiliary.spatialDomains.indices {
            guard let domainIndex = state.microdomainIndex(id: auxiliary.spatialDomains[index].microdomain),
                  let network = networkByID[state.microdomains[domainIndex].networkIndex] else { continue }
            diffuseSpatial(
                spatial: &auxiliary.spatialDomains[index],
                network: network,
                duration: dt,
                result: &result
            )
            state.microdomains[domainIndex].speciesAmounts = spatialMean(auxiliary.spatialDomains[index])
        }
        applyOutboundCoupling(state: &state, auxiliary: auxiliary, dt: dt)
        return result
    }

    public func selectSolver(domain: NTMicrodomainState, network: NTCompiledReactionNetwork) -> NTMicrodomainSolverKind {
        let minimum = domain.speciesAmounts.min() ?? 0
        let mean = domain.speciesAmounts.reduce(0, +) / Float(max(domain.speciesAmounts.count, 1))
        let spatial = network.species.contains { $0.diffusionSquareMicrometersPerSecond > 0 }
        if spatial && domain.speciesAmounts.count * 4 <= 256 { return .reactionDiffusion }
        if minimum < 100 || network.species.contains(where: { $0.isDiscrete && domain.speciesAmounts[Int($0.id)] < 1_000 }) {
            return .exactSSA
        }
        if mean < 100_000 { return .tauLeaping }
        return .deterministicODE
    }

    private func exactSSA(
        domain: inout NTMicrodomainState,
        network: NTCompiledReactionNetwork,
        duration: Float,
        voltage: Float,
        calcium: Float,
        seed: UInt64,
        transaction: TransactionID,
        result: inout NTMolecularStepResult
    ) {
        var elapsed: Float = 0
        var eventIndex = 0
        while elapsed < duration && eventIndex < maximumExactEventsPerStep {
            let propensities = network.reactions.map {
                propensity(reaction: $0, amounts: domain.speciesAmounts, voltage: voltage, calcium: calcium, discrete: true)
            }
            let total = propensities.reduce(0, +)
            guard total.isFinite, total > 0 else { break }
            let random = CounterRandom.generate(
                counter: RandomAddress(
                    transaction: transaction.rawValue,
                    entity: domain.id.rawValue,
                    stream: UInt32(eventIndex),
                    sample: UInt32(truncatingIfNeeded: domain.nextEvent.tick)
                ).counter(),
                key: PhiloxKey(seed: seed)
            )
            let wait = -log(max(CounterRandom.uniform01(random.x), 1.0e-12)) / total
            if elapsed + wait > duration { break }
            let threshold = CounterRandom.uniform01(random.y) * total
            var cumulative: Float = 0
            var selected = propensities.count - 1
            for index in propensities.indices {
                cumulative += propensities[index]
                if cumulative >= threshold { selected = index; break }
            }
            apply(reaction: network.reactions[selected], count: 1, amounts: &domain.speciesAmounts)
            elapsed += wait
            eventIndex += 1
            result.exactReactionEvents &+= 1
        }
        if eventIndex == maximumExactEventsPerStep {
            domain.solver = .tauLeaping
            result.promotedSolvers &+= 1
        }
    }

    private func tauLeap(
        domain: inout NTMicrodomainState,
        network: NTCompiledReactionNetwork,
        duration: Float,
        voltage: Float,
        calcium: Float,
        seed: UInt64,
        transaction: TransactionID,
        result: inout NTMolecularStepResult
    ) {
        var elapsed: Float = 0
        var leapIndex: UInt32 = 0
        while elapsed < duration {
            let propensities = network.reactions.map {
                propensity(reaction: $0, amounts: domain.speciesAmounts, voltage: voltage, calcium: calcium, discrete: false)
            }
            let maximum = propensities.max() ?? 0
            if maximum <= 0 || !maximum.isFinite { break }
            let minimumAmount = max(1, domain.speciesAmounts.filter { $0 > 0 }.min() ?? 1)
            let adaptive = min(duration - elapsed, max(1.0e-7, 0.03 * minimumAmount / maximum))
            for reactionIndex in network.reactions.indices {
                let lambda = max(0, min(Float(maximumTauLeapEventsPerReaction), propensities[reactionIndex] * adaptive))
                let random = CounterRandom.generate(
                    counter: RandomAddress(
                        transaction: transaction.rawValue,
                        entity: domain.id.rawValue,
                        stream: leapIndex,
                        sample: UInt32(reactionIndex)
                    ).counter(),
                    key: PhiloxKey(seed: seed)
                )
                let count = poisson(lambda: lambda, random: random)
                let feasible = feasibleReactionCount(
                    reaction: network.reactions[reactionIndex],
                    requested: count,
                    amounts: domain.speciesAmounts
                )
                if feasible > 0 {
                    apply(reaction: network.reactions[reactionIndex], count: feasible, amounts: &domain.speciesAmounts)
                    result.tauLeapReactionEvents &+= UInt64(feasible)
                }
            }
            elapsed += adaptive
            leapIndex &+= 1
        }
    }

    private func deterministicAdaptive(
        domain: inout NTMicrodomainState,
        network: NTCompiledReactionNetwork,
        duration: Float,
        voltage: Float,
        calcium: Float,
        result: inout NTMolecularStepResult
    ) {
        var time: Float = 0
        var step = min(duration, 0.001)
        var state = domain.speciesAmounts
        while time < duration {
            step = min(step, duration - time)
            let k1 = derivative(network: network, amounts: state, voltage: voltage, calcium: calcium)
            let euler = zip(state, k1).map { max(0, $0 + step * $1) }
            let k2 = derivative(network: network, amounts: euler, voltage: voltage, calcium: calcium)
            let heun = zip(zip(state, k1), k2).map { pair, second in
                max(0, pair.0 + 0.5 * step * (pair.1 + second))
            }
            result.deterministicEvaluations &+= 2
            var normalizedError: Float = 0
            for index in state.indices {
                let scale = absoluteTolerance + relativeTolerance * max(abs(state[index]), abs(heun[index]))
                normalizedError = max(normalizedError, abs(heun[index] - euler[index]) / max(scale, 1.0e-12))
            }
            if normalizedError <= 1 || step <= 1.0e-9 {
                state = heun
                time += step
            }
            let factor = normalizedError > 0 ? 0.9 * pow(normalizedError, -0.5) : 2
            step *= min(2, max(0.2, factor))
        }
        domain.speciesAmounts = state
    }

    private func diffuseSpatial(
        spatial: inout NTSpatialMicrodomainState,
        network: NTCompiledReactionNetwork,
        duration: Float,
        result: inout NTMolecularStepResult
    ) {
        let maxDiffusion = network.species.map(\.diffusionSquareMicrometersPerSecond).max() ?? 0
        guard maxDiffusion > 0 else { return }
        let stable = 0.8 * spatial.voxelEdgeMicrometers * spatial.voxelEdgeMicrometers / (6 * maxDiffusion)
        let substeps = max(1, Int(ceil(duration / max(stable, 1.0e-9))))
        let dt = duration / Float(substeps)
        let nx = Int(spatial.dimensions.x)
        let ny = Int(spatial.dimensions.y)
        let nz = Int(spatial.dimensions.z)
        let speciesCount = Int(spatial.speciesCount)
        for _ in 0..<substeps {
            let previous = spatial.amounts
            var next = previous
            for z in 0..<nz {
                for y in 0..<ny {
                    for x in 0..<nx {
                        for species in 0..<speciesCount {
                            let centerIndex = spatial.index(x: x, y: y, z: z, species: species)
                            let center = previous[centerIndex]
                            func value(_ px: Int, _ py: Int, _ pz: Int) -> Float {
                                if px < 0 || px >= nx || py < 0 || py >= ny || pz < 0 || pz >= nz {
                                    return center * max(0, 1 - spatial.boundaryLeakPerSecond * dt)
                                }
                                return previous[spatial.index(x: px, y: py, z: pz, species: species)]
                            }
                            let laplacian = (value(x - 1, y, z) + value(x + 1, y, z) +
                                value(x, y - 1, z) + value(x, y + 1, z) +
                                value(x, y, z - 1) + value(x, y, z + 1) - 6 * center) /
                                max(spatial.voxelEdgeMicrometers * spatial.voxelEdgeMicrometers, 1.0e-12)
                            let diffusion = network.species[species].diffusionSquareMicrometersPerSecond
                            next[centerIndex] = max(0, center + dt * diffusion * laplacian)
                        }
                    }
                }
            }
            spatial.amounts = next
        }
        result.diffusionSubsteps &+= UInt32(clamping: substeps)
    }

    private func derivative(
        network: NTCompiledReactionNetwork,
        amounts: [Float],
        voltage: Float,
        calcium: Float
    ) -> [Float] {
        var derivative = Array(repeating: Float.zero, count: amounts.count)
        for reaction in network.reactions {
            let rate = propensity(reaction: reaction, amounts: amounts, voltage: voltage, calcium: calcium, discrete: false)
            for index in reaction.netSpecies.indices {
                derivative[Int(reaction.netSpecies[index])] += Float(reaction.netCoefficients[index]) * rate
            }
        }
        return derivative
    }

    private func propensity(
        reaction: NTCompiledReaction,
        amounts: [Float],
        voltage: Float,
        calcium: Float,
        discrete: Bool
    ) -> Float {
        func massAction(_ rate: Float) -> Float {
            var value = rate
            for index in reaction.reactantSpecies.indices {
                let species = Int(reaction.reactantSpecies[index])
                let order = Int(reaction.reactantOrders[index])
                let amount = max(0, amounts[species])
                if discrete {
                    var falling: Float = 1
                    if order > 0 {
                        for term in 0..<order { falling *= max(0, amount - Float(term)) }
                    }
                    value *= falling
                } else {
                    value *= pow(amount, Float(order))
                }
            }
            return max(0, value)
        }

        switch reaction.rateLaw {
        case let .massAction(rate):
            return massAction(rate)
        case let .reversibleMassAction(forward, reverse):
            return max(0, massAction(forward) - reverse)
        case let .michaelisMenten(maximum, half, substrate):
            let s = max(0, amounts[Int(substrate)])
            return maximum * s / max(half + s, 1.0e-12)
        case let .hill(maximum, half, exponent, regulator):
            let x = pow(max(0, amounts[Int(regulator)]), exponent)
            return maximum * x / max(pow(half, exponent) + x, 1.0e-12)
        case let .inhibited(maximum, half, inhibitorConstant, substrate, inhibitor):
            let s = max(0, amounts[Int(substrate)])
            let i = max(0, amounts[Int(inhibitor)])
            return maximum * s / max(half * (1 + i / max(inhibitorConstant, 1.0e-12)) + s, 1.0e-12)
        case let .voltageDependent(base, half, slope):
            return base / (1 + exp(-(voltage - half) / max(abs(slope), 1.0e-6)))
        case let .calciumDependent(maximum, half, exponent):
            let x = pow(max(0, calcium), exponent)
            return maximum * x / max(pow(half, exponent) + x, 1.0e-12)
        case let .affine(constant, coefficients):
            return max(0, coefficients.reduce(constant) { partial, pair in
                partial + pair.value * amounts[Int(pair.key)]
            })
        }
    }

    private func apply(reaction: NTCompiledReaction, count: Int, amounts: inout [Float]) {
        for index in reaction.netSpecies.indices {
            let species = Int(reaction.netSpecies[index])
            amounts[species] += Float(Int(reaction.netCoefficients[index]) * count)
        }
    }

    private func feasibleReactionCount(reaction: NTCompiledReaction, requested: Int, amounts: [Float]) -> Int {
        var feasible = requested
        for index in reaction.reactantSpecies.indices {
            let species = Int(reaction.reactantSpecies[index])
            let order = max(1, Int(reaction.reactantOrders[index]))
            feasible = min(feasible, Int(max(0, floor(amounts[species] / Float(order)))))
        }
        return max(0, feasible)
    }

    private func poisson(lambda: Float, random: PhiloxCounter) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda < 30 {
            let limit = exp(-lambda)
            var product: Float = 1
            var count = 0
            var generated = random
            while product > limit && count < maximumTauLeapEventsPerReaction {
                let value: UInt32
                switch count & 3 {
                case 0: value = generated.x
                case 1: value = generated.y
                case 2: value = generated.z
                default:
                    value = generated.w
                    generated = CounterRandom.generate(counter: generated, key: PhiloxKey(seed: UInt64(count)))
                }
                product *= CounterRandom.uniform01(value)
                count += 1
            }
            return max(0, count - 1)
        }
        let normal = CounterRandom.normalPair(random.x, random.y).x
        return max(0, min(maximumTauLeapEventsPerReaction, Int((lambda + sqrt(lambda) * normal).rounded())))
    }

    private func clamp(domain: inout NTMicrodomainState, network: NTCompiledReactionNetwork, result: inout NTMolecularStepResult) {
        for index in domain.speciesAmounts.indices {
            let definition = network.species[index]
            let value = domain.speciesAmounts[index]
            if !value.isFinite {
                result.diagnostics.append(.init(
                    severity: .fatal,
                    code: .nonFiniteState,
                    message: "Molecular species \(definition.name) became non-finite.",
                    entity: domain.id.rawValue,
                    tile: domain.tile
                ))
                domain.speciesAmounts[index] = definition.minimumAmount
            } else if value < definition.minimumAmount {
                result.diagnostics.append(.init(
                    severity: .error,
                    code: .negativeMoleculeCount,
                    message: "Molecular species \(definition.name) fell below its minimum amount.",
                    entity: domain.id.rawValue,
                    tile: domain.tile
                ))
                domain.speciesAmounts[index] = definition.minimumAmount
            } else {
                domain.speciesAmounts[index] = min(definition.maximumAmount, value)
            }
        }
    }

    private func spatialMean(_ spatial: NTSpatialMicrodomainState) -> [Float] {
        let speciesCount = Int(spatial.speciesCount)
        var result = Array(repeating: Float.zero, count: speciesCount)
        for index in spatial.amounts.indices { result[index % speciesCount] += spatial.amounts[index] }
        let denominator = Float(max(1, spatial.voxelCount))
        return result.map { $0 / denominator }
    }

    private func coupledVoltage(domain: NTMicrodomainState, state: NTProductionState, couplings: [NTMicrodomainCoupling]) -> Float {
        for coupling in couplings where coupling.microdomain == domain.id && coupling.voltageSensitive {
            if let compartment = coupling.compartment,
               let index = state.compartmentIndex(id: compartment) {
                return state.compartments[index].record.membraneVoltageMillivolts
            }
        }
        return -65
    }

    private func coupledCalcium(domain: NTMicrodomainState, state: NTProductionState, couplings: [NTMicrodomainCoupling]) -> Float {
        for coupling in couplings where coupling.microdomain == domain.id && coupling.compartment != nil {
            if let compartment = coupling.compartment,
               let index = state.compartmentIndex(id: compartment) {
                return state.compartments[index].record.calciumMicromolar
            }
        }
        return 0.05
    }

    private func applyInboundCoupling(state: inout NTProductionState, auxiliary: NTMolecularAuxiliaryState, dt: Float) {
        for coupling in auxiliary.couplings {
            guard let domainIndex = state.microdomainIndex(id: coupling.microdomain),
                  state.microdomains[domainIndex].speciesAmounts.indices.contains(Int(coupling.species)) else { continue }
            if coupling.clampToCompartmentCalcium,
               let compartment = coupling.compartment,
               let compartmentIndex = state.compartmentIndex(id: compartment) {
                state.microdomains[domainIndex].speciesAmounts[Int(coupling.species)] =
                    state.compartments[compartmentIndex].record.calciumMicromolar
            }
            if let extracellularSpecies = coupling.extracellularSpecies,
               coupling.extracellularFluxScale != 0 {
                let domain = state.microdomains[domainIndex]
                if let value = fieldEngine.sample(
                    state: state,
                    tile: domain.tile,
                    positionMicrometers: position(domain: domain, state: state),
                    species: extracellularSpecies
                ) {
                    let current = state.microdomains[domainIndex].speciesAmounts[Int(coupling.species)]
                    state.microdomains[domainIndex].speciesAmounts[Int(coupling.species)] +=
                        coupling.extracellularFluxScale * (value - current) * dt
                }
            }
        }
    }

    private func applyOutboundCoupling(state: inout NTProductionState, auxiliary: NTMolecularAuxiliaryState, dt: Float) {
        for coupling in auxiliary.couplings {
            guard let domainIndex = state.microdomainIndex(id: coupling.microdomain),
                  state.microdomains[domainIndex].speciesAmounts.indices.contains(Int(coupling.species)) else { continue }
            let domain = state.microdomains[domainIndex]
            let amount = domain.speciesAmounts[Int(coupling.species)]
            if let compartment = coupling.compartment,
               let compartmentIndex = state.compartmentIndex(id: compartment),
               coupling.membraneFluxScale != 0 {
                state.compartments[compartmentIndex].record.calciumMicromolar = max(
                    0,
                    state.compartments[compartmentIndex].record.calciumMicromolar +
                    coupling.membraneFluxScale * (amount - state.compartments[compartmentIndex].record.calciumMicromolar) * dt
                )
            }
            if let extracellularSpecies = coupling.extracellularSpecies,
               coupling.extracellularFluxScale != 0 {
                fieldEngine.addSource(
                    state: &state,
                    tile: domain.tile,
                    positionMicrometers: position(domain: domain, state: state),
                    species: extracellularSpecies,
                    amountPerSecond: coupling.extracellularFluxScale * amount
                )
            }
        }
    }

    private func position(domain: NTMicrodomainState, state: NTProductionState) -> NTVector3 {
        if let compartment = domain.ownerCompartment,
           let index = state.compartmentIndex(id: compartment) {
            return state.compartments[index].record.positionMicrometers
        }
        if let index = state.cellIndex(id: domain.ownerCell) {
            return state.cells[index].record.positionMicrometers
        }
        return .zero
    }
}

public extension Int16 {
    init(clamping value: Int) {
        self = value < Int(Int16.min) ? Int16.min : value > Int(Int16.max) ? Int16.max : Int16(value)
    }
}
