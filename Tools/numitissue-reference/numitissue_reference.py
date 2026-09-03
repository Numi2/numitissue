#!/usr/bin/env python3
"""Fixed-engine reference sidecar for analytic traces and SONATA HDF5 materialization."""

from __future__ import annotations

import argparse
import importlib.metadata
import math
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping

_PHASE4 = Path(__file__).resolve().parents[1] / "phase4"
if str(_PHASE4) not in sys.path:
    sys.path.insert(0, str(_PHASE4))

from sidecar_common import (  # noqa: E402
    LoadedRequest,
    SidecarFailure,
    VerifiedInput,
    diagnostic,
    finite_json,
    make_artifact,
    read_json,
    run_sidecar,
    write_json_atomic,
)

IMPLEMENTATION = "numitissue-reference"
IMPLEMENTATION_VERSION = "1"
H5PY_VERSION = "3.16.0"
H5PY_SOURCE = "h5py/h5py@b2f0347c4200333acd89b43733f1caa0c115162f"
ALLOWED_OPERATIONS = {"simulate", "compare", "validate"}
ENGINE_CONTRACTS = {
    "analytic-passive-rc": ("1", "Numi2/numitissue:analytic-passive-rc-v1"),
    "canonical-trace-comparison": ("1", "Numi2/numitissue:canonical-trace-v1"),
    "sonata-hdf5": (H5PY_VERSION, H5PY_SOURCE),
}


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
            expected_sidecar="reference",
            allowed_operations=ALLOWED_OPERATIONS,
            implementation=IMPLEMENTATION,
            implementation_version=IMPLEMENTATION_VERSION,
            packages={"h5py": H5PY_VERSION},
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
    engine = require_parameter(request, "engine")
    expected = ENGINE_CONTRACTS.get(engine)
    if expected is None:
        raise SidecarFailure("reference.engine", f"Engine {engine!r} is not allowlisted.")
    version = require_parameter(request, "engineVersion")
    source = require_parameter(request, "engineSource")
    if (version, source) != expected:
        raise SidecarFailure(
            "reference.engine-pin",
            f"Engine {engine} must use version={expected[0]!r} and source={expected[1]!r}.",
        )

    operation = request.value["operation"]
    maximum_output = int(request.value["selection"]["maximumOutputBytes"])
    diagnostics: list[dict[str, Any]] = []
    if engine == "analytic-passive-rc":
        if operation not in {"simulate", "validate"}:
            raise SidecarFailure("reference.operation", "analytic-passive-rc supports simulate and validate.")
        payload = parse_passive_rc(inputs, request)
        if operation == "simulate":
            output_payload, metrics = simulate_passive_rc(payload, inputs[0])
            output_name = "analytic-passive-rc.json"
            role = "reference-simulation"
        else:
            output_payload = {
                "schemaVersion": 1,
                "engine": engine,
                "inputID": inputs[0].identifier,
                "inputSHA256": inputs[0].sha256,
                "valid": True,
                "sampleCount": payload["sampleCount"],
            }
            metrics = {"sampleCount": float(payload["sampleCount"])}
            output_name = "analytic-passive-rc-validation.json"
            role = "validation"
    elif engine == "canonical-trace-comparison":
        if operation not in {"compare", "validate"}:
            raise SidecarFailure("reference.operation", "canonical-trace-comparison supports compare and validate.")
        traces = [parse_trace(value, request) for value in inputs]
        if operation == "validate":
            output_payload = {
                "schemaVersion": 1,
                "engine": engine,
                "valid": True,
                "inputs": [
                    {
                        "id": trace["inputID"],
                        "sha256": trace["inputSHA256"],
                        "sampleCount": len(trace["values"]),
                        "spikeCount": len(trace["spikeTimesMilliseconds"]),
                    }
                    for trace in traces
                ],
            }
            metrics = {"inputCount": float(len(traces))}
            output_name = "canonical-trace-validation.json"
            role = "validation"
        else:
            if len(traces) != 2:
                raise SidecarFailure("reference.input-count", "Trace comparison requires exactly two inputs.")
            output_payload, metrics = compare_traces(traces[0], traces[1], request)
            output_name = "canonical-trace-comparison.json"
            role = "comparison"
    elif engine == "sonata-hdf5":
        if operation != "validate":
            raise SidecarFailure("reference.operation", "sonata-hdf5 uses the validate operation for bounded materialization.")
        output_payload, diagnostics, metrics = materialize_sonata(inputs, request)
        output_name = "sonata-hdf5-materialization.json"
        role = "circuit-materialization"
    else:
        raise SidecarFailure("reference.engine", f"Unhandled engine: {engine}")

    output = output_root / output_name
    write_json_atomic(output_payload, output, maximum_output)
    artifact = make_artifact(
        path=output,
        output_root=output_root,
        logical_name=output.stem,
        role=role,
        media_type="application/json",
        metadata={
            "engine": engine,
            "engineVersion": version,
            "engineSource": source,
        },
    )
    metrics = dict(metrics)
    metrics["artifactBytes"] = float(artifact["byteCount"])
    return [artifact], diagnostics, metrics, {
        "engine": engine,
        "engineVersion": version,
        "engineSource": source,
    }


