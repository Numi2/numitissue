# Phase 2 — CPU–Metal equivalence

Phase 2 establishes whether NumiTissue's Apple GPU backend executes the same declared model as the correctness-oriented CPU backend.

It does not treat a successful run as evidence of equivalence. The validation path compares state at scheduled phase boundaries, expands mismatches into semantic differences, certifies rollback behavior, checks same-seed replay, and records performance separately from correctness.

## Numerical profiles

Every validation or benchmark report carries an explicit `RuntimeNumericalProfile`.

| Profile | Current use | Floating-point contract |
|---|---|---|
| `reference64` | Reserved name for the future FP64 oracle path | Not yet a complete FP64 implementation |
| `scientific32` | Correctness-oriented FP32 execution | Safe Metal math mode, exact discrete state, bounded floating-point differences |
| `performance32` | Throughput-oriented FP32 execution | Fast Metal math mode, exact discrete state, wider declared floating-point tolerances |

The existing CPU reference runtime stores authoritative tissue state in FP32. It remains the semantic comparison backend, but Phase 2 must not describe it as a completed FP64 oracle. A separate FP64 reference path remains future work.

## What is compared

The differential contract separates state into these domains:

- metadata and capacity;
- tiles;
- cells;
- regulatory state;
- neurite segments;
- electrical compartments;
- mechanism state;
- synapses;
- extracellular fields;
- molecular microdomains;
- molecular species;
- delayed events;
- outputs;
- runtime counters.

Identifiers, topology, ranges, event ordering, discrete flags, solver choices, transaction identity and counters are exact by default. Floating-point fields are compared using a domain-specific combination of:

- absolute tolerance;
- relative tolerance;
- ULP distance;
- finite-value requirements.

`RuntimeDeterminismContract.bitwise`, `.scientific32`, and `.performance32` are versioned contracts. A tolerance change is therefore an explicit scientific change rather than an implicit test adjustment.

## Phase-by-phase differential execution

`DifferentialTissueRunner` executes one phase schedule through a reference backend and one or more candidate backends.

For every selected phase boundary it:

1. Executes the same phase and tick range on every backend.
2. Captures canonical pool digests.
3. Compares counts, delayed-event count and exact counters.
4. Requests complete semantic state only when a digest, count or counter differs.
5. Reports the first mismatched field with bounded difference output.
6. Stops at the first divergent phase by default.
7. Rolls every backend back unless commit mode was explicitly requested.

The default `rollbackAfterComparison` policy avoids partial multi-backend commit. `commitAfterValidation` exists for repeated differential experiments, but commits are sequential and should not be treated as a distributed atomic transaction.

## Canonical state digest

The canonical digest is semantic rather than a hash of native struct bytes. It excludes padding and reserved ABI fields and hashes each declared value in a fixed order.

The digest has four 64-bit lanes and is intended for divergence localization and deterministic identity checks. It is not a replacement for the SHA-256 artifact digests used by campaign provenance.

The Metal module contains a compact state-digest kernel. Ten GPU threads independently walk the ten GPU-resident state pools and return 320 bytes of digest output. `MetalStateDigestEngine` validates this kernel against the host semantic digest without modifying a production transaction.

The current production `MetalTissueBackend.captureShadowDigest` still uses the full shadow-inspection path. Direct installation of the compact digest buffers into the live backend is the remaining optimization after host/GPU digest parity is confirmed on Apple hardware.

## Delayed events

A delayed event is normalized before comparison:

- synapse-index destinations are converted to stable `SynapseID` values when the source and route identity agree;
- non-synaptic destinations retain their raw value;
- arrival tick, source, amplitude, event kind, flags and sequence remain explicit.

This allows event-wheel state to survive topology compaction and adaptive-fidelity migration without comparing transient array offsets as biological identity.

## Rollback certification

`RuntimeRollbackVerifier` produces a `RuntimeRollbackCertificate` for one failed or explicitly rolled-back transaction.

The certificate records:

- the triggering failure or validation rejection;
- committed state digest before and after rollback;
- backend-checkpoint digest before and after rollback;
- validation issues;
- deterministic fault rules that fired;
- backend and numerical profile;
- transaction identity and seed.

A rollback certificate passes only when visible state is unchanged and, when required, delayed/backend-private checkpoint state is also unchanged.

