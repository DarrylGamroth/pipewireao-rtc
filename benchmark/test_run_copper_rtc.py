"""Privilege-free checks for managed Copper wire qualification."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
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

    def test_ambiguous_live_replay_mismatch_is_inconclusive_and_still_rejected(self) -> None:
        for matrix, properties in (([4, 6], [9, 9]), ([4, 4], [8, 10])):
            with self.subTest(matrix=matrix, properties=properties):
                report = {"qualified": False, "live_updates": True,
                          "live_update_boundaries": {
                              "matrix_change_at": matrix[0],
                              "property_change_at": properties[0],
                              "matrix_change_at_interval": matrix,
                              "property_change_at_interval": properties}}
                with self.assertRaisesRegex(RuntimeError, "comparison is inconclusive"):
                    RUNNER.compare_reported_algorithm_output(
                        np.array([0.1], dtype=np.float32),
                        np.array([0.2], dtype=np.float32), 1, 1, "correction", report)
                self.assertEqual(report["numerical_comparison"], "inconclusive")
                self.assertFalse(report["qualified"])
                ambiguity = report["live_update_comparison_ambiguity"]
                self.assertIn("does not establish", ambiguity["diagnostic"])
                self.assertIn("frame 0", ambiguity["selected_replay_mismatch"])
                self.assertTrue(ambiguity["ambiguous_intervals"])

    def test_unique_live_replay_mismatch_remains_a_failure(self) -> None:
        report = {"live_updates": True, "live_update_boundaries": {
            "matrix_change_at_interval": [4, 4], "property_change_at_interval": [8, 8]}}
        with self.assertRaisesRegex(RuntimeError, "differs from direct Algorithm"):
            RUNNER.compare_reported_algorithm_output(
                np.array([0.1], dtype=np.float32),
                np.array([0.2], dtype=np.float32), 1, 1, "correction", report)
        self.assertEqual(report["numerical_comparison"], "failed")
        self.assertNotIn("live_update_comparison_ambiguity", report)

    def test_ambiguous_boundaries_do_not_hide_invalid_vectors(self) -> None:
        for actual, expected in (([np.nan], [0.1]), ([0.1], [np.inf]), ([], [0.1])):
            with self.subTest(actual=actual, expected=expected):
                report = {"live_updates": True, "live_update_boundaries": {
                    "matrix_change_at_interval": [4, 6]}}
                with self.assertRaises(RuntimeError):
                    RUNNER.compare_reported_algorithm_output(
                        np.array(actual, dtype=np.float32),
                        np.array(expected, dtype=np.float32), 1, 1, "correction", report)
                self.assertNotIn("live_update_comparison_ambiguity", report)
                self.assertNotEqual(report.get("numerical_comparison"), "inconclusive")

    def test_mean_mismatch_is_unaffected_by_ambiguous_update_boundaries(self) -> None:
        report = {"live_updates": True, "live_update_boundaries": {
            "matrix_change_at_interval": [4, 6], "property_change_at_interval": [8, 10]}}
        with self.assertRaises(RUNNER.AlgorithmComparisonMismatch):
            RUNNER.compare_reported_algorithm_output(
                np.array([0.1], dtype=np.float32),
                np.array([0.2], dtype=np.float32), 1, 1, "mean", report)
        self.assertEqual(report["numerical_comparison"], "failed")
        self.assertNotIn("live_update_comparison_ambiguity", report)

    def test_live_timing_is_separate_from_overall_qualification(self) -> None:
        for late in ([], [7]):
            with self.subTest(late=late):
                report = {"qualified": True, "schedule_qualified": True}
                latency = {"over_frame_period_sequences": late}
                RUNNER.record_live_update_timing(report, latency)
                self.assertEqual(report["live_update_timing_qualified"], not late)
                self.assertIs(report["live_command_latency"], latency)
                self.assertTrue(report["qualified"])
                self.assertTrue(report["schedule_qualified"])

    def test_live_latency_matches_source_identity_and_rejects_missing_or_early_commands(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "source-test.csv").write_text(
                "# capacity=8 used=4 omitted=0\n"
                "event,start_ns,frame,ordinal\nR,1000,0,1\nR,2000,0,2\n"
                "R,3000,1,1\nR,4000,1,2\n")
            commands = root / "commands.csv"
            commands.write_text("sequence,receipt_ns\n0,2500\n1,5000\n")
            report = RUNNER.live_command_latency(root, commands, 2, 474)
            self.assertEqual(report["per_frame_us"], [0.5, 1.0])
            self.assertEqual(report["over_frame_period_sequences"], [])
            self.assertIn("excludes physical DM", report["scope"])
            commands.write_text("sequence,receipt_ns\n0,2500\n1,3000000\n")
            late = RUNNER.live_command_latency(root, commands, 2, 474)
            self.assertEqual(late["over_frame_period_sequences"], [1])
            commands.write_text("sequence,receipt_ns\n0,1500\n1,5000\n")
            with self.assertRaisesRegex(RuntimeError, "preceded source"):
                RUNNER.live_command_latency(root, commands, 2, 474)
            commands.write_text("sequence,receipt_ns\n0,2500\n")
            with self.assertRaisesRegex(RuntimeError, "incomplete"):
                RUNNER.live_command_latency(root, commands, 2, 474)

    def test_julia_compile_trace_arguments_resolve_path_without_creation(self) -> None:
        self.assertEqual(RUNNER.julia_trace_compile_arguments(None, "native"), [])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostics" / "compile.jl"
            with self.assertRaisesRegex(ValueError, "requires --controller julia"):
                RUNNER.julia_trace_compile_arguments(path, "native")
            self.assertFalse(path.parent.exists())
            arguments = RUNNER.julia_trace_compile_arguments(path, "julia")
            self.assertEqual(arguments, [f"--trace-compile={path.resolve()}",
                                         "--trace-compile-timing"])
            self.assertFalse(path.parent.exists())
            self.assertFalse(path.exists())

    def test_trace_inside_output_is_created_after_exclusive_run_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "run"
            trace = output / "diagnostics" / "compile.jl"
            RUNNER.julia_trace_compile_arguments(trace, "julia")
            self.assertFalse(output.exists())
            RUNNER.create_output_directory(output, trace)
            self.assertTrue(output.is_dir())
            self.assertTrue(trace.parent.is_dir())
            self.assertFalse(trace.exists())
            with self.assertRaises(FileExistsError):
                RUNNER.create_output_directory(output, trace)

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
