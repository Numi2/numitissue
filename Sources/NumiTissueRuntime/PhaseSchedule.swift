import Foundation
import NumiTissueCore

public struct ScheduledRuntimePhase: Sendable, Hashable, Codable {
    public var phase: RuntimePhase
    public var tickRange: Range<UInt64>

    public init(_ phase: RuntimePhase, _ tickRange: Range<UInt64>) {
        self.phase = phase
        self.tickRange = tickRange
    }
}

public struct RuntimePhasePlanner: Sendable {
    public var fastQuantumTicks: UInt64
    public var routingBlockTicks: UInt64
    public var transactionTicks: UInt64
    public var glialTicks: UInt64
    public var mechanicsTicks: UInt64
    public var developmentTicks: UInt64
    public var structuralTicks: UInt64
    public var fidelityTicks: UInt64

    public init(
        fastQuantumTicks: UInt64 = 1,
        routingBlockTicks: UInt64 = 10,
        transactionTicks: UInt64 = 200,
        glialTicks: UInt64 = 40,
        mechanicsTicks: UInt64 = 4_000,
        developmentTicks: UInt64 = 40_000,
        structuralTicks: UInt64 = 40_000,
        fidelityTicks: UInt64 = 4_000
    ) {
        precondition(fastQuantumTicks > 0)
        precondition(routingBlockTicks > 0)
        precondition(transactionTicks > 0)
        self.fastQuantumTicks = fastQuantumTicks
        self.routingBlockTicks = routingBlockTicks
        self.transactionTicks = transactionTicks
        self.glialTicks = glialTicks
        self.mechanicsTicks = mechanicsTicks
        self.developmentTicks = developmentTicks
        self.structuralTicks = structuralTicks
        self.fidelityTicks = fidelityTicks
    }

    public func plan(startTick: UInt64) -> [ScheduledRuntimePhase] {
        let endTick = startTick &+ transactionTicks
        let transactionRange = startTick..<endTick
        var result: [ScheduledRuntimePhase] = [
            ScheduledRuntimePhase(.ingestInputs, transactionRange),
            ScheduledRuntimePhase(.buildWorklists, transactionRange)
        ]
        result.reserveCapacity(Int(transactionTicks / fastQuantumTicks) * 6 + 64)

        var tick = startTick
        while tick < endTick {
            let next = min(tick &+ fastQuantumTicks, endTick)
            let quantum = tick..<next
            result.append(ScheduledRuntimePhase(.deliverEvents, quantum))
            result.append(ScheduledRuntimePhase(.decaySynapses, quantum))
            result.append(ScheduledRuntimePhase(.updateChannels, quantum))
            result.append(ScheduledRuntimePhase(.solveCableTrees, quantum))
            result.append(ScheduledRuntimePhase(.detectSpikes, quantum))
            result.append(ScheduledRuntimePhase(.routeSpikes, quantum))

            if crossesBoundary(from: tick, through: next, cadence: routingBlockTicks) {
                result.append(ScheduledRuntimePhase(.updateFastFields, tick..<next))
                result.append(ScheduledRuntimePhase(.updateMolecularDomains, tick..<next))
            }
            if crossesBoundary(from: tick, through: next, cadence: glialTicks) {
                result.append(ScheduledRuntimePhase(.updateGliaAndMetabolism, tick..<next))
            }
            tick = next
        }

        result.append(ScheduledRuntimePhase(.applyPlasticity, transactionRange))
        if crossesBoundary(from: startTick, through: endTick, cadence: mechanicsTicks) {
            result.append(ScheduledRuntimePhase(.updateCellMechanics, transactionRange))
        }
        if crossesBoundary(from: startTick, through: endTick, cadence: developmentTicks) {
            result.append(ScheduledRuntimePhase(.updateDevelopment, transactionRange))
        }
        if crossesBoundary(from: startTick, through: endTick, cadence: structuralTicks) {
            result.append(ScheduledRuntimePhase(.updateStructuralPlasticity, transactionRange))
        }
        if crossesBoundary(from: startTick, through: endTick, cadence: fidelityTicks) {
            result.append(ScheduledRuntimePhase(.updateAdaptiveFidelity, transactionRange))
        }
        result.append(ScheduledRuntimePhase(.collectOutputs, transactionRange))
        result.append(ScheduledRuntimePhase(.validate, transactionRange))
        return result
    }

    public func context(
        startTime: TissueTime,
        epoch: UInt64,
        transaction: TransactionID,
        randomSeed: UInt64
    ) -> ExecutionContext {
        ExecutionContext(
            transaction: transaction,
            epoch: epoch,
            startTime: startTime,
            endTime: TissueTime(tick: startTime.tick &+ transactionTicks),
            randomSeed: randomSeed
        )
    }

    private func crossesBoundary(from start: UInt64, through end: UInt64, cadence: UInt64) -> Bool {
        guard cadence > 0, end > start else { return false }
        return start / cadence != (end - 1) / cadence || end % cadence == 0
    }
}
