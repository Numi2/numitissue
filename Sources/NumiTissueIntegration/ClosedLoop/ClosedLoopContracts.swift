import Foundation
import NumiTissueIO

/// Simulation time, monotonic host time and device time are distinct clock domains.
/// This mapping is established by an external synchronization procedure, not inferred from Date.
public struct ClosedLoopClockMap: Sendable, Hashable, Codable {
    public var hostAnchorNanoseconds: UInt64
    public var deviceAnchorNanoseconds: UInt64
    public var uncertaintyNanoseconds: UInt64
    public var maximumAgeNanoseconds: UInt64
    public var deviceClockID: String

    public init(hostAnchorNanoseconds: UInt64, deviceAnchorNanoseconds: UInt64,
                uncertaintyNanoseconds: UInt64, maximumAgeNanoseconds: UInt64, deviceClockID: String) {
        self.hostAnchorNanoseconds = hostAnchorNanoseconds
        self.deviceAnchorNanoseconds = deviceAnchorNanoseconds
        self.uncertaintyNanoseconds = uncertaintyNanoseconds
        self.maximumAgeNanoseconds = maximumAgeNanoseconds
        self.deviceClockID = deviceClockID
    }

    public func deviceTime(hostNow: UInt64, maximumUncertainty: UInt64) throws -> UInt64 {
        guard !deviceClockID.isEmpty, maximumAgeNanoseconds > 0,
              hostNow >= hostAnchorNanoseconds,
              hostNow - hostAnchorNanoseconds <= maximumAgeNanoseconds,
              uncertaintyNanoseconds <= maximumUncertainty else {
            throw ClosedLoopError.invalid("stale, uncertain or incompatible clock mapping")
        }
        return try LoopArithmetic.add(deviceAnchorNanoseconds, hostNow - hostAnchorNanoseconds)
    }
}

public enum ClosedLoopEnvironment: String, Sendable, Codable {
    case replay, emulator, electricalPhantom, livingCulture
    public var hasPhysicalEffects: Bool { self == .electricalPhantom || self == .livingCulture }
}

public struct ClosedLoopDeviceIdentity: Sendable, Hashable, Codable {
    public var serial: String
    public var firmware: String
    public var clockID: String
    public var electrodeMapSHA256: ScientificSHA256Digest
    public init(serial: String, firmware: String, clockID: String, electrodeMapSHA256: ScientificSHA256Digest) {
        self.serial = serial; self.firmware = firmware; self.clockID = clockID
        self.electrodeMapSHA256 = electrodeMapSHA256
    }
    public func validated() throws -> Self {
        guard !serial.isEmpty, !firmware.isEmpty, !clockID.isEmpty else {
            throw ClosedLoopError.invalid("device identity")
        }
        return self
    }
}

/// No biological safety constants are supplied. Values must be supplied by the laboratory and
/// device-specific protocol owner. A software envelope is not a safety or clinical certification.
public struct ClosedLoopSafetyEnvelope: Sendable, Hashable, Codable {
    public var maximumCurrentAmperes: Double
    public var maximumPhaseChargeCoulombs: Double
    public var maximumPhaseChargeDensityCoulombsPerSquareMeter: Double
    public var maximumResistiveVoltageEstimate: Double
    public var maximumNetChargeFraction: Double
    public var maximumPlanDurationNanoseconds: UInt64
    public var minimumLeadTimeNanoseconds: UInt64
    public var maximumClockUncertaintyNanoseconds: UInt64
    public var maximumObservationAgeNanoseconds: UInt64
    public var minimumElectrodeRecoveryNanoseconds: UInt64
    public var rollingWindowNanoseconds: UInt64
    public var maximumRollingChargePerElectrodeCoulombs: Double
    public var maximumRollingDutyFraction: Double
    public var maximumConcurrentElectrodes: Int
    public var maximumExpandedPhases: Int
    public var minimumTemperatureKelvin: Double
    public var maximumTemperatureKelvin: Double
    public var excludedElectrodes: [ElectrodeID]

    public init(maximumCurrentAmperes: Double, maximumPhaseChargeCoulombs: Double,
                maximumPhaseChargeDensityCoulombsPerSquareMeter: Double,
                maximumResistiveVoltageEstimate: Double, maximumNetChargeFraction: Double,
                maximumPlanDurationNanoseconds: UInt64, minimumLeadTimeNanoseconds: UInt64,
                maximumClockUncertaintyNanoseconds: UInt64, maximumObservationAgeNanoseconds: UInt64,
                minimumElectrodeRecoveryNanoseconds: UInt64, rollingWindowNanoseconds: UInt64,
                maximumRollingChargePerElectrodeCoulombs: Double, maximumRollingDutyFraction: Double,
                maximumConcurrentElectrodes: Int, maximumExpandedPhases: Int,
                minimumTemperatureKelvin: Double, maximumTemperatureKelvin: Double,
                excludedElectrodes: [ElectrodeID] = []) {
        self.maximumCurrentAmperes = maximumCurrentAmperes
        self.maximumPhaseChargeCoulombs = maximumPhaseChargeCoulombs
        self.maximumPhaseChargeDensityCoulombsPerSquareMeter = maximumPhaseChargeDensityCoulombsPerSquareMeter
        self.maximumResistiveVoltageEstimate = maximumResistiveVoltageEstimate
        self.maximumNetChargeFraction = maximumNetChargeFraction
        self.maximumPlanDurationNanoseconds = maximumPlanDurationNanoseconds
        self.minimumLeadTimeNanoseconds = minimumLeadTimeNanoseconds
        self.maximumClockUncertaintyNanoseconds = maximumClockUncertaintyNanoseconds
        self.maximumObservationAgeNanoseconds = maximumObservationAgeNanoseconds
        self.minimumElectrodeRecoveryNanoseconds = minimumElectrodeRecoveryNanoseconds
        self.rollingWindowNanoseconds = rollingWindowNanoseconds
        self.maximumRollingChargePerElectrodeCoulombs = maximumRollingChargePerElectrodeCoulombs
        self.maximumRollingDutyFraction = maximumRollingDutyFraction
        self.maximumConcurrentElectrodes = maximumConcurrentElectrodes
        self.maximumExpandedPhases = maximumExpandedPhases
        self.minimumTemperatureKelvin = minimumTemperatureKelvin
        self.maximumTemperatureKelvin = maximumTemperatureKelvin
        self.excludedElectrodes = excludedElectrodes
    }

