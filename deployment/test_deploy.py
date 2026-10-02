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

    def test_primary_startup_failure_survives_source_cleanup_failure(self):
        deployment = self.deployment()
        deployment.spec = self.owner_spec()
        deployment.spec["source-owner"] = "science"
        deployment.spec["owners"][0].update({"control-request": "source.request",
                                             "control-reply": "source.reply"})
        deployment.source_owner = deployment.spec["owners"][0]
        source = MagicMock()
        base = deployment.args.runtime
        original_atomic_record = deploy.atomic_record

        def fail_after_source_starts():
            deployment.processes.append(("science", source))
            raise deploy.DeploymentError("primary startup failure")

        def fail_source_request(path, value):
            if path.name == "source.request":
                raise OSError("source pause failed")
            original_atomic_record(path, value)

        with patch.object(deployment, "preflight", return_value={}), \
                patch.object(deploy.os, "sched_setaffinity"), \
                patch.object(deploy, "notify"), \
                patch.object(deployment, "prepare_julia_override", side_effect=fail_after_source_starts), \
                patch.object(deployment, "wait_owned_process"), \
                patch.object(deploy, "atomic_record", side_effect=fail_source_request):
            with self.assertRaisesRegex(deploy.DeploymentError, "primary startup failure") as raised:
                deployment.run()

        state = json.loads((base / "state.json").read_text())
        self.assertEqual(state["error"], "primary startup failure")
        self.assertEqual(state["cleanup_errors"], ["source pause failed"])
        self.assertEqual(raised.exception.__notes__,
                         ["cleanup also failed: deployment cleanup failed: source coordination failed: source pause failed"])

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


