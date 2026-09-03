import Foundation
import NumiTissueCore
import NumiTissueModels

/// Declares the numerical intent of a backend. A profile is part of scientific provenance;
/// callers must not infer it from a backend name or device type.
public enum RuntimeNumericalProfile: String, Sendable, Codable, CaseIterable {
    case reference64
    case scientific32
    case performance32
}

/// Semantic state domains used by differential execution, tolerance policies and reports.
public enum RuntimeComparisonDomain: String, Sendable, Codable, CaseIterable, Hashable {
    case metadata
    case tiles
    case cells
    case regulatoryState
    case segments
    case compartments
    case mechanismState
    case synapses
    case fields
    case microdomains
    case molecularSpecies
    case pendingEvents
    case output
    case counters
}

@frozen
public struct RuntimeFloatTolerance: Sendable, Hashable, Codable {
    public var absolute: Float
    public var relative: Float
    public var maximumULPDistance: UInt32
    public var signedZeroIsEqual: Bool

    public init(
        absolute: Float,
        relative: Float,
        maximumULPDistance: UInt32 = 0,
        signedZeroIsEqual: Bool = true
    ) {
        precondition(absolute.isFinite && absolute >= 0)
        precondition(relative.isFinite && relative >= 0)
        self.absolute = absolute
        self.relative = relative
        self.maximumULPDistance = maximumULPDistance
        self.signedZeroIsEqual = signedZeroIsEqual
    }

    public static let bitwise = Self(
        absolute: 0,
        relative: 0,
        maximumULPDistance: 0,
        signedZeroIsEqual: false
    )

    @inlinable
    public func accepts(_ lhs: Float, _ rhs: Float) -> Bool {
        if lhs.bitPattern == rhs.bitPattern { return true }
        if signedZeroIsEqual, lhs == 0, rhs == 0 { return true }
        guard lhs.isFinite, rhs.isFinite else { return false }

        let absoluteError = abs(lhs - rhs)
        if absoluteError <= absolute { return true }
        let scale = max(abs(lhs), abs(rhs), Float.leastNormalMagnitude)
        if absoluteError <= relative * scale { return true }
        return Self.ulpDistance(lhs, rhs) <= UInt64(maximumULPDistance)
    }

    @inlinable
    public static func ulpDistance(_ lhs: Float, _ rhs: Float) -> UInt64 {
        let left = orderedBits(lhs.bitPattern)
        let right = orderedBits(rhs.bitPattern)
        return left >= right ? UInt64(left - right) : UInt64(right - left)
    }

    @inlinable
    static func orderedBits(_ bits: UInt32) -> UInt32 {
        (bits & 0x8000_0000) == 0 ? bits | 0x8000_0000 : ~bits
    }
}

/// Explicit cross-backend comparison contract. Integer identity and topology are exact by default;
/// floating-point acceptance is declared per state domain.
public struct RuntimeDeterminismContract: Sendable, Hashable, Codable {
    public var identifier: String
    public var requireExactTopology: Bool
    public var requireExactEventOrdering: Bool
    public var requireExactCounters: Bool
    public var tolerances: [RuntimeComparisonDomain: RuntimeFloatTolerance]
    public var maximumReportedDifferences: Int

    public init(
        identifier: String,
        requireExactTopology: Bool = true,
        requireExactEventOrdering: Bool = true,
        requireExactCounters: Bool = true,
        tolerances: [RuntimeComparisonDomain: RuntimeFloatTolerance],
        maximumReportedDifferences: Int = 256
    ) {
        precondition(!identifier.isEmpty)
        precondition(maximumReportedDifferences > 0)
        self.identifier = identifier
        self.requireExactTopology = requireExactTopology
        self.requireExactEventOrdering = requireExactEventOrdering
        self.requireExactCounters = requireExactCounters
        self.tolerances = tolerances
        self.maximumReportedDifferences = maximumReportedDifferences
    }

    public func tolerance(for domain: RuntimeComparisonDomain) -> RuntimeFloatTolerance {
        tolerances[domain] ?? .bitwise
    }

    public static let bitwise = RuntimeDeterminismContract(
        identifier: "numitissue.bitwise.v1",
        tolerances: Dictionary(
            uniqueKeysWithValues: RuntimeComparisonDomain.allCases.map { ($0, .bitwise) }
        )
    )

