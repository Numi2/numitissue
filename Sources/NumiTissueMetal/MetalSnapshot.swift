#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

public extension MetalStateArena {
    func downloadCommittedState() async throws -> TissueRuntimeState {
        let template = committedCPUState
        let tileStaging = try stagingBuffer(count: template.tiles.count, type: MetalTileState.self, label: "snapshot.tiles")
        let cellStaging = try stagingBuffer(count: template.cells.count, type: MetalCellState.self, label: "snapshot.cells")
        let regulatoryStaging = try stagingBuffer(count: template.regulatoryState.count, type: Float.self, label: "snapshot.regulatory")
        let segmentStaging = try stagingBuffer(count: template.segments.count, type: MetalSegmentState.self, label: "snapshot.segments")
        let compartmentStaging = try stagingBuffer(count: template.compartments.count, type: MetalCompartmentState.self, label: "snapshot.compartments")
        let mechanismStaging = try stagingBuffer(count: template.mechanismState.count, type: Float.self, label: "snapshot.mechanisms")
        let synapseStaging = try stagingBuffer(count: template.synapses.count, type: MetalSynapseState.self, label: "snapshot.synapses")
        let fieldStaging = try stagingBuffer(count: template.fields.count, type: MetalFieldState.self, label: "snapshot.fields")
        let microdomainStaging = try stagingBuffer(count: template.microdomains.count, type: MetalMicrodomainState.self, label: "snapshot.microdomains")
        let molecularStaging = try stagingBuffer(count: template.molecularSpecies.count, type: Float.self, label: "snapshot.molecular")

        let command = try context.makeTransferCommandBuffer(label: "NumiTissue.snapshot")
        guard let blit = command.makeBlitCommandEncoder() else { throw MetalRuntimeError.encoderCreationFailed("snapshot") }
        copyIfNeeded(from: committed.tiles, to: tileStaging, count: template.tiles.count, type: MetalTileState.self, blit: blit)
        copyIfNeeded(from: committed.cells, to: cellStaging, count: template.cells.count, type: MetalCellState.self, blit: blit)
        copyIfNeeded(from: committed.regulatoryState, to: regulatoryStaging, count: template.regulatoryState.count, type: Float.self, blit: blit)
        copyIfNeeded(from: committed.segments, to: segmentStaging, count: template.segments.count, type: MetalSegmentState.self, blit: blit)
        copyIfNeeded(from: committed.compartments, to: compartmentStaging, count: template.compartments.count, type: MetalCompartmentState.self, blit: blit)
        copyIfNeeded(from: committed.mechanismState, to: mechanismStaging, count: template.mechanismState.count, type: Float.self, blit: blit)
        copyIfNeeded(from: committed.synapses, to: synapseStaging, count: template.synapses.count, type: MetalSynapseState.self, blit: blit)
        copyIfNeeded(from: committed.fields, to: fieldStaging, count: template.fields.count, type: MetalFieldState.self, blit: blit)
        copyIfNeeded(from: committed.microdomains, to: microdomainStaging, count: template.microdomains.count, type: MetalMicrodomainState.self, blit: blit)
        copyIfNeeded(from: committed.molecularSpecies, to: molecularStaging, count: template.molecularSpecies.count, type: Float.self, blit: blit)
        blit.endEncoding()
        try await context.awaitCompletion(command)

        var result = template
        result.tiles = read(tileStaging, count: template.tiles.count, as: MetalTileState.self).map(\.runtimeState)
        result.cells = read(cellStaging, count: template.cells.count, as: MetalCellState.self).map(\.runtimeState)
        result.regulatoryState = read(regulatoryStaging, count: template.regulatoryState.count, as: Float.self)
        result.segments = read(segmentStaging, count: template.segments.count, as: MetalSegmentState.self).map(\.runtimeState)
        result.compartments = read(compartmentStaging, count: template.compartments.count, as: MetalCompartmentState.self).map(\.runtimeState)
        result.mechanismState = read(mechanismStaging, count: template.mechanismState.count, as: Float.self)
        result.synapses = read(synapseStaging, count: template.synapses.count, as: MetalSynapseState.self).map(\.runtimeState)
        result.fields = read(fieldStaging, count: template.fields.count, as: MetalFieldState.self).map(\.runtimeState)
        result.microdomains = read(microdomainStaging, count: template.microdomains.count, as: MetalMicrodomainState.self).map(\.runtimeState)
        result.molecularSpecies = read(molecularStaging, count: template.molecularSpecies.count, as: Float.self)
        return result
    }

    private func stagingBuffer<T>(count: Int, type: T.Type, label: String) throws -> MTLBuffer {
        try context.makeSharedBuffer(length: max(1, count) * MemoryLayout<T>.stride, label: "NumiTissue.\(label)")
    }

    private func copyIfNeeded<T>(from source: MTLBuffer, to destination: MTLBuffer, count: Int, type: T.Type, blit: MTLBlitCommandEncoder) {
        guard count > 0 else { return }
        blit.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0, size: count * MemoryLayout<T>.stride)
    }

    private func read<T>(_ buffer: MTLBuffer, count: Int, as type: T.Type) -> [T] {
        guard count > 0 else { return [] }
        let pointer = buffer.contents().bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}

private extension MetalRange {
    var runtimeRange: RuntimeRange { RuntimeRange(lowerBound: lowerBound, count: count) }
}

private extension MetalTileState {
    var runtimeState: TileRuntimeState {
        var result = TileRuntimeState(
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
        let type = UInt16(truncatingIfNeeded: typeAndDevelopment)
        let developmental = UInt16(truncatingIfNeeded: typeAndDevelopment >> 16)
        let rawFidelity = UInt8(truncatingIfNeeded: fidelityAndFlags)
        var result = RuntimeCellState(
            id: CellID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            lineage: LineageID(rawValue: UInt64(lineageLo) | (UInt64(lineageHi) << 32)),
            tileIndex: tileIndex,
            typeIndex: type,
            developmentalState: developmental,
            fidelity: FidelityLevel(rawValue: rawFidelity) ?? .cellAgent,
            position: position,
            orientation: orientation,
            semiAxes: semiAxes
        )
        result.flags = UInt8(truncatingIfNeeded: fidelityAndFlags >> 8)
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
    var runtimeState: RuntimeFieldValue {
        RuntimeFieldValue(
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
            nextEventTick: UInt64(nextEventTickLo) | (UInt64(nextEventTickHi) << 32),
            propensitySum: volumeTemperaturePropensityReserved.z
        )
    }
}
#endif
