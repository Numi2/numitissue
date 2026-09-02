import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct NeuralCurrentSource: Sendable, Hashable, Codable {
    public var id: UInt64
    public var positionMicrometers: SIMD3<Float>
    public var currentNanoamperes: Float
    public var startTick: UInt64
    public var durationTicks: UInt32

    public init(id: UInt64, positionMicrometers: SIMD3<Float>, currentNanoamperes: Float, startTick: UInt64, durationTicks: UInt32 = 1) {
        self.id = id
        self.positionMicrometers = positionMicrometers
        self.currentNanoamperes = currentNanoamperes
        self.startTick = startTick
        self.durationTicks = durationTicks
    }
}

public struct VirtualMEAState: Sendable, Hashable, Codable {
    public var lowPassState: [ElectrodeID: Float]
    public var highPassInputState: [ElectrodeID: Float]
    public var highPassOutputState: [ElectrodeID: Float]
    public var sampleIndex: UInt64

    public init(
        lowPassState: [ElectrodeID: Float] = [:],
        highPassInputState: [ElectrodeID: Float] = [:],
        highPassOutputState: [ElectrodeID: Float] = [:],
        sampleIndex: UInt64 = 0
    ) {
        self.lowPassState = lowPassState
        self.highPassInputState = highPassInputState
        self.highPassOutputState = highPassOutputState
        self.sampleIndex = sampleIndex
    }
}

