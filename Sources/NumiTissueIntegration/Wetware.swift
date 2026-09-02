import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct NeuralCultureBackendCapabilities: Sendable, Hashable, Codable {
    public var maximumElectrodes: Int
    public var supportedSampleRatesHertz: [Double]
    public var minimumStimulationLeadTimeNanoseconds: UInt64
    public var timestampResolutionNanoseconds: UInt64
    public var supportsScheduledStimulation: Bool
    public var supportsStreaming: Bool
    public var supportsImpedanceMeasurement: Bool
    public var supportsHardwareLoop: Bool

    public init(
        maximumElectrodes: Int,
        supportedSampleRatesHertz: [Double],
        minimumStimulationLeadTimeNanoseconds: UInt64,
        timestampResolutionNanoseconds: UInt64,
        supportsScheduledStimulation: Bool,
        supportsStreaming: Bool,
        supportsImpedanceMeasurement: Bool,
        supportsHardwareLoop: Bool
    ) {
        self.maximumElectrodes = maximumElectrodes
        self.supportedSampleRatesHertz = supportedSampleRatesHertz
        self.minimumStimulationLeadTimeNanoseconds = minimumStimulationLeadTimeNanoseconds
        self.timestampResolutionNanoseconds = timestampResolutionNanoseconds
        self.supportsScheduledStimulation = supportsScheduledStimulation
        self.supportsStreaming = supportsStreaming
        self.supportsImpedanceMeasurement = supportsImpedanceMeasurement
        self.supportsHardwareLoop = supportsHardwareLoop
    }
}

public struct NeuralCultureSession: Sendable, Hashable, Codable {
    public var id: UUID
    public var backendName: String
    public var cultureID: String
    public var startedAt: Date
    public var timebaseEpochNanoseconds: UInt64
    public var metadata: [String: String]

    public init(id: UUID = UUID(), backendName: String, cultureID: String, startedAt: Date = Date(), timebaseEpochNanoseconds: UInt64, metadata: [String: String] = [:]) {
        self.id = id
        self.backendName = backendName
        self.cultureID = cultureID
        self.startedAt = startedAt
        self.timebaseEpochNanoseconds = timebaseEpochNanoseconds
        self.metadata = metadata
    }
}

public struct NeuralCultureHealth: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable { case healthy, degraded, unsafe, unavailable }
    public var status: Status
    public var activeElectrodes: Int
    public var meanImpedanceOhms: Float?
    public var temperatureKelvin: Float?
    public var dissolvedOxygenFraction: Float?
    public var contaminationRisk: Float?
    public var message: String?

    public init(status: Status, activeElectrodes: Int, meanImpedanceOhms: Float? = nil, temperatureKelvin: Float? = nil, dissolvedOxygenFraction: Float? = nil, contaminationRisk: Float? = nil, message: String? = nil) {
        self.status = status
        self.activeElectrodes = activeElectrodes
        self.meanImpedanceOhms = meanImpedanceOhms
        self.temperatureKelvin = temperatureKelvin
        self.dissolvedOxygenFraction = dissolvedOxygenFraction
        self.contaminationRisk = contaminationRisk
        self.message = message
    }
}

public struct NeuralRecordingRequest: Sendable, Hashable, Codable {
    public var electrodeIDs: [ElectrodeID]
    public var startTimeNanoseconds: UInt64
    public var durationNanoseconds: UInt64
    public var sampleRateHertz: Double
    public var rawVoltage: Bool
    public var includeDetectedSpikes: Bool

    public init(electrodeIDs: [ElectrodeID], startTimeNanoseconds: UInt64, durationNanoseconds: UInt64, sampleRateHertz: Double, rawVoltage: Bool = true, includeDetectedSpikes: Bool = true) {
        self.electrodeIDs = electrodeIDs
        self.startTimeNanoseconds = startTimeNanoseconds
        self.durationNanoseconds = durationNanoseconds
        self.sampleRateHertz = sampleRateHertz
        self.rawVoltage = rawVoltage
        self.includeDetectedSpikes = includeDetectedSpikes
    }
}

