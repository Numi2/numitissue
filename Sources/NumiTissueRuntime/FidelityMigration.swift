import Foundation
import NumiTissueCore

public enum FidelityTemplatePolicy: UInt8, Sendable, Hashable, Codable {
    case canonicalOnly = 0
    case synthesizeReduced = 1
    case boundedFallback = 2
}

public struct FidelityMigrationLimits: Sendable, Hashable, Codable {
    public var capacityGrowthFactor: Float
    public var capacityAlignment: Int
    public var minimumSlack: Int
    public var maximumSegments: Int
    public var maximumCompartments: Int
    public var maximumSynapses: Int
    public var maximumMicrodomains: Int
    public var maximumMolecularSpecies: Int

    public init(
        capacityGrowthFactor: Float = 1.5,
        capacityAlignment: Int = 256,
        minimumSlack: Int = 256,
        maximumSegments: Int = .max,
        maximumCompartments: Int = .max,
        maximumSynapses: Int = .max,
        maximumMicrodomains: Int = .max,
        maximumMolecularSpecies: Int = .max
    ) {
        precondition(capacityGrowthFactor >= 1)
        precondition(capacityAlignment > 0)
        precondition(minimumSlack >= 0)
        self.capacityGrowthFactor = capacityGrowthFactor
        self.capacityAlignment = capacityAlignment
        self.minimumSlack = minimumSlack
        self.maximumSegments = maximumSegments
        self.maximumCompartments = maximumCompartments
        self.maximumSynapses = maximumSynapses
        self.maximumMicrodomains = maximumMicrodomains
        self.maximumMolecularSpecies = maximumMolecularSpecies
    }

    func capacity(
        current: Int,
        required: Int,
        limit: Int,
        pool: FidelityMigrationPool
    ) throws -> Int {
        guard required <= limit else {
            throw FidelityMigrationError.capacityExceeded(pool: pool, required: required, limit: limit)
        }
        guard required > current else { return current }

        let scaled = Int(ceil(Double(max(current, 1)) * Double(capacityGrowthFactor)))
        let withSlack: Int
        if scaled > Int.max - minimumSlack {
            withSlack = Int.max
        } else {
            withSlack = scaled + minimumSlack
        }
        let requested = max(required, withSlack)
        let aligned: Int
        if requested > Int.max - capacityAlignment + 1 {
            aligned = Int.max
        } else {
            aligned = ((requested + capacityAlignment - 1) / capacityAlignment) * capacityAlignment
        }
        return min(max(required, aligned), limit)
    }
}

public struct FidelityMigrationConfiguration: Sendable, Hashable, Codable {
    public var templatePolicy: FidelityTemplatePolicy
    public var limits: FidelityMigrationLimits
    public var preserveDormantSynapses: Bool
    public var restoreDormantSynapses: Bool
    public var preserveModifiedPassiveProperties: Bool
    public var minimumCapacitanceNanofarads: Float
    public var maximumAbsoluteVoltageMillivolts: Float
    public var conservationTolerance: Float

    public init(
        templatePolicy: FidelityTemplatePolicy = .synthesizeReduced,
        limits: FidelityMigrationLimits = FidelityMigrationLimits(),
        preserveDormantSynapses: Bool = true,
        restoreDormantSynapses: Bool = true,
        preserveModifiedPassiveProperties: Bool = true,
        minimumCapacitanceNanofarads: Float = 1e-6,
        maximumAbsoluteVoltageMillivolts: Float = 250,
        conservationTolerance: Float = 1e-4
    ) {
        precondition(minimumCapacitanceNanofarads > 0)
        precondition(maximumAbsoluteVoltageMillivolts > 0)
        precondition(conservationTolerance >= 0)
        self.templatePolicy = templatePolicy
        self.limits = limits
        self.preserveDormantSynapses = preserveDormantSynapses
        self.restoreDormantSynapses = restoreDormantSynapses
        self.preserveModifiedPassiveProperties = preserveModifiedPassiveProperties
        self.minimumCapacitanceNanofarads = minimumCapacitanceNanofarads
        self.maximumAbsoluteVoltageMillivolts = maximumAbsoluteVoltageMillivolts
        self.conservationTolerance = conservationTolerance
    }
}

public struct FidelityTopologyTemplate: Sendable, Hashable, Codable {
    public var cellID: CellID
    public var level: FidelityLevel
    public var neuron: RuntimeNeuronBlueprint?
    public var microdomains: [RuntimeMicrodomainBlueprint]
    public var preferredCompartmentID: CompartmentID?
    public var source: String
    public var digest: UInt64

    public init(
        cellID: CellID,
        level: FidelityLevel,
        neuron: RuntimeNeuronBlueprint? = nil,
        microdomains: [RuntimeMicrodomainBlueprint] = [],
        preferredCompartmentID: CompartmentID? = nil,
        source: String = "canonical",
        digest: UInt64 = 0
    ) {
        self.cellID = cellID
        self.level = level
        self.neuron = neuron
        self.microdomains = microdomains
        self.preferredCompartmentID = preferredCompartmentID
        self.source = source
        self.digest = digest == 0
            ? FidelityMigrationHash.template(
                cellID: cellID,
                level: level,
                neuron: neuron,
                microdomains: microdomains
            )
            : digest
    }

    public func validated() throws -> Self {
        if level.rawValue < FidelityLevel.reducedNeuron.rawValue {
            guard neuron == nil, microdomains.isEmpty else {
                throw FidelityMigrationError.invalidTemplate(
                    cellID: cellID,
                    reason: "non-electrical fidelity contains explicit topology"
                )
            }
            return self
        }

        guard let neuron, neuron.cellID == cellID, !neuron.compartments.isEmpty else {
            throw FidelityMigrationError.invalidTemplate(
                cellID: cellID,
                reason: "electrical fidelity requires compartments"
            )
        }
        guard neuron.segments.count == neuron.segmentCompartmentLocalIndices.count else {
            throw FidelityMigrationError.invalidTemplate(
                cellID: cellID,
                reason: "segment/compartment mapping count mismatch"
            )
        }

        let compartmentIDs = Set(neuron.compartments.map(\.id))
        let segmentIDs = Set(neuron.segments.map(\.id))
        guard compartmentIDs.count == neuron.compartments.count else {
            throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "duplicate compartment identifier")
        }
        guard segmentIDs.count == neuron.segments.count else {
            throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "duplicate segment identifier")
        }

        for index in neuron.compartments.indices {
            let item = neuron.compartments[index]
            guard item.voltageMillivolts.isFinite,
                  item.capacitanceNanofarads.isFinite,
                  item.capacitanceNanofarads > 0,
                  item.axialConductanceMicrosiemens.isFinite,
                  item.mechanismState.allSatisfy(\.isFinite) else {
                throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "invalid compartment state")
            }
            if let parent = item.parentLocalIndex, !(0..<index).contains(parent) {
                throw FidelityMigrationError.invalidTemplate(
                    cellID: cellID,
                    reason: "compartment topology is not parent-before-child"
                )
            }
        }

        for index in neuron.segments.indices {
            let item = neuron.segments[index]
            guard item.radiusMicrometers.isFinite,
                  item.radiusMicrometers > 0,
                  item.myelinFraction.isFinite,
                  (0...1).contains(item.myelinFraction),
                  item.growthRateMicrometersPerSecond.isFinite,
                  item.structuralScore.isFinite,
                  FidelityMigrationNumerics.finite(item.start),
                  FidelityMigrationNumerics.finite(item.end) else {
                throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "invalid segment state")
            }
            if let parent = item.parentLocalIndex, !(0..<index).contains(parent) {
                throw FidelityMigrationError.invalidTemplate(
                    cellID: cellID,
                    reason: "segment topology is not parent-before-child"
                )
            }
            if let local = neuron.segmentCompartmentLocalIndices[index],
               !(0..<neuron.compartments.count).contains(local) {
                throw FidelityMigrationError.invalidTemplate(
                    cellID: cellID,
                    reason: "invalid segment compartment"
                )
            }
        }

        if let preferredCompartmentID, !compartmentIDs.contains(preferredCompartmentID) {
            throw FidelityMigrationError.invalidTemplate(
                cellID: cellID,
                reason: "preferred compartment is absent"
            )
        }

        if level == .molecularDetail && microdomains.isEmpty {
            throw FidelityMigrationError.invalidTemplate(
                cellID: cellID,
                reason: "molecular fidelity requires microdomains"
            )
        }
        let microdomainIDs = Set(microdomains.map(\.id))
        guard microdomainIDs.count == microdomains.count else {
            throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "duplicate microdomain identifier")
        }
        for item in microdomains {
            guard item.ownerCellID == cellID,
                  item.volumeFemtoliters.isFinite,
                  item.volumeFemtoliters > 0,
                  item.temperatureKelvin.isFinite,
                  item.temperatureKelvin > 0,
                  item.species.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                throw FidelityMigrationError.invalidTemplate(cellID: cellID, reason: "invalid molecular microdomain")
            }
            if let owner = item.ownerCompartmentID, !compartmentIDs.contains(owner) {
                throw FidelityMigrationError.invalidTemplate(
                    cellID: cellID,
                    reason: "microdomain owner is absent"
                )
            }
        }
        return self
    }
}

public struct FidelityTemplateKey: Sendable, Hashable, Codable {
    public var cellID: CellID
    public var level: FidelityLevel

    public init(cellID: CellID, level: FidelityLevel) {
        self.cellID = cellID
        self.level = level
    }
}

public struct FidelityTemplateCatalog: Sendable, Codable {
    private var storage: [FidelityTemplateKey: FidelityTopologyTemplate]

    public init() {
        storage = [:]
    }

    public init(_ templates: [FidelityTopologyTemplate]) throws {
        storage = [:]
        for template in templates {
            try register(template)
        }
    }

    public var count: Int { storage.count }

    public func template(cellID: CellID, level: FidelityLevel) -> FidelityTopologyTemplate? {
        storage[FidelityTemplateKey(cellID: cellID, level: level)]
    }

    public func levels(for cellID: CellID) -> [FidelityLevel] {
        storage.keys
            .filter { $0.cellID == cellID }
            .map(\.level)
            .sorted { $0.rawValue < $1.rawValue }
    }

    public mutating func register(_ template: FidelityTopologyTemplate) throws {
        let validated = try template.validated()
        storage[FidelityTemplateKey(cellID: validated.cellID, level: validated.level)] = validated
    }