def parse_passive_rc(inputs: list[VerifiedInput], request: LoadedRequest) -> dict[str, Any]:
    if len(inputs) != 1:
        raise SidecarFailure("reference.input-count", "Passive RC execution requires one input.")
    value = read_json(inputs[0].path)
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or value.get("model") != "passive-rc":
        raise SidecarFailure("reference.rc-schema", "Passive RC input must use model='passive-rc' and schemaVersion=1.")
    capacitance = finite_number(value.get("capacitanceNanofarads"), "capacitanceNanofarads")
    resistance = finite_number(value.get("resistanceMegaohms"), "resistanceMegaohms")
    resting = finite_number(value.get("restingVoltageMillivolts"), "restingVoltageMillivolts")
    initial = finite_number(value.get("initialVoltageMillivolts", resting), "initialVoltageMillivolts")
    dt = finite_number(value.get("deltaTMilliseconds"), "deltaTMilliseconds")
    duration = finite_number(value.get("durationMilliseconds"), "durationMilliseconds")
    if not 1e-9 <= capacitance <= 1e9 or not 1e-9 <= resistance <= 1e12:
        raise SidecarFailure("reference.rc-parameters", "Passive RC capacitance or resistance is outside the positive bound.")
    if not -1e6 <= resting <= 1e6 or not -1e6 <= initial <= 1e6:
        raise SidecarFailure("reference.rc-voltage", "Passive RC voltage is outside the bound.")
    if not 1e-6 <= dt <= 1e6 or not dt <= duration <= 1e12:
        raise SidecarFailure("reference.rc-time", "Passive RC time configuration is outside the bound.")
    sample_count = int(math.floor(duration / dt)) + 1
    maximum_samples = int(request.value["selection"]["maximumSamplesPerSeries"])
    if sample_count > maximum_samples:
        raise SidecarFailure(
            "reference.rc-samples",
            f"Passive RC trace has {sample_count} samples, above maximumSamplesPerSeries={maximum_samples}.",
        )
    intervals_value = value.get("currentIntervals", [])
    if not isinstance(intervals_value, list):
        raise SidecarFailure("reference.rc-current", "currentIntervals must be an array.")
    if len(intervals_value) > int(request.value["selection"]["maximumRecords"]):
        raise SidecarFailure("reference.rc-current", "Too many current intervals.")
    intervals = []
    for ordinal, interval in enumerate(intervals_value):
        if not isinstance(interval, dict):
            raise SidecarFailure("reference.rc-current", f"Current interval {ordinal} is not an object.")
        start = finite_number(interval.get("startMilliseconds"), f"interval[{ordinal}].startMilliseconds")
        end = finite_number(interval.get("endMilliseconds"), f"interval[{ordinal}].endMilliseconds")
        current = finite_number(interval.get("currentNanoamps"), f"interval[{ordinal}].currentNanoamps")
        if start < 0 or end <= start or end > duration or abs(current) > 1e12:
            raise SidecarFailure("reference.rc-current", f"Current interval {ordinal} is outside the bound.")
        intervals.append({"startMilliseconds": start, "endMilliseconds": end, "currentNanoamps": current})
    return {
        "schemaVersion": 1,
        "model": "passive-rc",
        "capacitanceNanofarads": capacitance,
        "resistanceMegaohms": resistance,
        "restingVoltageMillivolts": resting,
        "initialVoltageMillivolts": initial,
        "deltaTMilliseconds": dt,
        "durationMilliseconds": duration,
        "currentIntervals": intervals,
        "sampleCount": sample_count,
    }


