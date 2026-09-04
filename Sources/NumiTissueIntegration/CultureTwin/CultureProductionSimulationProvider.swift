import Foundation
import NumiTissueIO
import NumiTissueRuntime

public struct CultureRuntimeObservationFrame: Sendable, Codable {
    public var sampleIndex: Int
    public var timeSeconds: Double
    public var dtMilliseconds: Double
    public var state: TissueRuntimeState

    public init(sampleIndex: Int, timeSeconds: Double, dtMilliseconds: Double,
                state: TissueRuntimeState) {
        self.sampleIndex = sampleIndex
        self.timeSeconds = timeSeconds
        self.dtMilliseconds = dtMilliseconds
        self.state = state
    }

    public func validated(expectedSampleIndex: Int) throws -> Self {
        guard sampleIndex == expectedSampleIndex,
              timeSeconds.isFinite, timeSeconds >= 0,
              dtMilliseconds.isFinite, dtMilliseconds > 0,
              !state.compartments.isEmpty else {
            throw CultureTwinError.invalid("runtime observation frame")
        }
        return self
    }
}

public struct CultureRuntimeSimulationTrace: Sendable, Codable {
    public var frames: [CultureRuntimeObservationFrame]
    public var finalOpaqueState: Data
    public var topologyRevision: UInt64
    public var metadata: [String: String]

    public init(frames: [CultureRuntimeObservationFrame], finalOpaqueState: Data,
                topologyRevision: UInt64, metadata: [String: String] = [:]) {
        self.frames = frames
        self.finalOpaqueState = finalOpaqueState
        self.topologyRevision = topologyRevision
        self.metadata = metadata
    }

    public func validated(maximumFrames: Int) throws -> Self {
        guard !frames.isEmpty, frames.count <= maximumFrames,
              !finalOpaqueState.isEmpty,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw CultureTwinError.invalid("runtime simulation trace")
        }
        for (index, frame) in frames.enumerated() {
            _ = try frame.validated(expectedSampleIndex: index)
            if index > 0 {
                guard frame.timeSeconds > frames[index - 1].timeSeconds else {
                    throw CultureTwinError.invalid("nonmonotonic runtime observation trace")
                }
            }
        }
        return self
    }
}

/// Backend-owned execution adapter. Implementations may wrap the CPU reference, scientific32 Metal,
/// or a qualified Metal 4 backend. The driver owns checkpoint restore, parameter overlay application,
/// runtime stepping, pending-event/RNG continuation and state capture. It must not read held-out
/// outcomes or perform external side effects.
public protocol CultureProductionRuntimeDriver: Sendable {
    func simulate(
        memberID: UInt64,
        parameters: [String: Double],
        priorOpaqueState: Data?,
        request: CultureForecastRequest,
        sampleRateHertz: Double,
        maximumFrames: Int
    ) async throws -> CultureRuntimeSimulationTrace
}

public struct CultureProductionProviderConfiguration: Sendable, Hashable, Codable {
    public var sampleRateHertz: Double
    public var maximumFrames: Int
    public var sourceIDBase: UInt64
    public var conductor: CultureConductor
    public var voltageReference: CultureVoltageReference
    public var contactQuadraturePoints: Int
    public var measurementModel: CultureMeasurementModel
    public var stimulationArtifacts: [CultureStimulusArtifact]

    public init(
        sampleRateHertz: Double,
        maximumFrames: Int = 2_000_000,
        sourceIDBase: UInt64 = 1,
        conductor: CultureConductor = .init(),
        voltageReference: CultureVoltageReference = .remote,
        contactQuadraturePoints: Int = 64,
        measurementModel: CultureMeasurementModel,
        stimulationArtifacts: [CultureStimulusArtifact] = []
    ) {
        self.sampleRateHertz = sampleRateHertz
        self.maximumFrames = maximumFrames
        self.sourceIDBase = sourceIDBase
        self.conductor = conductor
        self.voltageReference = voltageReference
        self.contactQuadraturePoints = contactQuadraturePoints
        self.measurementModel = measurementModel
        self.stimulationArtifacts = stimulationArtifacts
    }

    public func validated(electrodes: [MEAElectrode]) throws -> Self {
        guard sampleRateHertz.isFinite, sampleRateHertz > 0,
              maximumFrames >= 3, maximumFrames <= 10_000_000,
              contactQuadraturePoints >= 1, contactQuadraturePoints <= 4096,
              !electrodes.isEmpty else {
            throw CultureTwinError.invalid("production provider configuration")
        }
        _ = try conductor.validated()
        _ = try measurementModel.validated(sampleRateHertz: sampleRateHertz)
        for value in stimulationArtifacts { _ = try value.validated() }
        return self
    }
}