    /// Default contract for correctness-oriented CPU/Metal comparisons. It keeps identity,
    /// topology and event order exact while allowing bounded FP32 arithmetic differences.
    public static let scientific32 = RuntimeDeterminismContract(
        identifier: "numitissue.scientific32.v1",
        tolerances: [
            .tiles: .init(absolute: 1e-6, relative: 1e-6, maximumULPDistance: 16),
            .cells: .init(absolute: 2e-6, relative: 2e-6, maximumULPDistance: 24),
            .regulatoryState: .init(absolute: 2e-6, relative: 2e-6, maximumULPDistance: 24),
            .segments: .init(absolute: 2e-6, relative: 2e-6, maximumULPDistance: 24),
            .compartments: .init(absolute: 1e-4, relative: 2e-6, maximumULPDistance: 64),
            .mechanismState: .init(absolute: 2e-5, relative: 2e-5, maximumULPDistance: 64),
            .synapses: .init(absolute: 2e-6, relative: 2e-5, maximumULPDistance: 64),
            .fields: .init(absolute: 2e-6, relative: 2e-5, maximumULPDistance: 64),
            .microdomains: .init(absolute: 2e-6, relative: 2e-5, maximumULPDistance: 64),
            .molecularSpecies: .init(absolute: 2e-6, relative: 2e-5, maximumULPDistance: 64),
            .pendingEvents: .init(absolute: 1e-6, relative: 1e-6, maximumULPDistance: 16),
            .output: .init(absolute: 1e-4, relative: 2e-5, maximumULPDistance: 64),
            .counters: .bitwise,
            .metadata: .bitwise
        ]
    )

    /// Performance mode retains exact discrete state but permits wider, declared numerical drift.
    public static let performance32 = RuntimeDeterminismContract(
        identifier: "numitissue.performance32.v1",
        requireExactCounters: false,
        tolerances: [
            .tiles: .init(absolute: 1e-5, relative: 1e-4, maximumULPDistance: 256),
            .cells: .init(absolute: 1e-5, relative: 1e-4, maximumULPDistance: 256),
            .regulatoryState: .init(absolute: 1e-5, relative: 1e-4, maximumULPDistance: 256),
            .segments: .init(absolute: 1e-5, relative: 1e-4, maximumULPDistance: 256),
            .compartments: .init(absolute: 5e-3, relative: 5e-4, maximumULPDistance: 2_048),
            .mechanismState: .init(absolute: 5e-4, relative: 5e-4, maximumULPDistance: 2_048),
            .synapses: .init(absolute: 2e-4, relative: 5e-4, maximumULPDistance: 2_048),
            .fields: .init(absolute: 2e-4, relative: 5e-4, maximumULPDistance: 2_048),
            .microdomains: .init(absolute: 2e-4, relative: 5e-4, maximumULPDistance: 2_048),
            .molecularSpecies: .init(absolute: 2e-4, relative: 5e-4, maximumULPDistance: 2_048),
            .pendingEvents: .init(absolute: 1e-5, relative: 1e-5, maximumULPDistance: 128),
            .output: .init(absolute: 5e-3, relative: 5e-4, maximumULPDistance: 2_048),
            .counters: .bitwise,
            .metadata: .bitwise
        ]
    )
}

/// Canonical event target identity used to compare event wheels after topology compaction.
public enum RuntimePendingEventTarget: Sendable, Hashable, Codable {
    case synapse(SynapseID)
    case raw(UInt64)
}

@frozen
public struct RuntimePendingEvent: Sendable, Hashable, Codable, Comparable {
    public var arrivalTick: UInt64
    public var source: UInt64
    public var target: RuntimePendingEventTarget
    public var amplitude: Float
    public var kind: RoutedEventKind
    public var flags: UInt16
    public var sequence: UInt32

    public init(
        arrivalTick: UInt64,
        source: UInt64,
        target: RuntimePendingEventTarget,
        amplitude: Float,
        kind: RoutedEventKind,
        flags: UInt16,
        sequence: UInt32
    ) {
        self.arrivalTick = arrivalTick
        self.source = source
        self.target = target
        self.amplitude = amplitude
        self.kind = kind
        self.flags = flags
        self.sequence = sequence
    }

