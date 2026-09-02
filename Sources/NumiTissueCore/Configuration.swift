import Foundation

public enum ComputeBackend: String, Codable, Sendable, CaseIterable {
    case automatic
    case metal
    case referenceCPU
}

public enum NumericalProfile: String, Codable, Sendable, CaseIterable {
    case boundedDeterministic
    case scientific
    case developmentalAccelerated
}

public enum GateStoragePrecision: String, Codable, Sendable, CaseIterable {
    case float16
    case float32
}

@frozen
public struct TileConfiguration: Codable, Sendable, Hashable {
    public var edgeMicrometers: Float
    public var fieldGridEdge: UInt32
    public var maximumCells: UInt32
    public var maximumNeuriteSegments: UInt32
    public var maximumCompartments: UInt32
    public var maximumExplicitSynapses: UInt32
    public var maximumMicrodomains: UInt32
    public var eventCapacityPerQuarterMillisecond: UInt32
    public var persistentMemoryBudgetBytes: UInt64

    public init(
        edgeMicrometers: Float = 200,
        fieldGridEdge: UInt32 = 32,
        maximumCells: UInt32 = 512,
        maximumNeuriteSegments: UInt32 = 16_384,
        maximumCompartments: UInt32 = 8_192,
        maximumExplicitSynapses: UInt32 = 131_072,
        maximumMicrodomains: UInt32 = 256,
        eventCapacityPerQuarterMillisecond: UInt32 = 65_536,
        persistentMemoryBudgetBytes: UInt64 = 10 * 1_024 * 1_024
    ) {
        self.edgeMicrometers = edgeMicrometers
        self.fieldGridEdge = fieldGridEdge
        self.maximumCells = maximumCells
        self.maximumNeuriteSegments = maximumNeuriteSegments
        self.maximumCompartments = maximumCompartments
        self.maximumExplicitSynapses = maximumExplicitSynapses
        self.maximumMicrodomains = maximumMicrodomains
        self.eventCapacityPerQuarterMillisecond = eventCapacityPerQuarterMillisecond
        self.persistentMemoryBudgetBytes = persistentMemoryBudgetBytes
    }

    public var fieldVoxelWidthMicrometers: Float {
        edgeMicrometers / Float(fieldGridEdge)
    }

    public func validate() throws {
        guard edgeMicrometers > 0 else { throw ConfigurationError.invalidValue("tile.edgeMicrometers") }
        guard fieldGridEdge >= 4 && fieldGridEdge.isPowerOfTwo else {
            throw ConfigurationError.invalidValue("tile.fieldGridEdge must be a power of two >= 4")
        }
        guard maximumCells > 0, maximumCompartments > 0, maximumExplicitSynapses > 0 else {
            throw ConfigurationError.invalidValue("tile capacities must be positive")
        }
        guard eventCapacityPerQuarterMillisecond >= maximumCells else {
            throw ConfigurationError.invalidValue("event capacity is smaller than cell capacity")
        }
    }
}

@frozen
public struct SchedulerConfiguration: Codable, Sendable, Hashable {
    public var fastQuantumMicroseconds: UInt32
    public var eventBlockMicroseconds: UInt32
    public var transactionMicroseconds: UInt32
    public var cellMechanicsMicroseconds: UInt32
    public var regulatoryMicroseconds: UInt32
    public var structuralMicroseconds: UInt32
    public var maximumAdaptiveSlowStepMicroseconds: UInt64

    public init(
        fastQuantumMicroseconds: UInt32 = 25,
        eventBlockMicroseconds: UInt32 = 250,
        transactionMicroseconds: UInt32 = 5_000,
        cellMechanicsMicroseconds: UInt32 = 100_000,
        regulatoryMicroseconds: UInt32 = 1_000_000,
        structuralMicroseconds: UInt32 = 10_000_000,
        maximumAdaptiveSlowStepMicroseconds: UInt64 = 60_000_000
    ) {
        self.fastQuantumMicroseconds = fastQuantumMicroseconds
        self.eventBlockMicroseconds = eventBlockMicroseconds
        self.transactionMicroseconds = transactionMicroseconds
        self.cellMechanicsMicroseconds = cellMechanicsMicroseconds
        self.regulatoryMicroseconds = regulatoryMicroseconds
        self.structuralMicroseconds = structuralMicroseconds
        self.maximumAdaptiveSlowStepMicroseconds = maximumAdaptiveSlowStepMicroseconds
    }

