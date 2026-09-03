#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal
import NumiTissueRuntime

@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
extension Metal4TissueBackend {
    public func execute(
        phase: RuntimePhase,
        tickRange: Range<UInt64>,
        context executionContext: ExecutionContext
    ) async throws {
        guard let arena,
              let modelBuffers,
              let biologyMetadata,
              let model else {
            throw MetalRuntimeError.noOpenTransaction
        }
        guard currentContext?.transaction == executionContext.transaction else {
            throw RuntimeExecutionError.staleTransaction
        }

        var header = MetalSimulationHeader(
            state: arena.committedCPUState,
            context: executionContext,
            fieldGridEdge: model.configuration.tile.fieldGridEdge,
            phase: phase,
            phaseRange: tickRange
        )
        header.reserved0.x = UInt32(clamping:
            currentInput?.afferentEvents.count ?? 0
        )
        header.reserved0.y = UInt32(clamping:
            currentInput?.stimuli.count ?? 0
        )
        header.reserved0.z = UInt32(clamping:
            biologyMetadata.regulatoryProgramCount
        )
        header.reserved0.w = UInt32(clamping:
            biologyMetadata.fateTransitionCount
        )
        header.reserved1.y = UInt32(clamping:
            arena.transient.validationCapacity
        )
        header.reserved1.z = UInt32(clamping:
            biologyMetadata.glialProgramCount
        )
        header.reserved1.w = UInt32(clamping:
            biologyMetadata.growthProgramCount
        )
        header.reserved2.y = UInt32(clamping:
            biologyMetadata.synapseParameterCount
        )
        header.reserved2.z = UInt32(clamping:
            biologyMetadata.fieldParameterCount
        )
        header.reserved2.w = UInt32(clamping:
            modelBuffers.cellProgramCount
        )
        header.reserved3.x = UInt32(clamping:
            modelBuffers.networkCount
        )
        header.reserved3.y = UInt32(clamping:
            modelBuffers.reactionCount
        )
        header.reserved3.z = UInt32(clamping:
            modelBuffers.channelCount
        )
        header.reserved3.w = UInt32(clamping:
            modelBuffers.mechanismSetCount
        )

        switch phase {
        case .ingestInputs:
            try await encodeKernel(
                .ingestInputEvents,
                count: max(
                    Int(header.reserved0.x),
                    Int(header.reserved0.y)
                ),
                header: header
            )

        case .buildWorklists:
            try await encodeKernel(
                .buildWorklists,
                count: Int(header.tileCount),
                header: header
            )
            try await encodeKernel(
                .encodeIndirectDispatch,
                count: 7,
                header: header
            )

        case .deliverEvents:
            try await encodeKernel(
                .sortEventBucket,
                count: 1,
                header: header
            )
            try await encodeKernel(
                .deliverEvents,
                count: 1,
                header: header,
                additionalBuffers: parameterBindings(
                    [.synapseParameter],
                    startingAt: 1
                )
            )
            if tickRange.upperBound > tickRange.lowerBound,
               tickRange.upperBound.isMultiple(
                    of: executionContext.cadence.routingBlockTicks
               ) {
                try await encodeKernel(
                    .clearEventBucket,
                    count: 1,
                    header: header
                )
            }

        case .decaySynapses:
            try await encodeKernel(
                .decaySynapses,
                count: Int(header.synapseCount),
                header: header,
                additionalBuffers: parameterBindings(
                    [.synapseParameter],
                    startingAt: 1
                )
            )

        case .updateChannels:
            var bindings: [Metal4BufferBinding] = [
                .init(index: 1, buffer: modelBuffers.channelMetadata),
                .init(index: 2, buffer: modelBuffers.mechanismSetMetadata)
            ]
            bindings += parameterBindings(
                [
                    .channelParameter,
                    .mechanismSetParameter,
                    .cellProgramParameter
                ],
                startingAt: 3
            )
            try await encodeKernel(
                .updateChannels,
                count: Int(header.compartmentCount),
                header: header,
                additionalBuffers: bindings
            )

        case .solveCableTrees:
            try await encodeCableSolve(header: header)

        case .detectSpikes:
            try await encodeKernel(
                .detectSpikes,
                count: Int(header.compartmentCount),
                header: header,
                additionalBuffers: parameterBindings(
                    [.cellProgramParameter],
                    startingAt: 1
                )
            )

        case .routeSpikes:
            try await encodeKernel(
                .routeSpikes,
                count: Int(header.synapseCount),
                header: header
            )
            try await encodeKernel(
                .clearSpikeFlags,
                count: Int(header.compartmentCount),
                header: header
            )

        case .updateFastFields:
            let bindings = parameterBindings(
                [.fieldParameter],
                startingAt: 1
            )
            var parity0 = header
            parity0.reserved2.x = 0
            try await encodeKernel(
                .updateFastFields,
                count: Int(header.fieldValueCount),
                header: parity0,
                additionalBuffers: bindings
            )
            var parity1 = header
            parity1.reserved2.x = 1
            try await encodeKernel(
                .updateFastFields,
                count: Int(header.fieldValueCount),
                header: parity1,
                additionalBuffers: bindings
            )

        case .updateMolecularDomains:
            var bindings: [Metal4BufferBinding] = [
                .init(index: 1, buffer: modelBuffers.molecularNetworks),
                .init(index: 2, buffer: modelBuffers.molecularReactions)
            ]
            bindings += parameterBindings(
                [.molecularReactionParameter],
                startingAt: 3
            )
            try await encodeKernel(
                .updateMolecularDomains,
                count: Int(header.microdomainCount),
                header: header,
                additionalBuffers: bindings
            )

        case .updateGliaAndMetabolism:
            let common: [Metal4BufferBinding] = [
                .init(index: 1, buffer: modelBuffers.cellProgramIdentity),
                .init(index: 2, buffer: modelBuffers.cellProgramMetadata)
            ] + parameterBindings(
                [.glialProgramParameter, .fieldParameter],
                startingAt: 3
            )
            try await encodeKernel(
                .updateGliaAndMetabolism,
                count: Int(header.cellCount),
                header: header,
                additionalBuffers: common
            )
            try await encodeKernel(
                .updateMyelination,
                count: Int(header.segmentCount),
                header: header,
                additionalBuffers: Array(common.prefix(3))
            )
            try await encodeKernel(
                .updateMicroglialPruning,
                count: Int(header.synapseCount),
                header: header,
                additionalBuffers: Array(common.prefix(3))
            )

        case .applyPlasticity:
            try await encodeKernel(
                .applyPlasticity,
                count: Int(header.synapseCount),
                header: header,
                additionalBuffers: parameterBindings(
                    [.synapseParameter],
                    startingAt: 1
                )
            )

        case .updateCellMechanics:
            try await encodeKernel(
                .updateCellMechanics,
                count: Int(header.cellCount),
                header: header,
                additionalBuffers: parameterBindings(
                    [.cellProgramParameter],
                    startingAt: 1
                )
            )

        case .updateDevelopment:
            var bindings: [Metal4BufferBinding] = [
                .init(index: 1, buffer: modelBuffers.cellProgramIdentity),
                .init(index: 2, buffer: modelBuffers.cellProgramMetadata),
                .init(index: 3, buffer: biologyMetadata.regulatoryStateAndMatrix),
                .init(index: 4, buffer: biologyMetadata.regulatoryBiasAndTransition),
                .init(index: 5, buffer: biologyMetadata.regulatoryMatrix),
                .init(index: 6, buffer: biologyMetadata.regulatoryBias),
                .init(index: 7, buffer: biologyMetadata.fateIdentity)
            ]
            bindings += parameterBindings(
                [
                    .regulatoryProgramParameter,
                    .fateTransitionParameter,
                    .growthProgramParameter,
                    .cellProgramParameter
                ],
                startingAt: 8
            )
            try await encodeKernel(
                .updateDevelopment,
                count: max(
                    Int(header.cellCount),
                    Int(header.segmentCount)
                ),
                header: header,
                additionalBuffers: bindings
            )

        case .updateStructuralPlasticity:
            try await encodeKernel(
                .updateStructuralPlasticity,
                count: Int(header.synapseCount),
                header: header,
                additionalBuffers: parameterBindings(
                    [.synapseParameter],
                    startingAt: 1
                )
            )

        case .updateAdaptiveFidelity:
            try await encodeKernel(
                .updateAdaptiveFidelity,
                count: Int(header.cellCount),
                header: header
            )

        case .collectOutputs:
            try await encodeKernel(
                .collectOutputs,
                count: max(
                    Int(header.tileCount),
                    Int(header.eventCapacity)
                ),
                header: header
            )

        case .validate:
            let count = [
                Int(header.cellCount),
                Int(header.compartmentCount),
                Int(header.synapseCount),
                Int(header.fieldValueCount),
                Int(header.microdomainCount),
                Int(header.molecularSpeciesCount)
            ].max() ?? 0
            try await encodeKernel(
                .validateState,
                count: count,
                header: header
            )
        }

        try await finishPhaseGroupIfRequired(after: phase)
    }

