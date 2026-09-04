import Foundation
import NumiTissueIO

public struct CultureElectrodeInterface: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var seriesResistanceOhms: Double
    public var doubleLayerCapacitanceFarads: Double
    public var chargeTransferResistanceOhms: Double
    public var amplifierInputResistanceOhms: Double
    public var amplifierInputCapacitanceFarads: Double
    public var gain: Double
    public var offsetVolts: Double
    public var saturationVolts: ClosedRange<Double>

    public init(
        electrode: ElectrodeID,
        seriesResistanceOhms: Double,
        doubleLayerCapacitanceFarads: Double,
        chargeTransferResistanceOhms: Double,
        amplifierInputResistanceOhms: Double = 1e9,
        amplifierInputCapacitanceFarads: Double = 10e-12,
        gain: Double = 1,
        offsetVolts: Double = 0,
        saturationVolts: ClosedRange<Double> = -0.01...0.01
    ) {
        self.electrode = electrode
        self.seriesResistanceOhms = seriesResistanceOhms
        self.doubleLayerCapacitanceFarads = doubleLayerCapacitanceFarads
        self.chargeTransferResistanceOhms = chargeTransferResistanceOhms
        self.amplifierInputResistanceOhms = amplifierInputResistanceOhms
        self.amplifierInputCapacitanceFarads = amplifierInputCapacitanceFarads
        self.gain = gain
        self.offsetVolts = offsetVolts
        self.saturationVolts = saturationVolts
    }

    public func validated() throws -> Self {
        guard seriesResistanceOhms.isFinite, seriesResistanceOhms >= 0,
              doubleLayerCapacitanceFarads.isFinite, doubleLayerCapacitanceFarads > 0,
              chargeTransferResistanceOhms.isFinite, chargeTransferResistanceOhms > 0,
              amplifierInputResistanceOhms.isFinite, amplifierInputResistanceOhms > 0,
              amplifierInputCapacitanceFarads.isFinite, amplifierInputCapacitanceFarads >= 0,
              gain.isFinite, gain != 0,
              offsetVolts.isFinite,
              saturationVolts.lowerBound.isFinite, saturationVolts.upperBound.isFinite,
              saturationVolts.lowerBound < saturationVolts.upperBound else {
            throw CultureTwinError.invalid("electrode interface")
        }
        return self
    }
}

public struct CultureStimulusArtifact: Sendable, Hashable, Codable {
    public var electrode: ElectrodeID
    public var startSeconds: Double
    public var chargeCoulombs: Double
    public var couplingOhms: Double
    public var decaySeconds: Double

    public init(
        electrode: ElectrodeID,
        startSeconds: Double,
        chargeCoulombs: Double,
        couplingOhms: Double,
        decaySeconds: Double
    ) {
        self.electrode = electrode
        self.startSeconds = startSeconds
        self.chargeCoulombs = chargeCoulombs
        self.couplingOhms = couplingOhms
        self.decaySeconds = decaySeconds
    }

    public func validated() throws -> Self {
        guard startSeconds.isFinite,
              chargeCoulombs.isFinite,
              couplingOhms.isFinite,
              couplingOhms >= 0,
              decaySeconds.isFinite,
              decaySeconds > 0 else {
            throw CultureTwinError.invalid("stimulation artifact")
        }
        return self
    }
}

public struct CultureMeasurementModel: Sendable, Hashable, Codable {
    public var id: String
    public var interfaces: [CultureElectrodeInterface]
    public var highPassHertz: Double
    public var lowPassHertz: Double
    public var blankingSecondsAfterStimulus: Double
    public var commonModeRejection: Double

    public init(
        id: String,
        interfaces: [CultureElectrodeInterface],
        highPassHertz: Double = 1,
        lowPassHertz: Double = 7_500,
        blankingSecondsAfterStimulus: Double = 0.001,
        commonModeRejection: Double = 1
    ) {
        self.id = id
        self.interfaces = interfaces
        self.highPassHertz = highPassHertz
        self.lowPassHertz = lowPassHertz
        self.blankingSecondsAfterStimulus = blankingSecondsAfterStimulus
        self.commonModeRejection = commonModeRejection
    }

    public func validated(sampleRateHertz: Double) throws -> Self {
        guard !id.isEmpty,
              !interfaces.isEmpty,
              Set(interfaces.map(\.electrode)).count == interfaces.count,
              sampleRateHertz.isFinite, sampleRateHertz > 0,
              highPassHertz.isFinite, highPassHertz >= 0,
              lowPassHertz.isFinite, lowPassHertz > highPassHertz,
              lowPassHertz < sampleRateHertz * 0.5,
              blankingSecondsAfterStimulus.isFinite, blankingSecondsAfterStimulus >= 0,
              commonModeRejection.isFinite, (0...1).contains(commonModeRejection) else {
            throw CultureTwinError.invalid("measurement model")
        }
        for value in interfaces { _ = try value.validated() }
        return self
    }