    public mutating func capture(
        cellIndex: UInt32,
        state: TissueRuntimeState,
        source: String = "runtime"
    ) throws {
        let index = try FidelitySourceIndex(state: state)
        try register(
            FidelityMigrationCapture.template(
                cellIndex: cellIndex,
                state: state,
                index: index,
                source: source
            )
        )
    }
}

public struct FidelityDormantSynapse: Sendable, Hashable, Codable {
    public var state: RuntimeSynapseState
    public var sourceCellID: CellID
    public var sourceCompartmentID: CompartmentID
    public var targetCellID: CellID
    public var targetCompartmentID: CompartmentID
    public var suspendedAtEpoch: UInt64

    public init(
        state: RuntimeSynapseState,
        sourceCellID: CellID,
        sourceCompartmentID: CompartmentID,
        targetCellID: CellID,
        targetCompartmentID: CompartmentID,
        suspendedAtEpoch: UInt64
    ) {
        self.state = state
        self.sourceCellID = sourceCellID
        self.sourceCompartmentID = sourceCompartmentID
        self.targetCellID = targetCellID
        self.targetCompartmentID = targetCompartmentID
        self.suspendedAtEpoch = suspendedAtEpoch
    }
}

public struct FidelityMigrationContext: Sendable, Codable {
    public var templates: FidelityTemplateCatalog
    public var dormantSynapses: [SynapseID: FidelityDormantSynapse]
    public var lastMigrationEpoch: UInt64

    public init(
        templates: FidelityTemplateCatalog = FidelityTemplateCatalog(),
        dormantSynapses: [SynapseID: FidelityDormantSynapse] = [:],
        lastMigrationEpoch: UInt64 = 0
    ) {
        self.templates = templates
        self.dormantSynapses = dormantSynapses
        self.lastMigrationEpoch = lastMigrationEpoch
    }
}

public enum FidelityMigrationPool: UInt8, Sendable, Hashable, Codable, CaseIterable {
    case segments = 0
    case compartments = 1
    case mechanismState = 2
    case synapses = 3
    case microdomains = 4
    case molecularSpecies = 5
}

public enum FidelityTransferKind: UInt8, Sendable, Hashable, Codable {
    case copy = 0
    case initialize = 1
    case project = 2
    case discard = 3
    case restore = 4
}

public struct FidelityIndexRemap: Sendable, Hashable, Codable {
    public var oldToNew: [UInt32]
    public var newToOld: [UInt32]

    public init(oldToNew: [UInt32], newToOld: [UInt32]) {
        self.oldToNew = oldToNew
        self.newToOld = newToOld
    }
}

public struct FidelityTransferSpan: Sendable, Hashable, Codable {
    public var pool: FidelityMigrationPool
    public var kind: FidelityTransferKind
    public var sourceLowerBound: UInt32
    public var destinationLowerBound: UInt32
    public var count: UInt32

    public init(
        pool: FidelityMigrationPool,
        kind: FidelityTransferKind,
        sourceLowerBound: UInt32,
        destinationLowerBound: UInt32,
        count: UInt32
    ) {
        self.pool = pool
        self.kind = kind
        self.sourceLowerBound = sourceLowerBound
        self.destinationLowerBound = destinationLowerBound
        self.count = count
    }
}

public struct FidelityCapacityChange: Sendable, Hashable, Codable {
    public var pool: FidelityMigrationPool
    public var oldCount: Int
    public var newCount: Int
    public var oldCapacity: Int
    public var newCapacity: Int

    public init(
        pool: FidelityMigrationPool,
        oldCount: Int,
        newCount: Int,
        oldCapacity: Int,
        newCapacity: Int
    ) {
        self.pool = pool
        self.oldCount = oldCount
        self.newCount = newCount
        self.oldCapacity = oldCapacity
        self.newCapacity = newCapacity
    }

    public var requiresReallocation: Bool { oldCapacity != newCapacity }
}

public struct FidelityProjectionRecord: Sendable, Hashable, Codable {
    public var cellID: CellID
    public var source: FidelityLevel
    public var target: FidelityLevel
    public var sourceCompartmentCount: UInt32
    public var targetCompartmentCount: UInt32
    public var targetLowerBound: UInt32
    public var chargeBefore: Float
    public var chargeAfter: Float
    public var previousChargeBefore: Float
    public var previousChargeAfter: Float
    public var calciumBefore: Float
    public var calciumAfter: Float
    public var sodiumBefore: Float
    public var sodiumAfter: Float
    public var potassiumBefore: Float
    public var potassiumAfter: Float

    public init(
        cellID: CellID,
        source: FidelityLevel,
        target: FidelityLevel,
        sourceCompartmentCount: UInt32,
        targetCompartmentCount: UInt32,
        targetLowerBound: UInt32,
        chargeBefore: Float,
        chargeAfter: Float,
        previousChargeBefore: Float,
        previousChargeAfter: Float,
        calciumBefore: Float,
        calciumAfter: Float,
        sodiumBefore: Float,
        sodiumAfter: Float,
        potassiumBefore: Float,
        potassiumAfter: Float
    ) {
        self.cellID = cellID
        self.source = source
        self.target = target
        self.sourceCompartmentCount = sourceCompartmentCount
        self.targetCompartmentCount = targetCompartmentCount
        self.targetLowerBound = targetLowerBound
        self.chargeBefore = chargeBefore
        self.chargeAfter = chargeAfter
        self.previousChargeBefore = previousChargeBefore
        self.previousChargeAfter = previousChargeAfter
        self.calciumBefore = calciumBefore
        self.calciumAfter = calciumAfter
        self.sodiumBefore = sodiumBefore
        self.sodiumAfter = sodiumAfter
        self.potassiumBefore = potassiumBefore
        self.potassiumAfter = potassiumAfter
    }
}

public struct FidelityGPUTransferPlan: Sendable, Hashable, Codable {
    public var capacityChanges: [FidelityCapacityChange]
    public var spans: [FidelityTransferSpan]
    public var segmentRemap: FidelityIndexRemap
    public var compartmentRemap: FidelityIndexRemap
    public var mechanismRemap: FidelityIndexRemap
    public var synapseRemap: FidelityIndexRemap
    public var microdomainRemap: FidelityIndexRemap
    public var molecularSpeciesRemap: FidelityIndexRemap

    public init(
        capacityChanges: [FidelityCapacityChange],
        spans: [FidelityTransferSpan],
        segmentRemap: FidelityIndexRemap,
        compartmentRemap: FidelityIndexRemap,
        mechanismRemap: FidelityIndexRemap,
        synapseRemap: FidelityIndexRemap,
        microdomainRemap: FidelityIndexRemap,
        molecularSpeciesRemap: FidelityIndexRemap
    ) {
        self.capacityChanges = capacityChanges
        self.spans = spans
        self.segmentRemap = segmentRemap
        self.compartmentRemap = compartmentRemap
        self.mechanismRemap = mechanismRemap
        self.synapseRemap = synapseRemap
        self.microdomainRemap = microdomainRemap
        self.molecularSpeciesRemap = molecularSpeciesRemap
    }

    public var requiresBufferReallocation: Bool {
        capacityChanges.contains(where: \.requiresReallocation)
    }
}

public struct FidelityMigrationPlan: Sendable, Hashable, Codable {
    public var sourceEpoch: UInt64
    public var targetEpoch: UInt64
    public var decisions: [FidelityDecision]
    public var projections: [FidelityProjectionRecord]
    public var transfer: FidelityGPUTransferPlan
    public var suspendedSynapseCount: UInt32
    public var restoredSynapseCount: UInt32
    public var digest: UInt64

    public init(
        sourceEpoch: UInt64,
        targetEpoch: UInt64,
        decisions: [FidelityDecision],
        projections: [FidelityProjectionRecord],
        transfer: FidelityGPUTransferPlan,
        suspendedSynapseCount: UInt32,
        restoredSynapseCount: UInt32,
        digest: UInt64
    ) {
        self.sourceEpoch = sourceEpoch
        self.targetEpoch = targetEpoch
        self.decisions = decisions
        self.projections = projections
        self.transfer = transfer
        self.suspendedSynapseCount = suspendedSynapseCount
        self.restoredSynapseCount = restoredSynapseCount
        self.digest = digest
    }
}

public enum FidelityMigrationError: Error, Sendable, CustomStringConvertible {
    case invalidCellIndex(UInt32)
    case duplicateDecision(UInt32)
    case staleDecision(cellIndex: UInt32, expected: FidelityLevel, actual: FidelityLevel)
    case missingTemplate(cellID: CellID, level: FidelityLevel)
    case invalidTemplate(cellID: CellID, reason: String)
    case duplicateIdentifier(pool: FidelityMigrationPool, rawValue: UInt64)
    case invalidSynapseEndpoint(SynapseID)
    case capacityExceeded(pool: FidelityMigrationPool, required: Int, limit: Int)
    case conservationFailure(cellID: CellID, quantity: String, before: Float, after: Float)
    case nonFinite(pool: FidelityMigrationPool, index: Int)

    public var description: String {
        switch self {
        case .invalidCellIndex(let index):
            return "Invalid fidelity migration cell index \(index)"
        case .duplicateDecision(let index):
            return "Duplicate fidelity decision for cell \(index)"
        case .staleDecision(let index, let expected, let actual):
            return "Stale fidelity decision for cell \(index): expected \(expected), found \(actual)"
        case .missingTemplate(let cellID, let level):
            return "Missing canonical topology for cell \(cellID) at fidelity \(level)"
        case .invalidTemplate(let cellID, let reason):
            return "Invalid fidelity template for cell \(cellID): \(reason)"
        case .duplicateIdentifier(let pool, let rawValue):
            return "Duplicate identifier \(rawValue) in \(pool)"
        case .invalidSynapseEndpoint(let id):
            return "Synapse \(id) has an invalid endpoint"
        case .capacityExceeded(let pool, let required, let limit):
            return "Fidelity migration requires \(required) \(pool) entries, above limit \(limit)"
        case .conservationFailure(let cellID, let quantity, let before, let after):
            return "Cell \(cellID) failed \(quantity) conservation: \(before) -> \(after)"
        case .nonFinite(let pool, let index):
            return "Fidelity migration produced invalid state in \(pool) at \(index)"
        }
    }
}