    public init(_ event: RoutedEvent, state: TissueRuntimeState) {
        let target: RuntimePendingEventTarget
        if event.destination < UInt64(state.synapses.count) {
            let synapse = state.synapses[Int(event.destination)]
            if Int(synapse.sourceRouteIndex) < state.compartments.count,
               state.compartments[Int(synapse.sourceRouteIndex)].id.rawValue == event.source {
                target = .synapse(synapse.id)
            } else {
                target = .raw(event.destination)
            }
        } else {
            target = .raw(event.destination)
        }
        self.init(
            arrivalTick: event.arrivalTick,
            source: event.source,
            target: target,
            amplitude: event.amplitude,
            kind: event.kind,
            flags: event.flags,
            sequence: event.sequence
        )
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.arrivalTick != rhs.arrivalTick { return lhs.arrivalTick < rhs.arrivalTick }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.flags != rhs.flags { return lhs.flags < rhs.flags }
        switch (lhs.target, rhs.target) {
        case (.synapse(let left), .synapse(let right)): return left < right
        case (.raw(let left), .raw(let right)): return left < right
        case (.synapse, .raw): return true
        case (.raw, .synapse): return false
        }
    }
}

@frozen
public struct RuntimeComparisonDigest: Sendable, Hashable, Codable, CustomStringConvertible {
    public var lane0: UInt64
    public var lane1: UInt64
    public var lane2: UInt64
    public var lane3: UInt64

    public init(lane0: UInt64, lane1: UInt64, lane2: UInt64, lane3: UInt64) {
        self.lane0 = lane0
        self.lane1 = lane1
        self.lane2 = lane2
        self.lane3 = lane3
    }

    public static let zero = Self(lane0: 0, lane1: 0, lane2: 0, lane3: 0)

    public var description: String {
        [lane0, lane1, lane2, lane3]
            .map { String(format: "%016llx", $0) }
            .joined()
    }
}

public struct RuntimePoolDigests: Sendable, Hashable, Codable {
    public var metadata: RuntimeComparisonDigest
    public var tiles: RuntimeComparisonDigest
    public var cells: RuntimeComparisonDigest
    public var regulatoryState: RuntimeComparisonDigest
    public var segments: RuntimeComparisonDigest
    public var compartments: RuntimeComparisonDigest
    public var mechanismState: RuntimeComparisonDigest
    public var synapses: RuntimeComparisonDigest
    public var fields: RuntimeComparisonDigest
    public var microdomains: RuntimeComparisonDigest
    public var molecularSpecies: RuntimeComparisonDigest
    public var pendingEvents: RuntimeComparisonDigest

    public init(
        metadata: RuntimeComparisonDigest,
        tiles: RuntimeComparisonDigest,
        cells: RuntimeComparisonDigest,
        regulatoryState: RuntimeComparisonDigest,
        segments: RuntimeComparisonDigest,
        compartments: RuntimeComparisonDigest,
        mechanismState: RuntimeComparisonDigest,
        synapses: RuntimeComparisonDigest,
        fields: RuntimeComparisonDigest,
        microdomains: RuntimeComparisonDigest,
        molecularSpecies: RuntimeComparisonDigest,
        pendingEvents: RuntimeComparisonDigest
    ) {
        self.metadata = metadata
        self.tiles = tiles
        self.cells = cells
        self.regulatoryState = regulatoryState
        self.segments = segments
        self.compartments = compartments
        self.mechanismState = mechanismState
        self.synapses = synapses
        self.fields = fields
        self.microdomains = microdomains
        self.molecularSpecies = molecularSpecies
        self.pendingEvents = pendingEvents
    }

    public var combined: RuntimeComparisonDigest {
        var digest = RuntimeDigestAccumulator(domain: 0x434F_4D42_494E_4544)
        for item in [
            metadata, tiles, cells, regulatoryState, segments, compartments,
            mechanismState, synapses, fields, microdomains, molecularSpecies,
            pendingEvents
        ] {
            digest.combine(item.lane0)
            digest.combine(item.lane1)
            digest.combine(item.lane2)
            digest.combine(item.lane3)
        }
        return digest.finalize()
    }
}

public struct RuntimePhaseDigestSnapshot: Sendable, Codable {
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var transaction: TransactionID
    public var phase: RuntimePhase
    public var tickRange: Range<UInt64>
    public var counts: RuntimeCapacity
    public var pendingEventCount: Int
    public var poolDigests: RuntimePoolDigests
    public var counters: RuntimeCounters
    public var metadata: [String: String]

    public init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        transaction: TransactionID,
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        state: TissueRuntimeState,
        pendingEvents: [RuntimePendingEvent],
        counters: RuntimeCounters,
        metadata: [String: String] = [:]
    ) {
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.transaction = transaction
        self.phase = phase
        self.tickRange = tickRange
        self.counts = state.counts
        self.pendingEventCount = pendingEvents.count
        self.poolDigests = RuntimeStateDigestBuilder.make(
            state: state,
            pendingEvents: pendingEvents
        )
        self.counters = counters
        self.metadata = metadata
    }
}

