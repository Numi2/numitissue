import Foundation
import NumiTissueIO

/// Explicit negative-peak / MAD detection and maximum-ISI burst definition.
/// No filtering is implicit; record preprocessing identity in measurementModelID.
public struct CultureFeatureConfiguration: Sendable, Codable {
    public var thresholdSigma: Double
    public var refractorySeconds: Double
    public var noiseFloorVolts: Double
    public var noiseWindow: CultureTimeInterval?
    public var blankingIntervals: [CultureTimeInterval]
    public var maximumBurstISISeconds: Double
    public var minimumBurstSpikes: Int
    public var populationBinSeconds: Double
    public var coactiveFraction: Double
    public var minimumNoiseSamples: Int
    public var maximumDetectedSpikes: Int
    public init(thresholdSigma: Double = 5, refractorySeconds: Double = 0.001,
                noiseFloorVolts: Double = 1e-9, noiseWindow: CultureTimeInterval? = nil,
                blankingIntervals: [CultureTimeInterval] = [], maximumBurstISISeconds: Double = 0.1,
                minimumBurstSpikes: Int = 4, populationBinSeconds: Double = 0.02,
                coactiveFraction: Double = 0.25, minimumNoiseSamples: Int = 32,
                maximumDetectedSpikes: Int = 1_000_000) {
        self.thresholdSigma = thresholdSigma; self.refractorySeconds = refractorySeconds
        self.noiseFloorVolts = noiseFloorVolts; self.noiseWindow = noiseWindow
        self.blankingIntervals = blankingIntervals; self.maximumBurstISISeconds = maximumBurstISISeconds
        self.minimumBurstSpikes = minimumBurstSpikes; self.populationBinSeconds = populationBinSeconds
        self.coactiveFraction = coactiveFraction; self.minimumNoiseSamples = minimumNoiseSamples
        self.maximumDetectedSpikes = maximumDetectedSpikes
    }
    public func validated() throws -> Self {
        guard thresholdSigma.isFinite, thresholdSigma > 0, refractorySeconds.isFinite, refractorySeconds > 0,
              noiseFloorVolts.isFinite, noiseFloorVolts > 0, maximumBurstISISeconds.isFinite,
              maximumBurstISISeconds > refractorySeconds, minimumBurstSpikes >= 2,
              populationBinSeconds.isFinite, populationBinSeconds > 0,
              coactiveFraction.isFinite, coactiveFraction > 0, coactiveFraction <= 1,
              minimumNoiseSamples >= 3, maximumDetectedSpikes > 0, blankingIntervals.count <= 4096 else {
            throw CultureTwinError.invalid("feature-extraction configuration")
        }
        if let noiseWindow { _ = try noiseWindow.validated() }
        for interval in blankingIntervals { _ = try interval.validated() }
        return self
    }
}