    func encodeKernel(
        _ kernel: MetalKernel,
        count: Int,
        header: MetalSimulationHeader,
        additionalBuffers: [Metal4BufferBinding] = []
    ) async throws {
        guard count > 0 else { return }
        guard let arena,
              let shaders = shaderLibrary,
              let ring = phaseHeaderRing,
              let root = argumentTables[ObjectIdentifier(arena.shadow)] else {
            throw MetalRuntimeError.noOpenTransaction
        }
        try await ensureEncodingCapacity(requiredCommands: 2)
        guard let session = encodingSession else {
            throw MetalRuntimeError.noOpenTransaction
        }

        try Metal4StateEncoder.copyPhaseHeader(
            header,
            ring: ring,
            destination: arena.transient.header,
            session: session
        )
        let table = try argumentTableCache.table(
            rootArgumentBuffer: root.buffer,
            additionalBindings: additionalBuffers,
            label: "NumiTissue.Metal4.\(kernel.rawValue)"
        )
        let specialization = specialization(
            for: kernel,
            header: header
        )
        try session.encodeDispatch(
            kernel: kernel,
            threadCount: count,
            pipeline: try shaders.pipeline(kernel),
            argumentTable: table,
            specialization: specialization
        )
    }

    func encodeCableSolve(
        header: MetalSimulationHeader
    ) async throws {
        try await encodeKernel(
            .assembleCableSystem,
            count: Int(header.compartmentCount),
            header: header
        )
        if maxCableDepth > 0 {
            for depth in stride(from: maxCableDepth, through: 1, by: -1) {
                var level = header
                level.reserved2.x = depth
                try await encodeKernel(
                    .eliminateCableLevels,
                    count: Int(header.compartmentCount),
                    header: level
                )
            }
        }
        try await encodeKernel(
            .solveCableRoots,
            count: Int(header.compartmentCount),
            header: header
        )
        if maxCableDepth > 0 {
            for depth in 1...maxCableDepth {
                var level = header
                level.reserved2.x = depth
                try await encodeKernel(
                    .backSubstituteCableLevels,
                    count: Int(header.compartmentCount),
                    header: level
                )
            }
        }
    }

