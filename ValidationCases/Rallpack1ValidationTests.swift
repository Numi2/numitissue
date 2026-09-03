import Foundation
import XCTest
@testable import NumiTissueReference

final class Rallpack1ValidationTests: XCTestCase {
    func testAnalyticalReferenceEndpointMatchesPinnedNSuiteGenerator() throws {
        var configuration = Rallpack1Configuration()
        configuration.sampleMilliseconds = 250
        let trace = try Rallpack1.analyticalTrace(configuration: configuration)

        XCTAssertEqual(trace.timeMilliseconds, [0, 250])
        XCTAssertEqual(
            trace.proximalVoltageMillivolts.last!,
            101.935051858483,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            trace.distalVoltageMillivolts.last!,
            43.09646796607879,
            accuracy: 1e-9
        )
    }

    func testRallpackDiscretizationHasExpectedSIConversions() throws {
        var configuration = Rallpack1Configuration()
        configuration.compartmentCount = 1_000
        let state = try Rallpack1.makeRuntimeState(configuration: configuration)
        let first = state.compartments[0]
        let second = state.compartments[1]

        XCTAssertEqual(first.capacitanceNanofarads, Float.pi * 1e-5, accuracy: 1e-10)
        XCTAssertEqual(state.mechanismState[10], Float.pi * 2.5e-7, accuracy: 1e-12)
        XCTAssertEqual(second.axialConductanceMicrosiemens, Float.pi * 0.25, accuracy: 1e-7)
        XCTAssertEqual(first.injectedCurrentNanoamps, 0.1, accuracy: 1e-7)
        XCTAssertEqual(state.compartments.count, 1_000)
    }

    func testFullRallpack1AgainstAnalyticalReference() throws {
        guard ProcessInfo.processInfo.environment[
            "NUMITISSUE_RUN_CROSS_SIMULATOR"
        ] == "1" else {
            throw XCTSkip(
                "Set NUMITISSUE_RUN_CROSS_SIMULATOR=1 to run the full 1000-compartment, 250 ms Rallpack case."
            )
        }

        let configuration = Rallpack1Configuration()
        let reference = try Rallpack1.analyticalTrace(
            configuration: configuration
        )
        let candidate = try Rallpack1.numiTissueTrace(
            configuration: configuration
        )
        let comparison = try Rallpack1.compare(
            candidate: candidate,
            reference: reference,
            relativeRMSTolerance: 0.001
        )

        XCTAssertTrue(
            comparison.passed,
            "proximal=\(comparison.proximalRelativeRMSError), distal=\(comparison.distalRelativeRMSError)"
        )
    }
}
