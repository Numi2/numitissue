import Foundation
import NumiTissueCore
import NumiTissueIO
import NumiTissueRuntime
import NumiTissueIntegration

public struct TissueScreeningArm: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var parameters: [String: Double]
    public var interventions: TissueInterventionPlan
    public var metadata: [String: String]

    public init(
        id: String,
        name: String,
        parameters: [String: Double] = [:],
        interventions: TissueInterventionPlan = TissueInterventionPlan(interventions: []),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.interventions = interventions
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !id.isEmpty,
              !name.isEmpty,
              parameters.keys.allSatisfy({ !$0.isEmpty }),
              parameters.values.allSatisfy(\.isFinite),
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw WorkflowPlanError.invalidScreeningArm(id)
        }
        try TissueExperimentCampaignCompiler.validateInterventions(
            interventions,
            trialID: 0
        )
        return self
    }
}

public struct TissueScreeningStudy: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var modelDigest: UInt64
    public var stepsPerTrial: Int
    public var baseSeed: UInt64
    public var replicatesPerArm: Int
    public var arms: [TissueScreeningArm]
    public var checkpointEverySteps: Int?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        modelDigest: UInt64,
        stepsPerTrial: Int,
        baseSeed: UInt64,
        replicatesPerArm: Int,
        arms: [TissueScreeningArm],
        checkpointEverySteps: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.modelDigest = modelDigest
        self.stepsPerTrial = stepsPerTrial
        self.baseSeed = baseSeed
        self.replicatesPerArm = replicatesPerArm
        self.arms = arms
        self.checkpointEverySteps = checkpointEverySteps
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              stepsPerTrial >= 0,
              replicatesPerArm > 0,
              !arms.isEmpty,
              Set(arms.map(\.id)).count == arms.count,
              checkpointEverySteps.map({ $0 > 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw WorkflowPlanError.invalidScreeningStudy
        }
        for arm in arms { _ = try arm.validated() }
        return self
    }

    public func experimentDefinition() throws -> TissueExperimentDefinition {
        let study = try validated()
        var trials: [TissueExperimentTrial] = []
        trials.reserveCapacity(study.arms.count * study.replicatesPerArm)

        for arm in study.arms.sorted(by: { $0.id < $1.id }) {
            for replicate in 0..<study.replicatesPerArm {
                let trialID = try WorkflowDeterminism.stableUInt64(
                    namespace: study.id,
                    components: ["screen", arm.id, String(replicate)]
                )
                var metadata = arm.metadata
                metadata["numitissue.workflow"] = "screening"
                metadata["numitissue.arm_id"] = arm.id
                metadata["numitissue.arm_name"] = arm.name
                trials.append(
                    TissueExperimentTrial(
                        id: trialID,
                        replicate: replicate,
                        parameters: arm.parameters,
                        interventions: arm.interventions,
                        metadata: metadata
                    )
                )
            }
        }

        var metadata = study.metadata
        metadata["numitissue.workflow"] = "screening"
        metadata["numitissue.arm_count"] = String(study.arms.count)
        metadata["numitissue.replicates_per_arm"] = String(study.replicatesPerArm)
        return try TissueExperimentDefinition(
            id: study.id,
            name: study.name,
            modelDigest: study.modelDigest,
            stepsPerTrial: study.stepsPerTrial,
            baseSeed: study.baseSeed,
            trials: trials,
            checkpointEverySteps: study.checkpointEverySteps,
            metadata: metadata
        ).validated()
    }

    public func compileCampaign(
        options: TissueExperimentCampaignOptions,
        createdAt: Date = Date()
    ) throws -> TissueExperimentCampaignBundle {
        try TissueExperimentCampaignCompiler.compile(
            experimentDefinition(),
            options: options,
            createdAt: createdAt
        )
    }
}

