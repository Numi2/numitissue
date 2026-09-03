#!/usr/bin/env python3
"""Pinned PyNWB sidecar for schema validation and bounded canonical extraction."""

from __future__ import annotations

import argparse
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

IMPLEMENTATION = "numitissue-nwb"
IMPLEMENTATION_VERSION = "1"
PYNWB_VERSION = "4.1.0"
ALLOWED_OPERATIONS = {"inspect", "validate", "extract"}


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
            expected_sidecar="nwb",
            allowed_operations=ALLOWED_OPERATIONS,
            implementation=IMPLEMENTATION,
            implementation_version=IMPLEMENTATION_VERSION,
            packages={"pynwb": PYNWB_VERSION},
            handler=handle,
        )
    except SidecarFailure as error:
        print(f"{IMPLEMENTATION}: {error.code}: {error.message}", file=sys.stderr)
        return 2
    except Exception as error:  # A crash remains distinct from protocol rejection.
        print(f"{IMPLEMENTATION}: unexpected failure: {error}", file=sys.stderr)
        return 1


def handle(
    request: LoadedRequest,
    inputs: list[VerifiedInput],
    output_root: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, float], dict[str, str]]:
    if len(inputs) != 1:
        raise SidecarFailure("nwb.input-count", "NWB operations require exactly one input file.")
    source = inputs[0]
    if source.path.suffix.lower() not in {".nwb", ".h5", ".hdf5"}:
        raise SidecarFailure("nwb.extension", f"Unsupported NWB input suffix: {source.path.suffix}")

    from pynwb import NWBHDF5IO, validate

    selection = request.value["selection"]
    maximum_records = int(selection["maximumRecords"])
    maximum_samples = int(selection["maximumSamplesPerSeries"])
    maximum_output = int(selection["maximumOutputBytes"])
    operation = request.value["operation"]
    diagnostics: list[dict[str, Any]] = []

    if operation == "validate":
        errors = list(validate(path=source.path, use_cached_namespaces=True, verbose=False))
        payload = {
            "schemaVersion": 1,
            "inputID": source.identifier,
            "inputSHA256": source.sha256,
            "valid": not errors,
            "errorCount": len(errors),
            "errors": [str(error) for error in errors[:maximum_records]],
            "truncated": len(errors) > maximum_records,
        }
        if errors:
            diagnostics.append(
                diagnostic(
                    "warning",
                    "nwb.schema-errors",
                    f"PyNWB reported {len(errors)} schema validation error(s).",
                )
            )
        output = output_root / "nwb-validation.json"
        write_json_atomic(payload, output, maximum_output)
        artifact = make_artifact(
            path=output,
            output_root=output_root,
            logical_name="nwb-validation",
            role="validation",
            media_type="application/json",
            metadata={"validator": f"PyNWB {PYNWB_VERSION}"},
        )
        return [artifact], diagnostics, {"validationErrorCount": float(len(errors))}, {
            "nwb.validation": "cached-namespaces",
            "inputSHA256": source.sha256,
        }

    with NWBHDF5IO(path=str(source.path), mode="r", load_namespaces=True) as io:
        nwbfile = io.read()
        version = _nwb_version(io)
        if operation == "inspect":
            payload = inspect_nwb(
                nwbfile,
                input_id=source.identifier,
                input_sha256=source.sha256,
                nwb_version=version,
            )
            output_name = "nwb-inspection.json"
        elif operation == "extract":
            payload, extract_diagnostics = extract_nwb(
                nwbfile,
                input_id=source.identifier,
                input_sha256=source.sha256,
                nwb_version=version,
                selection=selection,
                maximum_records=maximum_records,
                maximum_samples=maximum_samples,
            )
            diagnostics.extend(extract_diagnostics)
            output_name = "nwb-extract.json"
        else:
            raise SidecarFailure("nwb.operation", f"Unhandled operation: {operation}")

    output = output_root / output_name
    write_json_atomic(payload, output, maximum_output)
    artifact = make_artifact(
        path=output,
        output_root=output_root,
        logical_name=output.stem,
        role="observation" if operation == "extract" else "inspection",
        media_type="application/json",
        metadata={
            "nwbVersion": str(payload.get("nwbVersion", "unknown")),
            "inputSHA256": source.sha256,
        },
    )
    return [artifact], diagnostics, {
        "artifactBytes": float(artifact["byteCount"]),
    }, {
        "nwbVersion": str(payload.get("nwbVersion", "unknown")),
        "inputSHA256": source.sha256,
    }


