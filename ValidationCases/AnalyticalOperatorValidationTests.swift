import Foundation
import XCTest
@testable import NumiTissueReference
import NumiTissueCore
import NumiTissueRuntime

final class AnalyticalOperatorValidationTests: XCTestCase {
    func testPassiveRCBackwardEulerMatchesReferenceKernel() throws {
        let parameters = PassiveRCParameters(
            capacitanceNanofarads: 1,
            leakConductanceMicrosiemens: 0.1,
            leakReversalMillivolts: -65,
            injectedCurrentNanoamps: 1,
            initialVoltageMillivolts: -75
        )
        let step = 0.025
        let duration = 100.0
        let reference = try NumiTissueAnalyticalReferences.passiveRCBackwardEuler(
            parameters: parameters,
            durationMilliseconds: duration,
            stepMilliseconds: step
        )

        var state = makeState(compartmentCount: 1)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 1),
                neuronIndex: 0,
                voltageMillivolts: -75,
                previousVoltageMillivolts: -75,
                capacitanceNanofarads: 1,
                injectedCurrentNanoamps: 1
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 16)
        state.mechanismState[10] = 0.1
        state.mechanismState[11] = -6.5

        var candidate = [-75.0]
        candidate.reserveCapacity(reference.values.count)
        for _ in 1..<reference.values.count {
            try ReferenceCableTreeSolver.solve(
                state: &state,
                dtMilliseconds: Float(step)
            )
            candidate.append(Double(state.compartments[0].voltageMillivolts))
        }

        let result = try ScientificTraceComparator.compare(
            reference: ValidationSeries(
                name: "passive-rc-reference",
                unit: "mV",
                times: reference.times,
                values: reference.values
            ),
            candidate: ValidationSeries(
                name: "passive-rc-cpu",
                unit: "mV",
                times: reference.times,
                values: candidate
            ),
            tolerance: ValidationTolerance(
                absolute: 0.003,
                relative: 0.0001,
                rootMeanSquare: 0.001
            )
        )
        XCTAssertTrue(result.passed, result.failureReasons.joined(separator: "; "))
        XCTAssertEqual(candidate.last!, parameters.steadyStateMillivolts, accuracy: 0.005)
    }

    func testTwoCompartmentCableMatchesDirectMatrixSolution() throws {
        let dtMilliseconds = 0.1
        let rootCapacitance = 1.0
        let childCapacitance = 2.0
        let rootLeak = 0.1
        let childLeak = 0.2
        let axial = 0.4
        let rootSource = -6.5
        let childSource = -12.0
        let rootCurrent = 0.5
        let childCurrent = -0.2
        let rootInitial = -70.0
        let childInitial = -50.0

        let rootDiagonal = rootCapacitance / dtMilliseconds + rootLeak + axial
        let childDiagonal = childCapacitance / dtMilliseconds + childLeak + axial
        let rootRHS = rootCapacitance / dtMilliseconds * rootInitial + rootSource + rootCurrent
        let childRHS = childCapacitance / dtMilliseconds * childInitial + childSource + childCurrent
        let expected = try NumiTissueAnalyticalReferences.solveSymmetricTwoCompartment(
            diagonal0: rootDiagonal,
            diagonal1: childDiagonal,
            axial: axial,
            rhs0: rootRHS,
            rhs1: childRHS
        )

        var state = makeState(compartmentCount: 2)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 10),
                neuronIndex: 0,
                voltageMillivolts: Float(rootInitial),
                previousVoltageMillivolts: Float(rootInitial),
                capacitanceNanofarads: Float(rootCapacitance),
                injectedCurrentNanoamps: Float(rootCurrent)
            ),
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 11),
                neuronIndex: 0,
                parentIndex: 0,
                voltageMillivolts: Float(childInitial),
                previousVoltageMillivolts: Float(childInitial),
                capacitanceNanofarads: Float(childCapacitance),
                axialConductanceMicrosiemens: Float(axial),
                injectedCurrentNanoamps: Float(childCurrent)
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 32)
        state.mechanismState[10] = Float(rootLeak)
        state.mechanismState[11] = Float(rootSource)
        state.mechanismState[26] = Float(childLeak)
        state.mechanismState[27] = Float(childSource)

        try ReferenceCableTreeSolver.solve(
            state: &state,
            dtMilliseconds: Float(dtMilliseconds)
        )

        XCTAssertEqual(Double(state.compartments[0].voltageMillivolts), expected.0, accuracy: 1e-5)
        XCTAssertEqual(Double(state.compartments[1].voltageMillivolts), expected.1, accuracy: 1e-5)
        XCTAssertEqual(state.compartments[0].previousVoltageMillivolts, Float(rootInitial))
        XCTAssertEqual(state.compartments[1].previousVoltageMillivolts, Float(childInitial))
    }

    func testCableForestRejectsTopologyWithoutRoot() {
        var state = makeState(compartmentCount: 2)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 12),
                neuronIndex: 0,
                parentIndex: 1,
                capacitanceNanofarads: 1,
                axialConductanceMicrosiemens: 0.1
            ),
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 13),
                neuronIndex: 0,
                parentIndex: 0,
                capacitanceNanofarads: 1,
                axialConductanceMicrosiemens: 0.1
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 32)

        XCTAssertThrowsError(
            try ReferenceCableTreeSolver.solve(state: &state, dtMilliseconds: 0.025)
        ) { error in
            guard case ReferenceCableTreeError.noRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHodgkinHuxleyRushLarsenGateUpdate() throws {
        let initial = HodgkinHuxleyGateState(m: 0.05, h: 0.60, n: 0.32)
        let expected = try NumiTissueAnalyticalReferences.hodgkinHuxleyRushLarsen(
            state: initial,
            voltageMillivolts: -65,
            stepMilliseconds: 0.025
        )

        var state = makeState(compartmentCount: 1)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 2),
                neuronIndex: 0,
                voltageMillivolts: -65,
                previousVoltageMillivolts: -65,
                capacitanceNanofarads: 1
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 16)
        state.mechanismState[0] = Float(initial.m)
        state.mechanismState[1] = Float(initial.h)
        state.mechanismState[2] = Float(initial.n)
        state.mechanismState[4] = 0.120
        state.mechanismState[5] = 0.036
        state.mechanismState[6] = 0.0003
        state.mechanismState[7] = 50
        state.mechanismState[8] = -77
        state.mechanismState[9] = -54.387

        CPUReferenceKernels.updateChannels(state: &state, dtMilliseconds: 0.025)

        XCTAssertEqual(Double(state.mechanismState[0]), expected.m, accuracy: 1e-7)
        XCTAssertEqual(Double(state.mechanismState[1]), expected.h, accuracy: 1e-7)
        XCTAssertEqual(Double(state.mechanismState[2]), expected.n, accuracy: 1e-7)
        XCTAssertGreaterThan(state.mechanismState[10], 0)
        XCTAssertTrue(state.mechanismState[11].isFinite)
    }

    func testSpikeTimestampUsesThresholdInterpolationAndRefractoryState() {
        var state = makeState(compartmentCount: 1)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 3),
                neuronIndex: 0,
                voltageMillivolts: 10,
                previousVoltageMillivolts: -30,
                capacitanceNanofarads: 1
            )
        ]
        state.mechanismState = Array(repeating: 0, count: 16)

        let first = CPUReferenceKernels.detectSpikes(
            state: &state,
            tickRange: 100..<110
        )
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].arrivalTick, 102)
        XCTAssertEqual(state.compartments[0].refractoryUntilTick, 182)

        let second = CPUReferenceKernels.detectSpikes(
            state: &state,
            tickRange: 110..<120
        )
        XCTAssertTrue(second.isEmpty)
    }

    func testTwoCompartmentAnalyticalSolverRejectsSingularity() {
        XCTAssertThrowsError(
            try NumiTissueAnalyticalReferences.solveSymmetricTwoCompartment(
                diagonal0: 1,
                diagonal1: 1,
                axial: 1,
                rhs0: 0,
                rhs1: 0
            )
        )
    }

    private func makeState(compartmentCount: Int) -> TissueRuntimeState {
        TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 0,
                cells: 0,
                segments: 0,
                compartments: compartmentCount,
                synapses: 0,
                events: 65_536,
                fieldValues: 0,
                microdomains: 0,
                molecularSpecies: 0
            )
        )
    }
}
