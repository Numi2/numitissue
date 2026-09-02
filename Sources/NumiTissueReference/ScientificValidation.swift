import Foundation

public struct ValidationSeries: Sendable, Hashable, Codable {
    public var name: String
    public var unit: String
    public var times: [Double]
    public var values: [Double]
    public var metadata: [String: String]

    public init(name: String, unit: String, times: [Double], values: [Double], metadata: [String: String] = [:]) {
        self.name = name
        self.unit = unit
        self.times = times
        self.values = values
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty, times.count == values.count, !times.isEmpty else { throw ScientificValidationError.invalidSeries(name) }
        guard times.allSatisfy(\.isFinite), values.allSatisfy(\.isFinite) else { throw ScientificValidationError.invalidSeries(name) }
        for index in 1..<times.count where times[index] <= times[index - 1] { throw ScientificValidationError.nonMonotonicTime(name) }
        return self
    }

    public func value(at time: Double) -> Double? {
        guard !times.isEmpty, time >= times[0], time <= times[times.count - 1] else { return nil }
        let insertion = times.partitioningIndex { $0 >= time }
        if insertion == 0 { return values[0] }
        if insertion >= times.count { return values.last }
        if times[insertion] == time { return values[insertion] }
        let lower = insertion - 1
        let fraction = (time - times[lower]) / (times[insertion] - times[lower])
        return values[lower] + fraction * (values[insertion] - values[lower])
    }
}

public struct ValidationTolerance: Sendable, Hashable, Codable {
    public var absolute: Double
    public var relative: Double
    public var rootMeanSquare: Double?
    public var maximumSpikeTimeDifference: Double?
    public var allowedMissingSpikeFraction: Double

    public init(absolute: Double, relative: Double, rootMeanSquare: Double? = nil, maximumSpikeTimeDifference: Double? = nil, allowedMissingSpikeFraction: Double = 0) {
        self.absolute = absolute
        self.relative = relative
        self.rootMeanSquare = rootMeanSquare
        self.maximumSpikeTimeDifference = maximumSpikeTimeDifference
        self.allowedMissingSpikeFraction = allowedMissingSpikeFraction
    }
}

public struct TraceComparisonResult: Sendable, Hashable, Codable {
    public var referenceName: String
    public var candidateName: String
    public var sampleCount: Int
    public var maximumAbsoluteError: Double
    public var maximumRelativeError: Double
    public var rootMeanSquareError: Double
    public var normalizedRootMeanSquareError: Double
    public var correlation: Double
    public var passed: Bool
    public var failureReasons: [String]

    public init(referenceName: String, candidateName: String, sampleCount: Int, maximumAbsoluteError: Double, maximumRelativeError: Double, rootMeanSquareError: Double, normalizedRootMeanSquareError: Double, correlation: Double, passed: Bool, failureReasons: [String]) {
        self.referenceName = referenceName
        self.candidateName = candidateName
        self.sampleCount = sampleCount
        self.maximumAbsoluteError = maximumAbsoluteError
        self.maximumRelativeError = maximumRelativeError
        self.rootMeanSquareError = rootMeanSquareError
        self.normalizedRootMeanSquareError = normalizedRootMeanSquareError
        self.correlation = correlation
        self.passed = passed
        self.failureReasons = failureReasons
    }
}

public struct SpikeComparisonResult: Sendable, Hashable, Codable {
    public var referenceCount: Int
    public var candidateCount: Int
    public var matchedCount: Int
    public var missingCount: Int
    public var extraCount: Int
    public var maximumTimeError: Double
    public var meanAbsoluteTimeError: Double
    public var passed: Bool
    public var failureReasons: [String]

    public init(referenceCount: Int, candidateCount: Int, matchedCount: Int, missingCount: Int, extraCount: Int, maximumTimeError: Double, meanAbsoluteTimeError: Double, passed: Bool, failureReasons: [String]) {
        self.referenceCount = referenceCount
        self.candidateCount = candidateCount
        self.matchedCount = matchedCount
        self.missingCount = missingCount
        self.extraCount = extraCount
        self.maximumTimeError = maximumTimeError
        self.meanAbsoluteTimeError = meanAbsoluteTimeError
        self.passed = passed
        self.failureReasons = failureReasons
    }
}