public enum CultureFeatureExtractor {
    public static func extract(_ source: CultureRecording,
                               configuration sourceConfiguration: CultureFeatureConfiguration = .init()) throws -> CultureFeatureReport {
        let recording = try source.validated()
        let config = try sourceConfiguration.validated()
        let channels = recording.electrodeIDs.count
        let count = recording.sampleCount
        let binSamplesDouble = floor(config.populationBinSeconds * recording.sampleRateHertz)
        guard binSamplesDouble.isFinite, binSamplesDouble >= 1, binSamplesDouble <= Double(count) else {
            throw CultureTwinError.invalid("population bin outside recording resolution or duration")
        }
        let binSamples = Int(binSamplesDouble)
        let binCount = count / binSamples
        var valid = recording.validSamples ?? [Bool](repeating: true, count: recording.volts.count)
        for interval in config.blankingIntervals {
            let lower = max(0, min(Double(count), ceil((interval.startSeconds - recording.startSeconds) * recording.sampleRateHertz)))
            let upper = max(0, min(Double(count), ceil((interval.endSeconds - recording.startSeconds) * recording.sampleRateHertz)))
            if lower < upper {
                for sample in Int(lower)..<Int(upper) {
                    for channel in 0..<channels { valid[sample * channels + channel] = false }
                }
            }
        }
        var availableBins = [Bool](repeating: true, count: binCount)
        var activeChannelsPerBin = [Int](repeating: 0, count: binCount)
        var features = [CultureFeatureValue]()
        var unavailable = [String: String]()
        var allSpikes = [CultureDetectedSpike]()
        var activeElectrodes = 0
        var observableElectrodes = 0
        func time(_ index: Int) -> Double { recording.startSeconds + Double(index) / recording.sampleRateHertz }
        for channel in 0..<channels {
            let id = recording.electrodeIDs[channel]
            let prefix = "electrode.\(id.rawValue)"
            var baseline = [Double]()
            var exposureSamples = 0
            var sumSquares = 0.0
            for sample in 0..<count {
                let index = sample * channels + channel
                if valid[index] {
                    exposureSamples += 1
                    sumSquares += recording.volts[index] * recording.volts[index]
                    if config.noiseWindow?.contains(time(sample)) ?? true { baseline.append(recording.volts[index]) }
                } else if sample / binSamples < binCount {
                    availableBins[sample / binSamples] = false
                }
            }
            guard exposureSamples > 0, baseline.count >= config.minimumNoiseSamples else {
                unavailable[prefix] = "Insufficient valid exposure or baseline samples."
                availableBins = [Bool](repeating: false, count: binCount)
                continue
            }
            observableElectrodes += 1
            let center = median(baseline)
            let mad = median(baseline.map { abs($0 - center) })
            let sigma = max(mad / 0.6744897501960817, config.noiseFloorVolts)
            let threshold = -config.thresholdSigma * sigma
            var spikes = [CultureDetectedSpike]()
            var nextTime = -Double.infinity
            var activeBins = Set<Int>()
            for sample in 1..<(count - 1) {
                let index = sample * channels + channel
                guard valid[index - channels], valid[index], valid[index + channels] else { continue }
                let value = recording.volts[index] - center
                let previous = recording.volts[index - channels] - center
                let next = recording.volts[index + channels] - center
                guard value <= threshold, value < previous, value <= next, time(sample) >= nextTime else { continue }
                guard allSpikes.count + spikes.count < config.maximumDetectedSpikes else {
                    throw CultureTwinError.capacity("detected-spike budget")
                }
                spikes.append(CultureDetectedSpike(electrode: id, sampleIndex: sample,
                    timeSeconds: time(sample), amplitudeVolts: value))
                nextTime = time(sample) + config.refractorySeconds
                if sample / binSamples < binCount { activeBins.insert(sample / binSamples) }
            }
            if !spikes.isEmpty { activeElectrodes += 1 }
            for bin in activeBins { activeChannelsPerBin[bin] += 1 }
            let exposure = Double(exposureSamples) / recording.sampleRateHertz
            features.append(.init(id: prefix + ".firing_rate", unit: "Hz", value: Double(spikes.count) / exposure, supportCount: exposureSamples))
            features.append(.init(id: prefix + ".noise_sigma", unit: "V", value: sigma, supportCount: baseline.count))
            features.append(.init(id: prefix + ".voltage_rms", unit: "V", value: sqrt(sumSquares / Double(exposureSamples)), supportCount: exposureSamples))
            features.append(.init(id: prefix + ".valid_fraction", unit: "1", value: Double(exposureSamples) / Double(count), supportCount: count))
            var isi = [Double]()
            for pair in zip(spikes, spikes.dropFirst()) {
                let uninterrupted = (pair.0.sampleIndex...pair.1.sampleIndex).allSatisfy { valid[$0 * channels + channel] }
                if uninterrupted { isi.append(pair.1.timeSeconds - pair.0.timeSeconds) }
            }
            if isi.count >= 2 {
                let mean = isi.reduce(0, +) / Double(isi.count)
                let variance = isi.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(isi.count - 1)
                features.append(.init(id: prefix + ".isi_cv", unit: "1", value: sqrt(variance) / mean, supportCount: isi.count))
            } else { unavailable[prefix + ".isi_cv"] = "Fewer than two uninterrupted interspike intervals." }
            var runCount = spikes.isEmpty ? 0 : 1
            var bursts = 0
            for pair in zip(spikes, spikes.dropFirst()) {
                let close = pair.1.timeSeconds - pair.0.timeSeconds <= config.maximumBurstISISeconds
                let uninterrupted = (pair.0.sampleIndex...pair.1.sampleIndex).allSatisfy { valid[$0 * channels + channel] }
                if close && uninterrupted { runCount += 1 }
                else { if runCount >= config.minimumBurstSpikes { bursts += 1 }; runCount = 1 }
            }
            if runCount >= config.minimumBurstSpikes { bursts += 1 }
            features.append(.init(id: prefix + ".burst_rate", unit: "Hz", value: Double(bursts) / exposure, supportCount: spikes.count))
            allSpikes.append(contentsOf: spikes)
        }
        let usableBins = availableBins.indices.filter { availableBins[$0] }
        if !usableBins.isEmpty {
            let coactive = usableBins.filter { Double(activeChannelsPerBin[$0]) / Double(channels) >= config.coactiveFraction }.count
            features.append(.init(id: "network.coactive_bin_fraction", unit: "1", value: Double(coactive) / Double(usableBins.count), supportCount: usableBins.count))
        } else { unavailable["network.coactive_bin_fraction"] = "No fully observed population bins." }
        features.append(.init(id: "network.observable_electrode_fraction", unit: "1", value: Double(observableElectrodes) / Double(channels), supportCount: channels))
        if observableElectrodes > 0 {
            features.append(.init(id: "network.active_electrode_fraction", unit: "1", value: Double(activeElectrodes) / Double(observableElectrodes), supportCount: observableElectrodes))
        } else { unavailable["network.active_electrode_fraction"] = "No observable electrodes; not a silent network." }
        guard features.allSatisfy({ $0.value.isFinite }) else { throw CultureTwinError.invalid("feature overflow") }
        return CultureFeatureReport(recordingID: recording.recordingID, sourceSHA256: recording.sourceSHA256,
            extractionSHA256: ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(config)),
            measurementModelID: recording.measurementModelID, features: features.sorted { $0.id < $1.id },
            unavailable: unavailable, spikes: allSpikes.sorted { ($0.sampleIndex, $0.electrode) < ($1.sampleIndex, $1.electrode) })
    }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted(); let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] * 0.5 + sorted[middle] * 0.5 : sorted[middle]
    }
}