public struct FidelityMigrationEngine: Sendable {
    public var configuration: FidelityMigrationConfiguration

    public init(configuration: FidelityMigrationConfiguration = FidelityMigrationConfiguration()) {
        self.configuration = configuration
    }

    /// Atomically changes representation without advancing simulation time or epoch. The caller
    /// owns transaction authority; this operation only changes topology and allocation.
    @discardableResult
    public func migrate(
        decisions: [FidelityDecision],
        state: inout TissueRuntimeState,
        context: inout FidelityMigrationContext
    ) throws -> FidelityMigrationPlan {
        let selected = try validatedDecisions(decisions, state: state)
        guard !selected.isEmpty else { return identityPlan(state) }

        let source = state
        let sourceIndex = try FidelitySourceIndex(state: source)
        var nextContext = context
        for cellIndex in selected.keys.sorted() {
            try nextContext.templates.register(
                FidelityMigrationCapture.template(
                    cellIndex: cellIndex,
                    state: source,
                    index: sourceIndex,
                    source: "pre-migration-\(source.epoch)"
                )
            )
        }

        let templates = try resolvedTemplates(
            source: source,
            sourceIndex: sourceIndex,
            decisions: selected,
            catalog: nextContext.templates
        )
        var build = FidelityMigrationBuild(source: source)
        try rebuildTopology(
            source: source,
            sourceIndex: sourceIndex,
            templates: templates,
            decisions: selected,
            build: &build
        )

        for (cellIndex, decision) in selected {
            build.target.cells[Int(cellIndex)].fidelity = decision.to
        }

        let synapses = try rebuildSynapses(
            source: source,
            target: &build.target,
            build: build,
            context: &nextContext
        )
        build.synapseOldToNew = synapses.oldToNew
        build.synapseNewToOld = synapses.newToOld
        build.suspended = synapses.suspended
        build.restored = synapses.restored

        finalizeTiles(&build.target)
        build.target.epoch = source.epoch
        build.target.time = source.time
        build.target.capacity = try capacity(source: source, target: build.target)
        try build.target.validateCapacity()
        try validate(target: build.target, projections: build.projections)

        let targetIndex = try FidelitySourceIndex(state: build.target)
        for cellIndex in selected.keys.sorted() {
            try nextContext.templates.register(
                FidelityMigrationCapture.template(
                    cellIndex: cellIndex,
                    state: build.target,
                    index: targetIndex,
                    source: "post-migration-\(source.epoch)"
                )
            )
        }

        let transfer = transferPlan(source: source, build: build)
        let orderedDecisions = selected.values.sorted { $0.cellIndex < $1.cellIndex }
        let plan = FidelityMigrationPlan(
            sourceEpoch: source.epoch,
            targetEpoch: source.epoch,
            decisions: orderedDecisions,
            projections: build.projections.sorted { $0.cellID < $1.cellID },
            transfer: transfer,
            suspendedSynapseCount: build.suspended,
            restoredSynapseCount: build.restored,
            digest: FidelityMigrationHash.plan(
                sourceEpoch: source.epoch,
                targetEpoch: source.epoch,
                decisions: orderedDecisions,
                spans: transfer.spans
            )
        )

        nextContext.lastMigrationEpoch = max(nextContext.lastMigrationEpoch &+ 1, source.epoch)
        state = build.target
        context = nextContext
        return plan
    }

    private func validatedDecisions(
        _ decisions: [FidelityDecision],
        state: TissueRuntimeState
    ) throws -> [UInt32: FidelityDecision] {
        var result: [UInt32: FidelityDecision] = [:]
        for decision in decisions where decision.kind != .retain && decision.from != decision.to {
            guard Int(decision.cellIndex) < state.cells.count else {
                throw FidelityMigrationError.invalidCellIndex(decision.cellIndex)
            }
            guard result[decision.cellIndex] == nil else {
                throw FidelityMigrationError.duplicateDecision(decision.cellIndex)
            }
            let actual = state.cells[Int(decision.cellIndex)].fidelity
            guard actual == decision.from else {
                throw FidelityMigrationError.staleDecision(
                    cellIndex: decision.cellIndex,
                    expected: decision.from,
                    actual: actual
                )
            }
            result[decision.cellIndex] = decision
        }
        return result
    }

    private func resolvedTemplates(
        source: TissueRuntimeState,
        sourceIndex: FidelitySourceIndex,
        decisions: [UInt32: FidelityDecision],
        catalog: FidelityTemplateCatalog
    ) throws -> [UInt32: FidelityTopologyTemplate] {
        var result: [UInt32: FidelityTopologyTemplate] = [:]
        result.reserveCapacity(source.cells.count)

        for index in source.cells.indices {
            let cellIndex = UInt32(index)
            let current = try FidelityMigrationCapture.template(
                cellIndex: cellIndex,
                state: source,
                index: sourceIndex,
                source: "active-\(source.epoch)"
            )
            guard let decision = decisions[cellIndex] else {
                result[cellIndex] = current
                continue
            }

            let cell = source.cells[index]
            switch decision.to {
            case .fieldOnly, .cellAgent:
                result[cellIndex] = FidelityTopologyTemplate(
                    cellID: cell.id,
                    level: decision.to,
                    source: "implicit-empty"
                )

            case .reducedNeuron:
                if let canonical = catalog.template(cellID: cell.id, level: .reducedNeuron) {
                    result[cellIndex] = try canonical.validated()
                } else if configuration.templatePolicy != .canonicalOnly {
                    result[cellIndex] = try FidelityMigrationSynthesis
                        .reduced(cell: cell, current: current)
                        .validated()
                } else {
                    throw FidelityMigrationError.missingTemplate(cellID: cell.id, level: .reducedNeuron)
                }

            case .detailedNeuron:
                if current.level == .molecularDetail, var neuron = current.neuron {
                    neuron.cellID = cell.id
                    result[cellIndex] = try FidelityTopologyTemplate(
                        cellID: cell.id,
                        level: .detailedNeuron,
                        neuron: neuron,
                        preferredCompartmentID: current.preferredCompartmentID,
                        source: "molecular-demotion"
                    ).validated()
                } else if let canonical = catalog.template(cellID: cell.id, level: .detailedNeuron) {
                    result[cellIndex] = try canonical.validated()
                } else if configuration.templatePolicy == .boundedFallback {
                    result[cellIndex] = try FidelityMigrationSynthesis
                        .detailed(cell: cell, current: current)
                        .validated()
                } else {
                    throw FidelityMigrationError.missingTemplate(cellID: cell.id, level: .detailedNeuron)
                }

            case .molecularDetail:
                if let canonical = catalog.template(cellID: cell.id, level: .molecularDetail) {
                    result[cellIndex] = try canonical.validated()
                } else if configuration.templatePolicy == .boundedFallback {
                    result[cellIndex] = try FidelityMigrationSynthesis
                        .molecular(cell: cell, current: current)
                        .validated()
                } else {
                    throw FidelityMigrationError.missingTemplate(cellID: cell.id, level: .molecularDetail)
                }
            }
        }
        return result
    }

