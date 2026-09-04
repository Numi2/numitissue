import Foundation
import NumiTissueIO

/// Only explicitly nonphysical implementations may run without a live deployment verifier.
public protocol NonphysicalNeuralCultureBackend: NeuralCultureBackend {}

public protocol WatchdogNeuralCultureBackend: InterlockedNeuralCultureBackend {
    /// Refresh an already operator-armed DEVICE-local watchdog. Must not rearm a stopped device.
    /// Device stop must atomically reject later submissions, including requests already in flight.
    /// Implementations must reject past start timestamps on the device, not execute them immediately.
    func refreshWatchdog(session: NeuralCultureSession) async throws -> ClosedLoopInterlockState
}

public struct ClosedLoopAdmissionRequest: Sendable {
    public var runID: UUID
    public var session: NeuralCultureSession
    public var environment: ClosedLoopEnvironment
    public var identity: ClosedLoopDeviceIdentity
    public var envelopeSHA256: ScientificSHA256Digest
}

/// Application-supplied operator, protocol, device, firmware and qualification verification.
/// Returns an expiry in the named device clock. No default authorizes physical stimulation.
/// This is a trusted in-process boundary, not a process sandbox or regulatory authorization.
public typealias ClosedLoopAdmissionVerifier = @Sendable (ClosedLoopAdmissionRequest) async throws -> UInt64

