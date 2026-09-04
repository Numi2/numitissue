import XCTest
import NumiTissueCore
import NumiTissueRuntime
import NumiTissueIntegration

@MainActor
final class Phase7DeviceTimingTests: XCTestCase {
    func testSeparateFrameAndWaveformQuantaPreserveExactDeviceTiming() throws {
        let configuration = ClosedLoopReplayExample.configuration()
        let pulse = StimulationPulse(electrode: .init(rawValue: 1), startTick: 0,
            phases: [.init(amplitudeAmperes: -1e-6, durationMicroseconds: 80),
                     .init(amplitudeAmperes: 1e-6, durationMicroseconds: 80)], interphaseDelayMicroseconds: 40)
        let plan = try StimulationPlanCompiler.compile(pulses: [pulse], configuration: configuration,
            electrodeDestinations: [.init(rawValue: 1): 0])
        let request = NeuralStimulationRequest(plan: plan, scheduledTimeNanoseconds: 10_000_000,
                                              deadlineNanoseconds: 20_000_000)
        let schedule = try DeviceStimulationScheduleCompiler.compile(request: request, configuration: configuration,
            destinations: [.init(rawValue: 1): 0], envelope: ClosedLoopReplayExample.envelope(),
            timebase: .init(clockID: "queried-device-fixture", timestampQuantumNanoseconds: 40_000,
                            phaseQuantumNanoseconds: 20_000), deviceNowNanoseconds: 0, minimumLeadNanoseconds: 80_000)
        XCTAssertEqual(schedule.pulses.count, 1)
        XCTAssertEqual(schedule.pulses[0].timestampFrames, 250)
        XCTAssertEqual(schedule.pulses[0].phases[0].durationPhaseQuanta, 4)
        XCTAssertEqual(schedule.pulses[0].interphaseQuanta, 2)
        XCTAssertEqual(schedule.pulses[0].phases[0].amplitudeMicroamperes, -1, accuracy: 1e-6)
    }
    func testInexactDeviceGapIsRejectedInsteadOfRounded() throws {
        let request = NeuralStimulationRequest(plan: try ClosedLoopReplayExample.plan(),
            scheduledTimeNanoseconds: 10_000_000, deadlineNanoseconds: 20_000_000)
        // The example's 50-us interphase gap cannot be represented in 20-us waveform units.
        XCTAssertThrowsError(try DeviceStimulationScheduleCompiler.compile(request: request,
            configuration: ClosedLoopReplayExample.configuration(), destinations: [.init(rawValue: 1): 0],
            envelope: ClosedLoopReplayExample.envelope(),
            timebase: .init(clockID: "fixture", timestampQuantumNanoseconds: 40_000, phaseQuantumNanoseconds: 20_000),
            deviceNowNanoseconds: 0, minimumLeadNanoseconds: 80_000))
    }
    func testRCEmulatorRespondsToActualQueuedPulseAndDeduplicatesID() async throws {
        var configuration = ClosedLoopReplayExample.configuration()
        configuration.sampleRateHertz = 20_000
        let backend = try RCNeuralInterfaceEmulator(configuration: configuration,
            envelope: ClosedLoopReplayExample.envelope(), resistanceOhms: 1_000,
            capacitanceFarads: 1e-6, sessionID: UUID())
        let session = try await backend.open(cultureID: "software-circuit", configuration: configuration)
        let request = NeuralStimulationRequest(plan: try ClosedLoopReplayExample.plan(configuration: configuration),
            scheduledTimeNanoseconds: 1_000_000, deadlineNanoseconds: 5_000_000)
        let first = try await backend.stimulate(session: session, request: request)
        let repeated = try await backend.stimulate(session: session, request: request)
        XCTAssertEqual(first, repeated)
        let recording = try await backend.record(session: session,
            request: .init(electrodeIDs: [.init(rawValue: 1)], startTimeNanoseconds: 0,
                           durationNanoseconds: 2_000_000, sampleRateHertz: 20_000))
        XCTAssertEqual(recording.frame.sampleCount, 40)
        XCTAssertEqual(recording.frame.samplesByElectrode[0][19], 0)
        let analytical = -0.001 * (1 - exp(-50e-6 / 0.001))
        XCTAssertEqual(Double(recording.frame.samplesByElectrode[0][21]), analytical, accuracy: 1e-9)
    }
    func testCancelledUnstartedEmulatorPulseHasNoVoltageEffect() async throws {
        var configuration = ClosedLoopReplayExample.configuration()
        configuration.sampleRateHertz = 20_000
        let backend = try RCNeuralInterfaceEmulator(configuration: configuration,
            envelope: ClosedLoopReplayExample.envelope(), resistanceOhms: 1_000,
            capacitanceFarads: 1e-6, sessionID: UUID())
        let session = try await backend.open(cultureID: "software-circuit", configuration: configuration)
        let request = NeuralStimulationRequest(plan: try ClosedLoopReplayExample.plan(configuration: configuration),
            scheduledTimeNanoseconds: 1_000_000, deadlineNanoseconds: 5_000_000)
        _ = try await backend.stimulate(session: session, request: request)
        try await backend.cancel(session: session, requestID: request.id)
        let recording = try await backend.record(session: session,
            request: .init(electrodeIDs: [.init(rawValue: 1)], startTimeNanoseconds: 0,
                           durationNanoseconds: 2_000_000, sampleRateHertz: 20_000))
        XCTAssertTrue(recording.frame.samplesByElectrode[0].allSatisfy { $0 == 0 })
    }
    func testTotalMembraneCurrentConservesClosedUninjectedCableCurrent() throws {
        var state = TissueRuntimeState()
        state.compartments = [
            .init(id: .init(rawValue: 1), neuronIndex: 0, voltageMillivolts: -60,
                  previousVoltageMillivolts: -62, capacitanceNanofarads: 1),
            .init(id: .init(rawValue: 2), neuronIndex: 0, parentIndex: 0, voltageMillivolts: -70,
                  previousVoltageMillivolts: -68, capacitanceNanofarads: 1, axialConductanceMicrosiemens: 0.5)
        ]
        let balance = try CultureRuntimeCurrentExtractor.balance(state: state, dtMilliseconds: 0.025)
        XCTAssertEqual(balance.totalOutwardAmperes.reduce(0, +), 0, accuracy: 1e-15)
        for index in state.compartments.indices {
            XCTAssertEqual(balance.totalOutwardAmperes[index],
                balance.capacitiveOutwardAmperes[index] + balance.ionicAndSynapticOutwardAmperes[index], accuracy: 1e-15)
        }
    }
    func testCyclicCurrentSourceGraphIsRejected() throws {
        var state = TissueRuntimeState()
        state.compartments = [
            .init(id: .init(rawValue: 1), neuronIndex: 0, parentIndex: 1, capacitanceNanofarads: 1),
            .init(id: .init(rawValue: 2), neuronIndex: 0, parentIndex: 0, capacitanceNanofarads: 1)
        ]
        XCTAssertThrowsError(try CultureRuntimeCurrentExtractor.balance(state: state, dtMilliseconds: 0.025))
    }
}