    private func rebuildTopology(
        source: TissueRuntimeState,
        sourceIndex: FidelitySourceIndex,
        templates: [UInt32: FidelityTopologyTemplate],
        decisions: [UInt32: FidelityDecision],
        build: inout FidelityMigrationBuild
    ) throws {
        build.target.segments.removeAll(keepingCapacity: true)
        build.target.compartments.removeAll(keepingCapacity: true)
        build.target.mechanismState.removeAll(keepingCapacity: true)
        build.target.synapses.removeAll(keepingCapacity: true)
        build.target.microdomains.removeAll(keepingCapacity: true)
        build.target.molecularSpecies.removeAll(keepingCapacity: true)

        var activeSegmentIDs = Set<SegmentID>()
        var activeCompartmentIDs = Set<CompartmentID>()
        var activeMicrodomainIDs = Set<MicrodomainID>()

        for tileIndex in build.target.tiles.indices {
            let cellRange = build.target.tiles[tileIndex].cellRange
            let segmentStart = UInt32(build.target.segments.count)
            let compartmentStart = UInt32(build.target.compartments.count)
            let microdomainStart = UInt32(build.target.microdomains.count)

            for cellIndex in cellRange.lowerBound..<cellRange.upperBound {
                guard Int(cellIndex) < source.cells.count,
                      let template = templates[cellIndex] else {
                    throw FidelityMigrationError.invalidCellIndex(cellIndex)
                }
                let cell = source.cells[Int(cellIndex)]
                let sourceCompartments = sourceIndex.compartmentsByCell[Int(cellIndex)]
                let sourceSummary = FidelityMigrationProjection(
                    indices: sourceCompartments,
                    state: source,
                    minimumCapacitance: configuration.minimumCapacitanceNanofarads
                )

                guard let neuron = template.neuron else { continue }
                let compartmentBase = UInt32(build.target.compartments.count)
                var localCompartmentGlobals: [UInt32] = []
                var localCompartmentByID: [CompartmentID: UInt32] = [:]

                for blueprint in neuron.compartments {
                    guard activeCompartmentIDs.insert(blueprint.id).inserted else {
                        throw FidelityMigrationError.duplicateIdentifier(
                            pool: .compartments,
                            rawValue: blueprint.id.rawValue
                        )
                    }

                    let newIndex = UInt32(build.target.compartments.count)
                    let oldIndex = sourceIndex.compartmentByID[blueprint.id]
                    let parent = blueprint.parentLocalIndex.map { compartmentBase + UInt32($0) }
                        ?? RuntimeCompartmentState.invalidIndex
                    let mechanismLower = UInt32(build.target.mechanismState.count)
                    let mechanism = mergedMechanismState(
                        blueprint: blueprint,
                        oldIndex: oldIndex,
                        source: source
                    )

                    var runtime: RuntimeCompartmentState
                    if let oldIndex {
                        runtime = source.compartments[Int(oldIndex)]
                        build.compartmentOldToNew[Int(oldIndex)] = newIndex
                    } else {
                        runtime = RuntimeCompartmentState(
                            id: blueprint.id,
                            neuronIndex: cellIndex,
                            parentIndex: parent,
                            mechanismRange: RuntimeRange(),
                            synapseRange: RuntimeRange(),
                            voltageMillivolts: blueprint.voltageMillivolts,
                            previousVoltageMillivolts: blueprint.voltageMillivolts,
                            capacitanceNanofarads: max(
                                blueprint.capacitanceNanofarads,
                                configuration.minimumCapacitanceNanofarads
                            ),
                            axialConductanceMicrosiemens: max(blueprint.axialConductanceMicrosiemens, 0),
                            injectedCurrentNanoamps: 0,
                            synapticCurrentNanoamps: 0,
                            intracellularCalciumMicromolar: 5e-5,
                            intracellularSodiumMillimolar: 12,
                            intracellularPotassiumMillimolar: 140,
                            refractoryUntilTick: 0,
                            flags: blueprint.flags
                        )
                    }

                    runtime.id = blueprint.id
                    runtime.neuronIndex = cellIndex
                    runtime.parentIndex = parent
                    runtime.mechanismRange = RuntimeRange(
                        lowerBound: mechanismLower,
                        count: UInt32(mechanism.count)
                    )
                    runtime.synapseRange = RuntimeRange()
                    if oldIndex == nil || !configuration.preserveModifiedPassiveProperties {
                        runtime.capacitanceNanofarads = max(
                            blueprint.capacitanceNanofarads,
                            configuration.minimumCapacitanceNanofarads
                        )
                        runtime.axialConductanceMicrosiemens = max(
                            blueprint.axialConductanceMicrosiemens,
                            0
                        )
                    }

                    build.target.mechanismState.append(contentsOf: mechanism)
                    build.target.compartments.append(runtime)
                    localCompartmentGlobals.append(newIndex)
                    localCompartmentByID[blueprint.id] = newIndex
                    build.compartmentByID[blueprint.id] = newIndex
                    build.compartmentNewToOld.append(oldIndex ?? UInt32.max)
                    FidelityMigrationMaps.mapStateRange(
                        oldIndex: oldIndex,
                        oldStates: source.compartments,
                        newLower: mechanismLower,
                        newCount: mechanism.count,
                        oldToNew: &build.mechanismOldToNew,
                        newToOld: &build.mechanismNewToOld
                    )
                }

                let preferred = template.preferredCompartmentID.flatMap { localCompartmentByID[$0] }
                    ?? localCompartmentGlobals.first
                if let preferred {
                    build.preferredCompartment[cell.id] = preferred
                }

                if decisions[cellIndex] != nil,
                   sourceSummary.count > 0,
                   !localCompartmentGlobals.isEmpty,
                   FidelityMigrationProjection.requiresProjection(
                    sourceIndices: sourceCompartments,
                    targetIndices: localCompartmentGlobals,
                    source: source,
                    target: build.target
                   ) {
                    build.projections.append(
                        project(
                            cell: cell,
                            target: template.level,
                            source: sourceSummary,
                            indices: localCompartmentGlobals,
                            state: &build.target
                        )
                    )
                }

                let segmentBase = UInt32(build.target.segments.count)
                for (local, blueprint) in neuron.segments.enumerated() {
                    guard activeSegmentIDs.insert(blueprint.id).inserted else {
                        throw FidelityMigrationError.duplicateIdentifier(
                            pool: .segments,
                            rawValue: blueprint.id.rawValue
                        )
                    }
                    let newIndex = UInt32(build.target.segments.count)
                    let oldIndex = sourceIndex.segmentByID[blueprint.id]
                    let parent = blueprint.parentLocalIndex.map { segmentBase + UInt32($0) }
                        ?? RuntimeSegmentState.invalidIndex
                    let compartment = neuron.segmentCompartmentLocalIndices[local]
                        .map { compartmentBase + UInt32($0) }
                        ?? RuntimeSegmentState.invalidIndex

                    var runtime = oldIndex.map { source.segments[Int($0)] }
                        ?? RuntimeSegmentState(
                            id: blueprint.id,
                            cellIndex: cellIndex,
                            parentSegmentIndex: parent,
                            firstChildIndex: RuntimeSegmentState.invalidIndex,
                            nextSiblingIndex: RuntimeSegmentState.invalidIndex,
                            compartmentIndex: compartment,
                            type: blueprint.type,
                            flags: blueprint.flags,
                            start: blueprint.start,
                            end: blueprint.end,
                            radiusMicrometers: blueprint.radiusMicrometers,
                            myelinFraction: blueprint.myelinFraction,
                            growthRateMicrometersPerSecond: blueprint.growthRateMicrometersPerSecond,
                            structuralScore: blueprint.structuralScore
                        )
                    runtime.id = blueprint.id
                    runtime.cellIndex = cellIndex
                    runtime.parentSegmentIndex = parent
                    runtime.firstChildIndex = RuntimeSegmentState.invalidIndex
                    runtime.nextSiblingIndex = RuntimeSegmentState.invalidIndex
                    runtime.compartmentIndex = compartment
                    build.target.segments.append(runtime)
                    build.segmentNewToOld.append(oldIndex ?? UInt32.max)
                    if let oldIndex {
                        build.segmentOldToNew[Int(oldIndex)] = newIndex
                    }
                }
                FidelityMigrationMaps.patchSegmentChildren(
                    range: RuntimeRange(
                        lowerBound: segmentBase,
                        count: UInt32(neuron.segments.count)
                    ),
                    state: &build.target
                )

                for blueprint in template.microdomains.sorted(by: { $0.id < $1.id }) {
                    guard activeMicrodomainIDs.insert(blueprint.id).inserted else {
                        throw FidelityMigrationError.duplicateIdentifier(
                            pool: .microdomains,
                            rawValue: blueprint.id.rawValue
                        )
                    }
                    let newIndex = UInt32(build.target.microdomains.count)
                    let oldIndex = sourceIndex.microdomainByID[blueprint.id]
                    let speciesLower = UInt32(build.target.molecularSpecies.count)
                    let species = mergedSpeciesState(
                        blueprint: blueprint,
                        oldIndex: oldIndex,
                        source: source
                    )

                    var runtime: RuntimeMicrodomainState
                    if let oldIndex {
                        runtime = source.microdomains[Int(oldIndex)]
                        build.microdomainOldToNew[Int(oldIndex)] = newIndex
                    } else {
                        runtime = RuntimeMicrodomainState(
                            id: blueprint.id,
                            ownerCellIndex: cellIndex,
                            ownerCompartmentIndex: RuntimeMicrodomainState.invalidIndex,
                            reactionNetworkIndex: blueprint.reactionNetworkIndex,
                            solverKind: blueprint.solverKind,
                            flags: blueprint.flags,
                            speciesRange: RuntimeRange(),
                            volumeFemtoliters: blueprint.volumeFemtoliters,
                            temperatureKelvin: blueprint.temperatureKelvin,
                            nextEventTick: 0,
                            propensitySum: 0
                        )
                    }
                    runtime.id = blueprint.id
                    runtime.ownerCellIndex = cellIndex
                    runtime.ownerCompartmentIndex = blueprint.ownerCompartmentID
                        .flatMap { localCompartmentByID[$0] }
                        ?? RuntimeMicrodomainState.invalidIndex
                    runtime.reactionNetworkIndex = blueprint.reactionNetworkIndex
                    runtime.solverKind = blueprint.solverKind
                    runtime.flags = blueprint.flags
                    runtime.speciesRange = RuntimeRange(
                        lowerBound: speciesLower,
                        count: UInt32(species.count)
                    )
                    runtime.volumeFemtoliters = blueprint.volumeFemtoliters
                    runtime.temperatureKelvin = blueprint.temperatureKelvin

                    build.target.molecularSpecies.append(contentsOf: species)
                    build.target.microdomains.append(runtime)
                    build.microdomainNewToOld.append(oldIndex ?? UInt32.max)
                    FidelityMigrationMaps.mapSpeciesRange(
                        oldIndex: oldIndex,
                        oldDomains: source.microdomains,
                        newLower: speciesLower,
                        newCount: species.count,
                        oldToNew: &build.molecularOldToNew,
                        newToOld: &build.molecularNewToOld
                    )
                }
            }

            build.target.tiles[tileIndex].segmentRange = RuntimeRange(
                lowerBound: segmentStart,
                count: UInt32(build.target.segments.count) - segmentStart
            )
            build.target.tiles[tileIndex].compartmentRange = RuntimeRange(
                lowerBound: compartmentStart,
                count: UInt32(build.target.compartments.count) - compartmentStart
            )
            build.target.tiles[tileIndex].microdomainRange = RuntimeRange(
                lowerBound: microdomainStart,
                count: UInt32(build.target.microdomains.count) - microdomainStart
            )
        }
    }

    private func mergedMechanismState(
        blueprint: RuntimeCompartmentBlueprint,
        oldIndex: UInt32?,
        source: TissueRuntimeState
    ) -> [Float] {
        guard let oldIndex else { return blueprint.mechanismState }
        let old = FidelityMigrationSlices.values(
            source.mechanismState,
            range: source.compartments[Int(oldIndex)].mechanismRange
        )
        guard !blueprint.mechanismState.isEmpty else { return old }
        var result = blueprint.mechanismState
        let shared = min(result.count, old.count)
        if shared > 0 {
            result.replaceSubrange(0..<shared, with: old[0..<shared])
        }
        return result
    }

    private func mergedSpeciesState(
        blueprint: RuntimeMicrodomainBlueprint,
        oldIndex: UInt32?,
        source: TissueRuntimeState
    ) -> [Float] {
        guard let oldIndex else { return blueprint.species }
        let old = FidelityMigrationSlices.values(
            source.molecularSpecies,
            range: source.microdomains[Int(oldIndex)].speciesRange
        )
        guard !blueprint.species.isEmpty else { return old }
        var result = blueprint.species
        let shared = min(result.count, old.count)
        if shared > 0 {
            result.replaceSubrange(0..<shared, with: old[0..<shared])
        }
        return result
    }

