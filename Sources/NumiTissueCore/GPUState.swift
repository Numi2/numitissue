import Foundation

public enum FidelityLevel: UInt8, Codable, Sendable, CaseIterable {
    case fieldOnly = 0
    case cellAgent = 1
    case reducedNeuron = 2
    case detailedNeuron = 3
    case molecularDetail = 4
}

public enum CellKind: UInt16, Codable, Sendable, CaseIterable {
    case radialGlia = 0
    case intermediateProgenitor = 1
    case excitatoryNeuron = 2
    case inhibitoryInterneuron = 3
    case astrocyte = 4
    case oligodendrocytePrecursor = 5
    case oligodendrocyte = 6
    case microglia = 7
    case endothelial = 8
    case perivascular = 9
    case custom = 65_535
}

public enum DevelopmentalState: UInt16, Codable, Sendable, CaseIterable {
    case quiescent = 0
    case cyclingG1 = 1
    case cyclingS = 2
    case cyclingG2 = 3
    case mitosis = 4
    case differentiating = 5
    case migrating = 6
    case immature = 7
    case mature = 8
    case stressed = 9
    case apoptotic = 10
    case dead = 11
}

public enum SegmentKind: UInt16, Codable, Sendable, CaseIterable {
    case soma = 0
    case basalDendrite = 1
    case apicalDendrite = 2
    case axon = 3
    case axonInitialSegment = 4
    case growthCone = 5
    case spineNeck = 6
    case spineHead = 7
    case myelinatedAxon = 8
    case nodeOfRanvier = 9
}

public enum ReceptorKind: UInt8, Codable, Sendable, CaseIterable {
    case ampa = 0
    case nmda = 1
    case gabaA = 2
    case gabaB = 3
    case electrical = 4
    case modulatory = 5
}

public enum FieldChannel: UInt8, Codable, Sendable, CaseIterable {
    case extracellularPotassium = 0
    case extracellularCalcium = 1
    case glutamate = 2
    case oxygen = 3
    case glucose = 4
    case lactate = 5
    case pHWaste = 6
    case trophicSupport = 7
    case attractiveGuidance = 8
    case repulsiveGuidance = 9
    case inflammatoryDamage = 10
    case extracellularMatrix = 11
}

public struct TileFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let electricallyActive = Self(rawValue: 1 << 0)
    public static let fieldsActive = Self(rawValue: 1 << 1)
    public static let structuralActive = Self(rawValue: 1 << 2)
    public static let molecularActive = Self(rawValue: 1 << 3)
    public static let capacityLimited = Self(rawValue: 1 << 4)
    public static let requiresPromotion = Self(rawValue: 1 << 5)
    public static let requiresDemotion = Self(rawValue: 1 << 6)
}

/// GPU ABI. Every vector is 16-byte aligned in Swift and Metal.
@frozen
public struct GPUTileHeader: Sendable {
    public var coordinate: Int4
    public var counts0: UInt4       // cells, segments, compartments, synapses
    public var counts1: UInt4       // microdomains, routes, local events, remote events
    public var offsets0: UInt4      // cells, segments, compartments, synapses
    public var offsets1: UInt4      // fields, microdomains, routes, events
    public var activity: Float4     // electrical, structural, molecular, uncertainty
    public var epochs: UInt4        // topology, state, committed transaction low/high
    public var flags: UInt4         // flags, validation, overflow, reserved

    public init(coordinate: TileCoordinate) {
        self.coordinate = coordinate.packed
        self.counts0 = .zero
        self.counts1 = .zero
        self.offsets0 = .zero
        self.offsets1 = .zero
        self.activity = .zero
        self.epochs = .zero
        self.flags = .zero
    }
}

@frozen
public struct GPUCellState: Sendable {
    public var positionRadius: Float4
    public var orientation: Float4
    public var shapeVolume: Float4
    public var velocityMotility: Float4
    public var metabolism: Float4       // ATP, oxygen stress, glucose stress, damage
    public var development: Float4      // age, cycle progress, differentiation, apoptosis
    public var regulatory0: Float4
    public var regulatory1: Float4
    public var regulatory2: Float4
    public var regulatory3: Float4
    public var regulatory4: Float4
    public var regulatory5: Float4
    public var regulatory6: Float4
    public var regulatory7: Float4
    public var identity0: UInt4         // cell id low/high, lineage low/high
    public var identity1: UInt4         // kind, developmental state, fidelity, flags

    public init(id: CellID, lineage: LineageID, kind: CellKind, position: Float4, radius: Float, fidelity: FidelityLevel) {
        self.positionRadius = Float4(position.x, position.y, position.z, radius)
        self.orientation = Float4(0, 0, 0, 1)
        self.shapeVolume = Float4(radius, radius, radius, 4.0 / 3.0 * .pi * radius * radius * radius)
        self.velocityMotility = .zero
        self.metabolism = Float4(1, 0, 0, 0)
        self.development = .zero
        self.regulatory0 = .zero; self.regulatory1 = .zero
        self.regulatory2 = .zero; self.regulatory3 = .zero
        self.regulatory4 = .zero; self.regulatory5 = .zero
        self.regulatory6 = .zero; self.regulatory7 = .zero
        self.identity0 = UInt4(
            UInt32(truncatingIfNeeded: id.rawValue), UInt32(truncatingIfNeeded: id.rawValue >> 32),
            UInt32(truncatingIfNeeded: lineage.rawValue), UInt32(truncatingIfNeeded: lineage.rawValue >> 32)
        )
        self.identity1 = UInt4(UInt32(kind.rawValue), UInt32(DevelopmentalState.immature.rawValue), UInt32(fidelity.rawValue), 0)
    }
}

