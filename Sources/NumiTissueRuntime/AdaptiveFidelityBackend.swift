import Foundation
import NumiTissueCore

/// Optional capability for backends that can reconstruct live topology and migrate storage when
/// fidelity changes. Decisions are staged before a transaction and are applied atomically with its
/// normal state commit. Backends may also derive decisions internally from device-side policies.
public protocol AdaptiveFidelityExecutionBackend: NumiTissueExecutionBackend {
    func stageFidelityDecisions(
        _ decisions: [FidelityDecision],
        context: ExecutionContext
    ) async throws

    func lastFidelityMigrationPlan() async -> FidelityMigrationPlan?
}

public enum AdaptiveFidelityBackendError: Error, Sendable, CustomStringConvertible {
    case transactionInProgress
    case staleTransaction(expected: TransactionID, received: TransactionID)
    case duplicateCell(UInt32)
    case invalidTransition(cellIndex: UInt32, from: FidelityLevel, to: FidelityLevel)
    case migrationValidationFailed([RuntimeValidationIssue])

    public var description: String {
        switch self {
        case .transactionInProgress:
            return "Fidelity decisions must be staged before the shadow transaction begins"
        case .staleTransaction(let expected, let received):
            return "Fidelity plan targets transaction \(received), expected \(expected)"
        case .duplicateCell(let index):
            return "Fidelity plan contains duplicate cell index \(index)"
        case .invalidTransition(let index, let from, let to):
            return "Invalid fidelity transition for cell \(index): \(from) -> \(to)"
        case .migrationValidationFailed(let issues):
            return "Migrated state failed validation with \(issues.count) rejecting issue(s)"
        }
    }
}

public extension Array where Element == FidelityDecision {
    func validatedForStaging() throws -> [FidelityDecision] {
        var seen = Set<UInt32>()
        var result: [FidelityDecision] = []
        result.reserveCapacity(count)
        for decision in sorted(by: { $0.cellIndex < $1.cellIndex }) {
            guard seen.insert(decision.cellIndex).inserted else {
                throw AdaptiveFidelityBackendError.duplicateCell(decision.cellIndex)
            }
            guard decision.from != decision.to,
                  decision.kind != .retain,
                  (decision.kind == .promote) == (decision.to.rawValue > decision.from.rawValue) else {
                throw AdaptiveFidelityBackendError.invalidTransition(
                    cellIndex: decision.cellIndex,
                    from: decision.from,
                    to: decision.to
                )
            }
            result.append(decision)
        }
        return result
    }
}
