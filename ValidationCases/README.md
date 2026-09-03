# NumiTissue scientific validation corpus

This directory is the executable Phase 1 validation corpus.

Each case is self-contained under `Cases/<domain>/<case>/` and contains:

- `case.json`: versioned manifest and acceptance criteria;
- `model.json`: the bounded model configuration when a model is required;
- `input.json`: the protocol or deterministic input;
- `expected.json`: analytical or invariant reference metadata;
- generated simulator traces are added under `reference/` by the external tools in `Tools/validation`.

The tolerance is part of the case manifest. Production code must not silently widen it.

The Swift test target validates every manifest, resource path, canonical digest, analytical operator, and transaction invariant. Cross-simulator artifacts are generated separately so NEURON, Arbor, STEPS, and eFEL versions can be recorded explicitly.
