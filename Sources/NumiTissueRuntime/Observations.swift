import Foundation
import NumiTissueCore

public enum TissueObservationReduction: String, Sendable, Hashable, Codable, CaseIterable {
    case raw
    case mean
    case sum
    case minimum
    case maximum
    case rootMeanSquare
}

public struct TissueObservationRequest: Sendable, Hashable, Codable {
    public var path: String
    public var reduction: TissueObservationReduction
    public var unit: String?
    public var maximumRawValues: Int

    public init(
        path: String,
        reduction: TissueObservationReduction = .mean,
        unit: String? = nil,
        maximumRawValues: Int = 4_096
    ) {
        self.path = path
        self.reduction = reduction
        self.unit = unit
        self.maximumRawValues = maximumRawValues
    }

    public func validated() throws -> Self {
        guard !path.isEmpty, maximumRawValues > 0 else {
            throw TissueObservationError.invalidRequest(path)
        }
        return self
    }
}

public struct TissueObservation: Sendable, Hashable, Codable {
    public var path: String
    public var tick: UInt64
    public var reduction: TissueObservationReduction
    public var unit: String?
    public var values: [Double]

    public init(
        path: String,
        tick: UInt64,
        reduction: TissueObservationReduction,
        unit: String? = nil,
        values: [Double]
    ) {
        self.path = path
        self.tick = tick
        self.reduction = reduction
        self.unit = unit
        self.values = values
    }
}

public struct TissueObservationBatch: Sendable, Hashable, Codable {
    public var time: TissueTime
    public var observations: [TissueObservation]
    public var metadata: [String: String]

    public init(
        time: TissueTime,
        observations: [TissueObservation],
        metadata: [String: String] = [:]
    ) {
        self.time = time
        self.observations = observations
        self.metadata = metadata
    }
}

