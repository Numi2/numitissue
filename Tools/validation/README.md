# External scientific references

NumiTissue does not use its own production backend as the only definition of correctness.

This directory pins the external tools used by the Phase 1 validation corpus:

- NEURON for detailed compartmental electrophysiology;
- Arbor and the Arbor NSuite for independent cable and synapse validation;
- STEPS and its validation repository for spatial stochastic chemistry;
- eFEL for standardized electrophysiology features.

`reference-lock.json` is the authority for package versions and exact validation-repository revisions. Updating it is a scientific change and requires regenerated artifacts and a tolerance review.

## Create the reference environment

```bash
python3.13 -m venv .venv-reference
source .venv-reference/bin/activate
python -m pip install --upgrade pip
python -m pip install -r Tools/validation/requirements-reference.txt
python Tools/validation/prepare_sources.py
python Tools/validation/doctor.py
```

The doctor exits with status 2 if a package version, repository revision, or Python version is not exact.

## Generate Rallpack 1 with NEURON

```bash
python Tools/validation/run_neuron_rallpack1.py \
  --model ValidationCases/Cases/electrophysiology/rallpack1/model.json \
  --input ValidationCases/Cases/electrophysiology/rallpack1/input.json \
  --output-csv ValidationCases/Cases/electrophysiology/rallpack1/reference/neuron.csv \
  --output-provenance ValidationCases/Cases/electrophysiology/rallpack1/reference/neuron.provenance.json
```

## Extract standardized electrophysiology features

```bash
python Tools/validation/extract_efel.py \
  --input-csv ValidationCases/Cases/electrophysiology/rallpack1/reference/neuron.csv \
  --voltage-column v0_mV \
  --stim-start-ms 0 \
  --stim-end-ms 250 \
  --output-json ValidationCases/Cases/electrophysiology/rallpack1/reference/neuron.efel.json
```

Generated outputs are not accepted solely because the scripts complete. They must be compared using the case manifest, and simulator and feature-extractor provenance must accompany every trace.