    private func project(
        cell: RuntimeCellState,
        target: FidelityLevel,
        source: FidelityMigrationProjection,
        indices: [UInt32],
        state: inout TissueRuntimeState
    ) -> FidelityProjectionRecord {
        let totalCapacitance = indices.reduce(Float.zero) {
            $0 + max(
                state.compartments[Int($1)].capacitanceNanofarads,
                configuration.minimumCapacitanceNanofarads
            )
        }
        let voltage = FidelityMigrationNumerics.clamp(
            source.charge / max(totalCapacitance * 1e-3, 1e-12),
            magnitude: configuration.maximumAbsoluteVoltageMillivolts
        )
        let previousVoltage = FidelityMigrationNumerics.clamp(
            source.previousCharge / max(totalCapacitance * 1e-3, 1e-12),
            magnitude: configuration.maximumAbsoluteVoltageMillivolts
        )

        for index in indices {
            let i = Int(index)
            let capacitance = max(
                state.compartments[i].capacitanceNanofarads,
                configuration.minimumCapacitanceNanofarads
            )
            let fraction = capacitance / max(
                totalCapacitance,
                configuration.minimumCapacitanceNanofarads
            )
            state.compartments[i].voltageMillivolts = voltage
            state.compartments[i].previousVoltageMillivolts = previousVoltage
            state.compartments[i].injectedCurrentNanoamps = source.injectedCurrent * fraction
            state.compartments[i].synapticCurrentNanoamps = source.synapticCurrent * fraction
            state.compartments[i].intracellularCalciumMicromolar = source.calcium
            state.compartments[i].intracellularSodiumMillimolar = source.sodium
            state.compartments[i].intracellularPotassiumMillimolar = source.potassium
            state.compartments[i].refractoryUntilTick = source.refractoryUntil
            state.compartments[i].flags |= source.flags
        }

        let after = FidelityMigrationProjection(
            indices: indices,
            state: state,
            minimumCapacitance: configuration.minimumCapacitanceNanofarads
        )
        return FidelityProjectionRecord(
            cellID: cell.id,
            source: cell.fidelity,
            target: target,
            sourceCompartmentCount: UInt32(source.count),
            targetCompartmentCount: UInt32(after.count),
            targetLowerBound: indices.first ?? UInt32.max,
            chargeBefore: source.charge,
            chargeAfter: after.charge,
            previousChargeBefore: source.previousCharge,
            previousChargeAfter: after.previousCharge,
            calciumBefore: source.calcium,
            calciumAfter: after.calcium,
            sodiumBefore: source.sodium,
            sodiumAfter: after.sodium,
            potassiumBefore: source.potassium,
            potassiumAfter: after.potassium
        )
    }

    private func rebuildSynapses(
        source: TissueRuntimeState,
        target: inout TissueRuntimeState,
        build: FidelityMigrationBuild,
        context: inout FidelityMigrationContext
    ) throws -> FidelityMigrationSynapseResult {
        var candidates = configuration.restoreDormantSynapses ? context.dormantSynapses : [:]
        var oldIndexByID: [SynapseID: UInt32] = [:]
        for (index, synapse) in source.synapses.enumerated() {
            let descriptor = try FidelityMigrationCapture.synapse(
                index: UInt32(index),
                state: source
            )
            candidates[synapse.id] = descriptor
            oldIndexByID[synapse.id] = UInt32(index)
        }

        var active: [(state: RuntimeSynapseState, oldIndex: UInt32?)] = []
        var dormant: [SynapseID: FidelityDormantSynapse] = [:]
        var newlySuspended: UInt32 = 0
        var restored: UInt32 = 0

        for descriptor in candidates.values.sorted(by: { $0.state.id < $1.state.id }) {
            let sourceIndex = build.compartmentByID[descriptor.sourceCompartmentID]
                ?? build.preferredCompartment[descriptor.sourceCellID]
            let targetIndex = build.compartmentByID[descriptor.targetCompartmentID]
                ?? build.preferredCompartment[descriptor.targetCellID]
            guard let sourceIndex, let targetIndex else {
                if configuration.preserveDormantSynapses {
                    var suspended = descriptor
                    if oldIndexByID[descriptor.state.id] != nil {
                        suspended.suspendedAtEpoch = source.epoch
                        newlySuspended &+= 1
                    }
                    dormant[descriptor.state.id] = suspended
                }
                continue
            }

            var synapse = descriptor.state
            synapse.sourceRouteIndex = sourceIndex
            synapse.targetCompartmentIndex = targetIndex
            let oldIndex = oldIndexByID[synapse.id]
            if oldIndex == nil { restored &+= 1 }
            active.append((synapse, oldIndex))
        }

        active.sort {
            if $0.state.targetCompartmentIndex != $1.state.targetCompartmentIndex {
                return $0.state.targetCompartmentIndex < $1.state.targetCompartmentIndex
            }
            if $0.state.sourceRouteIndex != $1.state.sourceRouteIndex {
                return $0.state.sourceRouteIndex < $1.state.sourceRouteIndex
            }
            return $0.state.id < $1.state.id
        }

        var oldToNew = Array(repeating: UInt32.max, count: source.synapses.count)
        var newToOld: [UInt32] = []
        newToOld.reserveCapacity(active.count)
        target.synapses.removeAll(keepingCapacity: true)
        target.synapses.reserveCapacity(active.count)
        for item in active {
            let newIndex = UInt32(target.synapses.count)
            target.synapses.append(item.state)
            newToOld.append(item.oldIndex ?? UInt32.max)
            if let oldIndex = item.oldIndex {
                oldToNew[Int(oldIndex)] = newIndex
            }
        }

        for index in target.compartments.indices {
            target.compartments[index].synapseRange = RuntimeRange()
        }
        var cursor = 0
        while cursor < target.synapses.count {
            let compartment = target.synapses[cursor].targetCompartmentIndex
            guard Int(compartment) < target.compartments.count else {
                throw FidelityMigrationError.invalidSynapseEndpoint(target.synapses[cursor].id)
            }
            let start = cursor
            while cursor < target.synapses.count,
                  target.synapses[cursor].targetCompartmentIndex == compartment {
                cursor += 1
            }
            target.compartments[Int(compartment)].synapseRange = RuntimeRange(
                lowerBound: UInt32(start),
                count: UInt32(cursor - start)
            )
        }

        context.dormantSynapses = dormant
        return FidelityMigrationSynapseResult(
            oldToNew: oldToNew,
            newToOld: newToOld,
            suspended: newlySuspended,
            restored: restored
        )
    }

    private func finalizeTiles(_ state: inout TissueRuntimeState) {
        for tileIndex in state.tiles.indices {
            let cellRange = state.tiles[tileIndex].cellRange
            let compartmentRange = state.tiles[tileIndex].compartmentRange
            var mask: UInt32 = 0
            for cellIndex in cellRange.lowerBound..<cellRange.upperBound
                where Int(cellIndex) < state.cells.count {
                mask |= UInt32(1) << UInt32(state.cells[Int(cellIndex)].fidelity.rawValue)
            }
            state.tiles[tileIndex].fidelityMask = mask

            guard let first = state.synapses.firstIndex(where: {
                compartmentRange.contains($0.targetCompartmentIndex)
            }) else {
                state.tiles[tileIndex].synapseRange = RuntimeRange()
                continue
            }
            var end = first
            while end < state.synapses.count,
                  compartmentRange.contains(state.synapses[end].targetCompartmentIndex) {
                end += 1
            }
            state.tiles[tileIndex].synapseRange = RuntimeRange(
                lowerBound: UInt32(first),
                count: UInt32(end - first)
            )
        }
    }

    private func capacity(
        source: TissueRuntimeState,
        target: TissueRuntimeState
    ) throws -> RuntimeCapacity {
        let limits = configuration.limits
        return RuntimeCapacity(
            tiles: max(source.capacity.tiles, target.tiles.count),
            cells: max(source.capacity.cells, target.cells.count),
            segments: try limits.capacity(
                current: source.capacity.segments,
                required: target.segments.count,
                limit: limits.maximumSegments,
                pool: .segments
            ),
            compartments: try limits.capacity(
                current: source.capacity.compartments,
                required: target.compartments.count,
                limit: limits.maximumCompartments,
                pool: .compartments
            ),
            synapses: try limits.capacity(
                current: source.capacity.synapses,
                required: target.synapses.count,
                limit: limits.maximumSynapses,
                pool: .synapses
            ),
            events: max(source.capacity.events, max(65_536, target.synapses.count * 2)),
            fieldValues: max(source.capacity.fieldValues, target.fields.count),
            microdomains: try limits.capacity(
                current: source.capacity.microdomains,
                required: target.microdomains.count,
                limit: limits.maximumMicrodomains,
                pool: .microdomains
            ),
            molecularSpecies: try limits.capacity(
                current: source.capacity.molecularSpecies,
                required: target.molecularSpecies.count,
                limit: limits.maximumMolecularSpecies,
                pool: .molecularSpecies
            )
        )
    }

    private func validate(
        target: TissueRuntimeState,
        projections: [FidelityProjectionRecord]
    ) throws {
        for (index, value) in target.mechanismState.enumerated() where !value.isFinite {
            throw FidelityMigrationError.nonFinite(pool: .mechanismState, index: index)
        }
        for (index, value) in target.molecularSpecies.enumerated()
            where !value.isFinite || value < 0 {
            throw FidelityMigrationError.nonFinite(pool: .molecularSpecies, index: index)
        }
        for projection in projections {
            try conserved(
                cellID: projection.cellID,
                quantity: "membrane charge",
                before: projection.chargeBefore,
                after: projection.chargeAfter
            )
            try conserved(
                cellID: projection.cellID,
                quantity: "previous membrane charge",
                before: projection.previousChargeBefore,
                after: projection.previousChargeAfter
            )
            try conserved(
                cellID: projection.cellID,
                quantity: "intracellular calcium",
                before: projection.calciumBefore,
                after: projection.calciumAfter
            )
            try conserved(
                cellID: projection.cellID,
                quantity: "intracellular sodium",
                before: projection.sodiumBefore,
                after: projection.sodiumAfter
            )
            try conserved(
                cellID: projection.cellID,
                quantity: "intracellular potassium",
                before: projection.potassiumBefore,
                after: projection.potassiumAfter
            )
        }
    }

    private func conserved(
        cellID: CellID,
        quantity: String,
        before: Float,
        after: Float
    ) throws {
        let scale = max(max(abs(before), abs(after)), 1)
        guard abs(before - after) <= configuration.conservationTolerance * scale else {
            throw FidelityMigrationError.conservationFailure(
                cellID: cellID,
                quantity: quantity,
                before: before,
                after: after
            )
        }
    }

