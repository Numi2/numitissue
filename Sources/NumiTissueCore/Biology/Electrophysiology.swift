import Foundation

@frozen
public struct NTMechanismSetParameters: Codable, Hashable, Sendable {
    public var sodiumDensityMicrosiemensPerSquareMicrometer: Float
    public var potassiumDensityMicrosiemensPerSquareMicrometer: Float
    public var leakDensityMicrosiemensPerSquareMicrometer: Float
    public var calciumLDensityMicrosiemensPerSquareMicrometer: Float
    public var calciumTDensityMicrosiemensPerSquareMicrometer: Float
    public var calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer: Float
    public var hcnDensityMicrosiemensPerSquareMicrometer: Float
    public var mCurrentDensityMicrosiemensPerSquareMicrometer: Float
    public var optogeneticDensityMicrosiemensPerSquareMicrometer: Float
    public var leakReversalMillivolts: Float
    public var hcnReversalMillivolts: Float
    public var chlorideReversalMillivolts: Float
    public var extracellularSodiumMillimolar: Float
    public var extracellularPotassiumMillimolar: Float
    public var extracellularCalciumMillimolar: Float
    public var calciumRestMicromolar: Float
    public var calciumDecayMilliseconds: Float
    public var calciumCurrentToConcentration: Float
    public var temperatureQ10: Float
    public var referenceTemperatureCelsius: Float

    public init(
        sodiumDensityMicrosiemensPerSquareMicrometer: Float = 0.0012,
        potassiumDensityMicrosiemensPerSquareMicrometer: Float = 0.00036,
        leakDensityMicrosiemensPerSquareMicrometer: Float = 0.000003,
        calciumLDensityMicrosiemensPerSquareMicrometer: Float = 0.00001,
        calciumTDensityMicrosiemensPerSquareMicrometer: Float = 0.000004,
        calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer: Float = 0.00002,
        hcnDensityMicrosiemensPerSquareMicrometer: Float = 0.000002,
        mCurrentDensityMicrosiemensPerSquareMicrometer: Float = 0.00001,
        optogeneticDensityMicrosiemensPerSquareMicrometer: Float = 0,
        leakReversalMillivolts: Float = -65,
        hcnReversalMillivolts: Float = -35,
        chlorideReversalMillivolts: Float = -75,
        extracellularSodiumMillimolar: Float = 145,
        extracellularPotassiumMillimolar: Float = 3.5,
        extracellularCalciumMillimolar: Float = 2,
        calciumRestMicromolar: Float = 0.05,
        calciumDecayMilliseconds: Float = 80,
        calciumCurrentToConcentration: Float = 0.002,
        temperatureQ10: Float = 2.3,
        referenceTemperatureCelsius: Float = 6.3
    ) {
        self.sodiumDensityMicrosiemensPerSquareMicrometer = sodiumDensityMicrosiemensPerSquareMicrometer
        self.potassiumDensityMicrosiemensPerSquareMicrometer = potassiumDensityMicrosiemensPerSquareMicrometer
        self.leakDensityMicrosiemensPerSquareMicrometer = leakDensityMicrosiemensPerSquareMicrometer
        self.calciumLDensityMicrosiemensPerSquareMicrometer = calciumLDensityMicrosiemensPerSquareMicrometer
        self.calciumTDensityMicrosiemensPerSquareMicrometer = calciumTDensityMicrosiemensPerSquareMicrometer
        self.calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer = calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer
        self.hcnDensityMicrosiemensPerSquareMicrometer = hcnDensityMicrosiemensPerSquareMicrometer
        self.mCurrentDensityMicrosiemensPerSquareMicrometer = mCurrentDensityMicrosiemensPerSquareMicrometer
        self.optogeneticDensityMicrosiemensPerSquareMicrometer = optogeneticDensityMicrosiemensPerSquareMicrometer
        self.leakReversalMillivolts = leakReversalMillivolts
        self.hcnReversalMillivolts = hcnReversalMillivolts
        self.chlorideReversalMillivolts = chlorideReversalMillivolts
        self.extracellularSodiumMillimolar = extracellularSodiumMillimolar
        self.extracellularPotassiumMillimolar = extracellularPotassiumMillimolar
        self.extracellularCalciumMillimolar = extracellularCalciumMillimolar
        self.calciumRestMicromolar = calciumRestMicromolar
        self.calciumDecayMilliseconds = calciumDecayMilliseconds
        self.calciumCurrentToConcentration = calciumCurrentToConcentration
        self.temperatureQ10 = temperatureQ10
        self.referenceTemperatureCelsius = referenceTemperatureCelsius
    }

