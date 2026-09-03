import Foundation
import NumiTissueCore
import NumiTissueRuntime

public struct NeuralProjectionBundle: Sendable, Hashable, Codable {
    public var events: [RoutedEvent]
    public var analogChannels: [Float]
    public var routeNamespace: UInt64

    public init(events: [RoutedEvent] = [], analogChannels: [Float] = [], routeNamespace: UInt64 = 0) {
        self.events = events
        self.analogChannels = analogChannels
        self.routeNamespace = routeNamespace
    }
}

public struct TissueChemicalBoundary: Sendable, Hashable, Codable {
    public var oxygen: Float
    public var glucose: Float
    public var lactate: Float
    public var extracellularPotassium: Float
    public var extracellularCalcium: Float
    public var temperatureKelvin: Float
    public var pH: Float
    public var perfusion: Float

    public init(
        oxygen: Float = 0.2,
        glucose: Float = 1,
        lactate: Float = 0,
        extracellularPotassium: Float = 3.5,
        extracellularCalcium: Float = 1.2,
        temperatureKelvin: Float = 310.15,
        pH: Float = 7.4,
        perfusion: Float = 1
    ) {
        self.oxygen = oxygen
        self.glucose = glucose
        self.lactate = lactate
        self.extracellularPotassium = extracellularPotassium
        self.extracellularCalcium = extracellularCalcium
        self.temperatureKelvin = temperatureKelvin
        self.pH = pH
        self.perfusion = perfusion
    }
}

public struct TissueMechanicalBoundary: Sendable, Hashable, Codable {
    public var deformationGradient: SIMD16<Float>
    public var strain: SIMD6<Float>
    public var stress: SIMD6<Float>
    public var pressure: Float
    public var damage: Float
    public var temperatureKelvin: Float
    public var boundaryVelocity: SIMD3<Float>
    public var worldTransform: SIMD16<Float>

    public init(
        deformationGradient: SIMD16<Float> = Self.identity4x4,
        strain: SIMD6<Float> = .zero,
        stress: SIMD6<Float> = .zero,
        pressure: Float = 0,
        damage: Float = 0,
        temperatureKelvin: Float = 310.15,
        boundaryVelocity: SIMD3<Float> = .zero,
        worldTransform: SIMD16<Float> = Self.identity4x4
    ) {
        self.deformationGradient = deformationGradient
        self.strain = strain
        self.stress = stress
        self.pressure = pressure
        self.damage = damage
        self.temperatureKelvin = temperatureKelvin
        self.boundaryVelocity = boundaryVelocity
        self.worldTransform = worldTransform
    }

    public static let identity4x4 = SIMD16<Float>(
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    )
}

public struct NumanXObservationFrame: Sendable, Hashable, Codable {
    public var time: TissueTime
    public var proprioception: [Float]
    public var touch: [Float]
    public var vestibular: [Float]
    public var interoception: [Float]
    public var sensoryEvents: [RoutedEvent]
    public var chemicalBoundary: TissueChemicalBoundary
    public var mechanicalBoundary: TissueMechanicalBoundary
    public var injuryEvents: [RoutedEvent]

    public init(
        time: TissueTime,
        proprioception: [Float] = [],
        touch: [Float] = [],
        vestibular: [Float] = [],
        interoception: [Float] = [],
        sensoryEvents: [RoutedEvent] = [],
        chemicalBoundary: TissueChemicalBoundary = TissueChemicalBoundary(),
        mechanicalBoundary: TissueMechanicalBoundary = TissueMechanicalBoundary(),
        injuryEvents: [RoutedEvent] = []
    ) {
        self.time = time
        self.proprioception = proprioception
        self.touch = touch
        self.vestibular = vestibular
        self.interoception = interoception
        self.sensoryEvents = sensoryEvents
        self.chemicalBoundary = chemicalBoundary
        self.mechanicalBoundary = mechanicalBoundary
        self.injuryEvents = injuryEvents
    }
}

public struct NumiBrainTissueCommand: Sendable, Hashable, Codable {
    public var afferentProjection: NeuralProjectionBundle
    public var neuromodulators: SIMD8<Float>
    public var hormones: SIMD8<Float>
    public var stimulation: [TissueStimulus]
    public var attentionMask: [Float]
    public var targetFidelity: [UInt8]