public actor GuardedNeuralCultureSession {
    public enum State: String, Sendable { case idle, admitting, armed, stopped }
    public nonisolated let runID: UUID
    private let backend: any NeuralCultureBackend
    private let session: NeuralCultureSession
    private let environment: ClosedLoopEnvironment
    private let identity: ClosedLoopDeviceIdentity
    private let configuration: MEAConfiguration
    private let destinations: [ElectrodeID: UInt64]
    private let envelope: ClosedLoopSafetyEnvelope
    private let audit: any ClosedLoopAuditSink
    private let admission: ClosedLoopAdmissionVerifier?
    private var state: State = .idle
    private var busy = false
    private var expiry: UInt64 = 0
    private var lastDeviceTime: UInt64 = 0
    private var reservations: [ClosedLoopExposure] = []
    private var requests: [UUID: NeuralStimulationRequest] = [:]
    private var latestObservationSHA256: ScientificSHA256Digest?
    private var latestObservationEnd: UInt64?

    public init(runID: UUID, backend: any NeuralCultureBackend, session: NeuralCultureSession,
                environment: ClosedLoopEnvironment, identity: ClosedLoopDeviceIdentity,
                configuration: MEAConfiguration, destinations: [ElectrodeID: UInt64],
                envelope: ClosedLoopSafetyEnvelope, audit: any ClosedLoopAuditSink,
                admission: ClosedLoopAdmissionVerifier? = nil) throws {
        self.runID = runID; self.backend = backend; self.session = session
        self.environment = environment; self.identity = try identity.validated()
        self.configuration = try configuration.validated(); self.destinations = destinations
        self.envelope = try envelope.validated(); self.audit = audit; self.admission = admission
        guard !session.cultureID.isEmpty, session.backendName == backend.name,
              ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(configuration.electrodes)) == identity.electrodeMapSHA256 else {
            throw ClosedLoopError.invalid("session or electrode-map identity")
        }
        if environment.hasPhysicalEffects {
            guard backend is any WatchdogNeuralCultureBackend, audit.durable, admission != nil else {
                throw ClosedLoopError.unsafe("physical operation needs independent watchdog, durable journal and admission verifier")
            }
        } else if !(backend is any NonphysicalNeuralCultureBackend) {
            throw ClosedLoopError.unsafe("a physical backend cannot be relabeled replay or emulator")
        }
    }

    public func currentState() -> State { state }

    public func admit(nonphysicalExpiryNanoseconds: UInt64? = nil) async throws {
        guard state == .idle else { throw ClosedLoopError.latched("admission is one-shot") }
        state = .admitting
        do {
            let now = try await readClock()
            let capabilities = await backend.capabilities
            guard capabilities.supportsScheduledStimulation, capabilities.timestampResolutionNanoseconds > 0,
                  capabilities.maximumElectrodes >= configuration.electrodes.count,
                  capabilities.supportedSampleRatesHertz.contains(configuration.sampleRateHertz) else {
                throw ClosedLoopError.unsafe("device scheduling or acquisition capabilities")
            }
            let request = ClosedLoopAdmissionRequest(runID: runID, session: session,
                environment: environment, identity: identity, envelopeSHA256: try envelope.digest())
            if environment.hasPhysicalEffects {
                guard nonphysicalExpiryNanoseconds == nil, let admission else {
                    throw ClosedLoopError.unsafe("physical expiry must come from admission verification")
                }
                expiry = try await admission(request)
                try await checkInterlock(now: now, through: now, refresh: false)
            } else {
                guard let end = nonphysicalExpiryNanoseconds else { throw ClosedLoopError.invalid("bounded virtual expiry") }
                expiry = end
            }
            guard state == .admitting, expiry > now else { throw ClosedLoopError.latched("expired or interrupted admission") }
            try await log("admitted", now, ["run": runID.uuidString, "environment": environment.rawValue,
                "device": identity.serial, "firmware": identity.firmware, "clock": identity.clockID,
                "policy": try envelope.digest().hexadecimal, "expiry": String(expiry)])
            try Task.checkCancellation()
            guard state == .admitting else { throw ClosedLoopError.latched("admission interrupted") }
            state = .armed
        } catch { _ = await stop(reason: "admission failed: \(error)"); throw error }
    }

    public func observe(_ request: NeuralRecordingRequest) async throws -> NeuralRecording {
        guard state == .armed, !busy else { throw ClosedLoopError.latched("not armed or concurrent operation") }
        busy = true; defer { busy = false }
        do {
            let now = try await readClock()
            let end = try LoopArithmetic.add(request.startTimeNanoseconds, request.durationNanoseconds)
            let expected = Double(request.durationNanoseconds) * 1e-9 * request.sampleRateHertz
            guard request.durationNanoseconds > 0, request.sampleRateHertz == configuration.sampleRateHertz,
                  request.sampleRateHertz.isFinite, request.sampleRateHertz > 0,
                  expected.isFinite, expected >= 1, expected <= 1_000_000,
                  abs(expected - expected.rounded()) < 1e-6,
                  !request.electrodeIDs.isEmpty, request.electrodeIDs.count <= 4096,
                  expected * Double(request.electrodeIDs.count) <= 16_777_216,
                  Set(request.electrodeIDs).count == request.electrodeIDs.count,
                  Set(request.electrodeIDs).isSubset(of: Set(configuration.electrodes.filter(\.enabled).map(\.id))),
                  latestObservationEnd.map({ request.startTimeNanoseconds >= $0 }) ?? true,
                  end <= expiry, now < expiry else { throw ClosedLoopError.invalid("bounded nonoverlapping recording request") }
            try await checkInterlock(now: now, through: max(now, end), refresh: true)
            let recording = try await backend.record(session: session, request: request)
            let returnedNow = try await readClock()
            guard state == .armed, recording.request == request, recording.droppedSamples == 0,
                  recording.frame.electrodeOrder == request.electrodeIDs,
                  recording.frame.sampleRateHertz == request.sampleRateHertz,
                  recording.frame.samplesByElectrode.count == request.electrodeIDs.count,
                  recording.frame.sampleCount == Int(expected.rounded()),
                  recording.frame.samplesByElectrode.allSatisfy({
                      $0.count == recording.frame.sampleCount && $0.allSatisfy(\.isFinite)
                  }), recording.backendTimestampNanoseconds >= end,
                  recording.backendTimestampNanoseconds <= returnedNow,
                  returnedNow >= end, returnedNow - end <= envelope.maximumObservationAgeNanoseconds else {
                throw ClosedLoopError.unsafe("recording dropout, truncation, stale data, timestamps or channel shape")
            }
            for spike in recording.spikes {
                guard request.electrodeIDs.contains(spike.electrode), spike.sampleIndex >= 0,
                      spike.sampleIndex < recording.frame.sampleCount, spike.amplitudeVolts.isFinite else {
                    throw ClosedLoopError.invalid("recorded spike")
                }
            }
            let digest = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(recording))
            try await log("observation", returnedNow,
                ["sha256": digest.hexadecimal, "samples": String(recording.frame.sampleCount)])
            try Task.checkCancellation()
            guard state == .armed else { throw ClosedLoopError.latched("stopped during observation") }
            latestObservationSHA256 = digest; latestObservationEnd = end
            return recording
        } catch { _ = await stop(reason: "observation failed: \(error)"); throw error }
    }

    public func submit(_ request: NeuralStimulationRequest,
                       basedOn observationSHA256: ScientificSHA256Digest) async throws -> NeuralStimulationReceipt {
        guard state == .armed, !busy else { throw ClosedLoopError.latched("not armed or concurrent operation") }
        busy = true; defer { busy = false }
        do {
            guard requests[request.id] == nil, requests.count < 100_000,
                  latestObservationSHA256 == observationSHA256, let observedEnd = latestObservationEnd else {
                throw ClosedLoopError.invalid("duplicate request or stale observation authority")
            }
            let capabilities = await backend.capabilities
            var now = try await readClock()
            guard now >= observedEnd, now - observedEnd <= envelope.maximumObservationAgeNanoseconds,
                  now < expiry else { throw ClosedLoopError.unsafe("stale feedback or expired admission") }
            let health = try await backend.health(session: session)
            guard health.status == .healthy, let temperature = health.temperatureKelvin,
                  temperature.isFinite, Double(temperature) >= envelope.minimumTemperatureKelvin,
                  Double(temperature) <= envelope.maximumTemperatureKelvin else {
                throw ClosedLoopError.unsafe("culture health or temperature not established")
            }
            let decision = try ClosedLoopSafetyEvaluator.evaluate(request: request,
                configuration: configuration, destinations: destinations, envelope: envelope,
                deviceNowNanoseconds: now, deviceMinimumLeadNanoseconds: capabilities.minimumStimulationLeadTimeNanoseconds,
                timestampResolutionNanoseconds: capabilities.timestampResolutionNanoseconds, history: reservations)
            guard decision.endNanoseconds <= expiry else { throw ClosedLoopError.unsafe("plan exceeds session expiry") }
            try await checkInterlock(now: now, through: decision.endNanoseconds, refresh: true)
            guard state == .armed else { throw ClosedLoopError.latched("stopped before reservation") }
            // Reserve BEFORE dispatch; never release dose on an ambiguous acknowledgement.
            requests[request.id] = request; reservations.append(contentsOf: decision.exposures)
            try await log("stimulation-intent", now, Intent(request: request, decision: decision,
                observationSHA256: observationSHA256, identity: identity))
            now = try await readClock()
            let earliest = try LoopArithmetic.add(now, max(capabilities.minimumStimulationLeadTimeNanoseconds,
                                                           envelope.minimumLeadTimeNanoseconds))
            try Task.checkCancellation()
            guard state == .armed, request.scheduledTimeNanoseconds >= earliest, now < expiry,
                  now >= observedEnd, now - observedEnd <= envelope.maximumObservationAgeNanoseconds else {
                throw ClosedLoopError.unsafe("deadline missed while journaling; never execute immediately")
            }
            let receipt: NeuralStimulationReceipt
            do { receipt = try await backend.stimulate(session: session, request: request) }
            catch { throw ClosedLoopError.ambiguousDelivery(request.id) }
            try checkReceipt(receipt, request: request, earliestAcceptance: now)
            try await log("stimulation-receipt", receipt.acceptedAtNanoseconds, receipt)
            guard state == .armed, receipt.status == .accepted || receipt.status == .executed else {
                throw ClosedLoopError.unsafe("stopped, rejected or cancelled stimulation")
            }
            return receipt
        } catch { _ = await stop(reason: "dispatch failed: \(error)"); throw error }
    }

    /// Receipt queries do not resend stimuli. A failed query leaves reservations intact and stops.
    public func reconcile(requestID: UUID) async throws -> NeuralStimulationReceipt {
        guard state == .armed, !busy, let request = requests[requestID],
              let device = backend as? any InterlockedNeuralCultureBackend else {
            throw ClosedLoopError.invalid("receipt query requires a known request and interlocked adapter")
        }
        busy = true; defer { busy = false }
        do {
            let receipt = try await device.stimulationStatus(session: session, requestID: requestID)
            try checkReceipt(receipt, request: request, earliestAcceptance: 0)
            try await log("receipt-reconciliation", lastDeviceTime, receipt)
            guard state == .armed else { throw ClosedLoopError.latched("stopped during receipt query") }
            return receipt
        } catch { _ = await stop(reason: "receipt reconciliation failed: \(error)"); throw error }
    }

    /// Latch before transport I/O. A timeout/error is not a successful stop acknowledgement.
    @discardableResult public func stop(reason: String) async -> Bool {
        state = .stopped
        var confirmed = !environment.hasPhysicalEffects
        if let interlocked = backend as? any InterlockedNeuralCultureBackend {
            do {
                let result = try await interlocked.emergencyStop(session: session, reason: reason)
                confirmed = result.identity == identity && result.stopConfirmed
            } catch { confirmed = false }
        } else if !environment.hasPhysicalEffects {
            // Replay cancellation is best-effort bookkeeping; it has no physical effects.
            for id in requests.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                try? await backend.cancel(session: session, requestID: id)
            }
        }
        do { try await log("stopped", lastDeviceTime, ["reason": reason, "confirmed": String(confirmed)]) }
        catch { /* Stop was attempted even when the audit sink failed. Session remains latched. */ }
        return confirmed
    }

    private func checkReceipt(_ r: NeuralStimulationReceipt, request: NeuralStimulationRequest,
                              earliestAcceptance: UInt64) throws {
        guard r.requestID == request.id, r.acceptedAtNanoseconds >= earliestAcceptance,
              r.acceptedAtNanoseconds <= request.scheduledTimeNanoseconds,
              r.acceptedAtNanoseconds <= (request.deadlineNanoseconds ?? 0) else {
            throw ClosedLoopError.ambiguousDelivery(request.id)
        }
        if r.status == .executed {
            // Exact device-grid scheduling is this interface's contract. A late or early delivered
            // pulse is a failed execution, even when still inside the broader plan-end deadline.
            guard let at = r.executedAtNanoseconds, at == request.scheduledTimeNanoseconds,
                  at <= (request.deadlineNanoseconds ?? 0) else { throw ClosedLoopError.ambiguousDelivery(request.id) }
        }
    }
    private func readClock() async throws -> UInt64 {
        let now = try await backend.backendTimeNanoseconds(session: session)
        guard now >= lastDeviceTime else { throw ClosedLoopError.unsafe("device clock moved backwards") }
        lastDeviceTime = now
        return now
    }
    private func checkInterlock(now: UInt64, through: UInt64, refresh: Bool) async throws {
        guard environment.hasPhysicalEffects else { return }
        guard let device = backend as? any WatchdogNeuralCultureBackend else {
            throw ClosedLoopError.unsafe("device watchdog unavailable")
        }
        let status: ClosedLoopInterlockState
        if refresh { status = try await device.refreshWatchdog(session: session) }
        else { status = try await device.interlockState(session: session) }
        guard status.identity == identity, status.deviceNowNanoseconds >= now,
              status.armedUntilNanoseconds >= max(through, status.deviceNowNanoseconds),
              status.autonomousWatchdogNanoseconds > 0,
              status.autonomousWatchdogNanoseconds <= envelope.maximumObservationAgeNanoseconds,
              !status.stopConfirmed, status.measuredVoltageLimitSatisfied,
              status.temperatureKelvin.isFinite, status.temperatureKelvin >= envelope.minimumTemperatureKelvin,
              status.temperatureKelvin <= envelope.maximumTemperatureKelvin else {
            throw ClosedLoopError.unsafe("interlock identity, arming, watchdog, voltage or temperature")
        }
    }
    private struct Intent: Encodable {
        var request: NeuralStimulationRequest
        var decision: ClosedLoopSafetyDecision
        var observationSHA256: ScientificSHA256Digest
        var identity: ClosedLoopDeviceIdentity
    }
    private func log<T: Encodable>(_ kind: String, _ time: UInt64, _ payload: T) async throws {
        try await audit.append(kind: kind, deviceNanoseconds: time, payload: ScientificCanonicalJSON.encode(payload))
    }
}
