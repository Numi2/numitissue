import Foundation
import NumiTissueIO
import NumiTissueRuntime

public enum TissueExperimentDeterminism {
    public static func trialSeed(
        baseSeed: UInt64,
        trialID: UInt64,
        replicate: Int
    ) -> UInt64 {
        var value = baseSeed ^ trialID ^ UInt64(bitPattern: Int64(replicate))
        value &+= 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    public static func trialSeed(
        definition: TissueExperimentDefinition,
        trial: TissueExperimentTrial
    ) -> UInt64 {
        trialSeed(
            baseSeed: definition.baseSeed,
            trialID: trial.id,
            replicate: trial.replicate
        )
    }
}

public struct TissueExperimentCampaignOptions: Sendable, Hashable, Codable {
    public var shardCount: Int
    public var workUnitsPerStep: UInt64
    public var workUnitsPerIntervention: UInt64
    public var workUnitsPerParameter: UInt64
    public var modelArtifactDigest: ScientificSHA256Digest?
    public var requiredArtifactDigests: [ScientificSHA256Digest]
    public var metadata: [String: String]

    public init(
        shardCount: Int,
        workUnitsPerStep: UInt64 = 1,
        workUnitsPerIntervention: UInt64 = 100,
        workUnitsPerParameter: UInt64 = 10,
        modelArtifactDigest: ScientificSHA256Digest? = nil,
        requiredArtifactDigests: [ScientificSHA256Digest] = [],
        metadata: [String: String] = [:]
    ) {
        self.shardCount = shardCount
        self.workUnitsPerStep = workUnitsPerStep
        self.workUnitsPerIntervention = workUnitsPerIntervention
        self.workUnitsPerParameter = workUnitsPerParameter
        self.modelArtifactDigest = modelArtifactDigest
        self.requiredArtifactDigests = requiredArtifactDigests
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard shardCount > 0,
              workUnitsPerStep > 0,
              Set(requiredArtifactDigests).count == requiredArtifactDigests.count,
              metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw TissueExperimentCampaignError.invalidOptions
        }
        return self
    }
}

