import Foundation
import XCTest
import NumiTissueIntegration

final class CultureLeadFieldTests: XCTestCase {
    func testPointSourceUsesAmperesMetersAndVolts() throws {
        let source = CultureCurrentSource(id: 1, geometry: .point,
            startMicrometers: .zero, endMicrometers: .zero, radiusMicrometers: 1)
        let electrode = MEAElectrode(id: .init(rawValue: 1), positionMicrometers: SIMD3(100, 0, 0))
        let field = try CultureLeadFieldBuilder.build(sources: [source], electrodes: [electrode], contactQuadraturePoints: 1)
        let actual = try field.voltages(totalOutwardCurrentsAmperes: [1e-9])[0]
        XCTAssertEqual(actual, 1e-9 / (4 * Double.pi * 0.3 * 100e-6), accuracy: 1e-15)
    }

    func testInsulatingPlaneImageDoublesSurfacePotential() throws {
        let source = CultureCurrentSource(id: 1, geometry: .point,
            startMicrometers: SIMD3(0, 0, 10), endMicrometers: SIMD3(0, 0, 10), radiusMicrometers: 1)
        let electrode = MEAElectrode(id: .init(rawValue: 1), positionMicrometers: SIMD3(100, 0, 0))
        let remote = try CultureLeadFieldBuilder.build(sources: [source], electrodes: [electrode], contactQuadraturePoints: 1)
        let plane = try CultureLeadFieldBuilder.build(sources: [source], electrodes: [electrode],
            conductor: .init(insulatingPlaneZMicrometers: 0), contactQuadraturePoints: 1)
        XCTAssertEqual(plane.resistanceOhms[0], remote.resistanceOhms[0] * 2, accuracy: 1e-8)
    }

    func testCenteredLineSourceMatchesAnalyticIntegral() throws {
        let source = CultureCurrentSource(id: 1, geometry: .uniformLine,
            startMicrometers: SIMD3(-50, 0, 0), endMicrometers: SIMD3(50, 0, 0), radiusMicrometers: 1)
        let electrode = MEAElectrode(id: .init(rawValue: 1), positionMicrometers: SIMD3(0, 100, 0))
        let field = try CultureLeadFieldBuilder.build(sources: [source], electrodes: [electrode], contactQuadraturePoints: 1)
        let expected = 2 * asinh(0.5) / (4 * Double.pi * 0.3 * 100e-6)
        XCTAssertEqual(field.resistanceOhms[0], expected, accuracy: 1e-8)
    }

    func testCommonAverageIsAppliedToGeometryOperator() throws {
        let source = CultureCurrentSource(id: 1, geometry: .point,
            startMicrometers: .zero, endMicrometers: .zero, radiusMicrometers: 1)
        let electrodes = [100, 200].enumerated().map { index, distance in
            MEAElectrode(id: .init(rawValue: UInt32(index)), positionMicrometers: SIMD3(Float(distance), 0, 0))
        }
        let field = try CultureLeadFieldBuilder.build(sources: [source], electrodes: electrodes,
            reference: .commonAverage(electrodes.map(\.id)), contactQuadraturePoints: 1)
        XCTAssertEqual(field.resistanceOhms.reduce(0, +), 0, accuracy: 1e-8)
    }

    func testRejectsZeroLengthLinesAndOversizedMatrix() throws {
        let source = CultureCurrentSource(id: 1, geometry: .uniformLine,
            startMicrometers: .zero, endMicrometers: .zero, radiusMicrometers: 1)
        XCTAssertThrowsError(try source.validated())
        let point = CultureCurrentSource(id: 1, geometry: .point,
            startMicrometers: .zero, endMicrometers: .zero, radiusMicrometers: 1)
        let electrodes = [1, 2].map { MEAElectrode(id: .init(rawValue: UInt32($0)), positionMicrometers: SIMD3(100, 0, 0)) }
        XCTAssertThrowsError(try CultureLeadFieldBuilder.build(sources: [point], electrodes: electrodes, maximumCoefficients: 1))
    }
}
