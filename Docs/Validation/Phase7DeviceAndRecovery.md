# Phase 7 device and native recovery continuation

Status: source implemented, not executed against vendor hardware in this environment.

## CL1

Research was refreshed against the current Cortical Labs developer/reference documentation before
implementing the adapter. The documented API provides device frame timestamps, `StimPlan.run` with
an absolute timestamp, an 80 microsecond minimum stimulation lead, 20 microsecond timing increments,
`interrupt` for cancelling queued/channel stimulation, and `DetectionResult.stims`/`Stim.timestamp`
for observing delivered stimulation. `cl.open()` explicitly does not automatically stop the device.
The device also enforces a 200 Hz maximum individual-stimulation frequency per channel.

Sources:

- https://docs.corticallabs.com/
- https://docs.corticallabs.com/cl
- https://docs.corticallabs.com/cl/app/model

Implemented:

- `Tools/phase7/device_sidecars/cl1_sidecar.py`: device-local Python SDK boundary. It starts in an
  interrupted state, requires an operator arm lease, maintains a host-loss watchdog, rejects late
  absolute timestamps, uses at-most-once request IDs, interrupts all channels on errors/exit, and
  reconciles enqueue acknowledgements against observed `Stim` events.
- `DeviceSidecarAdapters.swift`: Swift-side bounded transport contract and CL1 receipt conversion.
  It discovers the actual frame duration rather than assuming the NumiTissue 25-us simulation tick.

Important limitation: the watchdog is a sidecar-process watchdog, not independent firmware or
external hardware. If the Python process itself is killed in a way that prevents `finally` cleanup,
this source cannot prove the CL1 has stopped. Physical admission must therefore remain disabled until
that failure mode is tested with the actual CL1 and, if necessary, backed by an external supervisor.

The sidecar has not been run here. First run it against the official CL SDK Simulator, inject process
termination and delayed requests, then inspect recorded stim timestamps. Only then move to a
nonbiological electrical load / operator-approved CL1 validation.

## FinalSpark

The current public NeuroPlatform v2 documentation says the system is network-mediated, has a strict
minimum network delay of roughly 35-50 ms, requires at least five seconds after `upload_stimparam`
before triggering or reading, and describes closed loops below roughly 200 ms as challenging. It
also directs users to `IntanController.disable_all_stim()` for safe cleanup and uses a 16-integer
trigger pattern.

Sources:

- https://finalspark-np.github.io/np-docs/np_core/doc_v2.html
- https://finalspark-np.github.io/np-docs/np_core/best_practices.html
- https://finalspark-np.github.io/np-docs/np_core/faq.html

Because those semantics do not provide an exact device-clock execution receipt comparable to CL1,
NumiTissue does **not** expose FinalSpark as a hard-real-time `NeuralCultureBackend`. The new
`FinalSparkAuditedContract` encodes the five-second settling requirement, exact trigger shape and
mandatory cleanup operation, and explicitly rejects use as the exact-timestamp Phase 7 backend.
This is preferable to manufacturing an execution timestamp from a network acknowledgement.

A future FinalSpark adapter can support asynchronous experimental campaigns after an operator-owned
SDK wrapper is available and tested. It should preserve trigger/configuration evidence and mark
physical delivery as unknown unless the platform supplies independent measurement.

## NumiBrain native recovery

The current `Numi2/numi-brain` repository already has a real joint transaction runtime and Metal
agent-state checkpoint kernels. Work therefore continued in that repository rather than duplicating
brain state in NumiTissue.

Added in NumiBrain:

- `BrainDurableRecovery.swift`: complete semantic `BrainAgentState` prepared-generation artifact,
  irreversible commit-decision chain, atomic/fsync persistence, and recovery-candidate loading.
- `MetalAgentStateRecovery.swift`: public byte-exact wrapper over the existing private Metal
  checkpoint snapshot/restore kernels, with generation and byte-integrity checks.

This gives the native brain a restartable committed Metal arena plus a durable semantic decision
record. One gap remains: the existing Metal runtime snapshots the **committed** arena. It does not yet
export the full private shadow hot state + mutation journal after `prepareCommit` but before
publication. Therefore the source does not claim that an arbitrary mid-prepare process death can
reconstruct the unpublished GPU shadow. Closing that gap requires a dedicated shadow-snapshot Metal
kernel/path using the transaction's output hot buffer and journal. It should be implemented and
fault-tested inside NumiBrain, where those buffers are authoritative.

## NumanX native recovery

The `Numi2/numanx` repository currently contained only an eight-byte README; there was no native
solver state to connect. Pretending otherwise would make the suite recovery claim false.

The repository now contains `Sources/NumanXRecovery/NumanXDurablePreparedState.swift`, defining the
required durable manifest and native solver protocol. The future solver must persist authoritative
state, topology/configuration fingerprints and all GPU reconstruction bytes before voting prepared;
a commit decision is irrevocable and recovery is idempotent roll-forward.

The actual NumanX solver and GPU buffers still have to be built in that repository before this
contract can become executable.

## Next executable gates

1. Compile/test NumiTissue and NumiBrain on the target Apple Silicon machine.
2. Run the CL1 sidecar against the official simulator and inject late timestamps, queue pressure,
   lost acknowledgements, sidecar termination and restart.
3. Add NumiBrain prepared-shadow snapshot/restore, then kill the process at every transition between
   GPU finish, durable prepare, commit decision and publication.
4. Build the actual NumanX runtime against its newly established recovery ABI.
5. Only after those gates, wire the three native prepared participants into the durable suite journal.

No hardware, biological, latency or crash-recovery qualification is asserted by this source update.