def simulate_passive_rc(
    specification: Mapping[str, Any],
    source: VerifiedInput,
) -> tuple[dict[str, Any], dict[str, float]]:
    dt = float(specification["deltaTMilliseconds"])
    count = int(specification["sampleCount"])
    capacitance = float(specification["capacitanceNanofarads"])
    resistance = float(specification["resistanceMegaohms"])
    resting = float(specification["restingVoltageMillivolts"])
    tau = resistance * capacitance
    voltage = float(specification["initialVoltageMillivolts"])
    times = [index * dt for index in range(count)]
    voltages = [voltage]
    currents = [current_at(0, specification["currentIntervals"])]
    for index in range(1, count):
        time = times[index - 1]
        current = current_at(time, specification["currentIntervals"])
        target = resting + resistance * current
        voltage = target + (voltage - target) * math.exp(-dt / tau)
        if not math.isfinite(voltage):
            raise SidecarFailure("reference.rc-numerical", f"Passive RC voltage became non-finite at sample {index}.")
        voltages.append(voltage)
        currents.append(current_at(times[index], specification["currentIntervals"]))
    payload = {
        "schemaVersion": 1,
        "engine": "analytic-passive-rc",
        "engineVersion": "1",
        "inputID": source.identifier,
        "inputSHA256": source.sha256,
        "parameters": dict(specification),
        "timeConstantMilliseconds": tau,
        "recordings": {
            "timeMilliseconds": times,
            "voltageMillivolts": voltages,
            "currentNanoamps": currents,
        },
    }
    return finite_json(payload), {
        "sampleCount": float(count),
        "timeConstantMilliseconds": tau,
        "minimumVoltageMillivolts": min(voltages),
        "maximumVoltageMillivolts": max(voltages),
    }


def current_at(time: float, intervals: Iterable[Mapping[str, Any]]) -> float:
    return sum(
        float(interval["currentNanoamps"])
        for interval in intervals
        if float(interval["startMilliseconds"]) <= time < float(interval["endMilliseconds"])
    )


def parse_trace(source: VerifiedInput, request: LoadedRequest) -> dict[str, Any]:
    value = read_json(source.path)
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise SidecarFailure("reference.trace-schema", f"Trace {source.identifier} must use schemaVersion 1.")
    time = finite_array(value.get("timeMilliseconds"), f"{source.identifier}.timeMilliseconds")
    raw_values = value.get("values", value.get("voltageMillivolts"))
    values = finite_array(raw_values, f"{source.identifier}.values")
    spikes = finite_array(value.get("spikeTimesMilliseconds", []), f"{source.identifier}.spikeTimesMilliseconds")
    if len(time) != len(values) or len(time) < 2:
        raise SidecarFailure("reference.trace-shape", f"Trace {source.identifier} has mismatched arrays.")
    maximum_samples = int(request.value["selection"]["maximumSamplesPerSeries"])
    if len(time) > maximum_samples:
        raise SidecarFailure("reference.trace-samples", f"Trace {source.identifier} exceeds the sample bound.")
    if any(right <= left for left, right in zip(time, time[1:])):
        raise SidecarFailure("reference.trace-time", f"Trace {source.identifier} time is not increasing.")
    if any(right < left for left, right in zip(spikes, spikes[1:])):
        raise SidecarFailure("reference.trace-spikes", f"Trace {source.identifier} spikes are not sorted.")
    return {
        "inputID": source.identifier,
        "inputSHA256": source.sha256,
        "timeMilliseconds": time,
        "values": values,
        "spikeTimesMilliseconds": spikes,
        "unit": value.get("unit"),
    }


