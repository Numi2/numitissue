import Foundation

public struct CultureStimulusEpoch: Sendable, Hashable, Codable {
    public var id: String
    public var onsetSeconds: Double
    public var electrode: ElectrodeID
    public var responseWindowSeconds: ClosedRange<Double>

    public init(id: String, onsetSeconds: Double, electrode: ElectrodeID,
                responseWindowSeconds: ClosedRange<Double>) {
        self.id = id; self.onsetSeconds = onsetSeconds; self.electrode = electrode
        self.responseWindowSeconds = responseWindowSeconds
    }

    public func validated() throws -> Self {
        guard !id.isEmpty, onsetSeconds.isFinite,
              responseWindowSeconds.lowerBound.isFinite,
              responseWindowSeconds.upperBound.isFinite,
              responseWindowSeconds.lowerBound >= 0,
              responseWindowSeconds.upperBound > responseWindowSeconds.lowerBound else {
            throw CultureTwinError.invalid("stimulus epoch")
        }
        return self
    }
}

public struct CultureEvokedFeatureConfiguration: Sendable, Hashable, Codable {
    public var baselineWindowSeconds: ClosedRange<Double>
    public var responseLatencyWindowSeconds: ClosedRange<Double>
    public var propagationThresholdFraction: Double
    public var spectralBandsHertz: [String: ClosedRange<Double>]

    public init(
        baselineWindowSeconds: ClosedRange<Double> = -0.050 ... -0.005,
        responseLatencyWindowSeconds: ClosedRange<Double> = 0.001 ... 0.100,
        propagationThresholdFraction: Double = 0.35,
        spectralBandsHertz: [String: ClosedRange<Double>] = [
            "low": 1...30,
            "high": 30...300
        ]
    ) {
        self.baselineWindowSeconds = baselineWindowSeconds
        self.responseLatencyWindowSeconds = responseLatencyWindowSeconds
        self.propagationThresholdFraction = propagationThresholdFraction
        self.spectralBandsHertz = spectralBandsHertz
    }

    public func validated(sampleRateHertz: Double) throws -> Self {
        guard baselineWindowSeconds.lowerBound.isFinite,
              baselineWindowSeconds.upperBound < 0,
              baselineWindowSeconds.lowerBound < baselineWindowSeconds.upperBound,
              responseLatencyWindowSeconds.lowerBound >= 0,
              responseLatencyWindowSeconds.upperBound > responseLatencyWindowSeconds.lowerBound,
              propagationThresholdFraction.isFinite,
              propagationThresholdFraction > 0,
              propagationThresholdFraction <= 1,
              !spectralBandsHertz.isEmpty else {
            throw CultureTwinError.invalid("evoked feature configuration")
        }
        for (name, band) in spectralBandsHertz {
            guard !name.isEmpty, band.lowerBound >= 0,
                  band.lowerBound < band.upperBound,
                  band.upperBound < sampleRateHertz * 0.5 else {
                throw CultureTwinError.invalid("spectral band")
            }
        }
        return self
    }
}

public struct CultureEvokedFeatureReport: Sendable, Codable {
    public var stimulusID: String
    public var features: [CultureFeatureValue]
    public var unavailable: [String: String]
}

