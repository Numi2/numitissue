import Foundation

public enum ProspectiveEvidenceEventKind: String, Sendable, Hashable, Codable, CaseIterable {
    case modelFrozen = "model-frozen"
    case protocolRegistered = "protocol-registered"
    case candidateForecastSealed = "candidate-forecast-sealed"
    case baselineForecastSealed = "baseline-forecast-sealed"
    case experimentStarted = "experiment-started"
    case observationBundleSealed = "observation-bundle-sealed"
    case unblinded
    case immutabilityVerified = "immutability-verified"
    case scoreSealed = "score-sealed"
    case claimIssued = "claim-issued"
    case evidenceClosed = "evidence-closed"
}

public struct ProspectiveEvidenceEvent: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var sequence: UInt64
    public var kind: ProspectiveEvidenceEventKind
    public var recordedAt: Date
    public var artifactID: String
    public var artifactSHA256: ScientificSHA256Digest
    public var previousEventSHA256: ScientificSHA256Digest?
    public var actor: String
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        sequence: UInt64,
        kind: ProspectiveEvidenceEventKind,
        recordedAt: Date,
        artifactID: String,
        artifactSHA256: ScientificSHA256Digest,
        previousEventSHA256: ScientificSHA256Digest? = nil,
        actor: String,
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sequence = sequence
        self.kind = kind
        self.recordedAt = recordedAt
        self.artifactID = artifactID
        self.artifactSHA256 = artifactSHA256
        self.previousEventSHA256 = previousEventSHA256
        self.actor = actor
        self.metadata = metadata
    }

    public func validated() throws -> Self {
        guard schemaVersion == 1,
              ProspectiveIdentifier.isStable(artifactID),
              !actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey) else {
            throw ProspectiveEvidenceError.invalidEvent(sequence)
        }
        if sequence == 0 {
            guard previousEventSHA256 == nil else {
                throw ProspectiveEvidenceError.invalidEvent(sequence)
            }
        } else {
            guard previousEventSHA256 != nil else {
                throw ProspectiveEvidenceError.invalidEvent(sequence)
            }
        }
        return self
    }

    public func canonicalData() throws -> Data {
        try ScientificCanonicalJSON.encode(validated())
    }

    public func sha256() throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData())
    }
}

public struct ProspectiveEvidenceLedger: Sendable, Hashable, Codable {
    public var schemaVersion: UInt32
    public var studyID: String
    public var modelFreezeSHA256: ScientificSHA256Digest
    public var protocolSHA256: ScientificSHA256Digest
    public var events: [ProspectiveEvidenceEvent]
    public var metadata: [String: String]

    public init(
        schemaVersion: UInt32 = 1,
        studyID: String,
        modelFreezeSHA256: ScientificSHA256Digest,
        protocolSHA256: ScientificSHA256Digest,
        events: [ProspectiveEvidenceEvent] = [],
        metadata: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.studyID = studyID
        self.modelFreezeSHA256 = modelFreezeSHA256
        self.protocolSHA256 = protocolSHA256
        self.events = events
        self.metadata = metadata
    }

    public mutating func append(
        kind: ProspectiveEvidenceEventKind,
        recordedAt: Date,
        artifactID: String,
        artifactSHA256: ScientificSHA256Digest,
        actor: String,
        metadata: [String: String] = [:]
    ) throws -> ProspectiveEvidenceEvent {
        if let last = events.last, recordedAt < last.recordedAt {
            throw ProspectiveEvidenceError.nonMonotonicTimeline
        }
        let event = ProspectiveEvidenceEvent(
            sequence: UInt64(events.count),
            kind: kind,
            recordedAt: recordedAt,
            artifactID: artifactID,
            artifactSHA256: artifactSHA256,
            previousEventSHA256: try events.last?.sha256(),
            actor: actor,
            metadata: metadata
        )
        var candidate = self
        candidate.events.append(try event.validated())
        _ = try candidate.validated(allowOpen: true)
        self = candidate
        return event
    }

