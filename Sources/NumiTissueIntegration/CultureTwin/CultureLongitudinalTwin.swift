import Foundation
import NumiTissueIO

/// Stimulus/time schedule only: no measured outcomes or observation covariance.
public struct CultureForecastRequest: Sendable {
    public let session: CultureStudySession
    public let featureIDs: [String]
    public let measurementModelID: String
}

public struct CultureSimulationResult: Sendable {
    public var recording: CultureRecording
    /// Complete independent simulator continuation, including pending events and RNG state.
    public var nextOpaqueState: Data
    public init(recording: CultureRecording, nextOpaqueState: Data) {
        self.recording = recording; self.nextOpaqueState = nextOpaqueState
    }
}

public typealias CultureSimulationProvider = @Sendable (
    _ memberID: UInt64, _ parameters: [String: Double], _ priorState: Data?, _ request: CultureForecastRequest
) async throws -> CultureSimulationResult

public struct CultureTwinCheckpoint: Sendable, Codable {
    public var schemaVersion: UInt32
    public var studySHA256: ScientificSHA256Digest
    public var cultureID: String
    public var modelSHA256: ScientificSHA256Digest
    public var assimilatedSessionIDs: [String]
    public var ensemble: TissueTwinAssimilationCheckpoint
    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

/// One actor per culture. Stage a fresh assimilator; adopt only after acceptance and cancellation checks.
/// Providers must be side-effect-free: no wetware or robot command is permitted here.
public actor CultureLongitudinalTwin {
    private let design: CultureStudyDesign
    private let cultureID: String
    private let modelSHA256: ScientificSHA256Digest
    private let initialParameters: [TissueTwinParameterDefinition]
    private let initialConfiguration: TissueTwinAssimilationConfiguration
    private let initialState: Data?
    private let provider: CultureSimulationProvider
    private var committed: TissueTwinAssimilationCheckpoint?
    private var sessionIDs: [String] = []
    private var busy = false

    public init(design: CultureStudyDesign, cultureID: String, modelSHA256: ScientificSHA256Digest,
                parameters: [TissueTwinParameterDefinition], configuration: TissueTwinAssimilationConfiguration,
                initialState: Data? = nil, provider: @escaping CultureSimulationProvider) throws {
        self.design = try design.validated()
        guard !parameters.isEmpty, parameters.count <= 1024,
              Set(parameters.map(\.name)).count == parameters.count,
              configuration.ensembleSize <= 4096, configuration.maximumConcurrentForecasts <= 64,
              design.sessions.contains(where: { $0.cultureID == cultureID && $0.partition == .calibration }) else {
            throw CultureTwinError.invalid("culture calibration or parameter definitions")
        }
        self.initialParameters = try parameters.map { try $0.validated() }
        self.initialConfiguration = try configuration.validated(parameters: parameters)
        self.cultureID = cultureID; self.modelSHA256 = modelSHA256
        self.initialState = initialState; self.provider = provider
    }

    public func assimilate(sessionID: String, measured: CultureFeatureReport) async throws -> TissueTwinAssimilationReport {
        guard !busy else { throw CultureTwinError.invalid("concurrent culture transaction") }
        busy = true; defer { busy = false }
        guard let session = design.sessions.first(where: { $0.id == sessionID }),
              session.cultureID == cultureID, session.partition == .calibration,
              measured.recordingID == sessionID, measured.measurementModelID == design.measurementModelID,
              !sessionIDs.contains(sessionID),
              measured.extractionSHA256 == ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(design.featureConfiguration)) else {
            throw CultureTwinError.leakage("only matching unused calibration sessions may update a twin")
        }
        let orderedCalibration = design.sessions.filter { $0.cultureID == cultureID && $0.partition == .calibration }
            .sorted { ($0.simulationTick, $0.id) < ($1.simulationTick, $1.id) }
        guard sessionIDs.count < orderedCalibration.count, orderedCalibration[sessionIDs.count].id == sessionID else {
            throw CultureTwinError.invalid("calibration sessions must be assimilated in scheduled order")
        }
        guard Set(measured.features.map(\.id)).count == measured.features.count else {
            throw CultureTwinError.invalid("duplicate measured feature")
        }
        let values = Dictionary(uniqueKeysWithValues: measured.features.map { ($0.id, $0) })
        let contracts = design.features.sorted { $0.id < $1.id }
        var covariance = [Double](repeating: 0, count: contracts.count * contracts.count)
        let observations = try contracts.enumerated().map { index, contract in
            guard let value = values[contract.id], value.unit == contract.unit, value.value.isFinite else {
                throw CultureTwinError.invalid("missing or mismatched measured feature: \(contract.id)")
            }
            covariance[index * contracts.count + index] = contract.observationVariance
            return value.value
        }
        let request = CultureForecastRequest(session: session, featureIDs: contracts.map(\.id),
                                             measurementModelID: design.measurementModelID)
        let provider = self.provider
        let featureConfiguration = design.featureConfiguration
        // Never forward the fourth argument (observed values) received from the legacy assimilator.
        let forward: TissueTwinForwardModel = { member, parameters, state, _ in
            let result = try await provider(member, parameters, state, request)
            guard !result.nextOpaqueState.isEmpty,
                  result.recording.measurementModelID == request.measurementModelID else {
                throw CultureTwinError.invalid("simulation continuation or measurement model")
            }
            let features = try CultureFeatureExtractor.extract(result.recording, configuration: featureConfiguration)
            let map = Dictionary(uniqueKeysWithValues: features.features.map { ($0.id, $0) })
            var prediction = [String: Double]()
            for contract in contracts {
                guard let value = map[contract.id], value.unit == contract.unit else {
                    throw CultureTwinError.invalid("simulated feature unavailable: \(contract.id)")
                }
                prediction[contract.id] = value.value
            }
            return TissueTwinPrediction(observables: prediction, nextOpaqueState: result.nextOpaqueState)
        }
        let staged: SequentialTissueTwinAssimilator
        if let committed { staged = try SequentialTissueTwinAssimilator(checkpoint: committed, forwardModel: forward) }
        else { staged = try SequentialTissueTwinAssimilator(parameters: initialParameters,
            configuration: initialConfiguration, initialOpaqueState: initialState, forwardModel: forward) }
        let observation = TissueTwinObservationBatch(tick: session.simulationTick, names: contracts.map(\.id),
            values: observations, covarianceRowMajor: covariance,
            metadata: ["culture": cultureID, "session": sessionID, "source-sha256": measured.sourceSHA256.hexadecimal])
        let report = try await staged.assimilate(observation)
        guard report.accepted else { return report }
        let next = await staged.checkpoint()
        try Task.checkCancellation()
        // No suspension between cancellation check, adoption and recording the accepted session.
        committed = next; sessionIDs.append(sessionID)
        return report
    }

