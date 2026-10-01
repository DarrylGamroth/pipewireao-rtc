"""Focused tests for the optional normal-run adapter CPU layout."""
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("run_classic_platform_campaign.py")
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("classic_platform_adapter_cpu_test", SCRIPT)
campaign = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = campaign
SPEC.loader.exec_module(campaign)


class AdapterCpuCampaignTests(unittest.TestCase):
    def args(self, *, cpu=None, diagnostic=False):
        return SimpleNamespace(
            diagnostic=diagnostic, adapter_loop_cpu=cpu, corpus=Path("corpus"),
            frames=252, current_rate=1000, readout_us=850,
            trace_library_directory=Path("trace-libs"),
            trace_module=Path("trace-module.so"),
            trace_heart_plugin=Path("trace-heart.so"),
        )

    def command(self, path, args):
        with patch.object(campaign.campaign, "command",
            return_value=["runner", "--adapter-loop-cpu", "8", "--plugin", "old-plugin"]):
            return campaign.run_command(path, Path("run"), args,
                                        Path("ready"), Path("release"))

    def test_default_command_keeps_original_adapter_cpu(self):
        command = self.command("fgn-row", self.args())
        self.assertEqual(command[command.index("--adapter-loop-cpu") + 1], "8")

    def test_override_is_path_specific_for_fgn_and_jfg(self):
        for path, cpu in (("fgn-row", 2), ("jfg-row", 4)):
            with self.subTest(path=path):
                command = self.command(path, self.args(cpu=cpu))
                self.assertEqual(command[command.index("--adapter-loop-cpu") + 1], str(cpu))

    def test_heart_command_is_unchanged_by_override(self):
        command = self.command("heart", self.args(cpu=2))
        self.assertEqual(command[command.index("--adapter-loop-cpu") + 1], "8")

    def test_cli_rejects_negative_unavailable_and_diagnostic_overrides(self):
        parser = campaign.argparse.ArgumentParser()
        cases = ((-1, False, "reserved CPUs"),
                 (0, False, "reserved CPUs"),
                 (1, False, "reserved CPUs"),
                 (16, False, "outside receiver CPU envelope"),
                 (2, True, "cannot be combined with --diagnostic"))
        for cpu, diagnostic, message in cases:
            error_output = io.StringIO()
            with self.subTest(cpu=cpu, diagnostic=diagnostic), \
                    patch.object(campaign.os, "cpu_count", return_value=16), \
                    patch.object(campaign.os, "sched_getaffinity", return_value={14}), \
                    contextlib.redirect_stderr(error_output):
                with self.assertRaises(SystemExit) as raised:
                    campaign.validate_adapter_loop_cpu(parser, cpu, diagnostic)
                self.assertEqual(raised.exception.code, 2)
            self.assertIn(message, error_output.getvalue())

    def test_accepts_cpu_inside_receiver_affinity(self):
        parser = campaign.argparse.ArgumentParser()
        with patch.object(campaign.os, "cpu_count", return_value=16), \
                patch.object(campaign.os, "sched_getaffinity", return_value={14}):
            campaign.validate_adapter_loop_cpu(parser, 2, False)


if __name__ == "__main__":
    unittest.main()