@frozen
public struct GPUNeuriteSegment: Sendable {
    public var startRadius: Float4
    public var endRadius: Float4
    public var electrical: Float4       // axial conductance, capacitance, myelin, energy
    public var topology: UInt4          // parent, first child, child count, compartment
    public var identity: UInt4          // segment id low/high, cell local index, kind/flags

    public init(start: Float4, end: Float4, radius: Float, parent: UInt32, cellIndex: UInt32, kind: SegmentKind) {
        self.startRadius = Float4(start.x, start.y, start.z, radius)
        self.endRadius = Float4(end.x, end.y, end.z, radius)
        self.electrical = .zero
        self.topology = UInt4(parent, UInt32.max, 0, UInt32.max)
        self.identity = UInt4(0, 0, cellIndex, UInt32(kind.rawValue))
    }
}

@frozen
public struct GPUCompartmentState: Sendable {
    public var voltageAndCurrent: Float4    // V, injected I, synaptic I, calcium
    public var passive: Float4              // capacitance, leak g, leak E, axial-to-parent
    public var gates0: Float4               // m, h, n, p
    public var gates1: Float4               // q, r, s, auxiliary
    public var linearSystem: Float4         // diagonal, rhs, parent coefficient, solution
    public var topology: UInt4              // parent, first child, child count, level
    public var mechanism: UInt4             // mechanism table, segment, neuron, flags

    public init(voltageMillivolts: Float = -65) {
        self.voltageAndCurrent = Float4(voltageMillivolts, 0, 0, 5e-5)
        self.passive = Float4(1, 0.1, -65, 0)
        self.gates0 = Float4(0.05, 0.6, 0.32, 0)
        self.gates1 = .zero
        self.linearSystem = .zero
        self.topology = UInt4(UInt32.max, UInt32.max, 0, 0)
        self.mechanism = .zero
    }
}

@frozen
public struct GPUSynapseState: Sendable {
    public var routing: UInt4          // post compartment, presyn route, last event tick, type/flags
    public var kinetics: Float4        // g, decay factor, reversal, weight
    public var plasticity0: Float4     // u, x, eligibility, consolidation
    public var plasticity1: Float4     // pre trace, post trace, structural score, homeostatic scale

    public init(postCompartment: UInt32, route: UInt32, receptor: ReceptorKind, weight: Float) {
        self.routing = UInt4(postCompartment, route, 0, UInt32(receptor.rawValue))
        self.kinetics = Float4(0, 1, 0, weight)
        self.plasticity0 = Float4(0.2, 1, 0, 0)
        self.plasticity1 = Float4(0, 0, 1, 1)
    }
}

@frozen
public struct GPUFieldVoxel: Sendable {
    public var channels0: Float4
    public var channels1: Float4
    public var channels2: Float4

    public init(baseline: Bool = true) {
        if baseline {
            self.channels0 = Float4(3.5, 1.2, 0, 0.2)
            self.channels1 = Float4(1, 0, 0, 1)
            self.channels2 = Float4(0, 0, 0, 1)
        } else {
            self.channels0 = .zero; self.channels1 = .zero; self.channels2 = .zero
        }
    }

    public subscript(_ channel: FieldChannel) -> Float {
        get {
            let index = Int(channel.rawValue)
            if index < 4 { return channels0[index] }
            if index < 8 { return channels1[index - 4] }
            return channels2[index - 8]
        }
        set {
            let index = Int(channel.rawValue)
            if index < 4 { channels0[index] = newValue }
            else if index < 8 { channels1[index - 4] = newValue }
            else { channels2[index - 8] = newValue }
        }
    }
}

@frozen
public struct GPUEvent: Sendable {
    public var address: UInt4          // destination, source, tick, type/flags
    public var payload: Float4         // amplitude and optional data

    public init(destination: UInt32, source: UInt32, tick: UInt32, type: UInt16, amplitude: Float) {
        self.address = UInt4(destination, source, tick, UInt32(type))
        self.payload = Float4(amplitude, 0, 0, 0)
    }
}

@frozen
public struct GPUMicrodomainHeader: Sendable {
    public var countsAndOffsets0: UInt4 // species count, reaction count, species offset, reaction offset
    public var countsAndOffsets1: UInt4 // voxel count, diffusion edge count, edge offset, flags
    public var coupling: UInt4          // cell, compartment, field voxel, solver mode
    public var timeAndError: Float4     // local time, dt, error, propensity sum

    public init() {
        self.countsAndOffsets0 = .zero
        self.countsAndOffsets1 = .zero
        self.coupling = UInt4(UInt32.max, UInt32.max, UInt32.max, 0)
        self.timeAndError = .zero
    }
}

@frozen
public struct GPUMolecularReaction: Sendable {
    public var reactants: UInt4
    public var products: UInt4
    public var stoichiometry: Float4
    public var kinetics: Float4

    public init() {
        self.reactants = UInt4(repeating: UInt32.max)
        self.products = UInt4(repeating: UInt32.max)
        self.stoichiometry = .zero
        self.kinetics = .zero
    }
}

@frozen
public struct GPULongRangeRoute: Sendable {
    public var addressing: UInt4
    public var timing: Float4

    public init(
        source: UInt32,
        destinationStart: UInt32,
        destinationCount: UInt32,
        delayTicks: UInt32,
        releaseProbability: Float = 1
    ) {
        self.addressing = UInt4(source, destinationStart, destinationCount, delayTicks)
        self.timing = Float4(releaseProbability, 0, 0, 0)
    }
}
