#!/usr/bin/env python3
"""Generate a first-order NEURON Rallpack 1 trace as canonical CSV + JSON provenance."""

from __future__ import annotations

import argparse
import csv
import importlib.metadata
import json
import math
import platform
import sys
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def finite_number(value: Any, name: str, *, positive: bool = False) -> float:
    result = float(value)
    if not math.isfinite(result) or (positive and result <= 0):
        raise ValueError(f"{name} is invalid")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-csv", type=Path, required=True)
    parser.add_argument("--output-provenance", type=Path, required=True)
    arguments = parser.parse_args()

    model = load_json(arguments.model)
    protocol = load_json(arguments.input)
    from neuron import h

    ra = finite_number(model["axialResistivityOhmMeter"], "axialResistivityOhmMeter", positive=True)
    rm = finite_number(model["membraneResistivityOhmMeterSquared"], "membraneResistivityOhmMeterSquared", positive=True)
    cm = finite_number(model["membraneCapacitanceFaradPerMeterSquared"], "membraneCapacitanceFaradPerMeterSquared", positive=True)
    reversal = finite_number(model["reversalMillivolts"], "reversalMillivolts")
    diameter = finite_number(model["diameterMicrometers"], "diameterMicrometers", positive=True)
    length = finite_number(model["lengthMicrometers"], "lengthMicrometers", positive=True)
    compartments = int(model["compartmentCount"])
    if compartments <= 0:
        raise ValueError("compartmentCount must be positive")

    dt = finite_number(protocol["stepMilliseconds"], "stepMilliseconds", positive=True)
    sample_dt = max(
        finite_number(protocol["sampleMilliseconds"], "sampleMilliseconds", positive=True),
        dt,
    )
    duration = finite_number(protocol["durationMilliseconds"], "durationMilliseconds", positive=True)
    current = finite_number(protocol["injectedCurrentNanoamps"], "injectedCurrentNanoamps")
    x0 = finite_number(protocol["measurementProportions"][0], "measurementProportions[0]")
    x1 = finite_number(protocol["measurementProportions"][1], "measurementProportions[1]")
    if not (0 <= x0 <= 1 and 0 <= x1 <= 1):
        raise ValueError("measurement proportions must be in [0, 1]")

    h.load_file("stdrun.hoc")
    cable = h.Section(name="numitissue_rallpack1")
    cable.diam = diameter
    cable.L = length
    cable.cm = 100 * cm
    cable.Ra = 100 * ra
    cable.nseg = compartments
    cable.insert("pas")
    cable.g_pas = 0.0001 / rm
    cable.e_pas = reversal

    stimulus = h.IClamp(cable(0))
    stimulus.delay = 0
    stimulus.dur = duration
    stimulus.amp = current

    time = h.Vector()
    voltage0 = h.Vector()
    voltage1 = h.Vector()
    time.record(h._ref_t, sample_dt)
    voltage0.record(cable(x0)._ref_v, sample_dt)
    voltage1.record(cable(x1)._ref_v, sample_dt)

    h.cvode.active(0)
    h.dt = dt
    h.steps_per_ms = 1 / dt
    h.secondorder = 0
    h.tstop = duration
    h.finitialize(reversal)
    h.continuerun(duration)

    times = list(time)
    values0 = list(voltage0)
    values1 = list(voltage1)
    if not (len(times) == len(values0) == len(values1) and times):
        raise RuntimeError("NEURON returned an invalid trace")

    arguments.output_csv.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(["time_ms", "v0_mV", "v1_mV"])
        writer.writerows(zip(times, values0, values1))

    provenance = {
        "schemaVersion": 1,
        "caseID": "electrophysiology.rallpack1",
        "simulator": "NEURON",
        "packageVersion": importlib.metadata.version("neuron"),
        "simulatorBuild": str(h.nrnversion()),
        "python": sys.version,
        "platform": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "integration": {
            "method": "fixed-step-first-order",
            "dtMilliseconds": dt,
            "sampleMilliseconds": sample_dt,
            "durationMilliseconds": duration,
        },
        "model": model,
        "input": protocol,
    }
    arguments.output_provenance.parent.mkdir(parents=True, exist_ok=True)
    arguments.output_provenance.write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
