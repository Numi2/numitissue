#if canImport(Metal)
import Foundation
import NumiTissueRuntime

public enum Metal4QualificationCheckKind: String, Sendable, Hashable, Codable, CaseIterable {
    case differentialEvidence
    case numericalProfiles
    case benchmarkConfiguration
    case workloadIdentity
    case finalStateIdentity
    case p95Latency
    case medianLatency
    case throughput
    case encoderCount
    case residentMemory
    case transferVolume
    case energy
    case commandFailures
}

public struct Metal4QualificationCriteria: Sendable, Hashable, Codable {
    public var minimumPassingDifferentialTransactions: Int
    public var requireScientific32Benchmarks: Bool
    public var requireMatchingBenchmarkConfiguration: Bool
    public var requireWorkloadIdentity: Bool
    public var workloadIdentityMetadataKeys: [String]
    public var requireFinalStateIdentityWhenAvailable: Bool
    public var maximumP95LatencyRatio: Double
    public var maximumMedianLatencyRatio: Double
    public var minimumThroughputRatio: Double
    public var maximumEncoderCountRatio: Double
    public var maximumResidentMemoryRatio: Double
    public var maximumTransferVolumeRatio: Double
    public var requireEnergyEvidence: Bool
    public var maximumEnergyRatio: Double
    public var requireZeroCommandFailures: Bool

    public init(
        minimumPassingDifferentialTransactions: Int = 3,
        requireScientific32Benchmarks: Bool = true,
        requireMatchingBenchmarkConfiguration: Bool = true,
        requireWorkloadIdentity: Bool = true,
        workloadIdentityMetadataKeys: [String] = [
            "workload.sha256",
            "workloadDigest",
            "workload.digest"
        ],
        requireFinalStateIdentityWhenAvailable: Bool = true,
        maximumP95LatencyRatio: Double = 0.95,
        maximumMedianLatencyRatio: Double = 0.98,
        minimumThroughputRatio: Double = 1.05,
        maximumEncoderCountRatio: Double = 0.75,
        maximumResidentMemoryRatio: Double = 1.05,
        maximumTransferVolumeRatio: Double = 1.00,
        requireEnergyEvidence: Bool = false,
        maximumEnergyRatio: Double = 1.00,
        requireZeroCommandFailures: Bool = true
    ) {
        self.minimumPassingDifferentialTransactions = minimumPassingDifferentialTransactions
        self.requireScientific32Benchmarks = requireScientific32Benchmarks
        self.requireMatchingBenchmarkConfiguration = requireMatchingBenchmarkConfiguration
        self.requireWorkloadIdentity = requireWorkloadIdentity
        self.workloadIdentityMetadataKeys = workloadIdentityMetadataKeys
        self.requireFinalStateIdentityWhenAvailable = requireFinalStateIdentityWhenAvailable
        self.maximumP95LatencyRatio = maximumP95LatencyRatio
        self.maximumMedianLatencyRatio = maximumMedianLatencyRatio
        self.minimumThroughputRatio = minimumThroughputRatio
        self.maximumEncoderCountRatio = maximumEncoderCountRatio
        self.maximumResidentMemoryRatio = maximumResidentMemoryRatio
        self.maximumTransferVolumeRatio = maximumTransferVolumeRatio
        self.requireEnergyEvidence = requireEnergyEvidence
        self.maximumEnergyRatio = maximumEnergyRatio
        self.requireZeroCommandFailures = requireZeroCommandFailures
    }

    public func validated() throws -> Self {
        guard minimumPassingDifferentialTransactions > 0 else {
            throw Metal4QualificationError.invalidMinimumDifferentialCount
        }
        let upperRatios = [
            maximumP95LatencyRatio,
            maximumMedianLatencyRatio,
            maximumEncoderCountRatio,
            maximumResidentMemoryRatio,
            maximumTransferVolumeRatio,
            maximumEnergyRatio
        ]
        guard upperRatios.allSatisfy({ $0.isFinite && $0 > 0 }),
              minimumThroughputRatio.isFinite,
              minimumThroughputRatio > 0 else {
            throw Metal4QualificationError.invalidRatio
        }
        guard workloadIdentityMetadataKeys.allSatisfy({ !$0.isEmpty }),
              Set(workloadIdentityMetadataKeys).count ==
                workloadIdentityMetadataKeys.count else {
            throw Metal4QualificationError.invalidWorkloadIdentityKeys
        }
        return self
    }
}