def compare_traces(
    reference: Mapping[str, Any],
    candidate: Mapping[str, Any],
    request: LoadedRequest,
) -> tuple[dict[str, Any], dict[str, float]]:
    if len(reference["values"]) != len(candidate["values"]):
        raise SidecarFailure("reference.trace-shape", "Compared traces have different sample counts.")
    time_tolerance = parameter_number(request, "timeToleranceMilliseconds", 0.0, 0.0, 1e9)
    value_tolerance = parameter_number(request, "valueTolerance", 0.0, 0.0, 1e300)
    spike_tolerance = parameter_number(request, "spikeToleranceMilliseconds", 0.05, 0.0, 1e9)
    time_errors = [
        abs(left - right)
        for left, right in zip(reference["timeMilliseconds"], candidate["timeMilliseconds"], strict=True)
    ]
    if max(time_errors, default=0.0) > time_tolerance:
        raise SidecarFailure("reference.time-grid", "Compared traces exceed the time-grid tolerance.")
    differences = [
        right - left
        for left, right in zip(reference["values"], candidate["values"], strict=True)
    ]
    absolute = [abs(value) for value in differences]
    count = len(differences)
    mean_error = sum(differences) / count
    mean_absolute = sum(absolute) / count
    root_mean_square = math.sqrt(sum(value * value for value in differences) / count)
    maximum_absolute = max(absolute, default=0.0)
    spike = compare_spikes(
        reference["spikeTimesMilliseconds"],
        candidate["spikeTimesMilliseconds"],
        spike_tolerance,
    )
    passed = maximum_absolute <= value_tolerance and spike["allMatchedWithinTolerance"]
    payload = {
        "schemaVersion": 1,
        "engine": "canonical-trace-comparison",
        "engineVersion": "1",
        "reference": {
            "inputID": reference["inputID"],
            "inputSHA256": reference["inputSHA256"],
        },
        "candidate": {
            "inputID": candidate["inputID"],
            "inputSHA256": candidate["inputSHA256"],
        },
        "sampleCount": count,
        "timeToleranceMilliseconds": time_tolerance,
        "valueTolerance": value_tolerance,
        "spikeToleranceMilliseconds": spike_tolerance,
        "meanError": mean_error,
        "meanAbsoluteError": mean_absolute,
        "rootMeanSquareError": root_mean_square,
        "maximumAbsoluteError": maximum_absolute,
        "spikes": spike,
        "passed": passed,
    }
    return finite_json(payload), {
        "sampleCount": float(count),
        "meanAbsoluteError": mean_absolute,
        "rootMeanSquareError": root_mean_square,
        "maximumAbsoluteError": maximum_absolute,
        "referenceSpikeCount": float(len(reference["spikeTimesMilliseconds"])),
        "candidateSpikeCount": float(len(candidate["spikeTimesMilliseconds"])),
    }


def compare_spikes(reference: list[float], candidate: list[float], tolerance: float) -> dict[str, Any]:
    if len(reference) != len(candidate):
        return {
            "referenceCount": len(reference),
            "candidateCount": len(candidate),
            "matchedCount": min(len(reference), len(candidate)),
            "maximumAbsoluteTimingErrorMilliseconds": None,
            "rootMeanSquareTimingErrorMilliseconds": None,
            "allMatchedWithinTolerance": False,
        }
    errors = [abs(left - right) for left, right in zip(reference, candidate, strict=True)]
    rms = math.sqrt(sum(value * value for value in errors) / len(errors)) if errors else 0.0
    maximum = max(errors, default=0.0)
    return {
        "referenceCount": len(reference),
        "candidateCount": len(candidate),
        "matchedCount": len(reference),
        "maximumAbsoluteTimingErrorMilliseconds": maximum,
        "rootMeanSquareTimingErrorMilliseconds": rms,
        "allMatchedWithinTolerance": maximum <= tolerance,
    }


