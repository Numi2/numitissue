# Phase 7 — closed-loop interfaces and recoverable suite execution

## Status

Implemented in source against repository baseline `f9c12960ec9160c2efb6466e9c0418e4f57d5717`.
**Uncompiled, unexecuted and not hardware- or biologically qualified.** This is not a claim that every
Phase 7 exit criterion has passed. No live device was contacted and no performance32 authorization
was issued. Tests are committed for execution on the user's Apple Silicon system.

The implemented software path is:

```
recording replay / responsive RC interface emulator
    -> bounded acquisition and freshness checks
    -> application policy proposes a stimulation request
    -> independently recomputed dose/timing checks
    -> durable intent before physical dispatch
    -> device-local scheduling and interlock contract
    -> receipt or explicit ambiguous-delivery stop
```

The independent simulation path is:

```
NumiBrain + NumiTissue + NumanX shadow execution
    -> all participants validate
    -> prepare tokens
    -> recorded commit decision
    -> idempotent publication
    -> joint committed observation, or fenced in-doubt recovery
```

These paths have different failure semantics. A simulation buffer can be discarded. Stimulation
already delivered to living tissue cannot be rolled back. A motor moving physical hardware cannot
be made transactional merely by implementing a Swift rollback method.

## Source map

All files below except the coordinator live in `Sources/NumiTissueIntegration/ClosedLoop/`.

| File | Responsibility |
| --- | --- |
| `ClosedLoopContracts.swift` | Device identity, clock mapping, explicit laboratory envelope, interlocks |
| `ClosedLoopSafetyEvaluator.swift` | Exact phase checks, cross-request recovery, rolling charge/duty and concurrency |
| `GuardedNeuralCultureSession.swift` | One-shot admission, bounded feedback, immutable intent, receipts and latched stop |
| `ClosedLoopJournal.swift` | Memory and fsync-backed append-only records with SHA-256 chaining |
| `DurableSuiteJournal.swift` | Single-writer prepare/commit-decision journal and restart-time inspection |
| `PreparedTissueBackendAdapter.swift` | Process-local idempotent tissue publication |
| `SnapshotSuiteEndpoints.swift` | Typed, snapshot-isolated NumiBrain and NumanX model adapters |
| `ReplayNeuralCultureBackend.swift` | Deterministic recording replay and bounded loop runner |
| `RCNeuralInterfaceEmulator.swift` | Responsive electrical RC load for interface testing, not biological tissue |
| `DeviceStimulationSchedule.swift` | Exact conversion to device frame/phase clocks and microamperes |
| `ClosedLoopReplayExample.swift` | Fully synthetic end-to-end example with no device access |
| `../SuiteCoordinator.swift` | Existing coordinator corrected and connected to prepare/decision/recovery interfaces |

The CLI entry is `Sources/NumiTissueCLI/Phase7Command.swift`. Regression sources are in
`ValidationCases/Phase7ClosedLoopSafetyTests.swift`, `Phase7SuiteRecoveryTests.swift`, and
`Phase7DeviceTimingTests.swift`.

## Stimulation authority

`ClosedLoopSafetyEnvelope` deliberately has no default biological limits. Current, charge, density,
recovery, temperature and rolling-dose limits must come from the selected electrode, culture,
instrument and approved laboratory protocol. The example values are software fixtures only.

Before dispatch the evaluator checks:

- exact start, phase, gap and repetition timing; positive durations and checked integer arithmetic;
- enabled and mapped electrodes, exclusion lists and finite electrode geometry/impedance;
- current, per-phase charge, geometric charge-density estimate and signed charge balance;
- a resistive voltage estimate, plan end deadline and maximum duration;
- electrode recovery across requests, not just within one pulse train;
- cumulative charge, conservative duty fraction and simultaneous electrode occupancy;
- consistency between original pulse definitions and the legacy compiled cache.

The resistive voltage estimate is **not** electrode polarization, charge-injection capacity or a
validated interface impedance model. A physical adapter must independently enforce measured voltage
limits, device-specific electrochemistry constraints, temperature limits and emergency shutdown.

Reservations count accepted, delivered and unknown-delivery pulses. Transport errors do not refund
charge. Rolling-window checks conservatively count the full charge/activity of any intersecting
pulse and may reject a protocol that a more detailed integration would accept. This conservatism is
intentional. The current implementation caps session history rather than silently dropping records.

