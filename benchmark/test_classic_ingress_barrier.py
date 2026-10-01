"""Tests for the optional gate before Classic frame ingress."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


RUNNER_PATH = Path(__file__).with_name("run_classic_live.py")
SPEC = importlib.util.spec_from_file_location("classic_live_ingress_test", RUNNER_PATH)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class IngressBarrierTests(unittest.TestCase):
    def test_missing_ready_marker_is_noop(self):
        helper = Mock()
        args = type("Args", (), {"ingress_ready_file": None})()

        runner.wait_for_ingress_release(helper, args, [("daemon", Mock(pid=41))])

        helper.wait_for.assert_not_called()

    def test_marker_records_processes_then_waits_for_release(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            ready = directory / "ready.json"
            release = directory / "release"
            first, second = Mock(pid=41), Mock(pid=42)
            helper = Mock()

            def release_when_waiting(label, predicate, *rest):
                self.assertEqual(label, "laboratory ingress release")
                self.assertFalse(predicate())
                release.touch()
                self.assertTrue(predicate())

            helper.wait_for.side_effect = release_when_waiting
            args = type("Args", (), {
                "ingress_ready_file": ready,
                "ingress_release_file": release,
            })()

            runner.wait_for_ingress_release(helper, args,
                                            [("daemon", first), ("adapter", second)])

            record = json.loads(ready.read_text())
            self.assertEqual(record["phase"], "prepared; no pixels sent")
            self.assertIsInstance(record["monotonic_ns"], int)
            self.assertEqual(record["processes"], [
                {"role": "daemon", "pid": 41}, {"role": "adapter", "pid": 42},
            ])
            helper.wait_for.assert_called_once()

    def test_existing_ready_marker_is_not_overwritten_or_released(self):
        with tempfile.TemporaryDirectory() as temp:
            ready = Path(temp) / "ready.json"
            ready.write_text("existing marker\n")
            helper = Mock()
            args = type("Args", (), {
                "ingress_ready_file": ready,
                "ingress_release_file": Path(temp) / "release",
            })()

            with self.assertRaises(FileExistsError):
                runner.wait_for_ingress_release(helper, args, [])

            self.assertEqual(ready.read_text(), "existing marker\n")
            helper.wait_for.assert_not_called()

    def test_done_marker_is_noop_without_configuration(self):
        runner.mark_ingress_done(type("Args", (), {"ingress_done_file": None})())

    def test_done_marker_is_created_exclusively(self):
        with tempfile.TemporaryDirectory() as temp:
            done = Path(temp) / "ingress.done"
            args = type("Args", (), {"ingress_done_file": done})()

            runner.mark_ingress_done(args)

            self.assertTrue(done.is_file())
            with self.assertRaises(FileExistsError):
                runner.mark_ingress_done(args)


class IngressArgumentTests(unittest.TestCase):
    @staticmethod
    def argv(*extra):
        return [
            "run_classic_live.py", "--role", "fgn", "--fixture", "fixture",
            "--cube", "cube", "--output", "output", "--plugin", "plugin",
            "--heart-plugin", "heart", "--heart-plugin-sha256", "0" * 64,
            "--wfs-simulator", "simulator", *extra,
        ]

    def test_cli_requires_ready_and_release_together(self):
        with patch.object(sys, "argv", self.argv("--ingress-ready-file", "ready")):
            with self.assertRaises(SystemExit) as error:
                runner.arguments()
        self.assertEqual(error.exception.code, 2)

        with patch.object(sys, "argv", self.argv("--ingress-release-file", "release")):
            with self.assertRaises(SystemExit) as error:
                runner.arguments()
        self.assertEqual(error.exception.code, 2)

    def test_cli_forwards_a_complete_pair(self):
        with patch.object(sys, "argv", self.argv(
                "--ingress-ready-file", "ready", "--ingress-release-file", "release",
                "--ingress-done-file", "done")):
            args = runner.arguments()
        self.assertEqual(args.ingress_ready_file, Path("ready"))
        self.assertEqual(args.ingress_release_file, Path("release"))
        self.assertEqual(args.ingress_done_file, Path("done"))


if __name__ == "__main__":
    unittest.main()
