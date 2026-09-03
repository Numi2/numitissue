# Phase 3 status

This status is deliberately fail-closed. It describes what the repository
can prove from source and what still requires measured evidence on an Apple
Silicon host.

| Area | Status | Boundary |
|---|---|---|
| Separate Metal 4 backend | Implemented in source | Runtime construction still requires a Metal 4 device and SDK |
| Swift 6 strict-concurrency build | Existing regression coverage | Must be rerun on the published revision |
| Metal shader compilation and pipeline prewarm | Existing tests and controlled runner | A source audit is not a driver/runtime qualification |
| CPU/reference, legacy Metal, and Metal 4 fixtures | Existing validation coverage | Comparisons are fixture-scoped and do not replace biological calibration |
| Data, DANDI, decoder, checksum, provenance, and evidence tests | Existing Swift validation coverage | External reference packages remain a separate prerequisite |
| Metal 4 indirect dispatch | Disabled by default; allow-list empty | No kernel may be promoted without its exact worklist ABI and evidence |
| Phase 3 source audit | `Tools/phase3/run_static_audits.sh` | Fails on missing files, ABI drift, availability drift, or dirty source |
| Apple Silicon host doctor | `Tools/phase3/doctor.py` | Requires Darwin arm64, macOS 26+, current SDK surface, and Metal 4 GPU |
| Controlled execution record | `Tools/phase3/run_apple_qualification.sh` | Produces qualification evidence only |
| Sealed qualification bundle | Not present | No bundle verifier or signed authority is accepted implicitly |
| Production promotion certificate | Not present | `productionAuthorized` must remain false |
| External NEURON/Arbor/STEPS/eFEL environment | Host-dependent | Missing packages/checkouts are retained as failed prerequisite evidence |

The status command is machine-readable:

```bash
./.build/debug/numitissue phase3 status
python3 Tools/phase3/phase3_evidence.py status
```

Neither command asserts that hardware qualification or production promotion
has occurred.