public struct NeuralRecording: Sendable, Hashable, Codable {
    public var request: NeuralRecordingRequest
    public var frame: MEASampleFrame
    public var spikes: [DetectedMEASpike]
    public var droppedSamples: UInt64
    public var backendTimestampNanoseconds: UInt64
    public var checksum: UInt64

    public init(request: NeuralRecordingRequest, frame: MEASampleFrame, spikes: [DetectedMEASpike] = [], droppedSamples: UInt64 = 0, backendTimestampNanoseconds: UInt64, checksum: UInt64) {
        self.request = request
        self.frame = frame
        self.spikes = spikes
        self.droppedSamples = droppedSamples
        self.backendTimestampNanoseconds = backendTimestampNanoseconds
        self.checksum = checksum
    }
}

public struct NeuralStimulationRequest: Sendable, Hashable, Codable {
    public var id: UUID
    public var plan: CompiledStimulationPlan
    public var scheduledTimeNanoseconds: UInt64
    public var deadlineNanoseconds: UInt64?
    public var experimentTag: String?

    public init(id: UUID = UUID(), plan: CompiledStimulationPlan, scheduledTimeNanoseconds: UInt64, deadlineNanoseconds: UInt64? = nil, experimentTag: String? = nil) {
        self.id = id
        self.plan = plan
        self.scheduledTimeNanoseconds = scheduledTimeNanoseconds
        self.deadlineNanoseconds = deadlineNanoseconds
        self.experimentTag = experimentTag
    }
}

public struct NeuralStimulationReceipt: Sendable, Hashable, Codable {
    public enum Status: String, Sendable, Hashable, Codable { case accepted, executed, rejected, cancelled }
    public var requestID: UUID
    public var status: Status
    public var acceptedAtNanoseconds: UInt64
    public var executedAtNanoseconds: UInt64?
    public var hardwareSequence: UInt64?
    public var message: String?

    public init(requestID: UUID, status: Status, acceptedAtNanoseconds: UInt64, executedAtNanoseconds: UInt64? = nil, hardwareSequence: UInt64? = nil, message: String? = nil) {
        self.requestID = requestID
        self.status = status
        self.acceptedAtNanoseconds = acceptedAtNanoseconds
        self.executedAtNanoseconds = executedAtNanoseconds
        self.hardwareSequence = hardwareSequence
        self.message = message
    }
}

public protocol NeuralCultureBackend: Sendable {
    var name: String { get }
    var capabilities: NeuralCultureBackendCapabilities { get async }
    func open(cultureID: String, configuration: MEAConfiguration) async throws -> NeuralCultureSession
    func close(session: NeuralCultureSession) async throws
    func backendTimeNanoseconds(session: NeuralCultureSession) async throws -> UInt64
    func health(session: NeuralCultureSession) async throws -> NeuralCultureHealth
    func record(session: NeuralCultureSession, request: NeuralRecordingRequest) async throws -> NeuralRecording
    func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) async throws -> NeuralStimulationReceipt
    func cancel(session: NeuralCultureSession, requestID: UUID) async throws
}

public protocol WetwareTransport: Sendable {
    func request(_ request: WetwareTransportRequest) async throws -> WetwareTransportResponse
    func stream(_ request: WetwareTransportRequest) -> AsyncThrowingStream<Data, Error>
}

public struct WetwareTransportRequest: Sendable {
    public var operation: String
    public var headers: [String: String]
    public var body: Data?
    public var timeoutNanoseconds: UInt64

    public init(operation: String, headers: [String: String] = [:], body: Data? = nil, timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.operation = operation
        self.headers = headers
        self.body = body
        self.timeoutNanoseconds = timeoutNanoseconds
    }
}

