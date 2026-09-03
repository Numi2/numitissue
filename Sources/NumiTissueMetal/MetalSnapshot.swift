#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

public extension MetalStateArena {
    func downloadCommittedState() async throws -> TissueRuntimeState {
        try await downloadState(
            from: committed,
            template: committedCPUState,
            label: "NumiTissue.snapshot.committed"
        )
    }

    /// Downloads the transaction shadow using the committed topology only as a count and identity
    /// template. This is used after GPU validation to derive fidelity and structural migrations
    /// without making the CPU authoritative during the fast path.
    func downloadShadowState() async throws -> TissueRuntimeState {
        try await downloadState(
            from: shadow,
            template: committedCPUState,
            label: "NumiTissue.snapshot.shadow"
        )
    }

    private func downloadState(
        from buffers: MetalStateBufferSet,
        template: TissueRuntimeState,
        label: String
    ) async throws -> TissueRuntimeState {
        let command = try context.makeTransferCommandBuffer(label: label)
        guard let blit = command.makeBlitCommandEncoder() else {
            throw MetalRuntimeError.encoderCreationFailed(label)
        }
        context.telemetry.recordBlitEncoder()

        var staging: [MTLBuffer] = []
        var readbackBytes = 0
        func stage(source: MTLBuffer, bytes: Int, name: String) throws -> MTLBuffer {
            let length = max(bytes, 1)
            let target = try context.makeSharedBuffer(
                length: length,
                label: "\(label).\(name)"
            )
            if bytes > 0 {
                blit.copy(
                    from: source,
                    sourceOffset: 0,
                    to: target,
                    destinationOffset: 0,
                    size: bytes
                )
                readbackBytes += bytes
            }
            staging.append(target)
            return target
        }

        let tileStage = try stage(source: buffers.tiles, bytes: template.tiles.count * MemoryLayout<MetalTileState>.stride, name: "tiles")
        let cellStage = try stage(source: buffers.cells, bytes: template.cells.count * MemoryLayout<MetalCellState>.stride, name: "cells")
        let regulatoryStage = try stage(source: buffers.regulatoryState, bytes: template.regulatoryState.count * MemoryLayout<Float>.stride, name: "regulatory")
        let segmentStage = try stage(source: buffers.segments, bytes: template.segments.count * MemoryLayout<MetalSegmentState>.stride, name: "segments")
        let compartmentStage = try stage(source: buffers.compartments, bytes: template.compartments.count * MemoryLayout<MetalCompartmentState>.stride, name: "compartments")
        let mechanismStage = try stage(source: buffers.mechanismState, bytes: template.mechanismState.count * MemoryLayout<Float>.stride, name: "mechanisms")
        let synapseStage = try stage(source: buffers.synapses, bytes: template.synapses.count * MemoryLayout<MetalSynapseState>.stride, name: "synapses")
        let fieldStage = try stage(source: buffers.fields, bytes: template.fields.count * MemoryLayout<MetalFieldState>.stride, name: "fields")
        let microdomainStage = try stage(source: buffers.microdomains, bytes: template.microdomains.count * MemoryLayout<MetalMicrodomainState>.stride, name: "microdomains")
        let molecularStage = try stage(source: buffers.molecularSpecies, bytes: template.molecularSpecies.count * MemoryLayout<Float>.stride, name: "molecular")
        blit.endEncoding()
        context.telemetry.recordReadback(bytes: readbackBytes)
        try await context.awaitCompletion(MetalCommandBufferHandle(command))

        var state = template
        state.tiles = Self.read(MetalTileState.self, from: tileStage, count: template.tiles.count).map(\.runtimeState)
        state.cells = Self.read(MetalCellState.self, from: cellStage, count: template.cells.count).map(\.runtimeState)
        state.regulatoryState = Self.read(Float.self, from: regulatoryStage, count: template.regulatoryState.count)
        state.segments = Self.read(MetalSegmentState.self, from: segmentStage, count: template.segments.count).map(\.runtimeState)
        state.compartments = Self.read(MetalCompartmentState.self, from: compartmentStage, count: template.compartments.count).map(\.runtimeState)
        state.mechanismState = Self.read(Float.self, from: mechanismStage, count: template.mechanismState.count)
        state.synapses = Self.read(MetalSynapseState.self, from: synapseStage, count: template.synapses.count).map(\.runtimeState)
        state.fields = Self.read(MetalFieldState.self, from: fieldStage, count: template.fields.count).map(\.runtimeState)
        state.microdomains = Self.read(MetalMicrodomainState.self, from: microdomainStage, count: template.microdomains.count).map(\.runtimeState)
        state.molecularSpecies = Self.read(Float.self, from: molecularStage, count: template.molecularSpecies.count)
        _ = staging
        return state
    }