    public func checkpoint() throws -> CultureTwinCheckpoint {
        guard !busy, let committed else { throw CultureTwinError.invalid("no quiescent calibrated checkpoint") }
        return CultureTwinCheckpoint(schemaVersion: 1, studySHA256: try design.digest(), cultureID: cultureID,
            modelSHA256: modelSHA256, assimilatedSessionIDs: sessionIDs, ensemble: committed)
    }

    public func restore(_ source: CultureTwinCheckpoint) throws {
        guard !busy, committed == nil, source.schemaVersion == 1,
              source.studySHA256 == (try design.digest()), source.cultureID == cultureID,
              source.modelSHA256 == modelSHA256, source.ensemble.parameters == initialParameters,
              source.ensemble.configuration == initialConfiguration else {
            throw CultureTwinError.invalid("culture checkpoint authority")
        }
        let expected = design.sessions.filter { $0.cultureID == cultureID && $0.partition == .calibration }
            .sorted { ($0.simulationTick, $0.id) < ($1.simulationTick, $1.id) }
        guard !source.assimilatedSessionIDs.isEmpty, source.assimilatedSessionIDs.count <= expected.count,
              source.assimilatedSessionIDs == Array(expected.prefix(source.assimilatedSessionIDs.count).map(\.id)),
              source.ensemble.lastTick == expected[source.assimilatedSessionIDs.count - 1].simulationTick else {
            throw CultureTwinError.invalid("culture checkpoint session sequence")
        }
        let unavailable: TissueTwinForwardModel = { _, _, _, _ in
            throw CultureTwinError.unsupported("restore validation does not run simulations")
        }
        _ = try SequentialTissueTwinAssimilator(checkpoint: source.ensemble, forwardModel: unavailable)
        committed = source.ensemble; sessionIDs = source.assimilatedSessionIDs
    }
}
