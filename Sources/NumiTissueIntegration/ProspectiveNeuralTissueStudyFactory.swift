import Foundation
import NumiTissueIO

public enum ProspectiveNeuralTissueStudyFactory {
    public static func intermittentOxygen(
        freeze sourceFreeze: ProspectiveModelFreezeCertificate,
        configuration sourceConfiguration: ProspectiveStudyFactoryConfiguration,
        secrets sourceSecrets: ProspectiveStudyFactorySecrets
    ) throws -> ProspectiveNeuralTissueStudyPackage {
        let freeze = try sourceFreeze.validated()
        let configuration = try sourceConfiguration.validated()
        let secrets = try sourceSecrets.validated()
        let grid = stride(
            from: 0.0,
            through: 3_600.0,
            by: 60.0
        ).map { $0 }
        let conditions = [
            ProspectiveExperimentalCondition(
                id: "normoxia-control",
                title: "Continuous normoxia control",
                interventionKind: "dissolved-oxygen-waveform",
                waveformQuantity: "dissolved-oxygen-fraction",
                waveformUnit: "fraction",
                waveformInterpolation: .step,
                waveform: [
                    .init(timeSeconds: 0, value: 0.21),
                    .init(timeSeconds: 3_600, value: 0.21)
                ],
                parameters: ["temperature-kelvin": 310.15],
                metadata: ["novel-condition": "false"]
            ),
            ProspectiveExperimentalCondition(
                id: "sustained-hypoxia-reference",
                title: "Sustained hypoxia reference",
                interventionKind: "dissolved-oxygen-waveform",
                waveformQuantity: "dissolved-oxygen-fraction",
                waveformUnit: "fraction",
                waveformInterpolation: .linear,
                waveform: sustainedHypoxiaWaveform(),
                parameters: ["temperature-kelvin": 310.15],
                metadata: ["novel-condition": "false"]
            ),
            ProspectiveExperimentalCondition(
                id: "intermittent-oxygen-novel",
                title: "Novel intermittent oxygen challenge",
                interventionKind: "dissolved-oxygen-waveform",
                waveformQuantity: "dissolved-oxygen-fraction",
                waveformUnit: "fraction",
                waveformInterpolation: .linear,
                waveform: intermittentOxygenWaveform(),
                parameters: ["temperature-kelvin": 310.15],
                metadata: ["novel-condition": "true"]
            )
        ]
        let targets = [
            oxygenTarget(
                id: "oxygen-depth-50",
                depth: 50,
                grid: grid,
                primary: false
            ),
            oxygenTarget(
                id: "oxygen-depth-150",
                depth: 150,
                grid: grid,
                primary: true
            ),
            oxygenTarget(
                id: "oxygen-depth-300",
                depth: 300,
                grid: grid,
                primary: true
            ),
            ProspectivePredictionTarget(
                id: "normalized-fepsp",
                title: "Normalized evoked field-potential amplitude",
                kind: .continuousTimeSeries,
                quantity: "normalized-field-potential-amplitude",
                unit: "fraction-of-preintervention-baseline",
                region: "recording-layer",
                timeGridSeconds: grid,
                alignment: .linear,
                alignmentToleranceSeconds: 5,
                transform: .normalizedToBaseline,
                primary: true,
                weight: 2,
                measurementStandardError: 0.03
            ),
            ProspectivePredictionTarget(
                id: "recovery-time-90",
                title: "Time to 90 percent field-potential recovery",
                kind: .eventTime,
                quantity: "recovery-time",
                unit: "second",
                region: "recording-layer",
                timeGridSeconds: [3_600],
                alignment: .nearest,
                alignmentToleranceSeconds: 120,
                primary: true,
                weight: 1.5,
                measurementStandardError: 30
            ),
            ProspectivePredictionTarget(
                id: "postchallenge-viability",
                title: "Post-challenge viable-cell fraction",
                kind: .probability,
                quantity: "viable-cell-fraction",
                unit: "fraction",
                region: "whole-tissue",
                timeGridSeconds: [3_600],
                alignment: .nearest,
                alignmentToleranceSeconds: 120,
                primary: false,
                weight: 0.5,
                measurementStandardError: 0.025
            )
        ]
        return try makeStudy(
            freeze: freeze,
            configuration: configuration,
            secrets: secrets,
            title: "Prospective intermittent-oxygen neural-microtissue prediction",
            domain: .intermittentOxygen,
            conditions: conditions,
            targets: targets,
            hypotheses: [
                "The frozen multiscale model will predict depth-resolved oxygen transients under a waveform not used in calibration.",
                "The frozen model will predict evoked field-potential suppression and recovery more accurately than preregistered nonmechanistic baselines.",
                "Preregistered predictive intervals will remain calibrated without post-unblinding parameter changes."
            ],
            workUnitsPerRun: 3_600
        )
    }