class SourceDeploymentTests(unittest.TestCase):
    # Share fixture helpers without rerunning the recorded test class.
    setUp = DeploymentTests.setUp
    tearDown = DeploymentTests.tearDown
    write = DeploymentTests.write
    owner_spec = DeploymentTests.owner_spec
    deployment = DeploymentTests.deployment
    def source_spec(self):
        spec = self.owner_spec()
        spec["source-owner"] = "science"
        spec["owners"][0].update({"control-request": "source.request", "control-reply": "source.reply"})
        return spec

    def source_deployment(self):
        deployment = self.deployment()
        deployment.spec = self.source_spec()
        deployment.source_owner = deployment.spec["owners"][0]
        deployment.runtime = self.directory
        deployment.native_socket = self.directory / "native-control.sock"
        return deployment

    def ack(self, deployment, operation="pause", sequence=0, **extra):
        value = {"version": 1, "id": deployment.source_id + 1, "operation": operation,
                 "state": "running" if operation == "resume" else "paused",
                 "sequence": sequence, "completed": False, "ok": True, "error": None}
        value.update(extra)
        (self.directory / "source.reply").write_text(json.dumps(value))
        return value

    def test_optional_source_role_selects_existing_owner_only(self):
        spec = self.source_spec()
        self.assertEqual(deploy.profile(self.write(spec), Path("/unused")), spec)
        for role in ("rtc", "missing", None, True):
            invalid = copy.deepcopy(spec)
            invalid["source-owner"] = role
            with self.subTest(role=role), self.assertRaises(deploy.DeploymentError):
                deploy.profile(self.write(invalid), Path("/unused"))
        for marker in ("source.request", "source.new", "prepared", "native-control.sock", "science"):
            invalid = copy.deepcopy(spec)
            invalid["owners"][0]["control-reply"] = marker
            with self.subTest(marker=marker), self.assertRaises(deploy.DeploymentError):
                deploy.profile(self.write(invalid), Path("/unused"))

    def test_source_profile_preflight_and_environment_without_fits(self):
        deployment = self.source_deployment()
        deployment.args.fits = None
        deployment.paths = {key: self.directory for key in ("spa", "library", "modules")}
        (self.directory / "bin").mkdir()
        (self.directory / "bin/pipewireao-rtc").touch()
        with patch.object(deploy, "credentials", return_value={}):
            self.assertEqual(deployment.preflight(), {})
        self.assertNotIn("PIPEWIREAO_RTC_FITS_PATH", deployment.environment("rtc", {"REMOTE": "test"}))
        deployment.source_owner = None
        with patch.object(deploy, "credentials", return_value={}):
            with self.assertRaisesRegex(deploy.DeploymentError, "FITS source"):
                deployment.preflight()

    def test_source_unit_omits_fits_recorded_unit_preserves_it(self):
        for source in (False, True):
            self.write(self.source_spec() if source else self.spec)
            destination = self.directory / ("source-install" if source else "recorded-install")
            deploy.install(argparse.Namespace(package=self.directory, destination=destination,
                                             pipewire_prefix=Path("/unused")))
            unit = (destination / "systemd/pipewireao-rtc@.service").read_text()
            self.assertEqual("--fits" in unit, not source)
            # Do not recursively copy an install nested in the source fixture.
            import shutil
            shutil.rmtree(destination)

    def test_source_protocol_ack_and_monotonic_request_identity(self):
        deployment = self.source_deployment()
        for operation in ("pause", "resume", "pause", "reset"):
            expected = self.ack(deployment, operation)
            self.assertEqual(deployment.source_control(operation), expected)
            request = json.loads((self.directory / "source.request").read_text())
            self.assertEqual(request, {"version": 1, "id": deployment.source_id, "operation": operation})
        self.assertEqual(deployment.source_id, 4)

    def test_source_protocol_rejects_bad_ack_without_admission(self):
        cases = [{"version": True}, {"id": True}, {"id": 2}, {"operation": "resume"},
                 {"state": "running"}, {"sequence": -1}, {"sequence": True}, {"completed": 1},
                 {"ok": 1}, {"error": "unexpected"}, {"extra": None}]
        for invalid in cases:
            deployment = self.source_deployment()
            self.ack(deployment, **invalid)
            with self.subTest(invalid=invalid), self.assertRaises(deploy.DeploymentError):
                deployment.source_control("pause")
            self.assertTrue(deployment.source_failed)
            self.assertEqual(deployment.record["phase"], "failed")
            self.assertFalse(deployment.record["admitted"])
        with self.assertRaisesRegex(deploy.DeploymentError, "64 KiB"):
            deploy.validate_source_reply(b" " * (deploy.MAX_REPLY_BYTES + 1))

    def test_startup_source_held_before_placement_and_released_after_native_running(self):
        deployment = self.source_deployment()
        deployment.paths["daemon"] = Path("/unused/daemon")
        events = []
        def spawned(role, _argv, _env):
            process = MagicMock(pid=100)
            process.poll.return_value = None
            deployment.processes.append((role, process))
            events.append(role)
        def native(_path, argv):
            events.append(argv[0])
            return {"state": "Ready" if argv == ["status"] else "Running"}
        def announced(message):
            if message.startswith("READY="):
                deployment.stopping = True
        with patch.object(deployment, "preflight", return_value={}), \
                patch.object(deploy.os, "sched_setaffinity"), \
                patch.object(deployment, "prepare_julia_override"), \
                patch.object(deployment, "environment", return_value={}), \
                patch.object(deployment, "spawn", side_effect=spawned), \
                patch.object(deployment, "wait"), \
                patch.object(deployment, "source_control", side_effect=lambda op, **kw: events.append(op)), \
                patch.object(deploy, "snapshot", side_effect=lambda *a: events.append("placement")), \
                patch.object(deploy, "control", side_effect=native), \
                patch.object(deploy, "notify", side_effect=announced), \
                patch.object(deployment, "open_broker"), \
                patch.object(deployment, "stop"):
            deployment.run()
        self.assertLess(events.index("pause"), events.index("placement"))
        self.assertLess(events.index("placement"), events.index("session-start"))
        self.assertLess(events.index("session-start"), events.index("resume"))
        state = json.loads((deployment.args.runtime / "state.json").read_text())
        self.assertEqual(state["source-owner"], "science")
        self.assertNotIn("fits_sha256", state)

    def test_source_sequence_zero_required_before_admission_and_reset(self):
        for operation in ("pause", "reset"):
            deployment = self.source_deployment()
            self.ack(deployment, operation, sequence=1)
            with self.subTest(operation=operation), self.assertRaisesRegex(deploy.DeploymentError, "sequence zero"):
                deployment.source_control(operation, initial=operation == "pause")

    def test_source_timeout_and_required_owner_death_fail_deployment(self):
        deployment = self.source_deployment()
        with patch.object(deploy.time, "monotonic", side_effect=[0, 9]):
            with self.assertRaisesRegex(deploy.DeploymentError, "timed out"):
                deployment.source_control("pause")
        deployment = self.source_deployment()
        process = MagicMock(returncode=7)
        process.poll.return_value = 7
        deployment.processes = [("science", process)]
        with self.assertRaisesRegex(deploy.DeploymentError, "required science exited"):
            deployment.source_control("pause")
        self.assertTrue(deployment.source_failed)

    def test_stale_ack_is_ignored_until_current_ack_and_symlink_is_rejected(self):
        deployment = self.source_deployment()
        deployment.source_id = 1
        self.ack(deployment, id=1)
        def publish(_seconds):
            self.ack(deployment, id=2)
        with patch.object(deploy.time, "sleep", side_effect=publish) as sleep:
            deployment.source_control("pause")
        sleep.assert_called_once_with(0.05)
        (self.directory / "source.reply").unlink()
        (self.directory / "source.reply").symlink_to(self.config)
        with self.assertRaises(deploy.DeploymentError):
            deployment.source_control("pause")

    def test_completed_owner_alive_paused_is_not_dependency_loss(self):
        deployment = self.source_deployment()
        owner = MagicMock()
        owner.poll.return_value = None
        deployment.processes = [("science", owner)]
        deployment.source_state = "paused"
        deployment.check()
        self.assertFalse(deployment.source_failed)

    def coordinate_events(self, argv, *, state="Running", accepted=True, source_state="running"):
        deployment = self.source_deployment()
        deployment.source_state = source_state
        events = []
        def native(arguments, request_id=None):
            events.append(tuple(arguments))
            return {"version": 1, "id": request_id, "ok": True if arguments == ["status"] else accepted,
                    "state": state}
        def owner(operation, **kwargs):
            events.append(operation)
            return {"state": source_state, "completed": False, "ok": True}
        with patch.object(deployment, "native_control", side_effect=native), \
                patch.object(deployment, "source_control", side_effect=owner):
            result = deployment.coordinate(argv, "operator")
        self.assertEqual(result["id"], "operator")
        return deployment, events

    def test_stop_and_group_stop_pause_before_native(self):
        for argv in (["session-stop"], ["source-ended"], ["stop", "controller"], ["quit"]):
            deployment, events = self.coordinate_events(argv)
            self.assertLess(events.index("pause"), events.index(tuple(argv)))
            self.assertEqual(deployment.stopping, argv == ["quit"])

    def test_start_and_group_start_native_before_source_resume(self):
        for argv in (["session-start"], ["start", "controller"]):
            _, events = self.coordinate_events(argv, source_state="paused")
            self.assertLess(events.index(tuple(argv)), events.index("resume"))

    def test_reset_only_ready_native_before_owner_reset(self):
        _, events = self.coordinate_events(["reset"], state="Ready", source_state="paused")
        self.assertEqual(events, [("status",), "status", ("reset",), "reset"])
        _, events = self.coordinate_events(["reset"], state="Running", accepted=False)
        self.assertEqual(events, [("status",), ("reset",)])

    def test_rejected_stop_restores_source_and_malformed_commands_preserve_source(self):
        for argv in (["session-stop"], ["stop", "unknown"]):
            _, events = self.coordinate_events(argv, accepted=False)
            self.assertEqual(events, [("status",), "status", "pause", tuple(argv), "resume"])
        for argv in (["stop"], ["start"], ["reset", "extra"], ["status"], ["properties", "graph"]):
            _, events = self.coordinate_events(argv, accepted=False)
            self.assertEqual(events, [tuple(argv)])

    def test_completed_source_rejects_start_before_native_and_survives_bad_stop(self):
        deployment = self.source_deployment()
        deployment.source_state = "running"  # Supervisor's earlier resume ACK is stale.
        completed = {"state": "paused", "completed": True}
        native_reply = {"version": 1, "id": "native", "ok": True, "state": "Running"}
        with patch.object(deployment, "source_control", return_value=completed), \
                patch.object(deployment, "native_control", return_value=native_reply) as native:
            reply = deployment.coordinate(["session-start"], "operator")
        native.assert_called_once_with(["status"])
        self.assertFalse(reply["ok"])
        self.assertIn("reset before start", reply["error"]["message"])
        self.assertFalse(deployment.source_failed)
        with patch.object(deployment, "source_control", return_value=completed) as source, \
                patch.object(deployment, "native_control", side_effect=[native_reply, {**native_reply, "ok": False}]):
            deployment.coordinate(["stop", "unknown"], "operator")
        self.assertEqual(source.call_args_list, [unittest.mock.call("status"), unittest.mock.call("pause")])
        self.assertFalse(deployment.source_failed)

    def test_known_resume_rejection_keeps_paused_owner_healthy_and_reports_native_outcome(self):
        deployment = self.source_deployment()
        self.ack(deployment, "resume", ok=False, state="paused", completed=True,
                 error="finite run completed; reset before resume")
        reply = deployment.source_control("resume", allow_rejection=True)
        self.assertFalse(reply["ok"])
        self.assertEqual(deployment.source_state, "paused")
        self.assertFalse(deployment.source_failed)
        source_status = {"state": "running", "completed": False, "ok": True}
        rejected = {"state": "paused", "completed": True, "ok": False, "error": "reset first"}
        native_reply = {"id": "operator", "ok": True, "state": "Running", "result": {"outcome": "completed"}}
        with patch.object(deployment, "source_control", side_effect=[source_status, rejected]), \
                patch.object(deployment, "native_control", return_value=native_reply):
            reply = deployment.coordinate(["session-start"], "operator")
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["result"]["native"]["outcome"], "completed")
        self.assertFalse(deployment.source_failed)

    def test_native_unknown_outcome_is_failed_without_resume_retry(self):
        deployment = self.source_deployment()
        deployment.source_state = "running"
        with patch.object(deployment, "source_control", return_value={"state": "running", "completed": False}) as source, \
                patch.object(deployment, "native_control", side_effect=[{"ok": True, "state": "Running"},
                    deploy.DeploymentError("unknown mutation outcome")]):
            with self.assertRaisesRegex(deploy.DeploymentError, "unknown mutation"):
                deployment.coordinate(["session-stop"], "id")
        self.assertEqual(source.call_args_list, [unittest.mock.call("status"), unittest.mock.call("pause")])
        self.assertTrue(deployment.source_failed)

    def test_shutdown_pauses_source_before_rtc_stop_and_core_first_on_failure(self):
        for failed in (False, True):
            deployment = self.source_deployment()
            deployment.source_failed = failed
            core, owner, rtc = MagicMock(), MagicMock(), MagicMock()
            deployment.processes = [("core", core), ("science", owner), ("rtc", rtc)]
            events = []
            def native(_path, argv, timeout):
                events.append(argv[0])
                return {"state": "Running"}
            def wait(process, grace):
                events.append("core-end" if process is core else "source-end" if process is owner else "rtc-end")
            with patch.object(deploy, "notify"), patch.object(Path, "is_socket", return_value=True), \
                    patch.object(deployment, "source_control", side_effect=lambda *a, **k: events.append("pause")), \
                    patch.object(deploy, "control", side_effect=native), \
                    patch.object(deployment, "wait_owned_process", side_effect=wait):
                deployment.stop()
            if failed:
                self.assertLess(events.index("core-end"), events.index("quit"))
                self.assertLess(events.index("source-end"), events.index("quit"))
            else:
                self.assertLess(events.index("pause"), events.index("session-stop"))

    def test_partial_launch_source_cleanup_finishes_after_marker_error(self):
        deployment = self.source_deployment()
        deployment.runtime = self.directory / "missing"
        core = MagicMock()
        deployment.processes = [("core", core)]
        with patch.object(deploy, "notify"), patch.object(deployment, "wait_owned_process") as wait:
            with self.assertRaisesRegex(deploy.DeploymentError, "cleanup failed"):
                deployment.stop()
        self.assertEqual(wait.call_count, 2)

    def test_public_protocol_bounds_and_identity(self):
        value = {"version": 1, "id": "operator", "argv": ["status"]}
        self.assertEqual(deploy.validate_control_request(json.dumps(value).encode()), value)
        for invalid in ({**value, "version": True}, {**value, "id": ""},
                        {**value, "id": "é" * 65}, {**value, "argv": ["status"] * 129},
                        {**value, "argv": [None]}, {**value, "extra": 0}):
            with self.subTest(invalid=invalid), self.assertRaises(deploy.DeploymentError):
                deploy.validate_control_request(json.dumps(invalid).encode())
        with self.assertRaisesRegex(deploy.DeploymentError, "16 KiB"):
            deploy.validate_control_request(b" " * (deploy.MAX_REQUEST_BYTES + 1))

    def test_public_broker_slow_client_is_bounded_and_does_not_dispatch(self):
        deployment = self.source_deployment()
        client = MagicMock()
        client.__enter__.return_value = client
        client.recv.side_effect = TimeoutError("incomplete request")
        deployment.broker = MagicMock()
        deployment.broker.accept.return_value = (client, None)
        with patch.object(deployment, "coordinate") as execute:
            deployment.serve_control()
        execute.assert_not_called()
        self.assertLessEqual(client.settimeout.call_args_list[0].args[0], 1)
        reply = json.loads(client.sendall.call_args.args[0])
        self.assertFalse(reply["ok"])
        self.assertFalse(deployment.source_failed)

    def test_public_broker_bounds_reply_and_does_not_repeat_on_disconnect(self):
        deployment = self.source_deployment()
        client = MagicMock()
        client.__enter__.return_value = client
        client.recv.return_value = b'{"version":1,"id":"one","argv":["status"]}\n'
        client.sendall.side_effect = BrokenPipeError("disconnected")
        deployment.broker = MagicMock()
        deployment.broker.accept.return_value = (client, None)
        with patch.object(deployment, "coordinate", return_value={"result": "x" * 65536}) as execute:
            deployment.serve_control()
        execute.assert_called_once_with(["status"], "one")
        payload = client.sendall.call_args.args[0]
        self.assertLessEqual(len(payload), deploy.MAX_REPLY_BYTES)
        self.assertFalse(json.loads(payload)["ok"])

    def test_source_kill_failure_prevents_all_graceful_consumer_quits(self):
        deployment = self.source_deployment()
        deployment.source_failed = True
        source, core, rtc = MagicMock(), MagicMock(), MagicMock()
        deployment.processes = [("core", core), ("science", source), ("rtc", rtc)]
        def terminate(process, grace):
            if process is core:
                raise OSError("core termination unconfirmed")
        with patch.object(deploy, "notify"), \
                patch.object(deployment, "wait_owned_process", side_effect=terminate), \
                patch.object(deploy, "control") as native, patch.object(Path, "touch") as marker:
            with self.assertRaisesRegex(deploy.DeploymentError, "cleanup failed"):
                deployment.stop()
        native.assert_not_called()
        marker.assert_not_called()

    def test_public_broker_owner_only_and_never_unlinks_existing_path(self):
        deployment = self.source_deployment()
        deployment.socket = self.directory / "control.sock"
        deployment.open_broker()
        try:
            self.assertEqual(deployment.socket.stat().st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(deploy.DeploymentError, "already exists"):
                deployment.open_broker()
        finally:
            deployment.broker.close()

    def test_public_broker_forwards_id_and_rejects_bad_client_surviving(self):
        deployment = self.source_deployment()
        deployment.socket = self.directory / "control.sock"
        deployment.open_broker()
        try:
            for payload in (b'{"version":1,"id":"public","argv":["status"]}\n', b'{bad}\n'):
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.connect(str(deployment.socket))
                    client.sendall(payload)
                    with patch.object(deployment, "coordinate", return_value={"version": 1, "id": "public", "ok": True}) as execute:
                        deployment.serve_control()
                    reply = json.loads(client.recv(65536))
                    if payload.startswith(b'{"version"'):
                        execute.assert_called_once_with(["status"], "public")
                        self.assertTrue(reply["ok"])
                    else:
                        execute.assert_not_called()
                        self.assertFalse(reply["ok"])
                    self.assertFalse(deployment.source_failed)
        finally:
            deployment.broker.close()


if __name__ == "__main__":
    unittest.main()
