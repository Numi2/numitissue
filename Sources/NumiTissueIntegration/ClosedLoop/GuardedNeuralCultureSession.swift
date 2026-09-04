import Foundation
import NumiTissueIO

/// Only explicitly nonphysical implementations may run without a live deployment verifier.
public protocol NonphysicalNeuralCultureBackend: NeuralCultureBackend {}

public protocol WatchdogNeuralCultureBackend: InterlockedNeuralCultureBackend {
    /// Refresh an already operator-armed DEVICE-local watchdog. Must not rearm a stopped device.
    func refreshWatchdog(session: NeuralCultureSession) async throws -> ClosedLoopInterlockState
}

public struct ClosedLoopAdmissionRequest: Sendable {
    public var runID: UUID
    public var session: NeuralCultureSession
    public var environment: ClosedLoopEnvironment
    public var identity: ClosedLoopDeviceIdentity
    public var envelopeSHA256: ScientificSHA256Digest
}

/// Application-supplied policy verification: operator approval, device-specific laboratory limits,
/// earlier-stage results and expiry. No default implementation authorizes physical stimulation.
/// Returned expiry is in the named device clock. This is a trusted in-process boundary, not a sandbox.
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
    private var requestIDs = Set<UUID>()
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
                throw ClosedLoopError.unsafe("physical operation needs independent watchdog, durable journal and operator admission verifier")
            }
        } else {
            guard backend is any NonphysicalNeuralCultureBackend else {
                throw ClosedLoopError.unsafe("a physical backend cannot be relabeled replay or emulator")
            }
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
                  capabilities.maximumElectrodes >= configuration.electrodes.count else {
                throw ClosedLoopError.unsafe("device scheduling capabilities")
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
                guard let end = nonphysicalExpiryNanoseconds else { throw ClosedLoopError.invalid("bounded virtual run expiry") }
                expiry = end
            }
            guard state == .admitting, expiry > now else { throw ClosedLoopError.latched("expired or interrupted admission") }
            try await log("admitted", now, ["run": runID.uuidString, "environment": environment.rawValue,
                "device": identity.serial, "firmware": identity.firmware, "clock": identity.clockID,
                "policy": try envelope.digest().hexadecimal, "expiry": String(expiry)])
            try Task.checkCancellation()
            guard state == .admitting else { throw ClosedLoopError.latched("admission interrupted") }
            state = .armed
        } catch {
            await stop(reason: "admission failed: \(error)")
            throw error
        }
    }

    public func observe(_ request: NeuralRecordingRequest) async throws -> NeuralRecording {
        guard state == .armed, !busy else { throw ClosedLoopError.latched("not armed or concurrent operation") }
        busy = true; defer { busy = false }
        do {
            let now = try await readClock()
            let end = try LoopArithmetic.add(request.startTimeNanoseconds, request.durationNanoseconds)
            let estimate = Double(request.durationNanoseconds) * 1e-9 * request.sampleRateHertz
            guard request.durationNanoseconds > 0, request.sampleRateHertz.isFinite, request.sampleRateHertz > 0,
                  estimate.isFinite, estimate >= 1, estimate <= 1_000_000,
                  !request.electrodeIDs.isEmpty, request.electrodeIDs.count <= 4096,
                  Set(request.electrodeIDs).count == request.electrodeIDs.count,
                  Set(request.electrodeIDs).isSubset(of: Set(configuration.electrodes.filter(\.enabled).map(\.id))),
                  end <= expiry, now < expiry else { throw ClosedLoopError.invalid("bounded recording request") }
            try await checkInterlock(now: now, through: end, refresh: true)
            let recording = try await backend.record(session: session, request: request)
            guard state == .armed, recording.request == request, recording.droppedSamples == 0,
                  recording.frame.electrodeOrder == request.electrodeIDs,
                  recording.frame.sampleRateHertz == request.sampleRateHertz,
                  recording.frame.samplesByElectrode.count == request.electrodeIDs.count,
                  recording.frame.sampleCount > 0, recording.frame.sampleCount <= 1_000_000,
                  recording.frame.samplesByElectrode.allSatisfy({
                      $0.count == recording.frame.sampleCount && $0.allSatisfy(\.isFinite)
                  }), recording.backendTimestampNanoseconds >= end else {
                throw ClosedLoopError.unsafe("recording dropout, identity, timestamps or channel data")
            }
            for spike in recording.spikes {
                guard request.electrodeIDs.contains(spike.electrode), spike.sampleIndex >= 0,
                      spike.sampleIndex < recording.frame.sampleCount, spike.amplitudeVolts.isFinite else {
                    throw ClosedLoopError.invalid("recorded spike")
                }
            }
            let digest = ScientificSHA256Digest(data: try ScientificCanonicalJSON.encode(recording))
            try await log("observation", recording.backendTimestampNanoseconds,
                ["sha256": digest.hexadecimal, "samples": String(recording.frame.sampleCount)])
            guard state == .armed else { throw ClosedLoopError.latched("stopped during observation") }
            latestObservationSHA256 = digest; latestObservationEnd = end
            return recording
        } catch {
            await stop(reason: "observation failed: \(error)")
            throw error
        }
    }

    public func submit(_ request: NeuralStimulationRequest,
                       basedOn observationSHA256: ScientificSHA256Digest) async throws -> NeuralStimulationReceipt {
        guard state == .armed, !busy else { throw ClosedLoopError.latched("not armed or concurrent operation") }
        busy = true; defer { busy = false }
        do {
            guard !requestIDs.contains(request.id), requestIDs.count < 100_000,
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
                deviceNowNanoseconds: now,
                deviceMinimumLeadNanoseconds: capabilities.minimumStimulationLeadTimeNanoseconds,
                timestampResolutionNanoseconds: capabilities.timestampResolutionNanoseconds, history: reservations)
            guard decision.endNanoseconds <= expiry else { throw ClosedLoopError.unsafe("plan exceeds session expiry") }
            try await checkInterlock(now: now, through: decision.endNanoseconds, refresh: true)
            guard state == .armed else { throw ClosedLoopError.latched("stopped before reservation") }
            // Reserve BEFORE any await or dispatch; never release on an ambiguous acknowledgement.
            requestIDs.insert(request.id); reservations.append(contentsOf: decision.exposures)
            try await log("stimulation-intent", now, ["id": request.id.uuidString,
                "request": decision.requestSHA256.hexadecimal, "observation": observationSHA256.hexadecimal,
                "policy": decision.envelopeSHA256.hexadecimal])
            now = try await readClock()
            let earliest = try LoopArithmetic.add(now, max(capabilities.minimumStimulationLeadTimeNanoseconds,
                                                           envelope.minimumLeadTimeNanoseconds))
            try Task.checkCancellation()
            guard state == .armed, request.scheduledTimeNanoseconds >= earliest, now < expiry else {
                throw ClosedLoopError.unsafe("deadline missed during admission/journaling; never execute immediately")
            }
            let receipt: NeuralStimulationReceipt
            do { receipt = try await backend.stimulate(session: session, request: request) }
            catch {
                // Transport failure can follow actual delivery. At-most-once application dispatch:
                // query/reconcile receipts outside this stopped session; do not resend this request.
                throw ClosedLoopError.ambiguousDelivery(request.id)
            }
            guard receipt.requestID == request.id,
                  receipt.acceptedAtNanoseconds >= now,
                  receipt.acceptedAtNanoseconds <= (request.deadlineNanoseconds ?? 0) else {
                throw ClosedLoopError.ambiguousDelivery(request.id)
            }
            if receipt.status == .executed {
                guard let executed = receipt.executedAtNanoseconds,
                      executed >= request.scheduledTimeNanoseconds,
                      executed <= (request.deadlineNanoseconds ?? 0) else {
                    throw ClosedLoopError.ambiguousDelivery(request.id)
                }
            }
            try await log("stimulation-receipt", receipt.acceptedAtNanoseconds, receipt)
            guard state == .armed, receipt.status == .accepted || receipt.status == .executed else {
                throw ClosedLoopError.unsafe("stopped, rejected or cancelled stimulation")
            }
            return receipt
        } catch {
            await stop(reason: "dispatch failed: \(error)")
            throw error
        }
    }

    /// Callable while another actor operation is suspended. Stop is latched before transport I/O.
    /// Failure to contact a device never becomes a successful stop acknowledgement.
    @discardableResult public func stop(reason: String) async -> Bool {
        state = .stopped
        var confirmed = !environment.hasPhysicalEffects
        if let interlocked = backend as? any InterlockedNeuralCultureBackend {
            do {
                let result = try await interlocked.emergencyStop(session: session, reason: reason)
                confirmed = result.identity == identity && result.stopConfirmed
            } catch { confirmed = false }
        }
        do { try await log("stopped", lastDeviceTime, ["reason": reason, "confirmed": String(confirmed)]) }
        catch { /* Stop was attempted even when the audit sink failed. Session remains latched. */ }
        return confirmed
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
        let status = try await (refresh ? device.refreshWatchdog(session: session) : device.interlockState(session: session))
        guard status.identity == identity, status.deviceNowNanoseconds >= now,
              status.armedUntilNanoseconds >= through, status.autonomousWatchdogNanoseconds > 0,
              status.autonomousWatchdogNanoseconds <= envelope.maximumObservationAgeNanoseconds,
              !status.stopConfirmed, status.measuredVoltageLimitSatisfied,
              status.temperatureKelvin.isFinite,
              status.temperatureKelvin >= envelope.minimumTemperatureKelvin,
              status.temperatureKelvin <= envelope.maximumTemperatureKelvin else {
            throw ClosedLoopError.unsafe("interlock identity, arming, watchdog, voltage or temperature")
        }
    }
    private func log<T: Encodable>(_ kind: String, _ time: UInt64, _ payload: T) async throws {
        try await audit.append(kind: kind, deviceNanoseconds: time, payload: ScientificCanonicalJSON.encode(payload))
    }
}
