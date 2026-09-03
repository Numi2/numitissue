#!/usr/bin/env python3
"""Pinned CPU Jaxley sidecar for bounded HH simulation and differentiable fitting."""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import Any, Mapping

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

IMPLEMENTATION = "numitissue-jaxley"
IMPLEMENTATION_VERSION = "1"
JAXLEY_VERSION = "0.13.0"
JAX_VERSION = "0.11.1"
JAXLIB_VERSION = "0.11.1"
ALLOWED_OPERATIONS = {"simulate", "fit", "validate"}
ALLOWED_PARAMETERS = {
    "HH_gNa",
    "HH_gK",
    "HH_gLeak",
    "HH_eNa",
    "HH_eK",
    "HH_eLeak",
    "HH_tadj",
    "temperature",
}
TRAINABLE_PARAMETERS = {"HH_gNa", "HH_gK", "HH_gLeak", "HH_tadj"}
ALLOWED_SOLVERS = {"bwd_euler", "fwd_euler", "crank_nicolson"}
ALLOWED_VOLTAGE_SOLVERS = {"jaxley.dhs", "jaxley.stone", "jax.sparse"}


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
            expected_sidecar="jaxley",
            allowed_operations=ALLOWED_OPERATIONS,
            implementation=IMPLEMENTATION,
            implementation_version=IMPLEMENTATION_VERSION,
            packages={
                "jaxley": JAXLEY_VERSION,
                "jax": JAX_VERSION,
                "jaxlib": JAXLIB_VERSION,
            },
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
        raise SidecarFailure("jaxley.input-count", "Jaxley operations require one model request file.")
    payload = read_json(inputs[0].path)
    specification = validate_specification(payload, request)
    operation = request.value["operation"]
    maximum_output = int(request.value["selection"]["maximumOutputBytes"])

    if operation == "validate":
        output_payload: dict[str, Any] = {
            "schemaVersion": 1,
            "inputID": inputs[0].identifier,
            "inputSHA256": inputs[0].sha256,
            "valid": True,
            "model": specification["model"],
            "simulation": specification["simulation"],
            "sampleUpperBound": specification["sampleUpperBound"],
            "trainableParameterCount": len(specification.get("trainable", [])),
        }
        output_name = "jaxley-validation.json"
        role = "validation"
        metrics = {
            "sampleUpperBound": float(specification["sampleUpperBound"]),
            "trainableParameterCount": float(len(specification.get("trainable", []))),
        }
    else:
        configure_jax(specification)
        if operation == "simulate":
            output_payload, metrics = simulate(specification, inputs[0])
            output_name = "jaxley-simulation.json"
            role = "reference-simulation"
        elif operation == "fit":
            output_payload, metrics = fit(specification, inputs[0])
            output_name = "jaxley-fit.json"
            role = "calibration"
        else:
            raise SidecarFailure("jaxley.operation", f"Unhandled operation: {operation}")

    output = output_root / output_name
    write_json_atomic(output_payload, output, maximum_output)
    artifact = make_artifact(
        path=output,
        output_root=output_root,
        logical_name=output.stem,
        role=role,
        media_type="application/json",
        metadata={
            "inputSHA256": inputs[0].sha256,
            "jaxleyVersion": JAXLEY_VERSION,
            "jaxVersion": JAX_VERSION,
            "jaxlibVersion": JAXLIB_VERSION,
            "platform": "cpu",
        },
    )
    metrics = dict(metrics)
    metrics["artifactBytes"] = float(artifact["byteCount"])
    return [artifact], [], metrics, {
        "inputSHA256": inputs[0].sha256,
        "jaxleyVersion": JAXLEY_VERSION,
        "jaxVersion": JAX_VERSION,
        "jaxlibVersion": JAXLIB_VERSION,
        "platform": "cpu",
    }


