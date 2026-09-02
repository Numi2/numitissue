import Foundation

public enum TissueStepStatus: String, Codable, Sendable {
    case committed
    case committedWithPromotion
    case substepped
    case capacityLimited
    case rejectedNumerical
    case rejectedBiologicalBounds
    case rejectedEventOverflow
    case invalidModel
}

public enum ValidationCode: UInt32, Codable, Sendable, CaseIterable {
    case none = 0
    case nonFinite = 1
    case negativeConcentration = 2
    case voltageOutOfBounds = 3
    case invalidCompartmentTree = 4
    case eventOverflow = 5
    case fieldMassError = 6
    case negativeMoleculeCount = 7
    case invalidCellVolume = 8
    case excessiveCellOverlap = 9
    case invalidTopologyMutation = 10
    case unorderedEventTimestamp = 11
    case invalidRoute = 12
    case weightOutOfBounds = 13
    case invalidMetabolicDemand = 14
    case incompleteShadowState = 15
}

@frozen
public struct ValidationFailure: Codable, Sendable, Hashable {
    public var code: ValidationCode
    public var tile: TileCoordinate?
    public var entityIndex: UInt32?
    public var measured: Double?
    public var limit: Double?
    public var message: String

    public init(
        code: ValidationCode,
        tile: TileCoordinate? = nil,
        entityIndex: UInt32? = nil,
        measured: Double? = nil,
        limit: Double? = nil,
        message: String
    ) {
        self.code = code
        self.tile = tile
        self.entityIndex = entityIndex
        self.measured = measured
        self.limit = limit
        self.message = message
    }
}

@frozen
public struct TissueStepMetrics: Codable, Sendable, Hashable {
    public var transactionIndex: UInt64
    public var activeTiles: UInt32
    public var activeCompartments: UInt64
    public var deliveredEvents: UInt64
    public var emittedSpikes: UInt64
    public var fieldVoxelsUpdated: UInt64
    public var molecularReactions: UInt64
    public var structuralMutations: UInt64
    public var promotedEntities: UInt64
    public var demotedEntities: UInt64
    public var gpuDurationMicroseconds: Double?

    public init(transactionIndex: UInt64 = 0) {
        self.transactionIndex = transactionIndex
        self.activeTiles = 0
        self.activeCompartments = 0
        self.deliveredEvents = 0
        self.emittedSpikes = 0
        self.fieldVoxelsUpdated = 0
        self.molecularReactions = 0
        self.structuralMutations = 0
        self.promotedEntities = 0
        self.demotedEntities = 0
        self.gpuDurationMicroseconds = nil
    }
}

@frozen
public struct AnalogCurrentInput: Sendable {
    public var compartment: UInt32
    public var currentNanoamps: Float

    public init(compartment: UInt32, currentNanoamps: Float) {
        self.compartment = compartment
        self.currentNanoamps = currentNanoamps
    }
}

@frozen
public struct MetabolicBoundary: Sendable {
    public var oxygen: Float
    public var glucose: Float
    public var temperatureCelsius: Float
    public var perfusion: Float

    public init(oxygen: Float = 0.2, glucose: Float = 1, temperatureCelsius: Float = 37, perfusion: Float = 1) {
        self.oxygen = oxygen
        self.glucose = glucose
        self.temperatureCelsius = temperatureCelsius
        self.perfusion = perfusion
    }
}

@frozen
public struct MechanicalBoundary: Sendable {
    public var strain: Float4
    public var pressure: Float
    public var damage: Float

    public init(strain: Float4 = .zero, pressure: Float = 0, damage: Float = 0) {
        self.strain = strain
        self.pressure = pressure
        self.damage = damage
    }
}

public enum ReadoutKind: UInt8, Sendable {
    case spikes
    case populationRate
    case localFieldPotential
    case metabolism
    case damage
    case fieldSlice
}

@frozen
public struct ReadoutRequest: Sendable {
    public var kind: ReadoutKind
    public var population: UInt64

    public init(kind: ReadoutKind, population: UInt64 = 0) {
        self.kind = kind
        self.population = population
    }
}

@frozen
public struct TissueInput: Sendable {
    public var afferentEvents: [GPUEvent]
    public var analogCurrents: [AnalogCurrentInput]
    public var neuromodulators: Float4
    public var hormoneState: Float4
    public var metabolicBoundary: MetabolicBoundary
    public var mechanicalBoundary: MechanicalBoundary
    public var requestedReadouts: [ReadoutRequest]