public struct Metal4QualificationCheck: Sendable, Hashable, Codable {
    public var kind: Metal4QualificationCheckKind
    public var passed: Bool
    public var baselineValue: Double?
    public var candidateValue: Double?
    public var ratio: Double?
    public var limit: Double?
    public var message: String

    public init(
        kind: Metal4QualificationCheckKind,
        passed: Bool,
        baselineValue: Double? = nil,
        candidateValue: Double? = nil,
        ratio: Double? = nil,
        limit: Double? = nil,
        message: String
    ) {
        self.kind = kind
        self.passed = passed
        self.baselineValue = baselineValue
        self.candidateValue = candidateValue
        self.ratio = ratio
        self.limit = limit
        self.message = message
    }
}

public struct Metal4QualificationReport: Sendable, Codable {
    public var schemaVersion: UInt32
    public var generatedAt: Date
    public var baselineBackend: String
    public var candidateBackend: String
    public var criteria: Metal4QualificationCriteria
    public var checks: [Metal4QualificationCheck]
    public var workloadIdentity: String?
    public var promotionApproved: Bool
    public var metadata: [String: String]

    public init(
        generatedAt: Date = Date(),
        baselineBackend: String,
        candidateBackend: String,
        criteria: Metal4QualificationCriteria,
        checks: [Metal4QualificationCheck],
        workloadIdentity: String?,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.baselineBackend = baselineBackend
        self.candidateBackend = candidateBackend
        self.criteria = criteria
        self.checks = checks
        self.workloadIdentity = workloadIdentity
        self.promotionApproved = checks.allSatisfy(\.passed)
        self.metadata = metadata
    }

    public var failures: [Metal4QualificationCheck] {
        checks.filter { !$0.passed }
    }
}

