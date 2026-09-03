# Phase 3 Metal 4 verification

Phase 3 is a controlled validation boundary for the separate Metal 4 backend.
It records source, host, execution, and evidence state independently. A source
audit or a successful test run is not a numerical qualification and cannot
authorize `performance32`.

## Current contract

The Metal 4 path is required explicitly when selected. It uses the current
Apple SDK surface, validates the 31-buffer argument-table limit, keeps the
indirect-dispatch allow-list empty until a kernel-specific ABI is qualified,
and records qualification execution separately from production execution.
The CPU reference and existing Metal/Metal 4 tests remain the executable
correctness authorities for the behaviors they cover.

Production promotion is intentionally blocked in this repository until a
bound workload, execution configuration, device identity, pipeline archive,
differential evidence, determinism evidence, rollback evidence, and sealed
promotion certificate are implemented and independently verified. No command
in this directory issues such a certificate.

## Checks

Run the static audit from a clean checkout:

```bash
Tools/phase3/run_static_audits.sh
```

Inspect the Apple Silicon host and SDK without creating repository artifacts:

```bash
python3 Tools/phase3/doctor.py
```

Run the bounded, manual-only evidence sequence. Use a new output directory;
`Phase3Artifacts/` is ignored by Git for this purpose.

```bash
Tools/phase3/run_apple_qualification.sh --output Phase3Artifacts
```

The runner performs the source audit before creating output, checks Darwin,
arm64, macOS 26 or newer, Xcode/Swift/Metal tools, the exact Metal 4 SDK
headers used by the source, and a GPU that advertises Metal 4. It then records
the following required checks:

* strict Swift build;
* all Swift tests with Metal API validation and the Metal differential path;
* release, AddressSanitizer, and ThreadSanitizer Metal 4 planning tests;
* the actual shader-library pipeline prewarm test;
* standalone compile/link of the three mechanism and molecular VM shaders;
* Python tool syntax and CLI smoke checks;
* a retained, non-required report for the external reference environment.

The runner continues through the required checks so a failure is retained in
its log. It exits nonzero when the host preflight or any required command
fails. Its `manifest.json` is integrity-checked before the runner exits:

```bash
python3 Tools/phase3/phase3_evidence.py verify Phase3Artifacts/manifest.json
./.build/debug/numitissue phase3 verify Phase3Artifacts/manifest.json
```

For the full differential test selection, the runner sets
`NUMITISSUE_RUN_METAL_DIFFERENTIAL=1` for the relevant Swift commands. The
environment variable does not turn a failed comparison into a pass.

## Evidence boundary

The manifest uses `executionPurpose: "qualification"`, records
`productionAuthorized: false`, and declares missing promotion nodes in an
acyclic evidence graph. It rejects path traversal, symlink traversal,
duplicate artifact records, changed SHA-256 content, unrecorded files, graph
cycles, and any request to treat an embedded or detached certificate as
verified.

The external reference doctor is separate from the Swift data and provenance
tests. If the pinned NEURON, Arbor, STEPS, eFEL, or Python environment is not
installed, that fact remains a failed prerequisite in the retained report; it
is not replaced with a mock and it does not get silently omitted.

## Interpretation

Passing the controlled run establishes that this revision can execute the
covered Apple Silicon smoke and regression checks on the selected host. It
does not establish biological calibration, a performance budget, energy
qualification, production authorization, or scientific equivalence outside
the measured fixtures. Those claims require the bound evidence described in
the request schema and status record.