def materialize_sonata(
    inputs: list[VerifiedInput],
    request: LoadedRequest,
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, float]]:
    if not inputs:
        raise SidecarFailure("sonata.input-count", "At least one SONATA HDF5 input is required.")
    import h5py

    if importlib.metadata.version("h5py") != H5PY_VERSION:
        raise SidecarFailure("sonata.h5py-version", f"SONATA materialization requires h5py=={H5PY_VERSION}.")
    maximum_records = int(request.value["selection"]["maximumRecords"])
    maximum_samples = int(request.value["selection"]["maximumSamplesPerSeries"])
    requested_paths = list(request.value["selection"].get("objectPaths", []))
    diagnostics: list[dict[str, Any]] = []
    files = []
    total_datasets = 0
    total_values = 0

    for source in inputs:
        if source.path.suffix.lower() not in {".h5", ".hdf5"}:
            raise SidecarFailure("sonata.extension", f"SONATA HDF5 input has unsupported suffix: {source.path.suffix}")
        with h5py.File(source.path, "r") as handle:
            kind = sonata_kind(handle)
            validate_sonata_structure(handle, kind)
            objects = inspect_hdf5_objects(handle, maximum_records)
            total_datasets += sum(1 for value in objects if value["kind"] == "dataset")
            selected = {}
            for path in requested_paths:
                normalized = normalize_hdf5_path(path)
                if normalized not in handle:
                    raise SidecarFailure("sonata.path", f"HDF5 object path does not exist: {path}")
                selected[normalized] = extract_hdf5_object(handle[normalized], maximum_samples)
                total_values += count_values(selected[normalized])
            files.append(
                {
                    "inputID": source.identifier,
                    "inputSHA256": source.sha256,
                    "sonataKind": kind,
                    "hdf5LibraryVersion": h5py.version.hdf5_version,
                    "rootAttributes": attributes(handle.attrs),
                    "objectCount": len(objects),
                    "objects": objects,
                    "selectedObjects": selected,
                }
            )
            if len(objects) >= maximum_records:
                diagnostics.append(
                    diagnostic(
                        "warning",
                        "sonata.object-limit",
                        f"HDF5 object listing for {source.identifier} reached maximumRecords={maximum_records}.",
                    )
                )

    payload = {
        "schemaVersion": 1,
        "engine": "sonata-hdf5",
        "engineVersion": H5PY_VERSION,
        "engineSource": H5PY_SOURCE,
        "files": files,
    }
    return finite_json(payload), diagnostics, {
        "fileCount": float(len(files)),
        "datasetCount": float(total_datasets),
        "selectedValueCount": float(total_values),
    }


def sonata_kind(handle: Any) -> str:
    has_nodes = "nodes" in handle
    has_edges = "edges" in handle
    if has_nodes and has_edges:
        return "nodes-and-edges"
    if has_nodes:
        return "nodes"
    if has_edges:
        return "edges"
    raise SidecarFailure("sonata.root", "HDF5 file contains neither /nodes nor /edges.")


def validate_sonata_structure(handle: Any, kind: str) -> None:
    if kind in {"nodes", "nodes-and-edges"}:
        nodes = handle["nodes"]
        if not list(nodes.keys()):
            raise SidecarFailure("sonata.nodes", "SONATA /nodes contains no populations.")
        for population_name, population in nodes.items():
            required = {"node_type_id", "node_group_id", "node_group_index"}
            missing = sorted(required - set(population.keys()))
            if missing:
                raise SidecarFailure(
                    "sonata.nodes",
                    f"Node population {population_name} is missing {', '.join(missing)}.",
                )
    if kind in {"edges", "nodes-and-edges"}:
        edges = handle["edges"]
        if not list(edges.keys()):
            raise SidecarFailure("sonata.edges", "SONATA /edges contains no populations.")
        for population_name, population in edges.items():
            required = {
                "edge_type_id",
                "edge_group_id",
                "edge_group_index",
                "source_node_id",
                "target_node_id",
            }
            missing = sorted(required - set(population.keys()))
            if missing:
                raise SidecarFailure(
                    "sonata.edges",
                    f"Edge population {population_name} is missing {', '.join(missing)}.",
                )