    public init(
        afferentEvents: [GPUEvent] = [],
        analogCurrents: [AnalogCurrentInput] = [],
        neuromodulators: Float4 = .zero,
        hormoneState: Float4 = .zero,
        metabolicBoundary: MetabolicBoundary = .init(),
        mechanicalBoundary: MechanicalBoundary = .init(),
        requestedReadouts: [ReadoutRequest] = []
    ) {
        self.afferentEvents = afferentEvents
        self.analogCurrents = analogCurrents
        self.neuromodulators = neuromodulators
        self.hormoneState = hormoneState
        self.metabolicBoundary = metabolicBoundary
        self.mechanicalBoundary = mechanicalBoundary
        self.requestedReadouts = requestedReadouts
    }
}

@frozen
public struct PopulationSummary: Sendable {
    public var population: PopulationID
    public var firingRateHz: Float
    public var synchrony: Float
    public var meanVoltage: Float
    public var uncertainty: Float

    public init(population: PopulationID, firingRateHz: Float, synchrony: Float, meanVoltage: Float, uncertainty: Float) {
        self.population = population
        self.firingRateHz = firingRateHz
        self.synchrony = synchrony
        self.meanVoltage = meanVoltage
        self.uncertainty = uncertainty
    }
}

@frozen
public struct DamageEvent: Sendable {
    public var cell: CellID
    public var severity: Float
    public var mechanism: UInt16

    public init(cell: CellID, severity: Float, mechanism: UInt16) {
        self.cell = cell
        self.severity = severity
        self.mechanism = mechanism
    }
}

@frozen
public struct TissueOutput: Sendable {
    public var efferentEvents: [GPUEvent]
    public var populationSummaries: [PopulationSummary]
    public var localFieldPotentials: [Float]
    public var metabolicDemand: Float
    public var damageEvents: [DamageEvent]

    public init(
        efferentEvents: [GPUEvent] = [],
        populationSummaries: [PopulationSummary] = [],
        localFieldPotentials: [Float] = [],
        metabolicDemand: Float = 0,
        damageEvents: [DamageEvent] = []
    ) {
        self.efferentEvents = efferentEvents
        self.populationSummaries = populationSummaries
        self.localFieldPotentials = localFieldPotentials
        self.metabolicDemand = metabolicDemand
        self.damageEvents = damageEvents
    }
}

@frozen
public struct TissueStepResult: Sendable {
    public var status: TissueStepStatus
    public var committedTime: TissueTime
    public var metrics: TissueStepMetrics
    public var failures: [ValidationFailure]
    public var output: TissueOutput

    public init(
        status: TissueStepStatus,
        committedTime: TissueTime,
        metrics: TissueStepMetrics,
        failures: [ValidationFailure] = [],
        output: TissueOutput = .init()
    ) {
        self.status = status
        self.committedTime = committedTime
        self.metrics = metrics
        self.failures = failures
        self.output = output
    }
}

public enum TransactionDecision: Sendable {
    case commit
    case rollback(reason: TissueStepStatus)
    case retryWithSubsteps(count: UInt32)
}

@frozen
public struct TransactionContext: Sendable {
    public let id: TransactionID
    public let startTime: TissueTime
    public let targetTime: TissueTime
    public let index: UInt64
    public let seed: UInt64

    public init(id: TransactionID, startTime: TissueTime, targetTime: TissueTime, index: UInt64, seed: UInt64) {
        self.id = id
        self.startTime = startTime
        self.targetTime = targetTime
        self.index = index
        self.seed = seed
    }
}

@frozen
public struct MultiRateClock: Sendable {
    public private(set) var time: TissueTime
    public private(set) var transactionIndex: UInt64
    public let schedule: SchedulerConfiguration

    public init(schedule: SchedulerConfiguration, start: TissueTime = .init()) {
        self.schedule = schedule
        self.time = start
        self.transactionIndex = 0
    }

    public mutating func advanceCommittedTransaction() {
        let ticks = UInt64(schedule.transactionMicroseconds) / TissueTime.quantumMicroseconds
        time = time + ticks
        transactionIndex &+= 1
    }

    public func isDue(periodMicroseconds: UInt64) -> Bool {
        time.microseconds.isMultiple(of: periodMicroseconds)
    }

    public var cellMechanicsDue: Bool { isDue(periodMicroseconds: UInt64(schedule.cellMechanicsMicroseconds)) }
    public var regulatoryDue: Bool { isDue(periodMicroseconds: UInt64(schedule.regulatoryMicroseconds)) }
    public var structuralDue: Bool { isDue(periodMicroseconds: UInt64(schedule.structuralMicroseconds)) }
}

