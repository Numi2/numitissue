#if canImport(Metal)
import Foundation
import NumiTissueIO

public enum MetalMolecularSolverKind: UInt32, Sendable, Hashable, Codable {
    case deterministicRK2 = 0
    case exactSSA = 1
    case adaptiveTauLeap = 2
    case automatic = 3
}

@frozen
public struct MetalMolecularReactionDescriptor: Sendable {
    public var reactant0: UInt32
    public var reactant1: UInt32
    public var reactant2: UInt32
    public var reactant3: UInt32
    public var product0: UInt32
    public var product1: UInt32
    public var product2: UInt32
    public var product3: UInt32
    public var reactantStoichiometry: UInt32
    public var productStoichiometry: UInt32
    public var reactantCount: UInt32
    public var productCount: UInt32
    public var flags: UInt32
    public var reserved: UInt32
    public var rateConstant: Float
    public var reservedFloat: Float

    public init(
        reactants: [(UInt32, UInt8)],
        products: [(UInt32, UInt8)],
        flags: UInt32,
        rateConstant: Float
    ) {
        let r = reactants.map(\.0) + repeatElement(UInt32.max, count: max(4 - reactants.count, 0))
        let p = products.map(\.0) + repeatElement(UInt32.max, count: max(4 - products.count, 0))
        reactant0 = r[0]; reactant1 = r[1]; reactant2 = r[2]; reactant3 = r[3]
        product0 = p[0]; product1 = p[1]; product2 = p[2]; product3 = p[3]
        reactantStoichiometry = Self.pack(reactants.map(\.1))
        productStoichiometry = Self.pack(products.map(\.1))
        reactantCount = UInt32(reactants.count)
        productCount = UInt32(products.count)
        self.flags = flags
        reserved = 0
        self.rateConstant = rateConstant
        reservedFloat = 0
    }

    private static func pack(_ values: [UInt8]) -> UInt32 {
        var packed: UInt32 = 0
        for (index, value) in values.prefix(4).enumerated() { packed |= UInt32(value) << UInt32(index * 8) }
        return packed
    }
}

@frozen
public struct MetalMolecularNetworkDescriptor: Sendable {
    public var reactionOffset: UInt32
    public var reactionCount: UInt32
    public var speciesCount: UInt32
    public var flags: UInt32
    public var deterministicThreshold: Float
    public var tauEpsilon: Float
    public var maximumTau: Float
    public var reserved: Float

    public init(reactionOffset: UInt32, reactionCount: UInt32, speciesCount: UInt32, flags: UInt32 = 0, deterministicThreshold: Float = 10_000, tauEpsilon: Float = 0.03, maximumTau: Float = 0.001) {
        self.reactionOffset = reactionOffset
        self.reactionCount = reactionCount
        self.speciesCount = speciesCount
        self.flags = flags
        self.deterministicThreshold = deterministicThreshold
        self.tauEpsilon = tauEpsilon
        self.maximumTau = maximumTau
        self.reserved = 0
    }
}

@frozen
public struct MetalMolecularDomainDescriptor: Sendable {
    public var networkIndex: UInt32
    public var speciesOffset: UInt32
    public var solverKind: UInt32
    public var flags: UInt32
    public var volumeLiters: Float
    public var temperatureKelvin: Float
    public var timeSeconds: Float
    public var reserved: Float

    public init(networkIndex: UInt32, speciesOffset: UInt32, solverKind: MetalMolecularSolverKind, flags: UInt32 = 0, volumeLiters: Float, temperatureKelvin: Float = 310.15, timeSeconds: Float = 0) {
        self.networkIndex = networkIndex
        self.speciesOffset = speciesOffset
        self.solverKind = solverKind.rawValue
        self.flags = flags
        self.volumeLiters = volumeLiters
        self.temperatureKelvin = temperatureKelvin
        self.timeSeconds = timeSeconds
        self.reserved = 0
    }
}

@frozen
public struct MetalMolecularExecutionParameters: Sendable {
    public var values: SIMD4<UInt32>
    public var timing: SIMD4<Float>

    public init(domainCount: UInt32, maximumFirings: UInt32, seedLo: UInt32, seedHi: UInt32, dtSeconds: Float, minimumTauSeconds: Float, maximumTauSeconds: Float) {
        values = SIMD4(domainCount, maximumFirings, seedLo, seedHi)
        timing = SIMD4(dtSeconds, minimumTauSeconds, maximumTauSeconds, 0)
    }
}