/// Evaluates Metal 4 against the established Metal backend. This is a promotion gate, not a score:
/// every required scientific and performance check must pass on the same workload.
public enum Metal4QualificationEvaluator {
    public static func evaluate(
        differentialReports: [DifferentialTransactionReport],
        baseline: RuntimeBenchmarkReport,
        candidate: RuntimeBenchmarkReport,
        criteria source: Metal4QualificationCriteria = .init(),
        metadata: [String: String] = [:]
    ) throws -> Metal4QualificationReport {
        let criteria = try source.validated()
        var checks: [Metal4QualificationCheck] = []
        checks.reserveCapacity(Metal4QualificationCheckKind.allCases.count)

        let passingDifferentials = differentialReports.filter(\.passed).count
        checks.append(Metal4QualificationCheck(
            kind: .differentialEvidence,
            passed: passingDifferentials >=
                criteria.minimumPassingDifferentialTransactions &&
                passingDifferentials == differentialReports.count,
            baselineValue: Double(criteria.minimumPassingDifferentialTransactions),
            candidateValue: Double(passingDifferentials),
            message: passingDifferentials == differentialReports.count
                ? "All supplied CPU–Metal 4 differential transactions passed"
                : "At least one CPU–Metal 4 differential transaction failed"
        ))

        let profilesPass = !criteria.requireScientific32Benchmarks ||
            (baseline.numericalProfile == .scientific32 &&
             candidate.numericalProfile == .scientific32)
        checks.append(Metal4QualificationCheck(
            kind: .numericalProfiles,
            passed: profilesPass,
            message: "baseline=\(baseline.numericalProfile.rawValue), candidate=\(candidate.numericalProfile.rawValue)"
        ))

        let configurationsMatch = benchmarkConfigurationMatches(
            baseline.configuration,
            candidate.configuration
        )
        checks.append(Metal4QualificationCheck(
            kind: .benchmarkConfiguration,
            passed: !criteria.requireMatchingBenchmarkConfiguration ||
                configurationsMatch,
            message: configurationsMatch
                ? "Benchmark windows and seed match"
                : "Benchmark windows or random seed differ"
        ))

        let identity = workloadIdentity(
            baseline: baseline,
            candidate: candidate,
            keys: criteria.workloadIdentityMetadataKeys
        )
        checks.append(Metal4QualificationCheck(
            kind: .workloadIdentity,
            passed: !criteria.requireWorkloadIdentity || identity != nil,
            message: identity.map { "Matched workload identity \($0)" }
                ?? "No matching workload identity was found"
        ))

        let stateIdentityPass: Bool
        let stateIdentityMessage: String
        if let baselineDigest = baseline.finalStateDigest,
           let candidateDigest = candidate.finalStateDigest {
            stateIdentityPass = baselineDigest == candidateDigest
            stateIdentityMessage = stateIdentityPass
                ? "Final-state digests match"
                : "Final-state digests differ"
        } else {
            stateIdentityPass = !criteria.requireFinalStateIdentityWhenAvailable
                || baseline.finalStateDigest == nil
                || candidate.finalStateDigest == nil
            stateIdentityMessage = "A final-state digest was unavailable; differential evidence remains authoritative"
        }
        checks.append(Metal4QualificationCheck(
            kind: .finalStateIdentity,
            passed: stateIdentityPass,
            message: stateIdentityMessage
        ))

        checks.append(upperBoundCheck(
            kind: .p95Latency,
            baseline: Double(baseline.statistics.p95Nanoseconds),
            candidate: Double(candidate.statistics.p95Nanoseconds),
            maximumRatio: criteria.maximumP95LatencyRatio,
            unit: "ns"
        ))
        checks.append(upperBoundCheck(
            kind: .medianLatency,
            baseline: Double(baseline.statistics.medianNanoseconds),
            candidate: Double(candidate.statistics.medianNanoseconds),
            maximumRatio: criteria.maximumMedianLatencyRatio,
            unit: "ns"
        ))
        checks.append(lowerBoundCheck(
            kind: .throughput,
            baseline: baseline.simulatedMillisecondsPerWallSecond,
            candidate: candidate.simulatedMillisecondsPerWallSecond,
            minimumRatio: criteria.minimumThroughputRatio,
            unit: "simulated-ms/wall-s"
        ))

        let baselineEncoderCount = totalEncoderCount(baseline.telemetry)
        let candidateEncoderCount = totalEncoderCount(candidate.telemetry)
        checks.append(optionalUpperBoundCheck(
            kind: .encoderCount,
            baseline: baselineEncoderCount,
            candidate: candidateEncoderCount,
            maximumRatio: criteria.maximumEncoderCountRatio,
            required: true,
            unit: "encoders"
        ))

        let baselineResident = residentBytes(baseline)
        let candidateResident = residentBytes(candidate)
        checks.append(upperBoundCheck(
            kind: .residentMemory,
            baseline: baselineResident,
            candidate: candidateResident,
            maximumRatio: criteria.maximumResidentMemoryRatio,
            unit: "bytes"
        ))

        let baselineTransfer = transferBytes(baseline.telemetry)
        let candidateTransfer = transferBytes(candidate.telemetry)
        checks.append(optionalUpperBoundCheck(
            kind: .transferVolume,
            baseline: baselineTransfer,
            candidate: candidateTransfer,
            maximumRatio: criteria.maximumTransferVolumeRatio,
            required: true,
            unit: "bytes"
        ))

        let baselineEnergy = baseline.telemetry?.energyJoules
        let candidateEnergy = candidate.telemetry?.energyJoules
        checks.append(optionalUpperBoundCheck(
            kind: .energy,
            baseline: baselineEnergy,
            candidate: candidateEnergy,
            maximumRatio: criteria.maximumEnergyRatio,
            required: criteria.requireEnergyEvidence,
            unit: "joules"
        ))

        let baselineFailures = baseline.telemetry?.failedCommandBuffers ?? 0
        let candidateFailures = candidate.telemetry?.failedCommandBuffers ?? 0
        checks.append(Metal4QualificationCheck(
            kind: .commandFailures,
            passed: !criteria.requireZeroCommandFailures ||
                (baselineFailures == 0 && candidateFailures == 0),
            baselineValue: Double(baselineFailures),
            candidateValue: Double(candidateFailures),
            limit: 0,
            message: "Command-buffer failures must remain zero"
        ))

        return Metal4QualificationReport(
            baselineBackend: baseline.backendName,
            candidateBackend: candidate.backendName,
            criteria: criteria,
            checks: checks,
            workloadIdentity: identity,
            metadata: metadata
        )
    }