    public static func receptorChannelBlocker(
        freeze: ProspectiveModelFreezeCertificate,
        configuration: ProspectiveStudyFactoryConfiguration,
        secrets: ProspectiveStudyFactorySecrets,
        blocker: String,
        concentrationMicromolar: Double
    ) throws -> ProspectiveNeuralTissueStudyPackage {
        guard ProspectiveStudyIdentifier.isStable(blocker),
              concentrationMicromolar.isFinite,
              concentrationMicromolar > 0 else {
            throw ProspectiveStudyFactoryError.invalidIntervention
        }
        let grid = stride(
            from: 0.0,
            through: 1_800.0,
            by: 30.0
        ).map { $0 }
        let conditions = [
            ProspectiveExperimentalCondition(
                id: "vehicle-control",
                title: "Vehicle control",
                interventionKind: "bath-application",
                parameters: ["concentration-micromolar": 0]
            ),
            ProspectiveExperimentalCondition(
                id: "blocker-challenge",
                title: "Preregistered receptor or channel blocker",
                interventionKind: "bath-application",
                parameters: [
                    "concentration-micromolar": concentrationMicromolar
                ],
                metadata: ["agent": blocker]
            )
        ]
        let targets = [
            ProspectivePredictionTarget(
                id: "evoked-response-amplitude",
                title: "Evoked response amplitude",
                kind: .continuousTimeSeries,
                quantity: "normalized-field-potential-amplitude",
                unit: "fraction-of-baseline",
                region: "recording-layer",
                timeGridSeconds: grid,
                primary: true,
                weight: 2,
                measurementStandardError: 0.03
            ),
            ProspectivePredictionTarget(
                id: "network-burst-rate",
                title: "Network burst rate",
                kind: .continuousTimeSeries,
                quantity: "burst-rate",
                unit: "hertz",
                region: "whole-array",
                timeGridSeconds: grid,
                primary: true,
                weight: 1,
                measurementStandardError: 0.1
            )
        ]
        return try makeStudy(
            freeze: freeze,
            configuration: configuration,
            secrets: secrets,
            title: "Prospective \(blocker) perturbation prediction",
            domain: .receptorChannelBlocker,
            conditions: conditions,
            targets: targets,
            hypotheses: [
                "The frozen model will predict the time course and magnitude of the blocker response without refitting.",
                "The prediction will outperform persistence and historical-mean baselines with calibrated uncertainty."
            ],
            workUnitsPerRun: 1_800
        )
    }

