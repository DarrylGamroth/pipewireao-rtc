"""Bounded subprocess checks for the unchanged HEART owner wrapper."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("heart_owner", Path(__file__).parent / "hil/heart_owner.py")
heart_owner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(heart_owner)

REQUIREMENTS = {"runtime_requirements": [
    {"block": "clwcBlock", "control": "ENABLE_HRT_FLAGS", "flags": {
        "enableClippingFeedback": 1, "enableNotClearingIntg": 0}},
    {"block": "tfcBlock", "control": "ENABLE_HRT_FLAGS", "flags": {
        "enableInHoVect": 1, "enableOutDmErrs": 1}}]}


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError("mock owner deadline exceeded")
        time.sleep(0.01)


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        path = self.root / "requirements.json"
        path.write_text(json.dumps(REQUIREMENTS))
        self.owner = heart_owner.HeartOwner(SimpleNamespace(requirements=path, runtime=self.root, config=path))

    def request(self, **changes):
        return json.dumps({"version": 1, "id": 1, "operation": "status", **changes}).encode()

    def test_status_and_stale_id(self):
        reply = self.owner.control(self.request())
        self.assertTrue(reply["ok"])
        self.assertEqual((reply["state"], reply["sequence"], reply["completed"]), ("paused", 0, False))
        self.assertEqual(self.owner.control(self.request())["error"], "stale request id")

    def test_source_config_hash_remains_frozen(self):
        original = self.owner.source_config_sha256
        self.owner.options.config.write_text("changed after preparation")
        self.owner.report()
        report = json.loads(self.owner.status_path.read_text())
        self.assertEqual(report["source_config_sha256"], original)

    def test_invalid_requests_do_not_consume_id(self):
        for changes in ({"version": True}, {"id": True}, {"id": 1.0}, {"id": 0},
                        {"id": 2**63}, {"operation": "resume"}, {"extra": 1}):
            with self.subTest(changes=changes):
                self.assertFalse(self.owner.control(self.request(**changes))["ok"])
                self.assertEqual(self.owner.last_id, 0)
        for payload in (b"{", b"[]", b"\xff", b" " * (heart_owner.MAX_REQUEST_BYTES + 1)):
            self.assertFalse(self.owner.control(payload)["ok"])

    def test_reset_restarts_once_and_stale_reset_rejected(self):
        with patch.object(self.owner, "stop") as stop, patch.object(self.owner, "start") as start:
            self.assertTrue(self.owner.control(self.request(operation="reset"))["ok"])
            self.assertFalse(self.owner.control(self.request(operation="reset"))["ok"])
        stop.assert_called_once()
        start.assert_called_once()
        self.assertEqual(stop.call_args.kwargs["deadline"], start.call_args.kwargs["deadline"])

    def test_requirements_must_enable_correction(self):
        path = self.root / "requirements.json"
        data = json.loads(json.dumps(REQUIREMENTS))
        data["runtime_requirements"][1]["flags"]["enableInHoVect"] = 0
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, "meaningful"):
            heart_owner.read_requirements(path)

    def test_stop_terminates_then_kills_and_reaps_owned_child(self):
        child = subprocess.Popen([sys.executable, "-c",
            "import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print('ready',flush=True); time.sleep(60)"],
            stdout=subprocess.PIPE)
        self.assertEqual(child.stdout.readline(), b"ready\n")
        self.owner.child = child
        try:
            with patch.object(heart_owner, "listener_ready", return_value=False), patch.object(heart_owner, "STOP_TIMEOUT", .03):
                self.owner.stop()
            self.assertEqual(child.returncode, -signal.SIGKILL)
            self.assertFalse(Path(f"/proc/{child.pid}").exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=2)
            child.stdout.close()

    def test_placement_requires_envelope_and_exact_worker_priority(self):
        declaration = {"cpus": [3, 4], "allowed_priorities": [5, 10, 15, 20], "workers": [
            {"name": "HOP0.wfs.w", "cpus": [4], "policy": 1, "priority": 15}]}
        thread = {"tid": 1, "name": "HOP0.wfs.w", "cpus": [4], "policy": 1, "priority": 15}
        heart_owner.validate_placement([thread], declaration)
        for changes in ({"cpus": [0]}, {"priority": 10}, {"policy": 2}, {"name": "missing"}):
            with self.subTest(changes=changes), self.assertRaises(RuntimeError):
                heart_owner.validate_placement([{**thread, **changes}], declaration)
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            heart_owner.validate_placement([thread, thread], declaration)

    def test_placement_parser_rejects_reserved_cpus(self):
        path = self.root / "placement.json"
        path.write_text(json.dumps({"cpus": [0, 4], "workers": []}))
        with self.assertRaisesRegex(ValueError, "excluding"):
            heart_owner.read_placement(path)

    def test_ack_requires_success_and_accepted(self):
        self.assertTrue(heart_owner.acknowledged(0, "ack<0><ACCEPTED> status<0><SUCCESS>"))
        for code, text in ((1, "ack<0><ACCEPTED> status<0><SUCCESS>"), (0, "ack<0><ACCEPTED>"),
                           (0, "status<0><SUCCESS>")):
            self.assertFalse(heart_owner.acknowledged(code, text))


class ProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="heart owner with spaces ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.markers = {name: self.root / name for name in (
            "prepared-event", "connect-request", "connect-reply", "quit-request",
            "control-request", "control-reply")}
        for name in ("config", "cpu-map", "thread-map"):
            (self.root / name).write_text(name)
        (self.root / "requirements").write_text(json.dumps(REQUIREMENTS))
        self.executable = self.root / "mock HEART"
        self.executable.write_text('''#!/usr/bin/env python3
import json, os, pathlib, socket, sys, time
root = pathlib.Path.cwd()
(root / "stop-child").unlink(missing_ok=True)
(root / "launch.json").write_text(json.dumps({"argv": sys.argv[1:], "cpu": os.environ["HRT_CPU_MACHINE_FILE"], "threads": os.environ["HRT_THREAD_MAP_FILE"]}))
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 5001)); s.listen()
while not (root / "stop-child").exists():
    time.sleep(.005)
''')
        self.client = self.root / "mock client"
        self.client.write_text('''#!/usr/bin/env python3
import pathlib, sys
root = pathlib.Path.cwd()
command = sys.argv[sys.argv.index("-cmdName") + 1]
with (root / "commands").open("a") as stream: stream.write(command + "\\n")
if command == "SHUTDOWN": (root / "stop-child").touch()
if (root.parent / "reject-command").exists() and command == "CORRECT":
    print("ack<0><ACCEPTED> status<1><FAILED>")
else: print("ack<0><ACCEPTED> status<0><SUCCESS>")
''')
        self.executable.chmod(0o755)
        self.client.chmod(0o755)
        # Serialize these fixed-port tests and fail clearly if a live controller
        # already occupies the unchanged command endpoint.
        if self._testMethodName != "test_reset_uses_one_deadline_and_reaps_failed_replacement":
            try:
                heart_owner.guard_port()
            except OSError:
                self.skipTest("HEART port 5001 already occupied")
        self.runtime = self.root / "runtime"
        self.argv = [sys.executable, str(Path(heart_owner.__file__))]
        for name, path in {"executable": self.executable, "client": self.client,
                           "runtime": self.runtime, **self.markers,
                           **{name: self.root / name for name in ("config", "requirements", "cpu-map", "thread-map")}}.items():
            self.argv += ["--" + name, str(path)]
        self.process = None

    def tearDown(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def start(self):
        self.process = subprocess.Popen(self.argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.process.stderr.close)

    def test_prepare_connect_status_and_quit_reaps_child(self):
        self.start()
        wait_for(self.markers["prepared-event"].exists)
        launch = json.loads((self.runtime / "launch.json").read_text())
        self.assertEqual(launch["argv"], ["-shm", "-config", str(self.runtime / "config/heart.yaml")])
        self.assertEqual(launch["cpu"], str(self.runtime / "config/host.cpu"))
        self.assertEqual(launch["threads"], str(self.runtime / "config/host.threads"))
        self.assertEqual((self.runtime / "commands").read_text().splitlines(), [
            "INIT", "RUN", *("ENABLE_HRT_FLAGS" for _ in range(4)), "CORRECT"])
        self.markers["connect-request"].touch()
        wait_for(self.markers["connect-reply"].exists)
        self.markers["control-request"].write_text(json.dumps({"version": 1, "id": 1, "operation": "status"}))
        wait_for(self.markers["control-reply"].exists)
        self.assertTrue(json.loads(self.markers["control-reply"].read_text())["ok"])
        report = json.loads((self.runtime / "heart-owner-status.json").read_text())
        self.assertTrue(report["native_threads"])
        child = report["child_pid"]
        self.markers["quit-request"].touch()
        self.assertEqual(self.process.wait(timeout=12), 0)
        self.assertFalse(Path(f"/proc/{child}").exists())
        self.assertEqual((self.runtime / "commands").read_text().splitlines()[-1], "SHUTDOWN")

    def test_reset_restarts_child_and_caches_identical_request(self):
        self.start()
        wait_for(self.markers["prepared-event"].exists)
        first = json.loads((self.runtime / "heart-owner-status.json").read_text())["child_pid"]
        self.markers["control-request"].write_text(json.dumps({"version": 1, "id": 1, "operation": "reset"}))
        wait_for(self.markers["control-reply"].exists)
        self.assertTrue(json.loads(self.markers["control-reply"].read_text())["ok"])
        second = json.loads((self.runtime / "heart-owner-status.json").read_text())
        self.assertNotEqual(first, second["child_pid"])
        self.assertEqual(second["generation"], 2)
        self.assertFalse(Path(f"/proc/{first}").exists())
        time.sleep(.05)
        self.assertEqual(json.loads((self.runtime / "heart-owner-status.json").read_text())["generation"], 2)
        self.markers["quit-request"].touch()
        self.assertEqual(self.process.wait(timeout=12), 0)
        self.assertFalse(Path(f"/proc/{second['child_pid']}").exists())

    def test_config_template_rejects_native_unsupported_package_path(self):
        package = self.root / 'package "quoted"'
        (self.root / "config").write_text('CAL: "@PACKAGE@/heart/calibration/file.fits"\n')
        self.argv += ["--package", str(package)]
        self.start()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse((self.runtime / "launch.json").exists())
        self.assertIn(b"quote, backslash or control", self.process.stderr.read())
        self.assertIn("@PACKAGE@", (self.root / "config").read_text())

    def test_config_template_rejects_native_scalar_overflow(self):
        (self.root / "config").write_text('CAL: "' + 'x' * 128 + '"\n')
        self.start()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse((self.runtime / "launch.json").exists())
        self.assertIn(b"shorter than 128 bytes", self.process.stderr.read())

    def test_reset_uses_one_deadline_and_reaps_failed_replacement(self):
        # This deadline test does not claim the fixed command endpoint and can
        # run alongside live integration. Clients remain real bounded children.
        child_source = self.executable.read_text().replace('s.bind(("127.0.0.1", 5001)); s.listen()', 'pass')
        self.executable.write_text(child_source)
        guard = patch.object(heart_owner, "guard_port")
        listener = patch.object(heart_owner, "listener_ready", side_effect=lambda child: child.poll() is None)
        guard.start()
        listener.start()
        self.addCleanup(guard.stop)
        self.addCleanup(listener.stop)
        source = self.client.read_text().replace("import pathlib, sys", "import pathlib, sys, time")
        source = source.replace('with (root / "commands")',
            'if (root.parent / "delay-reset").exists(): time.sleep(.04 if command == "SHUTDOWN" else .08)\nwith (root / "commands")')
        self.client.write_text(source)
        owner = heart_owner.HeartOwner(heart_owner.arguments(self.argv[2:]))
        try:
            owner.start()
            first = owner.child.pid
            (self.root / "delay-reset").touch()
            started = time.monotonic()
            with patch.object(heart_owner, "RESET_TIMEOUT", .13):
                with self.assertRaises((TimeoutError, subprocess.TimeoutExpired)):
                    owner.control(json.dumps({"version": 1, "id": 1, "operation": "reset"}).encode())
            self.assertLess(time.monotonic() - started, .8)
            self.assertEqual(owner.generation, 2)
            self.assertFalse(Path(f"/proc/{first}").exists())
            self.assertIsNotNone(owner.child.returncode)
            self.assertFalse(Path(f"/proc/{owner.child.pid}").exists())
        finally:
            owner.stop()

    def test_calibration_links_keep_short_relative_yaml_paths(self):
        calibration = self.root / "calibration"
        calibration.mkdir()
        matrix = calibration / "matrix.fits"
        matrix.write_bytes(b"immutable calibration")
        (self.root / "config").write_text('CAL: "./config/matrix.fits"\n')
        self.argv += ["--calibration-root", str(calibration)]
        self.start()
        wait_for(self.markers["prepared-event"].exists)
        link = self.runtime / "config/matrix.fits"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.read_bytes(), matrix.read_bytes())
        self.assertEqual((self.runtime / "config/heart.yaml").read_text(), 'CAL: "./config/matrix.fits"\n')
        self.markers["quit-request"].touch()
        self.assertEqual(self.process.wait(timeout=12), 0)

    def test_calibration_symlink_escape_rejected_before_child(self):
        calibration = self.root / "calibration"
        calibration.mkdir()
        (calibration / "escaped.fits").symlink_to(self.root / "config")
        self.argv += ["--calibration-root", str(calibration)]
        self.start()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse((self.runtime / "launch.json").exists())

    def test_spontaneous_exit_fails_and_removes_readiness(self):
        self.start()
        wait_for(self.markers["prepared-event"].exists)
        child = json.loads((self.runtime / "heart-owner-status.json").read_text())["child_pid"]
        os.kill(child, signal.SIGTERM)
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse(self.markers["prepared-event"].exists())
        self.assertIn("unexpectedly", json.loads(self.markers["control-reply"].read_text())["error"])
        self.assertFalse(Path(f"/proc/{child}").exists())

    def test_negative_correct_ack_fails_before_prepared(self):
        (self.root / "reject-command").touch()
        self.start()
        self.assertEqual(self.process.wait(timeout=12), 1)
        self.assertFalse(self.markers["prepared-event"].exists())
        self.assertIn("CORRECT", json.loads(self.markers["control-reply"].read_text())["error"])

    def test_sigterm_owner_reaps_child(self):
        self.start()
        wait_for(self.markers["prepared-event"].exists)
        child = json.loads((self.runtime / "heart-owner-status.json").read_text())["child_pid"]
        self.process.terminate()
        self.assertEqual(self.process.wait(timeout=12), 0)
        self.assertFalse(Path(f"/proc/{child}").exists())

    def test_occupied_command_port_rejected_before_child(self):
        with socket.socket() as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", 5001))
            server.listen()
            self.start()
            self.assertEqual(self.process.wait(timeout=5), 1)
            self.assertFalse((self.runtime / "launch.json").exists())
            self.assertFalse(self.markers["prepared-event"].exists())

    def test_dangling_marker_symlink_rejected_without_launch(self):
        self.markers["prepared-event"].symlink_to(self.root / "missing-target")
        self.start()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse(self.runtime.exists())

    def test_existing_marker_rejected_without_launch(self):
        self.markers["prepared-event"].touch()
        self.start()
        self.assertEqual(self.process.wait(timeout=5), 1)
        self.assertFalse(self.runtime.exists())


if __name__ == "__main__":
    unittest.main()
