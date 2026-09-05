#!/usr/bin/env python3
"""Bounded CL SDK SIMULATOR bridge; intentionally refuses physical CL1 before cl.open.

Public CL API does not establish the independently measured voltage, device-death watchdog,
atomic deadline rejection and operator authority required by GuardedNeuralCultureSession.
A Python event-loop timeout is NOT autonomous hardware shutdown. This bridge tests SDK semantics;
no flag, JSON boolean, environment variable or manual Swift method enables physical operation.
"""
from __future__ import annotations

import hashlib
import importlib
import json
import math
import os
import select
import sys
import time
import uuid
from collections import Counter
from dataclasses import dataclass, field
from typing import Any

MAX_LINE = 1_048_576
MAX_REQUESTS = 10_000
MAX_READ_FRAMES = 250_000
MAX_UINT64 = (1 << 64) - 1


def fail(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "code": code, "message": message}


def integer(value: Any, name: str, low: int = 0, high: int = MAX_UINT64) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"invalid integer {name}")
    return value


def encoded(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


@dataclass
class State:
    sdk: Any
    neurons: Any
    identity: dict[str, Any]
    phase: str = "idle"
    armed_until_frame: int = 0
    watchdog_ns: int = 0
    last_refresh_ns: int = 0
    last_frame: int = 0
    requests: dict[str, dict[str, Any]] = field(default_factory=dict)
    channel_until: dict[int, int] = field(default_factory=dict)

    def require_simulator(self) -> None:
        if self.sdk.is_simulator() is not True:
            self.phase = "stopped"
            raise RuntimeError("physical CL1 is unsupported by this simulator bridge")

    def device_frame(self) -> int:
        value = integer(int(self.neurons.timestamp()), "device timestamp")
        if value < self.last_frame:
            self.phase = "stopped"
            raise RuntimeError("device clock reset; new process/session required")
        self.last_frame = value
        return value

    def frame_us(self) -> int:
        value = float(self.neurons.get_frame_duration_us())
        if not math.isfinite(value) or value <= 0 or value > 1_000_000 or not value.is_integer():
            raise RuntimeError("unrepresentable CL frame duration")
        return int(value)

    def channel_count(self) -> int:
        return integer(int(self.neurons.get_channel_count()), "channels", 1, 4096)

    def stop(self, reason: str) -> dict[str, Any]:
        self.phase = "stopped"  # Latch before any possibly failing SDK operation.
        self.armed_until_frame = 0
        errors = []
        try:
            count = self.channel_count()
        except Exception as exc:
            return {"ok": False, "stop_confirmed": False, "code": "channel_query_failed", "message": str(exc)}
        for channel in range(count):
            try:
                self.neurons.interrupt(channel)
            except Exception as exc:
                errors.append({"channel": channel, "error": str(exc)[:256]})
        return {"ok": not errors, "stop_confirmed": not errors,
                "simulator": True, "physical_stop_verified": False,
                "code": "interrupt_failed" if errors else None,
                "message": reason[:1024], "errors": errors, "frame": self.last_frame}

    def check_expiry(self) -> None:
        if self.phase != "armed":
            return
        if (time.monotonic_ns() - self.last_refresh_ns >= self.watchdog_ns
                or self.device_frame() >= self.armed_until_frame):
            self.stop("simulator host timeout or arm expiry")
            raise RuntimeError("simulator lease expired; rearming is prohibited")


def parse_schedule(payload: dict[str, Any], state: State) -> tuple[list[tuple[int, Any]], int, int, list[dict[str, int]]]:
    pulses = payload.get("pulses")
    if not isinstance(pulses, list) or not 1 <= len(pulses) <= 64:
        raise ValueError("1..64 pulses required")
    starts: set[int] = set()
    channels: set[int] = set()
    operations = []
    expected = []
    latest = 0
    frame_us = state.frame_us()
    for pulse in pulses:
        if not isinstance(pulse, dict) or set(pulse) != {"channel", "timestamp_frames", "phases"}:
            raise ValueError("unknown or missing pulse fields")
        channel = integer(pulse["channel"], "channel", 0, state.channel_count() - 1)
        if channel in channels:
            raise ValueError("duplicate channel would serialize SDK operations rather than stimulate concurrently")
        channels.add(channel)
        start = integer(pulse["timestamp_frames"], "start frame")
        starts.add(start)
        phases = pulse["phases"]
        # StimDesign accepts width/current pairs; a biphasic pulse is TWO phases, FOUR arguments.
        if not isinstance(phases, list) or len(phases) not in (2, 3):
            raise ValueError("only balanced bi/triphasic simulator waveforms are supported")
        arguments = []
        duration = 0
        signed = absolute = 0.0
        for phase in phases:
            if not isinstance(phase, dict) or set(phase) != {"duration_us", "current_ua"}:
                raise ValueError("phase fields")
            width = integer(phase["duration_us"], "phase width", 20, 20_000)
            current = phase["current_ua"]
            if type(current) not in (float, int) or not math.isfinite(current) or abs(current) > 3.0 or width % 20:
                raise ValueError("unrepresentable simulator waveform")
            current = float(current)
            duration += width
            signed += current * width
            absolute += abs(current) * width
            arguments.extend((width, current))
        if absolute == 0 or abs(signed) > absolute * 1e-6:
            raise ValueError("simulator pulse must be charge balanced")
        end = start + (duration + frame_us - 1) // frame_us
        if end > MAX_UINT64 or start < state.channel_until.get(channel, 0):
            raise ValueError("timestamp overflow or channel overlap")
        latest = max(latest, end)
        operations.append((channel, state.sdk.StimDesign(*arguments)))
        expected.append({"timestamp": start, "channel": channel})
    if len(starts) != 1:
        raise ValueError("one exact shared start frame per request; no reordered or mixed starts")
    return operations, next(iter(starts)), latest, sorted(expected, key=lambda x: x["channel"])


def response_item(item: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in item.items() if key != "payload_sha256"}


def handle(state: State, request: dict[str, Any]) -> dict[str, Any]:
    state.require_simulator()
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    op = request.get("op")
    if op == "identity":
        return {"ok": True, "identity": state.identity, "frame": state.device_frame(),
                "frame_duration_us": state.frame_us(), "channels": state.channel_count(),
                "simulator": True, "physical_stimulation_supported": False,
                "autonomous_hardware_watchdog": False, "measured_voltage": None,
                "measured_temperature": None}
    if op == "arm-simulator":
        if state.phase != "idle":
            return fail("latched", "arming is one-shot per simulator session")
        until = integer(request.get("armed_until_frame"), "arm expiry")
        watchdog = integer(request.get("watchdog_ns"), "simulator timeout", 1_000_000, 1_000_000_000)
        now = state.device_frame()
        if until <= now or (until - now) * state.frame_us() > 60_000_000:
            return fail("invalid_lease", "simulator lease must be future and bounded to 60 seconds")
        state.phase = "armed"
        state.armed_until_frame = until
        state.watchdog_ns = watchdog
        state.last_refresh_ns = time.monotonic_ns()
        return {"ok": True, "simulator": True, "frame": now, "armed_until_frame": until}
    if op == "stop":
        return state.stop(str(request.get("reason", "requested")))
    if op == "watchdog.refresh":
        state.check_expiry()
        if state.phase != "armed":
            return fail("latched", "not armed")
        state.last_refresh_ns = time.monotonic_ns()
        return {"ok": True, "frame": state.device_frame(), "armed_until_frame": state.armed_until_frame}
    if op in ("stim.status", "stim.observe"):
        rid = str(uuid.UUID(str(request["id"])))
        item = state.requests.get(rid)
        if item is None:
            return fail("unknown_request", "request ID is unknown; never resubmit after process restart")
        if op == "stim.status" or item["status"] == "executed":
            return {"ok": True, **response_item(item)}
        now = state.device_frame()
        start = item["scheduled_frame"]
        if now < item["end_frame"]:
            return {"ok": True, **response_item(item)}
        count = now - start  # CL stop_timestamp is exclusive; do not block awaiting a future frame.
        if not 1 <= count <= MAX_READ_FRAMES:
            return fail("analysis_window_unavailable", "bounded recorded delivery window is unavailable")
        analysis = state.neurons.read(count, start, analysis=True)
        if int(analysis.start_timestamp) != start or int(analysis.stop_timestamp) != now:
            return fail("analysis_window_mismatch", "SDK returned a different analysis interval")
        observed = [{"timestamp": int(x.timestamp), "channel": int(x.channel)} for x in analysis.stims]
        # Every requested electrode must occur exactly once at the requested timestamp. Unrelated
        # stims, duplicate stims and partial delivery cannot authorize an executed receipt.
        actual = Counter((x["timestamp"], x["channel"]) for x in observed)
        expected = Counter((x["timestamp"], x["channel"]) for x in item["expected_stims"])
        item["observed_stims"] = observed
        item["status"] = "executed" if actual == expected else "unknown"
        item["delivery"] = "sdk_event_match_only" if actual == expected else "missing_extra_or_mismatched_events"
        return {"ok": True, **response_item(item)}
    if op == "stim.submit":
        rid = str(uuid.UUID(str(request["id"])))
        digest = hashlib.sha256(encoded({k: v for k, v in request.items() if k != "id"})).hexdigest()
        if rid in state.requests:
            if state.requests[rid]["payload_sha256"] != digest:
                return fail("id_conflict", "same ID with different pulse content")
            return {"ok": True, **response_item(state.requests[rid])}
        state.check_expiry()
        if state.phase != "armed":
            return fail("latched", "simulator is not armed")
        if len(state.requests) >= MAX_REQUESTS:
            return fail("capacity", "session request budget exceeded")
        operations, start, end, expected = parse_schedule(request, state)
        deadline = integer(request.get("deadline_frame"), "completion deadline")
        now = state.device_frame()
        lead = (80 + state.frame_us() - 1) // state.frame_us()
        if start < now + lead or end > deadline or end > state.armed_until_frame:
            return fail("late_or_unarmed", "request is outside its complete waveform/lease deadline")
        plan = state.neurons.create_stim_plan()
        # Do not interrupt previous accepted work merely to submit a new plan.
        for channel, design in operations:
            plan.stim(channel, design, lead_time_us=80)
        now = state.device_frame()
        if start < now + lead:
            return fail("late", "plan creation consumed the lead budget; no run call")
        item = {"id": rid, "payload_sha256": digest, "status": "unknown", "accepted_frame": now,
                "scheduled_frame": start, "end_frame": end, "expected_stims": expected,
                "delivery": "submission_intent", "simulator": True}
        # Reserve identity BEFORE the SDK call, including paths where it performs work then throws.
        state.requests[rid] = item
        for channel, _ in operations:
            state.channel_until[channel] = end
        try:
            plan.run(at_timestamp=start)
        except Exception:
            state.stop("SDK submission acknowledgement lost or rejected")
            raise
        item["status"] = "accepted"
        item["delivery"] = "pending_sdk_event_reconciliation"
        return {"ok": True, **response_item(item)}
    return fail("unsupported_operation", str(op))


def strict_json(raw: bytes) -> dict[str, Any]:
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    def reject(value):
        raise ValueError(f"nonfinite JSON number {value}")
    value = json.loads(raw, object_pairs_hook=pairs, parse_constant=reject)
    if not isinstance(value, dict):
        raise ValueError("JSON object required")
    return value


def serve(state: State, fd: int = 0) -> int:
    pending = bytearray()
    while True:
        try:
            state.check_expiry()
        except Exception:
            pass  # Latched by check_expiry; status and stop remain available, never rearm.
        readable, _, _ = select.select([fd], [], [], 0.01)
        if not readable:
            continue
        chunk = os.read(fd, min(65_536, MAX_LINE + 1 - len(pending)))
        if not chunk:
            if pending:
                print(encoded(fail("truncated_request", "EOF before newline")).decode(), flush=True)
            return 0
        pending.extend(chunk)
        if len(pending) > MAX_LINE:
            state.stop("oversized input")
            return 65
        while b"\n" in pending:
            raw, _, rest = pending.partition(b"\n")
            pending = bytearray(rest)
            try:
                response = handle(state, strict_json(raw))
            except Exception as exc:
                stopped = state.stop(f"request failed: {exc}")
                response = {**fail("request_failed", f"{type(exc).__name__}: {exc}"),
                            "stop_confirmed": stopped["stop_confirmed"]}
            output = encoded(response)
            if len(output) > MAX_LINE:
                state.stop("response budget exceeded")
                output = encoded(fail("response_too_large", "response exceeded budget"))
            print(output.decode(), flush=True)


def main() -> int:
    sdk = importlib.import_module("cl")
    # This check precedes taking control, clearing queues, opening or otherwise writing to a device.
    if sdk.is_simulator() is not True:
        print(encoded(fail("physical_backend_not_qualified",
            "This bridge supports CL SDK Simulator only; independently enforced hardware interlocks are unimplemented.")).decode())
        return 78
    identity = dict(sdk.get_system_attributes())
    with sdk.open(take_control=True, wait_until_recordable=True) as neurons:
        state = State(sdk=sdk, neurons=neurons, identity=identity)
        try:
            return serve(state)
        finally:
            result = state.stop("simulator sidecar exit")
            if not result["stop_confirmed"]:
                print(encoded(result).decode(), file=sys.stderr, flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
