"""Dependency-free source tests using an SDK double, not CL hardware or biological evidence."""
from __future__ import annotations
import importlib.util
import io
from pathlib import Path
import sys
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("numitissue_cl1_test_module", Path(__file__).with_name("cl1_sidecar.py"))
if spec is None or spec.loader is None:
    raise RuntimeError("missing CL1 sidecar source")
bridge = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = bridge
spec.loader.exec_module(bridge)


class SDK:
    is_simulator = staticmethod(lambda: True)
    StimDesign = staticmethod(lambda *args: args)


class Neurons:
    def __init__(self):
        self.now = 100
        self.calls = 0
        self.interrupts = []
        self.ack_loss = False
        self.stop_error = False
        self.events = []

    def timestamp(self): return self.now
    def get_frame_duration_us(self): return 40
    def get_channel_count(self): return 64

    def interrupt(self, channel):
        self.interrupts.append(channel)
        if self.stop_error and channel == 1:
            raise RuntimeError("injected interrupt failure")

    def create_stim_plan(self):
        owner = self
        class Plan:
            def stim(self, channel, design, lead_time_us): pass
            def run(self, at_timestamp):
                owner.calls += 1
                if owner.ack_loss:
                    raise RuntimeError("accepted then acknowledgement lost")
        return Plan()

    def read(self, count, start, analysis):
        return SimpleNamespace(start_timestamp=start, stop_timestamp=start + count,
                               stims=[SimpleNamespace(timestamp=t, channel=c) for t, c in self.events])


class CL1BridgeTests(unittest.TestCase):
    def state(self):
        neurons = Neurons()
        state = bridge.State(sdk=SDK, neurons=neurons, identity={"system_id": "fixture"})
        response = bridge.handle(state, {"op": "arm-simulator", "armed_until_frame": 10_000,
                                         "watchdog_ns": 1_000_000_000})
        self.assertTrue(response["ok"])
        return state

    def request(self, channels=(1, 2)):
        return {"op": "stim.submit", "id": "00000000-0000-4000-8000-000000000001",
                "deadline_frame": 300,
                "pulses": [{"channel": channel, "timestamp_frames": 200,
                            "phases": [{"duration_us": 100, "current_ua": -1.0},
                                       {"duration_us": 100, "current_ua": 1.0}]} for channel in channels]}

    def test_physical_refusal_precedes_open_or_interrupt(self):
        fake = SimpleNamespace(is_simulator=lambda: False,
                               open=lambda **kwargs: self.fail("must not take physical control"))
        with patch.object(bridge.importlib, "import_module", return_value=fake), patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(bridge.main(), 78)

    def test_idle_timeout_latches_and_interrupts_without_a_new_submit(self):
        state = self.state()
        state.last_refresh_ns = time.monotonic_ns() - state.watchdog_ns - 1
        with self.assertRaises(RuntimeError): state.check_expiry()
        self.assertEqual(state.phase, "stopped")
        self.assertEqual(len(state.neurons.interrupts), 64)
        response = bridge.handle(state, {"op": "arm-simulator", "armed_until_frame": 20_000, "watchdog_ns": 10_000_000})
        self.assertFalse(response["ok"])

    def test_failed_interrupt_is_not_confirmed_stop(self):
        state = self.state(); state.neurons.stop_error = True
        response = bridge.handle(state, {"op": "stop"})
        self.assertFalse(response["ok"])
        self.assertFalse(response["stop_confirmed"])
        self.assertEqual(state.phase, "stopped")

    def test_ack_loss_reserves_id_and_never_resends(self):
        state = self.state(); state.neurons.ack_loss = True
        request = self.request()
        with self.assertRaises(RuntimeError): bridge.handle(state, request)
        self.assertEqual(state.neurons.calls, 1)
        response = bridge.handle(state, request)
        self.assertEqual(response["status"], "unknown")
        self.assertEqual(state.neurons.calls, 1)
        self.assertEqual(state.phase, "stopped")

    def test_same_id_with_modified_content_is_rejected(self):
        state = self.state(); request = self.request()
        bridge.handle(state, request)
        request["deadline_frame"] = 400
        response = bridge.handle(state, request)
        self.assertEqual(response["code"], "id_conflict")
        self.assertEqual(state.neurons.calls, 1)

    def test_decreasing_mixed_start_frames_are_rejected(self):
        state = self.state(); request = self.request()
        request["pulses"][1]["timestamp_frames"] = 199
        with self.assertRaises(ValueError): bridge.handle(state, request)
        self.assertEqual(state.neurons.calls, 0)

    def test_duplicate_channels_cannot_be_mislabeled_concurrent(self):
        state = self.state()
        with self.assertRaises(ValueError): bridge.handle(state, self.request(channels=(1, 1)))
        self.assertEqual(state.neurons.calls, 0)

    def test_partial_unrelated_and_duplicate_receipts_are_not_delivery(self):
        for events in ([(200, 1)], [(200, 1), (200, 3)], [(200, 1), (200, 1)], [(201, 1), (201, 2)]):
            state = self.state(); request = self.request()
            bridge.handle(state, request); state.neurons.now = 250; state.neurons.events = events
            response = bridge.handle(state, {"op": "stim.observe", "id": request["id"]})
            self.assertEqual(response["status"], "unknown")

    def test_exact_complete_receipt_is_sdk_evidence_only(self):
        state = self.state(); request = self.request()
        bridge.handle(state, request); state.neurons.now = 250
        state.neurons.events = [(200, 2), (200, 1)]
        response = bridge.handle(state, {"op": "stim.observe", "id": request["id"]})
        self.assertEqual(response["status"], "executed")
        self.assertEqual(response["delivery"], "sdk_event_match_only")
        self.assertTrue(response["simulator"])

    def test_deadline_covers_entire_pulse_not_only_start(self):
        state = self.state(); request = self.request(); request["deadline_frame"] = 201
        response = bridge.handle(state, request)
        self.assertFalse(response["ok"])
        self.assertEqual(state.neurons.calls, 0)

    def test_nonfinite_and_duplicate_json_are_rejected(self):
        for raw in (b'{"op":"identity","op":"stop"}', b'{"x":NaN}', b'{"x":Infinity}'):
            with self.assertRaises(ValueError): bridge.strict_json(raw)
        with self.assertRaises(ValueError): bridge.integer(True, "boolean-is-not-an-integer")

    def test_frame_reset_latches_session(self):
        state = self.state(); state.neurons.now = 99
        with self.assertRaises(RuntimeError): state.device_frame()
        self.assertEqual(state.phase, "stopped")


if __name__ == "__main__":
    unittest.main()