    public static let passive = NTMechanismSetParameters(
        sodiumDensityMicrosiemensPerSquareMicrometer: 0,
        potassiumDensityMicrosiemensPerSquareMicrometer: 0,
        calciumLDensityMicrosiemensPerSquareMicrometer: 0,
        calciumTDensityMicrosiemensPerSquareMicrometer: 0,
        calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer: 0,
        hcnDensityMicrosiemensPerSquareMicrometer: 0,
        mCurrentDensityMicrosiemensPerSquareMicrometer: 0
    )
}

public struct NTElectrophysiologyLibrary: Codable, Sendable {
    public var mechanismSets: [UInt16: NTMechanismSetParameters]

    public init(mechanismSets: [UInt16: NTMechanismSetParameters] = [0: .passive, 1: .init()]) {
        self.mechanismSets = mechanismSets
    }

    public func parameters(for index: UInt16) -> NTMechanismSetParameters {
        mechanismSets[index] ?? mechanismSets[0] ?? .passive
    }

    public static let corticalDefault = NTElectrophysiologyLibrary(mechanismSets: [
        0: .passive,
        1: .init(),
        2: .init(
            sodiumDensityMicrosiemensPerSquareMicrometer: 0.0010,
            potassiumDensityMicrosiemensPerSquareMicrometer: 0.00030,
            calciumLDensityMicrosiemensPerSquareMicrometer: 0.000015,
            hcnDensityMicrosiemensPerSquareMicrometer: 0.000006,
            mCurrentDensityMicrosiemensPerSquareMicrometer: 0.000018,
            leakReversalMillivolts: -67
        ),
        3: .init(
            sodiumDensityMicrosiemensPerSquareMicrometer: 0.0015,
            potassiumDensityMicrosiemensPerSquareMicrometer: 0.00045,
            calciumTDensityMicrosiemensPerSquareMicrometer: 0.000010,
            hcnDensityMicrosiemensPerSquareMicrometer: 0.000001,
            mCurrentDensityMicrosiemensPerSquareMicrometer: 0.000004,
            leakReversalMillivolts: -63
        )
    ])
}

@frozen
public struct NTMembraneStepResult: Sendable {
    public var spikes: [NTSpike]
    public var routedEvents: [NTNeuralEvent]
    public var ionicEnergyPicojoules: Float
    public var diagnostics: [NTDiagnostic]

    public init(
        spikes: [NTSpike] = [],
        routedEvents: [NTNeuralEvent] = [],
        ionicEnergyPicojoules: Float = 0,
        diagnostics: [NTDiagnostic] = []
    ) {
        self.spikes = spikes
        self.routedEvents = routedEvents
        self.ionicEnergyPicojoules = ionicEnergyPicojoules
        self.diagnostics = diagnostics
    }
}

public struct NTElectrophysiologyEngine: Sendable {
    public var library: NTElectrophysiologyLibrary
    public var refractoryTicks: UInt64

    public init(library: NTElectrophysiologyLibrary = .corticalDefault, refractoryTicks: UInt64 = 80) {
        self.library = library
        self.refractoryTicks = refractoryTicks
    }

