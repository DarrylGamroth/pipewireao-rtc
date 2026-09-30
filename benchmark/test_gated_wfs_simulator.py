"""Small contract checks for the opt-in synchronized WFS gate."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


BENCHMARK = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCHMARK))
SPEC = importlib.util.spec_from_file_location(
    "gated_wfs_simulator", BENCHMARK / "gated_wfs_simulator.py")
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class GatedWfsTests(unittest.TestCase):
    def test_requires_exact_source_options(self) -> None:
        self.assertEqual(GATE.option(["-period", "0.002", "-numFrames", "3"], "-period"),
                         "0.002")
        with self.assertRaisesRegex(RuntimeError, "exactly one -period"):
            GATE.option(["-numFrames", "3"], "-period")
        with self.assertRaisesRegex(RuntimeError, "exactly one -period"):
            GATE.option(["-period", "0.002", "-period", "0.003"], "-period")

    def test_trigger_schedule_identity_and_monotonicity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "triggers.csv"
            path.write_text("frame,target_monotonic_ns,actual_monotonic_ns\n"
                            "0,100000,100005\n1,200000,200006\n2,300000,300007\n")
            summary = GATE.trigger_summary(path, 3, 10000)
            self.assertEqual(summary["count"], 3)
            self.assertEqual(summary["max_absolute_lateness_ns"], 7)
            path.write_text("frame,target_monotonic_ns,actual_monotonic_ns\n"
                            "0,100000,100005\n2,200000,200006\n")
            with self.assertRaisesRegex(RuntimeError, "expected 3 trigger records"):
                GATE.trigger_summary(path, 3, 10000)
            with self.assertRaisesRegex(RuntimeError, "wrong identity"):
                GATE.trigger_summary(path, 2, 10000)
            path.write_text("frame,target_monotonic_ns,actual_monotonic_ns\n"
                            "0,100000,100005\n1,210000,210006\n")
            with self.assertRaisesRegex(RuntimeError, "rational rate"):
                GATE.trigger_summary(path, 2, 10000)
            path.write_text("frame,target_monotonic_ns,actual_monotonic_ns\n"
                            "0,100000,99999\n")
            with self.assertRaisesRegex(RuntimeError, "before its scheduled"):
                GATE.trigger_summary(path, 1, 10000)

    def test_rejects_unplaced_thread_before_release(self) -> None:
        snapshot = {"threads": [{"tid": 10, "affinity": [12], "affinity_list": "12",
                                 "scheduler": {"policy": "fifo", "priority": 20}}]}
        with patch.object(GATE, "snapshot_process", return_value=snapshot):
            self.assertIs(GATE.verified_snapshot(10, {12}, ("fifo", 20)), snapshot)
            with self.assertRaisesRegex(RuntimeError, "expected \\[14\\]"):
                GATE.verified_snapshot(10, {14}, ("fifo", 20))
            with self.assertRaisesRegex(RuntimeError, "expected \\('fifo', 21\\)"):
                GATE.verified_snapshot(10, {12}, ("fifo", 21))

    def test_signal_during_child_launch_reaps_child(self) -> None:
        original_popen = subprocess.Popen
        previous_term = signal.getsignal(signal.SIGTERM)
        previous_int = signal.getsignal(signal.SIGINT)
        started = []

        def interrupting_popen(_argv, **kwargs):
            child = original_popen(["/bin/sleep", "30"], **kwargs)
            started.append(child)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        try:
            with tempfile.TemporaryDirectory() as temporary:
                report = Path(temporary) / "gate.json"
                environment = {
                    "PIPEWIREAO_RTC_WFS_REAL": "/bin/true",
                    "PIPEWIREAO_RTC_WFS_PACER": "/bin/sleep",
                    "PIPEWIREAO_RTC_WFS_GATE_REPORT": str(report),
                    "PIPEWIREAO_RTC_WFS_SOURCE_CPUS": str(min(os.sched_getaffinity(0))),
                    "PIPEWIREAO_RTC_WFS_SOURCE_POLICY": "other",
                }
                with patch.dict(os.environ, environment), patch.object(
                        GATE.subprocess, "Popen", side_effect=interrupting_popen):
                    self.assertEqual(GATE.main(["-numFrames", "1", "-period", "0.01"]), 1)
                self.assertFalse(json.loads(report.read_text())["qualified"])
            self.assertEqual(len(started), 1)
            self.assertIsNotNone(started[0].poll())
            self.assertTrue(started[0].stdin.closed)
            self.assertTrue(started[0].stdout.closed)
        finally:
            signal.signal(signal.SIGTERM, previous_term)
            signal.signal(signal.SIGINT, previous_int)
            for child in started:
                if child.poll() is None:
                    child.kill()
                    child.wait()


if __name__ == "__main__":
    unittest.main()
