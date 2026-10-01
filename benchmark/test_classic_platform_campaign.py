"""Mocked tests for perf control and platform campaign command construction."""

import tempfile
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

CAMPAIGN_PATH = Path(__file__).with_name("run_classic_platform_campaign.py")
sys.path.insert(0, str(CAMPAIGN_PATH.parent))
SPEC = importlib.util.spec_from_file_location("classic_platform_campaign_test", CAMPAIGN_PATH)
platform_campaign = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = platform_campaign
SPEC.loader.exec_module(platform_campaign)


class PerfControlTests(unittest.TestCase):
    def capture(self):
        capture = platform_campaign.PerfCapture.__new__(platform_campaign.PerfCapture)
        capture.control_write = 12
        capture.ack_read = 13
        return capture

    def test_accepts_perf_acknowledgement_with_nul_terminator(self):
        capture = self.capture()
        with patch.object(platform_campaign.os, "write", return_value=7) as write, \
                patch.object(platform_campaign.select, "select", return_value=([13], [], [])) as ready, \
                patch.object(platform_campaign.os, "read", return_value=b"ack\n\0") as read:
            capture.control("enable")

        write.assert_called_once_with(12, b"enable\n")
        ready.assert_called_once_with([13], [], [], 10)
        read.assert_called_once_with(13, 5)

    def test_rejects_wrong_acknowledgement(self):
        capture = self.capture()
        with patch.object(platform_campaign.os, "write", return_value=7), \
                patch.object(platform_campaign.select, "select", return_value=([13], [], [])), \
                patch.object(platform_campaign.os, "read", return_value=b"nope\0") as read:
            with self.assertRaisesRegex(RuntimeError, "perf failed enable"):
                capture.control("enable")
        read.assert_called_once_with(13, 5)

    def test_times_out_when_perf_does_not_acknowledge(self):
        capture = self.capture()
        with patch.object(platform_campaign.os, "write", return_value=7), \
                patch.object(platform_campaign.select, "select", return_value=([], [], [])) as ready, \
                patch.object(platform_campaign.os, "read") as read:
            with self.assertRaisesRegex(RuntimeError, "did not acknowledge enable"):
                capture.control("enable")
        ready.assert_called_once_with([13], [], [], 10)
        read.assert_not_called()

    def test_rejects_short_control_write(self):
        capture = self.capture()
        with patch.object(platform_campaign.os, "write", return_value=6), \
                patch.object(platform_campaign.select, "select") as ready, \
                patch.object(platform_campaign.os, "read") as read:
            with self.assertRaisesRegex(RuntimeError, "short perf control write"):
                capture.control("enable")
        ready.assert_not_called()
        read.assert_not_called()


class CampaignCommandTests(unittest.TestCase):
    def args(self, *, diagnostic=False):
        return SimpleNamespace(
            diagnostic=diagnostic, corpus=Path("corpus"), frames=21,
            current_rate=250, readout_us=2000,
            trace_library_directory=Path("trace-libs"),
            trace_module=Path("trace-module.so"),
            trace_heart_plugin=Path("trace-heart.so"),
        )

    def test_heart_normal_command_uses_canonical_roots_and_barrier_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            directory, ready, release = (Path(temp) / name for name in
                                         ("run", "ready.json", "release"))
            with patch.object(platform_campaign.campaign, "command",
                              return_value=["heart-runner", "--role", "heart"]) as base:
                result = platform_campaign.run_command(
                    "heart", directory, self.args(), ready, release)

        base.assert_called_once_with("heart", Path("corpus"), directory, 250, 2000, 21)
        self.assertEqual(result[:3], ["taskset", "-c", "0-15"])
        self.assertIn(str(platform_campaign.WORKSPACE / "calculon-algorithms-main-copper"), result)
        self.assertIn(str(platform_campaign.WORKSPACE / "JuliaFilterGraph.jl"), result)
        self.assertEqual(result[-6:], ["--ingress-ready-file", str(ready),
                                       "--ingress-release-file", str(release),
                                       "--ingress-done-file", str(ready.parent / "ingress.done")])

    def test_explicit_julia_checkout_is_forwarded_in_normal_and_diagnostic_modes(self):
        for diagnostic in (False, True):
            args = self.args(diagnostic=diagnostic)
            args.jfg_root = Path("candidate-julia")
            with self.subTest(diagnostic=diagnostic), \
                    patch.object(platform_campaign.campaign, "command", return_value=["runner"]):
                command = platform_campaign.run_command(
                    "jfg-row", Path("run"), args, Path("ready"), Path("release"))
            self.assertEqual(command[command.index("--jfg-root") + 1], "candidate-julia")

    def test_explicit_fgn_checkout_selects_matching_plugin_and_generator(self):
        args = self.args()
        args.fgn_root = Path("candidate-fgn")
        with patch.object(platform_campaign.campaign, "command",
                          return_value=["runner", "--plugin", "old-plugin"]):
            command = platform_campaign.run_command(
                "fgn-row", Path("run"), args, Path("ready"), Path("release"))
        self.assertEqual(command[command.index("--fgn-root") + 1], "candidate-fgn")
        self.assertEqual(command[command.index("--plugin") + 1],
                         "candidate-fgn/target/release/libcalculon_fgn_bundle.so")

    def test_fgn_diagnostic_uses_trace_runner_and_forwards_barrier_pair(self):
        with tempfile.TemporaryDirectory() as temp:
            directory, ready, release = (Path(temp) / name for name in
                                         ("run", "ready.json", "release"))
            with patch.object(platform_campaign.campaign, "command") as base:
                result = platform_campaign.run_command(
                    "fgn-row", directory, self.args(diagnostic=True), ready, release)

        base.assert_not_called()
        self.assertEqual(result[:3], ["taskset", "-c", "0-15"])
        self.assertEqual(result[3], platform_campaign.sys.executable)
        self.assertEqual(result[4], str(platform_campaign.ROOT / "benchmark/run_classic_ingress_trace.py"))
        self.assertIn("fgn", result)
        self.assertIn(str(self.args(diagnostic=True).trace_library_directory), result)
        self.assertIn(str(self.args(diagnostic=True).trace_module), result)
        self.assertEqual(result[-6:], ["--ingress-ready-file", str(ready),
                                       "--ingress-release-file", str(release),
                                       "--ingress-done-file", str(ready.parent / "ingress.done")])