    public func step(
        state: inout NTProductionState,
        currentTime: TissueTime,
        deltaTicks: UInt64,
        transaction: TransactionID,
        activeCurrentsNanoamps: [UInt64: Float],
        optogeneticDrive: [UInt64: Float] = [:]
    ) -> NTMembraneStepResult {
        guard !state.compartments.isEmpty, deltaTicks > 0 else { return .init() }
        let count = state.compartments.count
        let deltaMilliseconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 0.001
        var diagonal = Array(repeating: Float.zero, count: count)
        var rightHandSide = Array(repeating: Float.zero, count: count)
        var parentCoupling = Array(repeating: Float.zero, count: count)
        var diagnostics: [NTDiagnostic] = []
        var totalEnergy: Float = 0

        for index in 0..<count {
            var compartment = state.compartments[index]
            let record = compartment.record
            let parameters = library.parameters(for: record.mechanismSet)
            let temperatureCelsius = temperatureCelsius(for: record.tile, state: state)
            let rateScale = pow(parameters.temperatureQ10, (temperatureCelsius - parameters.referenceTemperatureCelsius) / 10)
            let voltage = record.membraneVoltageMillivolts
            let area = membraneArea(length: record.lengthMicrometers, diameter: record.diameterMicrometers)

            updateGates(
                gates: &compartment.gates,
                voltageMillivolts: voltage,
                calciumMicromolar: record.calciumMicromolar,
                optogeneticDrive: optogeneticDrive[record.id.rawValue, default: 0],
                deltaMilliseconds: deltaMilliseconds,
                rateScale: rateScale
            )

            let reversals = reversalPotentials(record: record, parameters: parameters, temperatureCelsius: temperatureCelsius)
            let conductances = channelConductances(gates: compartment.gates, parameters: parameters, area: area)
            let channelTotal = conductances.sodium + conductances.potassium + conductances.leak +
                conductances.calciumL + conductances.calciumT + conductances.calciumActivatedPotassium +
                conductances.hcn + conductances.mCurrent + conductances.optogenetic
            let reversalWeighted = conductances.sodium * reversals.sodium +
                conductances.potassium * reversals.potassium +
                conductances.leak * parameters.leakReversalMillivolts +
                (conductances.calciumL + conductances.calciumT) * reversals.calcium +
                conductances.calciumActivatedPotassium * reversals.potassium +
                conductances.hcn * parameters.hcnReversalMillivolts +
                conductances.mCurrent * reversals.potassium +
                conductances.optogenetic * 0

            let excitatory = max(0, compartment.synapticConductanceExcitatory)
            let inhibitory = max(0, compartment.synapticConductanceInhibitory)
            let capacitance = max(record.capacitanceNanofarads, 1.0e-9)
            let capacitanceOverDt = capacitance / max(deltaMilliseconds, 1.0e-9)
            var axialTotal: Float = 0
            if record.parentIndex >= 0 {
                let coupling = max(0, record.axialConductanceMicrosiemens)
                parentCoupling[index] = coupling
                axialTotal += coupling
            }
            for child in 0..<count where state.compartments[child].record.parentIndex == Int32(index) {
                axialTotal += max(0, state.compartments[child].record.axialConductanceMicrosiemens)
            }

            diagonal[index] = capacitanceOverDt + channelTotal + excitatory + inhibitory + axialTotal
            let directCurrent = record.injectedCurrentNanoamps + activeCurrentsNanoamps[record.id.rawValue, default: 0]
            rightHandSide[index] = capacitanceOverDt * voltage + reversalWeighted +
                excitatory * 0 + inhibitory * parameters.chlorideReversalMillivolts + directCurrent

            let sodiumCurrent = conductances.sodium * (voltage - reversals.sodium)
            let potassiumCurrent = (conductances.potassium + conductances.calciumActivatedPotassium + conductances.mCurrent) * (voltage - reversals.potassium)
            let calciumCurrent = (conductances.calciumL + conductances.calciumT) * (voltage - reversals.calcium)
            let leakCurrent = conductances.leak * (voltage - parameters.leakReversalMillivolts)
            let hcnCurrent = conductances.hcn * (voltage - parameters.hcnReversalMillivolts)
            let optogeneticCurrent = conductances.optogenetic * voltage
            compartment.ionicCurrentNanoamps = sodiumCurrent + potassiumCurrent + calciumCurrent + leakCurrent + hcnCurrent + optogeneticCurrent
            compartment.calciumFluxMicromolarPerSecond = -parameters.calciumCurrentToConcentration * calciumCurrent * 1_000
            compartment.energyCostPicojoules = (abs(sodiumCurrent) + abs(potassiumCurrent) + abs(calciumCurrent)) * abs(voltage) * deltaMilliseconds
            totalEnergy += compartment.energyCostPicojoules
            state.compartments[index] = compartment
        }

        let eliminationOrder = (0..<count).sorted {
            let left = state.compartments[$0].record.level
            let right = state.compartments[$1].record.level
            return left == right ? $0 > $1 : left > right
        }
        for child in eliminationOrder {
            let parent = Int(state.compartments[child].record.parentIndex)
            guard parent >= 0 else { continue }
            guard parent < count else {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .invalidMorphology,
                    message: "Compartment parent index is out of range during Hines elimination.",
                    entity: state.compartments[child].record.id.rawValue,
                    tile: state.compartments[child].record.tile
                ))
                continue
            }
            let pivot = diagonal[child]
            guard pivot.isFinite, pivot > 1.0e-12 else {
                diagnostics.append(.init(
                    severity: .fatal,
                    code: .nonFiniteState,
                    message: "Compartment matrix has a nonpositive or non-finite pivot.",
                    entity: state.compartments[child].record.id.rawValue,
                    tile: state.compartments[child].record.tile
                ))
                continue
            }
            let coupling = parentCoupling[child]
            diagonal[parent] -= coupling * coupling / pivot
            rightHandSide[parent] += coupling * rightHandSide[child] / pivot
        }

        var solvedVoltage = Array(repeating: Float.zero, count: count)
        let forwardOrder = (0..<count).sorted {
            let left = state.compartments[$0].record.level
            let right = state.compartments[$1].record.level
            return left == right ? $0 < $1 : left < right
        }
        for index in forwardOrder {
            let parent = Int(state.compartments[index].record.parentIndex)
            let numerator = parent >= 0 && parent < count
                ? rightHandSide[index] + parentCoupling[index] * solvedVoltage[parent]
                : rightHandSide[index]
            let pivot = diagonal[index]
            if pivot.isFinite, pivot > 1.0e-12 {
                solvedVoltage[index] = numerator / pivot
            } else {
                solvedVoltage[index] = state.compartments[index].record.membraneVoltageMillivolts
            }
        }

        var spikes: [NTSpike] = []
        var routedEvents: [NTNeuralEvent] = []
        for index in 0..<count {
            var compartment = state.compartments[index]
            let previous = compartment.record.membraneVoltageMillivolts
            let next = solvedVoltage[index]
            compartment.previousVoltageMillivolts = previous
            compartment.record.membraneVoltageMillivolts = next
            let parameters = library.parameters(for: compartment.record.mechanismSet)
            let calciumDelta = compartment.calciumFluxMicromolarPerSecond * (deltaMilliseconds * 0.001) -
                (compartment.record.calciumMicromolar - parameters.calciumRestMicromolar) *
                deltaMilliseconds / max(parameters.calciumDecayMilliseconds, 1.0e-3)
            compartment.record.calciumMicromolar = max(0, compartment.record.calciumMicromolar + calciumDelta)

            let canSpike = currentTime >= compartment.record.refractoryUntil
            let crossed = previous < compartment.spikeThresholdMillivolts && next >= compartment.spikeThresholdMillivolts
            if canSpike && crossed {
                let fraction = max(0, min(1, (compartment.spikeThresholdMillivolts - previous) / max(next - previous, 1.0e-9)))
                let offset = UInt64((Float(deltaTicks) * fraction).rounded(.toNearestOrAwayFromZero))
                let spikeTime = TissueTime(tick: currentTime.tick &+ min(offset, deltaTicks))
                compartment.lastSpike = spikeTime
                compartment.record.refractoryUntil = TissueTime(tick: spikeTime.tick &+ refractoryTicks)
                compartment.spikeCountWindow &+= 1

                let routeIndices = state.routeTable.routeIndices(sourceCompartmentIndex: index)
                if routeIndices.isEmpty {
                    spikes.append(.init(
                        time: spikeTime,
                        sourceCompartment: compartment.record.id,
                        route: .init(rawValue: 0)
                    ))
                } else {
                    for routeIndex in routeIndices {
                        let route = state.routeTable.routes[Int(routeIndex)]
                        let random = CounterRandom.generate(
                            counter: RandomAddress(
                                transaction: transaction.rawValue,
                                entity: route.id.rawValue,
                                stream: UInt32(truncatingIfNeeded: currentTime.tick),
                                sample: UInt32(index)
                            ).counter(),
                            key: PhiloxKey(seed: state.configuration.seed)
                        )
                        if CounterRandom.uniform01(random.x) < route.failureProbability { continue }
                        let amplitude = route.amplitudeScale
                        spikes.append(.init(
                            time: spikeTime,
                            sourceCompartment: compartment.record.id,
                            route: route.id,
                            amplitude: amplitude
                        ))
                        let first = Int(route.destinationSynapseStart)
                        let end = min(state.synapses.count, first + Int(route.destinationSynapseCount))
                        if first < end {
                            for synapseIndex in first..<end {
                                routedEvents.append(.init(
                                    deliveryTime: TissueTime(tick: spikeTime.tick &+ UInt64(route.delayTicks)),
                                    kind: .synapticRelease,
                                    source: compartment.record.id.rawValue,
                                    destination: UInt64(synapseIndex),
                                    route: route.id,
                                    payload0: amplitude,
                                    sequence: (transaction.rawValue << 32) ^ UInt64(synapseIndex)
                                ))
                            }
                        }
                    }
                }
            }
            state.compartments[index] = compartment
        }

        spikes.sort()
        routedEvents.sort()
        return NTMembraneStepResult(
            spikes: spikes,
            routedEvents: routedEvents,
            ionicEnergyPicojoules: totalEnergy,
            diagnostics: diagnostics
        )
    }

    private func updateGates(
        gates: inout NTGateState,
        voltageMillivolts v: Float,
        calciumMicromolar: Float,
        optogeneticDrive: Float,
        deltaMilliseconds dt: Float,
        rateScale: Float
    ) {
        let alphaM = 0.1 * vTrap(-(v + 40), 10)
        let betaM = 4 * exp(-(v + 65) / 18)
        let alphaH = 0.07 * exp(-(v + 65) / 20)
        let betaH = 1 / (1 + exp(-(v + 35) / 10))
        let alphaN = 0.01 * vTrap(-(v + 55), 10)
        let betaN = 0.125 * exp(-(v + 65) / 80)
        gates.sodiumActivation = rushLarsen(gates.sodiumActivation, alpha: alphaM, beta: betaM, dt: dt, scale: rateScale)
        gates.sodiumInactivation = rushLarsen(gates.sodiumInactivation, alpha: alphaH, beta: betaH, dt: dt, scale: rateScale)
        gates.potassiumActivation = rushLarsen(gates.potassiumActivation, alpha: alphaN, beta: betaN, dt: dt, scale: rateScale)

        gates.calciumLActivation = relax(gates.calciumLActivation, target: sigmoid((v + 20) / 6.5), tau: 1.5 / rateScale, dt: dt)
        gates.calciumLInactivation = relax(gates.calciumLInactivation, target: sigmoid(-(v + 25) / 12), tau: 30 / rateScale, dt: dt)
        gates.calciumTActivation = relax(gates.calciumTActivation, target: sigmoid((v + 57) / 6.2), tau: 3 / rateScale, dt: dt)
        gates.calciumTInactivation = relax(gates.calciumTInactivation, target: sigmoid(-(v + 81) / 4), tau: 20 / rateScale, dt: dt)
        gates.hcnActivation = relax(gates.hcnActivation, target: sigmoid(-(v + 82) / 8), tau: 80 / rateScale, dt: dt)
        gates.mActivation = relax(gates.mActivation, target: sigmoid((v + 35) / 10), tau: 40 / rateScale, dt: dt)
        gates.calciumActivatedPotassium = relax(
            gates.calciumActivatedPotassium,
            target: calciumMicromolar / (calciumMicromolar + 0.3),
            tau: 5 / rateScale,
            dt: dt
        )
        gates.optogeneticOpen = relax(
            gates.optogeneticOpen,
            target: max(0, min(1, optogeneticDrive)),
            tau: optogeneticDrive > gates.optogeneticOpen ? 1.5 : 10,
            dt: dt
        )
    }

    private func channelConductances(
        gates: NTGateState,
        parameters: NTMechanismSetParameters,
        area: Float
    ) -> (sodium: Float, potassium: Float, leak: Float, calciumL: Float, calciumT: Float,
          calciumActivatedPotassium: Float, hcn: Float, mCurrent: Float, optogenetic: Float) {
        (
            parameters.sodiumDensityMicrosiemensPerSquareMicrometer * area *
                pow(gates.sodiumActivation, 3) * gates.sodiumInactivation,
            parameters.potassiumDensityMicrosiemensPerSquareMicrometer * area * pow(gates.potassiumActivation, 4),
            parameters.leakDensityMicrosiemensPerSquareMicrometer * area,
            parameters.calciumLDensityMicrosiemensPerSquareMicrometer * area *
                gates.calciumLActivation * gates.calciumLActivation * gates.calciumLInactivation,
            parameters.calciumTDensityMicrosiemensPerSquareMicrometer * area *
                gates.calciumTActivation * gates.calciumTActivation * gates.calciumTInactivation,
            parameters.calciumActivatedPotassiumDensityMicrosiemensPerSquareMicrometer * area *
                gates.calciumActivatedPotassium,
            parameters.hcnDensityMicrosiemensPerSquareMicrometer * area * gates.hcnActivation,
            parameters.mCurrentDensityMicrosiemensPerSquareMicrometer * area * gates.mActivation,
            parameters.optogeneticDensityMicrosiemensPerSquareMicrometer * area * gates.optogeneticOpen
        )
    }

    private func reversalPotentials(
        record: NTCompartmentRecord,
        parameters: NTMechanismSetParameters,
        temperatureCelsius: Float
    ) -> (sodium: Float, potassium: Float, calcium: Float) {
        let temperatureKelvin = temperatureCelsius + 273.15
        let rtOverFMillivolts = 8.314_462_6 * temperatureKelvin / 96_485.33 * 1_000
        let sodium = rtOverFMillivolts * log(max(parameters.extracellularSodiumMillimolar, 1.0e-8) / max(record.sodiumMillimolar, 1.0e-8))
        let potassium = rtOverFMillivolts * log(max(parameters.extracellularPotassiumMillimolar, 1.0e-8) / max(record.potassiumMillimolar, 1.0e-8))
        let intracellularCalciumMillimolar = max(record.calciumMicromolar * 0.001, 1.0e-12)
        let calcium = 0.5 * rtOverFMillivolts * log(max(parameters.extracellularCalciumMillimolar, 1.0e-8) / intracellularCalciumMillimolar)
        return (sodium, potassium, calcium)
    }

    private func temperatureCelsius(for tile: TileID, state: NTProductionState) -> Float {
        if let encoded = state.metadata["tile.\(tile.rawValue).temperatureKelvin"], let kelvin = Float(encoded) {
            return kelvin - 273.15
        }
        return 37
    }

    @inline(__always)
    private func membraneArea(length: Float, diameter: Float) -> Float {
        let safeLength = max(length, 1.0e-4)
        let safeDiameter = max(diameter, 1.0e-4)
        return Float.pi * safeDiameter * safeLength + 0.5 * Float.pi * safeDiameter * safeDiameter
    }

    @inline(__always)
    private func vTrap(_ x: Float, _ y: Float) -> Float {
        let ratio = x / y
        if abs(ratio) < 1.0e-6 { return y * (1 - ratio / 2) }
        return x / (exp(ratio) - 1)
    }

    @inline(__always)
    private func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    @inline(__always)
    private func rushLarsen(_ value: Float, alpha: Float, beta: Float, dt: Float, scale: Float) -> Float {
        let total = max((alpha + beta) * scale, 1.0e-9)
        let target = alpha / max(alpha + beta, 1.0e-9)
        return max(0, min(1, target + (value - target) * exp(-dt * total)))
    }

    @inline(__always)
    private func relax(_ value: Float, target: Float, tau: Float, dt: Float) -> Float {
        max(0, min(1, target + (value - target) * exp(-dt / max(tau, 1.0e-6))))
    }
}
