import Foundation
import NumiTissueCore

public extension TissueSelection {
    func validated(
        maximumDepth: Int = 64,
        maximumLeafValues: Int = 1_000_000
    ) throws -> Self {
        guard maximumDepth > 0, maximumLeafValues > 0 else {
            throw TissueSelectionValidationError.invalidLimits
        }
        var leafValues = 0
        try validate(
            depth: 0,
            maximumDepth: maximumDepth,
            maximumLeafValues: maximumLeafValues,
            leafValues: &leafValues
        )
        return self
    }

    private func validate(
        depth: Int,
        maximumDepth: Int,
        maximumLeafValues: Int,
        leafValues: inout Int
    ) throws {
        guard depth < maximumDepth else {
            throw TissueSelectionValidationError.maximumDepthExceeded(maximumDepth)
        }

        switch self {
        case .all:
            break

        case .tiles(let coordinates):
            guard !coordinates.isEmpty,
                  Set(coordinates).count == coordinates.count else {
                throw TissueSelectionValidationError.invalidTileSelection
            }
            try accumulate(
                coordinates.count,
                maximum: maximumLeafValues,
                value: &leafValues
            )

        case .cells(let identifiers):
            guard !identifiers.isEmpty,
                  Set(identifiers).count == identifiers.count else {
                throw TissueSelectionValidationError.invalidCellSelection
            }
            try accumulate(
                identifiers.count,
                maximum: maximumLeafValues,
                value: &leafValues
            )

        case .cellTypes(let identifiers):
            guard !identifiers.isEmpty,
                  Set(identifiers).count == identifiers.count else {
                throw TissueSelectionValidationError.invalidCellTypeSelection
            }
            try accumulate(
                identifiers.count,
                maximum: maximumLeafValues,
                value: &leafValues
            )

        case .sphere(let center, let radius):
            guard center.x.isFinite,
                  center.y.isFinite,
                  center.z.isFinite,
                  radius.isFinite,
                  radius > 0 else {
                throw TissueSelectionValidationError.invalidSphere
            }
            try accumulate(1, maximum: maximumLeafValues, value: &leafValues)

        case .box(let minimum, let maximum):
            guard minimum.x.isFinite,
                  minimum.y.isFinite,
                  minimum.z.isFinite,
                  maximum.x.isFinite,
                  maximum.y.isFinite,
                  maximum.z.isFinite,
                  minimum.x <= maximum.x,
                  minimum.y <= maximum.y,
                  minimum.z <= maximum.z,
                  minimum != maximum else {
                throw TissueSelectionValidationError.invalidBox
            }
            try accumulate(1, maximum: maximumLeafValues, value: &leafValues)

        case .union(let selectors):
            guard !selectors.isEmpty else {
                throw TissueSelectionValidationError.emptyComposition("union")
            }
            for selector in selectors {
                try selector.validate(
                    depth: depth + 1,
                    maximumDepth: maximumDepth,
                    maximumLeafValues: maximumLeafValues,
                    leafValues: &leafValues
                )
            }

        case .intersection(let selectors):
            guard !selectors.isEmpty else {
                throw TissueSelectionValidationError.emptyComposition("intersection")
            }
            for selector in selectors {
                try selector.validate(
                    depth: depth + 1,
                    maximumDepth: maximumDepth,
                    maximumLeafValues: maximumLeafValues,
                    leafValues: &leafValues
                )
            }

        case .excluding(let included, let excluded):
            try included.validate(
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumLeafValues: maximumLeafValues,
                leafValues: &leafValues
            )
            try excluded.validate(
                depth: depth + 1,
                maximumDepth: maximumDepth,
                maximumLeafValues: maximumLeafValues,
                leafValues: &leafValues
            )
        }
    }

    private func accumulate(
        _ amount: Int,
        maximum: Int,
        value: inout Int
    ) throws {
        let addition = value.addingReportingOverflow(amount)
        guard !addition.overflow, addition.partialValue <= maximum else {
            throw TissueSelectionValidationError.maximumLeafValuesExceeded(maximum)
        }
        value = addition.partialValue
    }
}

public enum TissueSelectionValidationError: Error, Sendable, CustomStringConvertible {
    case invalidLimits
    case maximumDepthExceeded(Int)
    case maximumLeafValuesExceeded(Int)
    case invalidTileSelection
    case invalidCellSelection
    case invalidCellTypeSelection
    case invalidSphere
    case invalidBox
    case emptyComposition(String)

    public var description: String {
        switch self {
        case .invalidLimits:
            return "Tissue-selection validation limits are invalid"
        case .maximumDepthExceeded(let maximum):
            return "Tissue selection exceeds maximum recursive depth \(maximum)"
        case .maximumLeafValuesExceeded(let maximum):
            return "Tissue selection exceeds maximum leaf-value count \(maximum)"
        case .invalidTileSelection:
            return "Tissue tile selection is empty or contains duplicates"
        case .invalidCellSelection:
            return "Tissue cell selection is empty or contains duplicates"
        case .invalidCellTypeSelection:
            return "Tissue cell-type selection is empty or contains duplicates"
        case .invalidSphere:
            return "Tissue spherical selection is outside its admissible domain"
        case .invalidBox:
            return "Tissue box selection is outside its admissible domain"
        case .emptyComposition(let kind):
            return "Tissue selection \(kind) must contain at least one selector"
        }
    }
}
