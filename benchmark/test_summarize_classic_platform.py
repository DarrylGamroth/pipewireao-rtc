"""Synthetic checks for the Classic platform campaign report."""

import json
import math
from pathlib import Path
import tempfile
import unittest

from summarize_classic_platform import summarize_manifest


def run(repeat, p50, p99, *, qualified=True, errors=None, idle=10):
    def metric(base, count=120):
        result = {"count": count, "p50": base}
        if count >= 100:
            result["p99"] = base + 9
        return result

    return {
        "path": "fgn-row", "rate_hz": 250, "mode": "off", "repeat": repeat,
        "diagnostic": False, "comparison_qualified": qualified,
        "errors": errors or [], "exact_wire_delivery": True,
        "science_passed": True, "source_pacing_passed": True,
        "functional_passed": True, "normal_child_exit": True, "returncode": 0,
        "command": ["runner", "--role", "fgn"],
        "latency": {
            "all": {"first_to_dm_us": metric(p50), "terminal_to_dm_us": metric(p50 / 2)},
            "after_first_100": {"first_to_dm_us": metric(p99, 20),
                                 "terminal_to_dm_us": metric(p99 / 2, 20)},
            "achieved_source_rate_hz": 249.8 + repeat,
            "deadline_exceeded_count": repeat,
        },
        "before_ingress": {"cpus": {"0": {"idle": {"state0": {"name": "C1", "usage": "1", "time": "100"}}}}},
        "after_capture": {"cpus": {"0": {"idle": {"state0": {"name": "C1", "usage": str(1 + idle), "time": str(100 + idle * 100)}}}}},
    }


class SummaryTests(unittest.TestCase):
    def summarize(self, runs):
        with tempfile.TemporaryDirectory() as temp:
            manifest_path = Path(temp) / "manifest.json"
            manifest_path.write_text(json.dumps({"requested": {"frames": 120},
                                                 "source_revisions": {"rtc": "abc"},
                                                 "harness_revision": "def", "runs": runs}))
            return summarize_manifest(json.loads(manifest_path.read_text()), manifest_path)

    def test_counts_failures_and_ranges_only_qualified_windows(self):
        first, second = run(1, 10, 20), run(2, 30, 40)
        failed = run(3, 1000, 2000, qualified=False, errors=["capture failed"])
        group = self.summarize([first, second, failed])["groups"][0]

        self.assertEqual(group["counts"], {"cases": 3, "passed": 2, "failed": 1})
        self.assertEqual(group["percentile_ranges_across_per_window_values"]["all"][
            "first_to_dm_us"]["p50"], {"min": 10, "max": 30, "windows": 2})
        self.assertEqual(group["percentile_ranges_across_per_window_values"]["all"][
            "first_to_dm_us"]["p99"], {"min": 19, "max": 39, "windows": 2})
        self.assertEqual(group["all_frame_deadline_counts"],
                         {"windows": 2, "frames": 240, "exceeded": 3})
        self.assertEqual(group["gate_assertions"]["exact_wire_delivery"]["passed"], 3)

    def test_idle_counter_decrease_flags_idle_only(self):
        sample = run(1, 10, 20)
        sample["after_capture"]["cpus"]["0"]["idle"]["state0"]["usage"] = "0"
        group = self.summarize([sample])["groups"][0]

        self.assertEqual(group["counts"]["passed"], 1)
        self.assertEqual(group["runs"][0]["idle_delta"]["status"], "partial")
        self.assertEqual(group["runs"][0]["idle_delta"]["cpus"]["0"]["states"]["state0"][
            "flags"], ["decreasing_usage"])

    def test_rejects_inconsistent_diagnostic_flags_within_group(self):
        first, second = run(1, 10, 20), run(2, 30, 40)
        second["diagnostic"] = True
        with self.assertRaisesRegex(ValueError, "inconsistent diagnostic flag"):
            self.summarize([first, second])

    def test_rejects_qualified_run_with_errors_or_missing_acceptance_flags(self):
        sample = run(1, 10, 20, errors=["receiver failed"])
        with self.assertRaisesRegex(ValueError, "nonempty errors"):
            self.summarize([sample])

        sample = run(1, 10, 20)
        sample["functional_passed"] = False
        with self.assertRaisesRegex(ValueError, "failed functional_passed"):
            self.summarize([sample])

    def test_rejects_nonfinite_and_unsupported_p99(self):
        sample = run(1, 10, 20)
        sample["latency"]["all"]["first_to_dm_us"]["p50"] = math.inf
        with self.assertRaisesRegex(ValueError, "finite number"):
            self.summarize([sample])

        sample = run(1, 10, 20)
        sample["latency"]["after_first_100"]["first_to_dm_us"]["count"] = 20
        sample["latency"]["after_first_100"]["first_to_dm_us"]["p99"] = 99
        with self.assertRaisesRegex(ValueError, "fewer than 100"):
            self.summarize([sample])

    def test_63_frame_window_reports_no_after_first_100_percentiles(self):
        sample = run(1, 10, 20)
        for window, count in (("all", 63),):
            for metric in ("first_to_dm_us", "terminal_to_dm_us"):
                sample["latency"][window][metric] = {"count": count, "p50": 10}
        sample["latency"]["after_first_100"] = {
            "first_to_dm_us": None, "terminal_to_dm_us": None,
        }
        sample["latency"]["deadline_exceeded_count"] = 0
        group = self.summarize([sample])["groups"][0]
        summary = group["percentile_ranges_across_per_window_values"]["after_first_100"]
        self.assertIsNone(summary["first_to_dm_us"]["p50"])
        self.assertIsNone(summary["first_to_dm_us"]["p99"])

    def test_idle_snapshot_and_state_changes_are_flagged(self):
        sample = run(1, 10, 20)
        sample["before_ingress"]["cpus"]["0"]["idle"]["state0"]["name"] = "C1"
        sample["after_capture"]["cpus"]["0"]["idle"]["state0"]["name"] = "C2"
        group = self.summarize([sample])["groups"][0]
        state = group["runs"][0]["idle_delta"]["cpus"]["0"]["states"]["state0"]
        self.assertEqual(state["flags"], ["state_name_changed"])

        sample["before_ingress"] = {}
        group = self.summarize([sample])["groups"][0]
        self.assertEqual(group["runs"][0]["idle_delta"]["status"], "missing_snapshot")


if __name__ == "__main__":
    unittest.main()