    public func validate() throws {
        guard fastQuantumMicroseconds > 0 else { throw ConfigurationError.invalidValue("scheduler.fastQuantumMicroseconds") }
        guard eventBlockMicroseconds.isMultiple(of: fastQuantumMicroseconds) else {
            throw ConfigurationError.invalidValue("event block must be an integer multiple of fast quantum")
        }
        guard transactionMicroseconds.isMultiple(of: eventBlockMicroseconds) else {
            throw ConfigurationError.invalidValue("transaction must be an integer multiple of event block")
        }
        guard cellMechanicsMicroseconds.isMultiple(of: transactionMicroseconds) else {
            throw ConfigurationError.invalidValue("cell mechanics period must align to transactions")
        }
    }

    public var fastQuantaPerEventBlock: UInt32 { eventBlockMicroseconds / fastQuantumMicroseconds }
    public var eventBlocksPerTransaction: UInt32 { transactionMicroseconds / eventBlockMicroseconds }
    public var fastQuantaPerTransaction: UInt32 { transactionMicroseconds / fastQuantumMicroseconds }
}

@frozen
public struct PrecisionConfiguration: Codable, Sendable, Hashable {
    public var membraneStateUsesFloat32: Bool
    public var concentrationStateUsesFloat32: Bool
    public var gateStorage: GateStoragePrecision
    public var allowFloat16Surrogates: Bool
    public var useCompensatedReductions: Bool

    public init(
        membraneStateUsesFloat32: Bool = true,
        concentrationStateUsesFloat32: Bool = true,
        gateStorage: GateStoragePrecision = .float16,
        allowFloat16Surrogates: Bool = true,
        useCompensatedReductions: Bool = true
    ) {
        self.membraneStateUsesFloat32 = membraneStateUsesFloat32
        self.concentrationStateUsesFloat32 = concentrationStateUsesFloat32
        self.gateStorage = gateStorage
        self.allowFloat16Surrogates = allowFloat16Surrogates
        self.useCompensatedReductions = useCompensatedReductions
    }
}

@frozen
public struct SafetyConfiguration: Codable, Sendable, Hashable {
    public var minimumConcentration: Float
    public var minimumCellVolume: Float
    public var minimumMembraneVoltageMillivolts: Float
    public var maximumMembraneVoltageMillivolts: Float
    public var maximumRelativeFieldMassError: Float
    public var maximumCellOverlapFraction: Float
    public var rejectOnEventOverflow: Bool
    public var rejectOnNonFinite: Bool

    public init(
        minimumConcentration: Float = 0,
        minimumCellVolume: Float = 1e-6,
        minimumMembraneVoltageMillivolts: Float = -200,
        maximumMembraneVoltageMillivolts: Float = 120,
        maximumRelativeFieldMassError: Float = 1e-5,
        maximumCellOverlapFraction: Float = 0.35,
        rejectOnEventOverflow: Bool = true,
        rejectOnNonFinite: Bool = true
    ) {
        self.minimumConcentration = minimumConcentration
        self.minimumCellVolume = minimumCellVolume
        self.minimumMembraneVoltageMillivolts = minimumMembraneVoltageMillivolts
        self.maximumMembraneVoltageMillivolts = maximumMembraneVoltageMillivolts
        self.maximumRelativeFieldMassError = maximumRelativeFieldMassError
        self.maximumCellOverlapFraction = maximumCellOverlapFraction
        self.rejectOnEventOverflow = rejectOnEventOverflow
        self.rejectOnNonFinite = rejectOnNonFinite
    }
}