    private static func read<T>(_ type: T.Type, from buffer: MTLBuffer, count: Int) -> [T] {
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

private extension MetalTileState {
    var runtimeState: RuntimeTileState {
        var result = RuntimeTileState(
            id: TileID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            coordinate: TileCoordinate(x: coordinate.x, y: coordinate.y, z: coordinate.z)
        )
        result.flags = flags
        result.fidelityMask = fidelityMask
        result.cellRange = cellRange.runtimeRange
        result.segmentRange = segmentRange.runtimeRange
        result.compartmentRange = compartmentRange.runtimeRange
        result.synapseRange = synapseRange.runtimeRange
        result.fieldRange = fieldRange.runtimeRange
        result.microdomainRange = microdomainRange.runtimeRange
        result.lastActiveTick = UInt64(lastActiveTickLo) | (UInt64(lastActiveTickHi) << 32)
        result.activityScore = scores.x
        result.uncertaintyScore = scores.y
        result.damageScore = scores.z
        result.metabolicStress = scores.w
        return result
    }
}

private extension MetalCellState {
    var runtimeState: RuntimeCellState {
        var result = RuntimeCellState(
            id: CellID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            lineage: LineageID(rawValue: UInt64(lineageLo) | (UInt64(lineageHi) << 32)),
            tileIndex: tileIndex,
            typeIndex: UInt16(truncatingIfNeeded: typeAndDevelopment),
            developmentalState: UInt16(truncatingIfNeeded: typeAndDevelopment >> 16),
            fidelity: FidelityLevel(rawValue: UInt8(truncatingIfNeeded: fidelityAndFlags)) ?? .cellAgent,
            position: position,
            orientation: orientation,
            semiAxes: semiAxes
        )
        result.velocity = velocity
        result.ageSeconds = ageCycleDifferentiationEnergy.x
        result.cycleProgress = ageCycleDifferentiationEnergy.y
        result.differentiationProgress = ageCycleDifferentiationEnergy.z
        result.energyReserve = ageCycleDifferentiationEnergy.w
        result.oxygenStress = stressDamageHazard.x
        result.glucoseStress = stressDamageHazard.y
        result.damage = stressDamageHazard.z
        result.apoptosisHazard = stressDamageHazard.w
        result.regulatoryRange = regulatoryRange.runtimeRange
        result.flags = UInt8(truncatingIfNeeded: fidelityAndFlags >> 8)
        return result
    }
}

private extension MetalSegmentState {
    var runtimeState: RuntimeSegmentState {
        RuntimeSegmentState(
            id: SegmentID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            cellIndex: cellIndex,
            parentSegmentIndex: parentSegmentIndex,
            firstChildIndex: firstChildIndex,
            nextSiblingIndex: nextSiblingIndex,
            compartmentIndex: compartmentIndex,
            type: UInt16(truncatingIfNeeded: typeAndFlags),
            flags: UInt16(truncatingIfNeeded: typeAndFlags >> 16),
            start: start,
            end: end,
            radiusMicrometers: radiusMyelinGrowthScore.x,
            myelinFraction: radiusMyelinGrowthScore.y,
            growthRateMicrometersPerSecond: radiusMyelinGrowthScore.z,
            structuralScore: radiusMyelinGrowthScore.w
        )
    }
}

private extension MetalCompartmentState {
    var runtimeState: RuntimeCompartmentState {
        RuntimeCompartmentState(
            id: CompartmentID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            neuronIndex: neuronIndex,
            parentIndex: parentIndex,
            mechanismRange: mechanismRange.runtimeRange,
            synapseRange: synapseRange.runtimeRange,
            voltageMillivolts: voltagePreviousCapacitanceAxial.x,
            previousVoltageMillivolts: voltagePreviousCapacitanceAxial.y,
            capacitanceNanofarads: voltagePreviousCapacitanceAxial.z,
            axialConductanceMicrosiemens: voltagePreviousCapacitanceAxial.w,
            injectedCurrentNanoamps: injectedSynapticCalciumSodium.x,
            synapticCurrentNanoamps: injectedSynapticCalciumSodium.y,
            intracellularCalciumMicromolar: injectedSynapticCalciumSodium.z,
            intracellularSodiumMillimolar: injectedSynapticCalciumSodium.w,
            intracellularPotassiumMillimolar: potassiumReserved.x,
            refractoryUntilTick: UInt64(refractoryTickLo) | (UInt64(refractoryTickHi) << 32),
            flags: flags
        )
    }
}

private extension MetalSynapseState {
    var runtimeState: RuntimeSynapseState {
        RuntimeSynapseState(
            id: SynapseID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            sourceRouteIndex: sourceRouteIndex,
            targetCompartmentIndex: targetCompartmentIndex,
            parameterIndex: UInt16(truncatingIfNeeded: parameterAndFlags),
            flags: UInt16(truncatingIfNeeded: parameterAndFlags >> 16),
            delayTicks: delayTicks,
            weight: weightConductanceUtilizationResources.x,
            conductance: weightConductanceUtilizationResources.y,
            shortTermUtilization: weightConductanceUtilizationResources.z,
            shortTermResources: weightConductanceUtilizationResources.w,
            preTrace: prePostEligibilityConsolidation.x,
            postTrace: prePostEligibilityConsolidation.y,
            eligibility: prePostEligibilityConsolidation.z,
            consolidation: prePostEligibilityConsolidation.w,
            structuralScore: structuralReserved.x,
            lastEventTick: UInt64(lastEventTickLo) | (UInt64(lastEventTickHi) << 32)
        )
    }
}

private extension MetalFieldState {
    var runtimeState: RuntimeFieldState {
        RuntimeFieldState(
            concentration: concentrationSourceSinkDiffusion.x,
            source: concentrationSourceSinkDiffusion.y,
            sink: concentrationSourceSinkDiffusion.z,
            diffusionScale: concentrationSourceSinkDiffusion.w
        )
    }
}

private extension MetalMicrodomainState {
    var runtimeState: RuntimeMicrodomainState {
        RuntimeMicrodomainState(
            id: MicrodomainID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            ownerCellIndex: ownerCellIndex,
            ownerCompartmentIndex: ownerCompartmentIndex,
            reactionNetworkIndex: UInt16(truncatingIfNeeded: reactionSolverFlags),
            solverKind: UInt8(truncatingIfNeeded: reactionSolverFlags >> 16),
            flags: UInt8(truncatingIfNeeded: reactionSolverFlags >> 24),
            speciesRange: speciesRange.runtimeRange,
            volumeFemtoliters: volumeTemperaturePropensityReserved.x,
            temperatureKelvin: volumeTemperaturePropensityReserved.y,
            propensitySum: volumeTemperaturePropensityReserved.z
        )
    }
}

private extension MetalRange {
    var runtimeRange: RuntimeRange {
        RuntimeRange(lowerBound: lowerBound, count: count)
    }
}
#endif