def _nwb_version(io: Any) -> str:
    version = getattr(io, "nwb_version", None)
    if isinstance(version, tuple) and version:
        return str(version[0])
    if version is None:
        return "unknown"
    return str(version)


def inspect_nwb(
    nwbfile: Any,
    *,
    input_id: str,
    input_sha256: str,
    nwb_version: str,
) -> dict[str, Any]:
    intervals = getattr(nwbfile, "intervals", {}) or {}
    processing = getattr(nwbfile, "processing", {}) or {}
    stimulus = getattr(nwbfile, "stimulus", {}) or {}
    return finite_json(
        {
            "schemaVersion": 1,
            "inputID": input_id,
            "inputSHA256": input_sha256,
            "nwbVersion": nwb_version,
            "identifier": getattr(nwbfile, "identifier", None),
            "sessionDescription": getattr(nwbfile, "session_description", None),
            "sessionStartTime": _iso(getattr(nwbfile, "session_start_time", None)),
            "timestampsReferenceTime": _iso(
                getattr(nwbfile, "timestamps_reference_time", None)
            ),
            "experimenter": list(getattr(nwbfile, "experimenter", None) or []),
            "institution": getattr(nwbfile, "institution", None),
            "lab": getattr(nwbfile, "lab", None),
            "experimentDescription": getattr(nwbfile, "experiment_description", None),
            "sessionID": getattr(nwbfile, "session_id", None),
            "subject": _subject(getattr(nwbfile, "subject", None)),
            "devices": sorted(str(name) for name in (getattr(nwbfile, "devices", {}) or {}).keys()),
            "acquisition": _container_summary(getattr(nwbfile, "acquisition", {}) or {}),
            "stimulus": _container_summary(stimulus),
            "processing": _container_summary(processing),
            "intervals": _container_summary(intervals),
            "electrodeCount": _safe_length(getattr(nwbfile, "electrodes", None)),
            "unitCount": _safe_length(getattr(nwbfile, "units", None)),
            "objectID": getattr(nwbfile, "object_id", None),
        }
    )