public actor TissueStateRecorder {
    public let requests: [TissueObservationRequest]
    public let samplingIntervalTicks: UInt64
    public let maximumBatches: Int
    public let jsonLinesURL: URL?
    public let csvURL: URL?

    private var capturedBatches: [TissueObservationBatch] = []

    public init(
        requests: [TissueObservationRequest] = [],
        samplingIntervalTicks: UInt64 = 1,
        maximumBatches: Int = 100_000,
        jsonLinesURL: URL? = nil,
        csvURL: URL? = nil
    ) throws {
        guard samplingIntervalTicks > 0, maximumBatches > 0 else {
            throw TissueObservationError.invalidRecorderConfiguration
        }
        self.requests = try requests.map { try $0.validated() }
        self.samplingIntervalTicks = samplingIntervalTicks
        self.maximumBatches = maximumBatches
        self.jsonLinesURL = jsonLinesURL
        self.csvURL = csvURL
        capturedBatches.reserveCapacity(min(maximumBatches, 1_024))
    }

    public func requiresSample(at tick: UInt64) -> Bool {
        tick.isMultiple(of: samplingIntervalTicks)
    }

    @discardableResult
    public func sample(_ state: TissueRuntimeState) throws -> TissueObservationBatch {
        guard capturedBatches.count < maximumBatches else {
            throw TissueObservationError.capacityExceeded(maximumBatches)
        }
        try state.validateCapacity()
        var observations: [TissueObservation] = []
        observations.reserveCapacity(requests.count)
        for request in requests {
            let raw = try values(for: request.path, state: state)
            guard raw.allSatisfy(\.isFinite) else {
                throw TissueObservationError.nonFiniteValue(request.path)
            }
            let values = try reduce(raw, using: request)
            observations.append(
                TissueObservation(
                    path: request.path,
                    tick: state.time.tick,
                    reduction: request.reduction,
                    unit: request.unit,
                    values: values
                )
            )
        }
        let batch = TissueObservationBatch(
            time: state.time,
            observations: observations,
            metadata: [
                "numitissue.observation.schema": "1",
                "numitissue.observation.state": "committed"
            ]
        )
        capturedBatches.append(batch)
        return batch
    }

    public func batches() -> [TissueObservationBatch] { capturedBatches }

    public func reset() {
        capturedBatches.removeAll(keepingCapacity: true)
    }

    public func flush() throws {
        if let jsonLinesURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let lines = try capturedBatches.map { batch in
                String(decoding: try encoder.encode(batch), as: UTF8.self)
            }.joined(separator: "\n")
            try (lines + (lines.isEmpty ? "" : "\n")).write(to: jsonLinesURL, atomically: true, encoding: .utf8)
        }
        if let csvURL {
            var rows = ["tick,path,reduction,unit,index,value"]
            for batch in capturedBatches {
                for observation in batch.observations {
                    for (index, value) in observation.values.enumerated() {
                        rows.append([
                            String(observation.tick),
                            Self.csv(observation.path),
                            observation.reduction.rawValue,
                            Self.csv(observation.unit ?? ""),
                            String(index),
                            String(value)
                        ].joined(separator: ","))
                    }
                }
            }
            try (rows.joined(separator: "\n") + "\n").write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }

    private func values(for path: String, state: TissueRuntimeState) throws -> [Double] {
        switch path {
        case "time.tick": return [Double(state.time.tick)]
        case "time.seconds": return [state.time.seconds]
        case "compartment.voltage_mv", "cell.voltage_mv": return state.compartments.map { Double($0.voltageMillivolts) }
        case "compartment.injected_current_nA": return state.compartments.map { Double($0.injectedCurrentNanoamps) }
        case "cell.energy_reserve": return state.cells.map { Double($0.energyReserve) }
        case "cell.oxygen_stress": return state.cells.map { Double($0.oxygenStress) }
        case "cell.glucose_stress": return state.cells.map { Double($0.glucoseStress) }
        case "cell.damage": return state.cells.map { Double($0.damage) }
        case "cell.apoptosis_hazard": return state.cells.map { Double($0.apoptosisHazard) }
        case "synapse.conductance": return state.synapses.map { Double($0.conductance) }
        case "synapse.weight": return state.synapses.map { Double($0.weight) }
        case "field.concentration": return state.fields.map { Double($0.concentration) }
        case "field.oxygen": return fieldChannelValues(3, state: state)
        case "field.glucose": return fieldChannelValues(4, state: state)
        case "field.lactate": return fieldChannelValues(5, state: state)
        case "field.source": return state.fields.map { Double($0.source) }
        case "field.sink": return state.fields.map { Double($0.sink) }
        case "microdomain.species": return state.molecularSpecies.map(Double.init)
        case "metabolism.energy": return state.cells.map { Double($0.energyReserve) }
        default:
            if let suffix = path.split(separator: ".").last,
               path.hasPrefix("field.channel."),
               let channel = Int(suffix), (0..<12).contains(channel) {
                return fieldChannelValues(channel, state: state)
            }
            throw TissueObservationError.unknownPath(path)
        }
    }

    private func fieldChannelValues(_ channel: Int, state: TissueRuntimeState) -> [Double] {
        var result: [Double] = []
        for tile in state.tiles {
            let total = Int(tile.fieldRange.count)
            guard total >= 12, total.isMultiple(of: 12) else { continue }
            let voxelCount = total / 12
            let lower = Int(tile.fieldRange.lowerBound) + channel * voxelCount
            let upper = lower + voxelCount
            guard lower >= 0, upper <= state.fields.count else { continue }
            result.append(contentsOf: state.fields[lower..<upper].map { Double($0.concentration) })
        }
        return result
    }

    private func reduce(
        _ values: [Double],
        using request: TissueObservationRequest
    ) throws -> [Double] {
        guard !values.isEmpty else {
            throw TissueObservationError.emptySelection(request.path)
        }
        switch request.reduction {
        case .raw:
            guard values.count <= request.maximumRawValues else {
                throw TissueObservationError.rawCaptureExceeded(path: request.path, count: values.count, maximum: request.maximumRawValues)
            }
            return values
        case .mean: return [values.reduce(0, +) / Double(values.count)]
        case .sum: return [values.reduce(0, +)]
        case .minimum: return [values.min()!]
        case .maximum: return [values.max()!]
        case .rootMeanSquare:
            return [sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(values.count))]
        }
    }

    private static func csv(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum TissueObservationError: Error, Sendable, CustomStringConvertible {
    case invalidRecorderConfiguration
    case invalidRequest(String)
    case unknownPath(String)
    case emptySelection(String)
    case nonFiniteValue(String)
    case rawCaptureExceeded(path: String, count: Int, maximum: Int)
    case capacityExceeded(Int)

    public var description: String {
        switch self {
        case .invalidRecorderConfiguration: return "Observation recorder configuration is invalid."
        case .invalidRequest(let path): return "Observation request is invalid: \(path)"
        case .unknownPath(let path): return "Unknown tissue observation path: \(path)"
        case .emptySelection(let path): return "Observation path selected no values: \(path)"
        case .nonFiniteValue(let path): return "Observation path produced a non-finite value: \(path)"
        case .rawCaptureExceeded(let path, let count, let maximum): return "Raw observation \(path) contains \(count) values; maximum is \(maximum)."
        case .capacityExceeded(let maximum): return "Observation recorder reached its batch capacity of \(maximum)."
        }
    }
}
