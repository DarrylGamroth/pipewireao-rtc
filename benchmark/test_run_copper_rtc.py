"""Privilege-free checks for managed Copper wire qualification."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

import numpy as np


BENCHMARK = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCHMARK))
SPEC = importlib.util.spec_from_file_location("run_copper_rtc", BENCHMARK / "run_copper_rtc.py")
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class WireLatencyQualificationTests(unittest.TestCase):
    def test_algorithm_comparison_rejects_missing_nonfinite_and_different_values(self) -> None:
        reference = np.array([0.1, -0.2], dtype=np.float32)
        self.assertEqual(RUNNER.compare_algorithm_output(reference, reference, 1, 2,
                                                         "correction"), 0.0)
        for actual, expected in (
            (reference[:1], reference),
            (np.array([np.nan, -0.2], dtype=np.float32), reference),
            (reference, np.array([np.inf, -0.2], dtype=np.float32)),
            (np.array([0.1, -0.3], dtype=np.float32), reference),
        ):
            with self.subTest(actual=actual, expected=expected):
                with self.assertRaises(RuntimeError):
                    RUNNER.compare_algorithm_output(actual, expected, 1, 2,
                                                    "correction")

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

    def test_requires_complete_memory_record(self) -> None:
        record = {"observed": {
            "page_backing": {"available": True, "complete": True, "mappings": 2,
                             "kilobytes": {"Rss": 12},
                             "resident_by_kernel_page_size_kilobytes": {"4": 12}},
            "smaps_rollup": {"available": True},
            "status": {"vm_lck": "0 kB"},
        }}
        RUNNER.require_memory_record(record, "daemon", "before-ingress")
        record["observed"]["page_backing"]["kilobytes"]["Rss"] = 13
        with self.assertRaisesRegex(RuntimeError, "incomplete resident accounting"):
            RUNNER.require_memory_record(record, "daemon", "before-ingress")
        record["observed"]["page_backing"]["available"] = False
        with self.assertRaisesRegex(RuntimeError, "page backing unavailable"):
            RUNNER.require_memory_record(record, "daemon", "before-ingress")


if __name__ == "__main__":
    unittest.main()
