#if canImport(Metal) && compiler(>=6.2)
import Foundation
import Metal
import NumiTissueRuntime

/// Encodes transaction overlays through stable Metal 4 argument tables. The compiled model remains
/// immutable: baseline parameter tables are copied to effective tables first, then this encoder
/// applies state and parameter mutations only to the transaction shadow.
@available(macOS 26.0, iOS 26.0, macCatalyst 26.0, tvOS 26.0, visionOS 26.0, *)
public enum Metal4TransactionOverlayEncoder {
    public static func encode(
        buffers: MetalTransactionOverlayBuffers,
        rootArgumentTable: MetalArgumentTable,
        model: MetalModelBuffers,
        shaderLibrary: MetalShaderLibrary,
        argumentTables: Metal4ArgumentTableCache,
        session: Metal4EncodingSession
    ) throws {
        guard !buffers.overlay.records.isEmpty else { return }

        var bindings: [Metal4BufferBinding] = [
            .init(index: 1, buffer: buffers.groups),
            .init(index: 2, buffer: buffers.records),
            .init(index: 3, buffer: buffers.parameters)
        ]
        let parameterDomains: [RuntimeOverlayDomain] = [
            .channelParameter,
            .mechanismSetParameter,
            .synapseParameter,
            .fieldParameter,
            .cellProgramParameter,
            .regulatoryProgramParameter,
            .fateTransitionParameter,
            .growthProgramParameter,
            .glialProgramParameter,
            .molecularReactionParameter
        ]
        for (offset, domain) in parameterDomains.enumerated() {
            if let table = model.table(for: domain) {
                bindings.append(
                    Metal4BufferBinding(
                        index: 4 + offset,
                        buffer: table.effective
                    )
                )
            }
        }
        let table = try argumentTables.table(
            rootArgumentBuffer: rootArgumentTable.buffer,
            additionalBindings: bindings,
            label: "NumiTissue.Metal4.overlay"
        )

        try session.encodeDispatch(
            kernel: .materializeStateOverlays,
            threadCount: 1,
            pipeline: try shaderLibrary.pipeline(.materializeStateOverlays),
            argumentTable: table
        )
        if !buffers.overlay.parameterGroups.isEmpty {
            try session.encodeDispatch(
                kernel: .materializeParameterOverlays,
                threadCount: 1,
                pipeline: try shaderLibrary.pipeline(
                    .materializeParameterOverlays
                ),
                argumentTable: table
            )
        }
    }
}
#endif
