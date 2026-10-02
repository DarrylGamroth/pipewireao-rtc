"""Focused package/lifecycle checks. These are not timing qualification."""

import argparse
import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

import deploy
import placement


def fixture(directory: Path) -> dict:
    for name in ("session.conf.in", "core.conf.in", "client.conf.in"):
        (directory / name).write_text("{}\n")
    contract = {"cpus": [14], "leader-cpu": 14, "rt-priority": 0,
                "threads": [], "locked-bytes": 0}
    return {"version": 1, "name": "test-rtc", "session": "session.conf.in",
            "core": "core.conf.in", "client": {"core": "client.conf.in", "rtc": "client.conf.in"},
            "placement": {"core": copy.deepcopy(contract), "rtc": copy.deepcopy(contract)},
            "owners": [], "environment": {}, "cpu-latency-us": None,
            "artifacts": {"session.conf.in": deploy.digest(directory / "session.conf.in")}}


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.spec = fixture(self.directory)
        self.config = self.directory / "deployment.conf"

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, value=None):
        self.config.write_text(json.dumps(self.spec if value is None else value))
        return self.config

    def test_standard_json_profile_without_source_tree(self):
        self.assertEqual(deploy.profile(self.write(), Path("/unused")), self.spec)

    def test_profile_hash_mismatch_rejects_before_ingress(self):
        self.write()
        (self.directory / "session.conf.in").write_text("changed")
        with self.assertRaisesRegex(placement.DeploymentError, "hash mismatch"):
            deploy.profile(self.config, Path("/unused"))

    def test_profile_rejects_cpu_zero_and_sibling(self):
        for cpu in (0, 1):
            spec = copy.deepcopy(self.spec)
            spec["placement"]["rtc"]["cpus"] = [cpu, 14]
            with self.subTest(cpu=cpu), self.assertRaisesRegex(placement.DeploymentError, "0 and 1"):
                deploy.profile(self.write(spec), Path("/unused"))

    def test_no_undeclared_owner_or_client(self):
        spec = copy.deepcopy(self.spec)
        spec["client"].pop("rtc")
        with self.assertRaisesRegex(placement.DeploymentError, "client configuration"):
            deploy.profile(self.write(spec), Path("/unused"))

    def test_owner_markers_are_basenames_and_distinct(self):
        spec = copy.deepcopy(self.spec)
        spec["owners"] = [{"role": "science", "argv": ["program"], "environment": {},
                           "prepared": "../old", "connect": "connect", "connected": "connected", "quit": "quit"}]
        with self.assertRaisesRegex(placement.DeploymentError, "marker basename"):
            deploy.profile(self.write(spec), Path("/unused"))

    def owner_spec(self):
        spec = copy.deepcopy(self.spec)
        spec["owners"] = [{"role": "science", "argv": ["program"], "environment": {},
                           "prepared": "prepared", "connect": "connect",
                           "connected": "connected", "quit": "quit"}]
        spec["placement"]["science"] = copy.deepcopy(spec["placement"]["rtc"])
        spec["client"]["science"] = "client.conf.in"
        return spec

    def test_profile_wrong_types_report_deployment_errors(self):
        cases = [(("version",), True), (("environment",), []),
                 (("environment",), {"KEY": None}), (("environment",), {"A=B": "x"}),
                 (("environment",), {"KEY": "\0"}), (("artifacts",), []),
                 (("artifacts", "session.conf.in"), None), (("client",), []),
                 (("client", "rtc"), None), (("session",), None), (("core",), "\0"),
                 (("owners", 0), None), (("owners", 0, "environment"), []),
                 (("owners", 0, "environment"), {"KEY": 1}),
                 (("owners", 0, "argv"), "program"), (("owners", 0, "argv"), [None]),
                 (("owners", 0, "prepared"), None), (("owners", 0, "quit"), ".."),
                 (("placement",), []), (("placement", "rtc"), []),
                 (("placement", "rtc", "cpus"), 14),
                 (("placement", "rtc", "cpus"), {"cpu": 14}),
                 (("placement", "rtc", "threads"), [None]),
                 (("placement", "rtc", "threads", 0, "cpus"), None),
                 (("placement", "rtc", "threads", 0, "priority"), False),
                 (("placement", "rtc", "threads", 0, "name"), [])]
        for keys, invalid in cases:
            spec = self.owner_spec()
            spec["placement"]["rtc"]["threads"] = [
                {"cpus": [14], "policy": "other", "priority": 0, "count": 1}]
            parent = spec
            for key in keys[:-1]:
                parent = parent[key]
            parent[keys[-1]] = invalid
            with self.subTest(keys=keys, invalid=invalid), self.assertRaises(deploy.DeploymentError):
                deploy.profile(self.write(spec), Path("/unused"))

    def test_owner_markers_cannot_alias_runtime_paths_or_other_owners(self):
        for marker in ("science", "control.sock", "native-prefix", "julia-depot", "."):
            spec = self.owner_spec()
            spec["owners"][0]["prepared"] = marker
            with self.subTest(marker=marker), self.assertRaises(deploy.DeploymentError):
                deploy.profile(self.write(spec), Path("/unused"))
        spec = self.owner_spec()
        spec["owners"].append({**spec["owners"][0], "role": "other"})
        with self.assertRaisesRegex(deploy.DeploymentError, "distinct"):
            deploy.profile(self.write(spec), Path("/unused"))

    def test_asset_cannot_escape_through_symlink(self):
        (self.directory / "escape").symlink_to("/etc/passwd")
        with self.assertRaisesRegex(placement.DeploymentError, "escapes package"):
            deploy.relative_asset(self.directory, "escape")

    def test_template_paths_escape_quotes_without_shell(self):
        text = deploy.substitute('{ path = "@PACKAGE@/graph.conf" }',
                                 {"PACKAGE": '/a/space " quote'}, quoted=True)
        self.assertIn(r'/a/space \" quote/graph.conf', text)
        self.assertEqual(deploy.substitute("@PACKAGE@/graph.conf", {"PACKAGE": "/has spaces"}),
                         "/has spaces/graph.conf")
        with self.assertRaisesRegex(placement.DeploymentError, "unresolved"):
            deploy.substitute("@UNKNOWN@", {})

    def test_install_relocates_launcher_and_preserves_prefix(self):
        self.write()
        source = self.directory
        with tempfile.TemporaryDirectory(prefix="rtc alternate ") as target:
            destination = Path(target) / "installed package"
            args = argparse.Namespace(package=source, destination=destination,
                                      pipewire_prefix=Path("/alternate prefix/pipewireao"))
            deploy.install(args)
            unit = (destination / "systemd/pipewireao-rtc@.service").read_text()
            self.assertIn('"/alternate prefix/pipewireao"', unit)
            self.assertIn(str(destination / "bin/pipewireao-rtc-deploy"), unit)
            self.assertNotIn("@CPUS@", unit)
            self.assertTrue(os.access(destination / "bin/pipewireao-rtc-deploy", os.X_OK))
            self.assertTrue((destination / "bin/placement.py").is_file())
            self.assertTrue((destination / "bin/pipewireao-rtc@.service.in").is_file())
            relocated = Path(target) / "relocated package"
            destination.rename(relocated)
            installed = Path(target) / "installed again"
            result = subprocess.run([str(relocated / "bin/pipewireao-rtc-deploy"), "install",
                                     "--package", str(relocated), "--destination", str(installed),
                                     "--pipewire-prefix", "/alternate prefix/pipewireao"],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            unit = (installed / "systemd/pipewireao-rtc@.service").read_text()
            self.assertIn(str(installed / "bin/pipewireao-rtc-deploy"), unit)
            self.assertNotIn(str(relocated), unit)

    def deployment(self, *, runtime=None):
        fits = self.directory / "input.fits"
        fits.write_bytes(b"fixture")
        args = argparse.Namespace(deployment=self.write(), pipewire_prefix=Path("/unused"),
                                  runtime=runtime or self.directory / "runtime", fits=fits)
        with patch.object(deploy, "installed_paths", return_value={}), \
                patch.object(deploy.os, "sched_getaffinity", return_value={14}):
            return deploy.Deployment(args)

    def test_fresh_runtime_is_cleaned_on_preparation_and_finalization_failures(self):
        for stage in ("override", "render", "state", "stop"):
            deployment = self.deployment()
            base = deployment.args.runtime
            base.mkdir(mode=0o700, exist_ok=True)
            (base / "unrelated").write_text("preserved")
            previous = base / "run-previous"
            previous.mkdir(exist_ok=True)
            (previous / "marker").write_text("preserved")
            with self.subTest(stage=stage), \
                    patch.object(deployment, "preflight", return_value={}), \
                    patch.object(deploy.os, "sched_setaffinity"), \
                    patch.object(deploy, "notify"), \
                    patch.object(deployment, "prepare_julia_override",
                                 side_effect=OSError("override failed") if stage in ("override", "stop") else None), \
                    patch.object(deploy, "substitute",
                                 side_effect=OSError("render failed") if stage == "render" else deploy.substitute), \
                    patch.object(deploy, "atomic_record",
                                 side_effect=OSError("state failed") if stage == "state" else deploy.atomic_record), \
                    patch.object(deployment, "stop",
                                 side_effect=OSError("stop failed") if stage == "stop" else deployment.stop):
                with self.assertRaises(OSError):
                    deployment.run()
            self.assertEqual(sorted(path.name for path in base.glob("run-*")), ["run-previous"])
            self.assertEqual((base / "unrelated").read_text(), "preserved")
            self.assertEqual((previous / "marker").read_text(), "preserved")

    def test_fresh_runtime_is_cleaned_when_socket_path_is_too_long(self):
        deployment = self.deployment(runtime=self.directory / ("x" * 90))
        with patch.object(deployment, "preflight", return_value={}), \
                patch.object(deploy.os, "sched_setaffinity"), patch.object(deploy, "notify"):
            with self.assertRaisesRegex(deploy.DeploymentError, "too long"):
                deployment.run()
        self.assertEqual(list(deployment.args.runtime.glob("run-*")), [])

    def test_stop_finishes_owned_cleanup_after_marker_or_notify_error(self):
        deployment = self.deployment()
        deployment.spec = self.owner_spec()
        deployment.runtime = self.directory / "absent"
        process = MagicMock()
        deployment.processes = [("core", process)]
        deployment.latency_fd = 42
        with patch.object(deploy, "notify", side_effect=OSError("notify failed")), \
                patch.object(deploy.os, "close") as close:
            with self.assertRaisesRegex(deploy.DeploymentError, "cleanup failed"):
                deployment.stop()
        self.assertTrue(all(call.kwargs == {"timeout": 0} for call in process.wait.call_args_list))
        close.assert_called_once_with(42)
        self.assertIsNone(deployment.latency_fd)

    def test_consumers_quit_after_ingress_stop_and_rtc_teardown(self):
        for state in ("Running", "Fault"):
            deployment = self.deployment()
            deployment.spec = self.owner_spec()
            deployment.runtime = self.directory
            deployment.socket = self.directory / "control.sock"
            core, rtc, owner = MagicMock(), MagicMock(), MagicMock()
            deployment.processes = [("core", core), ("science", owner), ("rtc", rtc)]
            events = []
            original_touch = Path.touch

            def request(_socket, argv, timeout):
                events.append(argv[0])
                return {"state": "Ready" if argv[0] == "session-stop" else state}

            def wait(process, grace):
                events.append("rtc-done" if process is rtc else "core-done" if process is core else "owner-done")

            def touch(path, *args, **kwargs):
                events.append("owner-quit")
                original_touch(path, *args, **kwargs)

            with self.subTest(state=state), patch.object(Path, "is_socket", return_value=True), \
                    patch.object(deploy, "control", side_effect=request), \
                    patch.object(deploy, "notify"), \
                    patch.object(deployment, "wait_owned_process", side_effect=wait), \
                    patch.object(Path, "touch", touch):
                deployment.stop()
            self.assertLess(events.index("rtc-done"), events.index("owner-quit"))
            if state == "Running":
                self.assertLess(events.index("session-stop"), events.index("owner-quit"))
            else:
                self.assertLess(events.index("core-done"), events.index("owner-quit"))

    def test_missing_effective_rights_are_reported(self):
        with patch.object(placement.resource, "getrlimit", return_value=(0, 0)):
            with self.assertRaisesRegex(placement.DeploymentError, "inherited rights"):
                placement.credentials(83, 0, None)
            with self.assertRaisesRegex(placement.DeploymentError, "memlock"):
                placement.credentials(0, 1024, None)
        with patch.object(placement.os, "access", return_value=False):
            with self.assertRaisesRegex(placement.DeploymentError, "effective credentials"):
                placement.credentials(0, 0, 0)

    def test_client_rejects_mismatched_request_identity(self):
        path = self.directory / "peer.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen(1)

        def peer():
            with server:
                client, _ = server.accept()
                with client:
                    client.recv(16384)
                    client.sendall(b'{"version":1,"id":"wrong","ok":true}\n')

        worker = threading.Thread(target=peer)
        worker.start()
        try:
            with self.assertRaisesRegex(placement.DeploymentError, "request identity"):
                deploy.control(path, ["status"])
        finally:
            worker.join(timeout=2)
        self.assertFalse(worker.is_alive())

    def test_client_bounds_request(self):
        with self.assertRaisesRegex(placement.DeploymentError, "limits"):
            deploy.control(self.directory / "unused", ["x"] * 129)

    def test_client_deadline_covers_all_reply_blocks(self):
        elapsed = [0.0]
        blocks = iter([b" "] * 5 + [b'{"version":1,"id":"fixed","ok":true}\n'])
        client = MagicMock()
        client.__enter__.return_value = client

        def receive(_length):
            elapsed[0] += 0.06
            return next(blocks)

        client.recv.side_effect = receive
        with patch.object(deploy.socket, "socket", return_value=client), \
                patch.object(deploy.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(deploy.uuid, "uuid4", return_value=argparse.Namespace(hex="fixed")):
            with self.assertRaisesRegex(deploy.DeploymentError, "timed out.*outcome may be unknown"):
                deploy.control(self.directory / "unused", ["session-start"], timeout=0.15)
        self.assertEqual(client.recv.call_count, 3)
        self.assertAlmostEqual(client.settimeout.call_args[0][0], 0.03)

    def test_client_transport_timeout_has_unknown_mutation_outcome(self):
        for operation in ("connect", "sendall", "recv"):
            client = MagicMock()
            client.__enter__.return_value = client
            getattr(client, operation).side_effect = TimeoutError("peer stalled")
            with self.subTest(operation=operation), \
                    patch.object(deploy.socket, "socket", return_value=client):
                with self.assertRaisesRegex(deploy.DeploymentError, "timed out.*outcome may be unknown"):
                    deploy.control(self.directory / "unused", ["session-start"])

    def test_client_rejects_completed_reply_after_deadline(self):
        elapsed = [0.0]
        client = MagicMock()
        client.__enter__.return_value = client

        def receive(_length):
            elapsed[0] = 0.2
            return b'{"version":1,"id":"fixed","ok":true}\n'

        client.recv.side_effect = receive
        with patch.object(deploy.socket, "socket", return_value=client), \
                patch.object(deploy.time, "monotonic", side_effect=lambda: elapsed[0]), \
                patch.object(deploy.uuid, "uuid4", return_value=argparse.Namespace(hex="fixed")):
            with self.assertRaisesRegex(deploy.DeploymentError, "timed out.*outcome may be unknown"):
                deploy.control(self.directory / "unused", ["session-start"], timeout=0.15)


if __name__ == "__main__":
    unittest.main()
