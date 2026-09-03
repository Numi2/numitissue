# Phase 3 evidence threat model

The qualification boundary assumes that source and generated evidence may be
edited by an operator, copied from another machine, or produced by an
unsupported workload. The verifier therefore fails closed.

| Threat | Required mitigation |
|---|---|
| Portable qualification permit reused on another host | Do not serialize a permit as a credential; bind future authority to device, workload, execution configuration, and expiry |
| Stale workload or configuration presented as current | Record the full repository identity and require a cryptographic workload/configuration binding before promotion |
| Device drift | Record the Metal device registry identity and require it to match the qualification evidence |
| Pipeline archive substitution | Hash archive evidence and reject an archive not bound to the exact workload and configuration |
| Path traversal or symlink escape | Accept only normalized relative paths and reject symlink components during inventory and verification |
| Changed logs or artifacts | Record byte count and SHA-256, then rehash every file during verification |
| Unrecorded evidence | Compare the complete directory inventory against the manifest artifact list |
| Boolean or detached-certificate bypass | Reject `productionAuthorized: true` and all embedded/detached certificates unless a real bound authority verifier exists |
| Circular evidence graph | Reject self-edges, duplicate edges, and any graph that fails topological ordering |
| Partial transaction commit | Require runtime rollback evidence and commit only after completion and validation; a log entry alone is insufficient |
| Non-finite or hidden validation failure | Preserve command exit codes and diagnostics; never turn warning, overflow, capacity, or conservation failures into success |
| Execution-order-dependent stochastic result | Require deterministic counter-based RNG identity in the measured workload and compare repeated runs |
| Reference/Metal semantic divergence | Require same-fixture differential comparison with domain-level state, output, conservation, and rollback checks |

This threat model does not claim that all future authority-bearing types exist
today. Until they do, the only valid Phase 3 result is qualification evidence
with production authorization set to false.
