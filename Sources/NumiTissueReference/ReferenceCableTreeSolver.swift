import Foundation
import NumiTissueCore
import NumiTissueRuntime

/// Correctness-first implicit cable solver used by the scientific CPU backend.
///
/// Each parent diagonal receives the conductance of every incident child edge before
/// tree elimination. State is accumulated in Double and committed to the FP32 runtime
/// representation only after the complete forest has been solved.
public enum ReferenceCableTreeSolver {
    public static let mechanismStride = 16

    public static func solve(
        state: inout TissueRuntimeState,
        dtMilliseconds: Float
    ) throws {
        guard dtMilliseconds.isFinite, dtMilliseconds > 0 else {
            throw ReferenceCableTreeError.invalidStep
        }
        let count = state.compartments.count
        guard count > 0 else { return }
        let requiredMechanisms = count * mechanismStride
        guard state.mechanismState.count >= requiredMechanisms else {
            throw ReferenceCableTreeError.insufficientMechanismState(
                required: requiredMechanisms,
                actual: state.mechanismState.count
            )
        }

        let topology = try topology(of: state.compartments)
        let dt = Double(dtMilliseconds)
        var diagonal = Array(repeating: 0.0, count: count)
        var rhs = Array(repeating: 0.0, count: count)
        var solution = Array(repeating: 0.0, count: count)

        for index in 0..<count {
            let compartment = state.compartments[index]
            let base = index * mechanismStride
            let capacitance = Double(compartment.capacitanceNanofarads)
            let membraneConductance = Double(state.mechanismState[base + 10])
            let source = Double(state.mechanismState[base + 11])
            let applied = Double(
                compartment.injectedCurrentNanoamps -
                compartment.synapticCurrentNanoamps
            )
            guard capacitance.isFinite, capacitance > 0,
                  membraneConductance.isFinite, membraneConductance >= 0,
                  source.isFinite, applied.isFinite,
                  compartment.voltageMillivolts.isFinite else {
                throw ReferenceCableTreeError.invalidCompartment(index)
            }

            var incidentAxial = topology.parentAxial[index]
            for child in topology.children[index] {
                incidentAxial += topology.parentAxial[child]
            }
            diagonal[index] = capacitance / dt + membraneConductance + incidentAxial
            rhs[index] = capacitance / dt * Double(compartment.voltageMillivolts) +
                source + applied
            guard diagonal[index].isFinite, diagonal[index] > 0, rhs[index].isFinite else {
                throw ReferenceCableTreeError.nonPositiveDiagonal(index)
            }
        }

        for child in topology.descending {
            guard let parent = topology.parent[child] else { continue }
            let axial = topology.parentAxial[child]
            let pivot = diagonal[child]
            guard pivot.isFinite, pivot > 0 else {
                throw ReferenceCableTreeError.nonPositivePivot(child)
            }
            diagonal[parent] -= axial * axial / pivot
            rhs[parent] += axial * rhs[child] / pivot
            guard diagonal[parent].isFinite, diagonal[parent] > 0, rhs[parent].isFinite else {
                throw ReferenceCableTreeError.nonPositivePivot(parent)
            }
        }

        for root in topology.roots {
            solution[root] = rhs[root] / diagonal[root]
        }
        for child in topology.ascending {
            guard let parent = topology.parent[child] else { continue }
            solution[child] = (
                rhs[child] + topology.parentAxial[child] * solution[parent]
            ) / diagonal[child]
        }

        guard solution.allSatisfy(\.isFinite) else {
            throw ReferenceCableTreeError.nonFiniteSolution
        }
        for index in 0..<count {
            state.compartments[index].previousVoltageMillivolts =
                state.compartments[index].voltageMillivolts
            state.compartments[index].voltageMillivolts = Float(solution[index])
            let base = index * mechanismStride
            state.mechanismState[base + 12] = Float(diagonal[index])
            state.mechanismState[base + 13] = Float(rhs[index])
            state.mechanismState[base + 14] = Float(solution[index])
        }
    }

    private struct Topology {
        var parent: [Int?]
        var parentAxial: [Double]
        var children: [[Int]]
        var roots: [Int]
        var descending: [Int]
        var ascending: [Int]
    }

    private static func topology(
        of compartments: [RuntimeCompartmentState]
    ) throws -> Topology {
        let count = compartments.count
        var parent = Array<Int?>(repeating: nil, count: count)
        var parentAxial = Array(repeating: 0.0, count: count)
        var children = Array(repeating: [Int](), count: count)
        var roots: [Int] = []

        for index in 0..<count {
            let raw = compartments[index].parentIndex
            if raw == RuntimeCompartmentState.invalidIndex {
                roots.append(index)
                continue
            }
            let parentIndex = Int(raw)
            guard parentIndex >= 0, parentIndex < count, parentIndex != index else {
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
            parentAxial[index] = axial
            children[parentIndex].append(index)
        }
        guard !roots.isEmpty else {
            throw ReferenceCableTreeError.noRoot
        }

        var depth = Array(repeating: -1, count: count)
        for root in roots {
            try assignDepth(root, value: 0, children: children, depth: &depth)
        }
        guard depth.allSatisfy({ $0 >= 0 }) else {
            throw ReferenceCableTreeError.disconnectedCycle
        }

        let descending = (0..<count).sorted {
            depth[$0] == depth[$1] ? $0 < $1 : depth[$0] > depth[$1]
        }
        let ascending = (0..<count).sorted {
            depth[$0] == depth[$1] ? $0 < $1 : depth[$0] < depth[$1]
        }
        return Topology(
            parent: parent,
            parentAxial: parentAxial,
            children: children,
            roots: roots.sorted(),
            descending: descending,
            ascending: ascending
        )
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
            try assignDepth(child, value: value + 1, children: children, depth: &depth)
        }
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
        case .nonPositiveDiagonal(let index):
            return "Cable compartment \(index) has a non-positive assembled diagonal."
        case .nonPositivePivot(let index):
            return "Cable elimination produced a non-positive pivot at compartment \(index)."
        case .nonFiniteSolution:
            return "Cable solve produced a non-finite voltage."
        }
    }
}