    private func transferPlan(
        source: TissueRuntimeState,
        build: FidelityMigrationBuild
    ) -> FidelityGPUTransferPlan {
        let remaps: [(FidelityMigrationPool, FidelityIndexRemap)] = [
            (
                .segments,
                FidelityIndexRemap(
                    oldToNew: build.segmentOldToNew,
                    newToOld: build.segmentNewToOld
                )
            ),
            (
                .compartments,
                FidelityIndexRemap(
                    oldToNew: build.compartmentOldToNew,
                    newToOld: build.compartmentNewToOld
                )
            ),
            (
                .mechanismState,
                FidelityIndexRemap(
                    oldToNew: build.mechanismOldToNew,
                    newToOld: build.mechanismNewToOld
                )
            ),
            (
                .synapses,
                FidelityIndexRemap(
                    oldToNew: build.synapseOldToNew,
                    newToOld: build.synapseNewToOld
                )
            ),
            (
                .microdomains,
                FidelityIndexRemap(
                    oldToNew: build.microdomainOldToNew,
                    newToOld: build.microdomainNewToOld
                )
            ),
            (
                .molecularSpecies,
                FidelityIndexRemap(
                    oldToNew: build.molecularOldToNew,
                    newToOld: build.molecularNewToOld
                )
            )
        ]

        var spans = remaps.flatMap {
            FidelityMigrationTransfers.compile(pool: $0.0, remap: $0.1)
        }
        for projection in build.projections where projection.targetCompartmentCount > 0 {
            spans.append(
                FidelityTransferSpan(
                    pool: .compartments,
                    kind: .project,
                    sourceLowerBound: UInt32.max,
                    destinationLowerBound: projection.targetLowerBound,
                    count: projection.targetCompartmentCount
                )
            )
        }

        let changes = [
            FidelityCapacityChange(
                pool: .segments,
                oldCount: source.segments.count,
                newCount: build.target.segments.count,
                oldCapacity: source.capacity.segments,
                newCapacity: build.target.capacity.segments
            ),
            FidelityCapacityChange(
                pool: .compartments,
                oldCount: source.compartments.count,
                newCount: build.target.compartments.count,
                oldCapacity: source.capacity.compartments,
                newCapacity: build.target.capacity.compartments
            ),
            FidelityCapacityChange(
                pool: .mechanismState,
                oldCount: source.mechanismState.count,
                newCount: build.target.mechanismState.count,
                oldCapacity: source.mechanismState.count,
                newCapacity: build.target.mechanismState.count
            ),
            FidelityCapacityChange(
                pool: .synapses,
                oldCount: source.synapses.count,
                newCount: build.target.synapses.count,
                oldCapacity: source.capacity.synapses,
                newCapacity: build.target.capacity.synapses
            ),
            FidelityCapacityChange(
                pool: .microdomains,
                oldCount: source.microdomains.count,
                newCount: build.target.microdomains.count,
                oldCapacity: source.capacity.microdomains,
                newCapacity: build.target.capacity.microdomains
            ),
            FidelityCapacityChange(
                pool: .molecularSpecies,
                oldCount: source.molecularSpecies.count,
                newCount: build.target.molecularSpecies.count,
                oldCapacity: source.capacity.molecularSpecies,
                newCapacity: build.target.capacity.molecularSpecies
            )
        ]

        return FidelityGPUTransferPlan(
            capacityChanges: changes,
            spans: spans,
            segmentRemap: remaps[0].1,
            compartmentRemap: remaps[1].1,
            mechanismRemap: remaps[2].1,
            synapseRemap: remaps[3].1,
            microdomainRemap: remaps[4].1,
            molecularSpeciesRemap: remaps[5].1
        )
    }

    private func identityPlan(_ state: TissueRuntimeState) -> FidelityMigrationPlan {
        func identity(_ count: Int) -> FidelityIndexRemap {
            let values = (0..<count).map(UInt32.init)
            return FidelityIndexRemap(oldToNew: values, newToOld: values)
        }
        let transfer = FidelityGPUTransferPlan(
            capacityChanges: [],
            spans: [],
            segmentRemap: identity(state.segments.count),
            compartmentRemap: identity(state.compartments.count),
            mechanismRemap: identity(state.mechanismState.count),
            synapseRemap: identity(state.synapses.count),
            microdomainRemap: identity(state.microdomains.count),
            molecularSpeciesRemap: identity(state.molecularSpecies.count)
        )
        return FidelityMigrationPlan(
            sourceEpoch: state.epoch,
            targetEpoch: state.epoch,
            decisions: [],
            projections: [],
            transfer: transfer,
            suspendedSynapseCount: 0,
            restoredSynapseCount: 0,
            digest: FidelityMigrationHash.offsetBasis
        )
    }
}

public struct AdaptiveFidelityRuntimeController: Sendable {
    public var manager: AdaptiveFidelityManager
    public var migration: FidelityMigrationEngine
    public var context: FidelityMigrationContext

    public init(
        manager: AdaptiveFidelityManager = AdaptiveFidelityManager(),
        migration: FidelityMigrationEngine = FidelityMigrationEngine(),
        context: FidelityMigrationContext = FidelityMigrationContext()
    ) {
        self.manager = manager
        self.migration = migration
        self.context = context
    }

    @discardableResult
    public mutating func evaluateAndMigrate(
        state: inout TissueRuntimeState,
        tileIndices: [UInt32],
        probeWeights: [CellID: Float] = [:],
        at tick: UInt64
    ) throws -> FidelityMigrationPlan? {
        var candidateManager = manager
        let decisions = candidateManager.decide(
            state: state,
            tileIndices: tileIndices,
            probeWeights: probeWeights,
            at: tick
        )
        guard !decisions.isEmpty else {
            manager = candidateManager
            return nil
        }

        var candidateContext = context
        let plan = try migration.migrate(
            decisions: decisions,
            state: &state,
            context: &candidateContext
        )
        manager = candidateManager
        context = candidateContext
        return plan
    }
}

private struct FidelityMigrationBuild {
    var target: TissueRuntimeState
    var segmentOldToNew: [UInt32]
    var segmentNewToOld: [UInt32] = []
    var compartmentOldToNew: [UInt32]
    var compartmentNewToOld: [UInt32] = []
    var mechanismOldToNew: [UInt32]
    var mechanismNewToOld: [UInt32] = []
    var synapseOldToNew: [UInt32]
    var synapseNewToOld: [UInt32] = []
    var microdomainOldToNew: [UInt32]
    var microdomainNewToOld: [UInt32] = []
    var molecularOldToNew: [UInt32]
    var molecularNewToOld: [UInt32] = []
    var compartmentByID: [CompartmentID: UInt32] = [:]
    var preferredCompartment: [CellID: UInt32] = [:]
    var projections: [FidelityProjectionRecord] = []
    var suspended: UInt32 = 0
    var restored: UInt32 = 0

    init(source: TissueRuntimeState) {
        target = source
        segmentOldToNew = Array(repeating: UInt32.max, count: source.segments.count)
        compartmentOldToNew = Array(repeating: UInt32.max, count: source.compartments.count)
        mechanismOldToNew = Array(repeating: UInt32.max, count: source.mechanismState.count)
        synapseOldToNew = Array(repeating: UInt32.max, count: source.synapses.count)
        microdomainOldToNew = Array(repeating: UInt32.max, count: source.microdomains.count)
        molecularOldToNew = Array(repeating: UInt32.max, count: source.molecularSpecies.count)
    }
}

private struct FidelityMigrationSynapseResult {
    var oldToNew: [UInt32]
    var newToOld: [UInt32]
    var suspended: UInt32
    var restored: UInt32
}

private struct FidelityMigrationProjection {
    var count = 0
    var capacitance: Float = 0
    var charge: Float = 0
    var previousCharge: Float = 0
    var injectedCurrent: Float = 0
    var synapticCurrent: Float = 0
    var calciumWeighted: Float = 0
    var sodiumWeighted: Float = 0
    var potassiumWeighted: Float = 0
    var refractoryUntil: UInt64 = 0
    var flags: UInt32 = 0

    init(
        indices: [UInt32],
        state: TissueRuntimeState,
        minimumCapacitance: Float
    ) {
        for index in indices where Int(index) < state.compartments.count {
            let item = state.compartments[Int(index)]
            let weight = max(item.capacitanceNanofarads, minimumCapacitance)
            count += 1
            capacitance += weight
            charge += weight * item.voltageMillivolts * 1e-3
            previousCharge += weight * item.previousVoltageMillivolts * 1e-3
            injectedCurrent += item.injectedCurrentNanoamps
            synapticCurrent += item.synapticCurrentNanoamps
            calciumWeighted += weight * item.intracellularCalciumMicromolar
            sodiumWeighted += weight * item.intracellularSodiumMillimolar
            potassiumWeighted += weight * item.intracellularPotassiumMillimolar
            refractoryUntil = max(refractoryUntil, item.refractoryUntilTick)
            flags |= item.flags
        }
    }

    var calcium: Float {
        capacitance > 0 ? calciumWeighted / capacitance : 5e-5
    }

    var sodium: Float {
        capacitance > 0 ? sodiumWeighted / capacitance : 12
    }

    var potassium: Float {
        capacitance > 0 ? potassiumWeighted / capacitance : 140
    }

    static func requiresProjection(
        sourceIndices: [UInt32],
        targetIndices: [UInt32],
        source: TissueRuntimeState,
        target: TissueRuntimeState
    ) -> Bool {
        guard sourceIndices.count == targetIndices.count else { return true }
        for pair in zip(sourceIndices, targetIndices) {
            guard Int(pair.0) < source.compartments.count,
                  Int(pair.1) < target.compartments.count,
                  source.compartments[Int(pair.0)].id == target.compartments[Int(pair.1)].id else {
                return true
            }
        }
        return false
    }
}

private struct FidelitySourceIndex {
    var segmentsByCell: [[UInt32]]
    var compartmentsByCell: [[UInt32]]
    var microdomainsByCell: [[UInt32]]
    var segmentByID: [SegmentID: UInt32]
    var compartmentByID: [CompartmentID: UInt32]
    var microdomainByID: [MicrodomainID: UInt32]