public struct RuntimeShadowInspection: Sendable, Codable {
    public var backendName: String
    public var numericalProfile: RuntimeNumericalProfile
    public var transaction: TransactionID
    public var phase: RuntimePhase
    public var tickRange: Range<UInt64>
    public var state: TissueRuntimeState
    public var pendingEvents: [RuntimePendingEvent]
    public var counters: RuntimeCounters
    public var metadata: [String: String]

    public init(
        backendName: String,
        numericalProfile: RuntimeNumericalProfile,
        transaction: TransactionID,
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        state: TissueRuntimeState,
        pendingEvents: [RuntimePendingEvent],
        counters: RuntimeCounters,
        metadata: [String: String] = [:]
    ) {
        self.backendName = backendName
        self.numericalProfile = numericalProfile
        self.transaction = transaction
        self.phase = phase
        self.tickRange = tickRange
        self.state = state
        self.pendingEvents = pendingEvents.sorted()
        self.counters = counters
        self.metadata = metadata
    }

    public var digestSnapshot: RuntimePhaseDigestSnapshot {
        RuntimePhaseDigestSnapshot(
            backendName: backendName,
            numericalProfile: numericalProfile,
            transaction: transaction,
            phase: phase,
            tickRange: tickRange,
            state: state,
            pendingEvents: pendingEvents,
            counters: counters,
            metadata: metadata
        )
    }
}

/// Debug/scientific introspection is explicit because production backends may need to terminate a
/// command buffer and perform readback. It must never be invoked implicitly by normal execution.
public protocol RuntimePhaseInspectableBackend: NumiTissueExecutionBackend {
    var numericalProfile: RuntimeNumericalProfile { get }

    func captureShadowDigest(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimePhaseDigestSnapshot

    func exportShadowInspection(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context: ExecutionContext
    ) async throws -> RuntimeShadowInspection
}

public enum RuntimeStateDigestBuilder {
    public static func make(
        state: TissueRuntimeState,
        pendingEvents sourceEvents: [RuntimePendingEvent] = []
    ) -> RuntimePoolDigests {
        let events = sourceEvents.sorted()

        var metadata = RuntimeDigestAccumulator(domain: 0x4D45_5441_4441_5441)
        metadata.combine(state.time.tick)
        metadata.combine(state.epoch)
        combine(state.capacity, into: &metadata)

        var tiles = RuntimeDigestAccumulator(domain: 0x5449_4C45_5300_0001)
        tiles.combine(state.tiles.count)
        for value in state.tiles { combine(value, into: &tiles) }

        var cells = RuntimeDigestAccumulator(domain: 0x4345_4C4C_5300_0001)
        cells.combine(state.cells.count)
        for value in state.cells { combine(value, into: &cells) }

        var regulatory = RuntimeDigestAccumulator(domain: 0x5245_4755_4C41_544F)
        regulatory.combine(state.regulatoryState.count)
        for value in state.regulatoryState { regulatory.combine(value) }

        var segments = RuntimeDigestAccumulator(domain: 0x5345_474D_454E_5453)
        segments.combine(state.segments.count)
        for value in state.segments { combine(value, into: &segments) }

        var compartments = RuntimeDigestAccumulator(domain: 0x434F_4D50_4152_5453)
        compartments.combine(state.compartments.count)
        for value in state.compartments { combine(value, into: &compartments) }

        var mechanisms = RuntimeDigestAccumulator(domain: 0x4D45_4348_414E_4953)
        mechanisms.combine(state.mechanismState.count)
        for value in state.mechanismState { mechanisms.combine(value) }

        var synapses = RuntimeDigestAccumulator(domain: 0x5359_4E41_5053_4553)
        synapses.combine(state.synapses.count)
        for value in state.synapses { combine(value, into: &synapses) }

        var fields = RuntimeDigestAccumulator(domain: 0x4649_454C_4453_0001)
        fields.combine(state.fields.count)
        for value in state.fields { combine(value, into: &fields) }

        var microdomains = RuntimeDigestAccumulator(domain: 0x4D49_4352_4F44_4F4D)
        microdomains.combine(state.microdomains.count)
        for value in state.microdomains { combine(value, into: &microdomains) }

        var molecular = RuntimeDigestAccumulator(domain: 0x4D4F_4C45_4355_4C41)
        molecular.combine(state.molecularSpecies.count)
        for value in state.molecularSpecies { molecular.combine(value) }

        var pending = RuntimeDigestAccumulator(domain: 0x4556_454E_5453_0001)
        pending.combine(events.count)
        for value in events { combine(value, into: &pending) }

        return RuntimePoolDigests(
            metadata: metadata.finalize(),
            tiles: tiles.finalize(),
            cells: cells.finalize(),
            regulatoryState: regulatory.finalize(),
            segments: segments.finalize(),
            compartments: compartments.finalize(),
            mechanismState: mechanisms.finalize(),
            synapses: synapses.finalize(),
            fields: fields.finalize(),
            microdomains: microdomains.finalize(),
            molecularSpecies: molecular.finalize(),
            pendingEvents: pending.finalize()
        )
    }