public actor CultureProductionSimulationProvider {
    private let driver: any CultureProductionRuntimeDriver
    private let electrodes: [MEAElectrode]
    private let configuration: CultureProductionProviderConfiguration
    private var cachedTopologyRevision: UInt64?
    private var cachedSourceMap: CultureRuntimeSourceMap?
    private var cachedLeadField: CultureLeadField?

    public init(driver: any CultureProductionRuntimeDriver,
                electrodes: [MEAElectrode],
                configuration: CultureProductionProviderConfiguration) throws {
        self.driver = driver
        self.electrodes = electrodes
        self.configuration = try configuration.validated(electrodes: electrodes)
    }

    public func simulate(memberID: UInt64, parameters: [String: Double], priorState: Data?,
                         request: CultureForecastRequest) async throws -> CultureSimulationResult {
        try Task.checkCancellation()
        guard parameters.values.allSatisfy(\.isFinite),
              Set(request.featureIDs).count == request.featureIDs.count,
              request.measurementModelID == configuration.measurementModel.id else {
            throw CultureTwinError.invalid("production simulation request")
        }
        let trace = try await driver.simulate(
            memberID: memberID,
            parameters: parameters,
            priorOpaqueState: priorState,
            request: request,
            sampleRateHertz: configuration.sampleRateHertz,
            maximumFrames: configuration.maximumFrames
        ).validated(maximumFrames: configuration.maximumFrames)
        try Task.checkCancellation()

        let firstState = trace.frames[0].state
        let sourceMap: CultureRuntimeSourceMap
        let leadField: CultureLeadField
        if cachedTopologyRevision == trace.topologyRevision,
           let existingMap = cachedSourceMap,
           let existingLeadField = cachedLeadField,
           existingMap.sourceIDByCompartmentIndex.count == firstState.compartments.count {
            sourceMap = existingMap
            leadField = existingLeadField
        } else {
            sourceMap = try CultureRuntimeSourceMap.from(
                state: firstState,
                sourceIDBase: configuration.sourceIDBase
            )
            leadField = try CultureLeadFieldBuilder.build(
                sources: sourceMap.sourceGeometryByCompartmentIndex,
                electrodes: electrodes,
                conductor: configuration.conductor,
                reference: configuration.voltageReference,
                contactQuadraturePoints: configuration.contactQuadraturePoints
            )
            cachedTopologyRevision = trace.topologyRevision
            cachedSourceMap = sourceMap
            cachedLeadField = leadField
        }

        var extracellular = [Double]()
        extracellular.reserveCapacity(trace.frames.count * leadField.electrodeIDs.count)
        for frame in trace.frames {
            guard frame.state.compartments.count == sourceMap.sourceIDByCompartmentIndex.count else {
                throw CultureTwinError.invalid("topology changed inside acquisition window")
            }
            let currents = try CultureRuntimeCurrentExtractor
                .totalOutwardTransmembraneCurrentsAmperes(
                    state: frame.state,
                    dtMilliseconds: frame.dtMilliseconds
                )
            extracellular.append(contentsOf: try leadField.voltages(
                totalOutwardCurrentsAmperes: currents
            ))
        }
        let processed = try CultureMeasurementProcessor.process(
            extracellularVolts: extracellular,
            sampleRateHertz: configuration.sampleRateHertz,
            electrodeIDs: leadField.electrodeIDs,
            model: configuration.measurementModel,
            artifacts: configuration.stimulationArtifacts
        )
        let identity = try ScientificCanonicalJSON.encode([
            "lead-field": leadField.geometrySHA256.hexadecimal,
            "measurement-model": try configuration.measurementModel
                .sha256(sampleRateHertz: configuration.sampleRateHertz).hexadecimal,
            "session": request.session.id,
            "topology": String(trace.topologyRevision)
        ])
        let recording = try CultureRecording(
            recordingID: request.session.id,
            startSeconds: trace.frames[0].timeSeconds,
            sampleRateHertz: configuration.sampleRateHertz,
            electrodeIDs: leadField.electrodeIDs,
            volts: processed.volts,
            validSamples: processed.valid,
            sourceSHA256: ScientificSHA256Digest(data: identity),
            measurementModelID: configuration.measurementModel.id
        ).validated(maximumValues: configuration.maximumFrames * leadField.electrodeIDs.count)
        return CultureSimulationResult(
            recording: recording,
            nextOpaqueState: trace.finalOpaqueState
        )
    }

    public nonisolated func provider() -> CultureSimulationProvider {
        { memberID, parameters, priorState, request in
            try await self.simulate(
                memberID: memberID,
                parameters: parameters,
                priorState: priorState,
                request: request
            )
        }
    }
}