    func parameterBindings(
        _ domains: [RuntimeOverlayDomain],
        startingAt firstIndex: Int
    ) -> [Metal4BufferBinding] {
        guard let modelBuffers else { return [] }
        return domains.enumerated().compactMap { offset, domain in
            modelBuffers.table(for: domain).map {
                Metal4BufferBinding(
                    index: firstIndex + offset,
                    buffer: $0.effective
                )
            }
        }
    }

    func specialization(
        for kernel: MetalKernel,
        header: MetalSimulationHeader
    ) -> Metal4KernelSpecialization {
        let channelFamily = UInt32(truncatingIfNeeded:
            deterministicFamilyKey(
                seed: 0x4348_414E,
                values: model?.channelParameters.map {
                    UInt64($0.kindAndPowers.x)
                } ?? []
            )
        )
        let synapseModel = UInt32(truncatingIfNeeded:
            deterministicFamilyKey(
                seed: 0x5359_4E41,
                values: model?.synapseParameters.indices.map(UInt64.init) ?? []
            )
        )
        let molecularSolver = arena?.committedCPUState.microdomains.reduce(
            UInt32(0)
        ) {
            max($0, UInt32($1.solverKind))
        } ?? 0
        let fidelity = arena?.committedCPUState.cells.reduce(UInt32(0)) {
            max($0, UInt32($1.fidelity.rawValue))
        } ?? 0
        return Metal4KernelSpecialization(
            topologyDepth: maxCableDepth,
            channelFamily: channelFamily,
            synapseModel: synapseModel,
            fieldStencil: header.fieldGridWidth,
            molecularSolver: molecularSolver,
            fidelityLevel: fidelity,
            precisionClass: UInt32(
                options.effectiveNumericalProfile == .reference64 ? 64 : 32
            )
        )
    }

    func deterministicFamilyKey(
        seed: UInt64,
        values: [UInt64]
    ) -> UInt64 {
        var value = seed ^ UInt64(values.count)
        for item in values {
            value ^= item &+ 0x9E37_79B9_7F4A_7C15
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
        }
        return value
    }
}
#endif
