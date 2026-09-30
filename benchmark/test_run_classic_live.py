"""Focused tests for the Classic live replay helpers."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import numpy as np


BENCHMARK = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "run_classic_live", BENCHMARK / "run_classic_live.py")
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class ReplaceOnceTests(unittest.TestCase):
    def test_replaces_exactly_one_occurrence(self) -> None:
        self.assertEqual(RUNNER.replace_once("before TOKEN after", "TOKEN", "value"),
                         "before value after")

    def test_rejects_zero_or_duplicate_occurrences(self) -> None:
        for text in ("nothing", "TOKEN TOKEN"):
            with self.subTest(text=text), self.assertRaisesRegex(
                    ValueError, "expected one configuration insertion point"):
                RUNNER.replace_once(text, "TOKEN", "value")


class CompareCommandsTests(unittest.TestCase):
    @staticmethod
    def compare(root: Path, actual: np.ndarray, expected: np.ndarray,
                frames: int = 1) -> dict:
        actual_path, expected_path = root / "actual.f32", root / "expected.f32"
        actual.astype("<f4").tofile(actual_path)
        expected.astype("<f4").tofile(expected_path)
        return RUNNER.compare_commands(actual_path, expected_path, frames)

    def test_accepts_matching_actual_frames_and_seven_frame_reference(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            values = np.linspace(-0.7, 0.7, 277, dtype=np.float32)
            expected = np.tile(values, 7)
            report = self.compare(Path(temporary), values, expected)
            self.assertTrue(report["qualified"])
            self.assertEqual(report["frames"], 1)
            self.assertEqual(report["failed_values"], 0)

    def test_rejects_wrong_extents_and_nonfinite_values(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "declared frame extents"):
                self.compare(root, np.zeros(276), np.zeros(7 * 277))
            with self.assertRaisesRegex(ValueError, "declared frame extents"):
                self.compare(root, np.zeros(277), np.zeros(6 * 277))
            actual = np.zeros(277)
            actual[0] = np.nan
            with self.assertRaisesRegex(ValueError, "nonfinite command"):
                self.compare(root, actual, np.zeros(7 * 277))
            actual[0] = 0
            expected = np.zeros(7 * 277)
            expected[0] = np.inf
            with self.assertRaisesRegex(ValueError, "nonfinite command"):
                self.compare(root, actual, expected)

    def test_uses_inclusive_absolute_or_relative_1e_minus_6_tolerance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual = np.zeros(277, dtype=np.float32)
            expected = np.zeros(7 * 277, dtype=np.float32)
            actual[0], expected[0] = 0.0, 1e-6
            actual[1], expected[1] = 1_000_000.0, 1_000_001.0
            report = self.compare(root, actual, expected)
            self.assertTrue(report["qualified"])
            self.assertEqual(report["failed_values"], 0)
            expected[0] = np.nextafter(np.float32(1e-6), np.float32(np.inf))
            report = self.compare(root, actual, expected)
            self.assertFalse(report["qualified"])
            self.assertEqual(report["failed_values"], 1)

    def test_reports_clipping_counts_and_decision_mismatches(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            actual = np.zeros(277, dtype=np.float32)
            expected = np.zeros(7 * 277, dtype=np.float32)
            actual[:3] = (0.8, -0.7, 0.79)
            expected[:3] = (0.81, -0.7, 0.81)
            report = self.compare(Path(temporary), actual, expected)
            self.assertEqual(report["actual_values_at_limit"], 1)
            self.assertEqual(report["expected_values_at_limit"], 2)
            self.assertEqual(report["clipping_decision_mismatches"], 1)
            self.assertFalse(report["qualified"])


class SourceCounterTests(unittest.TestCase):
    @staticmethod
    def diagnostic(*, received: int = 2) -> str:
        return ("prefix HEART_WFS_DIAG name=rtc-heart-wfs-row-source ready=1 "
                f"received={received} rejected=0 blocks=0 frames=1 dropped=0 "
                "starvations=0 suffix")

    def test_parses_one_diagnostic_line(self) -> None:
        expected = {"received": 2, "rejected": 0, "blocks": 0,
                    "frames": 1, "dropped": 0, "starvations": 0}
        self.assertEqual(RUNNER.source_counters(self.diagnostic()), expected)

    def test_returns_none_when_diagnostic_is_absent_or_duplicated(self) -> None:
        self.assertIsNone(RUNNER.source_counters("no diagnostic"))
        line = self.diagnostic()
        self.assertIsNone(RUNNER.source_counters(line + "\n" + line))


class ArgumentValidationTests(unittest.TestCase):
    BASE_ARGS = ["run_classic_live.py", "--role", "fgn", "--fixture", "fixture",
                 "--cube", "cube", "--output", "output", "--plugin", "plugin",
                 "--heart-plugin", "heart", "--heart-plugin-sha256", "digest",
                 "--wfs-simulator", "sim"]

    def test_rejects_invalid_rate_and_readout_without_starting_external_processes(self) -> None:
        cases = (("--rate-hz", "0"), ("--readout-us", "0"),
                 ("--rate-hz", "500", "--readout-us", "1900"))
        for options in cases:
            with self.subTest(options=options), patch.object(
                    sys, "argv", self.BASE_ARGS + list(options)):
                with self.assertRaises(SystemExit):
                    RUNNER.arguments()

    def test_rejects_nondivisor_row_quantum(self) -> None:
        with patch.object(sys, "argv", self.BASE_ARGS + ["--rows-per-packet", "23"]):
            with self.assertRaises(SystemExit):
                RUNNER.arguments()


class CleanupTests(unittest.TestCase):
    def test_failure_does_not_skip_remaining_children(self) -> None:
        marker = Mock()
        marker.touch.side_effect = OSError("read-only marker")
        first, second = Mock(pid=1), Mock(pid=2)
        first.returncode = 0
        second.returncode = None
        second.poll.return_value = None
        first_log, second_log = Mock(), Mock()
        helper = Mock()
        helper.stop.side_effect = [OSError("failed wait"), None]
        report = {"qualified": True, "errors": []}
        RUNNER.cleanup_replay(helper, [marker],
                              [(first, first_log), (second, second_log)], report)
        self.assertEqual(helper.stop.call_count, 2)
        helper.stop.assert_called_with(first, first_log)
        second.kill.assert_called_once()
        second.wait.assert_called_once_with(timeout=5)
        second_log.close.assert_called_once()
        self.assertFalse(report["qualified"])
        self.assertEqual(len(report["errors"]), 2)
        self.assertIn("process_returncodes", report)

    def test_success_keeps_qualification(self) -> None:
        process = Mock(pid=1, returncode=0)
        report = {"qualified": True, "errors": []}
        RUNNER.cleanup_replay(Mock(), [], [(process, Mock())], report)
        self.assertTrue(report["qualified"])
        self.assertEqual(report["process_returncodes"], [0])


if __name__ == "__main__":
    unittest.main()
