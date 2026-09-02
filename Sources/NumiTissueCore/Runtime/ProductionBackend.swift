import Foundation

@frozen
public struct NTPersistentStimulus: Codable, Hashable, Sendable {
    public var id: UInt64
    public var stimulus: NTStimulus
    public var end: TissueTime

    public init(id: UInt64, stimulus: NTStimulus) {
        self.id = id
        self.stimulus = stimulus
        self.end = TissueTime(tick: stimulus.start.tick &+ stimulus.durationTicks)
    }

    public func isActive(at time: TissueTime) -> Bool {
        time >= stimulus.start && (stimulus.durationTicks == 0 ? time == stimulus.start : time < end)
    }

    public func isExpired(at time: TissueTime) -> Bool {
        stimulus.durationTicks == 0 ? time > stimulus.start : time >= end
    }
}

@frozen
public struct NTProductionAuxiliaryState: Codable, Sendable {
    public var growthCones: [NTGrowthConeState]
    public var molecular: NTMolecularAuxiliaryState
    public var fidelity: NTFidelityAuxiliaryState
    public var interestPoints: [NTInterestPoint]
    public var persistentStimuli: [NTPersistentStimulus]
    public var acceptedTransactions: UInt64
    public var rejectedTransactions: UInt64
    public var cumulativeSpikes: UInt64

    public init(
        growthCones: [NTGrowthConeState] = [],
        molecular: NTMolecularAuxiliaryState = .init(),
        fidelity: NTFidelityAuxiliaryState = .init(),
        interestPoints: [NTInterestPoint] = [],
        persistentStimuli: [NTPersistentStimulus] = [],
        acceptedTransactions: UInt64 = 0,
        rejectedTransactions: UInt64 = 0,
        cumulativeSpikes: UInt64 = 0
    ) {
        self.growthCones = growthCones
        self.molecular = molecular
        self.fidelity = fidelity
        self.interestPoints = interestPoints
        self.persistentStimuli = persistentStimuli
        self.acceptedTransactions = acceptedTransactions
        self.rejectedTransactions = rejectedTransactions
        self.cumulativeSpikes = cumulativeSpikes
    }
}

@frozen
public struct NTProductionCheckpoint: Codable, Sendable {
    public var schemaVersion: UInt32
    public var gpuABIVersion: UInt32
    public var state: NTProductionState
    public var auxiliary: NTProductionAuxiliaryState

    public init(state: NTProductionState, auxiliary: NTProductionAuxiliaryState) {
        schemaVersion = NumiTissueBuild.snapshotSchemaVersion
        gpuABIVersion = NumiTissueBuild.gpuABIVersion
        self.state = state
        self.auxiliary = auxiliary
    }
}

@frozen
public struct NTProductionTelemetry: Codable, Hashable, Sendable {
    public var time: TissueTime
    public var transaction: TransactionID
    public var fastSteps: UInt64
    public var fieldSubsteps: UInt64
    public var molecularEvents: UInt64
    public var generatedSpikes: UInt64
    public var cellDivisions: UInt64
    public var neuriteSegmentsCreated: UInt64
    public var synapsesCreated: UInt64
    public var residentBytes: UInt64
    public var activeCompartments: UInt64
    public var activeSynapses: UInt64
    public var activeMicrodomains: UInt64

    public init(time: TissueTime, transaction: TransactionID) {
        self.time = time
        self.transaction = transaction
        fastSteps = 0
        fieldSubsteps = 0
        molecularEvents = 0
        generatedSpikes = 0
        cellDivisions = 0
        neuriteSegmentsCreated = 0
        synapsesCreated = 0
        residentBytes = 0
        activeCompartments = 0
        activeSynapses = 0
        activeMicrodomains = 0
    }
}