public struct OrganoidFittingStudy: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var modelDigest: UInt64
    public var stepsPerTrial: Int
    public var baseSeed: UInt64
    public var parameters: CalibrationParameterSet
    public var objective: CalibrationObjective
    public var calibrationConfiguration: CalibrationConfiguration
    public var initialDesignCount: Int
    public var replicatesPerCandidate: Int
    public var selector: TissueSelection
    public var checkpointEverySteps: Int?
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        modelDigest: UInt64,
        stepsPerTrial: Int,
        baseSeed: UInt64,
        parameters: CalibrationParameterSet,
        objective: CalibrationObjective,
        calibrationConfiguration: CalibrationConfiguration = CalibrationConfiguration(),
        initialDesignCount: Int = 64,
        replicatesPerCandidate: Int = 3,
        selector: TissueSelection = .all,
        checkpointEverySteps: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.modelDigest = modelDigest
        self.stepsPerTrial = stepsPerTrial
        self.baseSeed = baseSeed
        self.parameters = parameters
        self.objective = objective
        self.calibrationConfiguration = calibrationConfiguration
        self.initialDesignCount = initialDesignCount
        self.replicatesPerCandidate = replicatesPerCandidate
        self.selector = selector
        self.checkpointEverySteps = checkpointEverySteps
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              stepsPerTrial >= 0,
              initialDesignCount > 0,
              replicatesPerCandidate > 0,
              checkpointEverySteps.map({ $0 > 0 }) ?? true,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw WorkflowPlanError.invalidOrganoidStudy
        }
        _ = try parameters.validated()
        _ = try objective.target.validated()
        _ = try calibrationConfiguration.validated()
        _ = try selector.validated()
        return self
    }

    public func initialDesign() throws -> [CalibrationParameterSet] {
        let study = try validated()
        var result: [CalibrationParameterSet] = [study.parameters]
        guard study.initialDesignCount > 1 else { return result }
        let dimensions = study.parameters.parameters.count
        let bases = WorkflowLowDiscrepancy.firstPrimes(count: dimensions)

        for sampleIndex in 1..<study.initialDesignCount {
            var candidate = study.parameters
            for dimension in 0..<dimensions {
                let parameter = candidate.parameters[dimension]
                let normalized = WorkflowLowDiscrepancy.radicalInverse(
                    index: sampleIndex,
                    base: bases[dimension]
                )
                candidate.parameters[dimension].value = try WorkflowLowDiscrepancy.decode(
                    normalized: normalized,
                    parameter: parameter
                )
            }
            result.append(try candidate.validated())
        }
        return result
    }

    public func experimentDefinition() throws -> TissueExperimentDefinition {
        let study = try validated()
        let design = try initialDesign()
        let targetDigest = ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(study.objective)
        )
        var trials: [TissueExperimentTrial] = []
        trials.reserveCapacity(design.count * study.replicatesPerCandidate)

        for (candidateIndex, candidate) in design.enumerated() {
            let values = Dictionary(
                uniqueKeysWithValues: candidate.parameters.map { ($0.path, $0.value) }
            )
            let mutations = candidate.parameters.map {
                RuntimeParameterMutation(
                    path: $0.path,
                    selector: study.selector,
                    operation: .set,
                    value: Float($0.value),
                    source: "organoid-fit.candidate.\(candidateIndex)"
                )
            }
            let interventionID = try WorkflowDeterminism.stableUUID(
                namespace: study.id,
                components: ["organoid", "candidate", String(candidateIndex)]
            )
            let intervention = ScheduledTissueIntervention(
                id: interventionID,
                name: "organoid-candidate-\(candidateIndex)",
                startTick: 0,
                mutations: mutations,
                metadata: [
                    "candidate_index": String(candidateIndex),
                    "target_digest": targetDigest.hexadecimal
                ]
            )

            for replicate in 0..<study.replicatesPerCandidate {
                let trialID = try WorkflowDeterminism.stableUInt64(
                    namespace: study.id,
                    components: [
                        "organoid",
                        String(candidateIndex),
                        String(replicate)
                    ]
                )
                trials.append(
                    TissueExperimentTrial(
                        id: trialID,
                        replicate: replicate,
                        parameters: values,
                        interventions: TissueInterventionPlan(
                            interventions: [intervention]
                        ),
                        metadata: [
                            "numitissue.workflow": "organoid-fitting",
                            "numitissue.candidate_index": String(candidateIndex),
                            "numitissue.target_digest": targetDigest.hexadecimal
                        ]
                    )
                )
            }
        }

        var metadata = study.metadata
        metadata["numitissue.workflow"] = "organoid-fitting"
        metadata["numitissue.target_digest"] = targetDigest.hexadecimal
        metadata["numitissue.initial_design_count"] = String(study.initialDesignCount)
        metadata["numitissue.replicates_per_candidate"] = String(
            study.replicatesPerCandidate
        )
        metadata["numitissue.calibration_configuration_digest"] = ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(study.calibrationConfiguration)
        ).hexadecimal
        return try TissueExperimentDefinition(
            id: study.id,
            name: study.name,
            modelDigest: study.modelDigest,
            stepsPerTrial: study.stepsPerTrial,
            baseSeed: study.baseSeed,
            trials: trials,
            checkpointEverySteps: study.checkpointEverySteps,
            metadata: metadata
        ).validated()
    }

    public func compileCampaign(
        options: TissueExperimentCampaignOptions,
        createdAt: Date = Date()
    ) throws -> TissueExperimentCampaignBundle {
        try TissueExperimentCampaignCompiler.compile(
            experimentDefinition(),
            options: options,
            createdAt: createdAt
        )
    }
}