def validate_specification(payload: Any, request: LoadedRequest) -> dict[str, Any]:
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise SidecarFailure("jaxley.schema", "Jaxley input must use schemaVersion 1.")
    if payload.get("model") != "hh-single-cell":
        raise SidecarFailure("jaxley.model", "Phase 4 supports only the bounded hh-single-cell model.")
    simulation = payload.get("simulation")
    stimulus = payload.get("stimulus")
    parameters = payload.get("parameters", {})
    if not isinstance(simulation, dict) or not isinstance(stimulus, dict) or not isinstance(parameters, dict):
        raise SidecarFailure("jaxley.structure", "simulation, stimulus and parameters must be objects.")

    platform = simulation.get("platform", "cpu")
    if platform != "cpu":
        raise SidecarFailure(
            "jaxley.platform",
            "Phase 4 Jaxley execution is CPU-only; Apple GPU authority remains the NumiTissue Metal backend.",
        )
    delta_t = finite_number(simulation.get("deltaTMilliseconds"), "deltaTMilliseconds")
    duration = finite_number(simulation.get("durationMilliseconds"), "durationMilliseconds")
    if not 0.001 <= delta_t <= 1.0:
        raise SidecarFailure("jaxley.delta-t", "deltaTMilliseconds must be in 0.001...1.0.")
    if not delta_t <= duration <= 600_000:
        raise SidecarFailure("jaxley.duration", "durationMilliseconds is outside the bounded range.")
    sample_upper_bound = int(math.ceil(duration / delta_t)) + 2
    maximum_samples = int(request.value["selection"]["maximumSamplesPerSeries"])
    if sample_upper_bound > maximum_samples:
        raise SidecarFailure(
            "jaxley.samples",
            f"Simulation may produce {sample_upper_bound} samples, above maximumSamplesPerSeries={maximum_samples}.",
        )
    solver = simulation.get("solver", "bwd_euler")
    voltage_solver = simulation.get("voltageSolver", "jaxley.dhs")
    if solver not in ALLOWED_SOLVERS or voltage_solver not in ALLOWED_VOLTAGE_SOLVERS:
        raise SidecarFailure("jaxley.solver", "Requested solver or voltage solver is not allowlisted.")
    enable_x64 = simulation.get("enableX64", False)
    if not isinstance(enable_x64, bool):
        raise SidecarFailure("jaxley.x64", "enableX64 must be Boolean.")

    delay = finite_number(stimulus.get("delayMilliseconds"), "delayMilliseconds")
    stimulus_duration = finite_number(stimulus.get("durationMilliseconds"), "stimulus.durationMilliseconds")
    amplitude = finite_number(stimulus.get("amplitudeNanoamps"), "amplitudeNanoamps")
    if delay < 0 or stimulus_duration < 0 or delay + stimulus_duration > duration:
        raise SidecarFailure("jaxley.stimulus", "Stimulus interval lies outside the simulation.")
    if abs(amplitude) > 100:
        raise SidecarFailure("jaxley.stimulus", "Stimulus amplitude exceeds the 100 nA safety bound.")

    normalized_parameters: dict[str, float] = {}
    for name, value in parameters.items():
        if name not in ALLOWED_PARAMETERS:
            raise SidecarFailure("jaxley.parameter", f"Unsupported HH parameter: {name}")
        normalized_parameters[name] = finite_number(value, name)
    validate_parameter_ranges(normalized_parameters)

    result: dict[str, Any] = {
        "schemaVersion": 1,
        "model": "hh-single-cell",
        "simulation": {
            "platform": "cpu",
            "enableX64": enable_x64,
            "deltaTMilliseconds": delta_t,
            "durationMilliseconds": duration,
            "solver": solver,
            "voltageSolver": voltage_solver,
        },
        "stimulus": {
            "delayMilliseconds": delay,
            "durationMilliseconds": stimulus_duration,
            "amplitudeNanoamps": amplitude,
        },
        "parameters": normalized_parameters,
        "sampleUpperBound": sample_upper_bound,
    }

    if request.value["operation"] == "fit":
        fit_value = payload.get("fit")
        if not isinstance(fit_value, dict):
            raise SidecarFailure("jaxley.fit", "Fit operation requires a fit object.")
        target = finite_array(fit_value.get("targetVoltageMillivolts"), "targetVoltageMillivolts")
        if len(target) > maximum_samples or len(target) < 2:
            raise SidecarFailure("jaxley.target", "Target trace length is outside the declared bound.")
        trainable_source = fit_value.get("trainable")
        if not isinstance(trainable_source, list) or not trainable_source:
            raise SidecarFailure("jaxley.trainable", "fit.trainable must be nonempty.")
        maximum_records = int(request.value["selection"]["maximumRecords"])
        if len(trainable_source) > min(maximum_records, 16):
            raise SidecarFailure("jaxley.trainable", "Too many trainable parameters.")
        trainable = [validate_trainable(value, index) for index, value in enumerate(trainable_source)]
        names = [value["name"] for value in trainable]
        if len(set(names)) != len(names):
            raise SidecarFailure("jaxley.trainable", "Trainable parameter names must be unique.")
        iterations = bounded_int(fit_value.get("iterations", 100), "iterations", 1, 10_000)
        learning_rate = finite_number(fit_value.get("learningRate", 0.01), "learningRate")
        gradient_clip = finite_number(fit_value.get("gradientClip", 100.0), "gradientClip")
        history_stride = bounded_int(fit_value.get("historyStride", 1), "historyStride", 1, iterations)
        if not 0 < learning_rate <= 10 or not 0 < gradient_clip <= 1_000_000:
            raise SidecarFailure("jaxley.optimizer", "Optimizer configuration is outside the bounded range.")
        result["fit"] = {
            "targetVoltageMillivolts": target,
            "trainable": trainable,
            "iterations": iterations,
            "learningRate": learning_rate,
            "gradientClip": gradient_clip,
            "historyStride": history_stride,
        }
        result["trainable"] = names
    return result


