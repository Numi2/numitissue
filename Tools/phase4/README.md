# Phase 4 sidecar protocol

The Phase 4 sidecars connect NumiTissue to established Python scientific
software without moving Python into the simulation runtime.

## Security and reproducibility contract

Every sidecar invocation requires:

- a schema-versioned JSON request;
- an exact sidecar implementation version;
- exact dependency versions;
- bounded record, sample and output sizes;
- safe paths relative to explicit input and output roots;
- SHA-256 and optional byte count for every input;
- an allowlisted operation;
- atomic output creation;
- a response bound to the request SHA-256.

The shared runtime rejects path traversal, symlink escape, unbounded
selections, mismatched packages, modified inputs, duplicate identifiers,
non-finite output metrics and existing output destinations.

No sidecar accepts a shell command, arbitrary Python source, module name from
the request or dynamic plugin path.

## Environments

Create one environment per sidecar. Do not install all scientific stacks into
one shared interpreter.

```bash
python3.12 -m venv .venv-nwb
.venv-nwb/bin/python -m pip install ./Tools/numitissue-nwb

python3.12 -m venv .venv-efel
.venv-efel/bin/python -m pip install ./Tools/numitissue-efel

python3.12 -m venv .venv-jaxley
.venv-jaxley/bin/python -m pip install ./Tools/numitissue-jaxley

python3.12 -m venv .venv-reference
.venv-reference/bin/python -m pip install ./Tools/numitissue-reference
```

The package pins are part of the Swift-side toolchain identity. Updating a
pin requires updating the protocol, conformance matrix, example requests and
validation evidence together.

## Common invocation

```bash
python path/to/sidecar.py request.json \
  --input-root path/to/inputs \
  --output-root path/to/new-output-directory \
  --response path/to/new-output-directory/response.json
```

The response must then be verified by the Swift authority:

```bash
swift run numitissue phase4 sidecar verify-response \
  request.json path/to/new-output-directory/response.json
```

## Sidecars

| Sidecar | Exact packages | Allowed operations |
|---|---|---|
| `numitissue-nwb` | `pynwb==4.1.0` | `inspect`, `validate`, `extract` |
| `numitissue-efel` | `efel==5.7.34` | `validate`, `featureExtract` |
| `numitissue-jaxley` | `jaxley==0.13.0`, `jax==0.11.1`, `jaxlib==0.11.1` | `validate`, `simulate`, `fit` |
| `numitissue-reference` | `h5py==3.16.0` | `validate`, `simulate`, `compare` through fixed engines |

The Jaxley path is intentionally CPU-only. The reference sidecar exposes only
fixed engine identities. External simulators such as NEURON, Arbor, STEPS and
LFPy require their own pinned campaign adapters; they are not invoked through
arbitrary commands here.

## Output ownership

Sidecars create new files only. Reusing an existing output directory or
response path is an error. This prevents a run from silently replacing the
artifacts of an earlier run.

The response lists every produced artifact with its relative path, media type,
byte count and SHA-256. Additional files that are not listed are not part of
the scientific result.