public enum WetwareProtocolBindingTarget: Sendable, Hashable, Codable {
    case trialDurationMilliseconds
    case intertrialIntervalMilliseconds
    case trialCount
    case trainFrequencyHertz(index: Int)
    case trainDurationMilliseconds(index: Int)
    case trainOnsetMilliseconds(index: Int)
    case trainJitterMicroseconds(index: Int)
    case cathodicAmplitudeMicroamps(index: Int)
    case anodicAmplitudeMicroamps(index: Int)
    case cathodicPhaseMicroseconds(index: Int)
    case anodicPhaseMicroseconds(index: Int)
    case interphaseGapMicroseconds(index: Int)
}

public struct WetwareProtocolBinding: Sendable, Hashable, Codable {
    public var parameter: String
    public var target: WetwareProtocolBindingTarget

    public init(parameter: String, target: WetwareProtocolBindingTarget) {
        self.parameter = parameter
        self.target = target
    }

    public func validated(
        parameterNames: Set<String>,
        trainCount: Int
    ) throws -> Self {
        guard !parameter.isEmpty, parameterNames.contains(parameter) else {
            throw WorkflowPlanError.invalidWetwareBinding(parameter)
        }
        switch target {
        case .trainFrequencyHertz(let index),
             .trainDurationMilliseconds(let index),
             .trainOnsetMilliseconds(let index),
             .trainJitterMicroseconds(let index),
             .cathodicAmplitudeMicroamps(let index),
             .anodicAmplitudeMicroamps(let index),
             .cathodicPhaseMicroseconds(let index),
             .anodicPhaseMicroseconds(let index),
             .interphaseGapMicroseconds(let index):
            guard (0..<trainCount).contains(index) else {
                throw WorkflowPlanError.invalidWetwareBinding(parameter)
            }
        case .trialDurationMilliseconds,
             .intertrialIntervalMilliseconds,
             .trialCount:
            break
        }
        return self
    }
}

