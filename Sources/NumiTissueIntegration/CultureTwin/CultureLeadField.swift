import Foundation
import NumiTissueIO

/// All lengths are micrometers; source currents are total outward transmembrane amperes.
/// Voltage, intracellular potential and current density are NOT accepted as source currents.
public struct CultureCurrentSource: Sendable, Hashable, Codable {
    public enum Geometry: String, Sendable, Codable { case point, uniformLine }
    public var id: UInt64
    public var geometry: Geometry
    public var startMicrometers: SIMD3<Double>
    public var endMicrometers: SIMD3<Double>
    public var radiusMicrometers: Double

    public init(id: UInt64, geometry: Geometry, startMicrometers: SIMD3<Double>,
                endMicrometers: SIMD3<Double>, radiusMicrometers: Double) {
        self.id = id; self.geometry = geometry
        self.startMicrometers = startMicrometers; self.endMicrometers = endMicrometers
        self.radiusMicrometers = radiusMicrometers
    }

    public func validated() throws -> Self {
        guard CultureGeometry.finite(startMicrometers), CultureGeometry.finite(endMicrometers),
              radiusMicrometers.isFinite, radiusMicrometers > 0 else {
            throw CultureTwinError.invalid("current-source geometry")
        }
        let length = CultureGeometry.length(endMicrometers - startMicrometers)
        guard length.isFinite, geometry != .uniformLine || length > 0 else {
            throw CultureTwinError.invalid("zero-length line source")
        }
        return self
    }
}

public struct CultureConductor: Sendable, Hashable, Codable {
    public var conductivitySiemensPerMeter: Double
    /// Optional perfectly insulating planar substrate. Not a finite three-layer saline model.
    public var insulatingPlaneZMicrometers: Double?
    public init(conductivitySiemensPerMeter: Double = 0.3,
                insulatingPlaneZMicrometers: Double? = nil) {
        self.conductivitySiemensPerMeter = conductivitySiemensPerMeter
        self.insulatingPlaneZMicrometers = insulatingPlaneZMicrometers
    }
    public func validated() throws -> Self {
        guard conductivitySiemensPerMeter.isFinite, conductivitySiemensPerMeter > 0,
              insulatingPlaneZMicrometers.map({ $0.isFinite }) ?? true else {
            throw CultureTwinError.invalid("volume conductor")
        }
        return self
    }
}

public enum CultureVoltageReference: Sendable, Hashable, Codable {
    case remote
    case electrode(ElectrodeID)
    case commonAverage([ElectrodeID])
}

/// Immutable geometry operator. Shape is [electrode, source]; units are V/A (ohms).
/// Build once per geometry revision, not once per simulation time step.
public struct CultureLeadField: Sendable, Codable {
    public let schemaVersion: UInt32
    public let electrodeIDs: [ElectrodeID]
    public let sourceIDs: [UInt64]
    public let resistanceOhms: [Double]
    public let geometrySHA256: ScientificSHA256Digest
    public let reference: CultureVoltageReference

    public func validated() throws -> Self {
        let product = electrodeIDs.count.multipliedReportingOverflow(by: sourceIDs.count)
        guard schemaVersion == 1, !electrodeIDs.isEmpty, !sourceIDs.isEmpty,
              Set(electrodeIDs).count == electrodeIDs.count,
              Set(sourceIDs).count == sourceIDs.count, !product.overflow,
              resistanceOhms.count == product.partialValue,
              resistanceOhms.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("lead-field dimensions or values")
        }
        return self
    }

    /// Deterministic FP64 observation reference; this does not relabel the tissue solver FP64.
    public func voltages(totalOutwardCurrentsAmperes currents: [Double]) throws -> [Double] {
        _ = try validated()
        guard currents.count == sourceIDs.count, currents.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("total transmembrane-current vector")
        }
        return try electrodeIDs.indices.map { row in
            var value = 0.0
            for column in currents.indices {
                value += resistanceOhms[row * currents.count + column] * currents[column]
            }
            guard value.isFinite else { throw CultureTwinError.invalid("extracellular voltage overflow") }
            return value
        }
    }

    /// Row-major coefficients suitable for the bounded scientific32 GPU observation operator.
    public func coefficientsFloat32() throws -> [Float] {
        _ = try validated()
        return try resistanceOhms.map { value in
            let converted = Float(value)
            guard converted.isFinite else { throw CultureTwinError.invalid("FP32 lead-field overflow") }
            return converted
        }
    }
}

