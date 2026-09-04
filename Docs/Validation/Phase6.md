# Phase 6: neural-culture digital twin

## Status and scope

This increment is **partial implementation, uncompiled and scientifically unqualified**. It begins the Phase 6 neural-culture twin from the original roadmap. It does not certify completion of the roadmap's held-out biological prediction exit gate.

The starting repository revision was `d76f1c8237506aeb06b62496658784d04fd5ec34`. Implementation extends the actual `MEA.swift`, `DigitalTwinCalibration.swift`, `SequentialDigitalTwinAssimilation.swift`, and main CLI interfaces. It does not assume that earlier prose descriptions of nonexistent or unverified tools establish a working dependency.

No builds, Swift tests, shader compilation, scientific experiments, sidecar environments, or benchmarks were executed during this increment. Tests are committed source for the user to execute.

## Implemented path

```
total transmembrane currents
  -> finite-contact extracellular lead field
  -> recorded SI voltages with explicit masks
  -> frozen feature extraction
  -> existing calibration / ensemble assimilation
  -> immutable per-culture checkpoint
  -> forecasts without held-out outcomes
  -> per-feature error and predictive interval scores
```

The first intended preparation remains a dissociated organoid-derived neural culture on a planar MEA. No calibrated biological preparation is bundled yet.

## Source map

| Path | Responsibility |
| --- | --- |
| `Sources/NumiTissueIntegration/CultureTwin/CultureLeadField.swift` | Point/line-source forward model, finite contacts, referencing, geometry identity |
| `CultureRecording.swift` in the same directory | Uniform SI voltage records, explicit validity masks, existing MEA-frame and NWB-scale conversion |
| `CultureFeatureExtractor.swift` | Negative peak detection, MAD noise, firing/burst rates, ISI variation and coactivity |
| `CultureCalibrationAdapter.swift` | Recording-producing provider adapter for the existing calibrator |
| `CultureStudyDesign.swift` | Feature/noise contracts, chronological and grouped holdout constraints |
| `CultureLongitudinalTwin.swift` | Staged per-culture assimilation, no-outcome forecast callback, checkpoints |
| `CultureHeldOutForecast.swift` | Bounded-concurrent frozen-posterior forecasts, independent external-culture initial state |
| `CulturePredictiveScoring.swift` | Empirical-distribution CRPS and predictive intervals in declared feature units |
| `Sources/NumiTissueMetal/MetalCultureLeadField.swift` | Bounded scientific32 projection into a caller-owned command buffer |
| `Sources/NumiTissueMetal/Shaders/CultureLeadField.metal` | Source-major coefficient loads, fixed-order per-output accumulation |
| `Sources/NumiTissue/CultureMetalBridge.swift` | CPU geometry to GPU observation-operator bridge |
| `Sources/NumiTissueCLI/Phase6Command.swift` | JSON inspection, synthetic signal demo, feature extraction and scoring |

## Electrical observation model

`CultureCurrentSource` requires total outward transmembrane current in amperes. Include capacitive and ionic/synaptic membrane contributions with the simulator's declared sign convention. Membrane voltage, injected current, and current density are different quantities and cannot be substituted.

Geometry is in micrometers and is converted to meters in the forward calculation. Conductivity is S/m. Coefficients are ohms; multiplying by amperes produces volts.

The homogeneous point-source coefficient is `1/(4*pi*sigma*r)`. The uniform-line source integrates this Green function along the segment. Distances are regularized at the source radius. This is an explicit near-source approximation, not a resolved membrane/electrolyte boundary solution. At large relative distance, the line expression uses a midpoint approximation to avoid subtractive cancellation.

Disk contacts use deterministic equal-area quadrature. Square/rectangular contacts use a midpoint grid and require a square-number quadrature count. One point explicitly selects the midpoint approximation. Spherical contacts are rejected. The optional insulating plane uses a same-sign image source; it is not a full tissue/saline/glass three-layer solution. Sources and all quadrature points must be on or above the declared substrate.

Reference subtraction is compiled into the lead field. A reference electrode must exist and be enabled. Common-average membership is explicit and fixed. Geometry/topology changes require a new operator and identity.

## Apple GPU path

The observation matrix is transposed once into source-major FP32 coefficients so adjacent electrode lanes load adjacent coefficients. Current frames and voltages stay in caller-owned Metal buffers. The operator queries pipeline thread width; it does not hardcode an undocumented physical GPU tile or warp size.

The encoder does not submit, block, read back, or mutate the tissue state. It requires tracked non-aliasing resources and retained-reference command buffers. Callers own inter-queue synchronization and must inspect output status after completion. Nonfinite input/output is flagged rather than accepted as valid observation data.

This is a separate observational kernel using the established Metal compute API, not integration into the Metal 4 transaction scheduler. It does not issue or bypass performance32 authorization. FP64 CPU lead-field results are an observation reference only; the tissue integrator is not renamed Reference64.

