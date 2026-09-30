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
    def test_capture_waits_for_initialized_output(self) -> None:
        helper, process = Mock(), Mock()
        directory = Path('/capture')
        RUNNER.wait_capture_ready(helper, directory, process)
        helper.wait_text.assert_called_once_with(
            directory / 'dumpcap.log', 'File: /capture/wire.pcapng', 30, process)

    def test_replaces_exactly_one_occurrence(self) -> None:
        self.assertEqual(RUNNER.replace_once("before TOKEN after", "TOKEN", "value"),
                         "before value after")

    def test_rejects_zero_or_duplicate_occurrences(self) -> None:
        for text in ("nothing", "TOKEN TOKEN"):
            with self.subTest(text=text), self.assertRaisesRegex(
                    ValueError, "expected one configuration insertion point"):
                RUNNER.replace_once(text, "TOKEN", "value")


class CompareCommandsTests(unittest.TestCase):
    def test_explicit_continuous_reference_extent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            actual, expected = root / "actual", root / "expected"
            np.zeros(28 * 277, dtype="<f4").tofile(actual)
            np.zeros(28 * 277, dtype="<f4").tofile(expected)
            self.assertTrue(RUNNER.compare_commands(
                actual, expected, 28, reference_frames=28)["qualified"])
            with self.assertRaises(ValueError):
                RUNNER.compare_commands(actual, expected, 28)

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

    def test_frame_and_row_delivery_expectations(self) -> None:
        frame = RUNNER.expected_source_counters("frame", 7, 11)
        row = RUNNER.expected_source_counters("row", 7, 11)
        self.assertEqual(frame["received"], 224)
        self.assertEqual(frame["blocks"], 0)
        self.assertEqual(row["blocks"], 224)
        self.assertEqual(row["frames"], 7)


class NodeReportTests(unittest.TestCase):
    def test_row_counts_are_not_treated_as_terminal_publications(self) -> None:
        report = {"status": "stopped", "callback_count": 224,
                  "feedback_bridge_failed": False, "mode": "row",
                  "callbacks_per_frame": 32, "frame_count": None}
        RUNNER.validate_node_report(report, "row", 7)
        for field, value in (("callback_count", 223), ("feedback_bridge_failed", True),
                             ("mode", "frame"), ("callbacks_per_frame", 1)):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                RUNNER.validate_node_report(dict(report, **{field: value}), "row", 7)

    def test_full_frame_report_still_requires_one_callback_per_frame(self) -> None:
        report = {"status": "stopped", "callback_count": 7,
                  "feedback_bridge_failed": False}
        RUNNER.validate_node_report(report, "frame", 7)
        with self.assertRaises(RuntimeError):
            RUNNER.validate_node_report(dict(report, callback_count=224), "frame", 7)


class SourceConfigurationTests(unittest.TestCase):
    SOURCE = """context.properties = {
}
api.heart.std-wfs.width = 64
api.heart.std-wfs.height = 64
api.heart.std-wfs.output-mode = frame
api.heart.std-wfs.ndarray-schema = org.calculon.ao.raw-detector-pixels/1
"""

    def test_row_negotiation_policy_and_canonical_source_schema(self) -> None:
        text = RUNNER.configure_source(self.SOURCE, "row")
        self.assertIn("link.max-buffers = 64", text)
        self.assertIn("api.heart.std-wfs.row-block-rows = 11", text)
        self.assertIn("api.heart.std-wfs.output-mode = row-block", text)
        self.assertNotIn("api.heart.std-wfs.ndarray-schema", text)
        self.assertIn("width = 352", text)
        self.assertIn("height = 352", text)

    def test_frame_preserves_source_schema_and_default_buffer_policy(self) -> None:
        text = RUNNER.configure_source(self.SOURCE, "frame")
        self.assertIn("api.heart.std-wfs.ndarray-schema", text)
        self.assertNotIn("row-block-rows", text)
        self.assertNotIn("link.max-buffers", text)


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

    def test_continuous_replay_requires_explicit_corpus(self) -> None:
        with patch.object(sys, "argv", self.BASE_ARGS + ["--frames", "28"]), patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                RUNNER.arguments()
        with patch.object(sys, "argv", self.BASE_ARGS + ["--frames", "28", "--replay-corpus", "corpus"]):
            self.assertEqual(RUNNER.arguments().frames, 28)
        with patch.object(sys, "argv", self.BASE_ARGS + ["--frames", "29", "--replay-corpus", "corpus"]), patch("sys.stderr"):
            with self.assertRaises(SystemExit):
                RUNNER.arguments()

    def test_rejects_nondivisor_row_quantum(self) -> None:
        with patch.object(sys, "argv", self.BASE_ARGS + ["--rows-per-packet", "23"]):
            with self.assertRaises(SystemExit):
                RUNNER.arguments()

    def test_row_requires_the_prepared_eleven_row_geometry(self) -> None:
        with patch.object(sys, "argv", self.BASE_ARGS + ["--mode", "row"]):
            self.assertEqual(RUNNER.arguments().mode, "row")
        with patch.object(sys, "argv", self.BASE_ARGS +
                          ["--mode", "row", "--rows-per-packet", "8"]):
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



class FeedbackSnapshotTests(unittest.TestCase):
    def test_final_nonzero_feedback_and_invalid_snapshots(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'feedback'
            expected = np.zeros((28, 221), dtype='<f4')
            expected[-1, 0] = 0.125
            expected.tofile(path)
            snapshot = {'unit': 'micron', 'values': expected[-1].tolist(), 'boundary': 'stopped owner'}
            report = RUNNER.compare_feedback_snapshot(snapshot, path, 28)
            self.assertTrue(report['qualified'])
            self.assertEqual(report['actual_nonzero_values'], 1)
            self.assertEqual(report['expected_nonzero_values'], 1)
            snapshot['values'][0] = 0
            self.assertFalse(RUNNER.compare_feedback_snapshot(snapshot, path, 28)['qualified'])
            for invalid in (None, {'unit': 'metre'}, {'unit': 'micron', 'values': [0]},
                            {'unit': 'micron', 'values': [float('nan')] * 221}):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    RUNNER.compare_feedback_snapshot(invalid, path, 28)
            with self.assertRaises(ValueError):
                RUNNER.compare_feedback_snapshot(snapshot, path, 29)


if __name__ == "__main__":
    unittest.main()
