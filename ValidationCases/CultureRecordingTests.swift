import Foundation
import XCTest
import NumiTissueIO
import NumiTissueIntegration

final class CultureRecordingTests: XCTestCase {
    func testElectricalSeriesGlobalAndChannelConversion() throws {
        let recording = try CultureRecording.fromElectricalSeries(recordingID: "unit-test",
            storedTimeMajor: [1, 2, 3, 4, 5, 6], electrodeIDs: [.init(rawValue: 3), .init(rawValue: 7)],
            startSeconds: 0, sampleRateHertz: 1000, conversion: 1e-6,
            channelConversion: [2, 3], offsetVolts: 1e-3,
            sourceSHA256: .init(data: Data("synthetic".utf8)), measurementModelID: "raw-v1")
        XCTAssertEqual(recording.volts[0], 0.001002, accuracy: 1e-12)
        XCTAssertEqual(recording.volts[1], 0.001006, accuracy: 1e-12)
        XCTAssertEqual(recording.sampleCount, 3)
    }

    func testMasksSuppressArtifactsWithoutCountingThemAsSilence() throws {
        var values = [Double](repeating: 0, count: 100)
        values[20] = -1e-4; values[50] = -1e-4
        let recording = CultureRecording(recordingID: "mask", startSeconds: 0, sampleRateHertz: 1000,
            electrodeIDs: [.init(rawValue: 1)], volts: values,
            sourceSHA256: .init(data: Data("synthetic".utf8)), measurementModelID: "raw-v1")
        let report = try CultureFeatureExtractor.extract(recording,
            configuration: .init(blankingIntervals: [.init(startSeconds: 0.019, endSeconds: 0.022)]))
        XCTAssertEqual(report.spikes.map(\.sampleIndex), [50])
        let rate = try XCTUnwrap(report.features.first { $0.id == "electrode.1.firing_rate" })
        XCTAssertEqual(rate.value, 1 / 0.097, accuracy: 1e-10)
        XCTAssertNotNil(report.unavailable["electrode.1.isi_cv"])
    }

    func testNonFiniteInputIsRejectedEvenWhenMasked() {
        let recording = CultureRecording(recordingID: "bad", startSeconds: 0, sampleRateHertz: 1000,
            electrodeIDs: [.init(rawValue: 1)], volts: [0, .nan, 0], validSamples: [true, false, true],
            sourceSHA256: .init(data: Data()), measurementModelID: "raw-v1")
        XCTAssertThrowsError(try recording.validated())
    }
}