    public func validated(allowOpen: Bool = false) throws -> Self {
        guard schemaVersion == 1,
              ProspectiveIdentifier.isStable(studyID),
              metadata.keys.allSatisfy(ProspectiveIdentifier.isMetadataKey),
              !events.isEmpty else {
            throw ProspectiveEvidenceError.invalidLedger
        }
        var priorDigest: ScientificSHA256Digest?
        var priorDate: Date?
        var seen = Set<ProspectiveEvidenceEventKind>()
        var baselineCount = 0
        for (index, source) in events.enumerated() {
            let event = try source.validated()
            guard event.sequence == UInt64(index),
                  event.previousEventSHA256 == priorDigest,
                  priorDate.map({ event.recordedAt >= $0 }) ?? true else {
                throw ProspectiveEvidenceError.invalidChain(UInt64(index))
            }
            try validateOrder(event.kind, seen: seen, baselineCount: baselineCount)
            if event.kind == .baselineForecastSealed { baselineCount += 1 }
            if event.kind != .baselineForecastSealed { seen.insert(event.kind) }
            priorDigest = try event.sha256()
            priorDate = event.recordedAt
        }
        guard events.first?.kind == .modelFrozen else {
            throw ProspectiveEvidenceError.incompleteLedger
        }
        if events.count > 1,
           events.dropFirst().first?.kind != .protocolRegistered {
            throw ProspectiveEvidenceError.incompleteLedger
        }
        if !allowOpen {
            guard events.dropFirst().first?.kind == .protocolRegistered,
                  seen.contains(.candidateForecastSealed),
                  baselineCount > 0,
                  seen.contains(.experimentStarted),
                  seen.contains(.observationBundleSealed),
                  seen.contains(.unblinded),
                  seen.contains(.immutabilityVerified),
                  seen.contains(.scoreSealed) else {
                throw ProspectiveEvidenceError.incompleteLedger
            }
            guard events.last?.kind == .evidenceClosed else {
                throw ProspectiveEvidenceError.openLedger
            }
        }
        return self
    }

    public func canonicalData(allowOpen: Bool = false) throws -> Data {
        try ScientificCanonicalJSON.encode(validated(allowOpen: allowOpen))
    }

    public func sha256(allowOpen: Bool = false) throws -> ScientificSHA256Digest {
        ScientificSHA256Digest(data: try canonicalData(allowOpen: allowOpen))
    }

    public var terminalEventSHA256: ScientificSHA256Digest? {
        guard let last = events.last else { return nil }
        return try? last.sha256()
    }

    private func validateOrder(
        _ kind: ProspectiveEvidenceEventKind,
        seen: Set<ProspectiveEvidenceEventKind>,
        baselineCount: Int
    ) throws {
        guard !seen.contains(.evidenceClosed) else {
            throw ProspectiveEvidenceError.invalidEventOrder(kind)
        }
        switch kind {
        case .modelFrozen:
            guard seen.isEmpty else { throw ProspectiveEvidenceError.invalidEventOrder(kind) }
        case .protocolRegistered:
            guard seen == [.modelFrozen] else { throw ProspectiveEvidenceError.invalidEventOrder(kind) }
        case .candidateForecastSealed:
            guard seen.contains(.protocolRegistered), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .baselineForecastSealed:
            guard seen.contains(.candidateForecastSealed),
                  !seen.contains(.experimentStarted) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .experimentStarted:
            guard seen.contains(.candidateForecastSealed), baselineCount > 0,
                  !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .observationBundleSealed:
            guard seen.contains(.experimentStarted), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .unblinded:
            guard seen.contains(.observationBundleSealed), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .immutabilityVerified:
            guard seen.contains(.unblinded), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .scoreSealed:
            guard seen.contains(.immutabilityVerified), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .claimIssued:
            guard seen.contains(.scoreSealed), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        case .evidenceClosed:
            guard seen.contains(.scoreSealed), !seen.contains(kind) else {
                throw ProspectiveEvidenceError.invalidEventOrder(kind)
            }
        }
    }
}
