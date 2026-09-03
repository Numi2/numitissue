# Phase 4 — Standards and pinned scientific corpus

Phase 4 establishes the boundary between NumiTissue and external scientific
models, datasets, feature extractors and reference simulators.

It does not claim that every supported file is biologically correct or that
NumiTissue reproduces every source simulator. It defines how such claims must
be represented, pinned, executed and verified.

## Objective

A NumiTissue result should be reconstructable from:

```text
standard version
+ exact source release or commit
+ bounded source selection
+ exact materialized bytes
+ decoder identity
+ declared transformations and exclusions
+ unit contract
+ feature contract
+ tolerance contract
+ executable evidence
```

Phase 4 makes that chain a first-class artifact.

## Standards boundary

`NumiTissueStandardConformance.phase4Baseline` is the authoritative feature
matrix for:

- SWC
- NeuroML 2
- LEMS
- SONATA
- SBML
- restricted NMODL
- NWB

Every feature has one of four dispositions:

| Disposition | Meaning |
|---|---|
| `supported` | The declared construct has a concrete native or pinned-sidecar implementation path. |
| `loweredWithDeclaredApproximation` | The construct executes only after an explicit, recorded approximation. |
| `preservedNotExecutable` | The construct is parsed and retained but does not affect authoritative execution. |
| `rejected` | The construct is not accepted for execution. |

This distinction is important. Parsing a value is not the same as applying it
to a simulation. For example, the current NeuroML path preserves specific
capacitance, resistivity and channel-density declarations, but the general
morphology lowering path does not yet install those declarations into all
runtime mechanism tables. The matrix records that boundary directly.

The matrix is canonical JSON and has a SHA-256 identity. A corpus manifest is
bound to the exact matrix it was prepared against.

## Scientific corpus

`ScientificCorpusManifest` records immutable evidence inputs. Its entries pin:

- dataset source, identifier and release;
- source stability and license;
- canonical bounded selection;
- upstream commit or tag when applicable;
- every materialized asset and dependency;
- media type, encoding and compression;
- decoder and sidecar toolchain;
- SHA-256 and byte count;
- transformation order;
- exclusions and their rationale;
- source-to-canonical unit conversion;
- scientific features and extractor versions;
- numerical and statistical tolerances;
- executable evidence case identifiers.

Three validation policies are available:

### `development`

Allows incomplete source candidates. Use this while selecting public data or
constructing a new case. It does not establish publishable evidence.

### `publishable`

Requires immutable and bounded sources, resolved licenses, SHA-256 for every
asset and executable evidence identifiers.

### `materialized`

Adds concrete byte counts and rejects entries that have not reached a
materialized or verified state.

A candidate catalog intentionally fails `publishable` validation until those
requirements are satisfied. This prevents a URL or dataset title from being
mistaken for a reproducible scientific input.

## Byte verification

`ScientificCorpusVerifier` resolves each asset beneath a declared root and
then verifies:

- safe relative path;
- symlink containment;
- regular-file existence;
- configured per-file and total byte limits;
- byte count;
- streaming SHA-256.

`ScientificCorpusSealer` can add identities to local files, but it refuses to
replace an existing SHA-256 or byte-count pin when the materialized bytes
differ.

The repository includes a small CC0 synthetic conformance corpus under:

```text
ValidationCases/Cases/Phase4
```

It covers SWC, NeuroML, LEMS, SBML, restricted NMODL and SONATA configuration
and type tables. These are interoperability fixtures, not biological data.

## Scientific sidecars

Some scientific formats and fitting systems already have mature Python
implementations. Phase 4 keeps those ecosystems outside the Swift simulation
runtime and connects them through a bounded request/response protocol.

The protocol binds:

- request schema and operation;
- exact implementation and package versions;
- input path, byte count and SHA-256;
- selection bounds;
- random seed when applicable;
- output artifact paths, byte counts and SHA-256;
- diagnostics and finite metrics;
- request SHA-256 in the response.

Sidecars do not receive arbitrary shell commands or Python source.

### `numitissue-nwb`

Pinned to PyNWB 4.1.0 and NWB 2.10.0. It supports:

- cached-namespace schema validation;
- session and subject inspection;
- device, electrode, unit and interval extraction;
- bounded acquisition and stimulus time-series extraction;
- selected time windows and record/sample limits.

