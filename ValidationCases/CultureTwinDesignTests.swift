import Foundation
import XCTest
import NumiTissueIntegration

final class CultureTwinDesignTests: XCTestCase {
    func testEmpiricalCRPSMatchesFiniteDistribution() throws {
        // E|X-1| = 1; one-half E|X-X'| = 0.5 for X uniform on {0,2}.
        XCTAssertEqual(try CulturePredictiveScorer.empiricalCRPS(samples: [0, 2], observed: 1), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try CulturePredictiveScorer.empiricalCRPS(samples: [3, 3, 3, 3], observed: 4), 1, accuracy: 1e-12)
        XCTAssertThrowsError(try CulturePredictiveScorer.empiricalCRPS(samples: [.nan], observed: 1))
    }

    func testCultureHoldoutCannotShareDonorOrBatch() throws {
        let calibration = session(id: "training", culture: "culture-a", donor: "donor-a", batch: "batch-a", partition: .calibration, time: 1)
        let leaked = session(id: "external", culture: "culture-b", donor: "donor-a", batch: "batch-b", partition: .cultureHoldout, time: 2)
        XCTAssertThrowsError(try design([calibration, leaked]).validated())
        let independent = session(id: "external", culture: "culture-b", donor: "donor-b", batch: "batch-b", partition: .cultureHoldout, time: 2)
        XCTAssertNoThrow(try design([calibration, independent]).validated())
    }

    func testTemporalHoldoutMustFollowCalibration() {
        let calibration = session(id: "training", culture: "culture-a", donor: "donor-a", batch: "batch-a", partition: .calibration, time: 2)
        let invalid = session(id: "later", culture: "culture-a", donor: "donor-a", batch: "batch-a", partition: .temporalHoldout, time: 1)
        XCTAssertThrowsError(try design([calibration, invalid]).validated())
    }

    private func session(id: String, culture: String, donor: String, batch: String,
                         partition: CultureStudyPartition, time: UInt64) -> CultureStudySession {
        .init(id: id, cultureID: culture, donorID: donor, batchID: batch,
              acquiredAt: Date(timeIntervalSince1970: Double(time)), simulationTick: time * 200,
              waveformID: "baseline", stimulatedElectrodes: [.init(rawValue: 1)], partition: partition)
    }
    private func design(_ sessions: [CultureStudySession]) -> CultureStudyDesign {
        .init(id: "test", measurementModelID: "raw-v1", featureConfiguration: .init(),
              features: [.init(id: "electrode.1.firing_rate", unit: "Hz", scale: 1, measurementSD: 0.1)], sessions: sessions)
    }
}
