import Foundation

public enum NTExtracellularSpecies: UInt16, Codable, CaseIterable, Sendable {
    case potassium = 0
    case calcium = 1
    case glutamate = 2
    case oxygen = 3
    case glucose = 4
    case lactate = 5
    case wastePH = 6
    case trophicSupport = 7
    case attractiveGuidance = 8
    case repulsiveGuidance = 9
    case inflammatoryDamage = 10
    case extracellularMatrix = 11
}

public enum NTFieldBoundaryCondition: Codable, Hashable, Sendable {
    case noFlux
    case fixed(Float)
    case perfused(target: Float, exchangePerSecond: Float)
}

@frozen
public struct NTFieldSpeciesParameters: Codable, Hashable, Sendable {
    public var species: NTExtracellularSpecies
    public var diffusionSquareMicrometersPerSecond: Float
    public var decayPerSecond: Float
    public var minimum: Float
    public var maximum: Float
    public var boundary: NTFieldBoundaryCondition

    public init(
        species: NTExtracellularSpecies,
        diffusionSquareMicrometersPerSecond: Float,
        decayPerSecond: Float = 0,
        minimum: Float = 0,
        maximum: Float = .greatestFiniteMagnitude,
        boundary: NTFieldBoundaryCondition = .noFlux
    ) {
        self.species = species
        self.diffusionSquareMicrometersPerSecond = diffusionSquareMicrometersPerSecond
        self.decayPerSecond = decayPerSecond
        self.minimum = minimum
        self.maximum = maximum
        self.boundary = boundary
    }
}

public struct NTFieldModel: Codable, Sendable {
    public var parameters: [NTFieldSpeciesParameters]

    public init(parameters: [NTFieldSpeciesParameters] = Self.brainTissueDefaults) {
        self.parameters = parameters.sorted { $0.species.rawValue < $1.species.rawValue }
    }

    public func parameter(speciesIndex: Int) -> NTFieldSpeciesParameters {
        if parameters.indices.contains(speciesIndex) { return parameters[speciesIndex] }
        return NTFieldSpeciesParameters(
            species: .extracellularMatrix,
            diffusionSquareMicrometersPerSecond: 0,
            minimum: 0
        )
    }

    public static let brainTissueDefaults: [NTFieldSpeciesParameters] = [
        .init(species: .potassium, diffusionSquareMicrometersPerSecond: 1_900, decayPerSecond: 0.2, maximum: 100, boundary: .perfused(target: 3.5, exchangePerSecond: 0.05)),
        .init(species: .calcium, diffusionSquareMicrometersPerSecond: 700, decayPerSecond: 0.02, maximum: 10, boundary: .perfused(target: 2, exchangePerSecond: 0.02)),
        .init(species: .glutamate, diffusionSquareMicrometersPerSecond: 330, decayPerSecond: 20, maximum: 100),
        .init(species: .oxygen, diffusionSquareMicrometersPerSecond: 2_000, decayPerSecond: 0, maximum: 2, boundary: .perfused(target: 0.04, exchangePerSecond: 2)),
        .init(species: .glucose, diffusionSquareMicrometersPerSecond: 600, decayPerSecond: 0, maximum: 30, boundary: .perfused(target: 5, exchangePerSecond: 0.5)),
        .init(species: .lactate, diffusionSquareMicrometersPerSecond: 700, decayPerSecond: 0.05, maximum: 50, boundary: .perfused(target: 1, exchangePerSecond: 0.2)),
        .init(species: .wastePH, diffusionSquareMicrometersPerSecond: 900, decayPerSecond: 0.1, maximum: 100),
        .init(species: .trophicSupport, diffusionSquareMicrometersPerSecond: 20, decayPerSecond: 0.001, maximum: 10),
        .init(species: .attractiveGuidance, diffusionSquareMicrometersPerSecond: 10, decayPerSecond: 0.0005, maximum: 10),
        .init(species: .repulsiveGuidance, diffusionSquareMicrometersPerSecond: 10, decayPerSecond: 0.0005, maximum: 10),
        .init(species: .inflammatoryDamage, diffusionSquareMicrometersPerSecond: 40, decayPerSecond: 0.002, maximum: 100),
        .init(species: .extracellularMatrix, diffusionSquareMicrometersPerSecond: 0, decayPerSecond: 0, maximum: 1)
    ]
}

