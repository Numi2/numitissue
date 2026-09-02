import Foundation

extension String {
    /// Explicit-label compatibility helper used by importers that need to preserve empty lines.
    /// Keeping the policy in one place avoids relying on standard-library argument-label ordering.
    func split(
        whereSeparator isSeparator: (Character) throws -> Bool,
        omittingEmptySubsequences: Bool
    ) rethrows -> [Substring] {
        try split(
            maxSplits: Int.max,
            omittingEmptySubsequences: omittingEmptySubsequences,
            whereSeparator: isSeparator
        )
    }
}