def configure_jax(specification: Mapping[str, Any]) -> None:
    from jax import config

    config.update("jax_platform_name", "cpu")
    config.update("jax_enable_x64", bool(specification["simulation"]["enableX64"]))


def build_cell(specification: Mapping[str, Any]) -> tuple[Any, Any]:
    import jaxley as jx
    from jaxley.channels import HH

    cell = jx.Cell()
    cell.insert(HH())
    for name, value in specification["parameters"].items():
        cell.set(name, value)
    stimulus = specification["stimulus"]
    simulation = specification["simulation"]
    current = jx.step_current(
        i_delay=stimulus["delayMilliseconds"],
        i_dur=stimulus["durationMilliseconds"],
        i_amp=stimulus["amplitudeNanoamps"],
        delta_t=simulation["deltaTMilliseconds"],
        t_max=simulation["durationMilliseconds"],
    )
    cell.stimulate(current)
    cell.record("v")
    return cell, jx


def simulate(
    specification: Mapping[str, Any],
    source: VerifiedInput,
) -> tuple[dict[str, Any], dict[str, float]]:
    import jax

    cell, jx = build_cell(specification)
    simulation = specification["simulation"]
    voltage = jx.integrate(
        cell,
        delta_t=simulation["deltaTMilliseconds"],
        solver=simulation["solver"],
        voltage_solver=simulation["voltageSolver"],
    )
    voltage = jax.device_get(voltage)
    trace = extract_voltage_trace(voltage)
    time = [index * simulation["deltaTMilliseconds"] for index in range(len(trace))]
    payload = {
        "schemaVersion": 1,
        "inputID": source.identifier,
        "inputSHA256": source.sha256,
        "engine": "Jaxley",
        "engineVersion": JAXLEY_VERSION,
        "jaxVersion": JAX_VERSION,
        "jaxlibVersion": JAXLIB_VERSION,
        "model": specification["model"],
        "simulation": specification["simulation"],
        "stimulus": specification["stimulus"],
        "parameters": specification["parameters"],
        "recordings": {
            "timeMilliseconds": time,
            "voltageMillivolts": trace,
        },
    }
    return finite_json(payload), {
        "sampleCount": float(len(trace)),
        "minimumVoltageMillivolts": min(trace),
        "maximumVoltageMillivolts": max(trace),
    }


