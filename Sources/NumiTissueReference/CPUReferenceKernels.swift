import Foundation
import NumiTissueCore
import NumiTissueModels
import NumiTissueRuntime

public enum CPUReferenceKernels {
    private static let mechanismStride = 16
    private static let tickMilliseconds: Float = 0.025

    public static func deliver(events: [RoutedEvent], state: inout TissueRuntimeState) {
        for event in events {
            let synapseIndex = Int(UInt32(truncatingIfNeeded: event.destination))
            guard synapseIndex >= 0 && synapseIndex < state.synapses.count else {
                let compartmentIndex = Int(UInt32(truncatingIfNeeded: event.destination))
                if compartmentIndex >= 0 && compartmentIndex < state.compartments.count {
                    state.compartments[compartmentIndex].injectedCurrentNanoamps += event.amplitude
                }
                continue
            }
            var synapse = state.synapses[synapseIndex]
            let utilization = clamp01(synapse.shortTermUtilization)
            let resources = clamp01(synapse.shortTermResources)
            let release = max(event.amplitude, 0) * utilization * resources
            synapse.conductance += synapse.weight * release
            synapse.shortTermResources = max(0, resources - utilization * resources)
            synapse.preTrace += 1
            synapse.eligibility += 1
            synapse.lastEventTick = event.arrivalTick
            state.synapses[synapseIndex] = synapse
        }
    }

