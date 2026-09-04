import XCTest
import NumiTissueCore
import NumiTissueRuntime
import NumiTissueIntegration
import NumiTissueIO

final class CulturePhase6CompletionTests: XCTestCase {
    func testTransmembraneCurrentUsesChargeAndAxialBalance() throws {
        var state = TissueRuntimeState()
        state.compartments = [
            RuntimeCompartmentState(id: CompartmentID(rawValue: 1), neuronIndex: 0,
                capacitanceNanofarads: 1, injectedCurrentNanoamps: 2),
            RuntimeCompartmentState(id: CompartmentID(rawValue: 2), neuronIndex: 0,
                parentIndex: 0, voltageMillivolts: -60, previousVoltageMillivolts: -61,
                capacitanceNanofarads: 2, axialConductanceMicrosiemens: 0.5,
                injectedCurrentNanoamps: 1)
        ]
        let balance = try CultureRuntimeCurrentExtractor.balance(state: state, dtMilliseconds: 1)
        let currents = try CultureRuntimeCurrentExtractor.totalOutwardTransmembraneCurrentsAmperes(
            state: state, dtMilliseconds: 1)
        XCTAssertEqual(currents.count, 2)
        // Total outward current INCLUDES capacitance: injected + net axial inflow.
        XCTAssertEqual(currents[0], 4.5e-9, accuracy: 1e-15)
        XCTAssertEqual(currents[1], -1.5e-9, accuracy: 1e-15)
        XCTAssertEqual(currents.reduce(0, +), 3e-9, accuracy: 1e-15)
        XCTAssertEqual(balance.capacitiveOutwardAmperes[1], 2e-9, accuracy: 1e-15)
        XCTAssertEqual(balance.ionicAndSynapticOutwardAmperes[1], -3.5e-9, accuracy: 1e-15)
        for i in currents.indices {
            XCTAssertEqual(currents[i], balance.capacitiveOutwardAmperes[i] +
                balance.ionicAndSynapticOutwardAmperes[i], accuracy: 1e-15)
        }
    }

    func testMeasurementProcessorBlanksStimulusArtifact() throws {
        let id = ElectrodeID(rawValue: 1)
        let model = CultureMeasurementModel(
            id: "fixture",
            interfaces: [CultureElectrodeInterface(
                electrode: id,
                seriesResistanceOhms: 1_000,
                doubleLayerCapacitanceFarads: 1e-6,
                chargeTransferResistanceOhms: 100_000
            )],
            highPassHertz: 0,
            lowPassHertz: 400,
            blankingSecondsAfterStimulus: 0.003,
            commonModeRejection: 0
        )
        let result = try CultureMeasurementProcessor.process(
            extracellularVolts: Array(repeating: 1e-6, count: 20),
            sampleRateHertz: 1_000,
            electrodeIDs: [id],
            model: model,
            artifacts: [CultureStimulusArtifact(
                electrode: id, startSeconds: 0.005,
                chargeCoulombs: 1e-9, couplingOhms: 1_000,
                decaySeconds: 0.001
            )]
        )
        XCTAssertEqual(result.volts.count, 20)
        XCTAssertFalse(result.valid[5])
        XCTAssertFalse(result.valid[7])
        XCTAssertTrue(result.valid[10])
    }

    func testEvokedFeaturesReportLatency() throws {
        let id = ElectrodeID(rawValue: 1)
        var values = [Double](repeating: 0, count: 200)
        values[110] = -100e-6
        let recording = try CultureRecording(
            recordingID: "evoked",
            startSeconds: 0,
            sampleRateHertz: 1_000,
            electrodeIDs: [id],
            volts: values,
            sourceSHA256: ScientificSHA256Digest(data: Data("evoked".utf8)),
            measurementModelID: "fixture"
        ).validated()
        let report = try CultureEvokedFeatureExtractor.extract(
            recording: recording,
            stimulus: CultureStimulusEpoch(
                id: "stimulus",
                onsetSeconds: 0.100,
                electrode: id,
                responseWindowSeconds: 0.001...0.100
            )
        )
        let map = Dictionary(uniqueKeysWithValues: report.features.map { ($0.id, $0.value) })
        XCTAssertEqual(map["evoked-latency-e1"] ?? -1, 0.010, accuracy: 0.0011)
        XCTAssertLessThan(map["evoked-amplitude-e1"] ?? 0, 0)
    }

    func testQualifierFailsWithoutBaselineOutperformance() throws {
        let digest = ScientificSHA256Digest(data: Data("x".utf8))
        let evidence = CultureTwinQualificationEvidence(
            modelSHA256: digest,
            studySHA256: digest,
            phase4CorpusEvidenceSHA256: [digest],
            phase5InferenceEvidenceSHA256: [digest],
            cpuMetalObservationEvidenceSHA256: digest,
            syntheticRecovery: CultureSyntheticRecoveryReport(
                parameterNames: ["g"], normalizedAbsoluteErrors: [0.01],
                maximumAllowedError: 0.1, identifiable: true
            ),
            intervalCalibration: [CultureIntervalCalibrationReport(
                nominalCoverage: 0.9, empiricalCoverage: 0.9,
                observationCount: 100, maximumAbsoluteCoverageError: 0.1
            )],
            hierarchicalEvaluation: CultureHierarchicalEvaluationReport(
                groupedScores: [], donorMeanCandidateMAE: [:], batchMeanCandidateMAE: [:],
                candidateOutperformedRequiredBaselines: false,
                minimumRelativeImprovement: 0.05,
                failureReasons: ["fixture"]
            ),
            heldOutSessionIDs: ["session"],
            heldOutWaveformCount: 1,
            heldOutElectrodeCount: 1,
            independentCultureCount: 1,
            independentDonorCount: 1,
            reproducibleCPUAndMetalConclusion: true,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertFalse(evidence.passed)
        XCTAssertThrowsError(try CultureTwinQualifier.qualify(
            evidence, issuedAt: Date(timeIntervalSince1970: 2)
        ))
    }
}
