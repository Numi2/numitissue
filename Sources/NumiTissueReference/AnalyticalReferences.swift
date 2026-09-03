import Foundation

public struct AnalyticalSeries: Sendable, Hashable, Codable {
    public var times: [Double]
    public var values: [Double]

    public init(times: [Double], values: [Double]) {
        precondition(times.count == values.count)
        self.times = times
        self.values = values
    }

    public func validated() throws -> Self {
        guard !times.isEmpty,
              times.count == values.count,
              times.allSatisfy(\.isFinite),
              values.allSatisfy(\.isFinite) else {
            throw AnalyticalReferenceError.invalidSeries
        }
        for index in times.indices.dropFirst() where times[index] <= times[index - 1] {
            throw AnalyticalReferenceError.nonMonotonicTime
        }
        return self
    }
}

public struct PassiveRCParameters: Sendable, Hashable, Codable {
    public var capacitanceNanofarads: Double
    public var leakConductanceMicrosiemens: Double
    public var leakReversalMillivolts: Double
    public var injectedCurrentNanoamps: Double
    public var initialVoltageMillivolts: Double

    public init(
        capacitanceNanofarads: Double,
        leakConductanceMicrosiemens: Double,
        leakReversalMillivolts: Double,
        injectedCurrentNanoamps: Double,
        initialVoltageMillivolts: Double
    ) {
        self.capacitanceNanofarads = capacitanceNanofarads
        self.leakConductanceMicrosiemens = leakConductanceMicrosiemens
        self.leakReversalMillivolts = leakReversalMillivolts
        self.injectedCurrentNanoamps = injectedCurrentNanoamps
        self.initialVoltageMillivolts = initialVoltageMillivolts
    }

    public func validated() throws -> Self {
        guard capacitanceNanofarads.isFinite,
              capacitanceNanofarads > 0,
              leakConductanceMicrosiemens.isFinite,
              leakConductanceMicrosiemens > 0,
              leakReversalMillivolts.isFinite,
              injectedCurrentNanoamps.isFinite,
              initialVoltageMillivolts.isFinite else {
            throw AnalyticalReferenceError.invalidPassiveRC
        }
        return self
    }

    public var timeConstantMilliseconds: Double {
        capacitanceNanofarads / leakConductanceMicrosiemens
    }

    public var steadyStateMillivolts: Double {
        leakReversalMillivolts + injectedCurrentNanoamps / leakConductanceMicrosiemens
    }
}

public struct HodgkinHuxleyGateState: Sendable, Hashable, Codable {
    public var m: Double
    public var h: Double
    public var n: Double

    public init(m: Double, h: Double, n: Double) {
        self.m = m
        self.h = h
        self.n = n
    }
}

public struct HodgkinHuxleyRates: Sendable, Hashable, Codable {
    public var alphaM: Double
    public var betaM: Double
    public var alphaH: Double
    public var betaH: Double
    public var alphaN: Double
    public var betaN: Double

    public init(
        alphaM: Double,
        betaM: Double,
        alphaH: Double,
        betaH: Double,
        alphaN: Double,
        betaN: Double
    ) {
        self.alphaM = alphaM
        self.betaM = betaM
        self.alphaH = alphaH
        self.betaH = betaH
        self.alphaN = alphaN
        self.betaN = betaN
    }
}

public enum NumiTissueAnalyticalReferences {
    public static func passiveRCExact(
        parameters source: PassiveRCParameters,
        durationMilliseconds: Double,
        stepMilliseconds: Double
    ) throws -> AnalyticalSeries {
        let parameters = try source.validated()
        let sampleCount = try validatedSampleCount(
            duration: durationMilliseconds,
            step: stepMilliseconds
        )
        let steady = parameters.steadyStateMillivolts
        let tau = parameters.timeConstantMilliseconds
        var times: [Double] = []
        var values: [Double] = []
        times.reserveCapacity(sampleCount + 1)
        values.reserveCapacity(sampleCount + 1)
        for sample in 0...sampleCount {
            let time = Double(sample) * stepMilliseconds
            times.append(time)
            values.append(
                steady + (parameters.initialVoltageMillivolts - steady) * exp(-time / tau)
            )
        }
        return AnalyticalSeries(times: times, values: values)
    }

