# Phase 6: recording analysis and frozen-posterior forecasts

These commands are intended for your Apple Silicon checkout. They were not run during this implementation. The demo is a synthetic two-electrode signal, not a simulated organoid, biological dataset or scientific validation.

```bash
swift run numitissue phase6 status
mkdir -p Phase6Artifacts
swift run numitissue phase6 demo-recording > Phase6Artifacts/recording.json
swift run numitissue phase6 demo-config > Phase6Artifacts/features-config.json
swift run numitissue phase6 features Phase6Artifacts/recording.json Phase6Artifacts/features-config.json > Phase6Artifacts/features.json
```

The output includes detected negative peaks, per-electrode firing/burst rates, valid-sample fractions, MAD noise estimates, interspike-interval variation where estimable, population coactivity and missing-feature reasons. The detector does not silently filter raw recordings. Preprocessing must be represented by `measurementModelID`.

## Swift integration

```swift
import NumiTissue

let source = CultureCurrentSource(
    id: 1, geometry: .uniformLine,
    startMicrometers: SIMD3(-50, 0, 10),
    endMicrometers: SIMD3(50, 0, 10), radiusMicrometers: 1
)
let electrode = MEAElectrode(
    id: ElectrodeID(rawValue: 1), positionMicrometers: SIMD3(0, 100, 0)
)
let leadField = try CultureLeadFieldBuilder.build(
    sources: [source], electrodes: [electrode],
    conductor: CultureConductor(insulatingPlaneZMicrometers: 0)
)
let volts = try leadField.voltages(totalOutwardCurrentsAmperes: [1e-9])
```

The electrical input is a total outward **transmembrane current**, including capacitive and ionic/synaptic contributions under the solver's sign convention. Do not substitute membrane voltage, injected electrode current, or current density.

For Apple GPU projection, use `leadField.makeMetalObservationOperator(device:)`. Prepare Float buffers for `[frame,source]` amperes, `[frame,electrode]` volts and UInt32 status flags. Call `encode` with the exact source order and geometry identity. The caller owns synchronization, command submission, completion, status inspection and resource lifetime. There is no automatic CPU fallback or performance32 promotion.

## Longitudinal assimilation

1. Create a `CultureStudyDesign` with calibration and validation sessions plus temporal, waveform, electrode and independent-culture holdouts. Keep donor and batch identifiers stable.
2. Construct `CultureLongitudinalTwin` for one culture. Supply a `CultureSimulationProvider` that creates isolated simulations from the member state and uses the requested stimulus schedule.
3. Extract measured features with the same frozen configuration and measurement model used for predictions. Assimilate only calibration sessions in scheduled order.
4. Save `await twin.checkpoint()`. The checkpoint binds the study, model, culture, ensemble and accepted session sequence.
5. Call `CultureHeldOutForecaster.forecast` without passing measured outcomes. The forecaster discards new simulator states and never updates the posterior. External cultures require their own initial simulator state.
6. Score after forecast generation with `CulturePredictiveScorer.score`, supplying independently expected model and posterior digests.

A complete runnable biological twin still needs a validated tissue model and a concrete recording-producing simulator provider. This example does not replace them with generated fake measurements. See `Docs/Validation/Phase6.md` for the remaining work.
