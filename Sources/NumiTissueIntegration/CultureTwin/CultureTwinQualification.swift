import Foundation
import NumiTissueIO

public struct CultureSyntheticRecoveryReport: Sendable, Hashable, Codable {
    public var parameterNames: [String]
    public var normalizedAbsoluteErrors: [Double]
    public var maximumAllowedError: Double
    public var identifiable: Bool

    public init(parameterNames: [String], normalizedAbsoluteErrors: [Double],
                maximumAllowedError: Double, identifiable: Bool) {
        self.parameterNames = parameterNames
        self.normalizedAbsoluteErrors = normalizedAbsoluteErrors
        self.maximumAllowedError = maximumAllowedError
        self.identifiable = identifiable
    }

    public func validated() throws -> Self {
        guard !parameterNames.isEmpty,
              Set(parameterNames).count == parameterNames.count,
              normalizedAbsoluteErrors.count == parameterNames.count,
              normalizedAbsoluteErrors.allSatisfy({ $0.isFinite && $0 >= 0 }),
              maximumAllowedError.isFinite, maximumAllowedError > 0 else {
            throw CultureTwinError.invalid("synthetic recovery report")
        }
        return self
    }

    public var passed: Bool {
        identifiable && normalizedAbsoluteErrors.allSatisfy { $0 <= maximumAllowedError }
    }
}

public struct CultureIntervalCalibrationReport: Sendable, Hashable, Codable {
    public var nominalCoverage: Double
    public var empiricalCoverage: Double
    public var observationCount: Int
    public var maximumAbsoluteCoverageError: Double

    public init(nominalCoverage: Double, empiricalCoverage: Double, observationCount: Int,
                maximumAbsoluteCoverageError: Double) {
        self.nominalCoverage = nominalCoverage; self.empiricalCoverage = empiricalCoverage
        self.observationCount = observationCount
        self.maximumAbsoluteCoverageError = maximumAbsoluteCoverageError
    }

    public func validated() throws -> Self {
        guard nominalCoverage.isFinite, nominalCoverage > 0, nominalCoverage < 1,
              empiricalCoverage.isFinite, empiricalCoverage >= 0, empiricalCoverage <= 1,
              observationCount > 0,
              maximumAbsoluteCoverageError.isFinite,
              maximumAbsoluteCoverageError >= 0,
              maximumAbsoluteCoverageError < 1 else {
            throw CultureTwinError.invalid("interval calibration report")
        }
        return self
    }

    public var passed: Bool {
        abs(empiricalCoverage - nominalCoverage) <= maximumAbsoluteCoverageError
    }
}

public struct CultureTwinQualificationEvidence: Sendable, Codable {
    public var schemaVersion: UInt32
    public var modelSHA256: ScientificSHA256Digest
    public var studySHA256: ScientificSHA256Digest
    public var phase4CorpusEvidenceSHA256: [ScientificSHA256Digest]
    public var phase5InferenceEvidenceSHA256: [ScientificSHA256Digest]
    public var cpuMetalObservationEvidenceSHA256: ScientificSHA256Digest
    public var syntheticRecovery: CultureSyntheticRecoveryReport
    public var intervalCalibration: [CultureIntervalCalibrationReport]
    public var hierarchicalEvaluation: CultureHierarchicalEvaluationReport
    public var heldOutSessionIDs: [String]
    public var heldOutWaveformCount: Int
    public var heldOutElectrodeCount: Int
    public var independentCultureCount: Int
    public var independentDonorCount: Int
    public var reproducibleCPUAndMetalConclusion: Bool
    public var generatedAt: Date
    public var metadata: [String: String]