public struct WetwareTransportResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// Hardware adapters use an injected transport because vendor authentication, endpoints and API
/// versions are deployment-specific. The codec preserves exact timestamp and stimulation semantics.
public actor RemoteNeuralCultureBackend: NeuralCultureBackend {
    public nonisolated let name: String
    public nonisolated let declaredCapabilities: NeuralCultureBackendCapabilities
    public var capabilities: NeuralCultureBackendCapabilities { declaredCapabilities }

    private let transport: any WetwareTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var sessions = Set<UUID>()

    public init(name: String, capabilities: NeuralCultureBackendCapabilities, transport: any WetwareTransport) {
        self.name = name
        self.declaredCapabilities = capabilities
        self.transport = transport
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func open(cultureID: String, configuration: MEAConfiguration) async throws -> NeuralCultureSession {
        _ = try configuration.validated()
        let payload = OpenPayload(cultureID: cultureID, configuration: configuration)
        let response = try await transport.request(WetwareTransportRequest(operation: "session.open", body: try encoder.encode(payload)))
        try requireSuccess(response)
        let session = try decoder.decode(NeuralCultureSession.self, from: response.body)
        sessions.insert(session.id)
        return session
    }

    public func close(session: NeuralCultureSession) async throws {
        try requireSession(session)
        let response = try await transport.request(WetwareTransportRequest(operation: "session.close", body: try encoder.encode(session)))
        try requireSuccess(response)
        sessions.remove(session.id)
    }

    public func backendTimeNanoseconds(session: NeuralCultureSession) async throws -> UInt64 {
        try requireSession(session)
        let response = try await transport.request(WetwareTransportRequest(operation: "clock.read", body: try encoder.encode(session)))
        try requireSuccess(response)
        return try decoder.decode(ClockPayload.self, from: response.body).nanoseconds
    }

    public func health(session: NeuralCultureSession) async throws -> NeuralCultureHealth {
        try requireSession(session)
        let response = try await transport.request(WetwareTransportRequest(operation: "culture.health", body: try encoder.encode(session)))
        try requireSuccess(response)
        return try decoder.decode(NeuralCultureHealth.self, from: response.body)
    }

    public func record(session: NeuralCultureSession, request: NeuralRecordingRequest) async throws -> NeuralRecording {
        try requireSession(session)
        let response = try await transport.request(WetwareTransportRequest(operation: "record", body: try encoder.encode(SessionPayload(session: session, payload: request))))
        try requireSuccess(response)
        return try decoder.decode(NeuralRecording.self, from: response.body)
    }

    public func stimulate(session: NeuralCultureSession, request: NeuralStimulationRequest) async throws -> NeuralStimulationReceipt {
        try requireSession(session)
        let now = try await backendTimeNanoseconds(session: session)
        guard request.scheduledTimeNanoseconds >= now + declaredCapabilities.minimumStimulationLeadTimeNanoseconds else { throw WetwareError.insufficientLeadTime }
        if let deadline = request.deadlineNanoseconds, request.scheduledTimeNanoseconds > deadline { throw WetwareError.missedDeadline }
        let response = try await transport.request(WetwareTransportRequest(operation: "stimulate", body: try encoder.encode(SessionPayload(session: session, payload: request))))
        try requireSuccess(response)
        return try decoder.decode(NeuralStimulationReceipt.self, from: response.body)
    }

    public func cancel(session: NeuralCultureSession, requestID: UUID) async throws {
        try requireSession(session)
        let response = try await transport.request(WetwareTransportRequest(operation: "stimulate.cancel", body: try encoder.encode(CancelPayload(session: session, requestID: requestID))))
        try requireSuccess(response)
    }

    private func requireSession(_ session: NeuralCultureSession) throws {
        guard sessions.contains(session.id) else { throw WetwareError.unknownSession }
    }

    private func requireSuccess(_ response: WetwareTransportResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw WetwareError.remote(status: response.statusCode, body: String(data: response.body, encoding: .utf8) ?? "") }
    }

    private struct OpenPayload: Codable { var cultureID: String; var configuration: MEAConfiguration }
    private struct ClockPayload: Codable { var nanoseconds: UInt64 }
    private struct CancelPayload: Codable { var session: NeuralCultureSession; var requestID: UUID }
    private struct SessionPayload<Payload: Codable & Sendable>: Codable, Sendable { var session: NeuralCultureSession; var payload: Payload }
}

