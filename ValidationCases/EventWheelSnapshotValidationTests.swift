import Foundation
import XCTest
import NumiTissueRuntime

final class EventWheelSnapshotValidationTests: XCTestCase {
    func testSnapshotRoundTripPreservesPendingOrderAndSequence() throws {
        var wheel = EventDelayWheel(
            originTick: 100,
            bucketCount: 16,
            bucketWidthTicks: 10,
            capacity: 8
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 125,
                source: 9,
                destination: 2,
                amplitude: 0.5,
                kind: .spike
            )
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 125,
                source: 8,
                destination: 2,
                amplitude: 0.75,
                kind: .spike
            )
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 121,
                source: 7,
                destination: 1,
                amplitude: 1,
                kind: .neuromodulatorPulse
            )
        )

        let snapshot = try wheel.snapshot().validated()
        let restored = try EventDelayWheel(snapshot: snapshot)
        XCTAssertEqual(try restored.snapshot().validated(), snapshot)
        XCTAssertEqual(snapshot.events.map(\.arrivalTick), [121, 125, 125])
        XCTAssertEqual(snapshot.events.map(\.source), [7, 8, 9])
        XCTAssertEqual(Set(snapshot.events.map(\.sequence)).count, 3)
    }

    func testFailedBatchSchedulingRestoresCountEventsAndSequenceCursor() throws {
        var wheel = EventDelayWheel(
            originTick: 100,
            bucketCount: 4,
            bucketWidthTicks: 10,
            capacity: 8
        )
        let before = wheel.snapshot()
        let batch = [
            RoutedEvent(
                arrivalTick: 101,
                source: 1,
                destination: 1
            ),
            RoutedEvent(
                arrivalTick: 140,
                source: 2,
                destination: 2
            )
        ]

        XCTAssertThrowsError(try wheel.schedule(contentsOf: batch)) { error in
            guard case EventRoutingError.horizonExceeded = error else {
                return XCTFail("Unexpected batch failure: \(error)")
            }
        }
        XCTAssertEqual(wheel.snapshot(), before)

        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 102,
                source: 3,
                destination: 3
            )
        )
        XCTAssertEqual(wheel.snapshot().events[0].sequence, 0)
    }

    func testDropLowestAmplitudePreservesCapacityAndReplacesOnlyWhenStronger() throws {
        var wheel = EventDelayWheel(
            originTick: 0,
            bucketCount: 8,
            bucketWidthTicks: 10,
            capacity: 2,
            overflowPolicy: .dropLowestAmplitude
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 1,
                source: 1,
                destination: 1,
                amplitude: 0.25
            )
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 2,
                source: 2,
                destination: 2,
                amplitude: 0.5
            )
        )
        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 3,
                source: 3,
                destination: 3,
                amplitude: 0.1
            )
        )
        XCTAssertEqual(wheel.pendingEvents.map(\.source), [1, 2])

        try wheel.schedule(
            RoutedEvent(
                arrivalTick: 4,
                source: 4,
                destination: 4,
                amplitude: 1
            )
        )
        XCTAssertEqual(wheel.count, 2)
        XCTAssertEqual(wheel.pendingEvents.map(\.source), [2, 4])
    }

    func testSnapshotRejectsDuplicateActiveSequenceNumbers() {
        let snapshot = EventDelayWheelSnapshot(
            originTick: 0,
            bucketCount: 8,
            bucketWidthTicks: 10,
            capacity: 4,
            overflowPolicy: .rejectTransaction,
            nextSequence: 2,
            events: [
                RoutedEvent(
                    arrivalTick: 1,
                    source: 1,
                    destination: 1,
                    sequence: 1
                ),
                RoutedEvent(
                    arrivalTick: 2,
                    source: 2,
                    destination: 2,
                    sequence: 1
                )
            ]
        )
        XCTAssertThrowsError(try snapshot.validated()) { error in
            guard case EventRoutingError.invalidSnapshot = error else {
                return XCTFail("Unexpected snapshot error: \(error)")
            }
        }
    }
}
