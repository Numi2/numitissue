import Foundation
import NumiTissueCore
import NumiTissueModels

public struct NeuralPathologyRuntimeBinding: Sendable, Hashable, Codable {
    public var channel: NeuralPathologyEffectChannel
    public var path: String
    public var operation: TissueMutationOperation?
    public var persistence: TissueMutationPersistence
    public var scale: Double
    public var offset: Double
    public var minimum: Double?
    public var maximum: Double?

    public init(
        channel: NeuralPathologyEffectChannel,
        path: String,
        operation: TissueMutationOperation? = nil,
        persistence: TissueMutationPersistence,
        scale: Double = 1,
        offset: Double = 0,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.channel = channel
        self.path = path
        self.operation = operation
        self.persistence = persistence
        self.scale = scale
        self.offset = offset
        self.minimum = minimum
        self.maximum = maximum
    }

    public func validated() throws -> Self {
        guard !path.isEmpty,
              scale.isFinite,
              offset.isFinite,
              minimum?.isFinite != false,
              maximum?.isFinite != false else {
            throw NeuralPathologyRuntimeError.invalidBinding(path)
        }
        if let minimum, let maximum, minimum > maximum {
            throw NeuralPathologyRuntimeError.invalidBinding(path)
        }
        return self
    }

    public func lower(
        effect: NeuralPathologyEffect,
        selector: TissueSelection,
        source: String
    ) throws -> RuntimeParameterMutation {
        var value = effect.value * scale + offset
        if let minimum { value = max(value, minimum) }
        if let maximum { value = min(value, maximum) }
        guard value.isFinite,
              value >= -Double(Float.greatestFiniteMagnitude),
              value <= Double(Float.greatestFiniteMagnitude) else {
            throw NeuralPathologyRuntimeError.nonFiniteEffect(channel)
        }
        let operation = self.operation ?? (effect.isMultiplier ? .multiply : .set)
        return RuntimeParameterMutation(
            path: path,
            selector: selector,
            operation: operation,
            value: Float(value),
            persistence: persistence,
            source: source
        )
    }
}

public struct NeuralPathologyRuntimeLayout: Sendable, Hashable, Codable {
    public var bindings: [NeuralPathologyRuntimeBinding]

    public init(bindings: [NeuralPathologyRuntimeBinding]) {
        self.bindings = bindings
    }

    public func validated() throws -> Self {
        guard !bindings.isEmpty,
              Set(bindings.map { ($0.channel.rawValue, $0.path) }).count == bindings.count else {
            throw NeuralPathologyRuntimeError.invalidLayout
        }
        for binding in bindings { _ = try binding.validated() }
        return self
    }

    public static func standard(
        membraneLeakPath: String = "mechanism.parameter.membrane_leak_multiplier",
        thresholdShiftPath: String = "mechanism.parameter.firing_threshold_shift_mv",
        sodiumConductancePath: String = "mechanism.parameter.sodium_conductance_multiplier",
        calciumConductancePath: String = "mechanism.parameter.calcium_conductance_multiplier",
        releaseProbabilityPath: String = "mechanism.parameter.release_probability_multiplier",
        conductionVelocityPath: String = "mechanism.parameter.conduction_velocity_multiplier",
        apoptosisHazardPath: String = "cell.apoptosis_hazard_per_second"
    ) -> Self {
        Self(bindings: [
            NeuralPathologyRuntimeBinding(
                channel: .energyReserve,
                path: "cell.energy_reserve",
                operation: .set,
                persistence: .persistent,
                minimum: 0,
                maximum: 1
            ),
            NeuralPathologyRuntimeBinding(
                channel: .membraneLeak,
                path: membraneLeakPath,
                operation: .set,
                persistence: .transaction,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .firingThresholdShift,
                path: thresholdShiftPath,
                operation: .set,
                persistence: .transaction
            ),
            NeuralPathologyRuntimeBinding(
                channel: .sodiumConductance,
                path: sodiumConductancePath,
                operation: .set,
                persistence: .transaction,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .calciumConductance,
                path: calciumConductancePath,
                operation: .set,
                persistence: .transaction,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .excitatorySynapticStrength,
                path: "synapse.weight",
                operation: .multiply,
                persistence: .transaction,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .synapticReleaseProbability,
                path: releaseProbabilityPath,
                operation: .set,
                persistence: .transaction,
                minimum: 0,
                maximum: 1
            ),
            NeuralPathologyRuntimeBinding(
                channel: .conductionVelocity,
                path: conductionVelocityPath,
                operation: .set,
                persistence: .transaction,
                minimum: 0.001
            ),
            NeuralPathologyRuntimeBinding(
                channel: .extracellularGlutamate,
                path: "field.channel.2",
                operation: .clampMinimum,
                persistence: .persistent,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .inflammatorySignal,
                path: "field.channel.10",
                operation: .clampMinimum,
                persistence: .persistent,
                minimum: 0
            ),
            NeuralPathologyRuntimeBinding(
                channel: .cellDamage,
                path: "cell.damage",
                operation: .clampMinimum,
                persistence: .persistent,
                minimum: 0,
                maximum: 1
            ),
            NeuralPathologyRuntimeBinding(
                channel: .apoptosisHazard,
                path: apoptosisHazardPath,
                operation: .set,
                persistence: .transaction,
                minimum: 0
            )
        ])
    }
}