    public static func decaySynapses(state: inout TissueRuntimeState, dtMilliseconds: Float) {
        for index in state.compartments.indices { state.compartments[index].synapticCurrentNanoamps = 0 }
        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let inhibitory = (synapse.flags & 1) != 0
            let tau: Float = inhibitory ? 10 : 5
            synapse.conductance *= exp(-dtMilliseconds / tau)
            synapse.preTrace *= exp(-dtMilliseconds / 20)
            synapse.postTrace *= exp(-dtMilliseconds / 20)
            synapse.eligibility *= exp(-dtMilliseconds / 1_000)
            let recoveryTau: Float = inhibitory ? 700 : 800
            synapse.shortTermResources = 1 - (1 - synapse.shortTermResources) * exp(-dtMilliseconds / recoveryTau)
            let target = Int(synapse.targetCompartmentIndex)
            if target >= 0 && target < state.compartments.count {
                let reversal: Float = inhibitory ? -70 : 0
                let current = synapse.conductance * (state.compartments[target].voltageMillivolts - reversal)
                state.compartments[target].synapticCurrentNanoamps += current
            }
            state.synapses[index] = synapse
        }
    }

    public static func updateChannels(
        state: inout TissueRuntimeState,
        dtMilliseconds: Float,
        thermalScales: [Float] = []
    ) {
        ensureMechanismCapacity(state: &state)
        for index in state.compartments.indices {
            let base = index * mechanismStride
            let voltage = Double(state.compartments[index].voltageMillivolts)
            var m = boundedGate(state.mechanismState[base], fallback: 0.05)
            var h = boundedGate(state.mechanismState[base + 1], fallback: 0.60)
            var n = boundedGate(state.mechanismState[base + 2], fallback: 0.32)
            let mechanismIndex = Int(state.compartments[index].flags & 0xFFFF)
            let thermalScale = thermalScales.indices.contains(mechanismIndex)
                ? max(thermalScales[mechanismIndex], 1e-4)
                : 1
            let dt = Double(dtMilliseconds) * Double(thermalScale)
            let mRates = alphaBetaM(voltage)
            let hRates = alphaBetaH(voltage)
            let nRates = alphaBetaN(voltage)
            m = rushLarsen(m, alpha: mRates.0, beta: mRates.1, dt: dt)
            h = rushLarsen(h, alpha: hRates.0, beta: hRates.1, dt: dt)
            n = rushLarsen(n, alpha: nRates.0, beta: nRates.1, dt: dt)

            let gNaMax = positiveOr(state.mechanismState[base + 4], 0.120)
            let gKMax = positiveOr(state.mechanismState[base + 5], 0.036)
            let gLeak = positiveOr(state.mechanismState[base + 6], 0.0003)
            let eNa = finiteNonzeroOr(state.mechanismState[base + 7], 50)
            let eK = finiteNonzeroOr(state.mechanismState[base + 8], -77)
            let eLeak = finiteNonzeroOr(state.mechanismState[base + 9], -54.387)
            let gNa = Double(gNaMax) * m * m * m * h
            let gK = Double(gKMax) * n * n * n * n
            state.mechanismState[base] = Float(clamp01(m))
            state.mechanismState[base + 1] = Float(clamp01(h))
            state.mechanismState[base + 2] = Float(clamp01(n))
            state.mechanismState[base + 10] = Float(gNa + gK + Double(gLeak))
            state.mechanismState[base + 11] = Float(gNa * Double(eNa) + gK * Double(eK) + Double(gLeak * eLeak))
        }
    }

    public static func solveCableTrees(state: inout TissueRuntimeState, dtMilliseconds: Float) {
        ensureMechanismCapacity(state: &state)
        let count = state.compartments.count
        guard count > 0 else { return }
        let dt = max(Double(dtMilliseconds), 1e-9)
        var diagonal = Array(repeating: 0.0, count: count)
        var rhs = Array(repeating: 0.0, count: count)
        var solution = Array(repeating: 0.0, count: count)
        var depths = Array(repeating: 0, count: count)

        for index in 0..<count {
            let compartment = state.compartments[index]
            let base = index * mechanismStride
            let capacitance = max(Double(compartment.capacitanceNanofarads), 1e-12)
            let axial = compartment.parentIndex == RuntimeCompartmentState.invalidIndex ? 0 : max(Double(compartment.axialConductanceMicrosiemens), 0)
            let conductance = max(Double(state.mechanismState[base + 10]), 0)
            let source = Double(state.mechanismState[base + 11])
            let applied = Double(compartment.injectedCurrentNanoamps - compartment.synapticCurrentNanoamps)
            diagonal[index] = capacitance / dt + conductance + axial
            rhs[index] = capacitance / dt * Double(compartment.voltageMillivolts) + source + applied
            depths[index] = depth(of: index, compartments: state.compartments)
        }

        let descending = (0..<count).sorted {
            if depths[$0] != depths[$1] { return depths[$0] > depths[$1] }
            return $0 < $1
        }
        for child in descending {
            let parentRaw = state.compartments[child].parentIndex
            guard parentRaw != RuntimeCompartmentState.invalidIndex else { continue }
            let parent = Int(parentRaw)
            guard parent >= 0 && parent < count else { continue }
            let axial = max(Double(state.compartments[child].axialConductanceMicrosiemens), 0)
            let d = max(diagonal[child], 1e-18)
            diagonal[parent] -= axial * axial / d
            rhs[parent] += axial * rhs[child] / d
        }

        for index in 0..<count where state.compartments[index].parentIndex == RuntimeCompartmentState.invalidIndex {
            solution[index] = rhs[index] / max(diagonal[index], 1e-18)
        }
        let ascending = (0..<count).sorted {
            if depths[$0] != depths[$1] { return depths[$0] < depths[$1] }
            return $0 < $1
        }
        for child in ascending {
            let parentRaw = state.compartments[child].parentIndex
            guard parentRaw != RuntimeCompartmentState.invalidIndex else { continue }
            let parent = Int(parentRaw)
            guard parent >= 0 && parent < count else { continue }
            let axial = max(Double(state.compartments[child].axialConductanceMicrosiemens), 0)
            solution[child] = (rhs[child] + axial * solution[parent]) / max(diagonal[child], 1e-18)
        }

        for index in 0..<count {
            state.compartments[index].previousVoltageMillivolts = state.compartments[index].voltageMillivolts
            state.compartments[index].voltageMillivolts = Float(solution[index])
            let base = index * mechanismStride
            state.mechanismState[base + 12] = Float(diagonal[index])
            state.mechanismState[base + 13] = Float(rhs[index])
            state.mechanismState[base + 14] = Float(solution[index])
        }
    }

    public static func detectSpikes(state: inout TissueRuntimeState, tickRange: Range<UInt64>) -> [RoutedEvent] {
        ensureMechanismCapacity(state: &state)
        var spikes: [RoutedEvent] = []
        for index in state.compartments.indices {
            var compartment = state.compartments[index]
            let previous = compartment.previousVoltageMillivolts
            let voltage = compartment.voltageMillivolts
            guard previous < -20, voltage >= -20, tickRange.upperBound >= compartment.refractoryUntilTick else { continue }
            let fraction = min(max((-20 - previous) / max(voltage - previous, 1e-6), 0), 1)
            let crossing = tickRange.lowerBound + UInt64(Float(tickRange.count) * fraction)
            spikes.append(RoutedEvent(
                arrivalTick: crossing,
                source: compartment.id.rawValue,
                destination: compartment.id.rawValue,
                amplitude: 1,
                kind: .spike,
                sequence: UInt32(clamping: index)
            ))
            compartment.refractoryUntilTick = crossing + 80
            state.compartments[index] = compartment
            state.mechanismState[index * mechanismStride + 15] = 1
        }
        return spikes
    }

    public static func route(spikes: [RoutedEvent], state: TissueRuntimeState, tick: UInt64) -> [RoutedEvent] {
        guard !spikes.isEmpty else { return [] }
        var spikingSources = Set<UInt32>()
        for index in state.compartments.indices where index * mechanismStride + 15 < state.mechanismState.count {
            if state.mechanismState[index * mechanismStride + 15] > 0 { spikingSources.insert(UInt32(index)) }
        }
        var events: [RoutedEvent] = []
        events.reserveCapacity(spikingSources.count * 8)
        for (index, synapse) in state.synapses.enumerated() where spikingSources.contains(synapse.sourceRouteIndex) {
            let source = Int(synapse.sourceRouteIndex) < state.compartments.count ? state.compartments[Int(synapse.sourceRouteIndex)].id.rawValue : UInt64(synapse.sourceRouteIndex)
            events.append(RoutedEvent(
                arrivalTick: tick + UInt64(synapse.delayTicks),
                source: source,
                destination: UInt64(index),
                amplitude: 1,
                kind: .spike,
                sequence: UInt32(clamping: index)
            ))
        }
        return events
    }

    public static func clearSpikeFlags(state: inout TissueRuntimeState) {
        guard state.mechanismState.count >= state.compartments.count * mechanismStride else { return }
        for index in state.compartments.indices { state.mechanismState[index * mechanismStride + 15] = 0 }
    }

    public static func updateFields(
        state: inout TissueRuntimeState,
        dtMilliseconds: Float,
        fieldEdge: Int = 32,
        fieldParameters: [GPUFieldParameter]? = nil,
        fastQuantumMilliseconds: Float = 0.025
    ) {
        let width = max(fieldEdge, 1)
        let height = width
        let depth = width
        let voxelCount = width * height * depth
        let channels = 12
        let valuesPerTile = voxelCount * channels
        let stepScale = max(dtMilliseconds, 0) / max(fastQuantumMilliseconds, 1e-6)
        for tile in state.tiles where Int(tile.fieldRange.count) >= valuesPerTile {
            let base = Int(tile.fieldRange.lowerBound)
            guard base >= 0 && base + valuesPerTile <= state.fields.count else { continue }
            for parity in 0...1 {
                for channel in 0..<channels {
                    let channelBase = base + channel * voxelCount
                    for z in 0..<depth {
                        for y in 0..<height {
                            for x in 0..<width where (x + y + z) & 1 == parity {
                                let voxel = x + width * (y + height * z)
                                let index = channelBase + voxel
                                let center = max(state.fields[index].concentration, 0)
                                var sum: Float = 0
                                var neighborCount: Float = 0
                                func add(_ nx: Int, _ ny: Int, _ nz: Int) {
                                    guard nx >= 0, ny >= 0, nz >= 0, nx < width, ny < height, nz < depth else { return }
                                    sum += max(state.fields[channelBase + nx + width * (ny + height * nz)].concentration, 0)
                                    neighborCount += 1
                                }
                                add(x - 1, y, z); add(x + 1, y, z)
                                add(x, y - 1, z); add(x, y + 1, z)
                                add(x, y, z - 1); add(x, y, z + 1)
                                let value = state.fields[index]
                                let laplacian = sum - neighborCount * center
                                let parameter = fieldParameters.flatMap { values in
                                    values.indices.contains(channel) ? values[channel] : nil
                                }
                                let updated: Float
                                if let parameter {
                                    let alpha = max(parameter.dynamics.x, 0) *
                                        max(value.diffusionScale, 0) * stepScale
                                    let decayBase = min(max(parameter.dynamics.y, 0), 1)
                                    let decay = pow(decayBase, stepScale)
                                    let baseline = max(parameter.dynamics.z, 0)
                                    let minimum = parameter.bounds.x
                                    let maximum = max(parameter.bounds.y, minimum)
                                    let decayed = baseline + (center - baseline) * decay
                                    updated = min(max(
                                        decayed + alpha * laplacian +
                                            dtMilliseconds * (value.source - max(value.sink, 0) * center),
                                        minimum
                                    ), maximum)
                                } else {
                                    updated = center + dtMilliseconds * (
                                        max(value.diffusionScale, 0) * laplacian +
                                            value.source - max(value.sink, 0) * center
                                    )
                                }
                                state.fields[index].concentration = max(updated, 0)
                                state.fields[index].source = 0
                                // Source and sink are transaction-local reaction terms. Metal
                                // consumes both in the same field pass; retaining sink here makes
                                // the CPU reference accumulate demand across glial updates and
                                // diverge from the authoritative field equation.
                                state.fields[index].sink = 0
                            }
                        }
                    }
                }
            }
        }
    }

    public static func updateGliaAndMetabolism(
        state: inout TissueRuntimeState,
        dtSeconds: Float,
        fieldEdge: Int = 32,
        cellPrograms: [GPUCellProgram] = [],
        glialPrograms: [GPUGlialProgram] = []
    ) {
        guard !state.tiles.isEmpty else { return }
        let edge = max(fieldEdge, 1)
        let voxelCount = edge * edge * edge
        for index in state.cells.indices {
            var cell = state.cells[index]
            guard Int(cell.tileIndex) < state.tiles.count else { continue }
            let tile = state.tiles[Int(cell.tileIndex)]
            let fieldBase = Int(tile.fieldRange.lowerBound)
            guard Int(tile.fieldRange.count) >= voxelCount * 12,
                  fieldBase >= 0,
                  fieldBase + voxelCount * 12 <= state.fields.count else { continue }
            let local = SIMD3<Float>(
                min(max(cell.position.x, 0), 199.999) / 200,
                min(max(cell.position.y, 0), 199.999) / 200,
                min(max(cell.position.z, 0), 199.999) / 200
            )
            let x = min(Int(local.x * Float(edge)), edge - 1)
            let y = min(Int(local.y * Float(edge)), edge - 1)
            let z = min(Int(local.z * Float(edge)), edge - 1)
            let voxel = x + edge * (y + edge * z)

            @inline(__always)
            func fieldIndex(_ channel: Int) -> Int {
                fieldBase + channel * voxelCount + voxel
            }
            @inline(__always)
            func concentration(_ channel: Int) -> Float {
                max(state.fields[fieldIndex(channel)].concentration, 0)
            }
            @inline(__always)
            func addSource(_ channel: Int, _ amount: Float) {
                guard amount != 0 else { return }
                state.fields[fieldIndex(channel)].source += amount
            }
            @inline(__always)
            func addSink(_ channel: Int, _ amount: Float) {
                guard amount != 0 else { return }
                state.fields[fieldIndex(channel)].sink += amount
            }
            @inline(__always)
            func finiteOr(_ value: Float, _ fallback: Float) -> Float {
                value.isFinite ? value : fallback
            }

            let oxygen = concentration(Int(FieldChannel.oxygen.rawValue))
            let glucose = concentration(Int(FieldChannel.glucose.rawValue))
            let potassium = concentration(Int(FieldChannel.extracellularPotassium.rawValue))
            let glutamate = concentration(Int(FieldChannel.glutamate.rawValue))
            let inflammatory = concentration(Int(FieldChannel.inflammatoryDamage.rawValue))
            let trophicIndex = fieldIndex(Int(FieldChannel.trophicSupport.rawValue))
            let kind: UInt32 = cellPrograms.indices.contains(Int(cell.typeIndex))
                ? cellPrograms[Int(cell.typeIndex)].identity.x
                : UInt32.max
            let glialProgramIndex: Int? = cellPrograms.indices.contains(Int(cell.typeIndex))
                ? Int(cellPrograms[Int(cell.typeIndex)].programIndices.z)
                : nil
            let glialProgram = glialProgramIndex.flatMap { glialPrograms.indices.contains($0) ? glialPrograms[$0] : nil }
            let uptake0 = max(finiteOr(glialProgram?.uptakeRates.x ?? 0.01, 0.01), 0)
            let uptake1 = max(finiteOr(glialProgram?.uptakeRates.y ?? 0.01, 0.01), 0)
            let uptake2 = max(finiteOr(glialProgram?.uptakeRates.z ?? 0.01, 0.01), 0)
            let uptake3 = max(finiteOr(glialProgram?.uptakeRates.w ?? 0.01, 0.01), 0)
            let release0 = max(finiteOr(glialProgram?.releaseRates.x ?? 0.01, 0.01), 0)
            let release1 = max(finiteOr(glialProgram?.releaseRates.y ?? 0.01, 0.01), 0)
            let release2 = max(finiteOr(glialProgram?.releaseRates.z ?? 0.01, 0.01), 0)
            let release3 = max(finiteOr(glialProgram?.releaseRates.w ?? 0.01, 0.01), 0)
            let threshold0 = finiteOr(glialProgram?.activationThresholds.x ?? 3.5, 3.5)
            let threshold1 = finiteOr(glialProgram?.activationThresholds.y ?? 0.01, 0.01)
            let threshold2 = finiteOr(glialProgram?.activationThresholds.z ?? 0.1, 0.1)
            let threshold3 = finiteOr(glialProgram?.activationThresholds.w ?? 0.1, 0.1)

            let electricalDemand = clamp01(tile.activityScore)
            let structuralDemand = clamp01(tile.uncertaintyScore)
            let demand = (0.001 + 0.004 * electricalDemand + 0.002 * structuralDemand) * (1 + clamp01(cell.damage))
            cell.oxygenStress = max(0, cell.oxygenStress + dtSeconds * (oxygen < 0.02 ? 0.5 : -0.1 * cell.oxygenStress))
            cell.glucoseStress = max(0, cell.glucoseStress + dtSeconds * (glucose < 0.05 ? 0.5 : -0.1 * cell.glucoseStress))
            let supplied = min(oxygen * 0.2, glucose * 0.1)
            cell.energyReserve = max(0, cell.energyReserve + dtSeconds * (supplied - demand))
            cell.damage = clamp01(cell.damage + dtSeconds * max(cell.oxygenStress + cell.glucoseStress - 0.5, 0) * 0.01)

            addSink(Int(FieldChannel.oxygen.rawValue), demand * 0.6)
            addSink(Int(FieldChannel.glucose.rawValue), demand * 0.4)

            let regulatory = cell.regulatoryRange
            let regulatoryLower = Int(regulatory.lowerBound)
            let hasRegulatory = regulatory.count >= 4 &&
                regulatoryLower >= 0 &&
                regulatoryLower + 4 <= state.regulatoryState.count &&
                regulatoryLower + 4 <= state.cells.count * 32
            var state0 = hasRegulatory ? state.regulatoryState[regulatoryLower] : 0
            var state1 = hasRegulatory ? state.regulatoryState[regulatoryLower + 1] : 0
            var state2 = hasRegulatory ? state.regulatoryState[regulatoryLower + 2] : 0
            var state3 = hasRegulatory ? state.regulatoryState[regulatoryLower + 3] : 0

            if kind == UInt32(CellKind.astrocyte.rawValue) {
                let ionicDrive = max(potassium - threshold0, 0)
                let transmitterDrive = max(glutamate - threshold1, 0)
                state1 = clamp01(state1 + dtSeconds * (transmitterDrive + 0.25 * ionicDrive - 0.2 * state1))
                state0 = clamp01(state0 + dtSeconds * (state1 + 0.1 * electricalDemand - 0.3 * state0))
                state2 = clamp01(state2 + dtSeconds * (state0 - 0.1 * state2))
                addSink(Int(FieldChannel.extracellularPotassium.rawValue), uptake0 * state2 * ionicDrive)
                addSink(Int(FieldChannel.glutamate.rawValue), uptake1 * state2 * glutamate)
                addSource(Int(FieldChannel.lactate.rawValue), release0 * state2 * glucose)
                addSource(Int(FieldChannel.trophicSupport.rawValue), release1 * state2 * (1 - cell.damage))
                addSource(Int(FieldChannel.extracellularCalcium.rawValue), 0.001 * state0)
            } else if kind == UInt32(CellKind.oligodendrocytePrecursor.rawValue) ||
                        kind == UInt32(CellKind.oligodendrocyte.rawValue) {
                let targetMaturity = kind == UInt32(CellKind.oligodendrocyte.rawValue)
                    ? 1
                    : clamp01(state.fields[trophicIndex].concentration)
                state0 = clamp01(state0 + dtSeconds * 0.02 * (targetMaturity - state0))
                state1 = clamp01(state1 + dtSeconds * (electricalDemand - 0.1 * state1))
                state2 = clamp01(state0 * state1 * cell.energyReserve)
                addSink(Int(FieldChannel.lactate.rawValue), uptake0 * state2 * 0.1)
                addSource(Int(FieldChannel.trophicSupport.rawValue), release0 * state2)
            } else if kind == UInt32(CellKind.microglia.rawValue) {
                let damageDrive = max(max(tile.damageScore, cell.damage) - threshold2, 0)
                let inflammationDrive = max(inflammatory - threshold3, 0)
                state0 = clamp01(state0 + dtSeconds * (damageDrive + inflammationDrive - 0.05 * state0))
                state1 = clamp01(state1 + dtSeconds * (state0 - 0.1 * state1))
                state2 = clamp01(state2 + dtSeconds * (max(state0 - 0.4, 0) - 0.05 * state2))
                state3 = clamp01(state3 + dtSeconds * (damageDrive - uptake3 * state3))
                let inflammatoryRelease = release2 * state2 * (1 - 0.5 * state1)
                addSource(Int(FieldChannel.inflammatoryDamage.rawValue), inflammatoryRelease)
                addSink(Int(FieldChannel.inflammatoryDamage.rawValue), uptake2 * state1 * inflammatory)
                addSource(Int(FieldChannel.trophicSupport.rawValue), release1 * state1 * (1 - state2))
                cell.damage = clamp01(cell.damage - dtSeconds * uptake3 * state1 * cell.damage)
            } else if kind == UInt32(CellKind.endothelial.rawValue) ||
                        kind == UInt32(CellKind.perivascular.rawValue) {
                let perfusionResponse = clamp01(1 - cell.oxygenStress - cell.glucoseStress)
                state0 = clamp01(state0 + dtSeconds * (electricalDemand - 0.05 * state0))
                addSource(Int(FieldChannel.oxygen.rawValue), release0 * perfusionResponse * (1 + state0))
                addSource(Int(FieldChannel.glucose.rawValue), release1 * perfusionResponse * (1 + state0))
                addSink(Int(FieldChannel.inflammatoryDamage.rawValue), uptake2 * inflammatory)
                addSource(Int(FieldChannel.extracellularMatrix.rawValue), release3 * (1 - cell.damage))
            }

            if hasRegulatory {
                state.regulatoryState[regulatoryLower] = state0
                state.regulatoryState[regulatoryLower + 1] = state1
                state.regulatoryState[regulatoryLower + 2] = state2
                state.regulatoryState[regulatoryLower + 3] = state3
            }
            state.cells[index] = cell
        }
    }

    public static func applyPlasticity(state: inout TissueRuntimeState, modulators: SIMD8<Float>, dtSeconds: Float) {
        let signal = modulators[0] + 0.25 * modulators[1] + 0.15 * modulators[2] + 0.05 * modulators[3] - 0.25 * modulators[4] + 0.10 * modulators[5]
        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            let rate: Float = synapse.consolidation > 0.5 ? 2e-5 : 2e-4
            synapse.weight = min(max(synapse.weight + dtSeconds * rate * signal * synapse.eligibility, 0), 1_000)
            synapse.consolidation = clamp01(synapse.consolidation + dtSeconds * max(abs(synapse.eligibility * signal) - 0.01, 0) * 0.001)
            state.synapses[index] = synapse
        }
    }

    public static func updateCellMechanics(state: inout TissueRuntimeState, dtSeconds: Float) {
        let old = state.cells
        for index in old.indices {
            let cell = old[index]
            guard Int(cell.tileIndex) < state.tiles.count else { continue }
            let tile = state.tiles[Int(cell.tileIndex)]
            let lower = Int(tile.cellRange.lowerBound)
            let upper = min(Int(tile.cellRange.upperBound), old.count)
            var force = SIMD3<Float>.zero
            let position = SIMD3(cell.position.x, cell.position.y, cell.position.z)
            let radius = max((cell.semiAxes.x + cell.semiAxes.y + cell.semiAxes.z) / 3, 0.05)
            for otherIndex in lower..<upper where otherIndex != index {
                let other = old[otherIndex]
                let otherPosition = SIMD3(other.position.x, other.position.y, other.position.z)
                let displacement = position - otherPosition
                let distance = max(simdLength(displacement), 1e-4)
                let otherRadius = max((other.semiAxes.x + other.semiAxes.y + other.semiAxes.z) / 3, 0.05)
                let contact = radius + otherRadius
                let direction = displacement / distance
                if distance < contact {
                    let overlap = contact - distance
                    force += direction * (0.5 * overlap + 0.02 * overlap * overlap)
                } else if distance < contact * 1.5 {
                    force -= direction * 0.015 * (1 - (distance - contact) / (0.5 * contact))
                }
            }
            let drag = max(1 + 4 * radius, 1e-4)
            let velocity = force / drag
            state.cells[index].velocity = Float4(velocity.x, velocity.y, velocity.z, 0)
            state.cells[index].position += Float4(velocity.x * dtSeconds, velocity.y * dtSeconds, velocity.z * dtSeconds, 0)
        }
    }

    @discardableResult
    public static func updateDevelopment(state: inout TissueRuntimeState, dtSeconds: Float) -> Int {
        var proposedDivisions = 0
        for index in state.cells.indices {
            var cell = state.cells[index]
            cell.ageSeconds += dtSeconds
            let stress = clamp01(max(cell.oxygenStress, cell.glucoseStress))
            let count = min(Int(cell.regulatoryRange.count), 32)
            let lower = Int(cell.regulatoryRange.lowerBound)
            if lower >= 0 && lower + count <= state.regulatoryState.count {
                let old = Array(state.regulatoryState[lower..<(lower + count)])
                for variable in 0..<count {
                    let value = old[variable]
                    let upstream = variable > 0 ? old[variable - 1] : cell.energyReserve
                    let downstream = variable + 1 < count ? old[variable + 1] : 0
                    state.regulatoryState[lower + variable] = clamp01(value + dtSeconds * (0.05 * upstream + 0.01 * cell.energyReserve - 0.02 * stress - 0.03 * downstream - 0.02 * value))
                }
                let fate = state.regulatoryState[lower + min(count - 1, 7)]
                cell.differentiationProgress = clamp01(cell.differentiationProgress + dtSeconds * max(fate - 0.5, 0) * 0.001)
            }
            cell.cycleProgress += dtSeconds * max(0, 0.001 * cell.energyReserve * (1 - cell.damage) * (1 - stress))
            cell.apoptosisHazard = max(0, 0.01 * stress + 0.02 * cell.damage - 0.005 * cell.energyReserve)
            if cell.cycleProgress >= 1 {
                proposedDivisions += 1
                cell.cycleProgress = 0
            }
            state.cells[index] = cell
        }

        for index in state.segments.indices where (state.segments[index].flags & 1) != 0 {
            let direction4 = state.segments[index].end - state.segments[index].start
            let direction = normalized(SIMD3(direction4.x, direction4.y, direction4.z))
            let distance = state.segments[index].growthRateMicrometersPerSecond * dtSeconds
            state.segments[index].start = state.segments[index].end
            state.segments[index].end += Float4(direction.x * distance, direction.y * distance, direction.z * distance, 0)
            state.segments[index].structuralScore = clamp01(state.segments[index].structuralScore + 0.001 * distance)
        }
        return proposedDivisions
    }

    @discardableResult
    public static func updateStructuralPlasticity(state: inout TissueRuntimeState) -> Int {
        var mutations = 0
        for index in state.synapses.indices {
            var synapse = state.synapses[index]
            synapse.structuralScore = clamp01(synapse.structuralScore + 0.01 * abs(synapse.eligibility) + 0.005 * synapse.consolidation - (synapse.weight < 1e-6 ? 0.002 : 0))
            if synapse.structuralScore < 0.01 && synapse.consolidation < 0.05 {
                synapse.flags |= 1
                synapse.weight = 0
                synapse.conductance = 0
                mutations += 1
            }
            state.synapses[index] = synapse
        }
        return mutations
    }

    public static func collectOutput(state: TissueRuntimeState, start: TissueTime, end: TissueTime) -> RuntimeOutputFrame {
        var output = RuntimeOutputFrame(startTime: start, endTime: end)
        output.populationActivity.reserveCapacity(state.tiles.count)
        output.localFieldPotentials.reserveCapacity(state.tiles.count)
        output.metabolicDemand.reserveCapacity(state.tiles.count)
        for tile in state.tiles {
            let lower = Int(tile.compartmentRange.lowerBound)
            let upper = min(Int(tile.compartmentRange.upperBound), state.compartments.count)
            if lower < upper {
                let voltages = state.compartments[lower..<upper].map(\.voltageMillivolts)
                output.localFieldPotentials.append(voltages.reduce(0, +) / Float(voltages.count))
            } else {
                output.localFieldPotentials.append(0)
            }
            output.populationActivity.append(tile.activityScore)
            output.metabolicDemand.append(tile.metabolicStress)
        }
        output.uncertainty = state.tiles.map(\.uncertaintyScore).max() ?? 0
        output.plasticityMagnitude = state.synapses.isEmpty ? 0 : state.synapses.reduce(0) { $0 + abs($1.eligibility) } / Float(state.synapses.count)
        return output
    }

    private static func ensureMechanismCapacity(state: inout TissueRuntimeState) {
        let required = state.compartments.count * mechanismStride
        if state.mechanismState.count < required {
            state.mechanismState.append(contentsOf: repeatElement(0, count: required - state.mechanismState.count))
        }
    }

    private static func depth(of index: Int, compartments: [RuntimeCompartmentState]) -> Int {
        var depth = 0
        var current = index
        var visited = Set<Int>()
        while current >= 0 && current < compartments.count {
            guard visited.insert(current).inserted else { return depth }
            let parent = compartments[current].parentIndex
            if parent == RuntimeCompartmentState.invalidIndex { return depth }
            current = Int(parent)
            depth += 1
        }
        return depth
    }

    private static func alphaBetaM(_ v: Double) -> (Double, Double) {
        (0.1 * vtrap(-(v + 40), 10), 4 * exp(-(v + 65) / 18))
    }

    private static func alphaBetaH(_ v: Double) -> (Double, Double) {
        (0.07 * exp(-(v + 65) / 20), 1 / (exp(-(v + 35) / 10) + 1))
    }

    private static func alphaBetaN(_ v: Double) -> (Double, Double) {
        (0.01 * vtrap(-(v + 55), 10), 0.125 * exp(-(v + 65) / 80))
    }

    private static func vtrap(_ x: Double, _ y: Double) -> Double {
        abs(x / y) < 1e-7 ? y * (1 - 0.5 * x / y) : x / expm1(x / y)
    }

    private static func rushLarsen(_ state: Double, alpha: Double, beta: Double, dt: Double) -> Double {
        let sum = max(alpha + beta, 1e-12)
        let infinity = alpha / sum
        return infinity + (state - infinity) * exp(-sum * dt)
    }

    private static func boundedGate(_ value: Float, fallback: Double) -> Double {
        value.isFinite && value >= 0 && value <= 1 ? Double(value) : fallback
    }

    private static func positiveOr(_ value: Float, _ fallback: Float) -> Float { value.isFinite && value > 0 ? value : fallback }
    private static func finiteNonzeroOr(_ value: Float, _ fallback: Float) -> Float { value.isFinite && value != 0 ? value : fallback }
    private static func clamp01(_ value: Float) -> Float { min(max(value, 0), 1) }
    private static func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }

    private static func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let length = simdLength(vector)
        return length > 1e-8 ? vector / length : SIMD3(1, 0, 0)
    }

    private static func simdLength(_ vector: SIMD3<Float>) -> Float {
        sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
    }
}