    private static func benchmarkConfigurationMatches(
        _ lhs: RuntimeBenchmarkConfiguration,
        _ rhs: RuntimeBenchmarkConfiguration
    ) -> Bool {
        lhs.warmupTransactions == rhs.warmupTransactions &&
        lhs.measuredTransactions == rhs.measuredTransactions &&
        lhs.randomSeed == rhs.randomSeed &&
        lhs.stopOnValidationWarning == rhs.stopOnValidationWarning &&
        lhs.captureFinalDigest == rhs.captureFinalDigest
    }

    private static func workloadIdentity(
        baseline: RuntimeBenchmarkReport,
        candidate: RuntimeBenchmarkReport,
        keys: [String]
    ) -> String? {
        for key in keys {
            if let lhs = baseline.metadata[key],
               let rhs = candidate.metadata[key],
               !lhs.isEmpty,
               lhs == rhs {
                return lhs
            }
        }
        return nil
    }

    private static func residentBytes(_ report: RuntimeBenchmarkReport) -> Double {
        if let encoded = report.telemetry?.metadata["residency.allocatedBytes"],
           let value = Double(encoded), value.isFinite, value >= 0 {
            return value
        }
        return Double(report.footprint.reservedStateBytes)
    }

    private static func totalEncoderCount(
        _ telemetry: RuntimeBackendTelemetry?
    ) -> Double? {
        guard let telemetry else { return nil }
        return Double(telemetry.computeEncoders + telemetry.blitEncoders)
    }

    private static func transferBytes(
        _ telemetry: RuntimeBackendTelemetry?
    ) -> Double? {
        guard let telemetry else { return nil }
        return Double(telemetry.hostToDeviceBytes + telemetry.deviceToHostBytes)
    }

    private static func upperBoundCheck(
        kind: Metal4QualificationCheckKind,
        baseline: Double,
        candidate: Double,
        maximumRatio: Double,
        unit: String
    ) -> Metal4QualificationCheck {
        let ratio = safeRatio(candidate, baseline)
        let passed = ratio.map { $0 <= maximumRatio } ?? false
        return Metal4QualificationCheck(
            kind: kind,
            passed: passed,
            baselineValue: baseline,
            candidateValue: candidate,
            ratio: ratio,
            limit: maximumRatio,
            message: "candidate/baseline \(unit) ratio must be <= \(maximumRatio)"
        )
    }

    private static func lowerBoundCheck(
        kind: Metal4QualificationCheckKind,
        baseline: Double,
        candidate: Double,
        minimumRatio: Double,
        unit: String
    ) -> Metal4QualificationCheck {
        let ratio = safeRatio(candidate, baseline)
        let passed = ratio.map { $0 >= minimumRatio } ?? false
        return Metal4QualificationCheck(
            kind: kind,
            passed: passed,
            baselineValue: baseline,
            candidateValue: candidate,
            ratio: ratio,
            limit: minimumRatio,
            message: "candidate/baseline \(unit) ratio must be >= \(minimumRatio)"
        )
    }

    private static func optionalUpperBoundCheck(
        kind: Metal4QualificationCheckKind,
        baseline: Double?,
        candidate: Double?,
        maximumRatio: Double,
        required: Bool,
        unit: String
    ) -> Metal4QualificationCheck {
        guard let baseline, let candidate else {
            return Metal4QualificationCheck(
                kind: kind,
                passed: !required,
                baselineValue: baseline,
                candidateValue: candidate,
                limit: maximumRatio,
                message: required
                    ? "Required \(unit) evidence is missing"
                    : "\(unit) evidence was not supplied; check is non-gating"
            )
        }
        return upperBoundCheck(
            kind: kind,
            baseline: baseline,
            candidate: candidate,
            maximumRatio: maximumRatio,
            unit: unit
        )
    }

    private static func safeRatio(_ numerator: Double, _ denominator: Double) -> Double? {
        guard numerator.isFinite,
              denominator.isFinite,
              numerator >= 0,
              denominator > 0 else { return nil }
        return numerator / denominator
    }
}

public enum Metal4QualificationError: Error, Sendable, CustomStringConvertible {
    case invalidMinimumDifferentialCount
    case invalidRatio
    case invalidWorkloadIdentityKeys

    public var description: String {
        switch self {
        case .invalidMinimumDifferentialCount:
            return "Metal 4 qualification requires at least one differential transaction"
        case .invalidRatio:
            return "Metal 4 qualification ratios must be finite and positive"
        case .invalidWorkloadIdentityKeys:
            return "Metal 4 workload identity metadata keys must be unique and nonempty"
        }
    }
}
#endif
