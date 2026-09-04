import Foundation

public enum ProspectiveClaimKind: String, Sendable, Hashable, Codable, CaseIterable {
    case prospectiveOutperformance = "prospective-outperformance"
    case calibratedProspectivePrediction = "calibrated-prospective-prediction"
}

public struct ProspectiveClaimCertificate: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var claimID: UUID
    public var kind: ProspectiveClaimKind
    public var studyID: String
    public var issuedAt: Date
    public var issuedBy: String
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var protocolSHA256: ScientificSHA256Digest
    public var scoreReportSHA256: ScientificSHA256Digest
    public var terminalEvidenceSHA256: ScientificSHA256Digest
    public var primaryScore: Double
    public var requiredBaselineComparisons: [ProspectiveBaselineComparison]
    public var maximumObservedCalibrationError: Double
    public var noPostUnblindingMutation: Bool
    public var claim: String
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        claimID: UUID = UUID(),
        kind: ProspectiveClaimKind,
        studyID: String,
        issuedAt: Date,
        issuedBy: String,
        modelFreezeSHA256: ScientificSHA256Digest,
        protocolSHA256: ScientificSHA256Digest,
        scoreReportSHA256: ScientificSHA256Digest,
        terminalEvidenceSHA256: ScientificSHA256Digest,
        primaryScore: Double,
        requiredBaselineComparisons: [ProspectiveBaselineComparison],
        maximumObservedCalibrationError: Double,
        noPostUnblindingMutation: Bool,
        claim: String,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.claimID = claimID
        self.kind = kind
        self.studyID = studyID
        self.issuedAt = issuedAt
        self.issuedBy = issuedBy
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.protocolSHA256 = protocolSHA256
        self.scoreReportSHA256 = scoreReportSHA256
        self.terminalEvidenceSHA256 = terminalEvidenceSHA256
        self.primaryScore = primaryScore
        self.requiredBaselineComparisons = requiredBaselineComparisons
        self.maximumObservedCalibrationError = maximumObservedCalibrationError
        self.noPostUnblindingMutation = noPostUnblindingMutation
        self.claim = claim
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              ProspectiveIdentifier.isStable(studyID),
              !issuedBy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              primaryScore.isFinite,
              primaryScore >= 0,
              !requiredBaselineComparisons.isEmpty,
              requiredBaselineComparisons.allSatisfy({ $0.requiredForSuccess && $0.passed }),
              maximumObservedCalibrationError.isFinite,
              maximumObservedCalibrationError >= 0,
              maximumObservedCalibrationError <= 1,
              noPostUnblindingMutation,
              !claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveEvidenceError.invalidClaim
        }
        for comparison in requiredBaselineComparisons {
            _ = try comparison.validated()
        }
        return self
    }

    public func validated(
        against sourceEvidence: ProspectiveTerminalEvidence
    ) throws -> Self {
        let certificate = try validated()
        let evidence = try sourceEvidence.validated()
        let required = evidence.score.comparisons
            .filter(\.requiredForSuccess)
            .sorted { $0.baselineID < $1.baselineID }
        let qualifiedCoverage = evidence.score.coverage.filter {
            $0.sampleCount >= evidence.protocolValue.successCriteria.minimumCoverageSampleCount
        }
        let maximumCalibrationError = qualifiedCoverage
            .map(\.absoluteCoverageError)
            .max() ?? 1
        guard certificate.studyID == evidence.protocolValue.prospectiveStudyIdentifier,
              certificate.issuedAt >= evidence.sealedAt,
              certificate.modelFreezeSHA256 == (try evidence.freeze.sha256()),
              certificate.protocolSHA256 == (try evidence.protocolValue.sha256()),
              certificate.scoreReportSHA256 == (try evidence.score.sha256()),
              certificate.terminalEvidenceSHA256 == (try evidence.sha256()),
              certificate.primaryScore == evidence.score.candidate.primaryAggregateScore,
              certificate.requiredBaselineComparisons.sorted(by: { $0.baselineID < $1.baselineID }) == required,
              certificate.maximumObservedCalibrationError == maximumCalibrationError,
              certificate.noPostUnblindingMutation == evidence.score.compliance.noPostUnblindingMutation else {
            throw ProspectiveEvidenceError.invalidClaim
        }
        return certificate
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public enum ProspectiveClaimIssuer {
    public static func issue(
        evidence source: ProspectiveTerminalEvidence,
        kind: ProspectiveClaimKind = .prospectiveOutperformance,
        issuedAt: Date,
        issuedBy: String,
        metadata: [String: String] = [:]
    ) throws -> ProspectiveClaimCertificate {
        let evidence = try source.validated()
        let score = evidence.score
        guard score.passed,
              score.failureReasons.isEmpty,
              score.compliance.noPostFreezeMutation,
              score.compliance.noPostUnblindingMutation,
              score.compliance.disqualifyingDeviationCount == 0 else {
            throw ProspectiveEvidenceError.scoreDidNotPass
        }
        let required = score.comparisons.filter(\.requiredForSuccess)
        guard !required.isEmpty, required.allSatisfy(\.passed) else {
            throw ProspectiveEvidenceError.requiredBaselineDidNotPass
        }
        let qualifiedCoverage = score.coverage.filter {
            $0.sampleCount >= evidence.protocolValue.successCriteria.minimumCoverageSampleCount
        }
        let maximumCalibrationError = qualifiedCoverage
            .map(\.absoluteCoverageError)
            .max() ?? 1
        guard !qualifiedCoverage.isEmpty,
              maximumCalibrationError <= evidence.protocolValue.successCriteria.maximumAbsoluteCoverageError else {
            throw ProspectiveEvidenceError.uncalibratedForecast
        }
        guard issuedAt >= evidence.sealedAt else {
            throw ProspectiveEvidenceError.invalidClaim
        }
        let comparisonText = required
            .sorted { $0.baselineID < $1.baselineID }
            .map { comparison in
                "\(comparison.baselineID)=\(String(format: "%.4f", comparison.relativeImprovement))"
            }
            .joined(separator: ",")
        let claim = "Frozen NumiTissue predictions prospectively outperformed all required preregistered baselines for study \(evidence.protocolValue.prospectiveStudyIdentifier); relative improvements: \(comparisonText)."
        let certificate = ProspectiveClaimCertificate(
            kind: kind,
            studyID: evidence.protocolValue.prospectiveStudyIdentifier,
            issuedAt: issuedAt,
            issuedBy: issuedBy,
            modelFreezeSHA256: try evidence.freeze.sha256(),
            protocolSHA256: try evidence.protocolValue.sha256(),
            scoreReportSHA256: try score.sha256(),
            terminalEvidenceSHA256: try evidence.sha256(),
            primaryScore: score.candidate.primaryAggregateScore,
            requiredBaselineComparisons: required,
            maximumObservedCalibrationError: maximumCalibrationError,
            noPostUnblindingMutation: true,
            claim: claim,
            metadata: metadata
        )
        return try certificate.validated(against: evidence)
    }
}

extension ProspectiveExperimentProtocol {
    var prospectiveStudyIdentifier: String {
        "study-\(id.uuidString.lowercased())"
    }
}

public enum ProspectiveEvidenceError: Error, Sendable, CustomStringConvertible {
    case invalidEvent(UInt64)
    case invalidChain(UInt64)
    case invalidLedger
    case incompleteLedger
    case openLedger
    case nonMonotonicTimeline
    case invalidEventOrder(ProspectiveEvidenceEventKind)
    case candidateAuthorityRequired
    case missingBaselineForecast
    case invalidBaselineForecast
    case evidenceMismatch
    case ledgerArtifactMismatch(ProspectiveEvidenceEventKind)
    case invalidClaim
    case scoreDidNotPass
    case requiredBaselineDidNotPass
    case uncalibratedForecast

    public var description: String {
        switch self {
        case .invalidEvent(let sequence): return "Prospective evidence event \(sequence) is invalid."
        case .invalidChain(let sequence): return "Prospective evidence chain breaks at sequence \(sequence)."
        case .invalidLedger: return "Prospective evidence ledger is invalid."
        case .incompleteLedger: return "Prospective evidence ledger is missing required lifecycle events."
        case .openLedger: return "Prospective evidence ledger is not terminally closed."
        case .nonMonotonicTimeline: return "Prospective evidence timeline is not monotonic."
        case .invalidEventOrder(let kind): return "Prospective evidence event \(kind.rawValue) is out of order or duplicated."
        case .candidateAuthorityRequired: return "Terminal evidence requires a frozen-model candidate forecast."
        case .missingBaselineForecast: return "Terminal evidence has no preregistered baseline forecast."
        case .invalidBaselineForecast: return "Terminal evidence contains an invalid or duplicate baseline forecast."
        case .evidenceMismatch: return "Prospective terminal evidence contains mismatched identities."
        case .ledgerArtifactMismatch(let kind): return "Prospective evidence ledger does not bind the \(kind.rawValue) artifact."
        case .invalidClaim: return "Prospective claim certificate is invalid."
        case .scoreDidNotPass: return "A prospective claim cannot be issued from a failed score report."
        case .requiredBaselineDidNotPass: return "A prospective claim requires every preregistered required baseline comparison to pass."
        case .uncalibratedForecast: return "A prospective claim requires calibrated uncertainty within the preregistered tolerance."
        }
    }
}
