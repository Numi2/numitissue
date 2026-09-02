import Foundation

public struct EvidenceFusionEngine: Sendable {
    public init() {}

    public func resolve(
        _ sourceRecords: [EvidenceRecord],
        policy sourcePolicy: EvidenceFusionPolicy = EvidenceFusionPolicy()
    ) throws -> ResolvedEvidence {
        let policy = try sourcePolicy.validated()
        guard !sourceRecords.isEmpty else {
            throw EvidenceFusionError.emptyGroup
        }
        let records = try sourceRecords
            .map { try $0.validated() }
            .sorted { $0.id < $1.id }

        let anchor = records[0]
        let anchorKey = fusionEntityKey(anchor.entity, policy: policy)
        guard records.allSatisfy({
            fusionEntityKey($0.entity, policy: policy) == anchorKey
        }) else {
            throw EvidenceFusionError.mixedEntities
        }
        guard records.allSatisfy({ $0.property.path == anchor.property.path }) else {
            throw EvidenceFusionError.mixedProperties
        }

        var eligible: [EvidenceRecord] = []
        var rejections: [EvidenceRejection] = []
        for record in records {
            if record.quality.confidence < policy.minimumConfidence {
                rejections.append(EvidenceRejection(
                    recordID: record.id,
                    reason: .belowConfidence
                ))
                continue
            }
            let excluded = record.quality.flags.intersection(policy.excludedFlags)
            if !excluded.isEmpty || record.quality.excludedByDefault {
                rejections.append(EvidenceRejection(
                    recordID: record.id,
                    reason: .excludedQuality,
                    detail: excluded.map(\.rawValue).sorted().joined(separator: ",")
                ))
                continue
            }
            eligible.append(record)
        }
        guard eligible.count >= policy.minimumSupport else {
            throw EvidenceFusionError.insufficientSupport(
                required: policy.minimumSupport,
                actual: eligible.count
            )
        }

        let firstValue = eligible[0].value
        switch firstValue {
        case .scalar, .interval, .gaussian, .samples:
            return try resolveScalar(
                eligible,
                anchor: anchor,
                policy: policy,
                initialRejections: rejections
            )
        case .vector:
            return try resolveVector(
                eligible,
                anchor: anchor,
                policy: policy,
                initialRejections: rejections
            )
        case .category, .categoryProbabilities, .boolean, .text:
            return try resolveCategorical(
                eligible,
                anchor: anchor,
                policy: policy,
                initialRejections: rejections
            )
        }
    }

    public func resolveAll(
        _ records: [EvidenceRecord],
        policy: EvidenceFusionPolicy = EvidenceFusionPolicy()
    ) -> EvidenceFusionReport {
        var grouped: [String: [EvidenceRecord]] = [:]
        for record in records {
            let key = [
                fusionEntityKey(record.entity, policy: policy),
                record.property.path
            ].joined(separator: "\u{1e}")
            grouped[key, default: []].append(record)
        }

        var resolved: [ResolvedEvidence] = []
        var failures: [EvidenceFusionFailure] = []
        for key in grouped.keys.sorted() {
            let group = grouped[key] ?? []
            do {
                resolved.append(try resolve(group, policy: policy))
            } catch {
                failures.append(EvidenceFusionFailure(
                    groupKey: key,
                    recordIDs: group.map(\.id).sorted(),
                    reason: String(describing: error)
                ))
            }
        }
        return EvidenceFusionReport(
            resolved: resolved.sorted {
                let lhs = $0.entity.semanticKey + "\u{1e}" + $0.property.path
                let rhs = $1.entity.semanticKey + "\u{1e}" + $1.property.path
                return lhs < rhs
            },
            unresolvedGroups: failures
        )
    }
}