A physical session requires an `InterlockedNeuralCultureBackend` with a device-local watchdog,
a durable journal, and an application-supplied `ClosedLoopAdmissionVerifier`. The verifier must check
operator approval, identity/firmware/electrode map, prior-stage evidence, expiry and unresolved prior
runs. It must also account for cumulative exposure from earlier sessions before admitting a new run;
the in-memory per-session dose tracker is not a cross-session laboratory exposure database.

There is no built-in verifier that authorizes physical operation. A self-reported JSON boolean or
an earlier source-only qualification artifact is not sufficient evidence. These protocols define a
trusted in-process interface; they cannot sandbox malicious adapter or policy code.

## Timing and vendor interfaces

NumiTissue's 25-us simulation tick, a host monotonic clock, a device timestamp frame, and the waveform
phase quantum are different quantities. `DeviceStimulationScheduleCompiler` preserves original SI
pulse definitions and rejects unrepresentable timestamps/widths/gaps; it never silently rounds them.
The compiler does not dispatch, arm or grant permission to use hardware.

The Cortical Labs reference API describes frame-based timestamps, a 25-kHz frame stream and
separate stimulation timing constraints. Past timestamps can run as soon as possible. Its `cl.open`
context manager does not automatically stop the device. Adapters must query their actual runtime
clock and timing capabilities and reject stale schedules immediately before device-local submission.
Do not copy a 25-us NumiTissue tick into a CL timestamp field. Do not treat an HTTP acknowledgement
as observed stimulus delivery. [1]

FinalSpark's documentation calls for explicit stimulation disabling and cleanup. A generic
`RemoteNeuralCultureBackend` transport is not an implemented or validated FinalSpark controller. [2]

No production CL1 or FinalSpark driver has been certified by this increment. The application still
needs an audited SDK-specific adapter with voltage/health sensing, autonomous host-loss shutdown,
receipt reconciliation, queue cancellation, identity verification and device-enforced expiry.
Where the hardware cannot provide these interlocks, physical admission must remain unavailable.

The legacy `VirtualNeuralCultureBackend` is not automatically admitted to the guarded path. Its
25-us rounding, stimulus-unit/routing semantics and scheduled-versus-executed receipt behavior need
separate verification. The new replay and RC backends do not inherit those assumptions. Passing the
new safety compiler's cache-integrity check does not establish virtual/live numerical equivalence.

## Stop and uncertain delivery

The controller latches `stopped` before transport calls. There is no in-place rearm. A failed device
stop is reported as unconfirmed; it is not converted into successful zero output. The autonomous
hardware watchdog must stop even if the host is dead, suspended, blocked in a driver, or disconnected.
The adapter must atomically reject in-flight submissions after a device stop.

A lost acknowledgement after stimulus acceptance has status **unknown**, not “not delivered”.
The controller dispatches an ID at most once, retains exposure, records the intent and stops.
`reconcile` queries an existing request and never resends it. A stopped session requires operator
reconciliation outside the controller, followed by a separately authorized new session.

The runner checks cancellation between windows and around policy calls. Cancellation is cooperative:
it cannot interrupt a stuck foreign driver or prove a GPU command stopped. A host timeout is not a
replacement for device-local safety. Replay health and emulator temperature are explicitly synthetic.

## Suite consistency and recovery

The previous coordinator could interleave actor steps and roll brain/physics back after tissue had
already published. It now rejects reentrancy, fences incomplete publication, and never aborts after
a possible commit decision. Begin attempts are registered before suspension so partial begin failures
receive cleanup. Nonfinite analog inputs are rejected instead of silently removed.

Use `requirePreparedParticipants: true` for the stronger contract. All three participants must provide
idempotent prepared commits. `PreparedTissueBackendAdapter`, `SnapshotNumiBrainEndpoint<State>` and
`SnapshotNumanXEndpoint<State>` supply process-local adapters. The NumiBrain/NumanX numerical kernels
are passed in as typed pure transitions; they are not fabricated model implementations or imported
sibling repositories. Serialization separates committed and shadow objects to avoid reference aliasing.

`DurableSuiteTransactionJournal` records prepare, commit decision, completion, abort and in-doubt
states distinctly. It uses exclusive creation, a single-writer lock, SHA-256 chaining, file sync and
directory sync. Reopening is explicit and rejects an incomplete tail. An ambiguous write poisons the
open writer rather than permitting additional decisions. Logs detect corruption but are not digital
signatures, independent timestamps or evidence that a biological experiment occurred.

