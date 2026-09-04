#!/usr/bin/env python3
"""CL1 device-local sidecar for NumiTissue Phase 7.

Uses the documented CL API only. The sidecar is intentionally single-session and requires an
operator-issued arm lease before any stimulation. It never converts a late request into immediate
stimulation. JSON lines are read from stdin and responses are written to stdout.

This source must be reviewed and exercised against the CL SDK Simulator before a physical CL1.
"""
from __future__ import annotations

import json
import os
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import cl
from cl import ChannelSet, StimDesign

MAX_LINE = 1_048_576
MAX_CHANNELS_PER_REQUEST = 64
MAX_PHASES = 6


def fail(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "code": code, "message": message}


def now_monotonic_ns() -> int:
    return time.monotonic_ns()


@dataclass
class State:
    neurons: Any
    identity: dict[str, Any]
    armed_until_frame: int = 0
    watchdog_ns: int = 0
    last_refresh_host_ns: int = 0
    stopped: bool = True
    requests: dict[str, dict[str, Any]] = field(default_factory=dict)
    observed_stims: dict[str, list[dict[str, Any]]] = field(default_factory=dict)

    def device_frame(self) -> int:
        value = int(self.neurons.timestamp())
        if value < 0:
            raise RuntimeError("negative CL1 timestamp")
        return value

    def frame_us(self) -> int:
        value = float(self.neurons.get_frame_duration_us())
        rounded = int(round(value))
        if value <= 0 or abs(value - rounded) > 1e-9:
            raise RuntimeError("CL1 frame duration is not an integral microsecond value")
        return rounded

    def enforce_watchdog(self) -> None:
        if self.stopped:
            return
        if self.watchdog_ns <= 0 or now_monotonic_ns() - self.last_refresh_host_ns > self.watchdog_ns:
            self.emergency_stop("device-local host watchdog expired")
            raise RuntimeError("watchdog expired")

    def emergency_stop(self, reason: str) -> None:
        # CL API interrupt clears existing and pending stimulation on selected channels.
        # Interrupt every reported channel; never assume context close stops the device.
        count = int(self.neurons.get_channel_count())
        for channel in range(count):
            try:
                self.neurons.interrupt(channel)
            except Exception:
                pass
        self.stopped = True
        self.armed_until_frame = 0
        self.last_refresh_host_ns = 0


def parse_schedule(payload: dict[str, Any], state: State) -> tuple[list[tuple[int, StimDesign]], int]:
    pulses = payload.get("pulses")
    if not isinstance(pulses, list) or not pulses or len(pulses) > MAX_CHANNELS_PER_REQUEST:
        raise ValueError("bounded nonempty pulses required")
    frame_us = state.frame_us()
    operations: list[tuple[int, StimDesign]] = []
    first_frame: int | None = None
    for pulse in pulses:
        channel = int(pulse["channel"])
        if channel < 0 or channel >= int(state.neurons.get_channel_count()):
            raise ValueError("channel outside device range")
        at_frame = int(pulse["timestamp_frames"])
        phases = pulse["phases"]
        if not isinstance(phases, list) or len(phases) not in (2, 4, 6) or len(phases) > MAX_PHASES:
            raise ValueError("CL1 StimDesign requires 2, 4 or 6 width/current arguments")
        args: list[float | int] = []
        for phase in phases:
            width_us = int(phase["duration_us"])
            current_ua = float(phase["current_ua"])
            if width_us <= 0 or width_us % 20 != 0 or not (-3.0 <= current_ua <= 3.0):
                raise ValueError("CL1 phase outside documented width/current representation")
            args.extend((width_us, current_ua))
        design = StimDesign(*args)
        operations.append((channel, design))
        first_frame = at_frame if first_frame is None else min(first_frame, at_frame)
        # Current CL API StimPlan has one run timestamp for its queued operations. NumiTissue
        # therefore admits only schedules whose pulses share one start frame in this adapter.
        if at_frame != first_frame:
            raise ValueError("multi-start schedule requires multiple independently admitted requests")
    assert first_frame is not None
    if first_frame * frame_us < 0:
        raise ValueError("timestamp overflow")
    return operations, first_frame