public enum CultureEvokedFeatureExtractor {
    public static func extract(
        recording source: CultureRecording,
        stimulus sourceStimulus: CultureStimulusEpoch,
        configuration sourceConfiguration: CultureEvokedFeatureConfiguration = .init()
    ) throws -> CultureEvokedFeatureReport {
        let recording = try source.validated()
        let stimulus = try sourceStimulus.validated()
        let configuration = try sourceConfiguration.validated(sampleRateHertz: recording.sampleRateHertz)
        let channels = recording.electrodeIDs.count
        let dt = 1 / recording.sampleRateHertz
        var features: [CultureFeatureValue] = []
        var unavailable: [String: String] = [:]
        var peakTimeByElectrode: [ElectrodeID: Double] = [:]
        var peakAmplitudeByElectrode: [ElectrodeID: Double] = [:]

        for channel in 0..<channels {
            let id = recording.electrodeIDs[channel]
            let baseline = samples(
                recording: recording,
                channel: channel,
                relativeTo: stimulus.onsetSeconds,
                window: configuration.baselineWindowSeconds
            )
            let response = samples(
                recording: recording,
                channel: channel,
                relativeTo: stimulus.onsetSeconds,
                window: configuration.responseLatencyWindowSeconds
            )
            guard !baseline.isEmpty, !response.isEmpty else {
                unavailable["evoked-amplitude-e\(id.rawValue)"] = "insufficient-valid-samples"
                continue
            }
            let baselineMean = baseline.reduce(0, +) / Double(baseline.count)
            guard let peak = response.min(by: { $0.value < $1.value }) else { continue }
            let amplitude = peak.value - baselineMean
            peakTimeByElectrode[id] = peak.time - stimulus.onsetSeconds
            peakAmplitudeByElectrode[id] = amplitude
            features.append(.init(id: "evoked-amplitude-e\(id.rawValue)", unit: "volt",
                                  value: amplitude, supportCount: response.count))
            features.append(.init(id: "evoked-latency-e\(id.rawValue)", unit: "second",
                                  value: peak.time - stimulus.onsetSeconds, supportCount: 1))
        }

        if !peakAmplitudeByElectrode.isEmpty {
            let strongest = peakAmplitudeByElectrode.values.map(abs).max() ?? 0
            let threshold = strongest * configuration.propagationThresholdFraction
            let propagated = peakAmplitudeByElectrode.filter { abs($0.value) >= threshold }
            features.append(.init(id: "evoked-responsive-electrode-fraction", unit: "fraction",
                                  value: Double(propagated.count) / Double(channels), supportCount: channels))
            if propagated.count >= 2 {
                let times = propagated.keys.compactMap { peakTimeByElectrode[$0] }
                if let minimum = times.min(), let maximum = times.max() {
                    features.append(.init(id: "evoked-propagation-span", unit: "second",
                                          value: maximum - minimum, supportCount: times.count))
                }
            }
        }

        // Deterministic direct DFT over a bounded post-stimulus window. This is intentionally
        // correctness-oriented; production FFT acceleration can replace it after equivalence tests.
        let spectralWindow = 0.0 ... min(0.250, configuration.responseLatencyWindowSeconds.upperBound)
        for (bandName, band) in configuration.spectralBandsHertz.sorted(by: { $0.key < $1.key }) {
            var channelPowers: [Double] = []
            for channel in 0..<channels {
                let values = samples(recording: recording, channel: channel,
                                     relativeTo: stimulus.onsetSeconds, window: spectralWindow).map(\.value)
                guard values.count >= 8 else { continue }
                channelPowers.append(bandPower(values: values, sampleRate: recording.sampleRateHertz, band: band))
            }
            if channelPowers.isEmpty {
                unavailable["evoked-bandpower-\(bandName)"] = "insufficient-valid-samples"
            } else {
                features.append(.init(id: "evoked-bandpower-\(bandName)", unit: "volt2",
                                      value: channelPowers.reduce(0, +) / Double(channelPowers.count),
                                      supportCount: channelPowers.count))
            }
        }
        _ = dt
        return CultureEvokedFeatureReport(stimulusID: stimulus.id,
                                          features: features.sorted { $0.id < $1.id },
                                          unavailable: unavailable)
    }

    private struct TimedValue { var time: Double; var value: Double }

    private static func samples(recording: CultureRecording, channel: Int, relativeTo onset: Double,
                                window: ClosedRange<Double>) -> [TimedValue] {
        let channels = recording.electrodeIDs.count
        var output: [TimedValue] = []
        for sample in 0..<recording.sampleCount {
            let time = recording.startSeconds + Double(sample) / recording.sampleRateHertz
            let relative = time - onset
            guard window.contains(relative) else { continue }
            let flat = sample * channels + channel
            if let mask = recording.validSamples, !mask[flat] { continue }
            output.append(TimedValue(time: time, value: recording.volts[flat]))
        }
        return output
    }

    private static func bandPower(values: [Double], sampleRate: Double,
                                  band: ClosedRange<Double>) -> Double {
        let count = values.count
        let mean = values.reduce(0, +) / Double(count)
        let centered = values.map { $0 - mean }
        var total = 0.0
        var bins = 0
        let upperBin = count / 2
        for k in 1...upperBin {
            let frequency = Double(k) * sampleRate / Double(count)
            guard band.contains(frequency) else { continue }
            var real = 0.0; var imaginary = 0.0
            for n in 0..<count {
                let angle = -2 * Double.pi * Double(k * n) / Double(count)
                real += centered[n] * cos(angle)
                imaginary += centered[n] * sin(angle)
            }
            total += (real * real + imaginary * imaginary) / Double(count * count)
            bins += 1
        }
        return bins > 0 ? total / Double(bins) : 0
    }
}