    public init(
        afferentProjection: NeuralProjectionBundle = NeuralProjectionBundle(),
        neuromodulators: SIMD8<Float> = .zero,
        hormones: SIMD8<Float> = .zero,
        stimulation: [TissueStimulus] = [],
        attentionMask: [Float] = [],
        targetFidelity: [UInt8] = []
    ) {
        self.afferentProjection = afferentProjection
        self.neuromodulators = neuromodulators
        self.hormones = hormones
        self.stimulation = stimulation
        self.attentionMask = attentionMask
        self.targetFidelity = targetFidelity
    }
}

public struct NumiBrainMotorFrame: Sendable, Hashable, Codable {
    public var motorEvents: [RoutedEvent]
    public var muscleExcitation: [Float]
    public var autonomicCommands: [Float]
    public var glandCommands: [Float]
    public var selectedOption: UInt32
    public var confidence: Float

    public init(
        motorEvents: [RoutedEvent] = [],
        muscleExcitation: [Float] = [],
        autonomicCommands: [Float] = [],
        glandCommands: [Float] = [],
        selectedOption: UInt32 = 0,
        confidence: Float = 0
    ) {
        self.motorEvents = motorEvents
        self.muscleExcitation = muscleExcitation
        self.autonomicCommands = autonomicCommands
        self.glandCommands = glandCommands
        self.selectedOption = selectedOption
        self.confidence = confidence
    }
}

public struct NumanXControlFrame: Sendable, Hashable, Codable {
    public var timeRange: Range<TissueTime>
    public var motor: NumiBrainMotorFrame
    public var tissueStress: [SIMD6<Float>]
    public var tissueGrowth: [SIMD6<Float>]
    public var metabolicDemand: [Float]
    public var swelling: [Float]

    public init(
        timeRange: Range<TissueTime>,
        motor: NumiBrainMotorFrame,
        tissueStress: [SIMD6<Float>] = [],
        tissueGrowth: [SIMD6<Float>] = [],
        metabolicDemand: [Float] = [],
        swelling: [Float] = []
    ) {
        self.timeRange = timeRange
        self.motor = motor
        self.tissueStress = tissueStress
        self.tissueGrowth = tissueGrowth
        self.metabolicDemand = metabolicDemand
        self.swelling = swelling
    }
}

public struct SuiteTransactionContext: Sendable, Hashable, Codable {
    public var transaction: TransactionID
    public var epoch: UInt64
    public var startTime: TissueTime
    public var endTime: TissueTime
    public var randomSeed: UInt64

    public init(transaction: TransactionID, epoch: UInt64, startTime: TissueTime, endTime: TissueTime, randomSeed: UInt64) {
        self.transaction = transaction
        self.epoch = epoch
        self.startTime = startTime
        self.endTime = endTime
        self.randomSeed = randomSeed
    }

    public var tissueExecutionContext: ExecutionContext {
        ExecutionContext(transaction: transaction, epoch: epoch, startTime: startTime, endTime: endTime, randomSeed: randomSeed)
    }
}

public struct SuiteValidationIssue: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable { case tissue, brain, physics, coordinator }
    public enum Severity: UInt8, Sendable, Hashable, Codable { case warning, reject }

    public var source: Source
    public var severity: Severity
    public var code: UInt32
    public var value: Float
    public var message: String

    public init(source: Source, severity: Severity, code: UInt32, value: Float = 0, message: String) {
        self.source = source
        self.severity = severity
        self.code = code
        self.value = value
        self.message = message
    }
}

public protocol NumiBrainTransactionalEndpoint: Sendable {
    var name: String { get }
    func committedTissueCommand(observation: NumanXObservationFrame, context: SuiteTransactionContext) async throws -> NumiBrainTissueCommand
    func beginShadow(context: SuiteTransactionContext, observation: NumanXObservationFrame) async throws
    func integrateTissue(_ output: RuntimeOutputFrame, context: SuiteTransactionContext) async throws -> NumiBrainMotorFrame
    func validateShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue]
    func commitShadow(context: SuiteTransactionContext) async throws
    func rollbackShadow(context: SuiteTransactionContext) async
}

