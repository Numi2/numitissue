import Foundation
import NumiTissueIO

/// SOFTWARE-ONLY parallel RC electrical load: dV/dt = (I - V/R)/C.
/// This is a deterministic interface emulator, not cultured neurons or organoid intelligence.
/// Current steps are integrated analytically between exact integer-nanosecond events and samples.
public actor RCNeuralInterfaceEmulator: NonphysicalNeuralCultureBackend {
    public nonisolated let name = "NumiTissue RC interface emulator (software only)"
    public var capabilities: NeuralCultureBackendCapabilities {
        .init(maximumElectrodes: configuration.electrodes.count,
            supportedSampleRatesHertz: [configuration.sampleRateHertz],
            minimumStimulationLeadTimeNanoseconds: 0, timestampResolutionNanoseconds: 1_000,
            supportsScheduledStimulation: true, supportsStreaming: false,
            supportsImpedanceMeasurement: false, supportsHardwareLoop: false)
    }
    private struct Edge: Sendable { var tick: UInt64; var channel: Int; var delta: Double; var requestID: UUID; var ordinal: Int }
    private let configuration: MEAConfiguration
    private let envelope: ClosedLoopSafetyEnvelope
    private let resistance: Double
    private let capacitance: Double
    private let id: UUID
    private let destinations: [ElectrodeID: UInt64]
    private let channelMap: [ElectrodeID: Int]
    private var session: NeuralCultureSession?
    private var opened = false
    private var clock: UInt64 = 0
    private var voltages: [Double]
    private var currents: [Double]
    private var edges: [Edge] = []
    private var requests: [UUID: NeuralStimulationRequest] = [:]
    private var receipts: [UUID: NeuralStimulationReceipt] = [:]
    private var history: [ClosedLoopExposure] = []

    public init(configuration: MEAConfiguration, envelope: ClosedLoopSafetyEnvelope,
                resistanceOhms: Double, capacitanceFarads: Double, sessionID: UUID) throws {
        let configuration = try configuration.validated()
        guard resistanceOhms.isFinite, resistanceOhms > 0, capacitanceFarads.isFinite, capacitanceFarads > 0,
              (resistanceOhms * capacitanceFarads).isFinite, resistanceOhms * capacitanceFarads > 0,
              configuration.electrodes.count <= 256 else { throw ClosedLoopError.invalid("RC emulator parameters") }
        self.configuration = configuration; self.envelope = try envelope.validated()
        self.resistance = resistanceOhms; self.capacitance = capacitanceFarads; self.id = sessionID
        self.channelMap = Dictionary(uniqueKeysWithValues: configuration.electrodes.enumerated().map { ($0.element.id, $0.offset) })
        self.destinations = Dictionary(uniqueKeysWithValues: configuration.electrodes.enumerated().map { ($0.element.id, UInt64($0.offset)) })
        self.voltages = .init(repeating: 0, count: configuration.electrodes.count)
        self.currents = .init(repeating: 0, count: configuration.electrodes.count)
    }
    public func open(cultureID: String, configuration: MEAConfiguration) throws -> NeuralCultureSession {
        guard !opened, !cultureID.isEmpty, configuration == self.configuration else { throw ClosedLoopError.invalid("emulator session") }
        let session = NeuralCultureSession(id: id, backendName: name, cultureID: cultureID,
            startedAt: Date(timeIntervalSince1970: 0), timebaseEpochNanoseconds: 0,
            metadata: ["model": "parallel-RC-load", "biologicalModel": "false", "hardware": "false"])
        self.session = session; opened = true
        return session
    }
    public func close(session: NeuralCultureSession) throws {
        try require(session); self.session = nil; edges.removeAll(); currents = currents.map { _ in 0 }
    }
    public func backendTimeNanoseconds(session: NeuralCultureSession) throws -> UInt64 { try require(session); return clock }
    public func health(session: NeuralCultureSession) throws -> NeuralCultureHealth {
        try require(session)
        return .init(status: .healthy, activeElectrodes: configuration.electrodes.filter(\.enabled).count,
            temperatureKelvin: 310.15, message: "Synthetic RC test status, not measured culture health")
    }
    public func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) throws -> NeuralStimulationReceipt {
        try require(session)
        if let prior = requests[request.id] {
            guard prior == request, let receipt = receipts[request.id] else { throw ClosedLoopError.invalid("emulator request ID substitution") }
            return receipt
        }
        let decision = try ClosedLoopSafetyEvaluator.evaluate(request: request, configuration: configuration,
            destinations: destinations, envelope: envelope, deviceNowNanoseconds: clock,
            deviceMinimumLeadNanoseconds: 0, timestampResolutionNanoseconds: 1_000, history: history)
        var additions: [Edge] = []
        for pulse in request.plan.pulses {
            guard let channel = channelMap[pulse.electrode] else { throw ClosedLoopError.invalid("emulator channel") }
            let offset = try LoopArithmetic.multiply(pulse.startTick - request.plan.startTick, 25_000)
            for repetition in 0..<pulse.repetitions {
                let repeated = try LoopArithmetic.multiply(UInt64(repetition), UInt64(pulse.periodMicroseconds) * 1_000)
                var tick = try LoopArithmetic.add(request.scheduledTimeNanoseconds, LoopArithmetic.add(offset, repeated))
                for (index, phase) in pulse.phases.enumerated() {
                    let end = try LoopArithmetic.add(tick, UInt64(phase.durationMicroseconds) * 1_000)
                    additions.append(.init(tick: tick, channel: channel, delta: Double(phase.amplitudeAmperes), requestID: request.id, ordinal: additions.count))
                    additions.append(.init(tick: end, channel: channel, delta: -Double(phase.amplitudeAmperes), requestID: request.id, ordinal: additions.count))
                    tick = end
                    if index + 1 < pulse.phases.count { tick = try LoopArithmetic.add(tick, UInt64(pulse.interphaseDelayMicroseconds) * 1_000) }
                }
            }
        }
        guard additions.count <= 200_000 - edges.count, requests.count < 100_000 else { throw ClosedLoopError.capacity("emulator event queue") }
        edges.append(contentsOf: additions)
        edges.sort { a, b in
            if a.tick != b.tick { return a.tick < b.tick }
            if a.requestID != b.requestID { return a.requestID.uuidString < b.requestID.uuidString }
            return a.ordinal < b.ordinal
        }
        history.append(contentsOf: decision.exposures); requests[request.id] = request
        let receipt = NeuralStimulationReceipt(requestID: request.id, status: .accepted,
            acceptedAtNanoseconds: clock, message: "Software RC event queue; not physical delivery")
        receipts[request.id] = receipt
        return receipt
    }
    public func record(session: NeuralCultureSession, request: NeuralRecordingRequest) throws -> NeuralRecording {
        try require(session)
        let interval = 1e9 / request.sampleRateHertz
        guard request.sampleRateHertz == configuration.sampleRateHertz,
              interval.isFinite, interval >= 1, interval <= Double(UInt32.max),
              abs(interval - interval.rounded()) < 1e-6,
              request.startTimeNanoseconds >= clock, request.startTimeNanoseconds.isMultiple(of: 25_000),
              !request.electrodeIDs.isEmpty, Set(request.electrodeIDs).count == request.electrodeIDs.count,
              request.electrodeIDs.allSatisfy({ channelMap[$0] != nil }) else { throw ClosedLoopError.invalid("emulator recording grid") }
        let step = UInt64(interval.rounded())
        guard request.durationNanoseconds > 0, request.durationNanoseconds.isMultiple(of: step) else { throw ClosedLoopError.invalid("fractional emulator sample") }
        let count = request.durationNanoseconds / step
        guard count <= 1_000_000, count * UInt64(request.electrodeIDs.count) <= 16_777_216 else { throw ClosedLoopError.capacity("emulator recording") }
        let end = try LoopArithmetic.add(request.startTimeNanoseconds, request.durationNanoseconds)
        var v = voltages, i = currents, position = clock, edgeIndex = 0
        func advance(_ target: UInt64) throws {
            func integrate(to time: UInt64) throws {
                guard time >= position else { throw ClosedLoopError.invalid("unordered emulator event") }
                let decay = exp(-Double(time - position) * 1e-9 / (resistance * capacitance))
                for channel in v.indices {
                    let equilibrium = i[channel] * resistance
                    v[channel] = equilibrium + (v[channel] - equilibrium) * decay
                    guard v[channel].isFinite else { throw ClosedLoopError.invalid("RC voltage overflow") }
                }
                position = time
            }
            while edgeIndex < edges.count, edges[edgeIndex].tick <= target {
                let edge = edges[edgeIndex]
                try integrate(to: edge.tick)
                i[edge.channel] += edge.delta; edgeIndex += 1
            }
            try integrate(to: target)
        }
        var channels = [[Float]](repeating: [], count: request.electrodeIDs.count)
        for index in channels.indices { channels[index].reserveCapacity(Int(count)) }
        for sample in 0..<count {
            let time = try LoopArithmetic.add(request.startTimeNanoseconds, LoopArithmetic.multiply(sample, step))
            try advance(time)
            for (index, electrode) in request.electrodeIDs.enumerated() {
                guard let channel = channelMap[electrode] else { throw ClosedLoopError.invalid("emulator channel map") }
                let value = Float(v[channel])
                guard value.isFinite else { throw ClosedLoopError.invalid("emulator FP32 overflow") }
                channels[index].append(value)
            }
        }
        try advance(end)
        voltages = v; currents = i; clock = end; edges.removeFirst(edgeIndex)
        for (id, receipt) in receipts where receipt.status == .accepted {
            guard let exposureEnd = history.filter({ $0.requestID == id }).map(\.endNanoseconds).max(),
                  exposureEnd <= end, let planned = requests[id] else { continue }
            var executed = receipt; executed.status = .executed; executed.executedAtNanoseconds = planned.scheduledTimeNanoseconds
            receipts[id] = executed
        }
        let frame = MEASampleFrame(startTick: request.startTimeNanoseconds / 25_000,
            sampleRateHertz: request.sampleRateHertz, electrodeOrder: request.electrodeIDs, samplesByElectrode: channels)
        return .init(request: request, frame: frame, backendTimestampNanoseconds: end, checksum: 0)
    }
    public func cancel(session: NeuralCultureSession, requestID: UUID) throws {
        try require(session)
        guard let planned = requests[requestID], planned.scheduledTimeNanoseconds > clock,
              var receipt = receipts[requestID], receipt.status == .accepted else {
            throw ClosedLoopError.invalid("emulator pulse already started or unknown")
        }
        edges.removeAll { $0.requestID == requestID }; receipt.status = .cancelled; receipts[requestID] = receipt
        // Retain dose history conservatively even for cancellation, matching the supervisory guard.
    }
    private func require(_ value: NeuralCultureSession) throws {
        guard session == value else { throw ClosedLoopError.invalid("emulator session identity") }
    }
}