def fit(
    specification: Mapping[str, Any],
    source: VerifiedInput,
) -> tuple[dict[str, Any], dict[str, float]]:
    import jax
    import jax.numpy as jnp

    cell, jx = build_cell(specification)
    simulation = specification["simulation"]
    fit_spec = specification["fit"]
    trainable = fit_spec["trainable"]
    names = [value["name"] for value in trainable]
    lower = jnp.asarray([value["minimum"] for value in trainable])
    upper = jnp.asarray([value["maximum"] for value in trainable])
    parameters = jnp.asarray([value["initial"] for value in trainable])
    target = jnp.asarray(fit_spec["targetVoltageMillivolts"])

    def simulate_vector(vector: Any) -> Any:
        parameter_state = None
        for index, name in enumerate(names):
            parameter_state = cell.data_set(name, vector[index], parameter_state)
        result = jx.integrate(
            cell,
            param_state=parameter_state,
            delta_t=simulation["deltaTMilliseconds"],
            solver=simulation["solver"],
            voltage_solver=simulation["voltageSolver"],
        )
        return result[0]

    initial_trace = simulate_vector(parameters)
    if int(initial_trace.shape[0]) != int(target.shape[0]):
        raise SidecarFailure(
            "jaxley.target-shape",
            f"Target has {int(target.shape[0])} samples, but the model produces {int(initial_trace.shape[0])}.",
        )

    def loss_function(vector: Any) -> Any:
        residual = simulate_vector(vector) - target
        return jnp.mean(residual * residual)

    value_and_gradient = jax.jit(jax.value_and_grad(loss_function))
    history: list[dict[str, Any]] = []
    iterations = int(fit_spec["iterations"])
    learning_rate = float(fit_spec["learningRate"])
    gradient_clip = float(fit_spec["gradientClip"])
    history_stride = int(fit_spec["historyStride"])

    for iteration in range(iterations):
        loss, gradient = value_and_gradient(parameters)
        loss_value = float(jax.device_get(loss))
        gradient_value = jax.device_get(gradient)
        if not math.isfinite(loss_value):
            raise SidecarFailure("jaxley.loss", f"Loss became non-finite at iteration {iteration}.")
        if not all(math.isfinite(float(value)) for value in gradient_value):
            raise SidecarFailure("jaxley.gradient", f"Gradient became non-finite at iteration {iteration}.")
        gradient = jnp.clip(gradient, -gradient_clip, gradient_clip)
        parameters = jnp.clip(parameters - learning_rate * gradient, lower, upper)
        if iteration % history_stride == 0 or iteration == iterations - 1:
            history.append(
                {
                    "iteration": iteration,
                    "meanSquaredError": loss_value,
                    "parameters": {
                        name: float(value)
                        for name, value in zip(
                            names,
                            jax.device_get(parameters),
                            strict=True,
                        )
                    },
                }
            )

    final_loss = float(jax.device_get(loss_function(parameters)))
    final_trace = extract_voltage_trace(jax.device_get(simulate_vector(parameters)))
    fitted_parameters = {
        name: float(value)
        for name, value in zip(names, jax.device_get(parameters), strict=True)
    }
    time = [index * simulation["deltaTMilliseconds"] for index in range(len(final_trace))]
    payload = {
        "schemaVersion": 1,
        "inputID": source.identifier,
        "inputSHA256": source.sha256,
        "engine": "Jaxley",
        "engineVersion": JAXLEY_VERSION,
        "jaxVersion": JAX_VERSION,
        "jaxlibVersion": JAXLIB_VERSION,
        "model": specification["model"],
        "simulation": specification["simulation"],
        "stimulus": specification["stimulus"],
        "fixedParameters": specification["parameters"],
        "fittedParameters": fitted_parameters,
        "bounds": {
            value["name"]: [value["minimum"], value["maximum"]]
            for value in trainable
        },
        "optimizer": {
            "name": "bounded-gradient-descent",
            "iterations": iterations,
            "learningRate": learning_rate,
            "gradientClip": gradient_clip,
        },
        "finalMeanSquaredError": final_loss,
        "history": history,
        "recordings": {
            "timeMilliseconds": time,
            "voltageMillivolts": final_trace,
            "targetVoltageMillivolts": fit_spec["targetVoltageMillivolts"],
        },
    }
    return finite_json(payload), {
        "iterationCount": float(iterations),
        "finalMeanSquaredError": final_loss,
        "sampleCount": float(len(final_trace)),
    }