@frozen
public struct FidelityConfiguration: Codable, Sendable, Hashable {
    public var promotionActivityThreshold: Float
    public var promotionUncertaintyThreshold: Float
    public var demotionActivityThreshold: Float
    public var demotionHoldTransactions: UInt32
    public var maximumDetailedFraction: Float
    public var molecularInterestRadiusMicrometers: Float

    public init(
        promotionActivityThreshold: Float = 0.35,
        promotionUncertaintyThreshold: Float = 0.25,
        demotionActivityThreshold: Float = 0.05,
        demotionHoldTransactions: UInt32 = 2_000,
        maximumDetailedFraction: Float = 0.15,
        molecularInterestRadiusMicrometers: Float = 50
    ) {
        self.promotionActivityThreshold = promotionActivityThreshold
        self.promotionUncertaintyThreshold = promotionUncertaintyThreshold
        self.demotionActivityThreshold = demotionActivityThreshold
        self.demotionHoldTransactions = demotionHoldTransactions
        self.maximumDetailedFraction = maximumDetailedFraction
        self.molecularInterestRadiusMicrometers = molecularInterestRadiusMicrometers
    }
}

@frozen
public struct NumiTissueConfiguration: Codable, Sendable, Hashable {
    public var schemaVersion: UInt32
    public var backend: ComputeBackend
    public var profile: NumericalProfile
    public var tile: TileConfiguration
    public var scheduler: SchedulerConfiguration
    public var precision: PrecisionConfiguration
    public var safety: SafetyConfiguration
    public var fidelity: FidelityConfiguration
    public var deterministicSeed: UInt64
    public var maximumResidentBytes: UInt64?
    public var enableGPUValidation: Bool
    public var enableCounterSampling: Bool

    public init(
        schemaVersion: UInt32 = NumiTissueBuild.modelSchemaVersion,
        backend: ComputeBackend = .automatic,
        profile: NumericalProfile = .boundedDeterministic,
        tile: TileConfiguration = .init(),
        scheduler: SchedulerConfiguration = .init(),
        precision: PrecisionConfiguration = .init(),
        safety: SafetyConfiguration = .init(),
        fidelity: FidelityConfiguration = .init(),
        deterministicSeed: UInt64 = 0x4E_55_4D_49_54_49_53_53,
        maximumResidentBytes: UInt64? = nil,
        enableGPUValidation: Bool = true,
        enableCounterSampling: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.backend = backend
        self.profile = profile
        self.tile = tile
        self.scheduler = scheduler
        self.precision = precision
        self.safety = safety
        self.fidelity = fidelity
        self.deterministicSeed = deterministicSeed
        self.maximumResidentBytes = maximumResidentBytes
        self.enableGPUValidation = enableGPUValidation
        self.enableCounterSampling = enableCounterSampling
    }

    public func validate() throws {
        guard schemaVersion == NumiTissueBuild.modelSchemaVersion else {
            throw ConfigurationError.unsupportedSchema(schemaVersion)
        }
        try tile.validate()
        try scheduler.validate()
        guard fidelity.maximumDetailedFraction > 0 && fidelity.maximumDetailedFraction <= 1 else {
            throw ConfigurationError.invalidValue("fidelity.maximumDetailedFraction")
        }
        guard safety.maximumMembraneVoltageMillivolts > safety.minimumMembraneVoltageMillivolts else {
            throw ConfigurationError.invalidValue("safety membrane voltage range")
        }
    }

    public static let production = Self()

    public static let scientific = Self(
        profile: .scientific,
        precision: .init(gateStorage: .float32, allowFloat16Surrogates: false),
        enableGPUValidation: true,
        enableCounterSampling: true
    )
}

public enum ConfigurationError: Error, Sendable, CustomStringConvertible {
    case unsupportedSchema(UInt32)
    case invalidValue(String)

    public var description: String {
        switch self {
        case let .unsupportedSchema(value): return "Unsupported NumiTissue schema version \(value)."
        case let .invalidValue(name): return "Invalid configuration value: \(name)."
        }
    }
}

private extension FixedWidthInteger {
    var isPowerOfTwo: Bool { self > 0 && (self & (self - 1)) == 0 }
}