public struct NeuralPathologyRegion: Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var selector: TissueSelection
    public var parameters: NeuralPathologyParameters
    public var initialState: NeuralPathologyState
    public var layout: NeuralPathologyRuntimeLayout
    public var enabled: Bool
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        selector: TissueSelection,
        parameters: NeuralPathologyParameters = NeuralPathologyParameters(),
        initialState: NeuralPathologyState = NeuralPathologyState(),
        layout: NeuralPathologyRuntimeLayout = .standard(),
        enabled: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.selector = selector
        self.parameters = parameters
        self.initialState = initialState
        self.layout = layout
        self.enabled = enabled
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard !name.isEmpty else { throw NeuralPathologyRuntimeError.invalidRegion(id) }
        _ = try selector.validated()
        _ = try parameters.validated()
        _ = try initialState.validated()
        _ = try layout.validated()
        return self
    }
}

public struct NeuralPathologyRegionSnapshot: Sendable, Hashable, Codable {
    public var regionID: UUID
    public var tick: UInt64
    public var state: NeuralPathologyState
    public var activeKinds: Set<NeuralPathologyKind>
    public var instantaneousHazardPerSecond: Double

    public init(
        regionID: UUID,
        tick: UInt64,
        state: NeuralPathologyState,
        activeKinds: Set<NeuralPathologyKind>,
        instantaneousHazardPerSecond: Double
    ) {
        self.regionID = regionID
        self.tick = tick
        self.state = state
        self.activeKinds = activeKinds
        self.instantaneousHazardPerSecond = instantaneousHazardPerSecond
    }
}

public struct NeuralPathologyAdvance: Sendable, Hashable, Codable {
    public var frame: TissueInterventionFrame
    public var snapshots: [NeuralPathologyRegionSnapshot]

    public init(
        frame: TissueInterventionFrame,
        snapshots: [NeuralPathologyRegionSnapshot]
    ) {
        self.frame = frame
        self.snapshots = snapshots
    }
}

public actor NeuralPathologyController {
    public let regions: [NeuralPathologyRegion]
    private var states: [UUID: NeuralPathologyState]
    private var lastTick: UInt64?

    public init(regions sourceRegions: [NeuralPathologyRegion]) throws {
        guard !sourceRegions.isEmpty,
              Set(sourceRegions.map(\.id)).count == sourceRegions.count else {
            throw NeuralPathologyRuntimeError.invalidController
        }
        let regions = try sourceRegions.map { try $0.validated() }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        self.regions = regions
        states = Dictionary(
            uniqueKeysWithValues: regions.map { ($0.id, $0.initialState) }
        )
    }

    public func advance(
        to tick: UInt64,
        drivers: [UUID: NeuralPathologyDrivers]
    ) throws -> NeuralPathologyAdvance {
        if let lastTick, tick < lastTick {
            throw NeuralPathologyRuntimeError.nonMonotonicTick
        }
        let previousTick = lastTick ?? tick
        let dtTicks = tick - previousTick
        let dtSeconds = Double(dtTicks) * 25e-6
        var mutations: [RuntimeParameterMutation] = []
        var activeIDs: [UUID] = []
        var snapshots: [NeuralPathologyRegionSnapshot] = []

        for region in regions where region.enabled {
            guard let current = states[region.id] else {
                throw NeuralPathologyRuntimeError.missingState(region.id)
            }
            let driver = drivers[region.id] ?? NeuralPathologyDrivers()
            let result = try NeuralPathologySolver.advance(
                state: current,
                drivers: driver,
                parameters: region.parameters,
                dtSeconds: dtSeconds
            )
            states[region.id] = result.state
            activeIDs.append(region.id)
            let effectsByChannel = Dictionary(
                uniqueKeysWithValues: result.effects.map { ($0.channel, $0) }
            )
            for binding in region.layout.bindings {
                guard let effect = effectsByChannel[binding.channel] else { continue }
                mutations.append(try binding.lower(
                    effect: effect,
                    selector: region.selector,
                    source: "pathology.\(region.id.uuidString).\(binding.channel.rawValue)"
                ))
            }
            snapshots.append(NeuralPathologyRegionSnapshot(
                regionID: region.id,
                tick: tick,
                state: result.state,
                activeKinds: result.activeKinds,
                instantaneousHazardPerSecond: result.instantaneousHazardPerSecond
            ))
        }
        lastTick = tick
        return NeuralPathologyAdvance(
            frame: TissueInterventionFrame(
                tick: tick,
                activeInterventions: activeIDs,
                mutations: mutations,
                stimuli: []
            ),
            snapshots: snapshots
        )
    }

    public func snapshot() -> [UUID: NeuralPathologyState] { states }

    public func restore(
        states newStates: [UUID: NeuralPathologyState],
        at tick: UInt64
    ) throws {
        guard Set(newStates.keys) == Set(regions.map(\.id)) else {
            throw NeuralPathologyRuntimeError.invalidRestore
        }
        for value in newStates.values { _ = try value.validated() }
        states = newStates
        lastTick = tick
    }
}

public enum NeuralPathologyRuntimeError: Error, Sendable, CustomStringConvertible {
    case invalidBinding(String)
    case invalidLayout
    case invalidRegion(UUID)
    case invalidController
    case nonFiniteEffect(NeuralPathologyEffectChannel)
    case nonMonotonicTick
    case missingState(UUID)
    case invalidRestore

    public var description: String {
        switch self {
        case .invalidBinding(let path): return "Invalid neural pathology runtime binding \(path)"
        case .invalidLayout: return "Neural pathology runtime layout is invalid"
        case .invalidRegion(let id): return "Neural pathology region \(id) is invalid"
        case .invalidController: return "Neural pathology controller configuration is invalid"
        case .nonFiniteEffect(let channel): return "Neural pathology effect \(channel.rawValue) is non-finite"
        case .nonMonotonicTick: return "Neural pathology controller tick moved backward"
        case .missingState(let id): return "Neural pathology state is missing for region \(id)"
        case .invalidRestore: return "Neural pathology restore state does not match configured regions"
        }
    }
}