public enum ScientificTraceComparator {
    public static func compare(
        reference: ValidationSeries,
        candidate: ValidationSeries,
        tolerance: ValidationTolerance,
        sampleTimes: [Double]? = nil
    ) throws -> TraceComparisonResult {
        let reference = try reference.validated()
        let candidate = try candidate.validated()
        guard reference.unit == candidate.unit else { throw ScientificValidationError.unitMismatch(reference.unit, candidate.unit) }
        let lower = max(reference.times[0], candidate.times[0])
        let upper = min(reference.times.last!, candidate.times.last!)
        guard upper > lower else { throw ScientificValidationError.noOverlap }
        let times = sampleTimes ?? reference.times.filter { $0 >= lower && $0 <= upper }
        guard !times.isEmpty else { throw ScientificValidationError.noOverlap }
        var referenceValues: [Double] = []
        var candidateValues: [Double] = []
        var maximumAbsolute = 0.0
        var maximumRelative = 0.0
        var squared = 0.0
        for time in times {
            guard let r = reference.value(at: time), let c = candidate.value(at: time) else { continue }
            referenceValues.append(r)
            candidateValues.append(c)
            let absolute = abs(c - r)
            let relative = absolute / max(abs(r), tolerance.absolute, Double.leastNonzeroMagnitude)
            maximumAbsolute = max(maximumAbsolute, absolute)
            maximumRelative = max(maximumRelative, relative)
            squared += absolute * absolute
        }
        guard !referenceValues.isEmpty else { throw ScientificValidationError.noOverlap }
        let rms = sqrt(squared / Double(referenceValues.count))
        let range = (referenceValues.max() ?? 0) - (referenceValues.min() ?? 0)
        let normalizedRMS = rms / max(abs(range), tolerance.absolute, Double.leastNonzeroMagnitude)
        let correlation = pearson(referenceValues, candidateValues)
        var reasons: [String] = []
        if maximumAbsolute > tolerance.absolute && maximumRelative > tolerance.relative {
            reasons.append("pointwise error exceeds absolute and relative tolerances")
        }
        if let rmsTolerance = tolerance.rootMeanSquare, rms > rmsTolerance { reasons.append("RMS error exceeds tolerance") }
        return TraceComparisonResult(
            referenceName: reference.name,
            candidateName: candidate.name,
            sampleCount: referenceValues.count,
            maximumAbsoluteError: maximumAbsolute,
            maximumRelativeError: maximumRelative,
            rootMeanSquareError: rms,
            normalizedRootMeanSquareError: normalizedRMS,
            correlation: correlation,
            passed: reasons.isEmpty,
            failureReasons: reasons
        )
    }

    public static func compareSpikes(reference: [Double], candidate: [Double], tolerance: ValidationTolerance) throws -> SpikeComparisonResult {
        guard reference.allSatisfy(\.isFinite), candidate.allSatisfy(\.isFinite) else { throw ScientificValidationError.invalidSpikes }
        let maximumDifference = tolerance.maximumSpikeTimeDifference ?? tolerance.absolute
        let reference = reference.sorted()
        let candidate = candidate.sorted()
        var used = Array(repeating: false, count: candidate.count)
        var errors: [Double] = []
        for spike in reference {
            var bestIndex: Int?
            var bestError = Double.greatestFiniteMagnitude
            for index in candidate.indices where !used[index] {
                let error = abs(candidate[index] - spike)
                if error <= maximumDifference && error < bestError { bestIndex = index; bestError = error }
                if candidate[index] > spike + maximumDifference { break }
            }
            if let bestIndex { used[bestIndex] = true; errors.append(bestError) }
        }
        let missing = reference.count - errors.count
        let extra = candidate.count - errors.count
        let missingFraction = reference.isEmpty ? (candidate.isEmpty ? 0 : 1) : Double(missing) / Double(reference.count)
        var reasons: [String] = []
        if missingFraction > tolerance.allowedMissingSpikeFraction { reasons.append("missing spike fraction exceeds tolerance") }
        if !reference.isEmpty {
            let extraFraction = Double(extra) / Double(reference.count)
            if extraFraction > tolerance.allowedMissingSpikeFraction { reasons.append("extra spike fraction exceeds tolerance") }
        }
        let maximum = errors.max() ?? 0
        if maximum > maximumDifference { reasons.append("spike time error exceeds tolerance") }
        return SpikeComparisonResult(
            referenceCount: reference.count,
            candidateCount: candidate.count,
            matchedCount: errors.count,
            missingCount: missing,
            extraCount: extra,
            maximumTimeError: maximum,
            meanAbsoluteTimeError: errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count),
            passed: reasons.isEmpty,
            failureReasons: reasons
        )
    }

    private static func pearson(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, lhs.count > 1 else { return lhs == rhs ? 1 : 0 }
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var covariance = 0.0
        var lhsVariance = 0.0
        var rhsVariance = 0.0
        for index in lhs.indices {
            let x = lhs[index] - lhsMean
            let y = rhs[index] - rhsMean
            covariance += x * y
            lhsVariance += x * x
            rhsVariance += y * y
        }
        let denominator = sqrt(lhsVariance * rhsVariance)
        return denominator > 0 ? covariance / denominator : (lhs == rhs ? 1 : 0)
    }
}

