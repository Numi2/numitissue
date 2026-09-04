# Phase 7 examples

These are **synthetic software examples**. They do not open a hardware connection, stimulate living
neurons or establish validated neural computation. Their source is committed; they have not been
executed as part of this development increment.

## Bounded feedback replay

From an Apple Silicon checkout:

```bash
swift build
swift test --filter Phase7
mkdir Phase7Artifacts
swift run numitissue phase7 status > Phase7Artifacts/status.json
swift run numitissue phase7 replay-example > Phase7Artifacts/replay.json
swift run numitissue phase7 safety-example > Phase7Artifacts/safety-input.json
swift run numitissue phase7 safety-check Phase7Artifacts/safety-input.json > Phase7Artifacts/safety-result.json
```

`replay-example` processes two ten-sample recordings, proposes a small synthetic biphasic request for
each, applies the guarded-session checks, and stops. The first simulated receipt advances from
accepted to executed when the second recording advances the virtual clock. The second is cancelled
at the end of the bounded run. A request being accepted is not a claim that stimulation was delivered.

The output contains the complete software audit chain and its terminal SHA-256. Repeated runs use
fixed fixture identifiers and data so their journal identities should match; the regression test
checks this property when executed. Replay returns pre-recorded data: it does not simulate a culture
adapting to a changed policy.

To inspect the same journal through the CLI:

```bash
python3 - <<'PY'
import json
from pathlib import Path
root = Path('Phase7Artifacts')
report = json.loads((root / 'replay.json').read_text())
with (root / 'records.jsonl').open('x') as stream:
    for record in report['journal']:
        stream.write(json.dumps(record, sort_keys=True, separators=(',', ':')) + '\n')
PY
swift run numitissue phase7 journal-verify Phase7Artifacts/records.jsonl 00000000-0000-4000-8000-000000000007
```

The verifier checks chain integrity. It does not establish an independent timestamp, signer,
physical experiment, measured latency or biological safety.

## Responsive electrical emulator

`RCNeuralInterfaceEmulator` implements the same nonphysical backend interface but produces a response
to queued stimulation. It integrates a parallel RC circuit analytically between event/sample
boundaries. The test `testRCEmulatorRespondsToActualQueuedPulseAndDeduplicatesID` compares its output
to the RC step response and ensures a repeated request ID does not double the stimulus.

Use this backend for device-interface logic, timeout/fault wrappers, dose bookkeeping and sampling
contracts. It is not a neuron model. Use a separately validated NumiTissue runtime adapter for neural
responses. The legacy virtual backend is not implicitly promoted by these examples.

## Prepared Numi suite execution

`SnapshotNumiBrainEndpoint<State>` and `SnapshotNumanXEndpoint<State>` accept typed, pure model
transitions and mandatory state validators. They deep-copy committed/shadow states by serialization.
`PreparedTissueBackendAdapter` wraps an exclusively owned `NumiTissueExecutionBackend`.

Pass all three to `NumiSuiteCoordinator` with `requirePreparedParticipants: true`. The regression
`testPartialPublicationNeverRollsBackAndCanRecoverIdempotently` deliberately loses a brain commit
acknowledgement after tissue publication. It checks that the coordinator fences the run, never rolls
back already-published participants, and completes the transaction by idempotent recovery.

The native NumiBrain/NumanX models are supplied by the embedding application. These endpoint adapters
are process-local and are not a substitute for the native projects' durable prepared-state format.
Use `DurableSuiteTransactionJournal` to record decisions. Its CLI inspection is:

```text
numitissue phase7 suite-recovery-inspect <existing-suite.jsonl> <that-run-uuid>
```

The existing log must be complete, unmodified, and not held by another writer. Inspecting it does not
reconstruct a lost GPU state or publish a transaction automatically.

## Before physical hardware

Physical sessions remain unavailable without an audited device-specific adapter, autonomous watchdog,
confirmed stop/cancel behavior, current/voltage/thermal enforcement, identity verification, durable
intent recording and external operator admission. The admission check must also review unresolved
and recent exposure from previous sessions; session-local counters are not a laboratory database.

Use `DeviceStimulationScheduleCompiler` to distinguish timestamp frames from waveform quanta.
Configure these from the actual device. A timing conversion that requires rounding is rejected.
No example limit should be copied to a laboratory protocol without independent device/culture review.

See [`Docs/Validation/Phase7.md`](../../Docs/Validation/Phase7.md) for the audit findings, scientific
current-extraction correction, recovery semantics, current limitations and primary references.
