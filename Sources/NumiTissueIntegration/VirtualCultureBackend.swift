import Foundation
import NumiTissueCore
import NumiTissueRuntime

public typealias VirtualCurrentSourceProvider = @Sendable (_ tickRange: Range<UInt64>) async throws -> [NeuralCurrentSource]
public typealias VirtualStimulusSink = @Sendable (_ stimuli: [TissueStimulus]) async throws -> Void
public typealias VirtualCultureClock = @Sendable () async -> UInt64

public actor VirtualNeuralCultureBackend: NeuralCultureBackend {
    public nonisolated let name = "NumiTissue Virtual Culture"
    public nonisolated let declaredCapabilities = NeuralCultureBackendCapabilities(
        maximumElectrodes: 4_096,
        supportedSampleRatesHertz: [10_000, 20_000, 25_000, 30_000, 40_000, 50_000],
        minimumStimulationLeadTimeNanoseconds: 0,
        timestampResolutionNanoseconds: 25_000,
        supportsScheduledStimulation: true,
        supportsStreaming: false,
        supportsImpedanceMeasurement: true,
        supportsHardwareLoop: false
    )
    public var capabilities: NeuralCultureBackendCapabilities { declaredCapabilities }

    private let sourceProvider: VirtualCurrentSourceProvider
    private let stimulusSink: VirtualStimulusSink
    private let clock: VirtualCultureClock
    private let randomSeed: UInt64
    private let detector: MEASpikeDetector
    private var session: NeuralCultureSession?
    private var simulator: VirtualMEASimulator?
    private var configuration: MEAConfiguration?
    private var sequence: UInt64 = 0
    private var cancelled = Set<UUID>()

    public init(
        randomSeed: UInt64,
        detector: MEASpikeDetector = MEASpikeDetector(),
        sourceProvider: @escaping VirtualCurrentSourceProvider,
        stimulusSink: @escaping VirtualStimulusSink,
        clock: @escaping VirtualCultureClock
    ) {
        self.randomSeed = randomSeed
        self.detector = detector
        self.sourceProvider = sourceProvider
        self.stimulusSink = stimulusSink
        self.clock = clock
    }

    public func open(cultureID: String, configuration: MEAConfiguration) async throws -> NeuralCultureSession {
        guard session == nil else { throw VirtualCultureError.sessionAlreadyOpen }
        let configuration = try configuration.validated()
        guard configuration.electrodes.count <= declaredCapabilities.maximumElectrodes else { throw VirtualCultureError.tooManyElectrodes }
        let now = await clock()
        let session = NeuralCultureSession(
            backendName: name,
            cultureID: cultureID,
            timebaseEpochNanoseconds: now,
            metadata: ["backend": "virtual", "tick_ns": "25000"]
        )
        self.configuration = configuration
        self.simulator = try VirtualMEASimulator(configuration: configuration)
        self.session = session
        return session
    }

    public func close(session: NeuralCultureSession) async throws {
        try requireSession(session)
        self.session = nil
        simulator = nil
        configuration = nil
        cancelled.removeAll(keepingCapacity: false)
    }

    public func backendTimeNanoseconds(session: NeuralCultureSession) async throws -> UInt64 {
        try requireSession(session)
        return await clock()
    }

    public func health(session: NeuralCultureSession) async throws -> NeuralCultureHealth {
        try requireSession(session)
        return NeuralCultureHealth(
            status: .healthy,
            activeElectrodes: configuration?.electrodes.filter(\.enabled).count ?? 0,
            meanImpedanceOhms: configuration.map { configuration in
                let active = configuration.electrodes.filter(\.enabled)
                return active.isEmpty ? 0 : active.reduce(0) { $0 + $1.impedanceOhmsAt1kHz } / Float(active.count)
            },
            temperatureKelvin: 310.15,
            dissolvedOxygenFraction: 1,
            contaminationRisk: 0
        )
    }

    public func record(session: NeuralCultureSession, request: NeuralRecordingRequest) async throws -> NeuralRecording {
        try requireSession(session)
        guard let simulator, let configuration else { throw VirtualCultureError.sessionNotOpen }
        guard request.sampleRateHertz == configuration.sampleRateHertz else { throw VirtualCultureError.sampleRateMismatch }
        let startTick = nanosecondsToTick(request.startTimeNanoseconds)
        let durationTicks = max(nanosecondsToTick(request.durationNanoseconds), 1)
        let endTick = startTick &+ durationTicks
        let sources = try await sourceProvider(startTick..<endTick)
        var frame = try await simulator.render(sources: sources, startTick: startTick, endTick: endTick, randomSeed: randomSeed ^ sequence)
        let requested = Set(request.electrodeIDs)
        if !requested.isEmpty {
            var order: [ElectrodeID] = []
            var channels: [[Float]] = []
            for (index, electrode) in frame.electrodeOrder.enumerated() where requested.contains(electrode) {
                order.append(electrode)
                channels.append(frame.samplesByElectrode[index])
            }
            frame = MEASampleFrame(startTick: frame.startTick, sampleRateHertz: frame.sampleRateHertz, electrodeOrder: order, samplesByElectrode: channels)
        }
        let spikes = request.includeDetectedSpikes ? detector.detect(frame) : []
        let checksum = Self.checksum(frame)
        sequence &+= 1
        return NeuralRecording(
            request: request,
            frame: frame,
            spikes: spikes,
            backendTimestampNanoseconds: tickToNanoseconds(endTick),
            checksum: checksum
        )
    }

    public func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) async throws -> NeuralStimulationReceipt {
        try requireSession(session)
        if cancelled.contains(request.id) {
            return NeuralStimulationReceipt(requestID: request.id, status: .cancelled, acceptedAtNanoseconds: await clock())
        }
        let now = await clock()
        guard request.scheduledTimeNanoseconds >= now else { throw WetwareError.missedDeadline }
        if let deadline = request.deadlineNanoseconds, request.scheduledTimeNanoseconds > deadline { throw WetwareError.missedDeadline }
        let baseTick = nanosecondsToTick(request.scheduledTimeNanoseconds)
        let planStart = request.plan.startTick
        let shifted = request.plan.runtimeStimuli.map { stimulus -> TissueStimulus in
            var copy = stimulus
            copy.startTick = baseTick &+ (stimulus.startTick >= planStart ? stimulus.startTick - planStart : 0)
            return copy
        }
        try await stimulusSink(shifted)
        sequence &+= 1
        return NeuralStimulationReceipt(
            requestID: request.id,
            status: .executed,
            acceptedAtNanoseconds: now,
            executedAtNanoseconds: request.scheduledTimeNanoseconds,
            hardwareSequence: sequence
        )
    }

    public func cancel(session: NeuralCultureSession, requestID: UUID) async throws {
        try requireSession(session)
        cancelled.insert(requestID)
    }

    private func requireSession(_ value: NeuralCultureSession) throws {
        guard let session, session.id == value.id else { throw WetwareError.unknownSession }
    }

    private func nanosecondsToTick(_ value: UInt64) -> UInt64 { value / 25_000 }
    private func tickToNanoseconds(_ value: UInt64) -> UInt64 { value &* 25_000 }

    private static func checksum(_ frame: MEASampleFrame) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        func mix(_ value: UInt64) { hash = (hash ^ value) &* 0x100000001b3 }
        mix(frame.startTick)
        mix(frame.sampleRateHertz.bitPattern)
        for electrode in frame.electrodeOrder { mix(UInt64(electrode.rawValue)) }
        for channel in frame.samplesByElectrode {
            for sample in channel { mix(UInt64(sample.bitPattern)) }
        }
        return hash
    }
}

public enum VirtualCultureError: Error, Sendable, CustomStringConvertible {
    case sessionAlreadyOpen
    case sessionNotOpen
    case tooManyElectrodes
    case sampleRateMismatch

    public var description: String {
        switch self {
        case .sessionAlreadyOpen: return "A virtual culture session is already open"
        case .sessionNotOpen: return "No virtual culture session is open"
        case .tooManyElectrodes: return "MEA exceeds virtual culture electrode capacity"
        case .sampleRateMismatch: return "Recording request sample rate does not match the virtual MEA"
        }
    }
}
