import Foundation
import XCTest
@testable import NumiTissueReference
import NumiTissueCore
import NumiTissueRuntime

final class FieldAndEventValidationTests: XCTestCase {
    func testUniformFieldIsInvariantUnderDiffusion() {
        var state = makeFieldState(concentration: 2.5, diffusion: 0.01)
        CPUReferenceKernels.updateFields(state: &state, dtMilliseconds: 0.025)
        XCTAssertTrue(state.fields.allSatisfy {
            abs($0.concentration - 2.5) <= 1e-7 &&
            $0.source == 0 &&
            $0.concentration.isFinite
        })
    }

    func testFieldSourceSinkUpdateIsNonnegativeAndClearsSource() {
        var state = makeFieldState(concentration: 0, diffusion: 0)
        let center = fieldIndex(channel: 0, x: 16, y: 16, z: 16)
        state.fields[center] = RuntimeFieldValue(
            concentration: 0,
            source: 2,
            sink: 0,
            diffusionScale: 0
        )
        CPUReferenceKernels.updateFields(state: &state, dtMilliseconds: 0.025)
        XCTAssertEqual(state.fields[center].concentration, 0.05, accuracy: 1e-7)
        XCTAssertEqual(state.fields[center].source, 0)

        state.fields[center].sink = 10
        CPUReferenceKernels.updateFields(state: &state, dtMilliseconds: 0.025)
        XCTAssertEqual(state.fields[center].concentration, 0.0375, accuracy: 1e-7)
        XCTAssertGreaterThanOrEqual(state.fields[center].concentration, 0)
    }

    func testEventWheelOrdersByTimestampDestinationSourceAndKind() throws {
        var wheel = EventDelayWheel(
            originTick: 100,
            bucketCount: 8,
            bucketWidthTicks: 10,
            capacity: 4
        )
        try wheel.schedule(RoutedEvent(arrivalTick: 105, source: 2, destination: 9, kind: .spike))
        try wheel.schedule(RoutedEvent(arrivalTick: 105, source: 1, destination: 9, kind: .spike))
        try wheel.schedule(RoutedEvent(arrivalTick: 104, source: 8, destination: 1, kind: .spike))

        let delivered = try wheel.pop(through: 106)
        XCTAssertEqual(delivered.map(\.arrivalTick), [104, 105, 105])
        XCTAssertEqual(delivered.map(\.destination), [1, 9, 9])
        XCTAssertEqual(delivered.map(\.source), [8, 1, 2])
        XCTAssertEqual(wheel.count, 0)
        XCTAssertEqual(wheel.currentTick, 106)
    }

    func testEventWheelRejectsOverflowWithoutMutatingAcceptedEvents() throws {
        var wheel = EventDelayWheel(
            originTick: 0,
            bucketCount: 8,
            bucketWidthTicks: 10,
            capacity: 2,
            overflowPolicy: .rejectTransaction
        )
        try wheel.schedule(RoutedEvent(arrivalTick: 1, source: 1, destination: 1))
        try wheel.schedule(RoutedEvent(arrivalTick: 2, source: 2, destination: 2))

        XCTAssertThrowsError(
            try wheel.schedule(RoutedEvent(arrivalTick: 3, source: 3, destination: 3))
        ) { error in
            guard case EventRoutingError.capacityExceeded(let capacity) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(capacity, 2)
        }

        XCTAssertEqual(wheel.count, 2)
        let delivered = try wheel.pop(through: 4)
        XCTAssertEqual(delivered.map(\.source), [1, 2])
    }

    func testEventWheelRejectsPastAndOutOfHorizonEvents() {
        var wheel = EventDelayWheel(
            originTick: 100,
            bucketCount: 4,
            bucketWidthTicks: 10,
            capacity: 8
        )
        XCTAssertThrowsError(
            try wheel.schedule(RoutedEvent(arrivalTick: 99, source: 1, destination: 1))
        ) { error in
            guard case EventRoutingError.eventInPast = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try wheel.schedule(RoutedEvent(arrivalTick: 140, source: 1, destination: 1))
        ) { error in
            guard case EventRoutingError.horizonExceeded = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(wheel.count, 0)
    }

    func testRouteTableIsDeterministicAtZeroLoss() throws {
        let routes = [
            LongRangeRoute(
                id: RouteID(rawValue: 1),
                source: 42,
                destination: 100,
                delayTicks: 4,
                gain: 0.5,
                destinationTileIndex: 0
            ),
            LongRangeRoute(
                id: RouteID(rawValue: 2),
                source: 42,
                destination: 101,
                delayTicks: 7,
                gain: 2,
                destinationTileIndex: 1
            )
        ]
        let table = try EventRouteTable(
            fanouts: [
                RouteFanout(
                    source: 42,
                    routeRange: RuntimeRange(lowerBound: 0, count: 2)
                )
            ],
            routes: routes
        )
        let source = RoutedEvent(
            arrivalTick: 10,
            source: 42,
            destination: 42,
            amplitude: 3,
            kind: .spike,
            sequence: 5
        )

        let first = table.route(
            sourceEvent: source,
            transaction: TransactionID(rawValue: 9),
            randomSeed: 123
        )
        let second = table.route(
            sourceEvent: source,
            transaction: TransactionID(rawValue: 9),
            randomSeed: 123
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.arrivalTick), [14, 17])
        XCTAssertEqual(first.map(\.destination), [100, 101])
        XCTAssertEqual(first.map(\.amplitude), [1.5, 6])
    }

    private func makeFieldState(
        concentration: Float,
        diffusion: Float
    ) -> TissueRuntimeState {
        let voxelCount = 32 * 32 * 32
        let fieldCount = voxelCount * 12
        var state = TissueRuntimeState(
            capacity: RuntimeCapacity(
                tiles: 1,
                cells: 0,
                segments: 0,
                compartments: 0,
                synapses: 0,
                events: 65_536,
                fieldValues: fieldCount,
                microdomains: 0,
                molecularSpecies: 0
            )
        )
        var tile = TileRuntimeState(
            id: TileID(rawValue: 1),
            coordinate: TileCoordinate(x: 0, y: 0, z: 0)
        )
        tile.fieldRange = RuntimeRange(lowerBound: 0, count: UInt32(fieldCount))
        state.tiles = [tile]
        state.fields = Array(
            repeating: RuntimeFieldValue(
                concentration: concentration,
                source: 0,
                sink: 0,
                diffusionScale: diffusion
            ),
            count: fieldCount
        )
        return state
    }

    private func fieldIndex(channel: Int, x: Int, y: Int, z: Int) -> Int {
        let voxelCount = 32 * 32 * 32
        return channel * voxelCount + x + 32 * (y + 32 * z)
    }
}