public struct TransactionSequencer: Sendable {
    private var nextValue: UInt64

    public init(startingAt: UInt64 = 1) { self.nextValue = startingAt }

    public mutating func next(time: TissueTime, schedule: SchedulerConfiguration, seed: UInt64) -> TransactionContext {
        let id = TransactionID(rawValue: nextValue)
        let transactionTicks = UInt64(schedule.transactionMicroseconds) / TissueTime.quantumMicroseconds
        let context = TransactionContext(
            id: id,
            startTime: time,
            targetTime: time + transactionTicks,
            index: nextValue - 1,
            seed: seed
        )
        nextValue &+= 1
        return context
    }
}

@inlinable
public func alignUp(_ value: Int, to alignment: Int) -> Int {
    precondition(alignment > 0 && alignment.nonzeroBitCount == 1)
    return (value + alignment - 1) & ~(alignment - 1)
}

public enum GPUABI {
    public static let alignment = 256
    public static let tileHeaderStride = alignUp(MemoryLayout<GPUTileHeader>.stride, to: 16)
    public static let cellStride = alignUp(MemoryLayout<GPUCellState>.stride, to: 16)
    public static let segmentStride = alignUp(MemoryLayout<GPUNeuriteSegment>.stride, to: 16)
    public static let compartmentStride = alignUp(MemoryLayout<GPUCompartmentState>.stride, to: 16)
    public static let synapseStride = alignUp(MemoryLayout<GPUSynapseState>.stride, to: 16)
    public static let fieldVoxelStride = alignUp(MemoryLayout<GPUFieldVoxel>.stride, to: 16)
    public static let eventStride = alignUp(MemoryLayout<GPUEvent>.stride, to: 16)
    public static let microdomainHeaderStride = alignUp(MemoryLayout<GPUMicrodomainHeader>.stride, to: 16)
}

@frozen
public struct PackedSection: Codable, Sendable, Hashable {
    public var offset: UInt64
    public var byteCount: UInt64
    public var stride: UInt32
    public var count: UInt64

    public init(offset: UInt64, byteCount: UInt64, stride: UInt32, count: UInt64) {
        self.offset = offset
        self.byteCount = byteCount
        self.stride = stride
        self.count = count
    }
}

public enum ExecutableSectionKind: String, Codable, Sendable, CaseIterable {
    case metadata
    case tileHeaders
    case cells
    case neuriteSegments
    case compartments
    case synapses
    case fieldVoxels
    case microdomainHeaders
    case molecularSpecies
    case molecularReactions
    case localRoutes
    case longRangeRoutes
    case morphologyLevels
    case mechanismTables
    case populationTables
}

@frozen
public struct ExecutableManifest: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var gpuABIVersion: UInt32
    public var modelName: String
    public var modelHash: String
    public var tileCount: UInt32
    public var sections: [ExecutableSectionKind: PackedSection]

    public init(modelName: String, modelHash: String, tileCount: UInt32, sections: [ExecutableSectionKind: PackedSection]) {
        self.schemaVersion = NumiTissueBuild.modelSchemaVersion
        self.gpuABIVersion = NumiTissueBuild.gpuABIVersion
        self.modelName = modelName
        self.modelHash = modelHash
        self.tileCount = tileCount
        self.sections = sections
    }
}

public enum NumiTissueError: Error, Sendable, CustomStringConvertible {
    case noCompatibleGPU
    case unsupportedPlatform
    case invalidConfiguration(String)
    case invalidModel(String)
    case shaderCompilation(String)
    case pipelineCreation(String)
    case allocationFailure(String)
    case commandEncoding(String)
    case executionFailure(String)
    case snapshotFailure(String)

    public var description: String {
        switch self {
        case .noCompatibleGPU: return "No compatible Metal GPU was found."
        case .unsupportedPlatform: return "This operation is not supported on the current platform."
        case let .invalidConfiguration(value): return "Invalid configuration: \(value)"
        case let .invalidModel(value): return "Invalid model: \(value)"
        case let .shaderCompilation(value): return "Metal shader compilation failed: \(value)"
        case let .pipelineCreation(value): return "Metal pipeline creation failed: \(value)"
        case let .allocationFailure(value): return "GPU allocation failed: \(value)"
        case let .commandEncoding(value): return "GPU command encoding failed: \(value)"
        case let .executionFailure(value): return "GPU execution failed: \(value)"
        case let .snapshotFailure(value): return "Snapshot operation failed: \(value)"
        }
    }
}