It does not include an unbounded recursive object dump.

### `numitissue-efel`

Pinned to eFEL 5.7.34. It accepts canonical voltage traces with explicit time
and stimulus intervals, validates monotonicity and shape, and extracts an
explicit feature allowlist from the request.

### `numitissue-jaxley`

Pinned to Jaxley 0.13.0, JAX 0.11.1 and jaxlib 0.11.1. The Phase 4 path is
CPU-only and restricted to a bounded Hodgkin–Huxley single-cell model.
It supports deterministic trace generation and bounded gradient-based fitting
of an explicit parameter allowlist.

Jaxley is an inference helper. It does not become the NumiTissue runtime and it
does not replace the Apple Metal authority.

### `numitissue-reference`

Pinned to h5py 3.16.0. It exposes only fixed engines:

- analytic passive-RC simulation;
- canonical trace comparison;
- bounded SONATA HDF5 inspection and materialization.

It does not execute arbitrary external simulators. NEURON, CoreNEURON, Arbor,
STEPS and LFPy evidence must be produced by separately pinned adapters or
campaign environments and returned as hashed artifacts.

## CLI

Inspect the Phase 4 boundary:

```bash
swift run numitissue phase4 status
swift run numitissue phase4 conformance
swift run numitissue phase4 conformance neuroml
swift run numitissue phase4 sidecar pins
```

Export and validate the built-in corpus:

```bash
swift run numitissue phase4 corpus built-in phase4-corpus.json
swift run numitissue phase4 corpus validate \
  phase4-corpus.json materialized
swift run numitissue phase4 corpus verify \
  phase4-corpus.json . phase4-verification.json
```

Hash any materialized input with the same streaming implementation used by the
corpus verifier:

```bash
swift run numitissue phase4 file sha256 path/to/artifact
```

Inspect sidecar identity before execution and verify the returned response:

```bash
swift run numitissue phase4 sidecar request-digest request.json
swift run numitissue phase4 sidecar verify-response \
  request.json output/response.json
```

The CLI never installs Python environments or launches sidecars implicitly.
Environment creation and execution remain explicit operations.

## Sidecar execution

Each sidecar is installed in an isolated environment. Example for the
reference sidecar:

```bash
python3.12 -m venv .venv-reference
source .venv-reference/bin/activate
python -m pip install --require-virtualenv \
  ./Tools/numitissue-reference
python Tools/numitissue-reference/numitissue_reference.py \
  Examples/Phase4/reference/request.json \
  --input-root Examples/Phase4/reference \
  --output-root Phase4Artifacts/reference \
  --response Phase4Artifacts/reference/response.json
swift run numitissue phase4 sidecar verify-response \
  Examples/Phase4/reference/request.json \
  Phase4Artifacts/reference/response.json
```

Equivalent requests are provided for eFEL and Jaxley under `Examples/Phase4`.
NWB execution requires an externally supplied `.nwb` file whose SHA-256 and
byte count are inserted into the request.

## Tests

The Phase 4 Swift tests cover:

- conformance-matrix completeness;
- canonical identity stability;
- known SHA-256 vectors;
- repository fixture bytes;
- SWC round trip;
- NeuroML preservation and morphology lowering;
- LEMS dynamics preservation;
- SBML core lowering;
- restricted NMODL bytecode compilation;
- SONATA manifest canonicalization and CSV types;
- publication gating;
- sidecar request/response substitution resistance;
- exact binding of example requests to their inputs.

Run:

```bash
swift test --filter Phase4
```

Run the source-only audits:

```bash
Tools/phase4/run_static_audits.sh
```

## Completion boundary

Phase 4 source completion means the contracts, sidecars, fixtures, CLI and
validation code exist. Phase 4 scientific completion additionally requires:

1. clean Swift and Python execution in pinned environments;
2. successful materialization of selected public sources;
3. license resolution for every published asset;
4. exact asset hashes and byte counts;
5. NWB ingest/export evidence where required;
6. external NEURON, Arbor, STEPS, LFPy and Jaxley evidence cases;
7. feature and tolerance contracts for each published case;
8. passing CPU/Metal comparison where the case reaches the runtime;
9. archived provenance for every result.

No source file, manifest or sidecar response alone establishes biological
validity.