    public func validated() throws -> Self {
        let positive = [maximumCurrentAmperes, maximumPhaseChargeCoulombs,
            maximumPhaseChargeDensityCoulombsPerSquareMeter, maximumResistiveVoltageEstimate,
            maximumRollingChargePerElectrodeCoulombs, minimumTemperatureKelvin, maximumTemperatureKelvin]
        guard positive.allSatisfy({ $0.isFinite && $0 > 0 }),
              maximumNetChargeFraction.isFinite, (0...1).contains(maximumNetChargeFraction),
              maximumNetChargeFraction < 1,
              maximumRollingDutyFraction.isFinite, maximumRollingDutyFraction > 0,
              maximumRollingDutyFraction <= 1,
              maximumPlanDurationNanoseconds > 0, rollingWindowNanoseconds > 0,
              maximumObservationAgeNanoseconds > 0,
              minimumTemperatureKelvin < maximumTemperatureKelvin,
              (1...4096).contains(maximumConcurrentElectrodes),
              (2...100_000).contains(maximumExpandedPhases),
              Set(excludedElectrodes).count == excludedElectrodes.count else {
            throw ClosedLoopError.invalid("safety envelope")
        }
        return self
    }
    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(validated()))
    }
}

public struct ClosedLoopInterlockState: Sendable {
    public var identity: ClosedLoopDeviceIdentity
    public var deviceNowNanoseconds: UInt64
    public var armedUntilNanoseconds: UInt64
    public var autonomousWatchdogNanoseconds: UInt64
    public var stopConfirmed: Bool
    public var temperatureKelvin: Double
    public var measuredVoltageLimitSatisfied: Bool
    public init(identity: ClosedLoopDeviceIdentity, deviceNowNanoseconds: UInt64,
                armedUntilNanoseconds: UInt64, autonomousWatchdogNanoseconds: UInt64,
                stopConfirmed: Bool, temperatureKelvin: Double, measuredVoltageLimitSatisfied: Bool) {
        self.identity = identity; self.deviceNowNanoseconds = deviceNowNanoseconds
        self.armedUntilNanoseconds = armedUntilNanoseconds
        self.autonomousWatchdogNanoseconds = autonomousWatchdogNanoseconds
        self.stopConfirmed = stopConfirmed; self.temperatureKelvin = temperatureKelvin
        self.measuredVoltageLimitSatisfied = measuredVoltageLimitSatisfied
    }
}

/// A live implementation must independently stop on host death/disconnect and cancel queued work.
/// Host Task cancellation, an HTTP timeout, and a software timer are NOT hardware watchdogs.
public protocol InterlockedNeuralCultureBackend: NeuralCultureBackend {
    func interlockState(session: NeuralCultureSession) async throws -> ClosedLoopInterlockState
    func emergencyStop(session: NeuralCultureSession, reason: String) async throws -> ClosedLoopInterlockState
    func stimulationStatus(session: NeuralCultureSession, requestID: UUID) async throws -> NeuralStimulationReceipt
}

public enum ClosedLoopError: Error, Sendable, CustomStringConvertible {
    case invalid(String), unsafe(String), capacity(String), latched(String), ambiguousDelivery(UUID)
    public var description: String {
        switch self {
        case .invalid(let s): return "Closed-loop invalid input: \(s)"
        case .unsafe(let s): return "Closed-loop safety rejection: \(s)"
        case .capacity(let s): return "Closed-loop capacity exceeded: \(s)"
        case .latched(let s): return "Closed-loop stopped; a new authorized session is required: \(s)"
        case .ambiguousDelivery(let id): return "Stimulation delivery is unknown; never resubmit automatically: \(id)"
        }
    }
}

enum LoopArithmetic {
    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let r = a.addingReportingOverflow(b)
        guard !r.overflow else { throw ClosedLoopError.invalid("timestamp overflow") }
        return r.partialValue
    }
    static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let r = a.multipliedReportingOverflow(by: b)
        guard !r.overflow else { throw ClosedLoopError.invalid("duration overflow") }
        return r.partialValue
    }
}
