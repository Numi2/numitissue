import Foundation
import NumiTissueCore

public extension ExecutionContext {
    /// Constructs an execution context for an externally coordinated interval while retaining a
    /// cadence that satisfies the runtime scheduler's divisibility contract.
    init(
        transaction: TransactionID,
        epoch: UInt64,
        startTime: TissueTime,
        endTime: TissueTime,
        randomSeed: UInt64
    ) {
        precondition(endTime.tick > startTime.tick, "Execution interval must be positive")
        let duration = endTime.tick - startTime.tick
        let routing = Self.greatestCommonDivisor(duration, RuntimeCadence.routingBlockTicks)
        let fast = Self.greatestCommonDivisor(routing, RuntimeCadence.fastQuantumTicks)
        self.init(
            transaction: transaction,
            epoch: epoch,
            startTime: startTime,
            randomSeed: randomSeed,
            cadence: RuntimeCadence(
                transactionTicks: duration,
                routingBlockTicks: max(routing, 1),
                fastQuantumTicks: max(fast, 1)
            )
        )
    }

    private static func greatestCommonDivisor(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            let remainder = a % b
            a = b
            b = remainder
        }
        return max(a, 1)
    }
}
