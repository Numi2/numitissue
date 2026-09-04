import Foundation
import NumiTissueIO

public enum ProspectiveSuiteComponent: String, Sendable, Hashable, Codable, CaseIterable {
    case numiTissue = "numitissue"
    case numiBrain = "numibrain"
    case numanX = "numanx"
    case derived
}

public struct ProspectiveSuiteOutputBinding: Sendable, Hashable, Codable {
    public var targetID: String
    public var component: ProspectiveSuiteComponent
    public var outputPath: String
    public var sourceUnit: String
    public var canonicalUnit: String
    public var scale: Double
    public var offset: Double
    public var metadata: [String: String]

    public init(
        targetID: String,
        component: ProspectiveSuiteComponent,
        outputPath: String,
        sourceUnit: String,
        canonicalUnit: String,
        scale: Double = 1,
        offset: Double = 0,
        metadata: [String: String] = [:]
    ) {
        self.targetID = targetID
        self.component = component
        self.outputPath = outputPath
        self.sourceUnit = sourceUnit
        self.canonicalUnit = canonicalUnit
        self.scale = scale
        self.offset = offset
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard ProspectiveStudyIdentifier.isStable(targetID),
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !canonicalUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              scale.isFinite,
              scale != 0,
              offset.isFinite,
              metadata.keys.allSatisfy(ProspectiveStudyIdentifier.isMetadataKey) else {
            throw ProspectiveSuiteForecastAdapterError.invalidBinding(targetID)
        }
        return self
    }
}

public struct ProspectiveSuiteOutputSample: Sendable, Hashable, Codable {
    public var memberID: String
    public var randomSeed: UInt64
    public var blindedID: String
    public var targetID: String
    public var timeSeconds: Double
    public var component: ProspectiveSuiteComponent
    public var outputPath: String
    public var sourceUnit: String
    public var value: Double
    public var sourceArtifactSHA256: ScientificSHA256Digest

    public init(
        memberID: String,
        randomSeed: UInt64,
        blindedID: String,
        targetID: String,
        timeSeconds: Double,
        component: ProspectiveSuiteComponent,
        outputPath: String,
        sourceUnit: String,
        value: Double,
        sourceArtifactSHA256: ScientificSHA256Digest
    ) {
        self.memberID = memberID
        self.randomSeed = randomSeed
        self.blindedID = blindedID
        self.targetID = targetID
        self.timeSeconds = timeSeconds
        self.component = component
        self.outputPath = outputPath
        self.sourceUnit = sourceUnit
        self.value = value
        self.sourceArtifactSHA256 = sourceArtifactSHA256
    }

    public func validated() throws -> Self {
        guard ProspectiveStudyIdentifier.isStable(memberID),
              randomSeed != 0,
              ProspectiveStudyIdentifier.isStable(blindedID),
              ProspectiveStudyIdentifier.isStable(targetID),
              timeSeconds.isFinite,
              timeSeconds >= 0,
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.isFinite else {
            throw ProspectiveSuiteForecastAdapterError.invalidSample
        }
        return self
    }
}

