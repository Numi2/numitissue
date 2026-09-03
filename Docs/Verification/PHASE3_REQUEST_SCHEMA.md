# Phase 3 request and evidence schema

The controlled runner emits schema version `1` records with the following
shape. Fields not listed here are not authority-bearing and must not be used
to bypass a failed check.

```json
{
  "schemaVersion": 1,
  "kind": "numitissue.phase3.validation-run",
  "executionPurpose": "qualification",
  "qualificationStatus": "hardware-smoke-only",
  "productionAuthorized": false,
  "promotionCertificate": null,
  "repository": {
    "revision": "full git commit SHA",
    "originMain": "matching fetched origin/main SHA",
    "matchesOriginMain": true,
    "workingTreeClean": true
  },
  "preflight": {
    "sourceAudit": {"path": "source-audit.json", "passing": true},
    "appleSiliconDoctor": {"path": "doctor.json", "passing": true}
  },
  "commands": [],
  "artifacts": [],
  "evidenceGraph": {
    "nodes": [],
    "edges": [],
    "missingForProduction": []
  }
}
```

## Required rules

* `schemaVersion`, `kind`, and `executionPurpose` are exact values.
* `productionAuthorized` is the literal JSON boolean `false` for a runner
  record, and `promotionCertificate` is JSON `null`.
* Repository identity uses a full commit SHA and records whether it matches
  the fetched `origin/main`.
* Every artifact path is relative, uses `/`, contains no `.` or `..`
  component, does not traverse a symlink, and has a byte count and SHA-256
  digest matching the file on disk.
* The artifact inventory is complete. Unrecorded files and duplicate paths
  invalidate the manifest.
* Every command has an ID, argv, exit code, success value, required flag, and
  an artifact-backed log. `requiredCommandFailures` must equal the command
  records, in order.
* The evidence graph must contain the workload, device, execution
  configuration, pipeline archive, qualification evidence, qualification
  bundle, promotion report, promotion certificate, execution identity,
  checkpoint, and production backend nodes. Missing nodes must be declared;
  graph cycles and self-edges are invalid.

The schema is an integrity and evidence-record format. It is not a signature
format and cannot be used to issue a production certificate.