    init(state: TissueRuntimeState) throws {
        segmentsByCell = Array(repeating: [], count: state.cells.count)
        compartmentsByCell = Array(repeating: [], count: state.cells.count)
        microdomainsByCell = Array(repeating: [], count: state.cells.count)
        segmentByID = [:]
        compartmentByID = [:]
        microdomainByID = [:]

        for (index, item) in state.segments.enumerated() {
            guard segmentByID.updateValue(UInt32(index), forKey: item.id) == nil else {
                throw FidelityMigrationError.duplicateIdentifier(
                    pool: .segments,
                    rawValue: item.id.rawValue
                )
            }
            guard Int(item.cellIndex) < segmentsByCell.count else {
                throw FidelityMigrationError.invalidCellIndex(item.cellIndex)
            }
            segmentsByCell[Int(item.cellIndex)].append(UInt32(index))
        }

        for (index, item) in state.compartments.enumerated() {
            guard compartmentByID.updateValue(UInt32(index), forKey: item.id) == nil else {
                throw FidelityMigrationError.duplicateIdentifier(
                    pool: .compartments,
                    rawValue: item.id.rawValue
                )
            }
            guard Int(item.neuronIndex) < compartmentsByCell.count else {
                throw FidelityMigrationError.invalidCellIndex(item.neuronIndex)
            }
            compartmentsByCell[Int(item.neuronIndex)].append(UInt32(index))
        }

        for (index, item) in state.microdomains.enumerated() {
            guard microdomainByID.updateValue(UInt32(index), forKey: item.id) == nil else {
                throw FidelityMigrationError.duplicateIdentifier(
                    pool: .microdomains,
                    rawValue: item.id.rawValue
                )
            }
            guard Int(item.ownerCellIndex) < microdomainsByCell.count else {
                throw FidelityMigrationError.invalidCellIndex(item.ownerCellIndex)
            }
            microdomainsByCell[Int(item.ownerCellIndex)].append(UInt32(index))
        }
    }
}

private enum FidelityMigrationCapture {
    static func template(
        cellIndex: UInt32,
        state: TissueRuntimeState,
        index: FidelitySourceIndex,
        source: String
    ) throws -> FidelityTopologyTemplate {
        guard Int(cellIndex) < state.cells.count else {
            throw FidelityMigrationError.invalidCellIndex(cellIndex)
        }
        let cell = state.cells[Int(cellIndex)]
        let compartmentGlobals = index.compartmentsByCell[Int(cellIndex)]
        let segmentGlobals = index.segmentsByCell[Int(cellIndex)]
        let compartmentLocal = Dictionary(
            uniqueKeysWithValues: compartmentGlobals.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let segmentLocal = Dictionary(
            uniqueKeysWithValues: segmentGlobals.enumerated().map {
                ($0.element, $0.offset)
            }
        )

        let compartments = compartmentGlobals.map { global -> RuntimeCompartmentBlueprint in
            let item = state.compartments[Int(global)]
            let parent = item.parentIndex == RuntimeCompartmentState.invalidIndex
                ? nil
                : compartmentLocal[item.parentIndex]
            return RuntimeCompartmentBlueprint(
                id: item.id,
                parentLocalIndex: parent,
                voltageMillivolts: item.voltageMillivolts,
                capacitanceNanofarads: item.capacitanceNanofarads,
                axialConductanceMicrosiemens: item.axialConductanceMicrosiemens,
                mechanismState: FidelityMigrationSlices.values(
                    state.mechanismState,
                    range: item.mechanismRange
                ),
                flags: item.flags
            )
        }

        let segments = segmentGlobals.map { global -> RuntimeSegmentBlueprint in
            let item = state.segments[Int(global)]
            let parent = item.parentSegmentIndex == RuntimeSegmentState.invalidIndex
                ? nil
                : segmentLocal[item.parentSegmentIndex]
            return RuntimeSegmentBlueprint(
                id: item.id,
                parentLocalIndex: parent,
                type: item.type,
                flags: item.flags,
                start: item.start,
                end: item.end,
                radiusMicrometers: item.radiusMicrometers,
                myelinFraction: item.myelinFraction,
                growthRateMicrometersPerSecond: item.growthRateMicrometersPerSecond,
                structuralScore: item.structuralScore
            )
        }

        let mapping = segmentGlobals.map { global -> Int? in
            let compartment = state.segments[Int(global)].compartmentIndex
            return compartment == RuntimeSegmentState.invalidIndex
                ? nil
                : compartmentLocal[compartment]
        }
        let neuron = compartments.isEmpty && segments.isEmpty
            ? nil
            : RuntimeNeuronBlueprint(
                cellID: cell.id,
                segments: segments,
                compartments: compartments,
                segmentCompartmentLocalIndices: mapping
            )

        let domains = index.microdomainsByCell[Int(cellIndex)].map {
            global -> RuntimeMicrodomainBlueprint in
            let item = state.microdomains[Int(global)]
            let owner: CompartmentID?
            if item.ownerCompartmentIndex == RuntimeMicrodomainState.invalidIndex {
                owner = nil
            } else if Int(item.ownerCompartmentIndex) < state.compartments.count {
                owner = state.compartments[Int(item.ownerCompartmentIndex)].id
            } else {
                owner = nil
            }
            return RuntimeMicrodomainBlueprint(
                id: item.id,
                ownerCellID: cell.id,
                ownerCompartmentID: owner,
                reactionNetworkIndex: item.reactionNetworkIndex,
                solverKind: item.solverKind,
                flags: item.flags,
                species: FidelityMigrationSlices.values(
                    state.molecularSpecies,
                    range: item.speciesRange
                ),
                volumeFemtoliters: item.volumeFemtoliters,
                temperatureKelvin: item.temperatureKelvin
            )
        }

        let preferred = compartments.first(where: { $0.parentLocalIndex == nil })?.id
            ?? compartments.first?.id
        return try FidelityTopologyTemplate(
            cellID: cell.id,
            level: cell.fidelity,
            neuron: neuron,
            microdomains: domains,
            preferredCompartmentID: preferred,
            source: source
        ).validated()
    }

    static func synapse(
        index: UInt32,
        state: TissueRuntimeState
    ) throws -> FidelityDormantSynapse {
        guard Int(index) < state.synapses.count else {
            throw FidelityMigrationError.invalidSynapseEndpoint(SynapseID(rawValue: 0))
        }
        let synapse = state.synapses[Int(index)]
        guard Int(synapse.sourceRouteIndex) < state.compartments.count,
              Int(synapse.targetCompartmentIndex) < state.compartments.count else {
            throw FidelityMigrationError.invalidSynapseEndpoint(synapse.id)
        }
        let sourceCompartment = state.compartments[Int(synapse.sourceRouteIndex)]
        let targetCompartment = state.compartments[Int(synapse.targetCompartmentIndex)]
        guard Int(sourceCompartment.neuronIndex) < state.cells.count,
              Int(targetCompartment.neuronIndex) < state.cells.count else {
            throw FidelityMigrationError.invalidSynapseEndpoint(synapse.id)
        }
        return FidelityDormantSynapse(
            state: synapse,
            sourceCellID: state.cells[Int(sourceCompartment.neuronIndex)].id,
            sourceCompartmentID: sourceCompartment.id,
            targetCellID: state.cells[Int(targetCompartment.neuronIndex)].id,
            targetCompartmentID: targetCompartment.id,
            suspendedAtEpoch: state.epoch
        )
    }
}

private enum FidelityMigrationSynthesis {
    static func reduced(
        cell: RuntimeCellState,
        current: FidelityTopologyTemplate
    ) -> FidelityTopologyTemplate {
        let rootCompartment = current.neuron?.compartments.first(where: {
            $0.parentLocalIndex == nil
        })
        let rootSegment = current.neuron?.segments.first(where: {
            $0.parentLocalIndex == nil
        })
        let compartmentID = rootCompartment?.id
            ?? CompartmentID(
                rawValue: FidelityMigrationHash.identifier(
                    cell: cell.id,
                    domain: 1,
                    ordinal: 0
                )
            )
        let segmentID = rootSegment?.id
            ?? SegmentID(
                rawValue: FidelityMigrationHash.identifier(
                    cell: cell.id,
                    domain: 2,
                    ordinal: 0
                )
            )
        let capacitance = max(
            current.neuron?.compartments.reduce(Float.zero) {
                $0 + $1.capacitanceNanofarads
            } ?? 1,
            0.1
        )
        let radius = max(
            max(cell.semiAxes.x, cell.semiAxes.y),
            max(cell.semiAxes.z, 1)
        )
        let compartment = RuntimeCompartmentBlueprint(
            id: compartmentID,
            voltageMillivolts: rootCompartment?.voltageMillivolts ?? -65,
            capacitanceNanofarads: capacitance,
            axialConductanceMicrosiemens: 0,
            mechanismState: rootCompartment?.mechanismState ?? []
        )
        let segment = RuntimeSegmentBlueprint(
            id: segmentID,
            type: SegmentKind.soma.rawValue,
            start: cell.position - Float4(radius, 0, 0, 0),
            end: cell.position + Float4(radius, 0, 0, 0),
            radiusMicrometers: radius,
            structuralScore: 1
        )
        let neuron = RuntimeNeuronBlueprint(
            cellID: cell.id,
            segments: [segment],
            compartments: [compartment],
            segmentCompartmentLocalIndices: [0]
        )
        return FidelityTopologyTemplate(
            cellID: cell.id,
            level: .reducedNeuron,
            neuron: neuron,
            preferredCompartmentID: compartmentID,
            source: "deterministic-reduced"
        )
    }