public struct TissueExperimentTrialSpecification: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var experimentID: UUID
    public var trial: TissueExperimentTrial
    public var randomSeed: UInt64
    public var steps: Int
    public var checkpointEverySteps: Int?
    public var legacyModelDigest: UInt64
    public var modelArtifactDigest: ScientificSHA256Digest
    public var parameterDigest: ScientificSHA256Digest
    public var estimatedWorkUnits: UInt64
    public var specificationDigest: ScientificSHA256Digest

    public init(
        schemaVersion: UInt32 = 1,
        experimentID: UUID,
        trial: TissueExperimentTrial,
        randomSeed: UInt64,
        steps: Int,
        checkpointEverySteps: Int?,
        legacyModelDigest: UInt64,
        modelArtifactDigest: ScientificSHA256Digest,
        parameterDigest: ScientificSHA256Digest,
        estimatedWorkUnits: UInt64,
        specificationDigest: ScientificSHA256Digest
    ) {
        self.schemaVersion = schemaVersion
        self.experimentID = experimentID
        self.trial = trial
        self.randomSeed = randomSeed
        self.steps = steps
        self.checkpointEverySteps = checkpointEverySteps
        self.legacyModelDigest = legacyModelDigest
        self.modelArtifactDigest = modelArtifactDigest
        self.parameterDigest = parameterDigest
        self.estimatedWorkUnits = estimatedWorkUnits
        self.specificationDigest = specificationDigest
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              trial.replicate >= 0,
              steps >= 0,
              estimatedWorkUnits > 0,
              trial.parameters.keys.allSatisfy({ !$0.isEmpty }),
              trial.parameters.values.allSatisfy(\.isFinite),
              trial.metadata.keys.allSatisfy({ !$0.isEmpty }),
              checkpointEverySteps.map({ $0 > 0 }) ?? true else {
            throw TissueExperimentCampaignError.invalidTrial(trial.id)
        }
        try TissueExperimentCampaignCompiler.validateInterventions(
            trial.interventions,
            trialID: trial.id
        )
        let expectedParameter = try TissueExperimentCampaignCompiler.parameterDigest(
            for: trial
        )
        guard expectedParameter == parameterDigest else {
            throw TissueExperimentCampaignError.parameterDigestMismatch(trial.id)
        }
        let expectedSpecification = try TissueExperimentCampaignCompiler.specificationDigest(
            experimentID: experimentID,
            trial: trial,
            randomSeed: randomSeed,
            steps: steps,
            checkpointEverySteps: checkpointEverySteps,
            legacyModelDigest: legacyModelDigest,
            modelArtifactDigest: modelArtifactDigest,
            parameterDigest: parameterDigest,
            estimatedWorkUnits: estimatedWorkUnits
        )
        guard expectedSpecification == specificationDigest else {
            throw TissueExperimentCampaignError.specificationDigestMismatch(trial.id)
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
}

public struct TissueExperimentCampaignBundle: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var experimentID: UUID
    public var experimentName: String
    public var legacyModelDigest: UInt64
    public var stepsPerTrial: Int
    public var baseSeed: UInt64
    public var checkpointEverySteps: Int?
    public var experimentMetadata: [String: String]
    public var manifest: ScientificCampaignManifest
    public var trialSpecifications: [TissueExperimentTrialSpecification]
    public var bundleDigest: ScientificSHA256Digest

    public init(
        schemaVersion: UInt32 = 1,
        experimentID: UUID,
        experimentName: String,
        legacyModelDigest: UInt64,
        stepsPerTrial: Int,
        baseSeed: UInt64,
        checkpointEverySteps: Int?,
        experimentMetadata: [String: String],
        manifest: ScientificCampaignManifest,
        trialSpecifications: [TissueExperimentTrialSpecification],
        bundleDigest: ScientificSHA256Digest
    ) {
        self.schemaVersion = schemaVersion
        self.experimentID = experimentID
        self.experimentName = experimentName
        self.legacyModelDigest = legacyModelDigest
        self.stepsPerTrial = stepsPerTrial
        self.baseSeed = baseSeed
        self.checkpointEverySteps = checkpointEverySteps
        self.experimentMetadata = experimentMetadata
        self.manifest = manifest
        self.trialSpecifications = trialSpecifications
        self.bundleDigest = bundleDigest
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              !experimentName.isEmpty,
              stepsPerTrial >= 0,
              checkpointEverySteps.map({ $0 > 0 }) ?? true,
              experimentMetadata.keys.allSatisfy({ !$0.isEmpty }),
              manifest.id == experimentID,
              manifest.name == experimentName else {
            throw TissueExperimentCampaignError.invalidBundle
        }
        _ = try manifest.validated()

        let specifications = try trialSpecifications.map { try $0.validated() }
        guard !specifications.isEmpty,
              Set(specifications.map { $0.trial.id }).count == specifications.count,
              specifications.allSatisfy({
                  $0.experimentID == experimentID
                      && $0.steps == stepsPerTrial
                      && $0.checkpointEverySteps == checkpointEverySteps
                      && $0.legacyModelDigest == legacyModelDigest
              }) else {
            throw TissueExperimentCampaignError.invalidBundle
        }

        let specificationByID = Dictionary(
            uniqueKeysWithValues: specifications.map { ($0.trial.id, $0) }
        )
        let campaignTrials = manifest.shards.flatMap(\.trials)
        guard campaignTrials.count == specifications.count else {
            throw TissueExperimentCampaignError.invalidBundle
        }
        for campaignTrial in campaignTrials {
            guard let specification = specificationByID[campaignTrial.id],
                  campaignTrial.randomSeed == specification.randomSeed,
                  campaignTrial.estimatedWorkUnits == specification.estimatedWorkUnits,
                  campaignTrial.modelDigest == specification.modelArtifactDigest,
                  campaignTrial.parameterDigest == specification.parameterDigest,
                  campaignTrial.requiredArtifactDigests.contains(
                    specification.specificationDigest
                  ) else {
                throw TissueExperimentCampaignError.manifestTrialMismatch(campaignTrial.id)
            }
        }

        let expected = try TissueExperimentCampaignCompiler.bundleDigest(
            schemaVersion: schemaVersion,
            experimentID: experimentID,
            experimentName: experimentName,
            legacyModelDigest: legacyModelDigest,
            stepsPerTrial: stepsPerTrial,
            baseSeed: baseSeed,
            checkpointEverySteps: checkpointEverySteps,
            experimentMetadata: experimentMetadata,
            manifestDigest: manifest.campaignDigest,
            trialDigests: specifications.map(\.specificationDigest)
        )
        guard expected == bundleDigest else {
            throw TissueExperimentCampaignError.bundleDigestMismatch
        }
        return self
    }

    public func definition() throws -> TissueExperimentDefinition {
        let valid = try validated()
        return try TissueExperimentDefinition(
            id: valid.experimentID,
            name: valid.experimentName,
            modelDigest: valid.legacyModelDigest,
            stepsPerTrial: valid.stepsPerTrial,
            baseSeed: valid.baseSeed,
            trials: valid.trialSpecifications
                .sorted { $0.trial.id < $1.trial.id }
                .map(\.trial),
            checkpointEverySteps: valid.checkpointEverySteps,
            metadata: valid.experimentMetadata
        ).validated()
    }

    public func specification(
        for trialID: UInt64
    ) -> TissueExperimentTrialSpecification? {
        trialSpecifications.first { $0.trial.id == trialID }
    }

    public func writeAtomically(to directory: URL) throws {
        let valid = try validated()
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let trialsDirectory = directory.appendingPathComponent(
            "trials",
            isDirectory: true
        )
        try manager.createDirectory(
            at: trialsDirectory,
            withIntermediateDirectories: true
        )

        try ScientificCanonicalJSON.encode(valid).write(
            to: directory.appendingPathComponent("bundle.json"),
            options: [.atomic]
        )
        try ScientificCanonicalJSON.encode(valid.manifest).write(
            to: directory.appendingPathComponent("campaign.json"),
            options: [.atomic]
        )
        let definition = try valid.definition()
        try ScientificCanonicalJSON.encode(definition).write(
            to: directory.appendingPathComponent("experiment.json"),
            options: [.atomic]
        )
        for specification in valid.trialSpecifications {
            try specification.writeAtomically(
                to: trialsDirectory.appendingPathComponent(
                    "\(specification.trial.id).json"
                )
            )
        }
    }

    public static func read(from directory: URL) throws -> Self {
        let data = try Data(
            contentsOf: directory.appendingPathComponent("bundle.json")
        )
        return try ScientificCanonicalJSON.decode(Self.self, from: data).validated()
    }
}

