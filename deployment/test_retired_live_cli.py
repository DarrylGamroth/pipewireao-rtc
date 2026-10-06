"""Fail-closed checks for retired Python live-control entry points."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


DEPLOYMENT = Path(__file__).resolve().parent
REPO = DEPLOYMENT.parent


class RetiredLiveCliTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rtc-retired-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / "runtime-must-not-exist"
        self.output = self.root / "output-must-not-exist" / "result.json"
        self.socket_attempt = self.root / "socket-attempted"
        site = self.root / "site"
        site.mkdir()
        (site / "sitecustomize.py").write_text(
            "import os, socket\n"
            "from pathlib import Path\n"
            "def forbidden_socket(*args, **kwargs):\n"
            "    Path(os.environ['RTC_SOCKET_ATTEMPT']).write_text('attempted')\n"
            "    raise AssertionError('socket creation is forbidden in this test')\n"
            "socket.socket = forbidden_socket\n"
        )
        self.environment = os.environ.copy()
        paths = [str(site), str(DEPLOYMENT), str(DEPLOYMENT / "hil")]
        if self.environment.get("PYTHONPATH"):
            paths.append(self.environment["PYTHONPATH"])
        self.environment["PYTHONPATH"] = os.pathsep.join(paths)
        self.environment["RTC_SOCKET_ATTEMPT"] = str(self.socket_attempt)

    def invoke(self, *argv):
        return subprocess.run(
            [sys.executable, *map(str, argv)],
            cwd=REPO,
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_retired_before_effects(self, command, replacement):
        result = self.invoke(*command)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(replacement, result.stderr)
        self.assertFalse(self.runtime.exists())
        self.assertFalse(self.output.parent.exists())
        self.assertFalse(self.socket_attempt.exists())

    def test_deployment_run_and_control_are_retired_before_runtime_access(self):
        deploy = DEPLOYMENT / "deploy.py"
        self.assert_retired_before_effects(
            (deploy, "run", "--deployment", self.root / "missing.conf", "--runtime", self.runtime),
            "deployment/julia/deploy_cli.jl",
        )
        self.assert_retired_before_effects(
            (deploy, "control", "--runtime", self.runtime, "status"),
            "deployment/julia/deploy_cli.jl",
        )

    def test_live_qualification_and_campaign_entrypoints_fail_closed(self):
        cases = (
            ("check_profile.py", ("--deployment", self.root / "missing.conf", "--fits",
                                   self.root / "missing.fits", "--frames", "1", "--output",
                                   self.output, "--runtime", self.runtime),
             "deployment/julia/deploy_cli.jl"),
            ("check_properties.py", ("--deployment", self.root / "missing.conf", "--fits",
                                     self.root / "missing.fits", "--node", "fixture", "--gain",
                                     "0.5", "--pole", "0.9", "--output", self.output,
                                     "--runtime", self.runtime),
             "deployment/julia/deploy_cli.jl"),
            ("check_hil.py", ("--deployment", self.root / "missing.conf", "--runtime",
                              self.runtime, "--output", self.output),
             "deployment/julia/deploy_cli.jl"),
            ("check_heart_failure.py", ("--deployment", self.root / "missing.conf", "--runtime",
                                        self.runtime, "--output", self.output),
             "deployment/julia/deploy_cli.jl"),
            ("calibration_campaign.py", ("--base-package", self.root / "missing-package",
                                         "--output", self.output, "--recipe", self.root / "missing.json",
                                         "--aoc-source", self.root / "missing-aoc", "--rtc-binary",
                                         self.root / "missing-rtc", "--calibration-binary",
                                         self.root / "missing-calibrate", "--runtime", self.runtime),
             "deployment/julia/src/calibration_campaign.jl"),
        )
        for filename, arguments, replacement in cases:
            with self.subTest(filename=filename):
                self.assert_retired_before_effects((DEPLOYMENT / filename, *arguments), replacement)

    def test_heart_owner_direct_service_entrypoint_is_retired(self):
        result = self.invoke(DEPLOYMENT / "hil" / "heart_owner.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deployment/julia/src/heart_owner.jl", result.stderr)
        self.assertFalse(self.socket_attempt.exists())

    def test_offline_deploy_commands_remain_available(self):
        deploy = DEPLOYMENT / "deploy.py"
        help_result = self.invoke(deploy, "install", "--help")
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("--destination", help_result.stdout)

        preflight = self.invoke(deploy, "preflight", "--deployment",
                                self.root / "missing.conf", "--runtime", self.runtime)
        self.assertNotEqual(preflight.returncode, 0)
        self.assertNotIn("live deployment control is retired", preflight.stderr)
        self.assertFalse(self.runtime.exists())
        self.assertFalse(self.socket_attempt.exists())

    def test_importable_fixture_and_offline_apis_remain_available(self):
        code = (
            "import importlib.util; from pathlib import Path; "
            "import deploy, check_profile, check_properties, check_hil, "
            "check_heart_failure, calibration_campaign; "
            "spec=importlib.util.spec_from_file_location('heart_owner_fixture', "
            "Path('deployment/hil/heart_owner.py')); "
            "heart_owner=importlib.util.module_from_spec(spec); spec.loader.exec_module(heart_owner); "
            "assert callable(deploy.Deployment.run); "
            "assert callable(deploy.control); "
            "assert callable(check_profile.qualify); "
            "assert callable(check_properties.PropertyCheck.run); "
            "assert callable(check_hil.qualify); "
            "assert callable(check_heart_failure.check); "
            "assert callable(calibration_campaign.campaign); "
            "assert callable(calibration_campaign.Endpoint.request); "
            "assert callable(heart_owner.HeartOwner.control)"
        )
        result = self.invoke("-c", code)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.socket_attempt.exists())


if __name__ == "__main__":
    unittest.main()
