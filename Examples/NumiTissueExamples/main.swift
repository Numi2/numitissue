import Foundation
import NumiTissue

@main
struct NumiTissueExamplesEntryPoint {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "all"
        let outputRoot = URL(
            fileURLWithPath: arguments.dropFirst().first ?? ".build/numitissue-examples",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: true
        )

        let artifacts: [GeneratedExample]
        switch command {
        case "all":
            artifacts = try [
                generateScreening(at: outputRoot),
                generateOrganoidFitting(at: outputRoot),
                generateWetwareOptimization(at: outputRoot)
            ]
        case "screening":
            artifacts = [try generateScreening(at: outputRoot)]
        case "organoid":
            artifacts = [try generateOrganoidFitting(at: outputRoot)]
        case "wetware":
            artifacts = [try generateWetwareOptimization(at: outputRoot)]
        case "help", "--help", "-h":
            printUsage()
            return
        default:
            throw ExampleError.unknownCommand(command)
        }

        try emit(
            GeneratedExamplesSummary(
                generatedAt: Date(),
                outputRoot: outputRoot.path,
                artifacts: artifacts
            )
        )
    }

    private static func generateScreening(
        at outputRoot: URL
    ) throws -> GeneratedExample {
        let directory = outputRoot.appendingPathComponent(
            "screening",
            isDirectory: true
        )
        let interventionDirectory = directory.appendingPathComponent(
            "campaign",
            isDirectory: true
        )
        let study = TissueScreeningStudy(
            id: requiredUUID("82F4C5A8-A8DB-59E4-90BC-2C634E51F476"),
            name: "hypoxia-resilience-screen",
            modelDigest: 0x4E54_5343_5245_454E,
            stepsPerTrial: 8_000,
            baseSeed: 0x5C12_7A91_B314_EE07,
            replicatesPerArm: 4,
            arms: [
                TissueScreeningArm(
                    id: "vehicle-control",
                    name: "Vehicle control",
                    parameters: [
                        "compound_concentration_um": 0
                    ],
                    metadata: [
                        "compound": "vehicle",
                        "dose_unit": "micromolar"
                    ]
                ),
                TissueScreeningArm(
                    id: "metabolic-rescue-low",
                    name: "Metabolic rescue low dose",
                    parameters: [
                        "compound_concentration_um": 0.5,
                        "oxygen_stress_scale": 0.82
                    ],
                    interventions: TissueInterventionPlan(
                        interventions: [
                            ScheduledTissueIntervention(
                                id: requiredUUID("B5A27773-848A-5305-B3F9-D2DD7169C734"),
                                name: "low-dose-metabolic-rescue",
                                startTick: 400,
                                endTick: 7_600,
                                riseTicks: 200,
                                fallTicks: 400,
                                envelope: .cosine,
                                mutations: [
                                    RuntimeParameterMutation(
                                        path: "cell.metabolic_stress",
                                        selector: .all,
                                        operation: .multiply,
                                        value: 0.82,
                                        source: "screen.metabolic-rescue-low"
                                    ),
                                    RuntimeParameterMutation(
                                        path: "cell.energy_reserve",
                                        selector: .all,
                                        operation: .add,
                                        value: 0.04,
                                        source: "screen.metabolic-rescue-low"
                                    )
                                ],
                                metadata: [
                                    "compound": "metabolic-rescue",
                                    "dose": "low"
                                ]
                            )
                        ]
                    ),
                    metadata: [
                        "compound": "metabolic-rescue",
                        "dose": "low"
                    ]
                ),
                TissueScreeningArm(
                    id: "metabolic-rescue-high",
                    name: "Metabolic rescue high dose",
                    parameters: [
                        "compound_concentration_um": 2,
                        "oxygen_stress_scale": 0.65
                    ],
                    interventions: TissueInterventionPlan(
                        interventions: [
                            ScheduledTissueIntervention(
                                id: requiredUUID("C17D23DF-5D18-5C4D-A64D-B945DA79D911"),
                                name: "high-dose-metabolic-rescue",
                                startTick: 400,
                                endTick: 7_600,
                                riseTicks: 200,
                                fallTicks: 400,
                                envelope: .cosine,
                                mutations: [
                                    RuntimeParameterMutation(
                                        path: "cell.metabolic_stress",
                                        selector: .all,
                                        operation: .multiply,
                                        value: 0.65,
                                        source: "screen.metabolic-rescue-high"
                                    ),
                                    RuntimeParameterMutation(
                                        path: "cell.energy_reserve",
                                        selector: .all,
                                        operation: .add,
                                        value: 0.08,
                                        source: "screen.metabolic-rescue-high"
                                    )
                                ],
                                metadata: [
                                    "compound": "metabolic-rescue",
                                    "dose": "high"
                                ]
                            )
                        ]
                    ),
                    metadata: [
                        "compound": "metabolic-rescue",
                        "dose": "high"
                    ]
                )
            ],
            checkpointEverySteps: 2_000,
            metadata: [
                "assay": "hypoxia-resilience",
                "primary_endpoint": "survival_and_network_recovery"
            ]
        )

        let validStudy = try study.validated()
        try writeJSON(
            validStudy,
            to: directory.appendingPathComponent("study.json")
        )
        let bundle = try validStudy.compileCampaign(
            options: TissueExperimentCampaignOptions(
                shardCount: 3,
                workUnitsPerStep: 1,
                workUnitsPerIntervention: 500,
                workUnitsPerParameter: 50,
                metadata: ["example": "screening"]
            ),
            createdAt: fixedCreationDate
        )
        try bundle.writeAtomically(to: interventionDirectory)
        return GeneratedExample(
            name: "screening",
            sourcePath: directory.appendingPathComponent("study.json").path,
            artifactPath: interventionDirectory.path,
            digest: bundle.bundleDigest.hexadecimal,
            itemCount: bundle.trialSpecifications.count
        )
    }

    private static func generateOrganoidFitting(
        at outputRoot: URL
    ) throws -> GeneratedExample {
        let directory = outputRoot.appendingPathComponent(
            "organoid-fitting",
            isDirectory: true
        )
        let campaignDirectory = directory.appendingPathComponent(
            "campaign",
            isDirectory: true
        )
        let study = OrganoidFittingStudy(
            id: requiredUUID("581E36D3-55C2-5A41-A903-2E35071DC9F8"),
            name: "cortical-organoid-electrophysiology-fit",
            modelDigest: 0x4E54_4F52_4741_4E4F,
            stepsPerTrial: 12_000,
            baseSeed: 0x81A3_40E2_7F19_C5D4,
            parameters: CalibrationParameterSet(
                parameters: [
                    CalibrationParameter(
                        path: "compartment.capacitance_nf",
                        value: 0.18,
                        bounds: 0.08...0.45,
                        transform: .logarithmic,
                        priorMean: 0.18,
                        priorStandardDeviation: 0.06,
                        group: "membrane"
                    ),
                    CalibrationParameter(
                        path: "compartment.axial_conductance_us",
                        value: 0.12,
                        bounds: 0.02...0.50,
                        transform: .logarithmic,
                        priorMean: 0.12,
                        priorStandardDeviation: 0.05,
                        group: "morphoelectric"
                    ),
                    CalibrationParameter(
                        path: "synapse.weight",
                        value: 1,
                        bounds: 0.35...2.5,
                        transform: .logarithmic,
                        priorMean: 1,
                        priorStandardDeviation: 0.4,
                        group: "network"
                    ),
                    CalibrationParameter(
                        path: "cell.energy_reserve",
                        value: 0.75,
                        bounds: 0.35...1.0,
                        transform: .logistic,
                        priorMean: 0.75,
                        priorStandardDeviation: 0.12,
                        group: "metabolism"
                    )
                ]
            ),
            objective: CalibrationObjective(
                target: CalibrationFeatureVector(
                    features: [
                        CalibrationFeature(
                            name: "mean_firing_rate_hz",
                            value: 4.8,
                            uncertainty: 0.45,
                            weight: 1
                        ),
                        CalibrationFeature(
                            name: "burst_rate_hz",
                            value: 0.32,
                            uncertainty: 0.06,
                            weight: 1.2
                        ),
                        CalibrationFeature(
                            name: "network_synchrony",
                            value: 0.41,
                            uncertainty: 0.08,
                            weight: 0.8
                        ),
                        CalibrationFeature(
                            name: "stimulus_response_latency_ms",
                            value: 23,
                            uncertainty: 3,
                            weight: 0.7
                        )
                    ]
                ),
                robustScale: 2,
                priorWeight: 0.02
            ),
            calibrationConfiguration: CalibrationConfiguration(
                populationSize: 32,
                eliteFraction: 0.25,
                maximumGenerations: 80,
                initialStepSize: 0.18,
                minimumStepSize: 0.0001,
                targetLoss: 0.001,
                seedsPerCandidate: 3,
                stagnationGenerations: 10
            ),
            initialDesignCount: 16,
            replicatesPerCandidate: 3,
            selector: .all,
            checkpointEverySteps: 3_000,
            metadata: [
                "preparation": "cortical-organoid",
                "recording": "multielectrode-array",
                "fit_stage": "initial-space-filling-design"
            ]
        )

        let validStudy = try study.validated()
        try writeJSON(
            validStudy,
            to: directory.appendingPathComponent("study.json")
        )
        let bundle = try validStudy.compileCampaign(
            options: TissueExperimentCampaignOptions(
                shardCount: 4,
                workUnitsPerStep: 2,
                workUnitsPerIntervention: 750,
                workUnitsPerParameter: 100,
                metadata: ["example": "organoid-fitting"]
            ),
            createdAt: fixedCreationDate
        )
        try bundle.writeAtomically(to: campaignDirectory)
        return GeneratedExample(
            name: "organoid-fitting",
            sourcePath: directory.appendingPathComponent("study.json").path,
            artifactPath: campaignDirectory.path,
            digest: bundle.bundleDigest.hexadecimal,
            itemCount: bundle.trialSpecifications.count
        )
    }

    private static func generateWetwareOptimization(
        at outputRoot: URL
    ) throws -> GeneratedExample {
        let directory = outputRoot.appendingPathComponent(
            "wetware-optimization",
            isDirectory: true
        )
        let protocolValue = WetwareExperimentProtocol(
            id: requiredUUID("7E087AA3-0582-5F83-8B32-4A7E8763012F"),
            name: "closed-loop-organoid-conditioning",
            electrodes: [
                WetwareElectrodeGeometry(
                    id: 0,
                    areaSquareMicrometers: 200_000,
                    positionMicrometers: SIMD3<Double>(0, 0, 0),
                    impedanceOhmsAtOneKilohertz: 35_000,
                    material: "platinum-black"
                )
            ],
            stimulationTrains: [
                WetwareStimulationTrain(
                    electrodeIDs: [0],
                    pulse: .chargeBalanced(
                        amplitudeMicroamps: 15,
                        phaseMicroseconds: 200,
                        interphaseGapMicroseconds: 50
                    ),
                    frequencyHertz: 20,
                    durationMilliseconds: 250,
                    onsetMilliseconds: 100,
                    jitterStandardDeviationMicroseconds: 0,
                    encodingChannel: "conditioned-stimulus"
                )
            ],
            readouts: [
                WetwareReadoutWindow(
                    electrodeIDs: [0],
                    startMilliseconds: 0,
                    durationMilliseconds: 900,
                    feature: .firingRate,
                    outputChannel: "firing_rate_hz"
                ),
                WetwareReadoutWindow(
                    electrodeIDs: [0],
                    startMilliseconds: 0,
                    durationMilliseconds: 900,
                    feature: .synchrony,
                    outputChannel: "network_synchrony"
                )
            ],
            trialDurationMilliseconds: 1_000,
            intertrialIntervalMilliseconds: 1_000,
            trialCount: 20,
            randomSeed: 0x6D10_7E29_4C83_BFA1,
            targetBackend: "mea",
            metadata: [
                "preparation": "organoid",
                "control": "closed-loop"
            ]
        )
        let safetyEnvelope = WetwareStimulationSafetyEnvelope(
            maximumAbsoluteCurrentMicroamps: 100,
            maximumPhaseDurationMicroseconds: 200,
            maximumChargePerPhaseMicrocoulombs: 0.08,
            maximumChargeDensityMicrocoulombsPerSquareCentimeter: 25,
            maximumDutyCycle: 0.10,
            maximumFrequencyHertz: 100,
            maximumSimultaneouslyActiveElectrodes: 1,
            maximumChargeImbalanceFraction: 0.01,
            minimumInterphaseGapMicroseconds: 50,
            minimumIntertrialIntervalMilliseconds: 100
        )
        let study = WetwareOptimizationStudy(
            id: requiredUUID("2E5F5E96-DB47-5544-9CB7-CB89391603F6"),
            name: "safe-closed-loop-wetware-search",
            baselineProtocol: protocolValue,
            safetyEnvelope: safetyEnvelope,
            parameterSpace: WetwareProtocolParameterSpace(
                parameters: [
                    WetwareProtocolParameter(
                        name: "frequency_hz",
                        lowerBound: 5,
                        upperBound: 40,
                        scale: .logarithmic,
                        quantizationStep: 1
                    ),
                    WetwareProtocolParameter(
                        name: "train_duration_ms",
                        lowerBound: 100,
                        upperBound: 500,
                        quantizationStep: 10
                    ),
                    WetwareProtocolParameter(
                        name: "onset_ms",
                        lowerBound: 50,
                        upperBound: 250,
                        quantizationStep: 10
                    ),
                    WetwareProtocolParameter(
                        name: "trial_count",
                        lowerBound: 10,
                        upperBound: 40,
                        quantizationStep: 1
                    )
                ]
            ),
            bindings: [
                WetwareProtocolBinding(
                    parameter: "frequency_hz",
                    target: .trainFrequencyHertz(index: 0)
                ),
                WetwareProtocolBinding(
                    parameter: "train_duration_ms",
                    target: .trainDurationMilliseconds(index: 0)
                ),
                WetwareProtocolBinding(
                    parameter: "onset_ms",
                    target: .trainOnsetMilliseconds(index: 0)
                ),
                WetwareProtocolBinding(
                    parameter: "trial_count",
                    target: .trialCount
                )
            ],
            objectives: [
                WetwareObjective(
                    metric: "conditioned_response_gain",
                    direction: .maximize,
                    epsilon: 0.01
                ),
                WetwareObjective(
                    metric: "energy_per_trial",
                    direction: .minimize,
                    epsilon: 0.001
                )
            ],
            constraints: [
                WetwareMetricConstraint(
                    metric: "tissue_damage_index",
                    maximum: 0.05,
                    normalizationScale: 0.05
                ),
                WetwareMetricConstraint(
                    metric: "baseline_drift",
                    maximum: 0.10,
                    normalizationScale: 0.10
                )
            ],
            configuration: WetwareProtocolOptimizationConfiguration(
                populationSize: 16,
                generations: 30,
                offspringPerGeneration: 16,
                maximumConcurrentEvaluations: 4,
                crossoverProbability: 0.9,
                mutationProbabilityPerParameter: 0.2,
                initialMutationStandardDeviation: 0.12,
                finalMutationStandardDeviation: 0.02,
                tournamentSize: 2,
                seed: 0x13D2_9987_6AA4_F01C
            ),
            initialCandidateCount: 16,
            maximumSamplingAttemptsPerCandidate: 32,
            metadata: [
                "assay": "closed-loop-conditioning",
                "optimization": "constrained-multiobjective"
            ]
        )

        let validStudy = try study.validated()
        try writeJSON(
            validStudy,
            to: directory.appendingPathComponent("study.json")
        )
        try writeJSON(
            try protocolValue.validated(),
            to: directory.appendingPathComponent("baseline-protocol.json")
        )
        try writeJSON(
            try safetyEnvelope.validated(),
            to: directory.appendingPathComponent("safety-envelope.json")
        )
        let plan = try validStudy.initialPlan()
        let planURL = directory.appendingPathComponent("initial-plan.json")
        try plan.writeAtomically(to: planURL)
        return GeneratedExample(
            name: "wetware-optimization",
            sourcePath: directory.appendingPathComponent("study.json").path,
            artifactPath: planURL.path,
            digest: plan.planDigest.hexadecimal,
            itemCount: plan.candidates.count
        )
    }

    private static func writeJSON<T: Encodable>(
        _ value: T,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ScientificCanonicalJSON.encode(value).write(
            to: url,
            options: [.atomic]
        )
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try ScientificCanonicalJSON.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func requiredUUID(_ source: String) -> UUID {
        guard let value = UUID(uuidString: source) else {
            preconditionFailure("Invalid embedded example UUID: \(source)")
        }
        return value
    }

    private static var fixedCreationDate: Date {
        Date(timeIntervalSince1970: 1_788_316_800)
    }

    private static func printUsage() {
        print(
            """
            Usage:
              numitissue-examples all [output-directory]
              numitissue-examples screening [output-directory]
              numitissue-examples organoid [output-directory]
              numitissue-examples wetware [output-directory]

            The executable writes canonical JSON source studies and their compiled campaign or
            safety-filtered optimization artifacts.
            """
        )
    }
}

private struct GeneratedExample: Sendable, Hashable, Codable {
    var name: String
    var sourcePath: String
    var artifactPath: String
    var digest: String
    var itemCount: Int
}

private struct GeneratedExamplesSummary: Sendable, Hashable, Codable {
    var generatedAt: Date
    var outputRoot: String
    var artifacts: [GeneratedExample]
}

private enum ExampleError: Error, CustomStringConvertible {
    case unknownCommand(String)

    var description: String {
        switch self {
        case .unknownCommand(let command):
            return "Unknown example command '\(command)'"
        }
    }
}
