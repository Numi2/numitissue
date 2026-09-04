import Foundation
import XCTest
import NumiTissueIO
import NumiTissueIntegration

final class CultureMissingDataTests: XCTestCase {
    func testUnobservableArrayIsNotReportedAsSilent() throws {
        let recording = CultureRecording(recordingID: "all-masked", startSeconds: 0, sampleRateHertz: 1000,
            electrodeIDs: [.init(rawValue: 1)], volts: [Double](repeating: 0, count: 100),
            validSamples: [Bool](repeating: false, count: 100),
            sourceSHA256: .init(data: Data("synthetic".utf8)), measurementModelID: "raw-v1")
        let report = try CultureFeatureExtractor.extract(recording)
        XCTAssertFalse(report.features.contains { $0.id == "network.active_electrode_fraction" })
        XCTAssertNotNil(report.unavailable["network.active_electrode_fraction"])
        XCTAssertNotNil(report.unavailable["network.coactive_bin_fraction"])
        XCTAssertTrue(report.spikes.isEmpty)
    }
}