@frozen
public struct NTFieldStepResult: Sendable {
    public var internalSubsteps: UInt32
    public var massBefore: [Double]
    public var massAfter: [Double]
    public var diagnostics: [NTDiagnostic]

    public init(internalSubsteps: UInt32, massBefore: [Double], massAfter: [Double], diagnostics: [NTDiagnostic]) {
        self.internalSubsteps = internalSubsteps
        self.massBefore = massBefore
        self.massAfter = massAfter
        self.diagnostics = diagnostics
    }
}

public struct NTExtracellularFieldEngine: Sendable {
    public var model: NTFieldModel
    public var cflSafety: Float

    public init(model: NTFieldModel = .init(), cflSafety: Float = 0.8) {
        self.model = model
        self.cflSafety = cflSafety
    }

    public func step(state: inout NTProductionState, deltaTicks: UInt64) -> NTFieldStepResult {
        guard !state.fields.isEmpty, deltaTicks > 0 else {
            return .init(internalSubsteps: 0, massBefore: [], massAfter: [], diagnostics: [])
        }
        let speciesCount = Int(state.fields[0].speciesCount)
        var massBefore = Array(repeating: Double.zero, count: speciesCount)
        for brick in state.fields {
            accumulateMass(brick: brick, into: &massBefore)
        }

        let voxelWidth = state.configuration.tileEdgeMicrometers / Float(state.configuration.fieldResolution)
        let totalSeconds = Float(deltaTicks * TissueTime.quantumMicroseconds) * 1.0e-6
        let maximumDiffusion = model.parameters.prefix(speciesCount).map(\.diffusionSquareMicrometersPerSecond).max() ?? 0
        let maximumStableSeconds = maximumDiffusion > 0
            ? cflSafety * voxelWidth * voxelWidth / (6 * maximumDiffusion)
            : totalSeconds
        let substeps = max(1, Int(ceil(totalSeconds / max(maximumStableSeconds, 1.0e-9))))
        let dt = totalSeconds / Float(substeps)
        var diagnostics: [NTDiagnostic] = []

        for _ in 0..<substeps {
            let previous = state.fields.map(\.concentrations)
            let coordinateMap = fieldCoordinateMap(state: state)
            for fieldIndex in state.fields.indices {
                var brick = state.fields[fieldIndex]
                let resolution = Int(brick.resolution)
                let localSpeciesCount = Int(brick.speciesCount)
                guard previous[fieldIndex].count == brick.voxelCount * localSpeciesCount else {
                    diagnostics.append(.init(
                        severity: .fatal,
                        code: .invalidReference,
                        message: "Extracellular field storage is inconsistent.",
                        tile: brick.tile
                    ))
                    continue
                }
                var next = previous[fieldIndex]
                for z in 0..<resolution {
                    for y in 0..<resolution {
                        for x in 0..<resolution {
                            for species in 0..<localSpeciesCount {
                                let parameter = model.parameter(speciesIndex: species)
                                let centerIndex = brick.linearIndex(x: x, y: y, z: z, species: species)
                                let center = previous[fieldIndex][centerIndex]
                                let neighbors = neighborValues(
                                    x: x,
                                    y: y,
                                    z: z,
                                    species: species,
                                    fieldIndex: fieldIndex,
                                    state: state,
                                    previous: previous,
                                    coordinateMap: coordinateMap,
                                    boundary: parameter.boundary
                                )
                                let laplacian = (neighbors.0 + neighbors.1 + neighbors.2 + neighbors.3 + neighbors.4 + neighbors.5 - 6 * center) /
                                    max(voxelWidth * voxelWidth, 1.0e-12)
                                let source = brick.sources[centerIndex]
                                var value = center + dt * (
                                    parameter.diffusionSquareMicrometersPerSecond * laplacian +
                                    source - parameter.decayPerSecond * center
                                )
                                switch parameter.boundary {
                                case let .perfused(target, exchange) where isBoundaryVoxel(x: x, y: y, z: z, resolution: resolution):
                                    value += dt * exchange * (target - value)
                                case let .fixed(fixed) where isBoundaryVoxel(x: x, y: y, z: z, resolution: resolution):
                                    value = fixed
                                default:
                                    break
                                }
                                next[centerIndex] = min(parameter.maximum, max(parameter.minimum, value))
                            }
                        }
                    }
                }
                brick.concentrations = next
                brick.sources = Array(repeating: 0, count: brick.sources.count)
                state.fields[fieldIndex] = brick
            }
        }

        var massAfter = Array(repeating: Double.zero, count: speciesCount)
        for brick in state.fields {
            accumulateMass(brick: brick, into: &massAfter)
            diagnostics.append(contentsOf: brick.validate())
        }
        for species in 0..<min(massBefore.count, massAfter.count) {
            let parameter = model.parameter(speciesIndex: species)
            guard parameter.decayPerSecond == 0 else { continue }
            if case .noFlux = parameter.boundary {
                let denominator = max(abs(massBefore[species]), 1.0e-12)
                let relative = abs(massAfter[species] - massBefore[species]) / denominator
                if relative > Double(state.configuration.fieldMassRelativeTolerance) {
                    diagnostics.append(.init(
                        severity: .error,
                        code: .fieldConservationFailure,
                        message: "No-flux field species \(species) changed mass by relative error \(relative)."
                    ))
                }
            }
        }
        return .init(
            internalSubsteps: UInt32(clamping: substeps),
            massBefore: massBefore,
            massAfter: massAfter,
            diagnostics: diagnostics
        )
    }

