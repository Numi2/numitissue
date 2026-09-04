# Phase 6: bounded neural-culture digital twin

## Status

Phase 6 is **source-complete and scientifically unqualified**.

The source now contains the bounded neural-culture digital-twin architecture from the roadmap: solver-state current extraction, extracellular observation, acquisition electronics, spontaneous and evoked feature extraction, calibration, longitudinal assimilation, frozen held-out forecasts, leakage-safe baselines, grouped donor/batch evaluation, CPU/Metal observation-equivalence evidence, a checksum-gated public organoid corpus target, and a fail-closed file-backed qualification gate.

Source completion is not the biological exit gate. No Phase 6 qualification certificate is valid until the exact external data, inference outputs, Apple GPU comparisons and held-out results have been materialized and verified.

No build, Swift test, Metal compilation, GPU execution, DANDI materialization, PyNWB extraction or biological experiment was executed while authoring this source increment.

## Authoritative flow

```text
NumiTissue runtime state
  -> discrete compartment charge balance
  -> total outward transmembrane current
  -> point / line source geometry
  -> finite-contact extracellular lead field
  -> acquisition electronics + artifact model
  -> explicit valid-sample mask
  -> spontaneous + evoked neural features
  -> calibration / sequential assimilation
  -> immutable culture checkpoint
  -> frozen posterior forecast
  -> preregistered baseline comparison
  -> donor / batch / independent-culture evaluation
  -> predictive interval calibration
  -> CPU / Metal observation equivalence
  -> file-backed Phase 6 qualification
```

## Runtime current authority

`CultureRuntimeCurrentExtractor` derives net outward transmembrane current directly from `TissueRuntimeState` using compartment charge balance:

```text
I_mem,out = I_injected + I_axial,in - C dV/dt
```

The runtime convention is explicit. Axial and injected current are positive into a compartment; the observation source current is positive outward into extracellular space. The calculation uses the parent/child tree and child-owned axial conductance. Units are converted from nF, mV, ms and nA to amperes.

Synaptic current is not independently added to the observation source because it is a membrane current represented through the compartment voltage/current balance. Adding it again would double count it. Any future solver that changes this state contract must change the current-extraction contract and its validation cases together.

`CultureRuntimeSourceMap` binds each compartment to immutable point/line geometry derived from the neurite topology. Topology revision changes invalidate the cached source map and lead field.

## Production simulation provider

`CultureProductionSimulationProvider` is the production observation pipeline. A backend implements `CultureProductionRuntimeDriver` so it can preserve the backend-specific state that is not exposed as ordinary biological arrays, including delayed events, random streams and scheduler state.

The driver returns bounded electrical observation frames and a complete opaque continuation. The provider then:

1. verifies the topology revision;
2. reconstructs total transmembrane currents;
3. applies the finite-contact lead field;
4. applies the pinned measurement model;
5. preserves the sample-validity mask;
6. returns the recording plus complete continuation state.

The provider does not permit held-out measured outcomes to enter the simulator callback. Backends are responsible for sampling at their electrical cadence; the host does not infer high-rate signals from sparse transaction snapshots.

## Extracellular forward model

`CultureLeadField` is a deterministic FP64 observation reference. It supports:

- point sources;
- uniform line sources;
- finite disk contacts;
- square and rectangular contacts;
- remote reference;
- explicit reference electrode;
- fixed common-average reference;
- homogeneous conductivity;
- an optional perfectly insulating planar substrate through an image source.

Geometry is expressed in micrometers and converted to meters. Currents are amperes. Lead-field coefficients are ohms and outputs are volts.

The near-source radius is a declared regularization. The insulating-plane implementation is not a full saline/tissue/glass boundary solver. A multilayer or anisotropic conductor must enter as a separately validated observation model rather than silently changing this one.

## Electrode and amplifier model

`CultureMeasurementModel` keeps acquisition physics outside the biological state. Per-electrode interfaces contain series resistance, double-layer capacitance, charge-transfer resistance, amplifier input properties, gain, offset and saturation limits.

`CultureMeasurementProcessor` applies deterministic first-order electrode/acquisition filtering, common-mode subtraction, stimulation-artifact transients, blanking, gain and saturation. Its SHA-256 identity is part of the observation contract.

This is a bounded equivalent-circuit model. It is not claimed to reproduce a particular commercial MEA system until its parameters are fitted to that system and validated against phantom or saline recordings.

## Neural features

The spontaneous feature path provides masked spike detection, firing and burst rates, interspike-interval statistics, active-electrode fraction, observable-electrode fraction and population coactivity.

The evoked path adds:

- per-electrode response amplitude;
- per-electrode response latency;
- responsive-electrode fraction;
- propagation-time span;
- declared spectral-band power.

Masked or blanked samples are excluded. Missing data are reported as unavailable rather than converted to zero neural activity.

The direct DFT used by the correctness path is intentionally simple. A faster FFT implementation may replace it only after an equivalence case demonstrates the same declared features.

## Calibration and longitudinal assimilation

`CultureCalibrationEvaluator` reuses the existing NumiTissue calibration machinery using fixed feature scales. A candidate cannot improve its objective by merely inflating its own reported uncertainty.

`CultureLongitudinalTwin` wraps the sequential ensemble assimilator transactionally. It stages each assimilation in a fresh assimilator and adopts the checkpoint only after acceptance and cancellation checks. Failed or rejected updates leave the committed checkpoint unchanged.