    public static func passiveRCBackwardEuler(
        parameters source: PassiveRCParameters,
        durationMilliseconds: Double,
        stepMilliseconds: Double
    ) throws -> AnalyticalSeries {
        let parameters = try source.validated()
        let sampleCount = try validatedSampleCount(
            duration: durationMilliseconds,
            step: stepMilliseconds
        )
        let cOverDt = parameters.capacitanceNanofarads / stepMilliseconds
        let denominator = cOverDt + parameters.leakConductanceMicrosiemens
        var voltage = parameters.initialVoltageMillivolts
        var times = [0.0]
        var values = [voltage]
        times.reserveCapacity(sampleCount + 1)
        values.reserveCapacity(sampleCount + 1)
        for sample in 1...sampleCount {
            voltage = (
                cOverDt * voltage +
                parameters.leakConductanceMicrosiemens * parameters.leakReversalMillivolts +
                parameters.injectedCurrentNanoamps
            ) / denominator
            times.append(Double(sample) * stepMilliseconds)
            values.append(voltage)
        }
        return AnalyticalSeries(times: times, values: values)
    }

    public static func firstOrderDecayExact(
        initialAmount: Double,
        ratePerSecond: Double,
        durationSeconds: Double,
        stepSeconds: Double
    ) throws -> AnalyticalSeries {
        guard initialAmount.isFinite, initialAmount >= 0,
              ratePerSecond.isFinite, ratePerSecond >= 0 else {
            throw AnalyticalReferenceError.invalidReaction
        }
        let sampleCount = try validatedSampleCount(
            duration: durationSeconds,
            step: stepSeconds
        )
        let times = (0...sampleCount).map { Double($0) * stepSeconds }
        let values = times.map { initialAmount * exp(-ratePerSecond * $0) }
        return AnalyticalSeries(times: times, values: values)
    }

    public static func firstOrderDecayForwardEuler(
        initialAmount: Double,
        ratePerSecond: Double,
        durationSeconds: Double,
        stepSeconds: Double
    ) throws -> AnalyticalSeries {
        guard initialAmount.isFinite, initialAmount >= 0,
              ratePerSecond.isFinite, ratePerSecond >= 0,
              ratePerSecond * stepSeconds <= 1 else {
            throw AnalyticalReferenceError.invalidReaction
        }
        let sampleCount = try validatedSampleCount(
            duration: durationSeconds,
            step: stepSeconds
        )
        var amount = initialAmount
        var times = [0.0]
        var values = [amount]
        times.reserveCapacity(sampleCount + 1)
        values.reserveCapacity(sampleCount + 1)
        for sample in 1...sampleCount {
            amount = max(amount * (1 - ratePerSecond * stepSeconds), 0)
            times.append(Double(sample) * stepSeconds)
            values.append(amount)
        }
        return AnalyticalSeries(times: times, values: values)
    }

    public static func exponentialConductance(
        initial: Double,
        tauMilliseconds: Double,
        durationMilliseconds: Double,
        stepMilliseconds: Double
    ) throws -> AnalyticalSeries {
        guard initial.isFinite, initial >= 0,
              tauMilliseconds.isFinite, tauMilliseconds > 0 else {
            throw AnalyticalReferenceError.invalidSynapse
        }
        let sampleCount = try validatedSampleCount(
            duration: durationMilliseconds,
            step: stepMilliseconds
        )
        let times = (0...sampleCount).map { Double($0) * stepMilliseconds }
        let values = times.map { initial * exp(-$0 / tauMilliseconds) }
        return AnalyticalSeries(times: times, values: values)
    }

    public static func hodgkinHuxleyRates(
        voltageMillivolts voltage: Double
    ) throws -> HodgkinHuxleyRates {
        guard voltage.isFinite else {
            throw AnalyticalReferenceError.invalidVoltage
        }
        return HodgkinHuxleyRates(
            alphaM: 0.1 * vtrap(-(voltage + 40), 10),
            betaM: 4 * exp(-(voltage + 65) / 18),
            alphaH: 0.07 * exp(-(voltage + 65) / 20),
            betaH: 1 / (exp(-(voltage + 35) / 10) + 1),
            alphaN: 0.01 * vtrap(-(voltage + 55), 10),
            betaN: 0.125 * exp(-(voltage + 65) / 80)
        )
    }