def inspect_hdf5_objects(handle: Any, maximum_records: int) -> list[dict[str, Any]]:
    import h5py

    result: list[dict[str, Any]] = []

    def visitor(name: str, value: Any) -> None:
        if len(result) >= maximum_records:
            return
        if isinstance(value, h5py.Dataset):
            result.append(
                {
                    "path": "/" + name,
                    "kind": "dataset",
                    "shape": list(value.shape),
                    "dtype": str(value.dtype),
                    "size": int(value.size),
                    "chunks": list(value.chunks) if value.chunks is not None else None,
                    "compression": value.compression,
                    "attributes": attributes(value.attrs),
                }
            )
        else:
            result.append(
                {
                    "path": "/" + name,
                    "kind": "group",
                    "attributes": attributes(value.attrs),
                }
            )

    handle.visititems(visitor)
    return result


def extract_hdf5_object(value: Any, maximum_samples: int) -> Any:
    import h5py

    if isinstance(value, h5py.Group):
        return {
            "kind": "group",
            "attributes": attributes(value.attrs),
            "children": sorted(str(name) for name in value.keys()),
        }
    if not isinstance(value, h5py.Dataset):
        return {"kind": type(value).__name__}
    size = int(value.size)
    if size > maximum_samples:
        if value.ndim == 0:
            raise SidecarFailure("sonata.dataset", "Scalar dataset reported an impossible size.")
        if value.shape[0] == 0:
            data = []
        else:
            row_width = max(1, math.prod(value.shape[1:]))
            rows = max(1, maximum_samples // row_width)
            data = value[: min(rows, value.shape[0])]
        truncated = True
    else:
        data = value[()]
        truncated = False
    return finite_json(
        {
            "kind": "dataset",
            "shape": list(value.shape),
            "dtype": str(value.dtype),
            "size": size,
            "truncated": truncated,
            "attributes": attributes(value.attrs),
            "data": data,
        }
    )


def attributes(source: Any) -> dict[str, Any]:
    return {
        str(key): finite_json(value)
        for key, value in sorted(source.items(), key=lambda item: str(item[0]))
    }


def normalize_hdf5_path(path: str) -> str:
    if not isinstance(path, str) or not path.startswith("/") or ".." in path.split("/"):
        raise SidecarFailure("sonata.path", f"Invalid HDF5 object path: {path!r}")
    return path.lstrip("/")


def count_values(value: Any) -> int:
    if isinstance(value, dict):
        return sum(count_values(item) for item in value.values())
    if isinstance(value, list):
        return sum(count_values(item) for item in value)
    return 1


def require_parameter(request: LoadedRequest, name: str) -> str:
    parameters = request.value.get("parameters", {})
    value = parameters.get(name) if isinstance(parameters, dict) else None
    if not isinstance(value, str) or not value:
        raise SidecarFailure("reference.parameter", f"Request parameter {name} must be a nonempty string.")
    return value


def parameter_number(
    request: LoadedRequest,
    name: str,
    default: float,
    lower: float,
    upper: float,
) -> float:
    parameters = request.value.get("parameters", {})
    raw = parameters.get(name) if isinstance(parameters, dict) else None
    if raw is None:
        return default
    try:
        value = float(raw)
    except (TypeError, ValueError) as error:
        raise SidecarFailure("reference.parameter", f"Request parameter {name} is not numeric.") from error
    if not math.isfinite(value) or not lower <= value <= upper:
        raise SidecarFailure("reference.parameter", f"Request parameter {name} is outside {lower}...{upper}.")
    return value


def finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SidecarFailure("reference.number", f"{name} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise SidecarFailure("reference.number", f"{name} must be finite.")
    return result


def finite_array(value: Any, name: str) -> list[float]:
    if not isinstance(value, list):
        raise SidecarFailure("reference.array", f"{name} must be an array.")
    return [finite_number(item, f"{name}[{index}]") for index, item in enumerate(value)]


if __name__ == "__main__":
    raise SystemExit(main())