/// Deterministic forward model for virtual-to-wetware protocol development. Currents are mapped to
/// extracellular voltage by the point-source volume-conductor equation, then electrode impedance,
/// recording filters, common reference, noise and ADC quantization are applied in a fixed order.
public actor VirtualMEASimulator {
    public let configuration: MEAConfiguration
    private var state: VirtualMEAState

    public init(configuration: MEAConfiguration, state: VirtualMEAState = VirtualMEAState()) throws {
        self.configuration = try configuration.validated()
        self.state = state
    }

    public func render(
        sources: [NeuralCurrentSource],
        startTick: UInt64,
        endTick: UInt64,
        randomSeed: UInt64
    ) throws -> MEASampleFrame {
        guard endTick >= startTick else { throw VirtualMEAError.invalidTimeRange }
        let durationSeconds = Double(endTick - startTick) * 25e-6
        let sampleCount = Int(ceil(durationSeconds * configuration.sampleRateHertz))
        let electrodes = configuration.electrodes.filter(\.enabled).sorted { $0.id < $1.id }
        var channels = Array(repeating: Array(repeating: Float.zero, count: sampleCount), count: electrodes.count)
        guard sampleCount > 0 else {
            return MEASampleFrame(startTick: startTick, sampleRateHertz: configuration.sampleRateHertz, electrodeOrder: electrodes.map(\.id), samplesByElectrode: channels)
        }

        let ticksPerSample = 40_000.0 / configuration.sampleRateHertz
        let lowPassAlpha = lowPassCoefficient(cutoff: configuration.lowPassHertz, sampleRate: configuration.sampleRateHertz)
        let highPassAlpha = highPassCoefficient(cutoff: configuration.highPassHertz, sampleRate: configuration.sampleRateHertz)

        for (channelIndex, electrode) in electrodes.enumerated() {
            var low = state.lowPassState[electrode.id] ?? 0
            var highInput = state.highPassInputState[electrode.id] ?? 0
            var highOutput = state.highPassOutputState[electrode.id] ?? 0
            for sampleIndex in 0..<sampleCount {
                let sampleTick = startTick + UInt64((Double(sampleIndex) * ticksPerSample).rounded(.down))
                var voltage: Float = 0
                for source in sources where sampleTick >= source.startTick && sampleTick < source.startTick + UInt64(source.durationTicks) {
                    voltage += transferVoltage(source: source, electrode: electrode)
                }
                voltage = electrodeImpedanceResponse(voltage, electrode: electrode, sampleRate: configuration.sampleRateHertz)
                low += lowPassAlpha * (voltage - low)
                let high = highPassAlpha * (highOutput + low - highInput)
                highInput = low
                highOutput = high
                var recorded = high * electrode.gain + electrode.offsetVolts
                recorded += deterministicGaussian(seed: randomSeed, electrode: electrode.id.rawValue, sample: state.sampleIndex + UInt64(sampleIndex)) * electrode.thermalNoiseVoltsRMS
                channels[channelIndex][sampleIndex] = quantize(recorded)
            }
            state.lowPassState[electrode.id] = low
            state.highPassInputState[electrode.id] = highInput
            state.highPassOutputState[electrode.id] = highOutput
        }

        if let reference = configuration.referenceElectrode,
           let referenceIndex = electrodes.firstIndex(where: { $0.id == reference }) {
            let referenceSamples = channels[referenceIndex]
            for channel in channels.indices where channel != referenceIndex {
                for sample in 0..<sampleCount { channels[channel][sample] -= referenceSamples[sample] }
            }
            channels[referenceIndex] = Array(repeating: 0, count: sampleCount)
        } else if channels.count > 1 {
            for sample in 0..<sampleCount {
                var mean: Float = 0
                for channel in channels.indices { mean += channels[channel][sample] }
                mean /= Float(channels.count)
                for channel in channels.indices { channels[channel][sample] -= mean }
            }
        }

        state.sampleIndex &+= UInt64(sampleCount)
        return MEASampleFrame(
            startTick: startTick,
            sampleRateHertz: configuration.sampleRateHertz,
            electrodeOrder: electrodes.map(\.id),
            samplesByElectrode: channels
        )
    }

    public func reset(_ newState: VirtualMEAState = VirtualMEAState()) { state = newState }
    public func exportState() -> VirtualMEAState { state }

    public static func currentSources(
        from state: TissueRuntimeState,
        tick: UInt64,
        durationTicks: UInt32 = 1
    ) -> [NeuralCurrentSource] {
        var positionByCompartment: [UInt32: SIMD3<Float>] = [:]
        positionByCompartment.reserveCapacity(state.segments.count)
        for segment in state.segments where segment.compartmentIndex != RuntimeSegmentState.invalidIndex {
            positionByCompartment[segment.compartmentIndex] = SIMD3(segment.end.x, segment.end.y, segment.end.z)
        }
        return state.compartments.enumerated().compactMap { index, compartment in
            guard let position = positionByCompartment[UInt32(index)] else { return nil }
            let current = compartment.injectedCurrentNanoamps - compartment.synapticCurrentNanoamps
            guard current.isFinite, abs(current) > 1e-12 else { return nil }
            return NeuralCurrentSource(
                id: compartment.id.rawValue,
                positionMicrometers: position,
                currentNanoamperes: current,
                startTick: tick,
                durationTicks: durationTicks
            )
        }
    }

    private func transferVoltage(source: NeuralCurrentSource, electrode: MEAElectrode) -> Float {
        let displacementMicrometers = electrode.positionMicrometers - source.positionMicrometers
        let distanceMeters = max(length(displacementMicrometers) * 1e-6, max(electrode.widthMicrometers * 0.5e-6, 1e-7))
        let currentAmperes = source.currentNanoamperes * 1e-9
        return currentAmperes / (4 * .pi * configuration.extracellularConductivitySiemensPerMeter * distanceMeters)
    }

    private func electrodeImpedanceResponse(_ voltage: Float, electrode: MEAElectrode, sampleRate: Double) -> Float {
        let omega = Float(2 * Double.pi * min(1_000, sampleRate * 0.25))
        let capacitiveReactance = electrode.capacitanceFarads > 0 ? 1 / max(omega * electrode.capacitanceFarads, Float.leastNonzeroMagnitude) : Float.greatestFiniteMagnitude
        let parallel = 1 / (1 / max(electrode.impedanceOhmsAt1kHz, 1) + 1 / max(capacitiveReactance, 1))
        let divider = parallel / max(parallel + electrode.accessResistanceOhms, 1)
        return voltage * divider
    }

    private func lowPassCoefficient(cutoff: Float, sampleRate: Double) -> Float {
        guard cutoff > 0 else { return 1 }
        let dt = Float(1 / sampleRate)
        let rc = 1 / (2 * Float.pi * cutoff)
        return dt / (rc + dt)
    }

    private func highPassCoefficient(cutoff: Float, sampleRate: Double) -> Float {
        guard cutoff > 0 else { return 0 }
        let dt = Float(1 / sampleRate)
        let rc = 1 / (2 * Float.pi * cutoff)
        return rc / (rc + dt)
    }

    private func quantize(_ voltage: Float) -> Float {
        let bounded = min(max(voltage, configuration.adcRangeVolts.lowerBound), configuration.adcRangeVolts.upperBound)
        let levels = Double((UInt64(1) << configuration.adcBits) - 1)
        let normalized = Double((bounded - configuration.adcRangeVolts.lowerBound) / (configuration.adcRangeVolts.upperBound - configuration.adcRangeVolts.lowerBound))
        let quantized = round(normalized * levels) / levels
        return configuration.adcRangeVolts.lowerBound + Float(quantized) * (configuration.adcRangeVolts.upperBound - configuration.adcRangeVolts.lowerBound)
    }

    private func deterministicGaussian(seed: UInt64, electrode: UInt32, sample: UInt64) -> Float {
        let a = splitMix64(seed ^ UInt64(electrode) << 32 ^ sample)
        let b = splitMix64(seed &+ 0x9E37_79B9_7F4A_7C15 ^ UInt64(electrode) ^ sample << 1)
        let u1 = max(Double(a >> 11) / 9_007_199_254_740_992, 1e-15)
        let u2 = Double(b >> 11) / 9_007_199_254_740_992
        return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
    }

    private func splitMix64(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private func length(_ vector: SIMD3<Float>) -> Float { sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z) }
}

public enum VirtualMEAError: Error, Sendable, CustomStringConvertible {
    case invalidTimeRange

    public var description: String {
        switch self { case .invalidTimeRange: return "Virtual MEA time range is invalid" }
    }
}
