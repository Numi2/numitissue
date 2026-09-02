import Foundation
import NumiTissueCore
import NumiTissueIO
import NumiTissueModels

public struct TissueEvidenceCompiler: Sendable {
    public let configuration: TissueEvidenceCompilerConfiguration

    public init(
        configuration: TissueEvidenceCompilerConfiguration =
            TissueEvidenceCompilerConfiguration()
    ) {
        self.configuration = configuration
    }

    public func compile(
        _ source: CanonicalTissueBlueprint,
        fusionReport: EvidenceFusionReport? = nil
    ) throws -> TissueEvidenceCompilation {
        let configuration = try configuration.validated()
        let blueprint = try source.validated()
        let unresolved = fusionReport?.unresolvedGroups.count ?? 0
        if configuration.rejectUnresolvedEvidence, unresolved > 0 {
            throw TissueEvidenceCompilerError.unresolvedEvidence(unresolved)
        }

        let resolved = mergeResolvedEvidence(
            blueprint.resolvedEvidence,
            fusionReport?.resolved ?? []
        )
        for item in resolved where
            item.conflictScore > configuration.maximumAllowedConflict {
            throw TissueEvidenceCompilerError.evidenceConflict(
                path: item.entity.semanticKey + "/" + item.property.path,
                score: item.conflictScore
            )
        }

        let identifiers = try StableIdentifierRegistry(blueprint: blueprint)
        let digest = try CanonicalTissueDigest.sha256(blueprint)
        var diagnostics: [TissueEvidenceDiagnostic] = []
        try validateAttributionThresholds(
            blueprint,
            diagnostics: &diagnostics
        )
        try validateCompilationPolicies(
            blueprint,
            diagnostics: &diagnostics
        )

        let morphologyNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.morphologies.map {
                ($0.id, $0.morphology.name)
            }
        )
        let mechanismNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.mechanismSets.map {
                ($0.id, $0.mechanism.name)
            }
        )
        let regulatoryNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.regulatoryPrograms.map {
                ($0.id, $0.program.name)
            }
        )
        let glialNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.glialPrograms.map {
                ($0.id, $0.program.name)
            }
        )
        let networkNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.molecularNetworks.map {
                ($0.id, $0.network.name)
            }
        )
        let cellTypeNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.cellTypes.map { ($0.id, $0.name) }
        )
        let synapseTypeNameByID = Dictionary(
            uniqueKeysWithValues: blueprint.synapseTypes.map { ($0.id, $0.name) }
        )

        let populations = try blueprint.populations.sorted(by: { $0.id < $1.id }).map {
            PopulationDescriptor(
                id: PopulationID(
                    rawValue: try identifiers.populations.requireRawValue(for: $0.id)
                ),
                name: $0.name,
                region: $0.region?.label ?? $0.regionLabel,
                tags: normalizedTags($0)
            )
        }

        let morphologies = blueprint.morphologies
            .sorted { $0.id < $1.id }
            .map(\.morphology)
        let mechanismSets = blueprint.mechanismSets
            .sorted { $0.id < $1.id }
            .map(\.mechanism)
        let regulatoryPrograms = blueprint.regulatoryPrograms
            .sorted { $0.id < $1.id }
            .map(\.program)
        let glialPrograms = blueprint.glialPrograms
            .sorted { $0.id < $1.id }
            .map(\.program)

        let cellPrototypes = try blueprint.cellTypes.sorted(by: { $0.id < $1.id }).map {
            CellPrototype(
                name: $0.name,
                kind: $0.kind,
                defaultFidelity: $0.defaultFidelity,
                morphology: try optionalReference(
                    $0.morphologyID,
                    in: morphologyNameByID,
                    owner: "cell type \($0.id) morphology"
                ),
                mechanismSet: try optionalReference(
                    $0.mechanismSetID,
                    in: mechanismNameByID,
                    owner: "cell type \($0.id) mechanism"
                ),
                radiusMicrometers: try finiteFloat(
                    $0.radiusMicrometers,
                    path: "cellTypes[\($0.id)].radiusMicrometers"
                ),
                membraneCapacitance: try finiteFloat(
                    $0.membraneCapacitance,
                    path: "cellTypes[\($0.id)].membraneCapacitance"
                ),
                leakConductance: try finiteFloat(
                    $0.leakConductance,
                    path: "cellTypes[\($0.id)].leakConductance"
                ),
                leakReversalMillivolts: try finiteFloat(
                    $0.leakReversalMillivolts,
                    path: "cellTypes[\($0.id)].leakReversalMillivolts"
                ),
                regulatoryProgram: try optionalReference(
                    $0.regulatoryProgramID,
                    in: regulatoryNameByID,
                    owner: "cell type \($0.id) regulatory program"
                ),
                glialProgram: try optionalReference(
                    $0.glialProgramID,
                    in: glialNameByID,
                    owner: "cell type \($0.id) glial program"
                )
            )
        }

        let cells = try blueprint.cells.sorted(by: { $0.id < $1.id }).map { cell in
            guard let typeName = cellTypeNameByID[cell.cellTypeID] else {
                throw TissueEvidenceCompilerError.missingReference(
                    "cell type \(cell.cellTypeID)"
                )
            }
            return CellInstance(
                id: CellID(
                    rawValue: try identifiers.cells.requireRawValue(for: cell.id)
                ),
                lineage: LineageID(
                    rawValue: try identifiers.lineages.requireRawValue(
                        for: cell.lineageID
                    )
                ),
                prototype: typeName,
                population: PopulationID(
                    rawValue: try identifiers.populations.requireRawValue(
                        for: cell.populationID
                    )
                ),
                positionMicrometers: try position(cell),
                orientation: try orientation(cell),
                fidelityOverride: cell.fidelityOverride
            )
        }

        let synapsePrototypes = try blueprint.synapseTypes
            .sorted { $0.id < $1.id }
            .map { type in
                SynapsePrototype(
                    name: type.name,
                    receptor: type.receptor,
                    riseMilliseconds: try finiteFloat(
                        type.riseMilliseconds,
                        path: "synapseTypes[\(type.id)].riseMilliseconds"
                    ),
                    decayMilliseconds: try finiteFloat(
                        type.decayMilliseconds,
                        path: "synapseTypes[\(type.id)].decayMilliseconds"
                    ),
                    reversalPotentialMillivolts: try finiteFloat(
                        type.reversalPotentialMillivolts,
                        path: "synapseTypes[\(type.id)].reversalPotentialMillivolts"
                    ),
                    defaultWeight: try finiteFloat(
                        type.defaultWeight,
                        path: "synapseTypes[\(type.id)].defaultWeight"
                    ),
                    shortTermPlasticity: type.shortTermPlasticity,
                    stdp: type.stdp
                )
            }

        let synapses = try blueprint.synapses
            .sorted { $0.id < $1.id }
            .map { synapse in
                guard let prototype = synapseTypeNameByID[synapse.synapseTypeID] else {
                    throw TissueEvidenceCompilerError.missingReference(
                        "synapse type \(synapse.synapseTypeID)"
                    )
                }
                if synapse.presynapticCellID == synapse.postsynapticCellID,
                   !configuration.allowAutapses,
                   synapse.metadata["allow_autapse"] != "true" {
                    throw TissueEvidenceCompilerError.autapseRejected(synapse.id)
                }
                let weight: Float?
                if let value = synapse.weight {
                    weight = try finiteFloat(
                        value,
                        path: "synapses[\(synapse.id)].weight"
                    )
                } else {
                    weight = nil
                }
                return SynapseConnection(
                    id: SynapseID(
                        rawValue: try identifiers.synapses.requireRawValue(
                            for: synapse.id
                        )
                    ),
                    prototype: prototype,
                    presynapticCell: CellID(
                        rawValue: try identifiers.cells.requireRawValue(
                            for: synapse.presynapticCellID
                        )
                    ),
                    postsynapticCell: CellID(
                        rawValue: try identifiers.cells.requireRawValue(
                            for: synapse.postsynapticCellID
                        )
                    ),
                    postsynapticMorphologyNode: synapse.postsynapticMorphologyNode,
                    weight: weight,
                    delayMilliseconds: try finiteFloat(
                        synapse.delayMilliseconds,
                        path: "synapses[\(synapse.id)].delayMilliseconds"
                    )
                )
            }

        let molecularNetworks = blueprint.molecularNetworks
            .sorted { $0.id < $1.id }
            .map(\.network)
        let molecularDomains = try blueprint.molecularDomains
            .sorted { $0.id < $1.id }
            .map { domain in
                guard let network = networkNameByID[domain.networkID] else {
                    throw TissueEvidenceCompilerError.missingReference(
                        "molecular network \(domain.networkID)"
                    )
                }
                return MolecularDomainInstance(
                    id: MicrodomainID(
                        rawValue: try identifiers.molecularDomains.requireRawValue(
                            for: domain.id
                        )
                    ),
                    network: network,
                    cell: CellID(
                        rawValue: try identifiers.cells.requireRawValue(
                            for: domain.cellID
                        )
                    ),
                    morphologyNode: domain.morphologyNode,
                    fieldVoxel: domain.fieldVoxel
                )
            }

        var metadata = blueprint.metadata
        metadata["numitissue.data.schema"] = String(blueprint.schemaVersion)
        metadata["numitissue.data.blueprint.sha256"] = digest.hexadecimal
        metadata["numitissue.data.datasets"] = blueprint.sourceDatasets
            .map(\.stableReference)
            .sorted()
            .joined(separator: "\n")
        metadata["numitissue.data.evidence.records"] = String(blueprint.evidence.count)
        metadata["numitissue.data.evidence.resolved"] = String(resolved.count)
        metadata["numitissue.data.evidence.unresolved"] = String(unresolved)
        metadata["numitissue.data.provenance.nodes"] = String(
            blueprint.provenance.nodes.count
        )
        metadata["numitissue.data.provenance.edges"] = String(
            blueprint.provenance.edges.count
        )
        try validateMetadata(metadata)

        let model = TissueModel(
            schemaVersion: configuration.modelSchemaVersion,
            name: blueprint.name,
            metadata: metadata,
            populations: populations,
            morphologies: morphologies,
            mechanismSets: mechanismSets,
            cellPrototypes: cellPrototypes,
            cells: cells,
            synapsePrototypes: synapsePrototypes,
            synapses: synapses,
            fieldSpecies: blueprint.fieldSpecies
                .sorted { $0.id < $1.id }
                .map(\.descriptor),
            regulatoryPrograms: regulatoryPrograms,
            glialPrograms: glialPrograms,
            molecularNetworks: molecularNetworks,
            molecularDomains: molecularDomains
        )

        let report = TissueEvidenceCompilationReport(
            blueprintDigest: digest.hexadecimal,
            sourceDatasetReferences: blueprint.sourceDatasets
                .map(\.stableReference)
                .sorted(),
            evidenceRecordCount: blueprint.evidence.count,
            resolvedEvidenceCount: resolved.count,
            unresolvedEvidenceCount: unresolved,
            provenanceNodeCount: blueprint.provenance.nodes.count,
            provenanceEdgeCount: blueprint.provenance.edges.count,
            identifierRegistry: identifiers,
            diagnostics: diagnostics.sorted(by: diagnosticOrder)
        )
        return TissueEvidenceCompilation(model: model, report: report)
    }

    public func compileExecutable(
        _ blueprint: CanonicalTissueBlueprint,
        fusionReport: EvidenceFusionReport? = nil,
        runtimeConfiguration: NumiTissueConfiguration = .production
    ) throws -> ExecutableTissueEvidenceCompilation {
        let source = try compile(blueprint, fusionReport: fusionReport)
        let executable = try TissueModelCompiler(
            configuration: runtimeConfiguration
        ).compile(source.model)
        return ExecutableTissueEvidenceCompilation(
            source: source,
            executable: executable
        )
    }
}
