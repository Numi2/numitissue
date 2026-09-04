import Foundation
import NumiTissueIO

public struct CultureForecastMember: Sendable, Codable {
    public var id: UInt64
    public var values: [String: Double]
    public var recordingSHA256: ScientificSHA256Digest
    public init(id: UInt64, values: [String: Double], recordingSHA256: ScientificSHA256Digest) {
        self.id = id; self.values = values; self.recordingSHA256 = recordingSHA256
    }
}

public struct CultureHeldOutForecast: Sendable, Codable {
    public var schemaVersion: UInt32
    public var sessionID: String
    public var studySHA256: ScientificSHA256Digest
    public var modelSHA256: ScientificSHA256Digest
    public var posteriorSHA256: ScientificSHA256Digest
    public var statePolicy: String
    public var members: [CultureForecastMember]
    public init(sessionID: String, studySHA256: ScientificSHA256Digest, modelSHA256: ScientificSHA256Digest,
                posteriorSHA256: ScientificSHA256Digest, statePolicy: String, members: [CultureForecastMember]) {
        self.schemaVersion = 1; self.sessionID = sessionID; self.studySHA256 = studySHA256
        self.modelSHA256 = modelSHA256; self.posteriorSHA256 = posteriorSHA256
        self.statePolicy = statePolicy; self.members = members
    }
    public func digest() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

/// Frozen-parameter forecasting. No holdout observations are accepted by this API.
public enum CultureHeldOutForecaster {
    public static func forecast(checkpoint: CultureTwinCheckpoint, design sourceDesign: CultureStudyDesign,
        sessionID: String, expectedModelSHA256: ScientificSHA256Digest,
        externalCultureInitialState: Data? = nil, maximumConcurrentSimulations: Int = 2,
        provider: @escaping CultureSimulationProvider) async throws -> CultureHeldOutForecast {
        let design = try sourceDesign.validated()
        guard checkpoint.schemaVersion == 1, checkpoint.studySHA256 == (try design.digest()),
              checkpoint.modelSHA256 == expectedModelSHA256, maximumConcurrentSimulations > 0,
              maximumConcurrentSimulations <= 64, checkpoint.ensemble.members.count >= 4,
              checkpoint.ensemble.members.count <= 4096,
              let session = design.sessions.first(where: { $0.id == sessionID }),
              session.partition != .calibration else {
            throw CultureTwinError.invalid("held-out forecast authority or bounds")
        }
        let expectedCalibration = design.sessions.filter {
            $0.cultureID == checkpoint.cultureID && $0.partition == .calibration
        }.sorted { ($0.simulationTick, $0.id) < ($1.simulationTick, $1.id) }
        guard !expectedCalibration.isEmpty, checkpoint.assimilatedSessionIDs == expectedCalibration.map(\.id),
              checkpoint.ensemble.lastTick == expectedCalibration.last?.simulationTick else {
            throw CultureTwinError.invalid("holdout requires complete scheduled calibration")
        }
        let unavailable: TissueTwinForwardModel = { _, _, _, _ in
            throw CultureTwinError.unsupported("forecast checkpoint validation")
        }
        _ = try SequentialTissueTwinAssimilator(checkpoint: checkpoint.ensemble, forwardModel: unavailable)
        let external = session.cultureID != checkpoint.cultureID
        if external {
            guard session.partition == .cultureHoldout,
                  externalCultureInitialState?.isEmpty == false else {
                throw CultureTwinError.invalid("external culture requires its own initial simulator state")
            }
        } else {
            guard session.simulationTick > (checkpoint.ensemble.lastTick ?? 0) else {
                throw CultureTwinError.leakage("forecast precedes calibrated state")
            }
        }
        let contracts = design.features.sorted { $0.id < $1.id }
        let request = CultureForecastRequest(session: session, featureIDs: contracts.map(\.id),
                                             measurementModelID: design.measurementModelID)
        let ordered = checkpoint.ensemble.members.sorted { $0.id < $1.id }
        let definitions = checkpoint.ensemble.parameters
        guard Set(definitions.map(\.name)).count == definitions.count else {
            throw CultureTwinError.invalid("duplicate checkpoint parameter")
        }
        var results = [CultureForecastMember]()
        for lower in stride(from: 0, to: ordered.count, by: maximumConcurrentSimulations) {
            try Task.checkCancellation()
            let upper = min(lower + maximumConcurrentSimulations, ordered.count)
            let batch = try await withThrowingTaskGroup(of: CultureForecastMember.self) { group in
                for member in ordered[lower..<upper] {
                    group.addTask {
                        guard member.latentParameters.count == definitions.count else {
                            throw CultureTwinError.invalid("checkpoint parameter vector")
                        }
                        var parameters = [String: Double]()
                        for index in definitions.indices {
                            parameters[definitions[index].name] = try definitions[index].decode(member.latentParameters[index])
                        }
                        let state = external ? externalCultureInitialState : member.opaqueState
                        guard state?.isEmpty == false else {
                            throw CultureTwinError.invalid("forecast requires complete simulator continuation")
                        }
                        let simulated = try await provider(member.id, parameters, state, request)
                        guard simulated.recording.measurementModelID == request.measurementModelID else {
                            throw CultureTwinError.invalid("forecast measurement-model mismatch")
                        }
                        let report = try CultureFeatureExtractor.extract(simulated.recording, configuration: design.featureConfiguration)
                        let features = Dictionary(uniqueKeysWithValues: report.features.map { ($0.id, $0) })
                        var values = [String: Double]()
                        for contract in contracts {
                            guard let value = features[contract.id], value.unit == contract.unit else {
                                throw CultureTwinError.invalid("required forecast feature unavailable: \(contract.id)")
                            }
                            values[contract.id] = value.value
                        }
                        // The new simulator state is deliberately discarded; the posterior is frozen.
                        return CultureForecastMember(id: member.id, values: values,
                                                     recordingSHA256: report.sourceSHA256)
                    }
                }
                var batch = [CultureForecastMember]()
                for try await result in group { batch.append(result) }
                return batch
            }
            results.append(contentsOf: batch)
        }
        return CultureHeldOutForecast(sessionID: sessionID, studySHA256: try design.digest(),
            modelSHA256: expectedModelSHA256, posteriorSHA256: try checkpoint.digest(),
            statePolicy: external ? "parameter-transfer-new-culture-state" : "frozen-posterior-continuation",
            members: results.sorted { $0.id < $1.id })
    }
}