public enum CultureLeadFieldBuilder {
    public static func build(sources: [CultureCurrentSource], electrodes: [MEAElectrode],
                             conductor: CultureConductor = .init(),
                             reference: CultureVoltageReference = .remote,
                             contactQuadraturePoints: Int = 64,
                             maximumCoefficients: Int = 16_777_216) throws -> CultureLeadField {
        _ = try conductor.validated()
        guard !sources.isEmpty, !electrodes.isEmpty,
              Set(sources.map(\.id)).count == sources.count,
              Set(electrodes.map(\.id)).count == electrodes.count,
              contactQuadraturePoints >= 1, contactQuadraturePoints <= 4096,
              maximumCoefficients > 0 else { throw CultureTwinError.invalid("lead-field request") }
        for source in sources { _ = try source.validated() }
        let enabled = electrodes.filter(\.enabled)
        let size = enabled.count.multipliedReportingOverflow(by: sources.count)
        guard !enabled.isEmpty, !size.overflow, size.partialValue <= maximumCoefficients else {
            throw CultureTwinError.capacity("lead-field coefficient budget")
        }
        let points = try enabled.map {
            try contactPoints($0, count: contactQuadraturePoints)
        }
        if let z = conductor.insulatingPlaneZMicrometers {
            guard sources.allSatisfy({ $0.startMicrometers.z >= z && $0.endMicrometers.z >= z }),
                  points.joined().allSatisfy({ $0.z >= z - 1e-9 }) else {
                throw CultureTwinError.invalid("source or contact below insulating substrate")
            }
        }
        var values = [Double](repeating: 0, count: size.partialValue)
        for row in enabled.indices {
            for column in sources.indices {
                let source = sources[column]
                var total = 0.0
                for point in points[row] {
                    total += resistance(at: point, source: source,
                                        conductivity: conductor.conductivitySiemensPerMeter)
                    if let z = conductor.insulatingPlaneZMicrometers {
                        var image = source
                        image.startMicrometers.z = 2 * z - source.startMicrometers.z
                        image.endMicrometers.z = 2 * z - source.endMicrometers.z
                        total += resistance(at: point, source: image,
                                            conductivity: conductor.conductivitySiemensPerMeter)
                    }
                }
                values[row * sources.count + column] = total / Double(points[row].count)
            }
        }
        let referenceIndices: [Int]
        switch reference {
        case .remote: referenceIndices = []
        case .electrode(let id):
            guard let index = enabled.firstIndex(where: { $0.id == id }) else {
                throw CultureTwinError.invalid("reference electrode missing or disabled")
            }
            referenceIndices = [index]
        case .commonAverage(let ids):
            guard !ids.isEmpty, Set(ids).count == ids.count else {
                throw CultureTwinError.invalid("common-average reference membership")
            }
            referenceIndices = try ids.map { id in
                guard let index = enabled.firstIndex(where: { $0.id == id }) else {
                    throw CultureTwinError.invalid("common-average electrode missing or disabled")
                }
                return index
            }
        }
        if !referenceIndices.isEmpty {
            for column in sources.indices {
                let mean = referenceIndices.reduce(0.0) {
                    $0 + values[$1 * sources.count + column]
                } / Double(referenceIndices.count)
                for row in enabled.indices { values[row * sources.count + column] -= mean }
            }
        }
        struct Identity: Encodable {
            var method: String; var sources: [CultureCurrentSource]; var electrodes: [MEAElectrode]
            var conductor: CultureConductor; var reference: CultureVoltageReference; var quadrature: Int
        }
        let identity = Identity(method: "finite-contact-line-source-v1", sources: sources,
                                electrodes: enabled, conductor: conductor, reference: reference,
                                quadrature: contactQuadraturePoints)
        return try CultureLeadField(schemaVersion: 1, electrodeIDs: enabled.map(\.id),
                                    sourceIDs: sources.map(\.id), resistanceOhms: values,
                                    geometrySHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(identity)),
                                    reference: reference).validated()
    }

    private static func resistance(at point: SIMD3<Double>, source: CultureCurrentSource,
                                   conductivity: Double) -> Double {
        let start = source.startMicrometers * 1e-6
        let end = source.endMicrometers * 1e-6
        let offset = point * 1e-6 - start
        let minimumRadius = source.radiusMicrometers * 1e-6
        let factor = 1 / (4 * Double.pi * conductivity)
        if source.geometry == .point {
            return factor / max(CultureGeometry.length(offset), minimumRadius)
        }
        let delta = end - start
        let length = CultureGeometry.length(delta)
        let midpointDistance = CultureGeometry.length(offset - delta * 0.5)
        // Avoid cancellation for distant observations or effectively vanishing segments.
        if length <= 1e-6 * max(midpointDistance, minimumRadius) {
            return factor / max(midpointDistance, minimumRadius)
        }
        let direction = delta / length
        let projection = CultureGeometry.dot(offset, direction)
        let radial = offset - direction * projection
        let rho = max(CultureGeometry.length(radial), minimumRadius)
        return factor * (asinh(projection / rho) - asinh((projection - length) / rho)) / length
    }

    private static func contactPoints(_ electrode: MEAElectrode, count: Int) throws -> [SIMD3<Double>] {
        let center = SIMD3<Double>(Double(electrode.positionMicrometers.x),
                                   Double(electrode.positionMicrometers.y), Double(electrode.positionMicrometers.z))
        let normal = SIMD3<Double>(Double(electrode.normal.x), Double(electrode.normal.y), Double(electrode.normal.z))
        let normalLength = CultureGeometry.length(normal)
        guard CultureGeometry.finite(center), CultureGeometry.finite(normal), normalLength.isFinite,
              normalLength > 1e-12, electrode.widthMicrometers.isFinite, electrode.widthMicrometers > 0,
              electrode.heightMicrometers.isFinite, electrode.heightMicrometers > 0 else {
            throw CultureTwinError.invalid("electrode geometry")
        }
        guard electrode.shape != .spherical else {
            throw CultureTwinError.unsupported("spherical-contact surface quadrature")
        }
        let n = normal / normalLength
        let axis = abs(n.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let cross = CultureGeometry.cross(n, axis)
        let u = cross / CultureGeometry.length(cross)
        let v = CultureGeometry.cross(n, u)
        if count == 1 { return [center] } // Explicit midpoint approximation.
        if electrode.shape == .disk {
            let radius = Double(electrode.widthMicrometers) * 0.5
            return (0..<count).map { i in
                let r = radius * sqrt((Double(i) + 0.5) / Double(count))
                let angle = Double(i) * Double.pi * (3 - sqrt(5))
                return center + u * (r * cos(angle)) + v * (r * sin(angle))
            }
        }
        let side = Int(Double(count).squareRoot())
        guard side * side == count else {
            throw CultureTwinError.invalid("rectangular contacts require square-number quadrature count")
        }
        let width = Double(electrode.widthMicrometers)
        let height = electrode.shape == .square ? width : Double(electrode.heightMicrometers)
        return (0..<count).map { i in
            center + u * (width * ((Double(i % side) + 0.5) / Double(side) - 0.5))
                + v * (height * ((Double(i / side) + 0.5) / Double(side) - 0.5))
        }
    }
}

enum CultureGeometry {
    static func finite(_ v: SIMD3<Double>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    static func length(_ v: SIMD3<Double>) -> Double { hypot(hypot(v.x, v.y), v.z) }
    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}

public enum CultureTwinError: Error, Sendable, CustomStringConvertible {
    case invalid(String), capacity(String), unsupported(String), leakage(String)
    public var description: String {
        switch self {
        case .invalid(let value): return "Invalid culture-twin input: \(value)"
        case .capacity(let value): return "Culture-twin resource limit: \(value)"
        case .unsupported(let value): return "Unsupported culture-twin operation: \(value)"
        case .leakage(let value): return "Culture-twin holdout leakage: \(value)"
        }
    }
}
