# Phase 4 examples

These examples exercise the pinned sidecar request protocol with bounded,
small inputs. They are development examples, not biological evidence.

## Validate request identities

```bash
swift run numitissue phase4 sidecar request-digest \
  Examples/Phase4/reference/request.json

swift run numitissue phase4 sidecar request-digest \
  Examples/Phase4/efel/request.json

swift run numitissue phase4 sidecar request-digest \
  Examples/Phase4/jaxley/request.json
```

Each request contains the exact SHA-256 and byte count of its input. Editing an
input without updating the request causes sidecar execution to reject it.

## Analytic passive membrane

```bash
python3.12 -m venv .venv-reference
.venv-reference/bin/python -m pip install ./Tools/numitissue-reference
.venv-reference/bin/python \
  Tools/numitissue-reference/numitissue_reference.py \
  Examples/Phase4/reference/request.json \
  --input-root Examples/Phase4/reference \
  --output-root Phase4Artifacts/reference \
  --response Phase4Artifacts/reference/response.json

swift run numitissue phase4 sidecar verify-response \
  Examples/Phase4/reference/request.json \
  Phase4Artifacts/reference/response.json
```

The fixed analytic engine integrates a passive RC membrane under a bounded
current step and emits voltage, current and time arrays.

## eFEL feature extraction

```bash
python3.12 -m venv .venv-efel
.venv-efel/bin/python -m pip install ./Tools/numitissue-efel
.venv-efel/bin/python Tools/numitissue-efel/numitissue_efel.py \
  Examples/Phase4/efel/request.json \
  --input-root Examples/Phase4/efel \
  --output-root Phase4Artifacts/efel \
  --response Phase4Artifacts/efel/response.json

swift run numitissue phase4 sidecar verify-response \
  Examples/Phase4/efel/request.json \
  Phase4Artifacts/efel/response.json
```

The trace is synthetic and deliberately small. It demonstrates canonical time,
voltage and stimulus arrays plus an explicit eFEL feature list.

## Jaxley HH simulation

```bash
python3.12 -m venv .venv-jaxley
.venv-jaxley/bin/python -m pip install ./Tools/numitissue-jaxley
.venv-jaxley/bin/python Tools/numitissue-jaxley/numitissue_jaxley.py \
  Examples/Phase4/jaxley/request.json \
  --input-root Examples/Phase4/jaxley \
  --output-root Phase4Artifacts/jaxley \
  --response Phase4Artifacts/jaxley/response.json

swift run numitissue phase4 sidecar verify-response \
  Examples/Phase4/jaxley/request.json \
  Phase4Artifacts/jaxley/response.json
```

This path uses the CPU backend explicitly. It is intended for differentiable
submodel work and does not replace NumiTissue's Apple Metal runtime.

## NWB

No binary NWB file is committed as an example. To use the NWB sidecar:

1. select an immutable published asset;
2. materialize it under an explicit input root;
3. compute its SHA-256 and byte count with `numitissue phase4 file sha256`;
4. create an NWB sidecar request containing those values;
5. select bounded object paths, time intervals and record/sample limits;
6. execute the sidecar in a PyNWB 4.1.0 environment;
7. verify the response through the Swift CLI.

This keeps the repository small and prevents a mutable URL from being treated
as a scientific input.