    public func addSource(
        state: inout NTProductionState,
        tile: TileID,
        positionMicrometers: NTVector3,
        species: NTExtracellularSpecies,
        amountPerSecond: Float
    ) {
        guard let fieldIndex = state.fields.firstIndex(where: { $0.tile == tile }) else { return }
        var brick = state.fields[fieldIndex]
        let resolution = Int(brick.resolution)
        guard Int(species.rawValue) < Int(brick.speciesCount),
              let tileIndex = state.tileIndex(id: tile) else { return }
        let coordinate = state.tiles[tileIndex].membership.coordinate
        let tileOrigin = NTVector3(
            state.configuration.originMicrometers.x + Float(coordinate.x) * state.configuration.tileEdgeMicrometers,
            state.configuration.originMicrometers.y + Float(coordinate.y) * state.configuration.tileEdgeMicrometers,
            state.configuration.originMicrometers.z + Float(coordinate.z) * state.configuration.tileEdgeMicrometers
        )
        let local = positionMicrometers - tileOrigin
        let scale = Float(resolution) / state.configuration.tileEdgeMicrometers
        let x = min(resolution - 1, max(0, Int(floor(local.x * scale))))
        let y = min(resolution - 1, max(0, Int(floor(local.y * scale))))
        let z = min(resolution - 1, max(0, Int(floor(local.z * scale))))
        let index = brick.linearIndex(x: x, y: y, z: z, species: Int(species.rawValue))
        brick.sources[index] += amountPerSecond
        state.fields[fieldIndex] = brick
    }

    public func sample(
        state: NTProductionState,
        tile: TileID,
        positionMicrometers: NTVector3,
        species: NTExtracellularSpecies
    ) -> Float? {
        guard let fieldIndex = state.fields.firstIndex(where: { $0.tile == tile }),
              let tileIndex = state.tileIndex(id: tile) else { return nil }
        let brick = state.fields[fieldIndex]
        let resolution = Int(brick.resolution)
        guard Int(species.rawValue) < Int(brick.speciesCount) else { return nil }
        let coordinate = state.tiles[tileIndex].membership.coordinate
        let origin = NTVector3(
            state.configuration.originMicrometers.x + Float(coordinate.x) * state.configuration.tileEdgeMicrometers,
            state.configuration.originMicrometers.y + Float(coordinate.y) * state.configuration.tileEdgeMicrometers,
            state.configuration.originMicrometers.z + Float(coordinate.z) * state.configuration.tileEdgeMicrometers
        )
        let local = positionMicrometers - origin
        let scale = Float(resolution) / state.configuration.tileEdgeMicrometers
        let x = min(resolution - 1, max(0, Int(floor(local.x * scale))))
        let y = min(resolution - 1, max(0, Int(floor(local.y * scale))))
        let z = min(resolution - 1, max(0, Int(floor(local.z * scale))))
        return brick.concentrations[brick.linearIndex(x: x, y: y, z: z, species: Int(species.rawValue))]
    }