public protocol NumanXTransactionalEndpoint: Sendable {
    var name: String { get }
    func committedObservation(at time: TissueTime) async throws -> NumanXObservationFrame
    func beginShadow(context: SuiteTransactionContext) async throws
    func integrate(_ control: NumanXControlFrame, context: SuiteTransactionContext) async throws
    func shadowObservation(context: SuiteTransactionContext) async throws -> NumanXObservationFrame
    func validateShadow(context: SuiteTransactionContext) async throws -> [SuiteValidationIssue]
    func commitShadow(context: SuiteTransactionContext) async throws
    func rollbackShadow(context: SuiteTransactionContext) async
}

public extension RuntimeInputFrame {
    init(command: NumiBrainTissueCommand, observation: NumanXObservationFrame) {
        let namespace = command.afferentProjection.routeNamespace == 0
            ? 0x4E54_0000_0000_0000
            : command.afferentProjection.routeNamespace
        var events = command.afferentProjection.events
        events.append(contentsOf: observation.sensoryEvents)
        events.append(contentsOf: observation.injuryEvents)
        events.append(contentsOf: Self.encodeAnalog(
            command.afferentProjection.analogChannels,
            lane: 0,
            namespace: namespace,
            tick: observation.time.tick
        ))
        events.append(contentsOf: Self.encodeAnalog(
            observation.proprioception,
            lane: 1,
            namespace: namespace,
            tick: observation.time.tick
        ))
        events.append(contentsOf: Self.encodeAnalog(
            observation.touch,
            lane: 2,
            namespace: namespace,
            tick: observation.time.tick
        ))
        events.append(contentsOf: Self.encodeAnalog(
            observation.vestibular,
            lane: 3,
            namespace: namespace,
            tick: observation.time.tick
        ))
        events.append(contentsOf: Self.encodeAnalog(
            observation.interoception,
            lane: 4,
            namespace: namespace,
            tick: observation.time.tick
        ))
        events.sort()

        let chemical = observation.chemicalBoundary
        let metabolic = SIMD8<Float>(
            chemical.oxygen,
            chemical.glucose,
            chemical.lactate,
            chemical.extracellularPotassium,
            chemical.extracellularCalcium,
            chemical.temperatureKelvin,
            chemical.pH,
            chemical.perfusion
        )
        self.init(
            afferentEvents: events,
            stimuli: command.stimulation,
            neuromodulators: command.neuromodulators,
            hormones: command.hormones,
            metabolicBoundary: metabolic,
            mechanicalBoundaryToken: Self.mechanicalToken(observation.mechanicalBoundary),
            behavioralContextToken: namespace
        )
    }

    private static func encodeAnalog(
        _ values: [Float],
        lane: UInt64,
        namespace: UInt64,
        tick: UInt64
    ) -> [RoutedEvent] {
        values.enumerated().compactMap { index, value in
            guard value.isFinite else { return nil }
            let laneBits = (lane & 0xFF) << 48
            let indexBits = UInt64(UInt32(clamping: index))
            return RoutedEvent(
                arrivalTick: tick,
                source: namespace ^ laneBits,
                destination: namespace ^ laneBits ^ indexBits,
                amplitude: value,
                kind: .analogAfferent,
                flags: UInt16(truncatingIfNeeded: lane),
                sequence: UInt32(clamping: index)
            )
        }
    }

    private static func mechanicalToken(_ boundary: TissueMechanicalBoundary) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: Float) {
            hash ^= UInt64(value.bitPattern)
            hash &*= 0x0000_0100_0000_01b3
        }
        for index in 0..<16 { mix(boundary.deformationGradient[index]) }
        for index in 0..<6 { mix(boundary.strain[index]) }
        for index in 0..<6 { mix(boundary.stress[index]) }
        mix(boundary.pressure)
        mix(boundary.damage)
        mix(boundary.temperatureKelvin)
        for index in 0..<3 { mix(boundary.boundaryVelocity[index]) }
        for index in 0..<16 { mix(boundary.worldTransform[index]) }
        return hash
    }
}