@frozen
public struct MetalMolecularExecutionStatus: Sendable, Hashable, Codable {
    public var faultCode: UInt32
    public var solverUsed: UInt32
    public var reactionFirings: UInt32
    public var rejectedLeaps: UInt32
    public var advancedTimeSeconds: Float
    public var minimumSpecies: Float
    public var totalPropensity: Float
    public var reserved: Float

    public init() {
        faultCode = 0; solverUsed = 0; reactionFirings = 0; rejectedLeaps = 0
        advancedTimeSeconds = 0; minimumSpecies = 0; totalPropensity = 0; reserved = 0
    }
}

public struct MetalMolecularArchive: Sendable {
    public var networks: [MetalMolecularNetworkDescriptor]
    public var reactions: [MetalMolecularReactionDescriptor]
    public var sourcePrograms: [MolecularProgramIR]
    public var initialSpeciesByNetwork: [[Float]]
    public var speciesIndices: [[String: UInt16]]

    public init(compiling programs: [MolecularProgramIR]) throws {
        guard !programs.isEmpty else { throw MetalMolecularArchiveError.empty }
        networks = []
        reactions = []
        sourcePrograms = []
        initialSpeciesByNetwork = []
        speciesIndices = []
        for source in programs { try append(try source.validated()) }
        try validateLayouts()
    }

    public func makeDomains(_ specifications: [MetalMolecularDomainSpecification]) throws -> MetalMolecularDomainSet {
        var descriptors: [MetalMolecularDomainDescriptor] = []
        var species: [Float] = []
        descriptors.reserveCapacity(specifications.count)
        for specification in specifications {
            guard specification.networkIndex >= 0, specification.networkIndex < networks.count else { throw MetalMolecularArchiveError.invalidNetwork(specification.networkIndex) }
            let network = networks[specification.networkIndex]
            let initial = specification.initialSpecies ?? initialSpeciesByNetwork[specification.networkIndex]
            guard initial.count == Int(network.speciesCount) else { throw MetalMolecularArchiveError.speciesCount }
            guard initial.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw MetalMolecularArchiveError.invalidSpecies }
            guard specification.volumeLiters.isFinite, specification.volumeLiters > 0 else { throw MetalMolecularArchiveError.invalidVolume }
            let offset = UInt32(clamping: species.count)
            species.append(contentsOf: initial)
            descriptors.append(MetalMolecularDomainDescriptor(
                networkIndex: UInt32(specification.networkIndex),
                speciesOffset: offset,
                solverKind: specification.solverKind,
                flags: specification.flags,
                volumeLiters: specification.volumeLiters,
                temperatureKelvin: specification.temperatureKelvin,
                timeSeconds: specification.timeSeconds
            ))
        }
        return MetalMolecularDomainSet(descriptors: descriptors, species: species)
    }

    private mutating func append(_ source: MolecularProgramIR) throws {
        guard source.species.count <= 64 else { throw MetalMolecularArchiveError.speciesCapacity(source.species.count) }
        let reactionOffset = UInt32(clamping: reactions.count)
        let indices = source.speciesIndex
        for reaction in source.reactions {
            guard reaction.rateLaw == .massAction else { throw MetalMolecularArchiveError.expressionRate(reaction.id) }
            try appendReaction(id: reaction.id, reactants: reaction.reactants, products: reaction.products, rate: reaction.rateConstant, flags: reaction.flags, indices: indices)
            if reaction.reversible && reaction.reverseRateConstant > 0 {
                try appendReaction(id: "\(reaction.id).reverse", reactants: reaction.products, products: reaction.reactants, rate: reaction.reverseRateConstant, flags: reaction.flags | 2, indices: indices)
            }
        }
        networks.append(MetalMolecularNetworkDescriptor(
            reactionOffset: reactionOffset,
            reactionCount: UInt32(clamping: reactions.count) - reactionOffset,
            speciesCount: UInt32(source.species.count)
        ))
        sourcePrograms.append(source)
        initialSpeciesByNetwork.append(source.species.map { Float($0.initialAmount) })
        speciesIndices.append(indices)
    }

    private mutating func appendReaction(
        id: String,
        reactants: [MolecularStoichiometryIR],
        products: [MolecularStoichiometryIR],
        rate: Double,
        flags: UInt32,
        indices: [String: UInt16]
    ) throws {
        guard reactants.count <= 4, products.count <= 4 else { throw MetalMolecularArchiveError.reactionArity(id) }
        guard rate.isFinite, rate >= 0, rate <= Double(Float.greatestFiniteMagnitude) else { throw MetalMolecularArchiveError.invalidRate(id) }
        let loweredReactants = try reactants.map { term -> (UInt32, UInt8) in
            guard let index = indices[term.speciesID] else { throw MetalMolecularArchiveError.unknownSpecies(term.speciesID) }
            return (UInt32(index), term.stoichiometry)
        }
        let loweredProducts = try products.map { term -> (UInt32, UInt8) in
            guard let index = indices[term.speciesID] else { throw MetalMolecularArchiveError.unknownSpecies(term.speciesID) }
            return (UInt32(index), term.stoichiometry)
        }
        reactions.append(MetalMolecularReactionDescriptor(reactants: loweredReactants, products: loweredProducts, flags: flags, rateConstant: Float(rate)))
    }

    private func validateLayouts() throws {
        guard MemoryLayout<MetalMolecularReactionDescriptor>.stride == 64 else { throw MetalMolecularArchiveError.layout("reaction") }
        guard MemoryLayout<MetalMolecularNetworkDescriptor>.stride == 32 else { throw MetalMolecularArchiveError.layout("network") }
        guard MemoryLayout<MetalMolecularDomainDescriptor>.stride == 32 else { throw MetalMolecularArchiveError.layout("domain") }
        guard MemoryLayout<MetalMolecularExecutionParameters>.stride == 32 else { throw MetalMolecularArchiveError.layout("parameters") }
        guard MemoryLayout<MetalMolecularExecutionStatus>.stride == 32 else { throw MetalMolecularArchiveError.layout("status") }
    }
}

