# NumiTissue runnable workflows

The `numitissue-examples` executable writes canonical, validated input artifacts for the three production workflow families.

```bash
swift run numitissue-examples all .build/examples
```

Generated content:

- `screening/study.json` and `screening/campaign/`: a replicated, sharded hypoxia-resilience intervention screen.
- `organoid-fitting/study.json` and `organoid-fitting/campaign/`: a low-discrepancy initial design for fitting electrophysiology and network features.
- `wetware-optimization/study.json`, safety inputs, and `initial-plan.json`: a safety-filtered multi-objective closed-loop stimulation population.

Each campaign directory contains:

- `bundle.json`: the complete experiment/campaign object and its digest.
- `campaign.json`: the cryptographic distributed-work manifest.
- `experiment.json`: the reconstructed high-level experiment definition.
- `trials/<trial-id>.json`: an exact worker specification for every trial.

The same source files can be processed by the production CLI:

```bash
swift run numitissue screening compile \
  .build/examples/screening/study.json \
  .build/examples/screening/recompiled-campaign \
  --shards 3

swift run numitissue organoid compile \
  .build/examples/organoid-fitting/study.json \
  .build/examples/organoid-fitting/recompiled-campaign \
  --shards 4

swift run numitissue wetware plan \
  .build/examples/wetware-optimization/study.json \
  .build/examples/wetware-optimization/recompiled-plan.json

swift run numitissue wetware validate \
  .build/examples/wetware-optimization/baseline-protocol.json \
  .build/examples/wetware-optimization/safety-envelope.json \
  .build/examples/wetware-optimization/safety-report.json
```

The generators use fixed study IDs, trial derivation, base seeds, and campaign creation time. Output digests therefore remain reproducible when the source schema and canonical encoder are unchanged. The summary timestamp printed by the executable is informational and is not included in campaign or plan digests.
