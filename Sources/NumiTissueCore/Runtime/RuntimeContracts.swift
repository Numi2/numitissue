import Foundation

// MARK: - Stable runtime vocabulary

@frozen
public struct NTVector3: Codable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    @inlinable
    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = NTVector3()

    @inlinable public static func + (lhs: Self, rhs: Self) -> Self {
        Self(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    @inlinable public static func - (lhs: Self, rhs: Self) -> Self {
        Self(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    @inlinable public static func * (lhs: Self, rhs: Float) -> Self {
        Self(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    @inlinable public static func / (lhs: Self, rhs: Float) -> Self {
        Self(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    @inlinable public var squaredLength: Float { x * x + y * y + z * z }
    @inlinable public var length: Float { sqrt(squaredLength) }

    @inlinable
    public func normalized(or fallback: Self = Self(1, 0, 0)) -> Self {
        let magnitude = length
        return magnitude > 1.0e-12 ? self / magnitude : fallback
    }

    @inlinable
    public static func dot(_ a: Self, _ b: Self) -> Float {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inlinable
    public static func cross(_ a: Self, _ b: Self) -> Self {
        Self(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }
}

public enum NTExecutionProfile: String, Codable, CaseIterable, Sendable {
    case deterministic
    case production
    case scientific
}

public enum NTClockMode: String, Codable, CaseIterable, Sendable {
    case embodied
    case developmental
    case protocolValidation
}

public enum NTFidelityLevel: UInt8, Codable, CaseIterable, Comparable, Sendable {
    case fieldOnly = 0
    case cellAgent = 1
    case reducedElectrical = 2
    case detailedElectrical = 3
    case molecularDetailed = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum NTTransactionStatus: String, Codable, Sendable {
    case committed
    case committedWithPromotion
    case substepped
    case capacityLimited
    case rejectedNumerical
    case rejectedBiologicalBounds
    case rejectedEventOverflow
    case invalidModel
}

public enum NTDiagnosticSeverity: UInt8, Codable, Comparable, Sendable {
    case information = 0
    case warning = 1
    case error = 2
    case fatal = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum NTDiagnosticCode: String, Codable, Sendable {
    case nonFiniteState
    case concentrationBelowZero
    case voltageOutsideBounds
    case invalidMorphology
    case invalidReference
    case eventQueueOverflow
    case fieldConservationFailure
    case negativeMoleculeCount
    case invalidCellVolume
    case cellOverlapExceeded
    case topologyMutationConflict
    case spikeOrderingFailure
    case invalidEventDestination
    case plasticityWeightOutsideBounds
    case metabolicDemandInvalid
    case incompleteShadowState
    case resourceBudgetExceeded
    case backendUnavailable
    case unsupportedFeature
}

@frozen
public struct NTDiagnostic: Codable, Hashable, Sendable {
    public var severity: NTDiagnosticSeverity
    public var code: NTDiagnosticCode
    public var message: String
    public var entity: UInt64?
    public var tile: TileID?

    public init(
        severity: NTDiagnosticSeverity,
        code: NTDiagnosticCode,
        message: String,
        entity: UInt64? = nil,
        tile: TileID? = nil
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.entity = entity
        self.tile = tile
    }
}

@frozen
public struct NTResourceBudget: Codable, Hashable, Sendable {
    public var maximumTiles: Int
    public var maximumCellsPerTile: Int
    public var maximumSegmentsPerTile: Int
    public var maximumCompartmentsPerTile: Int
    public var maximumExplicitSynapsesPerTile: Int
    public var maximumMicrodomainsPerTile: Int
    public var maximumEventsPerBlockPerTile: Int
    public var maximumResidentBytes: UInt64

    public init(
        maximumTiles: Int = 125,
        maximumCellsPerTile: Int = 512,
        maximumSegmentsPerTile: Int = 16_384,
        maximumCompartmentsPerTile: Int = 8_192,
        maximumExplicitSynapsesPerTile: Int = 131_072,
        maximumMicrodomainsPerTile: Int = 256,
        maximumEventsPerBlockPerTile: Int = 65_536,
        maximumResidentBytes: UInt64 = 12 * 1_024 * 1_024 * 1_024
    ) {
        self.maximumTiles = maximumTiles
        self.maximumCellsPerTile = maximumCellsPerTile
        self.maximumSegmentsPerTile = maximumSegmentsPerTile
        self.maximumCompartmentsPerTile = maximumCompartmentsPerTile
        self.maximumExplicitSynapsesPerTile = maximumExplicitSynapsesPerTile
        self.maximumMicrodomainsPerTile = maximumMicrodomainsPerTile
        self.maximumEventsPerBlockPerTile = maximumEventsPerBlockPerTile
        self.maximumResidentBytes = maximumResidentBytes
    }

    public func validate() throws {
        guard maximumTiles > 0,
              maximumCellsPerTile > 0,
              maximumSegmentsPerTile > 0,
              maximumCompartmentsPerTile > 0,
              maximumExplicitSynapsesPerTile > 0,
              maximumMicrodomainsPerTile >= 0,
              maximumEventsPerBlockPerTile > 0,
              maximumResidentBytes > 0 else {
            throw NTRuntimeError.invalidConfiguration("Resource limits must be positive.")
        }
    }
}

@frozen
public struct NTWorldConfiguration: Codable, Hashable, Sendable {
    public var executionProfile: NTExecutionProfile
    public var clockMode: NTClockMode
    public var seed: UInt64
    public var originMicrometers: NTVector3
    public var tileEdgeMicrometers: Float
    public var fieldResolution: Int
    public var fastQuantumTicks: UInt64
    public var communicationBlockTicks: UInt64
    public var transactionTicks: UInt64
    public var voltageMinimumMillivolts: Float
    public var voltageMaximumMillivolts: Float
    public var maximumCellOverlapFraction: Float
    public var fieldMassRelativeTolerance: Float
    public var resourceBudget: NTResourceBudget

    public init(
        executionProfile: NTExecutionProfile = .production,
        clockMode: NTClockMode = .embodied,
        seed: UInt64 = 0x4E_55_4D_49_54_49_53_53,
        originMicrometers: NTVector3 = .zero,
        tileEdgeMicrometers: Float = 200,
        fieldResolution: Int = 32,
        fastQuantumTicks: UInt64 = 1,
        communicationBlockTicks: UInt64 = 10,
        transactionTicks: UInt64 = 200,
        voltageMinimumMillivolts: Float = -200,
        voltageMaximumMillivolts: Float = 100,
        maximumCellOverlapFraction: Float = 0.35,
        fieldMassRelativeTolerance: Float = 1.0e-5,
        resourceBudget: NTResourceBudget = .init()
    ) {
        self.executionProfile = executionProfile
        self.clockMode = clockMode
        self.seed = seed
        self.originMicrometers = originMicrometers
        self.tileEdgeMicrometers = tileEdgeMicrometers
        self.fieldResolution = fieldResolution
        self.fastQuantumTicks = fastQuantumTicks
        self.communicationBlockTicks = communicationBlockTicks
        self.transactionTicks = transactionTicks
        self.voltageMinimumMillivolts = voltageMinimumMillivolts
        self.voltageMaximumMillivolts = voltageMaximumMillivolts
        self.maximumCellOverlapFraction = maximumCellOverlapFraction
        self.fieldMassRelativeTolerance = fieldMassRelativeTolerance
        self.resourceBudget = resourceBudget
    }

    public var fastQuantumSeconds: Float {
        Float(fastQuantumTicks * TissueTime.quantumMicroseconds) * 1.0e-6
    }

    public var transactionMilliseconds: Double {
        TissueTime(tick: transactionTicks).milliseconds
    }

    public func validate() throws {
        try resourceBudget.validate()
        guard tileEdgeMicrometers > 0 else {
            throw NTRuntimeError.invalidConfiguration("Tile edge must be positive.")
        }
        guard fieldResolution > 1 && fieldResolution.isMultiple(of: 2) else {
            throw NTRuntimeError.invalidConfiguration("Field resolution must be even and greater than one.")
        }
        guard fastQuantumTicks > 0,
              communicationBlockTicks >= fastQuantumTicks,
              communicationBlockTicks.isMultiple(of: fastQuantumTicks),
              transactionTicks >= communicationBlockTicks,
              transactionTicks.isMultiple(of: communicationBlockTicks) else {
            throw NTRuntimeError.invalidConfiguration("Clock intervals must form an integer hierarchy.")
        }
        guard voltageMinimumMillivolts < voltageMaximumMillivolts else {
            throw NTRuntimeError.invalidConfiguration("Voltage bounds are reversed.")
        }
        guard maximumCellOverlapFraction >= 0 && maximumCellOverlapFraction < 1 else {
            throw NTRuntimeError.invalidConfiguration("Cell-overlap threshold must be in [0, 1).")
        }
        guard fieldMassRelativeTolerance > 0 else {
            throw NTRuntimeError.invalidConfiguration("Field tolerance must be positive.")
        }
    }
}

public enum NTStimulusKind: String, Codable, Sendable {
    case intracellularCurrent
    case extracellularElectrode
    case optogenetic
    case chemical
    case sensorySpike
    case neuromodulator
}

@frozen
public struct NTStimulus: Codable, Hashable, Sendable {
    public var kind: NTStimulusKind
    public var target: UInt64
    public var start: TissueTime
    public var durationTicks: UInt64
    public var amplitude: Float
    public var secondaryAmplitude: Float
    public var channel: UInt16

    public init(
        kind: NTStimulusKind,
        target: UInt64,
        start: TissueTime,
        durationTicks: UInt64,
        amplitude: Float,
        secondaryAmplitude: Float = 0,
        channel: UInt16 = 0
    ) {
        self.kind = kind
        self.target = target
        self.start = start
        self.durationTicks = durationTicks
        self.amplitude = amplitude
        self.secondaryAmplitude = secondaryAmplitude
        self.channel = channel
    }
}

@frozen
public struct NTNeuromodulators: Codable, Hashable, Sendable {
    public var dopamine: Float
    public var acetylcholine: Float
    public var norepinephrine: Float
    public var serotonin: Float
    public var painThreat: Float
    public var novelty: Float

    public init(
        dopamine: Float = 0,
        acetylcholine: Float = 0,
        norepinephrine: Float = 0,
        serotonin: Float = 0,
        painThreat: Float = 0,
        novelty: Float = 0
    ) {
        self.dopamine = dopamine
        self.acetylcholine = acetylcholine
        self.norepinephrine = norepinephrine
        self.serotonin = serotonin
        self.painThreat = painThreat
        self.novelty = novelty
    }

    @inlinable
    public var plasticityGain: Float {
        dopamine + 0.35 * acetylcholine + 0.2 * norepinephrine + 0.1 * novelty - 0.15 * serotonin
    }
}

@frozen
public struct NTMechanicalBoundarySample: Codable, Hashable, Sendable {
    public var tile: TileID
    public var deformationGradientRow0: NTVector3
    public var deformationGradientRow1: NTVector3
    public var deformationGradientRow2: NTVector3
    public var pressurePascals: Float
    public var damage: Float
    public var temperatureKelvin: Float

    public init(
        tile: TileID,
        deformationGradientRow0: NTVector3 = .init(1, 0, 0),
        deformationGradientRow1: NTVector3 = .init(0, 1, 0),
        deformationGradientRow2: NTVector3 = .init(0, 0, 1),
        pressurePascals: Float = 0,
        damage: Float = 0,
        temperatureKelvin: Float = 310.15
    ) {
        self.tile = tile
        self.deformationGradientRow0 = deformationGradientRow0
        self.deformationGradientRow1 = deformationGradientRow1
        self.deformationGradientRow2 = deformationGradientRow2
        self.pressurePascals = pressurePascals
        self.damage = damage
        self.temperatureKelvin = temperatureKelvin
    }
}

@frozen
public struct NTMetabolicBoundarySample: Codable, Hashable, Sendable {
    public var tile: TileID
    public var oxygenMillimolar: Float
    public var glucoseMillimolar: Float
    public var lactateMillimolar: Float
    public var perfusionPerSecond: Float

    public init(
        tile: TileID,
        oxygenMillimolar: Float,
        glucoseMillimolar: Float,
        lactateMillimolar: Float = 0,
        perfusionPerSecond: Float
    ) {
        self.tile = tile
        self.oxygenMillimolar = oxygenMillimolar
        self.glucoseMillimolar = glucoseMillimolar
        self.lactateMillimolar = lactateMillimolar
        self.perfusionPerSecond = perfusionPerSecond
    }
}

@frozen
public struct NTStepInput: Codable, Sendable {
    public var requestedDurationTicks: UInt64
    public var stimuli: [NTStimulus]
    public var modulators: NTNeuromodulators
    public var mechanicalBoundary: [NTMechanicalBoundarySample]
    public var metabolicBoundary: [NTMetabolicBoundarySample]
    public var behavioralContext: [String: Float]

    public init(
        requestedDurationTicks: UInt64 = 200,
        stimuli: [NTStimulus] = [],
        modulators: NTNeuromodulators = .init(),
        mechanicalBoundary: [NTMechanicalBoundarySample] = [],
        metabolicBoundary: [NTMetabolicBoundarySample] = [],
        behavioralContext: [String: Float] = [:]
    ) {
        self.requestedDurationTicks = requestedDurationTicks
        self.stimuli = stimuli
        self.modulators = modulators
        self.mechanicalBoundary = mechanicalBoundary
        self.metabolicBoundary = metabolicBoundary
        self.behavioralContext = behavioralContext
    }
}

@frozen
public struct NTSpike: Codable, Hashable, Sendable, Comparable {
    public var time: TissueTime
    public var sourceCompartment: CompartmentID
    public var route: RouteID
    public var amplitude: Float

    public init(time: TissueTime, sourceCompartment: CompartmentID, route: RouteID, amplitude: Float = 1) {
        self.time = time
        self.sourceCompartment = sourceCompartment
        self.route = route
        self.amplitude = amplitude
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.route != rhs.route { return lhs.route < rhs.route }
        return lhs.sourceCompartment < rhs.sourceCompartment
    }
}

@frozen
public struct NTPopulationSample: Codable, Hashable, Sendable {
    public var population: PopulationID
    public var firingRateHertz: Float
    public var meanVoltageMillivolts: Float
    public var synchrony: Float
    public var calcium: Float
    public var uncertainty: Float

    public init(
        population: PopulationID,
        firingRateHertz: Float,
        meanVoltageMillivolts: Float,
        synchrony: Float,
        calcium: Float,
        uncertainty: Float
    ) {
        self.population = population
        self.firingRateHertz = firingRateHertz
        self.meanVoltageMillivolts = meanVoltageMillivolts
        self.synchrony = synchrony
        self.calcium = calcium
        self.uncertainty = uncertainty
    }
}

@frozen
public struct NTFieldSample: Codable, Hashable, Sendable {
    public var tile: TileID
    public var species: UInt16
    public var mean: Float
    public var minimum: Float
    public var maximum: Float

    public init(tile: TileID, species: UInt16, mean: Float, minimum: Float, maximum: Float) {
        self.tile = tile
        self.species = species
        self.mean = mean
        self.minimum = minimum
        self.maximum = maximum
    }
}

@frozen
public struct NTStepOutput: Codable, Sendable {
    public var startTime: TissueTime
    public var endTime: TissueTime
    public var spikes: [NTSpike]
    public var populations: [NTPopulationSample]
    public var fields: [NTFieldSample]
    public var motorChannels: [UInt16: Float]
    public var autonomicChannels: [UInt16: Float]
    public var metabolicDemandWatts: Float
    public var diagnostics: [NTDiagnostic]

    public init(
        startTime: TissueTime,
        endTime: TissueTime,
        spikes: [NTSpike] = [],
        populations: [NTPopulationSample] = [],
        fields: [NTFieldSample] = [],
        motorChannels: [UInt16: Float] = [:],
        autonomicChannels: [UInt16: Float] = [:],
        metabolicDemandWatts: Float = 0,
        diagnostics: [NTDiagnostic] = []
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.spikes = spikes
        self.populations = populations
        self.fields = fields
        self.motorChannels = motorChannels
        self.autonomicChannels = autonomicChannels
        self.metabolicDemandWatts = metabolicDemandWatts
        self.diagnostics = diagnostics
    }
}

@frozen
public struct NTStepReport: Codable, Sendable {
    public var transaction: TransactionID
    public var status: NTTransactionStatus
    public var output: NTStepOutput
    public var substeps: UInt32
    public var promotedTiles: [TileID]
    public var demotedTiles: [TileID]
    public var residentBytes: UInt64

    public init(
        transaction: TransactionID,
        status: NTTransactionStatus,
        output: NTStepOutput,
        substeps: UInt32,
        promotedTiles: [TileID] = [],
        demotedTiles: [TileID] = [],
        residentBytes: UInt64 = 0
    ) {
        self.transaction = transaction
        self.status = status
        self.output = output
        self.substeps = substeps
        self.promotedTiles = promotedTiles
        self.demotedTiles = demotedTiles
        self.residentBytes = residentBytes
    }
}

@frozen
public struct NTBackendCapabilities: Codable, Hashable, Sendable {
    public var name: String
    public var supportsGPU: Bool
    public var supportsDeterministicReplay: Bool
    public var supportsMolecularMicrodomains: Bool
    public var supportsDynamicTopology: Bool
    public var maximumRecommendedTiles: Int

    public init(
        name: String,
        supportsGPU: Bool,
        supportsDeterministicReplay: Bool = true,
        supportsMolecularMicrodomains: Bool = true,
        supportsDynamicTopology: Bool = true,
        maximumRecommendedTiles: Int
    ) {
        self.name = name
        self.supportsGPU = supportsGPU
        self.supportsDeterministicReplay = supportsDeterministicReplay
        self.supportsMolecularMicrodomains = supportsMolecularMicrodomains
        self.supportsDynamicTopology = supportsDynamicTopology
        self.maximumRecommendedTiles = maximumRecommendedTiles
    }
}

public protocol NTTissueBackend: Sendable {
    var capabilities: NTBackendCapabilities { get async }
    func configure(_ configuration: NTWorldConfiguration) async throws
    func load(snapshot: NTWorldSnapshot) async throws
    func step(_ input: NTStepInput) async throws -> NTStepReport
    func snapshot() async throws -> NTWorldSnapshot
    func reset() async
}

public enum NTRuntimeError: Error, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case invalidModel(String)
    case resourceExhausted(String)
    case backendUnavailable(String)
    case transactionRejected(NTTransactionStatus, [NTDiagnostic])
    case snapshotIncompatible(String)
    case internalInvariant(String)

    public var description: String {
        switch self {
        case let .invalidConfiguration(message): return "Invalid configuration: \(message)"
        case let .invalidModel(message): return "Invalid model: \(message)"
        case let .resourceExhausted(message): return "Resource exhausted: \(message)"
        case let .backendUnavailable(message): return "Backend unavailable: \(message)"
        case let .transactionRejected(status, diagnostics):
            return "Transaction rejected with \(status.rawValue): \(diagnostics.map(\.message).joined(separator: "; "))"
        case let .snapshotIncompatible(message): return "Snapshot incompatible: \(message)"
        case let .internalInvariant(message): return "Internal invariant failed: \(message)"
        }
    }
}