## Features and observation uncertainty

Recordings are uniform, time-major volts. NWB-style conversion is `stored * conversion * channelConversion + offset`. Arbitrary irregular NWB time series require explicit preprocessing; the Swift conversion routine does not resample or open HDF5.

Blanking windows and incoming sample masks determine valid exposure. Detection uses negative local peaks with a configurable MAD threshold and refractory interval. ISIs and bursts crossing masked gaps are excluded. Missing/insufficient data are reported, not presented as zero biological activity. Active-electrode fraction is over observable electrodes, with observable fraction reported separately. Population coactivity requires fully observed complete bins across the configured array.

Burst/coactivity definitions are explicit analysis choices, not claims of universal neuroscience definitions. Filtering, stimulation-artifact removal and impedance calibration must be part of an externally pinned `measurementModelID`.

`CultureFeatureContract` keeps measurement, electrode and model-discrepancy standard deviations separate, combining their variances only at the current diagonal observation-covariance boundary. These terms are declared inputs, not automatically inferred biological constants. Full correlated observation covariance and hierarchical donor/batch random effects remain future work.

## Calibration and held-out operation

`CultureCalibrationEvaluator` feeds simulated recording features into the existing `DigitalTwinCalibrator`. Its provider must create an independent candidate simulation. Fixed per-feature scales prevent the provider from lowering the existing objective merely by increasing reported prediction uncertainty.

`CultureLongitudinalTwin` reuses `SequentialTissueTwinAssimilator` in a staged wrapper. Failed, rejected or cancelled updates leave the wrapper's committed checkpoint unchanged. The forward provider receives only identity, stimulus/time schedule and required feature names, never measured values or covariance. It must have no external side effects. This API separation cannot prevent a malicious provider from reading unrelated files; it is not a process sandbox.

Only calibration sessions may update state. Validation is separate from calibration. Temporal holdouts occur strictly after same-culture fitting. Held-out waveforms and electrodes cannot overlap fitting/validation exposure. Independent-culture holdouts cannot share a culture, donor or batch with fitting/validation. Missing holdout categories are reported; a valid study schema is not a complete scientific study.

Forecasts require a complete scheduled calibration checkpoint. Same-culture forecasts continue the corresponding opaque simulator state without updating parameters. External-culture prediction transfers parameters but requires a different, explicitly supplied initial simulator state. The transfer is not evidence that the new culture has been individually calibrated.

## Scoring

For equally weighted samples `x_i`, the scorer evaluates the exact empirical-distribution CRPS:

`mean(abs(x_i - y)) - 0.5 * mean(abs(x_i - x_j))`.

The sorted implementation is O(N log N). Scores are normalized only by predeclared feature scales. Median absolute error and 50/80/90/95 percent predictive intervals are also reported. Measurement noise must be included by the prediction-generating model when needed; scoring does not silently add it again.

A single session's interval coverage is descriptive. It does not establish calibrated uncertainty, independent replication, posterior identifiability or outperformance over baselines. This increment does not issue a biological-validation certificate from these scores.

## Remaining Phase 6 work

1. Concrete production `CultureSimulationProvider` wiring: solver transmembrane-current extraction, complete checkpoint continuation, virtual electrode filtering, and source/topology mappings.
2. Frequency-dependent electrode impedance, amplifier/reference circuitry, stimulation artifacts, and a validated multilayer conductor.
3. Evoked-response features, propagation, spectral metrics and quality-control comparisons against public recordings.
4. Hierarchical donor/batch inference, structural discrepancy fitting, baseline forecasts and grouped uncertainty for held-out comparisons.
5. A pinned neural-culture dataset processed through the Phase 4 NWB workflow, synthetic parameter-recovery experiments, and independent held-out stimulation/culture results.
6. Actual Swift compilation, CPU/Metal observation comparisons, failure/cancellation tests and Apple Silicon profiling.

Do not mark the original Phase 6 exit gate passed until the bounded twin predicts held-out biological responses with calibrated uncertainty and independently reproduced evidence.

## Primary references

- LFPykit forward-model documentation: https://lfpykit.readthedocs.io/en/latest/
- LFPykit line-source equation and current/voltage units: https://lfpykit.readthedocs.io/en/v0.5.1/
- NWB ElectricalSeries conversion and timing: https://matnwb.readthedocs.io/en/latest/pages/neurodata_types/core/ElectricalSeries.html
- Apple compute encoder contract: https://developer.apple.com/documentation/metal/mtlcomputecommandencoder/
- Apple nonuniform-grid dispatch requirements: https://developer.apple.com/documentation/metal/mtlcomputecommandencoder/dispatchthreads(_:threadsperthreadgroup:)
- Bracher et al., probabilistic interval forecast evaluation: https://arxiv.org/abs/2005.12881

References guide methods and interoperability; no equivalence to their implementations is claimed without executed comparisons.
