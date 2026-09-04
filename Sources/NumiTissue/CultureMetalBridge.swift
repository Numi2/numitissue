import NumiTissueIntegration
import NumiTissueMetal
#if canImport(Metal)
@preconcurrency import Metal

public extension CultureLeadField {
    /// Rebuild after geometry/topology changes. Callers encode only currents with this source order.
    func makeMetalObservationOperator(device: any MTLDevice,
                                      maximumCoefficientBytes: Int = 128 * 1024 * 1024) throws -> MetalCultureLeadField {
        _ = try validated()
        return try MetalCultureLeadField(device: device, geometrySHA256: geometrySHA256,
            sourceIDs: sourceIDs, electrodeIDs: electrodeIDs.map(\.rawValue),
            resistanceOhmsRowMajor: coefficientsFloat32(), maximumCoefficientBytes: maximumCoefficientBytes)
    }
}
#endif
