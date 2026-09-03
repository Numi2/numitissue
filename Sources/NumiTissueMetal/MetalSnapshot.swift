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

        var staging: [MTLBuffer] = []
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
        try await context.awaitCompletion(command)

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
        RuntimeTileState(
            id: TileID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            coordinate: TileCoordinate(x: coordinate.x, y: coordinate.y, z: coordinate.z),
            cellRange: cellRange.runtimeRange,
            segmentRange: segmentRange.runtimeRange,
            compartmentRange: compartmentRange.runtimeRange,
            synapseRange: synapseRange.runtimeRange,
            fieldRange: fieldRange.runtimeRange,
            microdomainRange: microdomainRange.runtimeRange,
            activityScore: scores.x,
            uncertaintyScore: scores.y,
            damageScore: scores.z,
            metabolicStress: scores.w,
            flags: flags,
            lastActiveTick: UInt64(lastActiveTickLo) | (UInt64(lastActiveTickHi) << 32)
        )
    }
}

private extension MetalCellState {
    var runtimeState: RuntimeCellState {
        RuntimeCellState(
            id: CellID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            lineageID: LineageID(rawValue: UInt64(lineageLo) | (UInt64(lineageHi) << 32)),
            tileIndex: tileIndex,
            typeIndex: UInt16(truncatingIfNeeded: typeAndDevelopment),
            developmentalState: DevelopmentalState(rawValue: UInt16(truncatingIfNeeded: typeAndDevelopment >> 16)) ?? .progenitor,
            fidelity: FidelityLevel(rawValue: UInt8(truncatingIfNeeded: fidelityAndFlags)) ?? .cellAgent,
            position: position,
            orientation: orientationAndRadius,
            semiAxes: semiAxes,
            velocity: velocity,
            ageSeconds: ageCycleDifferentiationEnergy.x,
            cycleProgress: ageCycleDifferentiationEnergy.y,
            differentiationProgress: ageCycleDifferentiationEnergy.z,
            energyReserve: ageCycleDifferentiationEnergy.w,
            oxygenStress: stressDamageHazard.x,
            glucoseStress: stressDamageHazard.y,
            damage: stressDamageHazard.z,
            apoptosisHazard: stressDamageHazard.w,
            regulatoryRange: regulatoryRange.runtimeRange,
            flags: fidelityAndFlags >> 16
        )
    }
}

private extension MetalSegmentState {
    var runtimeState: RuntimeSegmentState {
        RuntimeSegmentState(
            id: SegmentID(rawValue: UInt64(idLo) | (UInt64(idHi) << 32)),
            cellIndex: cellIndex,
            parentSegmentIndex: parentSegmentIndex,
            compartmentIndex: compartmentIndex,
            kind: SegmentKind(rawValue: UInt16(truncatingIfNeeded: typeAndFlags)) ?? .soma,
            start: start,
            end: end,
            radiusMicrometers: radiusMyelinGrowthScore.x,
            myelinFraction: radiusMyelinGrowthScore.y,
            growthRateMicrometersPerSecond: radiusMyelinGrowthScore.z,
            structuralScore: radiusMyelinGrowthScore.w,
            flags: UInt16(truncatingIfNeeded: typeAndFlags >> 16)
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
            lastEventTick: UInt64(lastEventTickLo) | (UInt64(lastEventTickHi) << 32),
            structuralScore: structuralReserved.x
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
            speciesRange: speciesRange.runtimeRange,
            reactionNetworkIndex: UInt16(truncatingIfNeeded: reactionSolverFlags),
            solverKind: MolecularSolverKind(rawValue: UInt8(truncatingIfNeeded: reactionSolverFlags >> 16)) ?? .deterministic,
            flags: UInt8(truncatingIfNeeded: reactionSolverFlags >> 24),
            volumeFemtoliters: volumeTemperaturePropensityReserved.x,
            temperatureKelvin: volumeTemperaturePropensityReserved.y,
            totalPropensity: volumeTemperaturePropensityReserved.z
        )
    }
}

private extension MetalRange {
    var runtimeRange: RuntimeRange {
        RuntimeRange(lowerBound: lowerBound, count: count)
    }
}
#endif