def extract_nwb(
    nwbfile: Any,
    *,
    input_id: str,
    input_sha256: str,
    nwb_version: str,
    selection: Mapping[str, Any],
    maximum_records: int,
    maximum_samples: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    requested_paths = list(selection.get("objectPaths", []))
    if not requested_paths:
        requested_paths = [
            "/session",
            "/subject",
            "/devices",
            "/electrodes",
            "/units",
            "/intervals",
            "/acquisition",
        ]
    supported = {
        "/session",
        "/subject",
        "/devices",
        "/electrodes",
        "/units",
        "/intervals",
        "/acquisition",
        "/stimulus",
        "/processing",
    }
    unknown = sorted(set(requested_paths) - supported)
    if unknown:
        raise SidecarFailure(
            "nwb.object-path",
            "Unsupported object path(s): " + ", ".join(unknown),
        )

    diagnostics: list[dict[str, Any]] = []
    result: dict[str, Any] = {
        "schemaVersion": 1,
        "inputID": input_id,
        "inputSHA256": input_sha256,
        "nwbVersion": nwb_version,
        "selection": dict(selection),
        "objects": {},
    }
    objects = result["objects"]
    assert isinstance(objects, dict)

    if "/session" in requested_paths:
        objects["/session"] = {
            "identifier": getattr(nwbfile, "identifier", None),
            "sessionDescription": getattr(nwbfile, "session_description", None),
            "sessionStartTime": _iso(getattr(nwbfile, "session_start_time", None)),
            "timestampsReferenceTime": _iso(
                getattr(nwbfile, "timestamps_reference_time", None)
            ),
            "sessionID": getattr(nwbfile, "session_id", None),
            "experimenter": list(getattr(nwbfile, "experimenter", None) or []),
            "institution": getattr(nwbfile, "institution", None),
            "lab": getattr(nwbfile, "lab", None),
        }
    if "/subject" in requested_paths:
        objects["/subject"] = _subject(getattr(nwbfile, "subject", None))
    if "/devices" in requested_paths:
        devices = getattr(nwbfile, "devices", {}) or {}
        objects["/devices"] = [
            {
                "name": str(name),
                "description": getattr(device, "description", None),
                "manufacturer": getattr(device, "manufacturer", None),
                "modelNumber": getattr(device, "model_number", None),
                "serialNumber": getattr(device, "serial_number", None),
                "objectID": getattr(device, "object_id", None),
            }
            for name, device in sorted(devices.items(), key=lambda item: str(item[0]))
        ][:maximum_records]
    if "/electrodes" in requested_paths:
        table = getattr(nwbfile, "electrodes", None)
        objects["/electrodes"] = extract_table(
            table,
            maximum_records,
            maximum_samples,
            selected_ids=set(selection.get("electrodeIDs", [])),
        )
    if "/units" in requested_paths:
        objects["/units"] = extract_table(
            getattr(nwbfile, "units", None),
            maximum_records,
            maximum_samples,
        )
    if "/intervals" in requested_paths:
        interval_tables = getattr(nwbfile, "intervals", {}) or {}
        objects["/intervals"] = {
            str(name): extract_table(table, maximum_records, maximum_samples)
            for name, table in sorted(interval_tables.items(), key=lambda item: str(item[0]))
        }
    if "/acquisition" in requested_paths:
        objects["/acquisition"] = extract_timeseries_collection(
            getattr(nwbfile, "acquisition", {}) or {},
            selection,
            maximum_samples,
            diagnostics,
        )
    if "/stimulus" in requested_paths:
        objects["/stimulus"] = extract_timeseries_collection(
            getattr(nwbfile, "stimulus", {}) or {},
            selection,
            maximum_samples,
            diagnostics,
        )
    if "/processing" in requested_paths:
        modules = getattr(nwbfile, "processing", {}) or {}
        objects["/processing"] = {
            str(name): {
                "description": getattr(module, "description", None),
                "interfaces": _container_summary(
                    getattr(module, "data_interfaces", {}) or {}
                ),
            }
            for name, module in sorted(modules.items(), key=lambda item: str(item[0]))
        }

    return finite_json(result), diagnostics


def extract_table(
    table: Any,
    maximum_records: int,
    maximum_items_per_value: int,
    selected_ids: set[str] | None = None,
) -> dict[str, Any] | None:
    if table is None:
        return None
    count = _safe_length(table)
    limit = min(count, maximum_records)
    colnames = [str(value) for value in list(getattr(table, "colnames", ()) or ())]
    records: list[dict[str, Any]] = []
    scanned = 0
    for index in range(limit):
        scanned += 1
        identifier = _table_value(table, index, "id", fallback=index)
        if selected_ids and str(identifier) not in selected_ids:
            continue
        row: dict[str, Any] = {"id": finite_json(identifier)}
        for column in colnames:
            row[column] = bounded_value(
                _table_value(table, index, column),
                maximum_items_per_value,
            )
        records.append(row)
        if len(records) >= maximum_records:
            break
    return {
        "rowCount": count,
        "returnedRowCount": len(records),
        "scannedRowCount": scanned,
        "columns": colnames,
        "truncated": count > scanned,
        "records": records,
    }


def _table_value(table: Any, index: int, column: str, fallback: Any = None) -> Any:
    try:
        if column == "id":
            return table.id[index]
        return table[index, column]
    except Exception:
        return fallback


def extract_timeseries_collection(
    collection: Mapping[str, Any],
    selection: Mapping[str, Any],
    maximum_samples: int,
    diagnostics: list[dict[str, Any]],
) -> dict[str, Any]:
    start_time = selection.get("startTimeSeconds")
    end_time = selection.get("endTimeSeconds")
    result: dict[str, Any] = {}
    for name, series in sorted(collection.items(), key=lambda item: str(item[0])):
        if not hasattr(series, "data"):
            result[str(name)] = {
                "neurodataType": type(series).__name__,
                "objectID": getattr(series, "object_id", None),
                "dataExtracted": False,
            }
            continue
        try:
            result[str(name)] = extract_timeseries(
                series,
                maximum_samples=maximum_samples,
                start_time=start_time,
                end_time=end_time,
            )
        except Exception as error:
            diagnostics.append(
                diagnostic(
                    "warning",
                    "nwb.timeseries-extraction",
                    f"Unable to extract {name}: {error}",
                    f"/{name}",
                )
            )
            result[str(name)] = {
                "neurodataType": type(series).__name__,
                "objectID": getattr(series, "object_id", None),
                "dataExtracted": False,
                "error": str(error),
            }
    return result


def extract_timeseries(
    series: Any,
    *,
    maximum_samples: int,
    start_time: float | None,
    end_time: float | None,
) -> dict[str, Any]:
    data = series.data
    shape = list(getattr(data, "shape", ()) or ())
    sample_count = int(shape[0]) if shape else _safe_length(data)
    start_index = 0
    stop_index = min(sample_count, maximum_samples)
    starting_time = getattr(series, "starting_time", None)
    rate = getattr(series, "rate", None)
    if starting_time is not None and rate is not None and float(rate) > 0:
        base = float(starting_time)
        frequency = float(rate)
        if start_time is not None:
            start_index = max(0, min(sample_count, int((float(start_time) - base) * frequency)))
        if end_time is not None:
            stop_index = max(start_index, min(sample_count, int((float(end_time) - base) * frequency) + 1))
        stop_index = min(stop_index, start_index + maximum_samples)
    else:
        stop_index = min(sample_count, maximum_samples)

    values = data[start_index:stop_index]
    timestamps = getattr(series, "timestamps", None)
    timestamp_values: Any = None
    if timestamps is not None:
        timestamp_values = timestamps[start_index:stop_index]
        if start_time is not None or end_time is not None:
            paired = []
            for time, value in zip(timestamp_values, values):
                numeric_time = float(time)
                if start_time is not None and numeric_time < float(start_time):
                    continue
                if end_time is not None and numeric_time > float(end_time):
                    continue
                paired.append((time, value))
                if len(paired) >= maximum_samples:
                    break
            timestamp_values = [item[0] for item in paired]
            values = [item[1] for item in paired]

    return finite_json(
        {
            "neurodataType": type(series).__name__,
            "objectID": getattr(series, "object_id", None),
            "description": getattr(series, "description", None),
            "unit": getattr(series, "unit", None),
            "conversion": getattr(series, "conversion", None),
            "offset": getattr(series, "offset", None),
            "shape": shape,
            "sampleCount": sample_count,
            "startIndex": start_index,
            "stopIndex": stop_index,
            "truncated": stop_index - start_index < sample_count,
            "startingTime": starting_time,
            "rate": rate,
            "timestamps": bounded_value(timestamp_values, maximum_samples),
            "data": bounded_value(values, maximum_samples),
        }
    )


def bounded_value(value: Any, maximum_items: int, depth: int = 0) -> Any:
    if value is None or isinstance(value, (str, bool, int, float)):
        return finite_json(value)
    if depth >= 4:
        return str(value)
    if hasattr(value, "tolist") and callable(value.tolist):
        value = value.tolist()
    if isinstance(value, Mapping):
        return {
            str(key): bounded_value(item, maximum_items, depth + 1)
            for key, item in list(value.items())[:maximum_items]
        }
    if isinstance(value, (list, tuple)):
        return [
            bounded_value(item, maximum_items, depth + 1)
            for item in value[:maximum_items]
        ]
    if isinstance(value, Iterable):
        result = []
        for item in value:
            result.append(bounded_value(item, maximum_items, depth + 1))
            if len(result) >= maximum_items:
                break
        return result
    return finite_json(value)


def _subject(subject: Any) -> dict[str, Any] | None:
    if subject is None:
        return None
    keys = (
        "subject_id",
        "age",
        "age__reference",
        "date_of_birth",
        "description",
        "genotype",
        "sex",
        "species",
        "strain",
        "weight",
    )
    return finite_json(
        {
            key: _iso(getattr(subject, key, None))
            if key == "date_of_birth"
            else getattr(subject, key, None)
            for key in keys
        }
        | {"objectID": getattr(subject, "object_id", None)}
    )


def _container_summary(collection: Mapping[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "name": str(name),
            "neurodataType": type(value).__name__,
            "objectID": getattr(value, "object_id", None),
        }
        for name, value in sorted(collection.items(), key=lambda item: str(item[0]))
    ]


def _safe_length(value: Any) -> int:
    if value is None:
        return 0
    try:
        return int(len(value))
    except Exception:
        return 0


def _iso(value: Any) -> str | None:
    if value is None:
        return None
    if hasattr(value, "isoformat"):
        return str(value.isoformat())
    return str(value)


if __name__ == "__main__":
    raise SystemExit(main())