    public static func injurySpreadingDepolarization(
        freeze: ProspectiveModelFreezeCertificate,
        configuration: ProspectiveStudyFactoryConfiguration,
        secrets: ProspectiveStudyFactorySecrets
    ) throws -> ProspectiveNeuralTissueStudyPackage {
        let grid = stride(
            from: 0.0,
            through: 1_200.0,
            by: 10.0
        ).map { $0 }
        let conditions = [
            ProspectiveExperimentalCondition(
                id: "sham-control",
                title: "Sham mechanical exposure",
                interventionKind: "mechanical-strain-pulse",
                parameters: ["peak-strain": 0]
            ),
            ProspectiveExperimentalCondition(
                id: "subcritical-injury",
                title: "Subcritical injury pulse",
                interventionKind: "mechanical-strain-pulse",
                parameters: [
                    "peak-strain": 0.12,
                    "duration-millisecond": 25
                ]
            )
        ]
        let targets = [
            ProspectivePredictionTarget(
                id: "depolarization-front-radius",
                title: "Spreading-depolarization front radius",
                kind: .continuousTimeSeries,
                quantity: "front-radius",
                unit: "micrometer",
                region: "whole-tissue",
                timeGridSeconds: grid,
                primary: true,
                weight: 2,
                measurementStandardError: 20
            ),
            ProspectivePredictionTarget(
                id: "extracellular-potassium-peak",
                title: "Peak extracellular potassium",
                kind: .continuousTimeSeries,
                quantity: "potassium-concentration",
                unit: "millimolar",
                region: "injury-core",
                timeGridSeconds: grid,
                primary: true,
                weight: 1,
                measurementStandardError: 0.5
            ),
            ProspectivePredictionTarget(
                id: "recovery-time",
                title: "Electrical recovery time",
                kind: .eventTime,
                quantity: "recovery-time",
                unit: "second",
                region: "peri-injury",
                timeGridSeconds: [1_200],
                primary: true,
                weight: 1,
                measurementStandardError: 15
            )
        ]
        return try makeStudy(
            freeze: freeze,
            configuration: configuration,
            secrets: secrets,
            title: "Prospective injury and spreading-depolarization prediction",
            domain: .injurySpreadingDepolarization,
            conditions: conditions,
            targets: targets,
            hypotheses: [
                "The frozen coupled NumiTissue-NumanX model will predict spreading-depolarization initiation and propagation after an unseen strain pulse.",
                "The model will outperform preregistered persistence and reduced reaction-diffusion baselines."
            ],
            workUnitsPerRun: 2_400
        )
    }

    public static func developmentalOrganoidTrajectory(
        freeze: ProspectiveModelFreezeCertificate,
        configuration: ProspectiveStudyFactoryConfiguration,
        secrets: ProspectiveStudyFactorySecrets
    ) throws -> ProspectiveNeuralTissueStudyPackage {
        let days = stride(
            from: 0.0,
            through: 28.0,
            by: 1.0
        ).map { $0 * 86_400 }
        let conditions = [
            ProspectiveExperimentalCondition(
                id: "standard-medium",
                title: "Standard differentiation medium",
                interventionKind: "developmental-medium",
                parameters: ["growth-factor-scale": 1]
            ),
            ProspectiveExperimentalCondition(
                id: "trophic-pulse",
                title: "Novel trophic-factor pulse schedule",
                interventionKind: "developmental-medium",
                waveformQuantity: "growth-factor-scale",
                waveformUnit: "relative",
                waveformInterpolation: .step,
                waveform: [
                    .init(timeSeconds: 0, value: 1),
                    .init(timeSeconds: 7 * 86_400, value: 1.5),
                    .init(timeSeconds: 10 * 86_400, value: 1),
                    .init(timeSeconds: 28 * 86_400, value: 1)
                ]
            )
        ]
        let targets = [
            ProspectivePredictionTarget(
                id: "neuronal-fraction",
                title: "Neuronal lineage fraction",
                kind: .continuousTimeSeries,
                quantity: "cell-fraction",
                unit: "fraction",
                region: "whole-organoid",
                timeGridSeconds: days,
                primary: true,
                weight: 1,
                measurementStandardError: 0.03
            ),
            ProspectivePredictionTarget(
                id: "synapse-density",
                title: "Functional synapse density",
                kind: .continuousTimeSeries,
                quantity: "synapse-density",
                unit: "per-cubic-millimeter",
                region: "whole-organoid",
                timeGridSeconds: days,
                transform: .logarithmic,
                primary: true,
                weight: 1.5,
                measurementStandardError: 50
            ),
            ProspectivePredictionTarget(
                id: "network-burst-onset",
                title: "Onset of coordinated network bursting",
                kind: .eventTime,
                quantity: "developmental-event-time",
                unit: "second",
                region: "whole-organoid",
                timeGridSeconds: [28 * 86_400],
                primary: true,
                weight: 2,
                measurementStandardError: 43_200
            )
        ]
        return try makeStudy(
            freeze: freeze,
            configuration: configuration,
            secrets: secrets,
            title: "Prospective organoid developmental-trajectory prediction",
            domain: .developmentalOrganoidTrajectory,
            conditions: conditions,
            targets: targets,
            hypotheses: [
                "The frozen developmental model will predict lineage, synaptogenesis and network-maturation trajectories under an unseen trophic schedule.",
                "Predictive intervals will remain calibrated across biological replicates without post-unblinding parameter updates."
            ],
            workUnitsPerRun: 28 * 24
        )
    }
}