public struct StatisticalSample: Sendable, Hashable, Codable {
    public var values: [Double]
    public init(_ values: [Double]) { self.values = values }

    public var mean: Double { values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count) }
    public var variance: Double {
        guard values.count > 1 else { return 0 }
        let mean = self.mean
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
    }
}

public struct DistributionComparisonResult: Sendable, Hashable, Codable {
    public var referenceMean: Double
    public var candidateMean: Double
    public var referenceVariance: Double
    public var candidateVariance: Double
    public var meanZScore: Double
    public var varianceRatio: Double
    public var kolmogorovSmirnovDistance: Double
    public var passed: Bool
    public var failureReasons: [String]
}

public enum ScientificDistributionComparator {
    public static func compare(
        reference: StatisticalSample,
        candidate: StatisticalSample,
        maximumMeanZScore: Double = 3,
        varianceRatioRange: ClosedRange<Double> = 0.5...2,
        maximumKSDistance: Double = 0.1
    ) throws -> DistributionComparisonResult {
        guard reference.values.count >= 2, candidate.values.count >= 2,
              reference.values.allSatisfy(\.isFinite), candidate.values.allSatisfy(\.isFinite) else {
            throw ScientificValidationError.insufficientStatistics
        }
        let standardError = sqrt(reference.variance / Double(reference.values.count) + candidate.variance / Double(candidate.values.count))
        let z = standardError > 0 ? abs(candidate.mean - reference.mean) / standardError : (candidate.mean == reference.mean ? 0 : .infinity)
        let varianceRatio = reference.variance > 0 ? candidate.variance / reference.variance : (candidate.variance == 0 ? 1 : .infinity)
        let ks = kolmogorovSmirnov(reference.values.sorted(), candidate.values.sorted())
        var reasons: [String] = []
        if z > maximumMeanZScore { reasons.append("mean difference exceeds sampling uncertainty") }
        if !varianceRatioRange.contains(varianceRatio) { reasons.append("variance ratio is outside acceptance range") }
        if ks > maximumKSDistance { reasons.append("empirical distribution distance exceeds tolerance") }
        return DistributionComparisonResult(
            referenceMean: reference.mean,
            candidateMean: candidate.mean,
            referenceVariance: reference.variance,
            candidateVariance: candidate.variance,
            meanZScore: z,
            varianceRatio: varianceRatio,
            kolmogorovSmirnovDistance: ks,
            passed: reasons.isEmpty,
            failureReasons: reasons
        )
    }

    private static func kolmogorovSmirnov(_ lhs: [Double], _ rhs: [Double]) -> Double {
        var i = 0
        var j = 0
        var maximum = 0.0
        while i < lhs.count || j < rhs.count {
            let next: Double
            if j >= rhs.count || (i < lhs.count && lhs[i] <= rhs[j]) { next = lhs[i] }
            else { next = rhs[j] }
            while i < lhs.count && lhs[i] <= next { i += 1 }
            while j < rhs.count && rhs[j] <= next { j += 1 }
            maximum = max(maximum, abs(Double(i) / Double(lhs.count) - Double(j) / Double(rhs.count)))
        }
        return maximum
    }
}