    static func detailed(
        cell: RuntimeCellState,
        current: FidelityTopologyTemplate
    ) -> FidelityTopologyTemplate {
        let reducedTemplate = reduced(cell: cell, current: current)
        let root = reducedTemplate.neuron!.compartments[0]
        let rootSegment = reducedTemplate.neuron!.segments[0]
        let scale = max(
            max(cell.semiAxes.x, cell.semiAxes.y),
            max(cell.semiAxes.z, 2)
        )

        var compartments = [
            RuntimeCompartmentBlueprint(
                id: root.id,
                voltageMillivolts: root.voltageMillivolts,
                capacitanceNanofarads: max(root.capacitanceNanofarads / 5, 0.1),
                mechanismState: root.mechanismState
            )
        ]
        for ordinal in 1...4 {
            compartments.append(
                RuntimeCompartmentBlueprint(
                    id: CompartmentID(
                        rawValue: FidelityMigrationHash.identifier(
                            cell: cell.id,
                            domain: 1,
                            ordinal: UInt32(ordinal)
                        )
                    ),
                    parentLocalIndex: ordinal == 2 || ordinal == 4 ? ordinal - 1 : 0,
                    voltageMillivolts: root.voltageMillivolts,
                    capacitanceNanofarads: max(root.capacitanceNanofarads / 5, 0.1),
                    axialConductanceMicrosiemens: ordinal >= 3 ? 0.15 : 0.08,
                    mechanismState: root.mechanismState
                )
            )
        }

        let offsets = [
            Float4(0, scale * 4, 0, 0),
            Float4(0, scale * 8, scale, 0),
            Float4(scale * 3, 0, 0, 0),
            Float4(scale * 12, 0, 0, 0)
        ]
        let kinds: [SegmentKind] = [
            .basalDendrite,
            .apicalDendrite,
            .axonInitialSegment,
            .axon
        ]
        var segments = [rootSegment]
        for ordinal in 1...4 {
            let parent = ordinal == 2 || ordinal == 4 ? ordinal - 1 : 0
            let start = parent == 0
                ? cell.position
                : cell.position + offsets[parent - 1]
            segments.append(
                RuntimeSegmentBlueprint(
                    id: SegmentID(
                        rawValue: FidelityMigrationHash.identifier(
                            cell: cell.id,
                            domain: 2,
                            ordinal: UInt32(ordinal)
                        )
                    ),
                    parentLocalIndex: parent,
                    type: kinds[ordinal - 1].rawValue,
                    start: start,
                    end: cell.position + offsets[ordinal - 1],
                    radiusMicrometers: max(
                        scale * (ordinal >= 3 ? 0.1 : 0.2),
                        0.1
                    ),
                    structuralScore: 1
                )
            )
        }

        let neuron = RuntimeNeuronBlueprint(
            cellID: cell.id,
            segments: segments,
            compartments: compartments,
            segmentCompartmentLocalIndices: [0, 1, 2, 3, 4]
        )
        return FidelityTopologyTemplate(
            cellID: cell.id,
            level: .detailedNeuron,
            neuron: neuron,
            preferredCompartmentID: root.id,
            source: "bounded-fallback"
        )
    }

    static func molecular(
        cell: RuntimeCellState,
        current: FidelityTopologyTemplate
    ) -> FidelityTopologyTemplate {
        var result: FidelityTopologyTemplate
        if current.neuron != nil {
            result = FidelityTopologyTemplate(
                cellID: cell.id,
                level: .molecularDetail,
                neuron: current.neuron,
                preferredCompartmentID: current.preferredCompartmentID,
                source: "active-molecular-fallback"
            )
        } else {
            result = detailed(cell: cell, current: current)
            result.level = .molecularDetail
            result.source = "bounded-molecular-fallback"
        }
        result.microdomains = result.neuron!.compartments.enumerated().map {
            index, compartment in
            RuntimeMicrodomainBlueprint(
                id: MicrodomainID(
                    rawValue: FidelityMigrationHash.identifier(
                        cell: cell.id,
                        domain: 3,
                        ordinal: UInt32(index)
                    )
                ),
                ownerCellID: cell.id,
                ownerCompartmentID: compartment.id,
                reactionNetworkIndex: 0,
                solverKind: 0,
                species: [1, 0, 0, 0],
                volumeFemtoliters: max(compartment.capacitanceNanofarads, 0.1)
            )
        }
        result.digest = FidelityMigrationHash.template(
            cellID: result.cellID,
            level: result.level,
            neuron: result.neuron,
            microdomains: result.microdomains
        )
        return result
    }
}

private enum FidelityMigrationMaps {
    static func mapStateRange(
        oldIndex: UInt32?,
        oldStates: [RuntimeCompartmentState],
        newLower: UInt32,
        newCount: Int,
        oldToNew: inout [UInt32],
        newToOld: inout [UInt32]
    ) {
        guard let oldIndex else {
            newToOld.append(contentsOf: repeatElement(UInt32.max, count: newCount))
            return
        }
        let old = oldStates[Int(oldIndex)].mechanismRange
        let shared = min(Int(old.count), newCount)
        for local in 0..<shared {
            let source = Int(old.lowerBound) + local
            let destination = Int(newLower) + local
            if source < oldToNew.count {
                oldToNew[source] = UInt32(destination)
            }
            newToOld.append(UInt32(source))
        }
        if shared < newCount {
            newToOld.append(
                contentsOf: repeatElement(UInt32.max, count: newCount - shared)
            )
        }
    }

    static func mapSpeciesRange(
        oldIndex: UInt32?,
        oldDomains: [RuntimeMicrodomainState],
        newLower: UInt32,
        newCount: Int,
        oldToNew: inout [UInt32],
        newToOld: inout [UInt32]
    ) {
        guard let oldIndex else {
            newToOld.append(contentsOf: repeatElement(UInt32.max, count: newCount))
            return
        }
        let old = oldDomains[Int(oldIndex)].speciesRange
        let shared = min(Int(old.count), newCount)
        for local in 0..<shared {
            let source = Int(old.lowerBound) + local
            let destination = Int(newLower) + local
            if source < oldToNew.count {
                oldToNew[source] = UInt32(destination)
            }
            newToOld.append(UInt32(source))
        }
        if shared < newCount {
            newToOld.append(
                contentsOf: repeatElement(UInt32.max, count: newCount - shared)
            )
        }
    }

    static func patchSegmentChildren(
        range: RuntimeRange,
        state: inout TissueRuntimeState
    ) {
        var children: [UInt32: [UInt32]] = [:]
        for index in range.lowerBound..<range.upperBound {
            let parent = state.segments[Int(index)].parentSegmentIndex
            if parent != RuntimeSegmentState.invalidIndex {
                children[parent, default: []].append(index)
            }
        }
        for key in children.keys {
            children[key]?.sort()
        }
        for (parent, values) in children {
            state.segments[Int(parent)].firstChildIndex = values.first
                ?? RuntimeSegmentState.invalidIndex
            for position in values.indices {
                state.segments[Int(values[position])].nextSiblingIndex = position + 1 < values.count
                    ? values[position + 1]
                    : RuntimeSegmentState.invalidIndex
            }
        }
    }
}

private enum FidelityMigrationTransfers {
    static func compile(
        pool: FidelityMigrationPool,
        remap: FidelityIndexRemap
    ) -> [FidelityTransferSpan] {
        var spans: [FidelityTransferSpan] = []
        var old = 0
        while old < remap.oldToNew.count {
            let destination = remap.oldToNew[old]
            let start = old
            if destination == UInt32.max {
                while old < remap.oldToNew.count,
                      remap.oldToNew[old] == UInt32.max {
                    old += 1
                }
                spans.append(
                    FidelityTransferSpan(
                        pool: pool,
                        kind: .discard,
                        sourceLowerBound: UInt32(start),
                        destinationLowerBound: UInt32.max,
                        count: UInt32(old - start)
                    )
                )
            } else {
                old += 1
                while old < remap.oldToNew.count,
                      remap.oldToNew[old] == destination + UInt32(old - start) {
                    old += 1
                }
                spans.append(
                    FidelityTransferSpan(
                        pool: pool,
                        kind: .copy,
                        sourceLowerBound: UInt32(start),
                        destinationLowerBound: destination,
                        count: UInt32(old - start)
                    )
                )
            }
        }

        var new = 0
        while new < remap.newToOld.count {
            guard remap.newToOld[new] == UInt32.max else {
                new += 1
                continue
            }
            let start = new
            while new < remap.newToOld.count,
                  remap.newToOld[new] == UInt32.max {
                new += 1
            }
            spans.append(
                FidelityTransferSpan(
                    pool: pool,
                    kind: .initialize,
                    sourceLowerBound: UInt32.max,
                    destinationLowerBound: UInt32(start),
                    count: UInt32(new - start)
                )
            )
        }
        return spans
    }
}

private enum FidelityMigrationSlices {
    static func values(
        _ source: [Float],
        range: RuntimeRange
    ) -> [Float] {
        let lower = Int(range.lowerBound)
        let upper = min(Int(range.upperBound), source.count)
        guard lower >= 0, lower <= upper else { return [] }
        return Array(source[lower..<upper])
    }
}

private enum FidelityMigrationNumerics {
    static func finite(_ value: Float4) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
    }

    static func clamp(_ value: Float, magnitude: Float) -> Float {
        min(max(value, -magnitude), magnitude)
    }
}

private enum FidelityMigrationHash {
    static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    static func combine(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var result = hash
        var value = value
        for _ in 0..<8 {
            result ^= value & 0xff
            result &*= prime
            value >>= 8
        }
        return result
    }

    static func identifier(
        cell: CellID,
        domain: UInt64,
        ordinal: UInt32
    ) -> UInt64 {
        let value = combine(
            combine(combine(offsetBasis, cell.rawValue), domain),
            UInt64(ordinal)
        )
        return value == 0 ? 1 : value
    }

    static func template(
        cellID: CellID,
        level: FidelityLevel,
        neuron: RuntimeNeuronBlueprint?,
        microdomains: [RuntimeMicrodomainBlueprint]
    ) -> UInt64 {
        var hash = combine(combine(offsetBasis, cellID.rawValue), UInt64(level.rawValue))
        for item in neuron?.compartments ?? [] {
            hash = combine(hash, item.id.rawValue)
            hash = combine(hash, UInt64(item.capacitanceNanofarads.bitPattern))
        }
        for item in neuron?.segments ?? [] {
            hash = combine(hash, item.id.rawValue)
            hash = combine(hash, UInt64(item.radiusMicrometers.bitPattern))
        }
        for item in microdomains.sorted(by: { $0.id < $1.id }) {
            hash = combine(hash, item.id.rawValue)
            hash = combine(hash, UInt64(item.species.count))
        }
        return hash
    }

    static func plan(
        sourceEpoch: UInt64,
        targetEpoch: UInt64,
        decisions: [FidelityDecision],
        spans: [FidelityTransferSpan]
    ) -> UInt64 {
        var hash = combine(combine(offsetBasis, sourceEpoch), targetEpoch)
        for item in decisions.sorted(by: { $0.cellIndex < $1.cellIndex }) {
            hash = combine(hash, UInt64(item.cellIndex))
            hash = combine(hash, UInt64(item.to.rawValue))
        }
        for item in spans {
            hash = combine(hash, UInt64(item.pool.rawValue))
            hash = combine(hash, UInt64(item.kind.rawValue))
            hash = combine(hash, UInt64(item.sourceLowerBound))
            hash = combine(hash, UInt64(item.destinationLowerBound))
            hash = combine(hash, UInt64(item.count))
        }
        return hash
    }
}