/// Complete deterministic reference implementation of the production schedule. The Metal backend
/// uses the same engine order and state transitions, but replaces data-parallel loops with kernels.
public actor NTProductionBackend: NTTissueBackend {
    private var committed: NTProductionState
    private var auxiliary: NTProductionAuxiliaryState
    private var electrophysiology: NTElectrophysiologyEngine
    private var synapses: NTSynapseEngine
    private var fields: NTExtracellularFieldEngine
    private var glia: NTGliaAndMetabolismEngine
    private var development: NTTissueDevelopmentEngine
    private var molecular: NTMolecularMicrodomainEngine
    private var fidelity: NTAdaptiveFidelityController
    private var latestTelemetry: NTProductionTelemetry?

    public var capabilities: NTBackendCapabilities {
        NTBackendCapabilities(
            name: "NumiTissue production reference",
            supportsGPU: false,
            supportsDeterministicReplay: true,
            supportsMolecularMicrodomains: true,
            supportsDynamicTopology: true,
            maximumRecommendedTiles: 32
        )
    }

    public init(
        configuration: NTWorldConfiguration = .init(),
        snapshot: NTWorldSnapshot? = nil,
        routes: [NTRouteRecord] = [],
        auxiliary: NTProductionAuxiliaryState = .init(),
        electrophysiology: NTElectrophysiologyEngine = .init(),
        synapses: NTSynapseEngine = .init(),
        fields: NTExtracellularFieldEngine = .init(),
        glia: NTGliaAndMetabolismEngine = .init(),
        development: NTTissueDevelopmentEngine = .init(),
        molecular: NTMolecularMicrodomainEngine = .init(),
        fidelity: NTAdaptiveFidelityController = .init()
    ) throws {
        try configuration.validate()
        if let snapshot {
            self.committed = try NTProductionState(snapshot: snapshot, routes: routes)
        } else {
            self.committed = try NTProductionState(configuration: configuration, routes: routes)
        }
        self.auxiliary = auxiliary
        self.electrophysiology = electrophysiology
        self.synapses = synapses
        self.fields = fields
        self.glia = glia
        self.development = development
        self.molecular = molecular
        self.fidelity = fidelity
        self.latestTelemetry = nil
    }

    public func configure(_ configuration: NTWorldConfiguration) async throws {
        try configuration.validate()
        guard committed.tiles.count <= configuration.resourceBudget.maximumTiles else {
            throw NTRuntimeError.invalidConfiguration("The active world exceeds the requested tile budget.")
        }
        committed.configuration = configuration
    }

    public func load(snapshot: NTWorldSnapshot) async throws {
        let diagnostics = snapshot.validate()
        guard !diagnostics.contains(where: { $0.severity >= .error }) else {
            throw NTRuntimeError.invalidModel(diagnostics.map(\.message).joined(separator: "; "))
        }
        committed = try NTProductionState(snapshot: snapshot)
        auxiliary = .init()
        latestTelemetry = nil
    }

    public func load(checkpoint: NTProductionCheckpoint) throws {
        guard checkpoint.schemaVersion == NumiTissueBuild.snapshotSchemaVersion,
              checkpoint.gpuABIVersion == NumiTissueBuild.gpuABIVersion else {
            throw NTRuntimeError.snapshotIncompatible("Production checkpoint schema or GPU ABI is incompatible.")
        }
        let diagnostics = checkpoint.state.validate()
        guard !diagnostics.contains(where: { $0.severity >= .error }) else {
            throw NTRuntimeError.snapshotIncompatible(diagnostics.map(\.message).joined(separator: "; "))
        }
        committed = checkpoint.state
        auxiliary = checkpoint.auxiliary
        latestTelemetry = nil
    }

    public func setRoutes(_ routes: [NTRouteRecord]) throws {
        try committed.routeTable.replace(routes: routes, compartmentCount: committed.compartments.count)
    }

    public func setInterestPoints(_ points: [NTInterestPoint]) {
        auxiliary.interestPoints = points
    }

    public func setMolecularNetworks(_ state: NTMolecularAuxiliaryState) {
        auxiliary.molecular = state
    }

    public func setGrowthCones(_ growthCones: [NTGrowthConeState]) {
        auxiliary.growthCones = growthCones
    }

    public func telemetry() -> NTProductionTelemetry? { latestTelemetry }

    public func snapshot() async throws -> NTWorldSnapshot {
        try committed.makeInterchangeSnapshot()
    }

    public func productionCheckpoint() -> NTProductionCheckpoint {
        NTProductionCheckpoint(state: committed, auxiliary: auxiliary)
    }

    public func reset() async {
        do {
            committed = try NTProductionState(configuration: committed.configuration)
            auxiliary = .init()
            latestTelemetry = nil
        } catch {
            preconditionFailure("Validated runtime failed to reset: \(error)")
        }
    }

    public func step(_ input: NTStepInput) async throws -> NTStepReport {
        let configuration = committed.configuration
        guard input.requestedDurationTicks > 0,
              input.requestedDurationTicks.isMultiple(of: configuration.fastQuantumTicks) else {
            throw NTRuntimeError.invalidConfiguration("Step duration must be a positive multiple of the fast quantum.")
        }
        let start = committed.time
        let end = TissueTime(tick: start.tick &+ input.requestedDurationTicks)
        let transaction = TransactionID(rawValue: committed.nextTransactionRawValue)
        var shadow = committed
        var shadowAuxiliary = auxiliary
        shadow.nextTransactionRawValue &+= 1
        var telemetry = NTProductionTelemetry(time: start, transaction: transaction)
        var outputSpikes: [NTSpike] = []
        var diagnostics: [NTDiagnostic] = []
        var promoted: [TileID] = []
        var demoted: [TileID] = []
        var metabolicEnergyJoules: Double = 0

        do {
            try stage(input: input, transaction: transaction, auxiliary: &shadowAuxiliary, state: &shadow)
            apply(boundaries: input, state: &shadow)
            var current = start
            while current < end {
                let next = TissueTime(tick: min(end.tick, current.tick &+ configuration.fastQuantumTicks))
                let deltaTicks = next.tick - current.tick
                let delivered = try shadow.eventWheel.drain(through: current)
                let drives = activeDrives(at: current, auxiliary: shadowAuxiliary)

                let synapseResult = synapses.prepareAndDeliver(
                    state: &shadow,
                    events: delivered,
                    currentTime: current,
                    deltaTicks: deltaTicks,
                    transaction: transaction
                )
                diagnostics.append(contentsOf: synapseResult.diagnostics)

                let membrane = electrophysiology.step(
                    state: &shadow,
                    currentTime: current,
                    deltaTicks: deltaTicks,
                    transaction: transaction,
                    activeCurrentsNanoamps: drives.currents,
                    optogeneticDrive: drives.optogenetic
                )
                diagnostics.append(contentsOf: membrane.diagnostics)
                outputSpikes.append(contentsOf: membrane.spikes)
                synapses.observePostsynapticSpikes(state: &shadow, spikes: membrane.spikes, currentTime: current)
                try shadow.eventWheel.schedule(contentsOf: membrane.routedEvents)
                telemetry.generatedSpikes &+= UInt64(membrane.spikes.count)
                telemetry.fastSteps &+= 1

                if crossesCadence(from: current, to: next, intervalTicks: configuration.communicationBlockTicks) {
                    depositNeuronalFieldSources(state: &shadow)
                    let fieldResult = fields.step(state: &shadow, deltaTicks: configuration.communicationBlockTicks)
                    diagnostics.append(contentsOf: fieldResult.diagnostics)
                    telemetry.fieldSubsteps &+= UInt64(fieldResult.internalSubsteps)
                    let molecularResult = molecular.step(
                        state: &shadow,
                        auxiliary: &shadowAuxiliary.molecular,
                        deltaTicks: configuration.communicationBlockTicks,
                        transaction: transaction
                    )
                    diagnostics.append(contentsOf: molecularResult.diagnostics)
                    telemetry.molecularEvents &+= molecularResult.exactReactionEvents + molecularResult.tauLeapReactionEvents
                }

                if crossesCadence(from: current, to: next, intervalTicks: 40) {
                    let glialResult = glia.step(state: &shadow, deltaTicks: 40)
                    diagnostics.append(contentsOf: glialResult.diagnostics)
                    metabolicEnergyJoules += glialResult.energyJoules
                }

                if crossesCadence(from: current, to: next, intervalTicks: configuration.transactionTicks) {
                    synapses.applyPlasticity(
                        state: &shadow,
                        modulators: input.modulators,
                        deltaTicks: configuration.transactionTicks,
                        structuralEpoch: false
                    )
                }

                if crossesCadence(from: current, to: next, intervalTicks: 4_000) {
                    let developmentResult = development.step(
                        state: &shadow,
                        growthCones: &shadowAuxiliary.growthCones,
                        deltaTicks: 4_000,
                        transaction: transaction
                    )
                    diagnostics.append(contentsOf: developmentResult.diagnostics)
                    telemetry.cellDivisions &+= UInt64(developmentResult.divisions)
                    telemetry.neuriteSegmentsCreated &+= UInt64(developmentResult.newCompartments)
                    telemetry.synapsesCreated &+= UInt64(developmentResult.newSynapses)

                    updateTileScores(state: &shadow)
                    let fidelityResult = fidelity.evaluateAndApply(
                        state: &shadow,
                        auxiliary: &shadowAuxiliary.fidelity,
                        interestPoints: shadowAuxiliary.interestPoints,
                        deltaTicks: 4_000
                    )
                    diagnostics.append(contentsOf: fidelityResult.diagnostics)
                    promoted.append(contentsOf: fidelityResult.promoted.map(\.tile))
                    demoted.append(contentsOf: fidelityResult.demoted.map(\.tile))
                }

                if crossesCadence(from: current, to: next, intervalTicks: 40_000) {
                    synapses.applyPlasticity(
                        state: &shadow,
                        modulators: input.modulators,
                        deltaTicks: 40_000,
                        structuralEpoch: true
                    )
                    try shadow.compactDeletedTopology()
                }
                current = next
            }

            shadow.time = end
            shadowAuxiliary.persistentStimuli.removeAll { $0.isExpired(at: end) }
            outputSpikes.sort()
            diagnostics.append(contentsOf: shadow.validate())
            if shadow.estimatedResidentBytes > shadow.configuration.resourceBudget.maximumResidentBytes {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .resourceBudgetExceeded,
                    message: "Committed state would exceed the resident-memory budget."
                ))
            }

            let status = rejectionStatus(diagnostics)
            if let status {
                shadowAuxiliary.rejectedTransactions &+= 1
                return makeReport(
                    transaction: transaction,
                    status: status,
                    start: start,
                    end: start,
                    state: shadow,
                    spikes: outputSpikes,
                    diagnostics: diagnostics,
                    promoted: promoted,
                    demoted: demoted,
                    metabolicEnergyJoules: metabolicEnergyJoules,
                    substeps: telemetry.fastSteps
                )
            }

            shadowAuxiliary.acceptedTransactions &+= 1
            shadowAuxiliary.cumulativeSpikes &+= UInt64(outputSpikes.count)
            committed = shadow
            auxiliary = shadowAuxiliary
            telemetry.time = end
            telemetry.residentBytes = shadow.estimatedResidentBytes
            telemetry.activeCompartments = UInt64(shadowAuxiliary.fidelity.activeCompartmentMask.filter { $0 }.count)
            telemetry.activeSynapses = UInt64(shadowAuxiliary.fidelity.activeSynapseMask.filter { $0 }.count)
            telemetry.activeMicrodomains = UInt64(shadowAuxiliary.fidelity.activeMicrodomainMask.filter { $0 }.count)
            latestTelemetry = telemetry
            return makeReport(
                transaction: transaction,
                status: promoted.isEmpty ? .committed : .committedWithPromotion,
                start: start,
                end: end,
                state: shadow,
                spikes: outputSpikes,
                diagnostics: diagnostics,
                promoted: promoted,
                demoted: demoted,
                metabolicEnergyJoules: metabolicEnergyJoules,
                substeps: telemetry.fastSteps
            )
        } catch {
            shadowAuxiliary.rejectedTransactions &+= 1
            let diagnostic = NTDiagnostic(
                severity: .fatal,
                code: error is NTRuntimeError ? .incompleteShadowState : .nonFiniteState,
                message: "Transaction aborted: \(error)"
            )
            diagnostics.append(diagnostic)
            return makeReport(
                transaction: transaction,
                status: errorStatus(error),
                start: start,
                end: start,
                state: shadow,
                spikes: outputSpikes,
                diagnostics: diagnostics,
                promoted: promoted,
                demoted: demoted,
                metabolicEnergyJoules: metabolicEnergyJoules,
                substeps: telemetry.fastSteps
            )
        }
    }

    private func stage(
        input: NTStepInput,
        transaction: TransactionID,
        auxiliary: inout NTProductionAuxiliaryState,
        state: inout NTProductionState
    ) throws {
        var nextID = (auxiliary.persistentStimuli.map(\.id).max() ?? 0) &+ 1
        for (index, stimulus) in input.stimuli.enumerated() {
            guard stimulus.start >= state.time else {
                throw NTRuntimeError.invalidConfiguration("Stimulus \(index) begins before the committed simulation time.")
            }
            if stimulus.kind == .sensorySpike {
                try state.eventWheel.schedule(.init(
                    deliveryTime: stimulus.start,
                    kind: .spike,
                    source: UInt64(index),
                    destination: stimulus.target,
                    payload0: stimulus.amplitude,
                    payload1: stimulus.secondaryAmplitude,
                    sequence: (transaction.rawValue << 32) | UInt64(index)
                ))
            } else {
                auxiliary.persistentStimuli.append(.init(id: nextID, stimulus: stimulus))
                nextID &+= 1
            }
        }
        auxiliary.persistentStimuli.sort {
            if $0.stimulus.start != $1.stimulus.start { return $0.stimulus.start < $1.stimulus.start }
            return $0.id < $1.id
        }
    }

    private func activeDrives(
        at time: TissueTime,
        auxiliary: NTProductionAuxiliaryState
    ) -> (currents: [UInt64: Float], optogenetic: [UInt64: Float], chemical: [UInt64: Float]) {
        var currents: [UInt64: Float] = [:]
        var optogenetic: [UInt64: Float] = [:]
        var chemical: [UInt64: Float] = [:]
        for entry in auxiliary.persistentStimuli where entry.isActive(at: time) {
            switch entry.stimulus.kind {
            case .intracellularCurrent, .extracellularElectrode:
                currents[entry.stimulus.target, default: 0] += entry.stimulus.amplitude
            case .optogenetic:
                optogenetic[entry.stimulus.target, default: 0] += entry.stimulus.amplitude
            case .chemical:
                chemical[entry.stimulus.target, default: 0] += entry.stimulus.amplitude
            default:
                break
            }
        }
        return (currents, optogenetic, chemical)
    }

    private func apply(boundaries input: NTStepInput, state: inout NTProductionState) {
        for sample in input.mechanicalBoundary {
            state.metadata["tile.\(sample.tile.rawValue).temperatureKelvin"] = String(sample.temperatureKelvin)
            state.metadata["tile.\(sample.tile.rawValue).pressurePascals"] = String(sample.pressurePascals)
            guard let tileIndex = state.tileIndex(id: sample.tile) else { continue }
            for cellIndex in state.tiles[tileIndex].membership.cellIndices where state.cells.indices.contains(Int(cellIndex)) {
                let index = Int(cellIndex)
                state.cells[index].record.damage = min(1, state.cells[index].record.damage + max(0, sample.damage))
            }
        }
        for sample in input.metabolicBoundary {
            state.metadata["tile.\(sample.tile.rawValue).oxygenBoundary"] = String(sample.oxygenMillimolar)
            state.metadata["tile.\(sample.tile.rawValue).glucoseBoundary"] = String(sample.glucoseMillimolar)
            state.metadata["tile.\(sample.tile.rawValue).perfusion"] = String(sample.perfusionPerSecond)
            guard let tileIndex = state.tileIndex(id: sample.tile) else { continue }
            for cellIndex in state.tiles[tileIndex].membership.cellIndices where state.cells.indices.contains(Int(cellIndex)) {
                let cell = state.cells[Int(cellIndex)].record
                fields.addSource(
                    state: &state,
                    tile: sample.tile,
                    positionMicrometers: cell.positionMicrometers,
                    species: .oxygen,
                    amountPerSecond: sample.perfusionPerSecond * sample.oxygenMillimolar
                )
                fields.addSource(
                    state: &state,
                    tile: sample.tile,
                    positionMicrometers: cell.positionMicrometers,
                    species: .glucose,
                    amountPerSecond: sample.perfusionPerSecond * sample.glucoseMillimolar
                )
            }
        }
    }

    private func depositNeuronalFieldSources(state: inout NTProductionState) {
        for compartment in state.compartments {
            let potassiumEfflux = max(0, compartment.ionicCurrentNanoamps) * 1.0e-5
            let glutamateRelease = Float(compartment.spikeCountWindow) * 1.0e-4
            fields.addSource(
                state: &state,
                tile: compartment.record.tile,
                positionMicrometers: compartment.record.positionMicrometers,
                species: .potassium,
                amountPerSecond: potassiumEfflux
            )
            if glutamateRelease > 0 {
                fields.addSource(
                    state: &state,
                    tile: compartment.record.tile,
                    positionMicrometers: compartment.record.positionMicrometers,
                    species: .glutamate,
                    amountPerSecond: glutamateRelease
                )
            }
        }
    }

    private func updateTileScores(state: inout NTProductionState) {
        for tileIndex in state.tiles.indices {
            let compartmentIndices = state.tiles[tileIndex].membership.compartmentIndices.map(Int.init).filter(state.compartments.indices.contains)
            let cellIndices = state.tiles[tileIndex].membership.cellIndices.map(Int.init).filter(state.cells.indices.contains)
            let spikes = compartmentIndices.reduce(UInt64.zero) { $0 + UInt64(state.compartments[$1].spikeCountWindow) }
            let calcium = compartmentIndices.isEmpty ? 0 : compartmentIndices.reduce(Float.zero) {
                $0 + state.compartments[$1].record.calciumMicromolar
            } / Float(compartmentIndices.count)
            let injury = cellIndices.map { state.cells[$0].record.damage }.max() ?? 0
            let metabolicStress = cellIndices.isEmpty ? 0 : cellIndices.reduce(Float.zero) {
                $0 + max(state.cells[$1].record.oxygenStress, state.cells[$1].record.glucoseStress)
            } / Float(cellIndices.count)
            state.tiles[tileIndex].membership.activityScore = min(1, Float(spikes) * 0.001 + calcium * 0.1)
            state.tiles[tileIndex].membership.injuryScore = injury
            state.tiles[tileIndex].membership.uncertaintyScore = min(1, metabolicStress + 0.1 * injury)
        }
    }

    private func populationSummaries(state: NTProductionState, durationTicks: UInt64) -> [NTPopulationSample] {
        let durationSeconds = Float(durationTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        return state.tiles.map { tile in
            let indices = tile.membership.compartmentIndices.map(Int.init).filter(state.compartments.indices.contains)
            guard !indices.isEmpty else {
                return NTPopulationSample(
                    population: PopulationID(rawValue: tile.membership.id.rawValue),
                    firingRateHertz: 0,
                    meanVoltageMillivolts: -65,
                    synchrony: 0,
                    calcium: 0,
                    uncertainty: tile.membership.uncertaintyScore
                )
            }
            let spikeCount = indices.reduce(UInt64.zero) { $0 + UInt64(state.compartments[$1].spikeCountWindow) }
            let voltage = indices.reduce(Float.zero) { $0 + state.compartments[$1].record.membraneVoltageMillivolts } / Float(indices.count)
            let calcium = indices.reduce(Float.zero) { $0 + state.compartments[$1].record.calciumMicromolar } / Float(indices.count)
            let active = Float(indices.filter { state.compartments[$0].spikeCountWindow > 0 }.count)
            let synchrony = min(1, active / Float(indices.count))
            return NTPopulationSample(
                population: PopulationID(rawValue: tile.membership.id.rawValue),
                firingRateHertz: Float(spikeCount) / max(durationSeconds * Float(indices.count), 1.0e-9),
                meanVoltageMillivolts: voltage,
                synchrony: synchrony,
                calcium: calcium,
                uncertainty: tile.membership.uncertaintyScore
            )
        }
    }

    private func makeReport(
        transaction: TransactionID,
        status: NTTransactionStatus,
        start: TissueTime,
        end: TissueTime,
        state: NTProductionState,
        spikes: [NTSpike],
        diagnostics: [NTDiagnostic],
        promoted: [TileID],
        demoted: [TileID],
        metabolicEnergyJoules: Double,
        substeps: UInt64
    ) -> NTStepReport {
        let durationTicks = max(1, end.tick >= start.tick ? end.tick - start.tick : 1)
        let durationSeconds = Double(durationTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        let output = NTStepOutput(
            startTime: start,
            endTime: end,
            spikes: spikes,
            populations: populationSummaries(state: state, durationTicks: durationTicks),
            fields: fields.summaries(state: state),
            metabolicDemandWatts: durationSeconds > 0 ? Float(metabolicEnergyJoules / durationSeconds) : 0,
            diagnostics: diagnostics
        )
        return NTStepReport(
            transaction: transaction,
            status: status,
            output: output,
            substeps: UInt32(clamping: Int(substeps)),
            promotedTiles: Array(Set(promoted)).sorted(),
            demotedTiles: Array(Set(demoted)).sorted(),
            residentBytes: state.estimatedResidentBytes
        )
    }

    private func crossesCadence(from: TissueTime, to: TissueTime, intervalTicks: UInt64) -> Bool {
        guard intervalTicks > 0 else { return false }
        return from.tick / intervalTicks != to.tick / intervalTicks
    }

    private func rejectionStatus(_ diagnostics: [NTDiagnostic]) -> NTTransactionStatus? {
        guard diagnostics.contains(where: { $0.severity >= .error }) else { return nil }
        if diagnostics.contains(where: { $0.code == .eventQueueOverflow }) { return .rejectedEventOverflow }
        if diagnostics.contains(where: {
            $0.code == .concentrationBelowZero || $0.code == .negativeMoleculeCount ||
            $0.code == .invalidCellVolume || $0.code == .cellOverlapExceeded
        }) { return .rejectedBiologicalBounds }
        if diagnostics.contains(where: {
            $0.code == .invalidReference || $0.code == .invalidMorphology || $0.code == .unsupportedFeature
        }) { return .invalidModel }
        return .rejectedNumerical
    }

    private func errorStatus(_ error: Error) -> NTTransactionStatus {
        guard let runtime = error as? NTRuntimeError else { return .rejectedNumerical }
        switch runtime {
        case .resourceExhausted: return .capacityLimited
        case .invalidModel: return .invalidModel
        default: return .rejectedNumerical
        }
    }
}