Only calibration sessions may mutate the twin. Validation and all holdout partitions remain observational.

## Held-out design

`CultureStudyDesign` separates:

- calibration;
- validation;
- later temporal holdout;
- unseen waveform holdout;
- unseen stimulation-electrode holdout;
- independent-culture holdout.

Independent-culture holdouts may not share culture, donor or batch with fitting/validation data. Same-culture temporal holdouts must occur strictly after fitting.

`CultureHeldOutForecaster` freezes posterior parameters. Same-culture forecasts continue the committed simulator state. Independent-culture forecasts transfer only the parameter posterior and require a separate initial simulator state.

## Baselines and grouped evaluation

`CultureBaselineForecaster` supplies reproducible baselines without accessing held-out or future observations:

- persistence;
- historical mean;
- stimulus-matched historical mean;
- same-culture linear trend.

Independent-culture baselines reject training observations sharing the held-out culture, donor or batch.

`CultureHierarchicalEvaluator` scores held-out sessions with fixed feature scales and reports results by culture, donor and batch. Required baselines must be present for every evaluated session. Phase 6 cannot pass if the candidate misses the preregistered relative-improvement threshold for any required comparison.

This grouped evaluator is not itself a hierarchical Bayesian random-effects model. Donor/batch uncertainty can be fitted by the Phase 5 inference layer; the Phase 6 gate requires that biological grouping remain explicit and that independent evidence not be collapsed into pseudo-replicates.

## Apple GPU observation path

`MetalCultureLeadField` performs the bounded `scientific32` current-to-electrode projection while keeping current and voltage buffers GPU-resident. It does not submit command buffers, block the host or grant `performance32` authority.

`CultureObservationEquivalence` compares Metal results against the FP64 observation reference with explicit absolute and relative voltage tolerances. Device identity, lead-field identity and current-vector identity are part of the report.

The Phase 6 certificate requires a passing CPU/Metal observation report and the same scientific conclusion from the CPU and Metal evaluation paths.

## Public organoid-data target

`NumiTissuePhase6CultureCorpus` connects Phase 6 to DANDI dandiset `001268`, associated with the published feedback-driven brain-organoid platform study (`10.1016/j.iot.2025.101671`).

The repository deliberately does not hardcode an unverified mutable asset. To create a publishable corpus entry, the caller must provide:

- an exact published DANDI version;
- an exact NWB asset path;
- a resolved license;
- the byte count;
- the SHA-256 digest.

`draft` and `latest` are rejected. The resulting entry uses the existing Phase 4 PyNWB sidecar and scientific-corpus contracts. It remains a candidate until the exact bytes have been materialized and terminal evidence generated.

## Qualification

`CultureTwinQualificationEvidence` requires all of the following:

- Phase 4 corpus evidence;
- Phase 5 inference evidence;
- synthetic parameter recovery with identifiable parameters;
- calibrated predictive intervals;
- required-baseline outperformance;
- held-out waveform evidence;
- held-out electrode evidence;
- independent-culture evidence;
- independent-donor evidence;
- CPU/Metal observation equivalence;
- reproducible scientific conclusions across CPU and Metal.

Digest-only certification is disabled. `CultureTwinQualifier.qualify` intentionally refuses to issue a certificate.

Production certification requires:

```text
CultureQualificationAuthorityManifest
    -> secure path resolution
    -> no symlink traversal
    -> bounded file hashing
    -> exact byte count
    -> exact SHA-256
    -> complete required-role coverage
    -> CultureQualificationAuthorityVerification
    -> CultureTwinQualifier.qualifyVerified
```

The certificate binds both the qualification evidence and the file-backed authority manifest.

## CLI

```text
numitissue phase6 status
numitissue phase6 demo-recording
numitissue phase6 demo-config
numitissue phase6 features <recording.json> <configuration.json>
numitissue phase6 evoked <recording.json> <stimulus.json> <configuration.json>
numitissue phase6 lead-field <geometry-request.json>
numitissue phase6 study-validate <study.json>
numitissue phase6 score <score-request.json>
numitissue phase6 baseline <baseline-request.json>
numitissue phase6 hierarchical-score <request.json>
numitissue phase6 qualify <qualification-evidence.json> <authority-manifest.json> <artifact-root>
```

The qualification command re-hashes authority files before issuing a certificate. No Phase 6 CLI command controls wetware or grants Metal `performance32` authorization.

## Source audit

`Tools/phase6/source_audit.py` checks that the required Phase 6 source authorities exist, that the DANDI target rejects mutable aliases, that the digest-only qualifier remains fail-closed and that no unresolved Phase 6 conflict/TODO markers remain.

Run on the target development machine together with the repository build and validation suite:

```bash
python3 Tools/phase6/source_audit.py
swift build
swift test --filter Culture
swift run numitissue phase6 status
```

On Apple Silicon, also run the Phase 3 qualification path and produce the Phase 6 CPU/Metal observation-equivalence evidence.

## Exit gate

Phase 6 is scientifically complete only when a `CultureTwinQualificationCertificate` is produced from real materialized evidence and independently reproducible held-out results.

Until then the correct repository state is:

```text
SOURCE COMPLETE
SCIENTIFICALLY UNQUALIFIED
```

The source tree alone must never be cited as evidence that NumiTissue predicts living neural tissue.