public struct MetalMolecularDomainSpecification: Sendable, Hashable, Codable {
    public var networkIndex: Int
    public var solverKind: MetalMolecularSolverKind
    public var flags: UInt32
    public var volumeLiters: Float
    public var temperatureKelvin: Float
    public var timeSeconds: Float
    public var initialSpecies: [Float]?

    public init(networkIndex: Int, solverKind: MetalMolecularSolverKind = .automatic, flags: UInt32 = 0, volumeLiters: Float, temperatureKelvin: Float = 310.15, timeSeconds: Float = 0, initialSpecies: [Float]? = nil) {
        self.networkIndex = networkIndex
        self.solverKind = solverKind
        self.flags = flags
        self.volumeLiters = volumeLiters
        self.temperatureKelvin = temperatureKelvin
        self.timeSeconds = timeSeconds
        self.initialSpecies = initialSpecies
    }
}

public struct MetalMolecularDomainSet: Sendable {
    public var descriptors: [MetalMolecularDomainDescriptor]
    public var species: [Float]

    public init(descriptors: [MetalMolecularDomainDescriptor], species: [Float]) {
        self.descriptors = descriptors
        self.species = species
    }
}

public enum MetalMolecularArchiveError: Error, Sendable, CustomStringConvertible {
    case empty
    case speciesCapacity(Int)
    case expressionRate(String)
    case reactionArity(String)
    case invalidRate(String)
    case unknownSpecies(String)
    case invalidNetwork(Int)
    case speciesCount
    case invalidSpecies
    case invalidVolume
    case layout(String)

    public var description: String {
        switch self {
        case .empty: return "Metal molecular archive is empty"
        case .speciesCapacity(let value): return "Molecular network has \(value) species; the Metal microdomain ABI supports 64"
        case .expressionRate(let value): return "Reaction \(value) uses an expression rate law unsupported by the stochastic Metal kernel"
        case .reactionArity(let value): return "Reaction \(value) exceeds four reactants or products"
        case .invalidRate(let value): return "Reaction \(value) has an invalid rate"
        case .unknownSpecies(let value): return "Molecular reaction references unknown species \(value)"
        case .invalidNetwork(let value): return "Invalid molecular network index \(value)"
        case .speciesCount: return "Molecular domain initial species count is incorrect"
        case .invalidSpecies: return "Molecular domain contains negative or non-finite species"
        case .invalidVolume: return "Molecular domain volume must be positive and finite"
        case .layout(let value): return "Host and Metal molecular ABI disagree for \(value)"
        }
    }
}
#endif
