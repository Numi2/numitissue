#!/usr/bin/env python3
"""Pinned eFEL sidecar for bounded electrophysiology feature extraction."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import Any

_PHASE4 = Path(__file__).resolve().parents[1] / "phase4"
if str(_PHASE4) not in sys.path:
    sys.path.insert(0, str(_PHASE4))

from sidecar_common import (  # noqa: E402
    LoadedRequest,
    SidecarFailure,
    VerifiedInput,
    finite_json,
    make_artifact,
    read_json,
    run_sidecar,
    write_json_atomic,
)

IMPLEMENTATION = "numitissue-efel"
IMPLEMENTATION_VERSION = "1"
EFEL_VERSION = "5.7.34"
ALLOWED_OPERATIONS = {"featureExtract", "validate"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", type=Path)
    parser.add_argument("--input-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--response", type=Path, required=True)
    arguments = parser.parse_args(argv)
    try:
        return run_sidecar(
            request_path=arguments.request,
            input_root=arguments.input_root,
            output_root=arguments.output_root,
            response_path=arguments.response,
            expected_sidecar="efel",
            allowed_operations=ALLOWED_OPERATIONS,
            implementation=IMPLEMENTATION,
            implementation_version=IMPLEMENTATION_VERSION,
            packages={"efel": EFEL_VERSION},
            handler=handle,
        )
    except SidecarFailure as error:
        print(f"{IMPLEMENTATION}: {error.code}: {error.message}", file=sys.stderr)
        return 2
    except Exception as error:
        print(f"{IMPLEMENTATION}: unexpected failure: {error}", file=sys.stderr)
        return 1


def handle(
    request: LoadedRequest,
    inputs: list[VerifiedInput],
    output_root: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, float], dict[str, str]]:
    if len(inputs) != 1:
        raise SidecarFailure("efel.input-count", "eFEL operations require one canonical trace file.")
    payload = read_json(inputs[0].path)
    traces = parse_traces(payload, request)
    features = list(request.value["selection"].get("featureNames", []))
    if not features:
        raise SidecarFailure("efel.features", "selection.featureNames must be nonempty.")

    operation = request.value["operation"]
    maximum_output = int(request.value["selection"]["maximumOutputBytes"])
    if operation == "validate":
        output_payload = {
            "schemaVersion": 1,
            "inputID": inputs[0].identifier,
            "inputSHA256": inputs[0].sha256,
            "traceCount": len(traces),
            "featureNames": features,
            "valid": True,
        }
        name = "efel-validation.json"
        role = "validation"
    else:
        import efel

        efel.reset()
        efel_traces = [
            {
                "T": trace["timeMilliseconds"],
                "V": trace["voltageMillivolts"],
                "stim_start": trace["stimulusStartMilliseconds"],
                "stim_end": trace["stimulusEndMilliseconds"],
            }
            for trace in traces
        ]
        try:
            values = efel.get_feature_values(
                efel_traces,
                features,
                raise_warnings=True,
            )
        finally:
            efel.reset()
        results = []
        for trace, feature_values in zip(traces, values, strict=True):
            normalized = {
                feature: normalize_feature(feature_values.get(feature))
                for feature in features
            }
            results.append({"traceID": trace["id"], "features": normalized})
        output_payload = {
            "schemaVersion": 1,
            "inputID": inputs[0].identifier,
            "inputSHA256": inputs[0].sha256,
            "featureExtractor": "eFEL",
            "featureExtractorVersion": EFEL_VERSION,
            "featureNames": features,
            "traceCount": len(results),
            "results": results,
        }
        name = "efel-features.json"
        role = "features"

    output = output_root / name
    write_json_atomic(output_payload, output, maximum_output)
    artifact = make_artifact(
        path=output,
        output_root=output_root,
        logical_name=output.stem,
        role=role,
        media_type="application/json",
        metadata={
            "extractor": "eFEL",
            "extractorVersion": EFEL_VERSION,
            "inputSHA256": inputs[0].sha256,
        },
    )
    return [artifact], [], {
        "traceCount": float(len(traces)),
        "featureCount": float(len(features)),
    }, {
        "inputSHA256": inputs[0].sha256,
        "featureExtractor": f"eFEL {EFEL_VERSION}",
    }


def parse_traces(payload: Any, request: LoadedRequest) -> list[dict[str, Any]]:
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise SidecarFailure("efel.schema", "Trace input must use schemaVersion 1.")
    source = payload.get("traces")
    if not isinstance(source, list) or not source:
        raise SidecarFailure("efel.traces", "Trace input requires a nonempty traces array.")
    selection = request.value["selection"]
    maximum_records = int(selection["maximumRecords"])
    maximum_samples = int(selection["maximumSamplesPerSeries"])
    if len(source) > maximum_records:
        raise SidecarFailure(
            "efel.trace-count",
            f"Trace count {len(source)} exceeds maximumRecords={maximum_records}.",
        )

    traces: list[dict[str, Any]] = []
    identifiers: set[str] = set()
    for ordinal, value in enumerate(source):
        if not isinstance(value, dict):
            raise SidecarFailure("efel.trace", f"Trace {ordinal} is not an object.")
        identifier = value.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in identifiers:
            raise SidecarFailure("efel.trace-id", f"Trace {ordinal} has an invalid or duplicate id.")
        identifiers.add(identifier)
        time = finite_array(value.get("timeMilliseconds"), f"{identifier}.timeMilliseconds")
        voltage = finite_array(value.get("voltageMillivolts"), f"{identifier}.voltageMillivolts")
        if len(time) != len(voltage) or len(time) < 2:
            raise SidecarFailure("efel.trace-shape", f"Trace {identifier} has mismatched or insufficient samples.")
        if len(time) > maximum_samples:
            raise SidecarFailure(
                "efel.sample-count",
                f"Trace {identifier} has {len(time)} samples, above maximumSamplesPerSeries={maximum_samples}.",
            )
        if any(right <= left for left, right in zip(time, time[1:])):
            raise SidecarFailure("efel.time-order", f"Trace {identifier} time is not strictly increasing.")
        starts = finite_array(
            value.get("stimulusStartMilliseconds"),
            f"{identifier}.stimulusStartMilliseconds",
        )
        ends = finite_array(
            value.get("stimulusEndMilliseconds"),
            f"{identifier}.stimulusEndMilliseconds",
        )
        if not starts or len(starts) != len(ends):
            raise SidecarFailure("efel.stimulus", f"Trace {identifier} has invalid stimulus intervals.")
        if any(end < start for start, end in zip(starts, ends)):
            raise SidecarFailure("efel.stimulus", f"Trace {identifier} has a reversed stimulus interval.")
        if starts[0] < time[0] or ends[-1] > time[-1]:
            raise SidecarFailure("efel.stimulus", f"Trace {identifier} stimulus lies outside the trace.")
        traces.append(
            {
                "id": identifier,
                "timeMilliseconds": time,
                "voltageMillivolts": voltage,
                "stimulusStartMilliseconds": starts,
                "stimulusEndMilliseconds": ends,
            }
        )
    return traces


def finite_array(value: Any, name: str) -> list[float]:
    if not isinstance(value, list):
        raise SidecarFailure("efel.array", f"{name} must be an array.")
    result: list[float] = []
    for ordinal, item in enumerate(value):
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            raise SidecarFailure("efel.number", f"{name}[{ordinal}] is not numeric.")
        numeric = float(item)
        if not math.isfinite(numeric):
            raise SidecarFailure("efel.number", f"{name}[{ordinal}] is not finite.")
        result.append(numeric)
    return result


def normalize_feature(value: Any) -> list[float] | None:
    if value is None:
        return None
    normalized = finite_json(value)
    if not isinstance(normalized, list):
        normalized = [normalized]
    result: list[float] = []
    for item in normalized:
        if item is None:
            continue
        numeric = float(item)
        if math.isfinite(numeric):
            result.append(numeric)
    return result or None


if __name__ == "__main__":
    raise SystemExit(main())
