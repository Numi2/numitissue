import Foundation
import NumiTissueCore
import NumiTissueRuntime

/// A validated, reusable topology schedule for correctness-first implicit cable solves.
/// Axial conductances remain runtime state and are re-read on every solve; only the rooted forest
/// and its elimination order are cached.
public struct ReferenceCableTreePlan: Sendable {
    public let compartmentCount: Int
    private let expectedParents: [UInt32]
    private let parent: [Int?]
    private let children: [[Int]]
    private let roots: [Int]
    private let descending: [Int]
    private let ascending: [Int]

    public init(compartments: [RuntimeCompartmentState]) throws {
        compartmentCount = compartments.count
        expectedParents = compartments.map(\.parentIndex)
        var parent = Array<Int?>(repeating: nil, count: compartments.count)
        var children = Array(repeating: [Int](), count: compartments.count)
        var roots: [Int] = []

        for index in compartments.indices {
            let raw = compartments[index].parentIndex
            if raw == RuntimeCompartmentState.invalidIndex {
                roots.append(index)
                continue
            }
            let parentIndex = Int(raw)
            guard parentIndex >= 0,
                  parentIndex < compartments.count,
                  parentIndex != index else {
                throw ReferenceCableTreeError.invalidParent(
                    compartment: index,
                    parent: parentIndex
                )
            }
            let axial = Double(compartments[index].axialConductanceMicrosiemens)
            guard axial.isFinite, axial >= 0 else {
                throw ReferenceCableTreeError.invalidAxialConductance(index)
            }
            parent[index] = parentIndex
            children[parentIndex].append(index)
        }
        guard compartments.isEmpty || !roots.isEmpty else {
            throw ReferenceCableTreeError.noRoot
        }

        var depth = Array(repeating: -1, count: compartments.count)
        for root in roots {
            try Self.assignDepth(
                root,
                value: 0,
                children: children,
                depth: &depth
            )
        }
        guard depth.allSatisfy({ $0 >= 0 }) else {
            throw ReferenceCableTreeError.disconnectedCycle
        }

        self.parent = parent
        self.children = children
        self.roots = roots.sorted()
        descending = compartments.indices.sorted {
            depth[$0] == depth[$1] ? $0 < $1 : depth[$0] > depth[$1]
        }
        ascending = compartments.indices.sorted {
            depth[$0] == depth[$1] ? $0 < $1 : depth[$0] < depth[$1]
        }
    }

    public func solve(
        state: inout TissueRuntimeState,
        dtMilliseconds: Float
    ) throws {
        guard dtMilliseconds.isFinite, dtMilliseconds > 0 else {
            throw ReferenceCableTreeError.invalidStep
        }
        guard state.compartments.count == compartmentCount else {
            throw ReferenceCableTreeError.topologyChanged
        }
        guard state.compartments.indices.allSatisfy({
            state.compartments[$0].parentIndex == expectedParents[$0]
        }) else {
            throw ReferenceCableTreeError.topologyChanged
        }
        guard compartmentCount > 0 else { return }

        let requiredMechanisms = compartmentCount * ReferenceCableTreeSolver.mechanismStride
        guard state.mechanismState.count >= requiredMechanisms else {
            throw ReferenceCableTreeError.insufficientMechanismState(
                required: requiredMechanisms,
                actual: state.mechanismState.count
            )
        }

        var parentAxial = Array(repeating: 0.0, count: compartmentCount)
        var incidentAxial = Array(repeating: 0.0, count: compartmentCount)
        for index in state.compartments.indices {
            let axial = parent[index] == nil
                ? 0
                : Double(state.compartments[index].axialConductanceMicrosiemens)
            guard axial.isFinite, axial >= 0 else {
                throw ReferenceCableTreeError.invalidAxialConductance(index)
            }
            parentAxial[index] = axial
            incidentAxial[index] += axial
            if let parent = parent[index] {
                incidentAxial[parent] += axial
            }
        }

        let dt = Double(dtMilliseconds)
        var diagonal = Array(repeating: 0.0, count: compartmentCount)
        var rhs = Array(repeating: 0.0, count: compartmentCount)
        var solution = Array(repeating: 0.0, count: compartmentCount)

        for index in state.compartments.indices {
            let compartment = state.compartments[index]
            let base = index * ReferenceCableTreeSolver.mechanismStride
            let capacitance = Double(compartment.capacitanceNanofarads)
            let membraneConductance = Double(state.mechanismState[base + 10])
            let source = Double(state.mechanismState[base + 11])
            let applied = Double(
                compartment.injectedCurrentNanoamps -
                compartment.synapticCurrentNanoamps
            )
            guard capacitance.isFinite,
                  capacitance > 0,
                  membraneConductance.isFinite,
                  membraneConductance >= 0,
                  source.isFinite,
                  applied.isFinite,
                  compartment.voltageMillivolts.isFinite else {
                throw ReferenceCableTreeError.invalidCompartment(index)
            }

            diagonal[index] = capacitance / dt +
                membraneConductance + incidentAxial[index]
            rhs[index] = capacitance / dt * Double(compartment.voltageMillivolts) +
                source + applied
            guard diagonal[index].isFinite,
                  diagonal[index] > 0,
                  rhs[index].isFinite else {
                throw ReferenceCableTreeError.nonPositiveDiagonal(index)
            }
        }

        for child in descending {
            guard let parent = parent[child] else { continue }
            let axial = parentAxial[child]
            let pivot = diagonal[child]
            guard pivot.isFinite, pivot > 0 else {
                throw ReferenceCableTreeError.nonPositivePivot(child)
            }
            diagonal[parent] -= axial * axial / pivot
            rhs[parent] += axial * rhs[child] / pivot
            guard diagonal[parent].isFinite,
                  diagonal[parent] > 0,
                  rhs[parent].isFinite else {
                throw ReferenceCableTreeError.nonPositivePivot(parent)
            }
        }

        for root in roots {
            solution[root] = rhs[root] / diagonal[root]
        }
        for child in ascending {
            guard let parent = parent[child] else { continue }
            solution[child] = (
                rhs[child] + parentAxial[child] * solution[parent]
            ) / diagonal[child]
        }

        guard solution.allSatisfy(\.isFinite) else {
            throw ReferenceCableTreeError.nonFiniteSolution
        }
        for index in state.compartments.indices {
            state.compartments[index].previousVoltageMillivolts =
                state.compartments[index].voltageMillivolts
            state.compartments[index].voltageMillivolts = Float(solution[index])
            let base = index * ReferenceCableTreeSolver.mechanismStride
            state.mechanismState[base + 12] = Float(diagonal[index])
            state.mechanismState[base + 13] = Float(rhs[index])
            state.mechanismState[base + 14] = Float(solution[index])
        }
    }