public enum TissueExperimentCampaignCompiler {
    public static func compile(
        _ sourceDefinition: TissueExperimentDefinition,
        options sourceOptions: TissueExperimentCampaignOptions,
        createdAt: Date = Date()
    ) throws -> TissueExperimentCampaignBundle {
        let definition = try sourceDefinition.validated()
        let options = try sourceOptions.validated()
        let modelDigest = try options.modelArtifactDigest
            ?? legacyModelArtifactDigest(definition.modelDigest)

        var specifications: [TissueExperimentTrialSpecification] = []
        specifications.reserveCapacity(definition.trials.count)
        var campaignTrials: [ScientificCampaignTrial] = []
        campaignTrials.reserveCapacity(definition.trials.count)

        for trial in definition.trials.sorted(by: { $0.id < $1.id }) {
            try validateTrial(trial)
            let randomSeed = TissueExperimentDeterminism.trialSeed(
                definition: definition,
                trial: trial
            )
            let parameterDigest = try parameterDigest(for: trial)
            let estimatedWorkUnits = try estimateWork(
                definition: definition,
                trial: trial,
                options: options
            )
            let specificationDigest = try specificationDigest(
                experimentID: definition.id,
                trial: trial,
                randomSeed: randomSeed,
                steps: definition.stepsPerTrial,
                checkpointEverySteps: definition.checkpointEverySteps,
                legacyModelDigest: definition.modelDigest,
                modelArtifactDigest: modelDigest,
                parameterDigest: parameterDigest,
                estimatedWorkUnits: estimatedWorkUnits
            )
            let specification = TissueExperimentTrialSpecification(
                experimentID: definition.id,
                trial: trial,
                randomSeed: randomSeed,
                steps: definition.stepsPerTrial,
                checkpointEverySteps: definition.checkpointEverySteps,
                legacyModelDigest: definition.modelDigest,
                modelArtifactDigest: modelDigest,
                parameterDigest: parameterDigest,
                estimatedWorkUnits: estimatedWorkUnits,
                specificationDigest: specificationDigest
            )
            _ = try specification.validated()
            specifications.append(specification)

            let required = uniqueDigests(
                options.requiredArtifactDigests + [specificationDigest]
            )
            var metadata = trial.metadata
            metadata["numitissue.experiment_id"] = definition.id.uuidString
            metadata["numitissue.replicate"] = String(trial.replicate)
            metadata["numitissue.steps"] = String(definition.stepsPerTrial)
            metadata["numitissue.specification_digest"] = specificationDigest.hexadecimal
            campaignTrials.append(
                ScientificCampaignTrial(
                    id: trial.id,
                    randomSeed: randomSeed,
                    estimatedWorkUnits: estimatedWorkUnits,
                    modelDigest: modelDigest,
                    parameterDigest: parameterDigest,
                    requiredArtifactDigests: required,
                    metadata: metadata
                )
            )
        }

        var campaignMetadata = definition.metadata
        for (key, value) in options.metadata {
            campaignMetadata[key] = value
        }
        campaignMetadata["numitissue.schema"] = "experiment-campaign-v1"
        campaignMetadata["numitissue.legacy_model_digest"] = String(
            definition.modelDigest
        )
        campaignMetadata["numitissue.steps_per_trial"] = String(
            definition.stepsPerTrial
        )
        campaignMetadata["numitissue.base_seed"] = String(definition.baseSeed)

        let manifest = try ScientificCampaignSharder.makeManifest(
            name: definition.name,
            trials: campaignTrials,
            shardCount: options.shardCount,
            campaignID: definition.id,
            createdAt: createdAt,
            metadata: campaignMetadata
        )
        let digest = try bundleDigest(
            schemaVersion: 1,
            experimentID: definition.id,
            experimentName: definition.name,
            legacyModelDigest: definition.modelDigest,
            stepsPerTrial: definition.stepsPerTrial,
            baseSeed: definition.baseSeed,
            checkpointEverySteps: definition.checkpointEverySteps,
            experimentMetadata: definition.metadata,
            manifestDigest: manifest.campaignDigest,
            trialDigests: specifications.map(\.specificationDigest)
        )
        return try TissueExperimentCampaignBundle(
            experimentID: definition.id,
            experimentName: definition.name,
            legacyModelDigest: definition.modelDigest,
            stepsPerTrial: definition.stepsPerTrial,
            baseSeed: definition.baseSeed,
            checkpointEverySteps: definition.checkpointEverySteps,
            experimentMetadata: definition.metadata,
            manifest: manifest,
            trialSpecifications: specifications,
            bundleDigest: digest
        ).validated()
    }

