import XCTest
import NumiTissueIntegration
import NumiTissueIO

final class CulturePhase6QualificationTests: XCTestCase {
    func testIndependentCultureBaselineRejectsSharedDonor() throws {
        let request = CultureBaselineRequest(
            kind: .historicalMean,
            id: "historical",
            holdoutSessionID: "holdout",
            holdoutCultureID: "culture-b",
            holdoutDonorID: "donor-1",
            holdoutBatchID: "batch-b",
            holdoutTick: 100,
            stimulusID: "stimulus",
            requiredFeatures: ["rate"],
            independentCulture: true
        )
        let training = [CultureBaselineTrainingSession(
            sessionID: "training",
            cultureID: "culture-a",
            donorID: "donor-1",
            batchID: "batch-a",
            simulationTick: 10,
            stimulusID: "stimulus",
            values: ["rate": 4]
        )]
        XCTAssertThrowsError(try CultureBaselineForecaster.forecast(
            request: request, training: training
        ))
    }

    func testObservationEquivalenceAcceptsRoundedFP32Projection() throws {
        let electrode = MEAElectrode(
            id: ElectrodeID(rawValue: 1),
            positionMicrometers: SIMD3<Float>(0, 0, 100),
            widthMicrometers: 20,
            heightMicrometers: 20
        )
        let source = CultureCurrentSource(
            id: 1,
            geometry: .point,
            startMicrometers: SIMD3<Double>(0, 0, 0),
            endMicrometers: SIMD3<Double>(0, 0, 0),
            radiusMicrometers: 2
        )
        let field = try CultureLeadFieldBuilder.build(
            sources: [source],
            electrodes: [electrode],
            contactQuadraturePoints: 1
        )
        let currents = [1e-9]
        let reference = try field.voltages(totalOutwardCurrentsAmperes: currents)
        let result = try CultureObservationEquivalence.compare(
            id: "fp32-rounding",
            leadField: field,
            currentsAmperes: currents,
            metalVolts: reference.map(Float.init),
            tolerance: CultureObservationTolerance(
                absoluteVolts: 1e-9,
                relative: 1e-5
            )
        )
        XCTAssertTrue(result.passed)
    }

    func testDigestOnlyQualificationIsDisabled() throws {
        let digest = ScientificSHA256Digest(data: Data("fixture".utf8))
        let evidence = CultureTwinQualificationEvidence(
            modelSHA256: digest,
            studySHA256: digest,
            phase4CorpusEvidenceSHA256: [digest],
            phase5InferenceEvidenceSHA256: [digest],
            cpuMetalObservationEvidenceSHA256: digest,
            syntheticRecovery: CultureSyntheticRecoveryReport(
                parameterNames: ["parameter"],
                normalizedAbsoluteErrors: [0.01],
                maximumAllowedError: 0.1,
                identifiable: true
            ),
            intervalCalibration: [CultureIntervalCalibrationReport(
                nominalCoverage: 0.9,
                empiricalCoverage: 0.9,
                observationCount: 100,
                maximumAbsoluteCoverageError: 0.1
            )],
            hierarchicalEvaluation: CultureHierarchicalEvaluationReport(
                groupedScores: [],
                donorMeanCandidateMAE: [:],
                batchMeanCandidateMAE: [:],
                candidateOutperformedRequiredBaselines: true,
                minimumRelativeImprovement: 0.05,
                failureReasons: []
            ),
            heldOutSessionIDs: ["holdout"],
            heldOutWaveformCount: 1,
            heldOutElectrodeCount: 1,
            independentCultureCount: 1,
            independentDonorCount: 1,
            reproducibleCPUAndMetalConclusion: true,
            generatedAt: Date(timeIntervalSince1970: 1)
        )
        XCTAssertTrue(evidence.passed)
        XCTAssertThrowsError(try CultureTwinQualifier.qualify(
            evidence, issuedAt: Date(timeIntervalSince1970: 2)
        ))
    }
}
