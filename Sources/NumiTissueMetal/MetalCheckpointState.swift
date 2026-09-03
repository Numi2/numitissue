#if canImport(Metal)
import Foundation
import Metal
import NumiTissueCore
import NumiTissueRuntime

/// Opaque state required to resume the Apple-Silicon event scheduler. Biological pools remain in
/// `TissueCheckpoint.state`; this payload preserves the committed delayed-event wheel without
/// making the fast path perform a CPU readback.
public extension MetalTissueBackend {
    static var checkpointBackendID: String { "numitissue.metal.apple" }
}

extension MetalTissueBackend: RuntimeBackendCheckpointStateProvider {
    nonisolated public var checkpointBackendIdentifier: String {
        Self.checkpointBackendID
    }

    public func validateBackendCheckpointState(
        _ data: Data,
        committedState: TissueRuntimeState
    ) async throws {
        let snapshot = try Self.decodeCheckpointState(data)
        guard snapshot.minimumArrivalTick == committedState.time.tick else {
            throw MetalEventWheelPersistenceError.stateTickMismatch(
                snapshot: snapshot.minimumArrivalTick,
                committed: committedState.time.tick
            )
        }
        let synapseIDs = Set(committedState.synapses.map(\.id))
        for event in snapshot.events {
            if case .synapse(let id) = event.target,
               !synapseIDs.contains(id) {
                throw MetalEventWheelPersistenceError.missingSynapse(id)
            }
        }
    }

    public func exportBackendCheckpointState() async throws -> Data {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        let state = try await arena.downloadCommittedState()
        let routingBlockTicks = checkpointRoutingBlockTicks
            ?? RuntimeCadence.routingBlockTicks
        let snapshot = try await arena.exportPersistentEventWheel(
            state: state,
            routingBlockTicks: routingBlockTicks,
            minimumArrivalTick: state.time.tick
        )
        return try RuntimeBackendCheckpointArchive.encode(
            backendIdentifier: checkpointBackendIdentifier,
            payloadVersion: 1,
            payload: snapshot,
            metadata: [
                "numitissue.state": "committed",
                "numitissue.event-order": "arrival-target-source-kind-sequence",
                "numitissue.event-storage": "gpu-resident-double-buffered-wheel"
            ]
        )
    }

    public func restoreBackendCheckpointState(_ data: Data) async throws {
        guard let arena else { throw MetalRuntimeError.stateNotLoaded }
        guard currentContext == nil else {
            throw RuntimeExecutionError.transactionInProgress
        }
        let snapshot = try Self.decodeCheckpointState(data)
        let state = arena.committedCPUState
        guard snapshot.minimumArrivalTick == state.time.tick else {
            throw MetalEventWheelPersistenceError.stateTickMismatch(
                snapshot: snapshot.minimumArrivalTick,
                committed: state.time.tick
            )
        }
        checkpointRoutingBlockTicks = snapshot.routingBlockTicks
        try await arena.importPersistentEventWheel(
            snapshot,
            state: state
        )
    }

    private nonisolated static func decodeCheckpointState(
        _ data: Data
    ) throws -> MetalEventWheelSnapshot {
        try RuntimeBackendCheckpointArchive.decode(
            MetalEventWheelSnapshot.self,
            from: data,
            expectedBackendIdentifier: checkpointBackendID,
            expectedPayloadVersion: 1
        ).validated()
    }
}
#endif