    private static func combine(_ value: RuntimeCapacity, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.tiles)
        digest.combine(value.cells)
        digest.combine(value.segments)
        digest.combine(value.compartments)
        digest.combine(value.synapses)
        digest.combine(value.events)
        digest.combine(value.fieldValues)
        digest.combine(value.microdomains)
        digest.combine(value.molecularSpecies)
    }

    private static func combine(_ value: RuntimeRange, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.lowerBound)
        digest.combine(value.count)
    }

    private static func combine(_ value: Float4, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.x)
        digest.combine(value.y)
        digest.combine(value.z)
        digest.combine(value.w)
    }

    private static func combine(_ value: TileRuntimeState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.coordinate.x)
        digest.combine(value.coordinate.y)
        digest.combine(value.coordinate.z)
        digest.combine(value.flags)
        digest.combine(value.fidelityMask)
        combine(value.cellRange, into: &digest)
        combine(value.segmentRange, into: &digest)
        combine(value.compartmentRange, into: &digest)
        combine(value.synapseRange, into: &digest)
        combine(value.fieldRange, into: &digest)
        combine(value.microdomainRange, into: &digest)
        digest.combine(value.lastActiveTick)
        digest.combine(value.activityScore)
        digest.combine(value.uncertaintyScore)
        digest.combine(value.damageScore)
        digest.combine(value.metabolicStress)
    }

    private static func combine(_ value: RuntimeCellState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.lineage.rawValue)
        digest.combine(value.tileIndex)
        digest.combine(value.typeIndex)
        digest.combine(value.developmentalState)
        digest.combine(value.fidelity.rawValue)
        digest.combine(value.flags)
        combine(value.position, into: &digest)
        combine(value.orientation, into: &digest)
        combine(value.semiAxes, into: &digest)
        combine(value.velocity, into: &digest)
        digest.combine(value.ageSeconds)
        digest.combine(value.cycleProgress)
        digest.combine(value.differentiationProgress)
        digest.combine(value.energyReserve)
        digest.combine(value.oxygenStress)
        digest.combine(value.glucoseStress)
        digest.combine(value.damage)
        digest.combine(value.apoptosisHazard)
        combine(value.regulatoryRange, into: &digest)
    }

    private static func combine(_ value: RuntimeSegmentState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.cellIndex)
        digest.combine(value.parentSegmentIndex)
        digest.combine(value.firstChildIndex)
        digest.combine(value.nextSiblingIndex)
        digest.combine(value.compartmentIndex)
        digest.combine(value.type)
        digest.combine(value.flags)
        combine(value.start, into: &digest)
        combine(value.end, into: &digest)
        digest.combine(value.radiusMicrometers)
        digest.combine(value.myelinFraction)
        digest.combine(value.growthRateMicrometersPerSecond)
        digest.combine(value.structuralScore)
    }

    private static func combine(_ value: RuntimeCompartmentState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.neuronIndex)
        digest.combine(value.parentIndex)
        combine(value.mechanismRange, into: &digest)
        combine(value.synapseRange, into: &digest)
        digest.combine(value.voltageMillivolts)
        digest.combine(value.previousVoltageMillivolts)
        digest.combine(value.capacitanceNanofarads)
        digest.combine(value.axialConductanceMicrosiemens)
        digest.combine(value.injectedCurrentNanoamps)
        digest.combine(value.synapticCurrentNanoamps)
        digest.combine(value.intracellularCalciumMicromolar)
        digest.combine(value.intracellularSodiumMillimolar)
        digest.combine(value.intracellularPotassiumMillimolar)
        digest.combine(value.refractoryUntilTick)
        digest.combine(value.flags)
    }

    private static func combine(_ value: RuntimeSynapseState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.sourceRouteIndex)
        digest.combine(value.targetCompartmentIndex)
        digest.combine(value.parameterIndex)
        digest.combine(value.flags)
        digest.combine(value.delayTicks)
        digest.combine(value.weight)
        digest.combine(value.conductance)
        digest.combine(value.shortTermUtilization)
        digest.combine(value.shortTermResources)
        digest.combine(value.preTrace)
        digest.combine(value.postTrace)
        digest.combine(value.eligibility)
        digest.combine(value.consolidation)
        digest.combine(value.structuralScore)
        digest.combine(value.lastEventTick)
    }

    private static func combine(_ value: RuntimeFieldValue, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.concentration)
        digest.combine(value.source)
        digest.combine(value.sink)
        digest.combine(value.diffusionScale)
    }

    private static func combine(_ value: RuntimeMicrodomainState, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.id.rawValue)
        digest.combine(value.ownerCellIndex)
        digest.combine(value.ownerCompartmentIndex)
        digest.combine(value.reactionNetworkIndex)
        digest.combine(value.solverKind)
        digest.combine(value.flags)
        combine(value.speciesRange, into: &digest)
        digest.combine(value.volumeFemtoliters)
        digest.combine(value.temperatureKelvin)
        digest.combine(value.nextEventTick)
        digest.combine(value.propensitySum)
    }

    private static func combine(_ value: RuntimePendingEvent, into digest: inout RuntimeDigestAccumulator) {
        digest.combine(value.arrivalTick)
        digest.combine(value.source)
        switch value.target {
        case .synapse(let id):
            digest.combine(UInt8(0))
            digest.combine(id.rawValue)
        case .raw(let raw):
            digest.combine(UInt8(1))
            digest.combine(raw)
        }
        digest.combine(value.amplitude)
        digest.combine(value.kind.rawValue)
        digest.combine(value.flags)
        digest.combine(value.sequence)
    }
}

