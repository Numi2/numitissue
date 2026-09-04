import Foundation
import NumiTissueIO

enum ProspectiveStudyCryptography {
    static func digest(_ value: String) -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: Data(value.utf8))
    }

    static func randomizationSeedCommitment(
        studyID: UUID,
        seed: UInt64
    ) -> ScientificSHA256Digest {
        digest("numitissue.phase5.randomization-seed.v1:\(studyID.uuidString.lowercased()):\(seed)")
    }

    static func conditionNonce(
        studyID: UUID,
        conditionID: String,
        secret: String
    ) -> String {
        digest(
            "numitissue.phase5.blinding-nonce.v1:\(studyID.uuidString.lowercased()):\(conditionID):\(secret)"
        ).hexadecimal
    }

    static func blindedLabelOrder(
        count: Int,
        studyID: UUID,
        seed: UInt64
    ) -> [String] {
        let labels = (1...count).map {
            "condition-\(String(format: "%03d", $0))"
        }
        return shuffled(
            labels,
            seed: mixedSeed(
                seed,
                stableSeed("blind-labels:\(studyID.uuidString.lowercased())")
            )
        )
    }

    static func stableSeed(_ value: String) -> UInt64 {
        let hex = digest(value).hexadecimal
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }

    static func shuffled<T>(_ values: [T], seed: UInt64) -> [T] {
        var output = values
        guard output.count > 1 else { return output }
        var random = ProspectiveStudyRandom(seed: seed)
        for index in stride(from: output.count - 1, through: 1, by: -1) {
            let selected = random.index(upperBound: index + 1)
            if selected != index { output.swapAt(index, selected) }
        }
        return output
    }

    static func mixedSeed(_ seed: UInt64, _ domain: UInt64) -> UInt64 {
        var value = seed ^ domain ^ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        return value == 0 ? 0xA076_1D64_78BD_642F : value
    }
}

struct ProspectiveStudyRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xA076_1D64_78BD_642F : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        let bound = UInt64(upperBound)
        let limit = UInt64.max - UInt64.max % bound
        var value = next()
        while value >= limit { value = next() }
        return Int(value % bound)
    }
}

enum ProspectiveStudyIdentifier {
    static func isStable(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 256,
              value.first?.isLetter == true else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
                scalar == "-" || scalar == "." || scalar == "_"
        }
    }

    static func isMetadataKey(_ value: String) -> Bool {
        isStable(value)
    }
}

public enum ProspectiveStudyFactoryError: Error, Sendable, CustomStringConvertible {
    case invalidRunAssignment
    case invalidPublicPackage
    case invalidCustodianPackage
    case invalidStudyPackage
    case campaignMismatch
    case invalidConfiguration
    case invalidSecrets
    case invalidIntervention
    case invalidConditionSet
    case invalidTargetSet
    case invalidWorkEstimate
    case unbalancedCommitments
    case randomizationFailure

    public var description: String {
        switch self {
        case .invalidRunAssignment:
            return "Prospective blinded run assignment is invalid."
        case .invalidPublicPackage:
            return "Prospective public study package is invalid."
        case .invalidCustodianPackage:
            return "Prospective custodian package is invalid."
        case .invalidStudyPackage:
            return "Prospective study package is internally inconsistent."
        case .campaignMismatch:
            return "Prospective campaign does not match the blinded run schedule."
        case .invalidConfiguration:
            return "Prospective study factory configuration is invalid."
        case .invalidSecrets:
            return "Prospective study secrets are invalid."
        case .invalidIntervention:
            return "Prospective study intervention is invalid."
        case .invalidConditionSet:
            return "Prospective study conditions are empty, duplicated or invalid."
        case .invalidTargetSet:
            return "Prospective study targets are empty, duplicated or invalid."
        case .invalidWorkEstimate:
            return "Prospective campaign work estimate must be positive."
        case .unbalancedCommitments:
            return "Prospective block randomization requires equal replicate counts across blinded conditions."
        case .randomizationFailure:
            return "Prospective randomization could not produce a complete balanced schedule."
        }
    }
}