public enum ProspectiveSuiteForecastAdapter {
    public static func assemble(
        protocol sourceProtocol: ProspectiveExperimentProtocol,
        freeze sourceFreeze: ProspectiveModelFreezeCertificate? = nil,
        authority: ProspectiveForecastAuthority,
        issuedAt: Date,
        bindings sourceBindings: [ProspectiveSuiteOutputBinding],
        samples sourceSamples: [ProspectiveSuiteOutputSample],
        supportingArtifactSHA256: [ScientificSHA256Digest],
        configuration: ProspectiveEnsembleForecastConfiguration = .init(),
        metadata: [String: String] = [:]
    ) throws -> ProspectiveForecastBundle {
        let protocolValue = try sourceProtocol.validated(against: sourceFreeze)
        let bindings = try sourceBindings.map { try $0.validated() }
        guard !bindings.isEmpty,
              Set(bindings.map(\.targetID)).count == bindings.count,
              Set(bindings.map(\.targetID)) == Set(protocolValue.targets.map(\.id)) else {
            throw ProspectiveSuiteForecastAdapterError.incompleteBindings
        }
        let bindingByTarget = Dictionary(
            uniqueKeysWithValues: bindings.map { ($0.targetID, $0) }
        )
        let samples = try sourceSamples.map { try $0.validated() }
        guard !samples.isEmpty else {
            throw ProspectiveSuiteForecastAdapterError.noSamples
        }
        var grouped: [String: [ProspectiveSuiteOutputSample]] = [:]
        for sample in samples {
            guard let binding = bindingByTarget[sample.targetID],
                  binding.component == sample.component,
                  binding.outputPath == sample.outputPath,
                  binding.sourceUnit == sample.sourceUnit else {
                throw ProspectiveSuiteForecastAdapterError.bindingMismatch(
                    sample.targetID
                )
            }
            let key = "\(sample.memberID)::\(sample.blindedID)::\(sample.targetID)"
            grouped[key, default: []].append(sample)
        }
        let memberSeries = try grouped.keys.sorted().map { key -> ProspectiveEnsembleMemberSeries in
            guard let values = grouped[key],
                  let first = values.first,
                  let binding = bindingByTarget[first.targetID] else {
                throw ProspectiveSuiteForecastAdapterError.noSamples
            }
            let ordered = values.sorted { $0.timeSeconds < $1.timeSeconds }
            guard Set(ordered.map(\.timeSeconds)).count == ordered.count,
                  ordered.allSatisfy({
                      $0.memberID == first.memberID &&
                          $0.randomSeed == first.randomSeed &&
                          $0.blindedID == first.blindedID &&
                          $0.targetID == first.targetID
                  }) else {
                throw ProspectiveSuiteForecastAdapterError.duplicateOrMixedSeries(key)
            }
            let points = ordered.map {
                ProspectiveWaveformPoint(
                    timeSeconds: $0.timeSeconds,
                    value: $0.value * binding.scale + binding.offset
                )
            }
            return try ProspectiveEnsembleMemberSeries(
                memberID: first.memberID,
                randomSeed: first.randomSeed,
                blindedID: first.blindedID,
                targetID: first.targetID,
                unit: binding.canonicalUnit,
                points: points,
                sourceArtifactSHA256: Array(Set(
                    ordered.map(\.sourceArtifactSHA256)
                )).sorted { $0.hexadecimal < $1.hexadecimal },
                metadata: [
                    "component": binding.component.rawValue,
                    "output-path": binding.outputPath,
                    "source-unit": binding.sourceUnit
                ]
            ).validated()
        }
        return try ProspectiveEnsembleForecastAssembler.assemble(
            protocol: protocolValue,
            freeze: sourceFreeze,
            authority: authority,
            issuedAt: issuedAt,
            memberSeries: memberSeries,
            supportingArtifactSHA256: supportingArtifactSHA256,
            configuration: configuration,
            metadata: metadata.merging([
                "adapter": "numi-suite-output-v1",
                "components": Array(Set(bindings.map { $0.component.rawValue })).sorted().joined(separator: ",")
            ], uniquingKeysWith: { explicit, _ in explicit })
        )
    }
}

public enum ProspectiveSuiteForecastAdapterError: Error, Sendable, CustomStringConvertible {
    case invalidBinding(String)
    case invalidSample
    case incompleteBindings
    case noSamples
    case bindingMismatch(String)
    case duplicateOrMixedSeries(String)

    public var description: String {
        switch self {
        case .invalidBinding(let id):
            return "Prospective suite output binding \(id) is invalid."
        case .invalidSample:
            return "Prospective suite output sample is invalid."
        case .incompleteBindings:
            return "Prospective suite output bindings must cover every preregistered target exactly once."
        case .noSamples:
            return "Prospective suite forecast adapter received no samples."
        case .bindingMismatch(let id):
            return "Prospective suite sample does not match target binding \(id)."
        case .duplicateOrMixedSeries(let key):
            return "Prospective suite series \(key) contains duplicate times or mixed identities."
        }
    }
}
