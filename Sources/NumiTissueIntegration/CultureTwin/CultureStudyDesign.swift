import Foundation
import NumiTissueIO

public enum CultureStudyPartition: String, Sendable, Codable, CaseIterable {
    case calibration, validation, temporalHoldout, waveformHoldout, electrodeHoldout, cultureHoldout
}

public struct CultureStudySession: Sendable, Hashable, Codable {
    public var id: String
    public var cultureID: String
    public var donorID: String
    public var batchID: String
    public var acquiredAt: Date
    public var simulationTick: UInt64
    public var waveformID: String
    public var stimulatedElectrodes: [ElectrodeID]
    public var partition: CultureStudyPartition
    public init(id: String, cultureID: String, donorID: String, batchID: String,
                acquiredAt: Date, simulationTick: UInt64, waveformID: String,
                stimulatedElectrodes: [ElectrodeID], partition: CultureStudyPartition) {
        self.id = id; self.cultureID = cultureID; self.donorID = donorID; self.batchID = batchID
        self.acquiredAt = acquiredAt; self.simulationTick = simulationTick; self.waveformID = waveformID
        self.stimulatedElectrodes = stimulatedElectrodes; self.partition = partition
    }
}

public struct CultureFeatureContract: Sendable, Hashable, Codable {
    public var id: String
    public var unit: String
    /// Fixed pre-fit normalization. Never estimate this from held-out outcomes.
    public var scale: Double
    public var measurementSD: Double
    public var electrodeSD: Double
    public var modelDiscrepancySD: Double
    public init(id: String, unit: String, scale: Double,
                measurementSD: Double, electrodeSD: Double = 0, modelDiscrepancySD: Double = 0) {
        self.id = id; self.unit = unit; self.scale = scale; self.measurementSD = measurementSD
        self.electrodeSD = electrodeSD; self.modelDiscrepancySD = modelDiscrepancySD
    }
    public var observationVariance: Double {
        measurementSD * measurementSD + electrodeSD * electrodeSD + modelDiscrepancySD * modelDiscrepancySD
    }
    public func validated() throws -> Self {
        guard !id.isEmpty, !unit.isEmpty, scale.isFinite, scale > 0,
              [measurementSD, electrodeSD, modelDiscrepancySD].allSatisfy({ $0.isFinite && $0 >= 0 }),
              observationVariance.isFinite, observationVariance > 0 else {
            throw CultureTwinError.invalid("feature scale or declared noise budget")
        }
        return self
    }
}

public struct CultureStudyDesign: Sendable, Codable {
    public var schemaVersion: UInt32
    public var id: String
    public var measurementModelID: String
    public var featureConfiguration: CultureFeatureConfiguration
    public var features: [CultureFeatureContract]
    public var sessions: [CultureStudySession]
    public init(id: String, measurementModelID: String, featureConfiguration: CultureFeatureConfiguration,
                features: [CultureFeatureContract], sessions: [CultureStudySession]) {
        self.schemaVersion = 1; self.id = id; self.measurementModelID = measurementModelID
        self.featureConfiguration = featureConfiguration; self.features = features; self.sessions = sessions
    }
    public func validated() throws -> Self {
        guard schemaVersion == 1, !id.isEmpty, !measurementModelID.isEmpty,
              !features.isEmpty, features.count <= 1024, Set(features.map(\.id)).count == features.count,
              !sessions.isEmpty, sessions.count <= 100_000, Set(sessions.map(\.id)).count == sessions.count,
              sessions.contains(where: { $0.partition == .calibration }) else {
            throw CultureTwinError.invalid("study identity, features or sessions")
        }
        _ = try featureConfiguration.validated()
        for feature in features { _ = try feature.validated() }
        for session in sessions {
            guard ![session.id, session.cultureID, session.donorID, session.batchID, session.waveformID].contains(""),
                  session.acquiredAt.timeIntervalSince1970.isFinite,
                  Set(session.stimulatedElectrodes).count == session.stimulatedElectrodes.count else {
                throw CultureTwinError.invalid("session identity or stimulus")
            }
        }
        // Metadata for the same culture cannot change between sessions to evade grouped holdouts.
        for group in Dictionary(grouping: sessions, by: \.cultureID).values {
            guard Set(group.map(\.donorID)).count == 1, Set(group.map(\.batchID)).count == 1 else {
                throw CultureTwinError.leakage("culture has inconsistent donor or batch identity")
            }
        }
        let fitting = sessions.filter { $0.partition == .calibration || $0.partition == .validation }
        let fittingCultures = Set(fitting.map(\.cultureID))
        let fittingDonors = Set(fitting.map(\.donorID))
        let fittingBatches = Set(fitting.map(\.batchID))
        let fittingWaveforms = Set(fitting.map(\.waveformID))
        let fittingElectrodes = Set(fitting.flatMap(\.stimulatedElectrodes))
        for session in sessions {
            switch session.partition {
            case .calibration: break
            case .validation:
                let earlier = sessions.filter { $0.partition == .calibration && $0.cultureID == session.cultureID }
                guard earlier.allSatisfy({ $0.acquiredAt < session.acquiredAt && $0.simulationTick < session.simulationTick }) else {
                    throw CultureTwinError.leakage("validation precedes same-culture calibration")
                }
            case .temporalHoldout:
                let earlier = fitting.filter { $0.cultureID == session.cultureID }
                guard !earlier.isEmpty, earlier.allSatisfy({ $0.acquiredAt < session.acquiredAt && $0.simulationTick < session.simulationTick }) else {
                    throw CultureTwinError.leakage("temporal holdout is not strictly later")
                }
            case .waveformHoldout:
                guard !fittingWaveforms.contains(session.waveformID) else {
                    throw CultureTwinError.leakage("held-out waveform was used for fitting or validation")
                }
            case .electrodeHoldout:
                guard !session.stimulatedElectrodes.isEmpty,
                      fittingElectrodes.isDisjoint(with: session.stimulatedElectrodes) else {
                    throw CultureTwinError.leakage("held-out stimulation electrode was used for fitting or validation")
                }
            case .cultureHoldout:
                guard !fittingCultures.contains(session.cultureID), !fittingDonors.contains(session.donorID),
                      !fittingBatches.contains(session.batchID) else {
                    throw CultureTwinError.leakage("external culture shares culture, donor or batch with fitting")
                }
            }
        }
        return self
    }
    public var missingHoldoutPartitions: [CultureStudyPartition] {
        [.temporalHoldout, .waveformHoldout, .electrodeHoldout, .cultureHoldout].filter { partition in
            !sessions.contains { $0.partition == partition }
        }
    }
    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(validated()))
    }
}
