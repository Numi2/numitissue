import Foundation
import NumiTissueIO

/// Bounded, uniformly sampled recording. Values are time-major SI volts.
/// Invalid samples remain explicitly masked; missing observations are never zero-filled.
public struct CultureRecording: Sendable, Codable {
    public var recordingID: String
    public var startSeconds: Double
    public var sampleRateHertz: Double
    public var electrodeIDs: [ElectrodeID]
    public var volts: [Double]
    public var validSamples: [Bool]?
    public var sourceSHA256: ScientificSHA256Digest
    public var measurementModelID: String

    public init(recordingID: String, startSeconds: Double, sampleRateHertz: Double,
                electrodeIDs: [ElectrodeID], volts: [Double], validSamples: [Bool]? = nil,
                sourceSHA256: ScientificSHA256Digest, measurementModelID: String) {
        self.recordingID = recordingID; self.startSeconds = startSeconds
        self.sampleRateHertz = sampleRateHertz; self.electrodeIDs = electrodeIDs
        self.volts = volts; self.validSamples = validSamples
        self.sourceSHA256 = sourceSHA256; self.measurementModelID = measurementModelID
    }
    public var sampleCount: Int { electrodeIDs.isEmpty ? 0 : volts.count / electrodeIDs.count }
    public var endSeconds: Double { startSeconds + Double(sampleCount) / sampleRateHertz }

    public func validated(maximumValues: Int = 16_777_216) throws -> Self {
        guard !recordingID.isEmpty, !measurementModelID.isEmpty,
              startSeconds.isFinite, sampleRateHertz.isFinite, sampleRateHertz > 0,
              !electrodeIDs.isEmpty, electrodeIDs.count <= 4096,
              Set(electrodeIDs).count == electrodeIDs.count,
              !volts.isEmpty, volts.count <= maximumValues,
              volts.count.isMultiple(of: electrodeIDs.count), sampleCount >= 3,
              volts.allSatisfy(\.isFinite), validSamples.map({ $0.count == volts.count }) ?? true,
              endSeconds.isFinite, endSeconds > startSeconds else {
            throw CultureTwinError.invalid("recording dimensions, timebase or samples")
        }
        return self
    }

    /// NWB ElectricalSeries conversion: volts = stored * conversion * channel_conversion + offset.
    /// Callers must pin the source NWB and provide an explicitly bounded uniformly sampled window.
    public static func fromElectricalSeries(recordingID: String, storedTimeMajor: [Double],
        electrodeIDs: [ElectrodeID], startSeconds: Double, sampleRateHertz: Double,
        conversion: Double, channelConversion: [Double], offsetVolts: Double,
        validSamples: [Bool]? = nil, sourceSHA256: ScientificSHA256Digest,
        measurementModelID: String, maximumValues: Int = 16_777_216) throws -> Self {
        guard !electrodeIDs.isEmpty, channelConversion.count == electrodeIDs.count,
              storedTimeMajor.count <= maximumValues, conversion.isFinite, conversion != 0,
              offsetVolts.isFinite, channelConversion.allSatisfy({ $0.isFinite && $0 != 0 }) else {
            throw CultureTwinError.invalid("ElectricalSeries conversion")
        }
        let values = storedTimeMajor.enumerated().map { index, value in
            value * conversion * channelConversion[index % electrodeIDs.count] + offsetVolts
        }
        return try Self(recordingID: recordingID, startSeconds: startSeconds, sampleRateHertz: sampleRateHertz,
            electrodeIDs: electrodeIDs, volts: values, validSamples: validSamples,
            sourceSHA256: sourceSHA256, measurementModelID: measurementModelID).validated(maximumValues: maximumValues)
    }

    public static func from(frame: MEASampleFrame, recordingID: String,
                            sourceSHA256: ScientificSHA256Digest, measurementModelID: String,
                            secondsPerTick: Double = 25e-6, maximumValues: Int = 16_777_216) throws -> Self {
        let count = frame.electrodeOrder.count.multipliedReportingOverflow(by: frame.sampleCount)
        guard secondsPerTick.isFinite, secondsPerTick > 0, !count.overflow,
              count.partialValue <= maximumValues,
              frame.samplesByElectrode.count == frame.electrodeOrder.count,
              frame.samplesByElectrode.allSatisfy({ $0.count == frame.sampleCount }) else {
            throw CultureTwinError.invalid("MEA frame shape or timebase")
        }
        var values = [Double](); values.reserveCapacity(count.partialValue)
        for sample in 0..<frame.sampleCount {
            for channel in frame.electrodeOrder.indices { values.append(Double(frame.samplesByElectrode[channel][sample])) }
        }
        return try Self(recordingID: recordingID, startSeconds: Double(frame.startTick) * secondsPerTick,
            sampleRateHertz: frame.sampleRateHertz, electrodeIDs: frame.electrodeOrder, volts: values,
            sourceSHA256: sourceSHA256, measurementModelID: measurementModelID).validated(maximumValues: maximumValues)
    }
}

public struct CultureTimeInterval: Sendable, Hashable, Codable {
    public var startSeconds: Double
    public var endSeconds: Double
    public init(startSeconds: Double, endSeconds: Double) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds
    }
    public func validated() throws -> Self {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds < endSeconds else {
            throw CultureTwinError.invalid("time interval")
        }
        return self
    }
    public func contains(_ time: Double) -> Bool { time >= startSeconds && time < endSeconds }
}

public struct CultureDetectedSpike: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var sampleIndex: Int
    public var timeSeconds: Double
    public var amplitudeVolts: Double
}

public struct CultureFeatureValue: Sendable, Hashable, Codable {
    public var id: String
    public var unit: String
    public var value: Double
    /// Number of observations used, not an estimate of independent biological replicates.
    public var supportCount: Int
}

public struct CultureFeatureReport: Sendable, Codable {
    public var recordingID: String
    public var sourceSHA256: ScientificSHA256Digest
    public var extractionSHA256: ScientificSHA256Digest
    public var measurementModelID: String
    public var features: [CultureFeatureValue]
    public var unavailable: [String: String]
    public var spikes: [CultureDetectedSpike]
}