public struct ConservationCertificate: Sendable, Hashable, Codable {
    public var name: String
    public var initial: Double
    public var final: Double
    public var absoluteDrift: Double
    public var relativeDrift: Double
    public var tolerance: Double
    public var passed: Bool

    public init(name: String, initial: Double, final: Double, tolerance: Double) {
        self.name = name
        self.initial = initial
        self.final = final
        absoluteDrift = abs(final - initial)
        relativeDrift = absoluteDrift / max(abs(initial), Double.leastNonzeroMagnitude)
        self.tolerance = tolerance
        passed = relativeDrift <= tolerance
    }
}

public struct ScientificValidationReport: Sendable, Codable {
    public var suiteName: String
    public var generatedAt: Date
    public var traceComparisons: [TraceComparisonResult]
    public var spikeComparisons: [SpikeComparisonResult]
    public var distributionComparisons: [DistributionComparisonResult]
    public var conservationCertificates: [ConservationCertificate]
    public var metadata: [String: String]

    public init(suiteName: String, traceComparisons: [TraceComparisonResult] = [], spikeComparisons: [SpikeComparisonResult] = [], distributionComparisons: [DistributionComparisonResult] = [], conservationCertificates: [ConservationCertificate] = [], metadata: [String: String] = [:]) {
        self.suiteName = suiteName
        generatedAt = Date()
        self.traceComparisons = traceComparisons
        self.spikeComparisons = spikeComparisons
        self.distributionComparisons = distributionComparisons
        self.conservationCertificates = conservationCertificates
        self.metadata = metadata
    }

    public var passed: Bool {
        traceComparisons.allSatisfy(\.passed) && spikeComparisons.allSatisfy(\.passed) && distributionComparisons.allSatisfy(\.passed) && conservationCertificates.allSatisfy(\.passed)
    }
}

public enum ValidationCSV {
    public static func readSeries(url: URL, name: String, unit: String, timeColumn: Int = 0, valueColumn: Int = 1, delimiter: Character = ",") throws -> ValidationSeries {
        let source = try String(contentsOf: url, encoding: .utf8)
        var times: [Double] = []
        var values: [Double] = []
        for (lineNumber, raw) in source.split(whereSeparator: \.isNewline).enumerated() {
            let fields = raw.split(separator: delimiter, omittingEmptySubsequences: false)
            guard timeColumn < fields.count, valueColumn < fields.count else { continue }
            guard let time = Double(fields[timeColumn].trimmingCharacters(in: .whitespaces)), let value = Double(fields[valueColumn].trimmingCharacters(in: .whitespaces)) else {
                if lineNumber == 0 { continue }
                throw ScientificValidationError.invalidCSV(lineNumber + 1)
            }
            times.append(time); values.append(value)
        }
        return try ValidationSeries(name: name, unit: unit, times: times, values: values, metadata: ["source": url.path]).validated()
    }
}

private extension Array where Element == Double {
    func partitioningIndex(where predicate: (Double) -> Bool) -> Int {
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = (lower + upper) / 2
            if predicate(self[middle]) { upper = middle } else { lower = middle + 1 }
        }
        return lower
    }
}

public enum ScientificValidationError: Error, Sendable, CustomStringConvertible {
    case invalidSeries(String)
    case nonMonotonicTime(String)
    case unitMismatch(String, String)
    case noOverlap
    case invalidSpikes
    case insufficientStatistics
    case invalidCSV(Int)

    public var description: String {
        switch self {
        case .invalidSeries(let value): return "Validation series \(value) is invalid"
        case .nonMonotonicTime(let value): return "Validation series \(value) time is not strictly increasing"
        case .unitMismatch(let lhs, let rhs): return "Validation units differ: \(lhs) versus \(rhs)"
        case .noOverlap: return "Validation series have no overlapping samples"
        case .invalidSpikes: return "Spike time sequence contains non-finite values"
        case .insufficientStatistics: return "Statistical validation requires at least two finite samples per group"
        case .invalidCSV(let line): return "Validation CSV contains invalid numeric data on line \(line)"
        }
    }
}
