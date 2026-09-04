import Foundation
import NumiTissueIO

public struct ClosedLoopReplayExampleResult: Sendable, Codable {
    public var kind: String
    public var summary: ClosedLoopRunSummary
    public var receipts: [NeuralStimulationReceipt]
    public var journal: [ClosedLoopAuditRecord]
    public var journalSHA256: ScientificSHA256Digest
}

/// Deterministic SOFTWARE fixture, not a biological model, laboratory limit set or live protocol.
public enum ClosedLoopReplayExample {
    public static func configuration() -> MEAConfiguration {
        MEAConfiguration(electrodes: [MEAElectrode(id: .init(rawValue: 1),
            positionMicrometers: .zero, widthMicrometers: 200, heightMicrometers: 200)],
            sampleRateHertz: 1_000, highPassHertz: 1, lowPassHertz: 400)
    }
    public static func envelope() -> ClosedLoopSafetyEnvelope {
        .init(maximumCurrentAmperes: 10e-6, maximumPhaseChargeCoulombs: 10e-9,
            maximumPhaseChargeDensityCoulombsPerSquareMeter: 0.1,
            maximumResistiveVoltageEstimate: 2, maximumNetChargeFraction: 0.01,
            maximumPlanDurationNanoseconds: 10_000_000, minimumLeadTimeNanoseconds: 100_000,
            maximumClockUncertaintyNanoseconds: 20_000, maximumObservationAgeNanoseconds: 20_000_000,
            minimumElectrodeRecoveryNanoseconds: 100_000, rollingWindowNanoseconds: 1_000_000_000,
            maximumRollingChargePerElectrodeCoulombs: 100e-9, maximumRollingDutyFraction: 0.05,
            maximumConcurrentElectrodes: 1, maximumExpandedPhases: 256,
            minimumTemperatureKelvin: 300, maximumTemperatureKelvin: 315)
    }
    public static func plan(configuration: MEAConfiguration? = nil) throws -> CompiledStimulationPlan {
        let configuration = configuration ?? Self.configuration()
        return try StimulationPlanCompiler.compile(pulses: [.init(electrode: .init(rawValue: 1), startTick: 0,
            phases: [.init(amplitudeAmperes: -1e-6, durationMicroseconds: 100),
                     .init(amplitudeAmperes: 1e-6, durationMicroseconds: 100)],
            interphaseDelayMicroseconds: 50)],
            configuration: configuration, electrodeDestinations: [.init(rawValue: 1): 0])
    }
    public static func recordings() -> [NeuralRecording] {
        [UInt64(0), 20_000_000].enumerated().map { index, start in
            let request = NeuralRecordingRequest(electrodeIDs: [.init(rawValue: 1)],
                startTimeNanoseconds: start, durationNanoseconds: 10_000_000, sampleRateHertz: 1_000)
            var samples = [Float](repeating: 1e-6, count: 10)
            samples[3] = -60e-6
            let frame = MEASampleFrame(startTick: start / 25_000, sampleRateHertz: 1_000,
                                      electrodeOrder: request.electrodeIDs, samplesByElectrode: [samples])
            return NeuralRecording(request: request, frame: frame,
                spikes: [.init(electrode: .init(rawValue: 1), sampleIndex: 3,
                    tick: start / 25_000 + 120, amplitudeVolts: -60e-6, polarity: -1)],
                backendTimestampNanoseconds: start + 10_000_000, checksum: UInt64(index + 1))
        }
    }
    public static func run() async throws -> ClosedLoopReplayExampleResult {
        guard let runID = UUID(uuidString: "00000000-0000-4000-8000-000000000007"),
              let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000071"),
              let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000072") else {
            throw ClosedLoopError.invalid("built-in fixture UUID")
        }
        let config = configuration(), source = recordings()
        let backend = try ReplayNeuralCultureBackend(recordings: source, sessionID: runID)
        let rawSession = try await backend.open(cultureID: "synthetic-replay-only", configuration: config)
        let journal = try MemoryClosedLoopJournal(runID: runID)
        let identity = ClosedLoopDeviceIdentity(serial: "fixture", firmware: "not-hardware", clockID: "virtual-nanoseconds",
            electrodeMapSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(config.electrodes)))
        let guardSession = try GuardedNeuralCultureSession(runID: runID, backend: backend, session: rawSession,
            environment: .replay, identity: identity, configuration: config, destinations: [.init(rawValue: 1): 0],
            envelope: envelope(), audit: journal)
        try await guardSession.admit(nonphysicalExpiryNanoseconds: 1_000_000_000)
        let pulse = try plan(configuration: config)
        let summary = try await ClosedLoopRunner.run(session: guardSession, windows: source.map(\.request)) { recording in
            guard !recording.spikes.isEmpty else { return nil }
            return .init(id: recording.request.startTimeNanoseconds == 0 ? firstID : secondID,
                plan: pulse, scheduledTimeNanoseconds: recording.backendTimestampNanoseconds + 1_000_000,
                deadlineNanoseconds: recording.backendTimestampNanoseconds + 5_000_000,
                experimentTag: "software-replay-not-biological-evidence")
        }
        let receipts = await backend.stimulationReceipts()
        let records = await journal.snapshot()
        try await backend.close(session: rawSession)
        return .init(kind: "synthetic-replay-no-hardware-no-learning-claim", summary: summary,
            receipts: receipts, journal: records,
            journalSHA256: try ClosedLoopJournalVerifier.verify(records, expectedRunID: runID))
    }
}