public struct WetwareOptimizationStudy: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var baselineProtocol: WetwareExperimentProtocol
    public var safetyEnvelope: WetwareStimulationSafetyEnvelope
    public var parameterSpace: WetwareProtocolParameterSpace
    public var bindings: [WetwareProtocolBinding]
    public var objectives: [WetwareObjective]
    public var constraints: [WetwareMetricConstraint]
    public var configuration: WetwareProtocolOptimizationConfiguration
    public var initialCandidateCount: Int
    public var maximumSamplingAttemptsPerCandidate: Int
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        baselineProtocol: WetwareExperimentProtocol,
        safetyEnvelope: WetwareStimulationSafetyEnvelope,
        parameterSpace: WetwareProtocolParameterSpace,
        bindings: [WetwareProtocolBinding],
        objectives: [WetwareObjective],
        constraints: [WetwareMetricConstraint] = [],
        configuration: WetwareProtocolOptimizationConfiguration,
        initialCandidateCount: Int? = nil,
        maximumSamplingAttemptsPerCandidate: Int = 64,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.baselineProtocol = baselineProtocol
        self.safetyEnvelope = safetyEnvelope
        self.parameterSpace = parameterSpace
        self.bindings = bindings
        self.objectives = objectives
        self.constraints = constraints
        self.configuration = configuration
        self.initialCandidateCount = initialCandidateCount ?? configuration.populationSize
        self.maximumSamplingAttemptsPerCandidate = maximumSamplingAttemptsPerCandidate
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty,
              initialCandidateCount > 0,
              maximumSamplingAttemptsPerCandidate > 0,
              !objectives.isEmpty,
              Set(objectives.map(\.metric)).count == objectives.count,
              Set(constraints.map(\.metric)).count == constraints.count,
              Set(bindings.map(\.parameter)).count == bindings.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw WorkflowPlanError.invalidWetwareStudy
        }
        let protocolValue = try baselineProtocol.validated()
        _ = try safetyEnvelope.validated()
        let space = try parameterSpace.validated()
        _ = try configuration.validated()
        for objective in objectives { _ = try objective.validated() }
        for constraint in constraints { _ = try constraint.validated() }
        let names = Set(space.parameters.map(\.name))
        guard Set(bindings.map(\.parameter)) == names else {
            throw WorkflowPlanError.incompleteWetwareBindings
        }
        for binding in bindings {
            _ = try binding.validated(
                parameterNames: names,
                trainCount: protocolValue.stimulationTrains.count
            )
        }
        return self
    }

    public func apply(
        parameters: [String: Double],
        candidateID: UInt64
    ) throws -> WetwareExperimentProtocol {
        let study = try validated()
        guard Set(parameters.keys) == Set(study.parameterSpace.parameters.map(\.name)),
              parameters.values.allSatisfy(\.isFinite) else {
            throw WorkflowPlanError.invalidWetwareParameters
        }
        var result = study.baselineProtocol
        result.id = try WorkflowDeterminism.stableUUID(
            namespace: study.id,
            components: ["wetware", String(candidateID)]
        )
        result.name = "\(study.name)-candidate-\(candidateID)"
        result.randomSeed = study.configuration.seed ^ candidateID
        result.metadata["numitissue.workflow"] = "wetware-optimization"
        result.metadata["numitissue.study_id"] = study.id.uuidString
        result.metadata["numitissue.candidate_id"] = String(candidateID)

        for binding in study.bindings {
            guard let value = parameters[binding.parameter] else {
                throw WorkflowPlanError.invalidWetwareParameters
            }
            try Self.apply(value: value, binding: binding, protocolValue: &result)
        }
        return try result.validated()
    }

    public func initialPlan() throws -> WetwareOptimizationPlan {
        let study = try validated()
        let dimension = study.parameterSpace.parameters.count
        let bases = WorkflowLowDiscrepancy.firstPrimes(count: dimension)
        var candidates: [WetwareOptimizationPlan.Candidate] = []
        var rejected: [WetwareOptimizationPlan.Rejection] = []
        var sampleIndex = 1
        let maximumAttempts = study.initialCandidateCount
            * study.maximumSamplingAttemptsPerCandidate

        while candidates.count < study.initialCandidateCount,
              sampleIndex <= maximumAttempts {
            let genome = WetwareProtocolGenome(
                normalizedValues: (0..<dimension).map {
                    WorkflowLowDiscrepancy.radicalInverse(
                        index: sampleIndex,
                        base: bases[$0]
                    )
                }
            )
            let parameters = try study.parameterSpace.decode(genome)
            let candidateID = try WorkflowDeterminism.stableUInt64(
                namespace: study.id,
                components: ["wetware", String(sampleIndex)]
            )
            do {
                let protocolValue = try study.apply(
                    parameters: parameters,
                    candidateID: candidateID
                )
                let safety = try WetwareProtocolSafetyValidator.validate(
                    protocolValue,
                    envelope: study.safetyEnvelope
                )
                if safety.passed {
                    candidates.append(
                        WetwareOptimizationPlan.Candidate(
                            id: candidateID,
                            sampleIndex: sampleIndex,
                            genome: genome,
                            parameters: parameters,
                            protocolValue: protocolValue,
                            safetyReport: safety
                        )
                    )
                } else {
                    rejected.append(
                        WetwareOptimizationPlan.Rejection(
                            id: candidateID,
                            sampleIndex: sampleIndex,
                            reason: "safety-envelope",
                            safetyReport: safety
                        )
                    )
                }
            } catch {
                rejected.append(
                    WetwareOptimizationPlan.Rejection(
                        id: candidateID,
                        sampleIndex: sampleIndex,
                        reason: String(describing: error),
                        safetyReport: nil
                    )
                )
            }
            sampleIndex += 1
        }

        guard candidates.count == study.initialCandidateCount else {
            throw WorkflowPlanError.insufficientSafeWetwareCandidates(
                generated: candidates.count,
                required: study.initialCandidateCount
            )
        }
        return try WetwareOptimizationPlan.make(
            study: study,
            candidates: candidates,
            rejected: rejected
        )
    }

    private static func apply(
        value: Double,
        binding: WetwareProtocolBinding,
        protocolValue: inout WetwareExperimentProtocol
    ) throws {
        switch binding.target {
        case .trialDurationMilliseconds:
            protocolValue.trialDurationMilliseconds = value
        case .intertrialIntervalMilliseconds:
            protocolValue.intertrialIntervalMilliseconds = value
        case .trialCount:
            protocolValue.trialCount = max(Int(value.rounded()), 1)
        case .trainFrequencyHertz(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.frequencyHertz = value
            }
        case .trainDurationMilliseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.durationMilliseconds = value
            }
        case .trainOnsetMilliseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.onsetMilliseconds = value
            }
        case .trainJitterMicroseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.jitterStandardDeviationMicroseconds = value
            }
        case .cathodicAmplitudeMicroamps(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.pulse.cathodicAmplitudeMicroamps = value
            }
        case .anodicAmplitudeMicroamps(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.pulse.anodicAmplitudeMicroamps = value
            }
        case .cathodicPhaseMicroseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.pulse.cathodicPhaseMicroseconds = value
            }
        case .anodicPhaseMicroseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.pulse.anodicPhaseMicroseconds = value
            }
        case .interphaseGapMicroseconds(let index):
            try updateTrain(index, protocolValue: &protocolValue) {
                $0.pulse.interphaseGapMicroseconds = value
            }
        }
    }

    private static func updateTrain(
        _ index: Int,
        protocolValue: inout WetwareExperimentProtocol,
        operation: (inout WetwareStimulationTrain) -> Void
    ) throws {
        guard protocolValue.stimulationTrains.indices.contains(index) else {
            throw WorkflowPlanError.invalidWetwareTrainIndex(index)
        }
        operation(&protocolValue.stimulationTrains[index])
    }
}