    public func sha256(sampleRateHertz: Double) throws -> ScientificSHA256Digest {
        _ = try validated(sampleRateHertz: sampleRateHertz)
        return ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(self))
    }
}

/// Deterministic first-order electrode/amplifier observation model. It intentionally keeps the
/// biology and acquisition electronics separate. Frequency-domain impedance fitting can produce
/// the R/C values; this runtime applies them without changing tissue state.
public enum CultureMeasurementProcessor {
    public static func process(
        extracellularVolts: [Double],
        sampleRateHertz: Double,
        electrodeIDs: [ElectrodeID],
        model sourceModel: CultureMeasurementModel,
        artifacts sourceArtifacts: [CultureStimulusArtifact] = []
    ) throws -> (volts: [Double], valid: [Bool]) {
        let model = try sourceModel.validated(sampleRateHertz: sampleRateHertz)
        guard !electrodeIDs.isEmpty,
              extracellularVolts.count.isMultiple(of: electrodeIDs.count),
              extracellularVolts.allSatisfy(\.isFinite) else {
            throw CultureTwinError.invalid("measurement input")
        }
        let interfaceByID = Dictionary(uniqueKeysWithValues: model.interfaces.map { ($0.electrode, $0) })
        guard electrodeIDs.allSatisfy({ interfaceByID[$0] != nil }) else {
            throw CultureTwinError.invalid("missing electrode interface")
        }
        let artifacts = try sourceArtifacts.map { try $0.validated() }
        let sampleCount = extracellularVolts.count / electrodeIDs.count
        let dt = 1 / sampleRateHertz
        var output = [Double](repeating: 0, count: extracellularVolts.count)
        var valid = [Bool](repeating: true, count: extracellularVolts.count)
        var lowPassState = [Double](repeating: 0, count: electrodeIDs.count)
        var highPassState = [Double](repeating: 0, count: electrodeIDs.count)
        var previousInput = [Double](repeating: 0, count: electrodeIDs.count)
        let lowPassRC = 1 / (2 * Double.pi * model.lowPassHertz)
        let lowAlpha = dt / (lowPassRC + dt)
        let highPassRC = model.highPassHertz > 0 ? 1 / (2 * Double.pi * model.highPassHertz) : 0
        let highAlpha = model.highPassHertz > 0 ? highPassRC / (highPassRC + dt) : 1

        for sample in 0..<sampleCount {
            let time = Double(sample) * dt
            var common = 0.0
            for channel in electrodeIDs.indices {
                common += extracellularVolts[sample * electrodeIDs.count + channel]
            }
            common /= Double(electrodeIDs.count)
            for channel in electrodeIDs.indices {
                let id = electrodeIDs[channel]
                guard let interface = interfaceByID[id] else { continue }
                var value = extracellularVolts[sample * electrodeIDs.count + channel]
                value -= model.commonModeRejection * common
                for artifact in artifacts where artifact.electrode == id && time >= artifact.startSeconds {
                    let elapsed = time - artifact.startSeconds
                    value += artifact.chargeCoulombs * artifact.couplingOhms / artifact.decaySeconds
                        * exp(-elapsed / artifact.decaySeconds)
                    if elapsed <= model.blankingSecondsAfterStimulus {
                        valid[sample * electrodeIDs.count + channel] = false
                    }
                }
                // Electrode RC is represented as a stable first-order low pass.
                let electrodeRC = max(
                    (interface.seriesResistanceOhms + interface.chargeTransferResistanceOhms)
                        * interface.doubleLayerCapacitanceFarads,
                    1e-12
                )
                let electrodeAlpha = dt / (electrodeRC + dt)
                lowPassState[channel] += electrodeAlpha * (value - lowPassState[channel])
                let acquisitionLP = lowPassState[channel]
                let filteredLP = previousInput[channel] + lowAlpha * (acquisitionLP - previousInput[channel])
                let filtered: Double
                if model.highPassHertz > 0 {
                    highPassState[channel] = highAlpha
                        * (highPassState[channel] + filteredLP - previousInput[channel])
                    filtered = highPassState[channel]
                } else {
                    filtered = filteredLP
                }
                previousInput[channel] = filteredLP
                let amplified = filtered * interface.gain + interface.offsetVolts
                output[sample * electrodeIDs.count + channel] = min(
                    max(amplified, interface.saturationVolts.lowerBound),
                    interface.saturationVolts.upperBound
                )
            }
        }
        return (output, valid)
    }
}