struct RuntimeDigestAccumulator {
    private var lane0: UInt64
    private var lane1: UInt64
    private var lane2: UInt64
    private var lane3: UInt64
    private var count: UInt64 = 0

    init(domain: UInt64) {
        lane0 = 0x243F_6A88_85A3_08D3 ^ domain
        lane1 = 0x1319_8A2E_0370_7344 &+ domain
        lane2 = 0xA409_3822_299F_31D0 ^ RuntimeDigestAccumulator.rotateLeft(domain, by: 17)
        lane3 = 0x082E_FA98_EC4E_6C89 &+ RuntimeDigestAccumulator.rotateLeft(domain, by: 41)
    }

    mutating func combine(_ value: UInt64) {
        count &+= 1
        let keyed = RuntimeDigestAccumulator.mix64(
            value &+ count &* 0x9E37_79B9_7F4A_7C15
        )
        lane0 = RuntimeDigestAccumulator.rotateLeft(lane0 ^ keyed, by: 13) &* 0xBF58_476D_1CE4_E5B9
        lane1 = RuntimeDigestAccumulator.rotateLeft(lane1 &+ keyed, by: 29) &* 0x94D0_49BB_1331_11EB
        lane2 ^= RuntimeDigestAccumulator.mix64(keyed &+ lane0)
        lane3 &+= RuntimeDigestAccumulator.rotateLeft(keyed ^ lane1, by: 37)
    }

    mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }
    mutating func combine(_ value: UInt32) { combine(UInt64(value)) }
    mutating func combine(_ value: Int32) { combine(UInt64(bitPattern: Int64(value))) }
    mutating func combine(_ value: UInt16) { combine(UInt64(value)) }
    mutating func combine(_ value: UInt8) { combine(UInt64(value)) }
    mutating func combine(_ value: Float) { combine(UInt64(value.bitPattern)) }

    func finalize() -> RuntimeComparisonDigest {
        RuntimeComparisonDigest(
            lane0: RuntimeDigestAccumulator.mix64(lane0 ^ count),
            lane1: RuntimeDigestAccumulator.mix64(lane1 &+ count),
            lane2: RuntimeDigestAccumulator.mix64(lane2 ^ RuntimeDigestAccumulator.rotateLeft(count, by: 23)),
            lane3: RuntimeDigestAccumulator.mix64(lane3 &+ RuntimeDigestAccumulator.rotateLeft(count, by: 47))
        )
    }

    @inline(__always)
    private static func rotateLeft(_ value: UInt64, by amount: UInt64) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return value }
        return (value << shift) | (value >> (64 - shift))
    }

    @inline(__always)
    private static func mix64(_ source: UInt64) -> UInt64 {
        var value = source
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
