#!/usr/bin/env python3
"""Extract versioned eFEL features from a NumiTissue or reference voltage CSV."""

from __future__ import annotations

import argparse
import csv
import importlib.metadata
import json
import math
from pathlib import Path
from typing import Any


def parse_features(value: str) -> list[str]:
    features = [item.strip() for item in value.split(",") if item.strip()]
    if not features or len(features) != len(set(features)):
        raise argparse.ArgumentTypeError("features must be a unique comma-separated list")
    return features


def read_trace(path: Path, time_column: str, voltage_column: str) -> tuple[list[float], list[float]]:
    times: list[float] = []
    voltages: list[float] = []
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or time_column not in reader.fieldnames or voltage_column not in reader.fieldnames:
            raise ValueError("CSV is missing the requested time or voltage column")
        for line, row in enumerate(reader, start=2):
            try:
                time = float(row[time_column])
                voltage = float(row[voltage_column])
            except (TypeError, ValueError) as error:
                raise ValueError(f"invalid numeric value at CSV line {line}") from error
            if not math.isfinite(time) or not math.isfinite(voltage):
                raise ValueError(f"non-finite trace value at CSV line {line}")
            if times and time <= times[-1]:
                raise ValueError(f"time is not strictly increasing at CSV line {line}")
            times.append(time)
            voltages.append(voltage)
    if not times:
        raise ValueError("CSV contains no trace samples")
    return times, voltages


def json_value(value: Any) -> Any:
    if value is None:
        return None
    if hasattr(value, "tolist"):
        value = value.tolist()
    if isinstance(value, list):
        return [json_value(item) for item in value]
    if isinstance(value, (int, float)):
        scalar = float(value)
        if not math.isfinite(scalar):
            raise ValueError("eFEL returned a non-finite feature")
        return scalar
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input-csv", type=Path, required=True)
    parser.add_argument("--output-json", type=Path, required=True)
    parser.add_argument("--time-column", default="time_ms")
    parser.add_argument("--voltage-column", required=True)
    parser.add_argument("--stim-start-ms", type=float, required=True)
    parser.add_argument("--stim-end-ms", type=float, required=True)
    parser.add_argument("--threshold-mv", type=float, default=-20)
    parser.add_argument(
        "--features",
        type=parse_features,
        default=parse_features(
            "voltage_base,steady_state_voltage_stimend,peak_time,"
            "AP_amplitude,AP_width,mean_frequency,adaptation_index2"
        ),
    )
    arguments = parser.parse_args()
    if (
        not math.isfinite(arguments.stim_start_ms)
        or not math.isfinite(arguments.stim_end_ms)
        or arguments.stim_end_ms <= arguments.stim_start_ms
        or not math.isfinite(arguments.threshold_mv)
    ):
        raise ValueError("stimulus interval or threshold is invalid")

    times, voltages = read_trace(
        arguments.input_csv,
        arguments.time_column,
        arguments.voltage_column,
    )
    import efel

    efel.reset()
    efel.set_setting("Threshold", arguments.threshold_mv)
    trace = {
        "T": times,
        "V": voltages,
        "stim_start": [arguments.stim_start_ms],
        "stim_end": [arguments.stim_end_ms],
    }
    result = efel.get_feature_values([trace], arguments.features)[0]
    output = {
        "schemaVersion": 1,
        "extractor": "eFEL",
        "extractorVersion": importlib.metadata.version("efel"),
        "source": str(arguments.input_csv),
        "timeColumn": arguments.time_column,
        "voltageColumn": arguments.voltage_column,
        "stimulus": {
            "startMilliseconds": arguments.stim_start_ms,
            "endMilliseconds": arguments.stim_end_ms,
        },
        "settings": {"Threshold": arguments.threshold_mv},
        "features": {key: json_value(result.get(key)) for key in arguments.features},
    }
    arguments.output_json.parent.mkdir(parents=True, exist_ok=True)
    arguments.output_json.write_text(
        json.dumps(output, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
