"""Privilege-free checks for managed Copper wire qualification."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


BENCHMARK = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCHMARK))
SPEC = importlib.util.spec_from_file_location("run_copper_rtc", BENCHMARK / "run_copper_rtc.py")
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class WireLatencyQualificationTests(unittest.TestCase):
    @staticmethod
    def physical() -> dict:
        summary = {"count": 2, "min": 100.0, "p50": 150.0,
                   "p99": 199.0, "max": 200.0}
        return {name: dict(summary) for name in (
            "first_wfs_packet_to_dm_us", "terminal_wfs_packet_to_dm_us",
            "source_first_to_terminal_us")}

    def test_accepts_complete_positive_latencies(self) -> None:
        RUNNER.require_physical_latencies(self.physical(), 2)

    def test_rejects_impossible_or_incomplete_latencies(self) -> None:
        for field, value in (("min", -1.0), ("p99", float("nan")),
                             ("max", float("inf")), ("count", 1)):
            with self.subTest(field=field, value=value):
                physical = self.physical()
                physical["terminal_wfs_packet_to_dm_us"][field] = value
                with self.assertRaises(RuntimeError):
                    RUNNER.require_physical_latencies(physical, 2)


if __name__ == "__main__":
    unittest.main()
