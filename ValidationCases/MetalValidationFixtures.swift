#if canImport(Metal)
import Foundation
import NumiTissue

struct MetalValidationFixture: Sendable {
    let model: CompiledTissueModel
    let state: TissueRuntimeState
    let metalMolecularProgram: MetalMolecularProgram
    let cpuMolecularProgram: CPUReferenceMolecularProgram

    static func make() throws -> Self {
        var configuration = NumiTissueConfiguration.scientific
        configuration.tile.fieldGridEdge = 4

        let mechanism = MechanismSet.corticalRegularSpiking
        let glial = GlialProgram(
            name: "astrocyte-homeostasis",
            kind: .astrocyteTerritory,
            uptakeRates: Float4(0.02, 0.03, 0.01, 0.01),
            releaseRates: Float4(0.02, 0.03, 0.02, 0.01),
            activationThresholds: Float4(3.0, 0.01, 0.1, 0.1),
            spatialRadiusMicrometers: 30
        )
        let network = MolecularNetwork(
            name: "metabolism",
            solver: .deterministic,
            species: [
                MolecularSpecies(name: "substrate", initialAmount: 10),
                MolecularSpecies(name: "product", initialAmount: 0)
            ],
            reactions: [
                MolecularReaction(
                    name: "conversion",
                    reactants: [ReactionParticipant(species: "substrate")],
                    products: [ReactionParticipant(species: "product")],
                    forwardRate: 0.5
                )
            ]
        )
        let population = PopulationDescriptor(
            id: PopulationID(rawValue: 1),
            name: "validation",
            region: "single-tile"
        )
        let neuronPrototype = CellPrototype(
            name: "regular-spiking-neuron",
            kind: .excitatoryNeuron,
            defaultFidelity: .detailedNeuron,
            mechanismSet: mechanism.name,
            radiusMicrometers: 5,
            membraneCapacitance: 1,
            leakConductance: 0.1,
            leakReversalMillivolts: -65
        )
        let astroPrototype = CellPrototype(
            name: "astrocyte",
            kind: .astrocyte,
            defaultFidelity: .cellAgent,
            radiusMicrometers: 5,
            glialProgram: glial.name
        )
        let synapsePrototype = SynapsePrototype(
            name: "ampa-validation",
            receptor: .ampa,
            riseMilliseconds: 1,
            decayMilliseconds: 5,
            reversalPotentialMillivolts: 0,
            defaultWeight: 2,
            shortTermPlasticity: ShortTermPlasticity(
                utilization: 0.2,
                recoveryMilliseconds: 800,
                facilitationMilliseconds: 0
            ),
            stdp: STDPParameters(
                positiveAmplitude: 1,
                negativeAmplitude: 1,
                positiveTimeConstantMilliseconds: 20,
                negativeTimeConstantMilliseconds: 20,
                eligibilityTimeConstantMilliseconds: 1_000,
                learningRate: 1e-3,
                minimumWeight: 0,
                maximumWeight: 4
            )
        )
        let sourceCell = CellID(rawValue: 101)
        let targetCell = CellID(rawValue: 102)
        let astroCell = CellID(rawValue: 103)
        let modelSource = TissueModel(
            name: "metal-rich-validation",
            metadata: [
                "fixture": "metal-rich-v1",
                "units": "NumiTissue SI-derived runtime units"
            ],
            populations: [population],
            mechanismSets: [mechanism],
            cellPrototypes: [neuronPrototype, astroPrototype],
            cells: [
                CellInstance(
                    id: sourceCell,
                    lineage: LineageID(rawValue: 201),
                    prototype: neuronPrototype.name,
                    population: population.id,
                    positionMicrometers: Float4(20, 20, 20, 0),
                    fidelityOverride: .detailedNeuron
                ),
                CellInstance(
                    id: targetCell,
                    lineage: LineageID(rawValue: 202),
                    prototype: neuronPrototype.name,
                    population: population.id,
                    positionMicrometers: Float4(35, 20, 20, 0),
                    fidelityOverride: .detailedNeuron
                ),
                CellInstance(
                    id: astroCell,
                    lineage: LineageID(rawValue: 203),
                    prototype: astroPrototype.name,
                    population: population.id,
                    positionMicrometers: Float4(28, 20, 20, 0)
                )
            ],
            synapsePrototypes: [synapsePrototype],
            synapses: [
                SynapseConnection(
                    id: SynapseID(rawValue: 301),
                    prototype: synapsePrototype.name,
                    presynapticCell: sourceCell,
                    postsynapticCell: targetCell,
                    delayMilliseconds: 0.025
                )
            ],
            glialPrograms: [glial],
            molecularNetworks: [network],
            molecularDomains: [
                MolecularDomainInstance(
                    id: MicrodomainID(rawValue: 401),
                    network: network.name,
                    cell: sourceCell,
                    fieldVoxel: 0
                )
            ]
        )
        let model = try TissueModelCompiler(configuration: configuration).compile(modelSource)

        let mechanismValues = [
            Float(0.05), Float(0.60), Float(0.32), Float(0),
            Float(0.120), Float(0.036), Float(0.0003), Float(50),
            Float(-77), Float(-54.387), Float(0), Float(0),
            Float(0), Float(0), Float(0), Float(0)
        ]
        func neuron(_ cellID: CellID, _ compartmentID: CompartmentID) -> RuntimeNeuronBlueprint {
            let soma = RuntimeSegmentBlueprint(
                id: SegmentID(rawValue: compartmentID.rawValue),
                type: SegmentKind.soma.rawValue,
                start: Float4(0, 0, 0, 0),
                end: Float4(5, 0, 0, 0),
                radiusMicrometers: 5,
                structuralScore: 0.8
            )
            return RuntimeNeuronBlueprint(
                cellID: cellID,
                segments: [soma],
                compartments: [
                    RuntimeCompartmentBlueprint(
                        id: compartmentID,
                        voltageMillivolts: -65,
                        capacitanceNanofarads: 1,
                        axialConductanceMicrosiemens: 0,
                        mechanismState: mechanismValues,
                        flags: 0
                    )
                ],
                segmentCompartmentLocalIndices: [0]
            )
        }

        let fieldInitialization = RuntimeFieldInitialization(
            concentrations: SIMD12(3.5, 1.2, 0.5, 0.2, 1, 0, 7.4, 1, 0, 0, 0, 1),
            diffusionScales: SIMD12(
                0.001, 0.001, 0.001, 0.001, 0.001, 0.001,
                0.001, 0.001, 0.001, 0.001, 0.001, 0
            )
        )
        var builder = TissueRuntimeStateBuilder(
            fieldInitialization: fieldInitialization,
            fieldResolution: Int(configuration.tile.fieldGridEdge),
            fieldChannels: 12
        )
        let tile = TileCoordinate(x: 0, y: 0, z: 0)
        builder.addTile(tile)
        try builder.addCell(RuntimeCellBlueprint(
            id: sourceCell,
            lineage: LineageID(rawValue: 201),
            tile: tile,
            typeIndex: 0,
            fidelity: .detailedNeuron,
            position: Float4(20, 20, 20, 0),
            semiAxes: Float4(repeating: 5),
            regulatoryState: Array(repeating: 0, count: 32),
            energyReserve: 1
        ))
        try builder.addCell(RuntimeCellBlueprint(
            id: targetCell,
            lineage: LineageID(rawValue: 202),
            tile: tile,
            typeIndex: 0,
            fidelity: .detailedNeuron,
            position: Float4(35, 20, 20, 0),
            semiAxes: Float4(repeating: 5),
            regulatoryState: Array(repeating: 0, count: 32),
            energyReserve: 1
        ))
        try builder.addCell(RuntimeCellBlueprint(
            id: astroCell,
            lineage: LineageID(rawValue: 203),
            tile: tile,
            typeIndex: 1,
            fidelity: .cellAgent,
            position: Float4(28, 20, 20, 0),
            semiAxes: Float4(repeating: 5),
            regulatoryState: Array(repeating: 0, count: 32),
            energyReserve: 1
        ))
        try builder.addNeuron(neuron(sourceCell, CompartmentID(rawValue: 601)))
        try builder.addNeuron(neuron(targetCell, CompartmentID(rawValue: 602)))
        try builder.addSynapse(RuntimeSynapseBlueprint(
            id: SynapseID(rawValue: 301),
            sourceCompartmentID: CompartmentID(rawValue: 601),
            targetCompartmentID: CompartmentID(rawValue: 602),
            delayTicks: 1,
            weight: 2,
            utilization: 0.2,
            resources: 1
        ))
        try builder.addMicrodomain(RuntimeMicrodomainBlueprint(
            id: MicrodomainID(rawValue: 401),
            ownerCellID: sourceCell,
            reactionNetworkIndex: 0,
            solverKind: 2,
            species: [10, 0],
            volumeFemtoliters: 1
        ))
        var state = try builder.build(capacityScale: 1.25)
        state.tiles[0].activityScore = 1
        state.tiles[0].lastActiveTick = 0
        state.tiles[0].uncertaintyScore = 0
        state.tiles[0].damageScore = 0
        state.tiles[0].metabolicStress = 0

        let metalProgram = MetalMolecularProgram(
            networks: [
                MetalMolecularNetworkABI(
                    reactionOffset: 0,
                    reactionCount: 1,
                    speciesCount: 2
                )
            ],
            reactions: [
                MetalMolecularReactionABI(
                    reactants: SIMD4<UInt32>(0, UInt32.max, UInt32.max, UInt32.max),
                    products: SIMD4<UInt32>(1, UInt32.max, UInt32.max, UInt32.max),
                    reactantStoichiometry: SIMD4<Int8>(1, 0, 0, 0),
                    productStoichiometry: SIMD4<Int8>(1, 0, 0, 0),
                    rateConstant: 0.5,
                    order: 1
                )
            ]
        )
        let cpuProgram = CPUReferenceMolecularProgram(networks: [
            CPUReferenceMolecularNetwork(
                speciesCount: 2,
                reactions: [
                    CPUReferenceMolecularReaction(
                        reactants: [CPUReferenceStoichiometryTerm(species: 0)],
                        products: [CPUReferenceStoichiometryTerm(species: 1)],
                        rateConstant: 0.5
                    )
                ]
            )
        ])
        return Self(
            model: model,
            state: state,
            metalMolecularProgram: metalProgram,
            cpuMolecularProgram: cpuProgram
        )
    }
}
#endif