public struct WetwareOptimizationPlan: Sendable, Hashable, Codable {
    public struct Candidate: Sendable, Hashable, Codable {
        public var id: UInt64
        public var sampleIndex: Int
        public var genome: WetwareProtocolGenome
        public var parameters: [String: Double]
        public var protocolValue: WetwareExperimentProtocol
        public var safetyReport: WetwareSafetyReport

        public init(
            id: UInt64,
            sampleIndex: Int,
            genome: WetwareProtocolGenome,
            parameters: [String: Double],
            protocolValue: WetwareExperimentProtocol,
            safetyReport: WetwareSafetyReport
        ) {
            self.id = id
            self.sampleIndex = sampleIndex
            self.genome = genome
            self.parameters = parameters
            self.protocolValue = protocolValue
            self.safetyReport = safetyReport
        }
    }

    public struct Rejection: Sendable, Hashable, Codable {
        public var id: UInt64
        public var sampleIndex: Int
        public var reason: String
        public var safetyReport: WetwareSafetyReport?

        public init(
            id: UInt64,
            sampleIndex: Int,
            reason: String,
            safetyReport: WetwareSafetyReport?
        ) {
            self.id = id
            self.sampleIndex = sampleIndex
            self.reason = reason
            self.safetyReport = safetyReport
        }
    }