public protocol ClosedLoopInputEncoder: Sendable {
    associatedtype Input: Sendable
    func encode(_ input: Input, at backendTimeNanoseconds: UInt64) async throws -> [StimulationPulse]
}

public protocol ClosedLoopOutputDecoder: Sendable {
    associatedtype Output: Sendable
    func decode(_ recording: NeuralRecording) async throws -> Output
}

public struct ClosedLoopCycleResult<Output: Sendable>: Sendable {
    public var stimulation: NeuralStimulationReceipt
    public var recording: NeuralRecording
    public var output: Output
    public var latencyNanoseconds: UInt64
}

public actor ClosedLoopExperiment<Encoder: ClosedLoopInputEncoder, Decoder: ClosedLoopOutputDecoder> {
    private let backend: any NeuralCultureBackend
    private let session: NeuralCultureSession
    private let configuration: MEAConfiguration
    private let electrodeDestinations: [ElectrodeID: UInt64]
    private let encoder: Encoder
    private let decoder: Decoder
    private let safety: StimulationSafetyLimits

    public init(
        backend: any NeuralCultureBackend,
        session: NeuralCultureSession,
        configuration: MEAConfiguration,
        electrodeDestinations: [ElectrodeID: UInt64],
        encoder: Encoder,
        decoder: Decoder,
        safety: StimulationSafetyLimits = StimulationSafetyLimits()
    ) {
        self.backend = backend
        self.session = session
        self.configuration = configuration
        self.electrodeDestinations = electrodeDestinations
        self.encoder = encoder
        self.decoder = decoder
        self.safety = safety
    }

    public func cycle(
        input: Encoder.Input,
        recordingDurationNanoseconds: UInt64,
        stimulationLeadTimeNanoseconds: UInt64? = nil
    ) async throws -> ClosedLoopCycleResult<Decoder.Output> {
        let capabilities = await backend.capabilities
        let now = try await backend.backendTimeNanoseconds(session: session)
        let lead = max(stimulationLeadTimeNanoseconds ?? capabilities.minimumStimulationLeadTimeNanoseconds, capabilities.minimumStimulationLeadTimeNanoseconds)
        let pulses = try await encoder.encode(input, at: now + lead)
        let plan = try StimulationPlanCompiler.compile(pulses: pulses, configuration: configuration, electrodeDestinations: electrodeDestinations, limits: safety)
        let stimulationRequest = NeuralStimulationRequest(plan: plan, scheduledTimeNanoseconds: now + lead)
        let receipt = try await backend.stimulate(session: session, request: stimulationRequest)
        let recordingRequest = NeuralRecordingRequest(
            electrodeIDs: configuration.electrodes.filter(\.enabled).map(\.id),
            startTimeNanoseconds: now + lead,
            durationNanoseconds: recordingDurationNanoseconds,
            sampleRateHertz: configuration.sampleRateHertz
        )
        let recording = try await backend.record(session: session, request: recordingRequest)
        let output = try await decoder.decode(recording)
        let finished = try await backend.backendTimeNanoseconds(session: session)
        return ClosedLoopCycleResult(stimulation: receipt, recording: recording, output: output, latencyNanoseconds: finished >= now ? finished - now : 0)
    }
}

public enum WetwareError: Error, Sendable, CustomStringConvertible {
    case unknownSession
    case insufficientLeadTime
    case missedDeadline
    case remote(status: Int, body: String)
    case unsafeCulture(String)
    case unsupportedOperation(String)

    public var description: String {
        switch self {
        case .unknownSession: return "Unknown neural-culture session"
        case .insufficientLeadTime: return "Stimulation request does not satisfy hardware lead time"
        case .missedDeadline: return "Stimulation request misses its deadline"
        case .remote(let status, let body): return "Wetware backend returned HTTP-equivalent status \(status): \(body)"
        case .unsafeCulture(let reason): return "Neural culture is outside its safety envelope: \(reason)"
        case .unsupportedOperation(let operation): return "Wetware backend does not support \(operation)"
        }
    }
}