`FaultInjectingTissueBackend` can inject deterministic failures at explicit lifecycle sites, including before or after a phase, after validation, before commit, or around rollback. Diagnostic perturbations affect only exported inspections and outputs; they do not alter wrapped committed state.

## Same-seed replay

`RuntimeReproducibilityVerifier` creates a fresh backend for every repetition and executes the same transaction, input and seed sequence.

After every committed transaction it compares:

- authoritative state digest;
- backend checkpoint-state digest;
- output digest;
- counters;
- validation digest.

This is stricter than comparing only the final checkpoint because it identifies the first transaction at which deterministic identity is lost.

## Benchmarking

`RuntimeBenchmarkRunner` separates warmup transactions from measured transactions and reports:

- minimum, median, p95, p99 and maximum transaction latency;
- mean and standard deviation;
- simulated milliseconds per wall-clock second;
- active and reserved state footprint;
- bytes per cell, compartment and synapse;
- final state digest;
- backend telemetry when available.

Metal telemetry currently records:

- private and shared buffer allocations;
- explicit host-to-device uploads;
- explicit device-to-host state readbacks;
- compute and transfer command buffers;
- instrumented compute and blit encoders;
- instrumented dispatches;
- completed and failed command buffers;
- measured GPU start/end duration when supplied by Metal.

Encoder instrumentation is currently partial because some model-archive and overlay helpers own encoders internally. Reports mark this explicitly.

Energy remains absent unless a real measurement provider supplies joules. NumiTissue does not infer energy from elapsed time or device name.

## Running the validation cases

From an Apple Silicon checkout:

```bash
swift build
swift test
```

Run the compact GPU digest and Metal telemetry cases:

```bash
swift test --filter MetalDifferentialValidationTests
```

The complete CPU–Metal phase comparison is opt-in because it is intended to expose scientific differences rather than be silently skipped or weakened:

```bash
NUMITISSUE_RUN_METAL_DIFFERENTIAL=1 \
  swift test \
  --filter MetalDifferentialValidationTests/testFullScientificCPUMetalDifferentialWhenExplicitlyEnabled
```

Run only the CPU differential, rollback and replay cases:

```bash
swift test --filter DifferentialExecutionValidationTests
swift test --filter RollbackVerificationTests
swift test --filter ReproducibilityValidationTests
```

## Required report metadata

A retained Phase 2 report should include:

- NumiTissue Git commit;
- Swift and Xcode versions;
- macOS version;
- device name and registry identifier;
- numerical profile;
- Metal math mode;
- model and initial-state artifact digests;
- random seed;
- transaction cadence;
- comparison-contract identifier;
- validation-case identifier;
- benchmark warmup and measured transaction counts;
- all skipped or unavailable measurements.

## Phase 2 exit criteria

Phase 2 is complete only when all of the following have been demonstrated on Apple hardware:

1. Every deterministic Phase 1 case passes the CPU–Metal semantic contract.
2. Stochastic cases use identical stream assignment and pass their declared distributional tests.
3. The compact GPU digest matches the host semantic digest for all validation fixtures.
4. Same-seed runs reproduce state, delayed events, outputs, counters and validation results.
5. Fault injection preserves committed and backend-private state after rollback.
6. Scientific mode uses safe floating-point math and never silently falls back to another backend.
7. Performance mode differences are measured against scientific mode rather than assumed acceptable.
8. Apple Silicon latency, throughput, memory traffic and GPU duration are published with complete metadata.
9. Energy is reported only when measured.
10. All unresolved divergences are retained as artifacts with the first mismatched phase and semantic field.

## Current implementation status

Implemented in source:

- numerical profiles and versioned tolerance contracts;
- canonical semantic digests;
- semantic state and output comparison;
- phase-by-phase differential runner;
- CPU and Metal shadow inspection;
- deterministic fault injection;
- rollback certificates;
- same-seed replay certificates;
- benchmark reports and backend telemetry;
- scientific Metal math mode;
- compact GPU state-digest kernel and standalone parity engine;
- validation cases for the above components.

Not established until run on the target machine:

- successful Swift compilation of every new path;
- successful compilation of the new Metal digest shader;
- host/GPU digest parity;
- CPU–Metal scientific equivalence;
- same-device deterministic Metal replay;
- latency, throughput, memory and GPU-duration baselines;
- hardware-counter or energy measurements.