    public func summaries(state: NTProductionState) -> [NTFieldSample] {
        var output: [NTFieldSample] = []
        for brick in state.fields {
            let speciesCount = Int(brick.speciesCount)
            for species in 0..<speciesCount {
                var sum: Double = 0
                var minimum = Float.greatestFiniteMagnitude
                var maximum = -Float.greatestFiniteMagnitude
                var count = 0
                var index = species
                while index < brick.concentrations.count {
                    let value = brick.concentrations[index]
                    sum += Double(value)
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    count += 1
                    index += speciesCount
                }
                output.append(.init(
                    tile: brick.tile,
                    species: UInt16(clamping: species),
                    mean: count > 0 ? Float(sum / Double(count)) : 0,
                    minimum: count > 0 ? minimum : 0,
                    maximum: count > 0 ? maximum : 0
                ))
            }
        }
        return output
    }

    private func fieldCoordinateMap(state: NTProductionState) -> [TileCoordinate: Int] {
        var tileToCoordinate: [TileID: TileCoordinate] = [:]
        for tile in state.tiles { tileToCoordinate[tile.membership.id] = tile.membership.coordinate }
        var result: [TileCoordinate: Int] = [:]
        for (index, brick) in state.fields.enumerated() {
            if let coordinate = tileToCoordinate[brick.tile] { result[coordinate] = index }
        }
        return result
    }

    private func neighborValues(
        x: Int,
        y: Int,
        z: Int,
        species: Int,
        fieldIndex: Int,
        state: NTProductionState,
        previous: [[Float]],
        coordinateMap: [TileCoordinate: Int],
        boundary: NTFieldBoundaryCondition
    ) -> (Float, Float, Float, Float, Float, Float) {
        let brick = state.fields[fieldIndex]
        let resolution = Int(brick.resolution)
        let current = previous[fieldIndex][brick.linearIndex(x: x, y: y, z: z, species: species)]
        guard let tileIndex = state.tileIndex(id: brick.tile) else {
            return (current, current, current, current, current, current)
        }
        let coordinate = state.tiles[tileIndex].membership.coordinate

        func value(_ nx: Int, _ ny: Int, _ nz: Int) -> Float {
            if nx >= 0, nx < resolution, ny >= 0, ny < resolution, nz >= 0, nz < resolution {
                return previous[fieldIndex][brick.linearIndex(x: nx, y: ny, z: nz, species: species)]
            }
            let dx: Int32 = nx < 0 ? -1 : nx >= resolution ? 1 : 0
            let dy: Int32 = ny < 0 ? -1 : ny >= resolution ? 1 : 0
            let dz: Int32 = nz < 0 ? -1 : nz >= resolution ? 1 : 0
            let neighborCoordinate = coordinate.neighbor(dx: dx, dy: dy, dz: dz)
            if let neighborIndex = coordinateMap[neighborCoordinate] {
                let neighbor = state.fields[neighborIndex]
                let wrappedX = nx < 0 ? resolution - 1 : nx >= resolution ? 0 : nx
                let wrappedY = ny < 0 ? resolution - 1 : ny >= resolution ? 0 : ny
                let wrappedZ = nz < 0 ? resolution - 1 : nz >= resolution ? 0 : nz
                return previous[neighborIndex][neighbor.linearIndex(x: wrappedX, y: wrappedY, z: wrappedZ, species: species)]
            }
            switch boundary {
            case let .fixed(fixed): return fixed
            case let .perfused(target, _): return target
            case .noFlux: return current
            }
        }

        return (
            value(x - 1, y, z), value(x + 1, y, z),
            value(x, y - 1, z), value(x, y + 1, z),
            value(x, y, z - 1), value(x, y, z + 1)
        )
    }

    private func accumulateMass(brick: NTFieldBrickState, into mass: inout [Double]) {
        let speciesCount = Int(brick.speciesCount)
        guard speciesCount > 0 else { return }
        for index in brick.concentrations.indices {
            let species = index % speciesCount
            if mass.indices.contains(species) { mass[species] += Double(brick.concentrations[index]) }
        }
    }

    @inline(__always)
    private func isBoundaryVoxel(x: Int, y: Int, z: Int, resolution: Int) -> Bool {
        x == 0 || y == 0 || z == 0 || x == resolution - 1 || y == resolution - 1 || z == resolution - 1
    }
}
