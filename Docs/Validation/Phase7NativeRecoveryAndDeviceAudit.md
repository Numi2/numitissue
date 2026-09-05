# Native recovery and CL SDK integration audit

This increment implements additional recovery code and corrects the earlier CL1 adapter. It does
not mark Phase 7 complete or certify a live device. No Swift build, Python test, shader compilation,
GPU execution, hardware stimulation or biological experiment was run during this increment.

## NumiBrain: real unpublished cognitive state

`Numi2/numi-brain` now contains:

- `BrainPreparedGPUImage`: base hot state, candidate hot state, base persistent memory and the
  complete unapplied memory journal; native root identity, layout fingerprints and SHA-256.
- `MetalPreparedRecoveryTransfer`: exact byte copies on the owner-supplied Metal 4 command buffer,
  retained residency/staging and completion-gated host access.
- New capture and restore operations on the actual `MetalJointAgentStateTransaction`.
- `BrainPreparedGPUStore`: immutable, fully synchronized image/prepare/decision publication and
  bounded verified reads after process restart.
- `BrainPreparedGPURecoveryTests`: regression source for corruption, journal invariants,
  conflicting candidates, storage bounds, locking and irreversible decisions.

This closes the previous *cognitive arena* gap: the earlier committed checkpoint did not preserve
an unpublished candidate and its pending memory writes. The candidate restore stays unpublished
until the real joint owner supplies a matching durable decision and native commit receipt.

It does not capture every fast `MetalTissueRuntime` buffer, physical NumanX state, external archive
or NumiTissue pool. Those owners retain separate native state. See the brain repository's
`docs/PREPARED_GPU_RECOVERY.md` for exact capture/restore ordering and remaining owner integration.

## NumanX: executable recovery support, not a fabricated solver

The standalone `Numi2/numanx` repository initially contained only its recovery protocol. It now has
an actual Swift package, `FileNumanXPreparedStateStore`, a recovery coordinator, inspection CLI and
regression sources. The store persists the supplied authoritative/GPU bytes and verifies SHA-256,
lengths and generations on reopening. Decisions are immutable. The coordinator requires an actual
native publication receipt, rejects later/unrelated state and never infers commit from prepare.

This is an implementation of persistence/recovery, not a new implementation of the full physics
solver. The inspected NumiLab sources include a Matter runtime and accepted-snapshot exporter, but
that exporter does not provide a complete unpublished NumanX/MyoSim image. No local-only source path
or unavailable native class has been invented to claim full integration.

The native physical state adapter, full fast-brain state, authentic joint root receipts and the
owner's restore/bootstrap sequence remain required. They must be connected in the authoritative
native projects, not approximated with generic host object state.

## CL1: concrete defects corrected

The previous sidecar was not suitable for physical admission:

- Its watchdog was checked only when requests arrived, so idle input could bypass expiry.
- Interrupt exceptions were ignored while returning successful stop confirmation.
- Request identity was recorded after the SDK call, permitting uncertainty after acknowledgement loss.
- Reconciliation accepted unrelated or partial stimulation events.
- Mixed decreasing timestamps could pass the shared-start check.
- The phase-count check confused width/current argument count with the number of phases.
- The Swift wrapper exposed a manual `markArmedForVerifiedSidecar` bypass.

The sidecar now **refuses physical CL1 before taking control or opening a device**. The Swift
adapter independently requires simulator identity and does not conform to the physical watchdog
backend protocol. There is no flag, environment variable, operator boolean or legacy manual arming
method that makes this path a physical deployment.

The SDK simulator path now has one-shot bounded admission, idle expiry polling, explicit failed-stop
results, a bounded input parser, duplicate-JSON/nonfinite rejection, future-only bounded schedules,
complete-waveform deadlines, exact shared starts, unique channels, balanced bi/triphasic waveforms,
request reservation before SDK submission and no automatic resend. Reconciliation matches the full
channel/timestamp multiset; missing, extra, duplicate or mistimed SDK events cannot become an
executed receipt. SDK events are not independent measurements of electrode charge or voltage.

A host poll loop cannot survive process death or a stuck native call. It is intentionally named and
reported as simulator behavior, not autonomous device protection. Temperature and measured voltage
are reported unavailable rather than fabricated. Original pulse timing is preserved, not silently
rounded to tissue ticks.

### Simulator-only API changes

Use `verifyIdentity()` then `armSimulator(untilFrame:hostTimeoutNanoseconds:)`. Submission requires
`submit(id:pulses:deadlineFrame:)`. The old manual arming method and deadline-free submission are
compile-time unavailable. The wire format remains a flat JSON object with `op` and payload fields.
The Python `arm-simulator` operation cannot rearm a stopped or expired session.

Dependency-free test source is in `Tools/phase7/device_sidecars/test_cl1_sidecar.py`:

```sh
python3 -m unittest discover -s Tools/phase7/device_sidecars -p 'test_*.py'
```

These tests use an SDK double; even a pass would not qualify CL hardware or biological behavior.
They have not been executed here.

## FinalSpark and physical deployment

The existing FinalSpark contract continues to reject exact-time physical admission. Public network
operations and `disable_all_stim` do not by themselves establish independently enforced deadlines,
process-death shutdown or measured delivery. No production FinalSpark actuator adapter has been
certified or enabled by this increment.

Actual physical admission still needs vendor/device-supported mechanisms for hard deadline
rejection, independently measured voltage/health, autonomous shutdown on host failure, persistent
request reconciliation and operator authorization. Where the installed hardware cannot provide a
required mechanism, software must report it unsupported rather than manufacturing a capability.

## Primary API references checked

- CL API reference and simulator identity, interrupts, frame timestamps, read bounds, Stim events:
  https://docs.corticallabs.com/cl
- CL developer guide: https://docs.corticallabs.com/
- Apple Metal 4 copy stages and command encoder:
  https://developer.apple.com/documentation/metal/mtl4computecommandencoder
- Apple consumer barriers:
  https://developer.apple.com/documentation/metal/synchronizing-passes-with-consumer-barriers

The CL API explicitly documents that a past `StimPlan.run(at_timestamp:)` can run immediately. A
host-side timestamp check has a race and cannot establish device-enforced no-late-delivery behavior.
That is one reason the current bridge stays simulator-only. A public API reference is not a
laboratory safety certification or a measurement from the user's installed firmware.