    public static func parameterDigest(
        for trial: TissueExperimentTrial
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var schemaVersion: UInt32
            var parameters: [String: Double]
            var interventions: TissueInterventionPlan
            var metadata: [String: String]
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(
                    schemaVersion: 1,
                    parameters: trial.parameters,
                    interventions: trial.interventions,
                    metadata: trial.metadata
                )
            )
        )
    }

    public static func specificationDigest(
        experimentID: UUID,
        trial: TissueExperimentTrial,
        randomSeed: UInt64,
        steps: Int,
        checkpointEverySteps: Int?,
        legacyModelDigest: UInt64,
        modelArtifactDigest: ScientificSHA256Digest,
        parameterDigest: ScientificSHA256Digest,
        estimatedWorkUnits: UInt64
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var schemaVersion: UInt32
            var experimentID: UUID
            var trial: TissueExperimentTrial
            var randomSeed: UInt64
            var steps: Int
            var checkpointEverySteps: Int?
            var legacyModelDigest: UInt64
            var modelArtifactDigest: ScientificSHA256Digest
            var parameterDigest: ScientificSHA256Digest
            var estimatedWorkUnits: UInt64
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(
                    schemaVersion: 1,
                    experimentID: experimentID,
                    trial: trial,
                    randomSeed: randomSeed,
                    steps: steps,
                    checkpointEverySteps: checkpointEverySteps,
                    legacyModelDigest: legacyModelDigest,
                    modelArtifactDigest: modelArtifactDigest,
                    parameterDigest: parameterDigest,
                    estimatedWorkUnits: estimatedWorkUnits
                )
            )
        )
    }

    public static func bundleDigest(
        schemaVersion: UInt32,
        experimentID: UUID,
        experimentName: String,
        legacyModelDigest: UInt64,
        stepsPerTrial: Int,
        baseSeed: UInt64,
        checkpointEverySteps: Int?,
        experimentMetadata: [String: String],
        manifestDigest: ScientificSHA256Digest,
        trialDigests: [ScientificSHA256Digest]
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var schemaVersion: UInt32
            var experimentID: UUID
            var experimentName: String
            var legacyModelDigest: UInt64
            var stepsPerTrial: Int
            var baseSeed: UInt64
            var checkpointEverySteps: Int?
            var experimentMetadata: [String: String]
            var manifestDigest: ScientificSHA256Digest
            var trialDigests: [ScientificSHA256Digest]
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(
                    schemaVersion: schemaVersion,
                    experimentID: experimentID,
                    experimentName: experimentName,
                    legacyModelDigest: legacyModelDigest,
                    stepsPerTrial: stepsPerTrial,
                    baseSeed: baseSeed,
                    checkpointEverySteps: checkpointEverySteps,
                    experimentMetadata: experimentMetadata,
                    manifestDigest: manifestDigest,
                    trialDigests: trialDigests.sorted {
                        $0.hexadecimal < $1.hexadecimal
                    }
                )
            )
        )
    }

    public static func legacyModelArtifactDigest(
        _ legacyDigest: UInt64
    ) throws -> ScientificSHA256Digest {
        struct Payload: Encodable {
            var schema: String
            var value: UInt64
        }
        return ScientificSHA256Digest(
            data: try ScientificCanonicalJSON.encode(
                Payload(
                    schema: "numitissue-legacy-model-digest-v1",
                    value: legacyDigest
                )
            )
        )
    }

    public static func validateInterventions(
        _ plan: TissueInterventionPlan,
        trialID: UInt64
    ) throws {
        guard Set(plan.interventions.map(\.id)).count == plan.interventions.count else {
            throw TissueExperimentCampaignError.invalidInterventionPlan(trialID)
        }
        for intervention in plan.interventions {
            guard !intervention.name.isEmpty,
                  intervention.endTick.map({ $0 > intervention.startTick }) ?? true,
                  intervention.mutations.allSatisfy({
                      !$0.path.isEmpty && $0.value.isFinite && !$0.source.isEmpty
                  }),
                  intervention.metadata.keys.allSatisfy({ !$0.isEmpty }) else {
                throw TissueExperimentCampaignError.invalidInterventionPlan(trialID)
            }
        }
    }

    private static func validateTrial(
        _ trial: TissueExperimentTrial
    ) throws {
        guard trial.replicate >= 0,
              trial.parameters.keys.allSatisfy({ !$0.isEmpty }),
              trial.parameters.values.allSatisfy(\.isFinite),
              trial.metadata.keys.allSatisfy({ !$0.isEmpty }) else {
            throw TissueExperimentCampaignError.invalidTrial(trial.id)
        }
        try validateInterventions(trial.interventions, trialID: trial.id)
    }

    private static func estimateWork(
        definition: TissueExperimentDefinition,
        trial: TissueExperimentTrial,
        options: TissueExperimentCampaignOptions
    ) throws -> UInt64 {
        let steps = UInt64(definition.stepsPerTrial)
        let interventions = UInt64(trial.interventions.interventions.count)
        let parameters = UInt64(trial.parameters.count)
        let stepWork = try checkedMultiply(
            steps,
            options.workUnitsPerStep
        )
        let interventionWork = try checkedMultiply(
            interventions,
            options.workUnitsPerIntervention
        )
        let parameterWork = try checkedMultiply(
            parameters,
            options.workUnitsPerParameter
        )
        return max(
            try checkedAdd(
                try checkedAdd(stepWork, interventionWork),
                parameterWork
            ),
            1
        )
    }

    private static func checkedMultiply(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw TissueExperimentCampaignError.workOverflow
        }
        return result.partialValue
    }

    private static func checkedAdd(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) throws -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw TissueExperimentCampaignError.workOverflow
        }
        return result.partialValue
    }

    private static func uniqueDigests(
        _ values: [ScientificSHA256Digest]
    ) -> [ScientificSHA256Digest] {
        var byHex: [String: ScientificSHA256Digest] = [:]
        for value in values {
            byHex[value.hexadecimal] = value
        }
        return byHex.keys.sorted().compactMap { byHex[$0] }
    }
}