    public init(modelSHA256: ScientificSHA256Digest, studySHA256: ScientificSHA256Digest,
                phase4CorpusEvidenceSHA256: [ScientificSHA256Digest],
                phase5InferenceEvidenceSHA256: [ScientificSHA256Digest],
                cpuMetalObservationEvidenceSHA256: ScientificSHA256Digest,
                syntheticRecovery: CultureSyntheticRecoveryReport,
                intervalCalibration: [CultureIntervalCalibrationReport],
                hierarchicalEvaluation: CultureHierarchicalEvaluationReport,
                heldOutSessionIDs: [String], heldOutWaveformCount: Int,
                heldOutElectrodeCount: Int, independentCultureCount: Int,
                independentDonorCount: Int, reproducibleCPUAndMetalConclusion: Bool,
                generatedAt: Date, metadata: [String: String] = [:]) {
        self.schemaVersion = 1; self.modelSHA256 = modelSHA256; self.studySHA256 = studySHA256
        self.phase4CorpusEvidenceSHA256 = phase4CorpusEvidenceSHA256
        self.phase5InferenceEvidenceSHA256 = phase5InferenceEvidenceSHA256
        self.cpuMetalObservationEvidenceSHA256 = cpuMetalObservationEvidenceSHA256
        self.syntheticRecovery = syntheticRecovery; self.intervalCalibration = intervalCalibration
        self.hierarchicalEvaluation = hierarchicalEvaluation; self.heldOutSessionIDs = heldOutSessionIDs
        self.heldOutWaveformCount = heldOutWaveformCount; self.heldOutElectrodeCount = heldOutElectrodeCount
        self.independentCultureCount = independentCultureCount; self.independentDonorCount = independentDonorCount
        self.reproducibleCPUAndMetalConclusion = reproducibleCPUAndMetalConclusion
        self.generatedAt = generatedAt; self.metadata = metadata
    }

    public func validated() throws -> Self {
        _ = try syntheticRecovery.validated()
        for report in intervalCalibration { _ = try report.validated() }
        guard schemaVersion == 1,
              !phase4CorpusEvidenceSHA256.isEmpty,
              !phase5InferenceEvidenceSHA256.isEmpty,
              Set(phase4CorpusEvidenceSHA256).count == phase4CorpusEvidenceSHA256.count,
              Set(phase5InferenceEvidenceSHA256).count == phase5InferenceEvidenceSHA256.count,
              !intervalCalibration.isEmpty,
              !heldOutSessionIDs.isEmpty,
              Set(heldOutSessionIDs).count == heldOutSessionIDs.count,
              heldOutWaveformCount > 0,
              heldOutElectrodeCount > 0,
              independentCultureCount > 0,
              independentDonorCount > 0,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw CultureTwinError.invalid("Phase 6 qualification evidence")
        }
        return self
    }

    public var passed: Bool {
        syntheticRecovery.passed
            && intervalCalibration.allSatisfy(\.passed)
            && hierarchicalEvaluation.candidateOutperformedRequiredBaselines
            && reproducibleCPUAndMetalConclusion
            && heldOutWaveformCount > 0
            && heldOutElectrodeCount > 0
            && independentCultureCount > 0
            && independentDonorCount > 0
    }

    public func digest() throws -> ScientificSHA256Digest {
        _ = try validated()
        return ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

public struct CultureTwinQualificationCertificate: Sendable, Codable {
    public var schemaVersion: UInt32
    public var evidenceSHA256: ScientificSHA256Digest
    public var modelSHA256: ScientificSHA256Digest
    public var studySHA256: ScientificSHA256Digest
    public var issuedAt: Date
    public var claim: String

    public init(evidenceSHA256: ScientificSHA256Digest, modelSHA256: ScientificSHA256Digest,
                studySHA256: ScientificSHA256Digest, issuedAt: Date, claim: String) {
        self.schemaVersion = 1; self.evidenceSHA256 = evidenceSHA256
        self.modelSHA256 = modelSHA256; self.studySHA256 = studySHA256
        self.issuedAt = issuedAt; self.claim = claim
    }
}

public enum CultureTwinQualifier {
    public static func qualify(_ source: CultureTwinQualificationEvidence,
                               issuedAt: Date) throws -> CultureTwinQualificationCertificate {
        let evidence = try source.validated()
        guard evidence.passed else {
            throw CultureTwinError.invalid("Phase 6 exit gate not satisfied")
        }
        return CultureTwinQualificationCertificate(
            evidenceSHA256: try evidence.digest(),
            modelSHA256: evidence.modelSHA256,
            studySHA256: evidence.studySHA256,
            issuedAt: issuedAt,
            claim: "This bounded neural-culture twin passed preregistered synthetic recovery, predictive-calibration, required-baseline, held-out stimulation/electrode, independent-culture/donor, and CPU/Metal conclusion gates."
        )
    }
}