class CaseGroupCleanupTests(unittest.TestCase):
    def process(self):
        return SimpleNamespace(pid=314, poll=lambda: 0)

    def test_empty_case_group_requires_no_signals(self):
        record = {"errors": []}
        with patch.object(platform_campaign, "group_members", return_value=[]), \
                patch.object(platform_campaign.os, "killpg") as killpg:
            platform_campaign.cleanup_case_group(self.process(), record)

        self.assertTrue(record["case_group_empty"])
        self.assertEqual(record["errors"], [])
        killpg.assert_not_called()

    def test_orphaned_group_is_terminated_and_failure_retained(self):
        record = {"errors": []}
        with patch.object(platform_campaign, "group_members",
                          side_effect=[[271], [271], [], [], []]), \
                patch.object(platform_campaign.os, "killpg") as killpg, \
                patch.object(platform_campaign.time, "sleep"):
            platform_campaign.cleanup_case_group(self.process(), record)

        killpg.assert_called_once_with(314, platform_campaign.signal.SIGTERM)
        self.assertTrue(record["case_group_empty"])
        self.assertIn("receiver left case processes running: [271]", record["errors"])

    def test_term_resistant_orphan_is_killed_and_unreaped_group_raises(self):
        record = {"errors": []}
        with patch.object(platform_campaign, "group_members", return_value=[271]), \
                patch.object(platform_campaign.os, "killpg") as killpg, \
                patch.object(platform_campaign.time, "monotonic", side_effect=[0, 3, 4, 7]), \
                patch.object(platform_campaign.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "case group cleanup failed"):
                platform_campaign.cleanup_case_group(self.process(), record)

        self.assertEqual([call.args for call in killpg.call_args_list], [
            (314, platform_campaign.signal.SIGTERM),
            (314, platform_campaign.signal.SIGKILL),
        ])
        self.assertFalse(record["case_group_empty"])
        self.assertEqual(record["remaining_case_processes"], [271])
        self.assertTrue(record["errors"])


class QoSAdmissionTests(unittest.TestCase):
    def test_off_condition_with_effective_zero_latency_never_releases_ingress(self):
        with tempfile.TemporaryDirectory() as temp:
            case = Path(temp) / "case"
            process = SimpleNamespace(pid=271, poll=lambda: None, wait=lambda **kwargs: 0,
                                      send_signal=lambda signal_number: None)
            request = {"requested_us": None, "effective_during_us": 0,
                       "effective_after_release_us": 0, "released": True}
            args = SimpleNamespace(diagnostic=False, current_rate=250, frames=63,
                                   readout_us=2000, current_latency=None)

            def launch(*_args, **_kwargs):
                ready = case / "ingress.ready.json"
                ready.write_text(json.dumps({"processes": [{"pid": process.pid}]}))
                return process

            class LatencyRequest:
                def __enter__(self):
                    return request

                def __exit__(self, *_exc):
                    return False

            with patch.object(platform_campaign, "run_command", return_value=["fake-receiver"]), \
                    patch.object(platform_campaign.subprocess, "Popen", side_effect=launch), \
                    patch.object(platform_campaign.os, "getpgid", return_value=process.pid), \
                    patch.object(platform_campaign, "cpu_latency_request",
                                 return_value=LatencyRequest()), \
                    patch.object(platform_campaign, "snapshot", return_value={}) as snapshot, \
                    patch.object(platform_campaign, "cleanup_case_group",
                                 side_effect=lambda _process, record: record.update(case_group_empty=True)), \
                    patch.object(platform_campaign.campaign, "archive_wire") as archive, \
                    patch.object(platform_campaign.campaign, "intervals") as intervals, \
                    patch.object(platform_campaign, "PerfCapture") as perf:
                record = platform_campaign.run_case("fgn-row", case, args)

            self.assertFalse((case / "ingress.release").exists())
            self.assertIs(record["cpu_latency_request"], request)
            self.assertTrue(record["case_group_empty"])
            self.assertTrue(any("external zero-latency constraint" in error
                                for error in record["errors"]))
            self.assertEqual(snapshot.call_count, 1)
            archive.assert_called_once()
            intervals.assert_not_called()
            perf.assert_not_called()

if __name__ == "__main__":
    unittest.main()
