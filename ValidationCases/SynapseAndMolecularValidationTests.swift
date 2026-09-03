import Foundation
import XCTest
@testable import NumiTissueReference
import NumiTissueCore
import NumiTissueRuntime

final class SynapseAndMolecularValidationTests: XCTestCase {
    func testExponentialSynapticConductanceDecay() throws {
        var state = makeState(compartments: 1, synapses: 1)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 10),
                neuronIndex: 0,
                voltageMillivolts: -65,
                previousVoltageMillivolts: -65,
                capacitanceNanofarads: 1
            )
        ]
        state.synapses = [
            RuntimeSynapseState(
                id: SynapseID(rawValue: 20),
                sourceRouteIndex: 0,
                targetCompartmentIndex: 0,
                parameterIndex: 0,
                delayTicks: 1,
                weight: 1,
                conductance: 1
            )
        ]

        let step = 0.025
        let duration = 20.0
        let reference = try NumiTissueAnalyticalReferences.exponentialConductance(
            initial: 1,
            tauMilliseconds: 5,
            durationMilliseconds: duration,
            stepMilliseconds: step
        )
        var candidate = [1.0]
        candidate.reserveCapacity(reference.values.count)
        for _ in 1..<reference.values.count {
            CPUReferenceKernels.decaySynapses(
                state: &state,
                dtMilliseconds: Float(step)
            )
            candidate.append(Double(state.synapses[0].conductance))
        }

        let result = try ScientificTraceComparator.compare(
            reference: ValidationSeries(
                name: "exponential-synapse-reference",
                unit: "uS",
                times: reference.times,
                values: reference.values
            ),
            candidate: ValidationSeries(
                name: "exponential-synapse-cpu",
                unit: "uS",
                times: reference.times,
                values: candidate
            ),
            tolerance: ValidationTolerance(
                absolute: 2e-6,
                relative: 2e-5,
                rootMeanSquare: 1e-6
            )
        )
        XCTAssertTrue(result.passed, result.failureReasons.joined(separator: "; "))
    }

    func testShortTermDepressionConsumesAvailableResources() {
        var state = makeState(compartments: 1, synapses: 1)
        state.synapses = [
            RuntimeSynapseState(
                id: SynapseID(rawValue: 21),
                sourceRouteIndex: 0,
                targetCompartmentIndex: 0,
                parameterIndex: 0,
                delayTicks: 0,
                weight: 5,
                shortTermUtilization: 0.2,
                shortTermResources: 1
            )
        ]
        let event = RoutedEvent(
            arrivalTick: 100,
            source: 1,
            destination: 0,
            amplitude: 1,
            kind: .spike
        )

        CPUReferenceKernels.deliver(events: [event], state: &state)
        XCTAssertEqual(state.synapses[0].conductance, 1, accuracy: 1e-7)
        XCTAssertEqual(state.synapses[0].shortTermResources, 0.8, accuracy: 1e-7)

        CPUReferenceKernels.deliver(events: [event], state: &state)
        XCTAssertEqual(state.synapses[0].conductance, 1.8, accuracy: 1e-6)
        XCTAssertEqual(state.synapses[0].shortTermResources, 0.64, accuracy: 1e-6)
        XCTAssertEqual(state.synapses[0].preTrace, 2, accuracy: 1e-7)
        XCTAssertEqual(state.synapses[0].eligibility, 2, accuracy: 1e-7)
    }

    func testInhibitoryCurrentHasHyperpolarizingSignAboveReversal() {
        var state = makeState(compartments: 1, synapses: 1)
        state.compartments = [
            RuntimeCompartmentState(
                id: CompartmentID(rawValue: 11),
                neuronIndex: 0,
                voltageMillivolts: -60,
                previousVoltageMillivolts: -60,
                capacitanceNanofarads: 1
            )
        ]
        state.synapses = [
            RuntimeSynapseState(
                id: SynapseID(rawValue: 22),
                sourceRouteIndex: 0,
                targetCompartmentIndex: 0,
                parameterIndex: 0,
                flags: 1,
                delayTicks: 0,
                weight: 1,
                conductance: 1
            )
        ]

        CPUReferenceKernels.decaySynapses(state: &state, dtMilliseconds: 0)
        XCTAssertEqual(
            state.compartments[0].synapticCurrentNanoamps,
            10,
            accuracy: 1e-6
        )
    }

    func testNeuromodulatedEligibilityUpdatesWeightAndConsolidation() {
        var state = makeState(compartments: 0, synapses: 1)
        state.synapses = [
            RuntimeSynapseState(
                id: SynapseID(rawValue: 23),
                sourceRouteIndex: 0,
                targetCompartmentIndex: 0,
                parameterIndex: 0,
                delayTicks: 0,
                weight: 0.5,
                eligibility: 2,
                consolidation: 0
            )
        ]

        CPUReferenceKernels.applyPlasticity(
            state: &state,
            modulators: SIMD8<Float>(1, 0, 0, 0, 0, 0, 0, 0),
            dtSeconds: 10
        )

        XCTAssertEqual(state.synapses[0].weight, 0.504, accuracy: 1e-6)
        XCTAssertEqual(state.synapses[0].consolidation, 0.0199, accuracy: 1e-6)
    }

    func testDeterministicFirstOrderMolecularDecay() throws {
        let stepSeconds = 0.001
        let durationSeconds = 2.0
        let steps = Int(durationSeconds / stepSeconds)
        let program = CPUReferenceMolecularProgram(networks: [
            CPUReferenceMolecularNetwork(
                speciesCount: 1,
                reactions: [
                    CPUReferenceMolecularReaction(
                        reactants: [CPUReferenceStoichiometryTerm(species: 0)],
                        products: [],
                        rateConstant: 0.5
                    )
                ]
            )
        ])
        var state = makeMolecularState(amounts: [100], solverKind: 2)

        var candidate = [100.0]
        candidate.reserveCapacity(steps + 1)
        for index in 0..<steps {
            _ = CPUReferenceMolecularSolver.step(
                state: &state,
                program: program,
                tickRange: UInt64(index * 40)..<UInt64((index + 1) * 40),
                transaction: TransactionID(rawValue: UInt64(index + 1)),
                seed: 0x4E_55_4D_49
            )
            candidate.append(Double(state.molecularSpecies[0]))
        }

        let reference = try NumiTissueAnalyticalReferences.firstOrderDecayForwardEuler(
            initialAmount: 100,
            ratePerSecond: 0.5,
            durationSeconds: durationSeconds,
            stepSeconds: stepSeconds
        )
        let result = try ScientificTraceComparator.compare(
            reference: ValidationSeries(
                name: "first-order-euler-reference",
                unit: "molecule-equivalent",
                times: reference.times,
                values: reference.values
            ),
            candidate: ValidationSeries(
                name: "first-order-euler-cpu",
                unit: "molecule-equivalent",
                times: reference.times,
                values: candidate
            ),
            tolerance: ValidationTolerance(
                absolute: 0.003,
                relative: 0.0001,
                rootMeanSquare: 0.0015
            )
        )
        XCTAssertTrue(result.passed, result.failureReasons.joined(separator: "; "))
        XCTAssertGreaterThanOrEqual(candidate.min()!, 0)
    }

    func testReversibleReactionConservesTotalAmount() {
        let program = CPUReferenceMolecularProgram(networks: [
            CPUReferenceMolecularNetwork(
                speciesCount: 2,
                reactions: [
                    CPUReferenceMolecularReaction(
                        reactants: [CPUReferenceStoichiometryTerm(species: 0)],
                        products: [CPUReferenceStoichiometryTerm(species: 1)],
                        rateConstant: 0.2
                    ),
                    CPUReferenceMolecularReaction(
                        reactants: [CPUReferenceStoichiometryTerm(species: 1)],
                        products: [CPUReferenceStoichiometryTerm(species: 0)],
                        rateConstant: 0.1
                    )
                ]
            )
        ])
        var state = makeMolecularState(amounts: [80, 20], solverKind: 2)
        let initialTotal = state.molecularSpecies.reduce(0, +)

        for index in 0..<1_000 {
            _ = CPUReferenceMolecularSolver.step(
                state: &state,
                program: program,
                tickRange: UInt64(index * 40)..<UInt64((index + 1) * 40),
                transaction: TransactionID(rawValue: UInt64(index + 1)),
                seed: 1
            )
        }

        let finalTotal = state.molecularSpecies.reduce(0, +)
        XCTAssertEqual(finalTotal, initialTotal, accuracy: 2e-4)
        XCTAssertTrue(state.molecularSpecies.allSatisfy { $0 >= 0 && $0.isFinite })
    }

    private func makeState(compartments: Int, synapses: Int) -> TissueRuntimeState {
        TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 0,
                cells: 0,
                segments: 0,
                compartments: compartments,
                synapses: synapses,
                events: 65_536,
                fieldValues: 0,
                microdomains: 0,
                molecularSpecies: 0
            )
        )
    }

    private func makeMolecularState(
        amounts: [Float],
        solverKind: UInt8
    ) -> TissueRuntimeState {
        var state = TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 0,
                cells: 0,
                segments: 0,
                compartments: 0,
                synapses: 0,
                events: 65_536,
                fieldValues: 0,
                microdomains: 1,
                molecularSpecies: amounts.count
            )
        )
        state.microdomains = [
            RuntimeMicrodomainState(
                id: MicrodomainID(rawValue: 30),
                ownerCellIndex: 0,
                reactionNetworkIndex: 0,
                solverKind: solverKind,
                speciesRange: RuntimeRange(
                    lowerBound: 0,
                    count: UInt32(amounts.count)
                ),
                volumeFemtoliters: 1
            )
        ]
        state.molecularSpecies = amounts
        return state
    }
}