    public var schemaVersion: UInt32
    public var study: WetwareOptimizationStudy
    public var candidates: [Candidate]
    public var rejected: [Rejection]
    public var planDigest: ScientificSHA256Digest

    public init(
        schemaVersion: UInt32 = 1,
        study: WetwareOptimizationStudy,
        candidates: [Candidate],
        rejected: [Rejection],
        planDigest: ScientificSHA256Digest
    ) {
        self.schemaVersion = schemaVersion
        self.study = study
        self.candidates = candidates
        self.rejected = rejected
        self.planDigest = planDigest
    }

    public static func make(
        study: WetwareOptimizationStudy,
        candidates: [Candidate],
        rejected: [Rejection]
    ) throws -> Self {
        let candidate = Self(
            study: study,
            candidates: candidates,
            rejected: rejected,
            planDigest: ScientificSHA256Digest(data: Data())
        )
        return try Self(
            study: study,
            candidates: candidates,
            rejected: rejected,
            planDigest: digest(of: candidate)
        ).validated()
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !candidates.isEmpty,
              Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({ $0.safetyReport.passed }),
              candidates.allSatisfy({
                  $0.safetyReport.protocolID == $0.protocolValue.id
              }) else {
            throw WorkflowPlanError.invalidWetwarePlan
        }
        _ = try study.validated()
        for candidate in candidates {
            _ = try candidate.genome.validated(
                dimension: study.parameterSpace.parameters.count
            )
            _ = try candidate.protocolValue.validated()
            let report = try WetwareProtocolSafetyValidator.validate(
                candidate.protocolValue,
                envelope: study.safetyEnvelope
            )
            guard report == candidate.safetyReport else {
                throw WorkflowPlanError.invalidWetwarePlan
            }
        }
        guard try Self.digest(of: self) == planDigest else {
            throw WorkflowPlanError.wetwarePlanDigestMismatch
        }
        return self
    }

    public func writeAtomically(to url: URL) throws {
        let data = try ScientificCanonicalJSON.encode(try validated())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    public static func read(from url: URL) throws -> Self {
        try ScientificCanonicalJSON.decode(
            Self.self,
            from: Data(contentsOf: url)
        ).validated()
    }

    private static func digest(
        of source: Self
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var schemaVersion: UInt32
            var study: WetwareOptimizationStudy
            var candidates: [Candidate]
            var rejected: [Rejection]
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(
                    schemaVersion: source.schemaVersion,
                    study: source.study,
                    candidates: source.candidates,
                    rejected: source.rejected
                )
            )
        )
    }
}

public enum WorkflowPlanError: Error, Sendable, CustomStringConvertible {
    case invalidScreeningArm(String)
    case invalidScreeningStudy
    case invalidOrganoidStudy
    case invalidWetwareStudy
    case invalidWetwareBinding(String)
    case incompleteWetwareBindings
    case invalidWetwareParameters
    case invalidWetwareTrainIndex(Int)
    case insufficientSafeWetwareCandidates(generated: Int, required: Int)
    case invalidWetwarePlan
    case wetwarePlanDigestMismatch
    case digestEncoding