def handle(state: State, request: dict[str, Any]) -> dict[str, Any]:
    op = request.get("op")
    if op == "identity":
        return {"ok": True, "identity": state.identity, "frame": state.device_frame(),
                "frame_duration_us": state.frame_us(), "channels": int(state.neurons.get_channel_count()),
                "simulator": bool(cl.is_simulator())}
    if op == "arm":
        if not bool(request.get("operator_approved", False)):
            return fail("approval_required", "operator approval is required")
        until = int(request["armed_until_frame"])
        watchdog_ns = int(request["watchdog_ns"])
        now = state.device_frame()
        if until <= now or watchdog_ns <= 0 or watchdog_ns > 1_000_000_000:
            return fail("invalid_lease", "bounded future lease and <=1s watchdog required")
        state.armed_until_frame = until
        state.watchdog_ns = watchdog_ns
        state.last_refresh_host_ns = now_monotonic_ns()
        state.stopped = False
        return {"ok": True, "frame": now, "armed_until_frame": until, "watchdog_ns": watchdog_ns}
    if op == "watchdog.refresh":
        state.enforce_watchdog()
        if state.device_frame() >= state.armed_until_frame:
            state.emergency_stop("arm lease expired")
            return fail("lease_expired", "arm lease expired")
        state.last_refresh_host_ns = now_monotonic_ns()
        return {"ok": True, "frame": state.device_frame(), "armed_until_frame": state.armed_until_frame,
                "watchdog_ns": state.watchdog_ns}
    if op == "stop":
        state.emergency_stop(str(request.get("reason", "requested")))
        return {"ok": True, "stop_confirmed": True, "frame": state.device_frame()}
    if op == "stim.status":
        rid = str(request["id"])
        item = state.requests.get(rid)
        if item is None:
            return fail("unknown_request", "request id is unknown")
        return {"ok": True, **item}
    if op == "stim.submit":
        state.enforce_watchdog()
        rid = str(uuid.UUID(str(request["id"])))
        if rid in state.requests:
            # Idempotency is status lookup, never a second SDK call.
            return {"ok": True, **state.requests[rid]}
        operations, at_frame = parse_schedule(request, state)
        now = state.device_frame()
        minimum_lead_frames = (80 + state.frame_us() - 1) // state.frame_us()
        if at_frame < now + minimum_lead_frames or at_frame >= state.armed_until_frame:
            return fail("late_or_unarmed", "request is late or outside arm lease; not submitted")
        plan = state.neurons.create_stim_plan()
        channels = ChannelSet([channel for channel, _ in operations])
        plan.channels_to_interrupt = channels
        for channel, design in operations:
            plan.stim(channel, design, lead_time_us=80)
        # CL API documents absolute StimPlan.run(at_timestamp=...). We checked it remains future.
        plan.run(at_timestamp=at_frame)
        state.requests[rid] = {"id": rid, "status": "accepted", "accepted_frame": now,
                               "scheduled_frame": at_frame, "delivery": "pending_observation"}
        return {"ok": True, **state.requests[rid]}
    if op == "stim.observe":
        # Reconcile from CL analysis, not merely the enqueue acknowledgement.
        rid = str(request["id"])
        item = state.requests.get(rid)
        if item is None:
            return fail("unknown_request", "request id is unknown")
        scheduled = int(item["scheduled_frame"])
        now = state.device_frame()
        if now <= scheduled:
            return {"ok": True, **item}
        analysis = state.neurons.read(max(1, now - scheduled + 1), scheduled, analysis=True)
        observed = [{"timestamp": int(stim.timestamp), "channel": int(stim.channel)} for stim in analysis.stims]
        item = dict(item)
        item["observed_stims"] = observed
        item["status"] = "executed" if observed else "unknown"
        item["delivery"] = "observed" if observed else "not_observed_in_requested_window"
        state.requests[rid] = item
        return {"ok": True, **item}
    return fail("unknown_operation", str(op))


def main() -> int:
    attrs = cl.get_system_attributes()
    identity = {"system_id": str(attrs.get("system_id", "")), "chip_id": str(attrs.get("chip_id", "")),
                "cell_batch_id": str(attrs.get("cell_batch_id", "")), "hostname": str(attrs.get("hostname", ""))}
    with cl.open(take_control=True, wait_until_recordable=True) as neurons:
        state = State(neurons=neurons, identity=identity)
        # Start from known no-stimulation state.
        state.emergency_stop("sidecar startup")
        try:
            for raw in sys.stdin.buffer:
                if len(raw) > MAX_LINE:
                    print(json.dumps(fail("request_too_large", "line exceeds bound")), flush=True)
                    continue
                try:
                    request = json.loads(raw)
                    response = handle(state, request)
                except Exception as exc:
                    try:
                        state.emergency_stop(f"request failure: {exc}")
                    finally:
                        response = fail("exception", f"{type(exc).__name__}: {exc}")
                print(json.dumps(response, sort_keys=True, separators=(",", ":")), flush=True)
        finally:
            state.emergency_stop("sidecar exit")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