After a commit decision, completion is by idempotent roll-forward. `recoverCommit()` retries the
prepared transaction in the same process. No other step or exported joint state is allowed while
in doubt. Transactional state publication is visible through the coordinator; callers reading the
participants directly bypass that fence. Two-phase commit can block when a participant or decision
store is unavailable; this is not solved by labeling a partial commit an abort. [3]

**Cross-process automatic recovery is not implemented by these generic model adapters.** It requires
native participants to durably store their prepared state and transaction identity, then restore those
states before resolving the journal. A journal cannot reconstruct missing GPU buffers or model state.
The legacy nonthrowing rollback ports also cannot prove successful cleanup after a participant failure.
Do not claim crash-atomic whole-suite recovery without those native implementations and fault tests.

## Phase 6 electrical-current correction

The audit found a scientific defect in `CultureRuntimeCurrentExtractor`: subtracting capacitive
current while labeling the result *total* membrane current. It is now separated explicitly:

```
I_total,out = I_injected,in + I_axial,in
I_cap,out   = C * (V_new - V_old) / dt
I_ionic+syn,out = I_total,out - I_cap,out
```

The extracellular lead field needs the total, including capacitive current. Closed-cable axial
contributions cancel pairwise. A current-clamp experiment also needs its external return-electrode
source; the extractor does not invent that source. The diagnostic capacitive interval must match the
actual saved voltage interval. This is especially important when an observation frame spans several
fast substeps. LFPykit provides an independent transmembrane-current observation reference. [4]

Source IDs now follow stable compartment IDs rather than pool positions. Missing/ambiguous source
geometry, invalid radii, identifier overflow, cross-neuron edges and cyclic cable graphs are rejected.
Old recording predictions built from the incorrect total-current definition must be regenerated.

## Apple Silicon integration

This increment reuses the existing tissue backend and does not replace its Metal kernels. The guarded
host loop is a supervisory API, not a hard-real-time claim. Dense model evaluation can remain on Apple
GPU resources; the prepare boundary must only become ready after the relevant command buffer has
completed and validation has accepted its results. Commit must not recycle a buffer still used by the
GPU. Those lifetime obligations remain with the native backend adapter. [5]

Fsync and snapshot serialization are intentionally not performed for individual neurons or GPU lanes.
They operate at experiment/publication boundaries. Their latency must be measured before using a
5-ms wall-clock budget. Simulated time progressing by 5 ms does not imply real-time wall-clock behavior.
Phase 7 does not bypass Phase 3 numerical or performance qualification.

## Validation to execute

```bash
python3 Tools/phase7/source_audit.py
swift build
swift test --filter Phase7
swift run numitissue phase7 replay-example > phase7-replay.json
swift run numitissue phase7 safety-example > phase7-safety-input.json
swift run numitissue phase7 safety-check phase7-safety-input.json > phase7-safety-result.json
```

The tests cover dose/recovery limits, cached-plan substitution, integer overflow, clock uncertainty,
unknown delivery, deterministic replay, RC responses, explicit device timebases, partial suite commits,
idempotent recovery, prepublication rejection, journal tampering and membrane-current conservation.
The source audit checks file/contract presence only. Neither that audit nor a passing synthetic test
establishes living-culture safety, correct tissue learning, measured latency or clinical usability.

Remaining external gates: execute the source tests; qualify native Metal completion/rollback;
implement and review device and native model adapters; fault-inject disconnects, process death,
clock reset, voltage trips and lost acknowledgements on a nonbiological load; restore native prepared
states across process death; then perform approved living-culture experiments using materialized,
independently validated models. The Phase 6 biological held-out prediction gate is still unpassed.

## Primary references

[1] Cortical Labs CL API reference: https://docs.corticallabs.com/cl

[2] FinalSpark NeuroPlatform best practices:
https://finalspark-np.github.io/np-docs/np_core/best_practices.html

[3] PostgreSQL two-phase transaction documentation:
https://www.postgresql.org/docs/current/two-phase.html

[4] LFPykit observation models and units: https://lfpykit.readthedocs.io/en/latest/

[5] Apple command-buffer completion:
https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:)

Sources inform API and numerical contracts; no equivalence, device support or executed qualification
is claimed merely because a source is referenced.
