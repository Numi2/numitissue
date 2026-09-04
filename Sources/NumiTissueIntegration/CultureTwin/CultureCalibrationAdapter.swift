import Foundation

/// Connects actual simulator-generated recordings to the existing DigitalTwinCalibrator.
/// The provider must create an isolated simulation for each candidate and seed.
/// Fixed feature uncertainties prevent a candidate from lowering loss by inflating its noise.
public struct CultureCalibrationEvaluator: TissueCalibrationEvaluator {
    public typealias RecordingProvider = @Sendable (CalibrationParameterSet, UInt64) async throws -> CultureRecording
    private let provider: RecordingProvider
    private let configuration: CultureFeatureConfiguration
    private let selected: [CalibrationFeature]
    private let measurementModelID: String

    public init(provider: @escaping RecordingProvider, configuration: CultureFeatureConfiguration,
                target: CalibrationFeatureVector, measurementModelID: String) throws {
        self.provider = provider; self.configuration = try configuration.validated()
        self.selected = try target.validated().features.sorted { $0.name < $1.name }
        guard !measurementModelID.isEmpty else { throw CultureTwinError.invalid("measurement-model identity") }
        self.measurementModelID = measurementModelID
    }

    public func evaluate(parameters: CalibrationParameterSet, seed: UInt64) async throws -> CalibrationFeatureVector {
        _ = try parameters.validated()
        let recording = try await provider(parameters, seed)
        guard recording.measurementModelID == measurementModelID else {
            throw CultureTwinError.invalid("calibration measurement model changed")
        }
        let report = try CultureFeatureExtractor.extract(recording, configuration: configuration)
        let byID = Dictionary(uniqueKeysWithValues: report.features.map { ($0.id, $0) })
        return try CalibrationFeatureVector(features: selected.map { target in
            guard let feature = byID[target.name] else {
                throw CultureTwinError.invalid("required calibration feature unavailable: \(target.name)")
            }
            // Existing objective combines target and prediction uncertainty quadratically.
            // Use the same fixed scale for every candidate; do not fit predictive noise here.
            return CalibrationFeature(name: target.name, value: feature.value,
                                      uncertainty: target.uncertainty, weight: target.weight)
        }).validated()
    }
}