def validate_trainable(value: Any, ordinal: int) -> dict[str, float | str]:
    if not isinstance(value, dict):
        raise SidecarFailure("jaxley.trainable", f"Trainable parameter {ordinal} is not an object.")
    name = value.get("name")
    if name not in TRAINABLE_PARAMETERS:
        raise SidecarFailure("jaxley.trainable", f"Unsupported trainable parameter: {name!r}")
    initial = finite_number(value.get("initial"), f"trainable[{ordinal}].initial")
    minimum = finite_number(value.get("minimum"), f"trainable[{ordinal}].minimum")
    maximum = finite_number(value.get("maximum"), f"trainable[{ordinal}].maximum")
    if maximum <= minimum or not minimum <= initial <= maximum:
        raise SidecarFailure("jaxley.trainable", f"Invalid bounds for trainable parameter {name}.")
    validate_parameter_ranges({name: minimum})
    validate_parameter_ranges({name: maximum})
    return {"name": name, "initial": initial, "minimum": minimum, "maximum": maximum}


def validate_parameter_ranges(parameters: Mapping[str, float]) -> None:
    limits = {
        "HH_gNa": (0.0, 10.0),
        "HH_gK": (0.0, 10.0),
        "HH_gLeak": (0.0, 1.0),
        "HH_eNa": (-200.0, 200.0),
        "HH_eK": (-200.0, 200.0),
        "HH_eLeak": (-200.0, 200.0),
        "HH_tadj": (0.0, 100.0),
        "temperature": (-273.15, 200.0),
    }
    for name, value in parameters.items():
        lower, upper = limits[name]
        if not lower <= value <= upper:
            raise SidecarFailure("jaxley.parameter-range", f"{name}={value} is outside {lower}...{upper}.")


def extract_voltage_trace(value: Any) -> list[float]:
    if hasattr(value, "tolist"):
        value = value.tolist()
    while isinstance(value, list) and len(value) == 1 and isinstance(value[0], list):
        value = value[0]
    if not isinstance(value, list) or not value:
        raise SidecarFailure("jaxley.output", "Jaxley produced no voltage trace.")
    result: list[float] = []
    for ordinal, item in enumerate(value):
        if isinstance(item, list):
            raise SidecarFailure("jaxley.output", "Expected one recorded voltage trace.")
        numeric = float(item)
        if not math.isfinite(numeric):
            raise SidecarFailure("jaxley.output", f"Voltage sample {ordinal} is non-finite.")
        result.append(numeric)
    return result


def finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise SidecarFailure("jaxley.number", f"{name} must be numeric.")
    result = float(value)
    if not math.isfinite(result):
        raise SidecarFailure("jaxley.number", f"{name} must be finite.")
    return result


def finite_array(value: Any, name: str) -> list[float]:
    if not isinstance(value, list):
        raise SidecarFailure("jaxley.array", f"{name} must be an array.")
    return [finite_number(item, f"{name}[{index}]") for index, item in enumerate(value)]


def bounded_int(value: Any, name: str, lower: int, upper: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not lower <= value <= upper:
        raise SidecarFailure("jaxley.integer", f"{name} must be an integer in {lower}...{upper}.")
    return value


if __name__ == "__main__":
    raise SystemExit(main())