public enum TissueExperimentCampaignError: Error, Sendable, CustomStringConvertible {
    case invalidOptions
    case invalidTrial(UInt64)
    case invalidInterventionPlan(UInt64)
    case parameterDigestMismatch(UInt64)
    case specificationDigestMismatch(UInt64)
    case manifestTrialMismatch(UInt64)
    case bundleDigestMismatch
    case invalidBundle
    case workOverflow

    public var description: String {
        switch self {
        case .invalidOptions:
            return "Experiment campaign options are invalid"
        case .invalidTrial(let id):
            return "Experiment campaign trial \(id) is invalid"
        case .invalidInterventionPlan(let id):
            return "Experiment campaign trial \(id) has an invalid intervention plan"
        case .parameterDigestMismatch(let id):
            return "Experiment campaign trial \(id) parameter digest does not match"
        case .specificationDigestMismatch(let id):
            return "Experiment campaign trial \(id) specification digest does not match"
        case .manifestTrialMismatch(let id):
            return "Campaign manifest trial \(id) does not match its embedded specification"
        case .bundleDigestMismatch:
            return "Experiment campaign bundle digest does not match"
        case .invalidBundle:
            return "Experiment campaign bundle is invalid"
        case .workOverflow:
            return "Experiment campaign work estimate overflowed UInt64"
        }
    }
}