    public static func hodgkinHuxleyRushLarsen(
        state: HodgkinHuxleyGateState,
        voltageMillivolts: Double,
        stepMilliseconds: Double
    ) throws -> HodgkinHuxleyGateState {
        guard stepMilliseconds.isFinite, stepMilliseconds > 0,
              [state.m, state.h, state.n].allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }) else {
            throw AnalyticalReferenceError.invalidGateState
        }
        let rates = try hodgkinHuxleyRates(voltageMillivolts: voltageMillivolts)
        return HodgkinHuxleyGateState(
            m: rushLarsen(state.m, alpha: rates.alphaM, beta: rates.betaM, dt: stepMilliseconds),
            h: rushLarsen(state.h, alpha: rates.alphaH, beta: rates.betaH, dt: stepMilliseconds),
            n: rushLarsen(state.n, alpha: rates.alphaN, beta: rates.betaN, dt: stepMilliseconds)
        )
    }

    public static func solveSymmetricTwoCompartment(
        diagonal0: Double,
        diagonal1: Double,
        axial: Double,
        rhs0: Double,
        rhs1: Double
    ) throws -> (Double, Double) {
        guard [diagonal0, diagonal1, axial, rhs0, rhs1].allSatisfy(\.isFinite),
              diagonal0 > 0, diagonal1 > 0, axial >= 0 else {
            throw AnalyticalReferenceError.invalidLinearSystem
        }
        let determinant = diagonal0 * diagonal1 - axial * axial
        guard determinant > Double.ulpOfOne else {
            throw AnalyticalReferenceError.singularLinearSystem
        }
        return (
            (rhs0 * diagonal1 + axial * rhs1) / determinant,
            (rhs1 * diagonal0 + axial * rhs0) / determinant
        )
    }

    private static func validatedSampleCount(duration: Double, step: Double) throws -> Int {
        guard duration.isFinite, duration > 0,
              step.isFinite, step > 0,
              duration / step <= Double(Int.max) else {
            throw AnalyticalReferenceError.invalidTimeGrid
        }
        let ratio = duration / step
        let rounded = ratio.rounded()
        guard abs(ratio - rounded) <= 1e-10 * max(1, abs(ratio)) else {
            throw AnalyticalReferenceError.nonIntegralTimeGrid
        }
        return Int(rounded)
    }

    private static func rushLarsen(
        _ state: Double,
        alpha: Double,
        beta: Double,
        dt: Double
    ) -> Double {
        let sum = max(alpha + beta, Double.leastNonzeroMagnitude)
        let steady = alpha / sum
        return min(max(steady + (state - steady) * exp(-sum * dt), 0), 1)
    }

    private static func vtrap(_ x: Double, _ y: Double) -> Double {
        let ratio = x / y
        if abs(ratio) < 1e-7 { return y * (1 - ratio / 2) }
        return x / expm1(ratio)
    }
}

public enum AnalyticalReferenceError: Error, Sendable, CustomStringConvertible {
    case invalidSeries
    case nonMonotonicTime
    case invalidPassiveRC
    case invalidReaction
    case invalidSynapse
    case invalidVoltage
    case invalidGateState
    case invalidLinearSystem
    case singularLinearSystem
    case invalidTimeGrid
    case nonIntegralTimeGrid

    public var description: String {
        switch self {
        case .invalidSeries: return "Analytical series is empty, non-finite, or dimensionally invalid."
        case .nonMonotonicTime: return "Analytical series time is not strictly increasing."
        case .invalidPassiveRC: return "Passive RC parameters are invalid."
        case .invalidReaction: return "Analytical reaction parameters are invalid."
        case .invalidSynapse: return "Analytical synapse parameters are invalid."
        case .invalidVoltage: return "Membrane voltage is invalid."
        case .invalidGateState: return "Hodgkin-Huxley gate state is invalid."
        case .invalidLinearSystem: return "Two-compartment linear system is invalid."
        case .singularLinearSystem: return "Two-compartment linear system is singular."
        case .invalidTimeGrid: return "Analytical time grid is invalid."
        case .nonIntegralTimeGrid: return "Duration must be an integer multiple of the step."
        }
    }
}