    private static func assignDepth(
        _ node: Int,
        value: Int,
        children: [[Int]],
        depth: inout [Int]
    ) throws {
        guard depth[node] == -1 else {
            throw ReferenceCableTreeError.disconnectedCycle
        }
        depth[node] = value
        for child in children[node] {
            try assignDepth(
                child,
                value: value + 1,
                children: children,
                depth: &depth
            )
        }
    }
}

/// Correctness-first implicit cable solver used by the scientific CPU backend.
///
/// Each parent diagonal receives the conductance of every incident child edge before tree
/// elimination. State is accumulated in Double and committed to the FP32 runtime representation
/// only after the complete forest has been solved.
public enum ReferenceCableTreeSolver {
    public static let mechanismStride = 16

    public static func solve(
        state: inout TissueRuntimeState,
        dtMilliseconds: Float
    ) throws {
        let plan = try ReferenceCableTreePlan(compartments: state.compartments)
        try plan.solve(state: &state, dtMilliseconds: dtMilliseconds)
    }
}

public enum ReferenceCableTreeError: Error, Sendable, CustomStringConvertible {
    case invalidStep
    case insufficientMechanismState(required: Int, actual: Int)
    case invalidCompartment(Int)
    case invalidParent(compartment: Int, parent: Int)
    case invalidAxialConductance(Int)
    case noRoot
    case disconnectedCycle
    case topologyChanged
    case nonPositiveDiagonal(Int)
    case nonPositivePivot(Int)
    case nonFiniteSolution

    public var description: String {
        switch self {
        case .invalidStep:
            return "Cable-solver step must be finite and positive."
        case .insufficientMechanismState(let required, let actual):
            return "Cable solver requires \(required) mechanism values; state contains \(actual)."
        case .invalidCompartment(let index):
            return "Cable compartment \(index) contains invalid numerical state."
        case .invalidParent(let compartment, let parent):
            return "Cable compartment \(compartment) has invalid parent \(parent)."
        case .invalidAxialConductance(let index):
            return "Cable compartment \(index) has invalid axial conductance."
        case .noRoot:
            return "Cable forest has no root compartment."
        case .disconnectedCycle:
            return "Cable topology contains a cycle or is disconnected from every root."
        case .topologyChanged:
            return "Cable topology changed after its reference plan was compiled."
        case .nonPositiveDiagonal(let index):
            return "Cable compartment \(index) has a non-positive assembled diagonal."
        case .nonPositivePivot(let index):
            return "Cable elimination produced a non-positive pivot at compartment \(index)."
        case .nonFiniteSolution:
            return "Cable solve produced a non-finite voltage."
        }
    }
}
