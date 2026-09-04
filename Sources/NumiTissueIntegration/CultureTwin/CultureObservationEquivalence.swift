import Foundation
import NumiTissueIO

public struct CultureObservationTolerance: Sendable, Hashable, Codable {
    public var absoluteVolts: Double
    public var relative: Double

    public init(absoluteVolts: Double = 1e-7, relative: Double = 1e-4) {
        self.absoluteVolts = absoluteVolts; self.relative = relative
    }

    public func validated() throws -> Self {
        guard absoluteVolts.isFinite, absoluteVolts >= 0,
              relative.isFinite, relative >= 0 else {
            throw CultureTwinError.invalid("observation tolerance")
        }
        return self
    }
}

public struct CultureObservationEquivalenceCase: Sendable, Codable {
    public var id: String
    public var leadFieldSHA256: ScientificSHA256Digest
    public var currentSHA256: ScientificSHA256Digest
    public var cpuVolts: [Double]
    public var metalVolts: [Double]
    public var maximumAbsoluteErrorVolts: Double
    public var maximumRelativeError: Double
    public var passed: Bool
}

public struct CultureObservationEquivalenceReport: Sendable, Codable {
    public var schemaVersion: UInt32
    public var numericalProfile: String
    public var deviceIdentity: String
    public var tolerance: CultureObservationTolerance
    public var cases: [CultureObservationEquivalenceCase]
    public var generatedAt: Date
    public var passed: Bool

    public func validated() throws -> Self {
        _ = try tolerance.validated()
        guard schemaVersion == 1, numericalProfile == "scientific32",
              !deviceIdentity.isEmpty, !cases.isEmpty,
              Set(cases.map(\.id)).count == cases.count,
              passed == cases.allSatisfy(\.passed) else {
            throw CultureTwinError.invalid("observation equivalence report")
        }
        return self
    }

    public func digest() throws -> ScientificSHA256Digest {
        _ = try validated()
        return ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

public enum CultureObservationEquivalence {
    /// Compares caller-supplied Metal results against the deterministic FP64 observation reference.
    /// The Metal values must come from `MetalCultureLeadField`; this function does not execute GPU work.
    public static func compare(
        id: String,
        leadField: CultureLeadField,
        currentsAmperes: [Double],
        metalVolts: [Float],
        tolerance sourceTolerance: CultureObservationTolerance = .init()
    ) throws -> CultureObservationEquivalenceCase {
        let tolerance = try sourceTolerance.validated()
        let field = try leadField.validated()
        let cpu = try field.voltages(totalOutwardCurrentsAmperes: currentsAmperes)
        guard !id.isEmpty, metalVolts.count == cpu.count,
              metalVolts.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("Metal observation result")
        }
        let metal = metalVolts.map(Double.init)
        var maxAbsolute = 0.0
        var maxRelative = 0.0
        var passed = true
        for index in cpu.indices {
            let absolute = abs(cpu[index] - metal[index])
            let relative = absolute / max(abs(cpu[index]), abs(metal[index]), 1e-15)
            maxAbsolute = max(maxAbsolute, absolute)
            maxRelative = max(maxRelative, relative)
            if absolute > tolerance.absoluteVolts + tolerance.relative * max(abs(cpu[index]), abs(metal[index])) {
                passed = false
            }
        }
        return CultureObservationEquivalenceCase(
            id: id,
            leadFieldSHA256: field.geometrySHA256,
            currentSHA256: ScientificSHA256Digest(
                data: try ScientificCanonicalJSON.encode(currentsAmperes)
            ),
            cpuVolts: cpu,
            metalVolts: metal,
            maximumAbsoluteErrorVolts: maxAbsolute,
            maximumRelativeError: maxRelative,
            passed: passed
        )
    }

    public static func report(
        cases: [CultureObservationEquivalenceCase],
        tolerance: CultureObservationTolerance,
        deviceIdentity: String,
        generatedAt: Date
    ) throws -> CultureObservationEquivalenceReport {
        let report = CultureObservationEquivalenceReport(
            schemaVersion: 1,
            numericalProfile: "scientific32",
            deviceIdentity: deviceIdentity,
            tolerance: tolerance,
            cases: cases,
            generatedAt: generatedAt,
            passed: cases.allSatisfy(\.passed)
        )
        return try report.validated()
    }
}