    public var description: String {
        switch self {
        case .invalidScreeningArm(let id):
            return "Screening arm \(id) is invalid"
        case .invalidScreeningStudy:
            return "Screening study is invalid"
        case .invalidOrganoidStudy:
            return "Organoid fitting study is invalid"
        case .invalidWetwareStudy:
            return "Wetware optimization study is invalid"
        case .invalidWetwareBinding(let parameter):
            return "Wetware parameter binding for \(parameter) is invalid"
        case .incompleteWetwareBindings:
            return "Wetware bindings must cover every parameter exactly once"
        case .invalidWetwareParameters:
            return "Wetware candidate parameters do not match the parameter space"
        case .invalidWetwareTrainIndex(let index):
            return "Wetware stimulation train index \(index) is invalid"
        case .insufficientSafeWetwareCandidates(let generated, let required):
            return "Generated \(generated) safe wetware candidates; \(required) are required"
        case .invalidWetwarePlan:
            return "Wetware optimization plan is invalid"
        case .wetwarePlanDigestMismatch:
            return "Wetware optimization plan digest does not match"
        case .digestEncoding:
            return "Workflow digest could not be encoded"
        }
    }
}

private enum WorkflowLowDiscrepancy {
    static func radicalInverse(index: Int, base: Int) -> Double {
        precondition(index >= 0 && base >= 2)
        var index = index
        var factor = 1.0 / Double(base)
        var result = 0.0
        while index > 0 {
            result += factor * Double(index % base)
            index /= base
            factor /= Double(base)
        }
        return min(max(result, 1e-12), 1 - 1e-12)
    }

    static func firstPrimes(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var result: [Int] = []
        var candidate = 2
        while result.count < count {
            var prime = true
            var divisor = 2
            while divisor * divisor <= candidate {
                if candidate % divisor == 0 {
                    prime = false
                    break
                }
                divisor += 1
            }
            if prime { result.append(candidate) }
            candidate += 1
        }
        return result
    }

    static func decode(
        normalized: Double,
        parameter: CalibrationParameter
    ) throws -> Double {
        switch parameter.transform {
        case .linear, .logarithmic:
            return try parameter.transform.decode(
                value: normalized,
                bounds: parameter.bounds
            )
        case .logistic:
            let logit = log(normalized / (1 - normalized))
            return try parameter.transform.decode(
                value: logit,
                bounds: parameter.bounds
            )
        }
    }
}

private enum WorkflowDeterminism {
    private struct Payload: Encodable {
        var namespace: UUID
        var components: [String]
    }

    static func stableUInt64(
        namespace: UUID,
        components: [String]
    ) throws -> UInt64 {
        let digest = try digest(namespace: namespace, components: components)
        let bytes = try bytes(from: digest)
        var value: UInt64 = 0
        for byte in bytes.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value == 0 ? 1 : value
    }

    static func stableUUID(
        namespace: UUID,
        components: [String]
    ) throws -> UUID {
        let digest = try digest(namespace: namespace, components: components)
        var bytes = Array(try bytes(from: digest).prefix(16))
        guard bytes.count == 16 else { throw WorkflowPlanError.digestEncoding }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func digest(
        namespace: UUID,
        components: [String]
    ) throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(namespace: namespace, components: components)
            )
        )
    }

    private static func bytes(
        from digest: ScientificSHA256Digest
    ) throws -> [UInt8] {
        let characters = Array(digest.hexadecimal.utf8)
        guard characters.count == 64 else { throw WorkflowPlanError.digestEncoding }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        var index = 0
        while index < characters.count {
            guard let high = nibble(characters[index]),
                  let low = nibble(characters[index + 1]) else {
                throw WorkflowPlanError.digestEncoding
            }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: return value - 48
        case 97...102: return value - 87
        default: return nil
        }
    }
}
