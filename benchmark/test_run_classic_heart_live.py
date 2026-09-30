"""Lifecycle checks and local socket reuse regression; no HEART execution."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import socket
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np


SCRIPT = Path(__file__).with_name("run_classic_heart_live.py")
SPEC = importlib.util.spec_from_file_location("run_classic_heart_live", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.options = ["--fixture", str(self.root / "fixture"), "--cube", str(self.root / "cube.fits"),
                        "--output", str(self.root / "result"), "--heart-root", str(self.root / "heart"),
                        "--calibration-root", str(self.root / "calibration"), "--jfg-root", str(self.root / "jfg")]

    def test_default_seven_frame_packetization_and_config(self) -> None:
        args = RUNNER.arguments(self.options)
        self.assertEqual((args.frames, args.rate_hz, args.readout_us, args.rows_per_packet), (7, 10, 2000, 11))
        self.assertEqual(args.source_config, args.calibration_root / "config/classic_config_sim.yaml")
        self.assertEqual(args.frames * (352 // args.rows_per_packet), 224)

    def test_continuous_replay_requires_explicit_corpus(self) -> None:
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            RUNNER.arguments(self.options + ["--frames", "28"])
        args = RUNNER.arguments(self.options + ["--frames", "28", "--replay-corpus", "corpus"])
        self.assertEqual((args.frames, args.replay_corpus), (28, Path("corpus")))
        with patch("sys.stderr"), self.assertRaises(SystemExit):
            RUNNER.arguments(self.options + ["--frames", "29", "--replay-corpus", "corpus"])

    def test_rejects_illegal_frame_rate_packet_extent_and_map_pair(self) -> None:
        for options in (["--frames", "8"], ["--rate-hz", "0"], ["--rows-per-packet", "22"],
                        ["--rows-per-packet", "3"], ["--readout-us", "95000"],
                        ["--cpu-map", "cpu"], ["--rtc-cpus", "4-2"]):
            with self.subTest(options=options), patch("sys.stderr"), self.assertRaises(SystemExit):
                RUNNER.arguments(self.options + options)

    def test_flag_command_uses_actual_api_and_canonical_sections(self) -> None:
        command = RUNNER.heart_command(Path("client"), "ENABLE_HRT_FLAGS", "CLWFC", "enableClippingFeedback", 1)
        self.assertEqual(command, ["client", "-cmdName", "ENABLE_HRT_FLAGS", "-address", "127.0.0.1", "-port", "5001",
                                   "-configEnableHrtFlag", "1", "-configEnableHrtFlagField", "enableClippingFeedback",
                                   "-configEnableHrtFlagSec", "CLWFC"])
        with self.assertRaises(ValueError):
            RUNNER.heart_command(Path("client"), "ENABLE_HRT_FLAGS", "CLWC", "enableClippingFeedback", 1)
        self.assertTrue(RUNNER.acknowledged(0, "ack<0><ACCEPTED><>, status<0><SUCCESS><>"))
        self.assertFalse(RUNNER.acknowledged(0, "ack<0><ACCEPTED><>, status<1><WARNING><>"))
        self.assertFalse(RUNNER.acknowledged(1, "ack<0><ACCEPTED><>, status<0><SUCCESS><>"))

    def test_clipping_counter_requires_one_dm_zero_entry(self) -> None:
        line = "pdmNumActsClipped               : [  0] : 12\n"
        self.assertEqual(RUNNER.parse_clipping_count(line), 12)
        for text in ("", line + line, line.replace("[  0]", "[  1]")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                RUNNER.parse_clipping_count(text)

    def test_boundary_dump_uses_existing_client_and_new_file(self) -> None:
        path = self.root / "cbClUnclipped0.fits"
        command = RUNNER.boundary_dump_command(Path("client"), "cbClUnclipped0", path)
        self.assertIn("DUMP_BUFFER", command)
        self.assertEqual(command[-4:], ["-configDumpBufferInterval", "0", "-configDumpBufferFile", str(path)])
        with self.assertRaises(ValueError):
            RUNNER.boundary_dump_command(Path("client"), "unknown", path)
        path.touch()
        with self.assertRaises(ValueError):
            RUNNER.boundary_dump_command(Path("client"), "cbClUnclipped0", path)

    def test_command_failures_and_timeouts_retain_status_and_output(self) -> None:
        report = {"commands": []}
        recorder = RUNNER.CommandLog(self.root, {}, self.root, report)
        with patch.object(RUNNER.subprocess, "run", return_value=SimpleNamespace(returncode=2, stdout="failed details")):
            with self.assertRaises(RuntimeError):
                recorder.run(["client"], "failed.log")
        self.assertEqual((self.root / "failed.log").read_text(), "failed details")
        self.assertEqual(report["commands"][0]["returncode"], 2)
        with patch.object(RUNNER.subprocess, "run", side_effect=subprocess.TimeoutExpired(["client"], 2, output=b"partial")):
            recorder.run(["client"], "timeout.log", required=False)
        self.assertEqual((self.root / "timeout.log").read_text(), "partial")
        self.assertEqual(report["commands"][1]["status"], "timed_out")

    def test_port_conflicts_fail_without_sending_command(self) -> None:
        with patch.object(RUNNER.socket, "socket") as socket_factory:
            socket_factory.return_value.__enter__.return_value.bind.side_effect = OSError("occupied")
            with self.assertRaisesRegex(RuntimeError, "port 5000 is unavailable"):
                RUNNER.guard_ports()

    def test_tcp_time_wait_does_not_block_reusable_server_port(self) -> None:
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            listener.listen(1)
            with socket.socket() as client:
                client.connect(("127.0.0.1", port))
                connection, _ = listener.accept()
                connection.shutdown(socket.SHUT_WR)
                connection.close()
                self.assertEqual(client.recv(1), b"")
        with patch.object(RUNNER, "PORTS", (port,)):
            RUNNER.guard_ports()

    def test_tcp_listener_remains_a_conflict_with_reuse_enabled(self) -> None:
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("0.0.0.0", 0))
            port = listener.getsockname()[1]
            listener.listen(1)
            with patch.object(RUNNER, "PORTS", (port,)):
                with self.assertRaisesRegex(RuntimeError, "TCP port"):
                    RUNNER.guard_ports()

    def test_secondary_telemetry_ports_are_guarded(self) -> None:
        self.assertTrue({6200, 6201, 6202, 6300, 6301}.issubset(RUNNER.PORTS))

    def setup_mocked_run(self, source_failure: bool = False, abnormal_rtc_exit: bool = False,
                         snapshot_failure: str | None = None):
        args = RUNNER.arguments(self.options)
        paths = [args.heart_root / "source/template/bin/scaoTemplate",
                 args.heart_root / "source/template/bin/scaoTemplateCmdClient",
                 args.heart_root / "source/testServer/bin/wfsSimulator",
                 args.heart_root / "source/aoTypes/bin/hrtGmsPrint",
                 args.cube, args.source_config, args.fixture / "prepared-profile.toml",
                 args.fixture / "raw-frames.u16le", args.fixture / "demanded_pdm_command.f32le",
                 args.jfg_root / "benchmark/heart/decode_std_dm_packets.py",
                 args.jfg_root / "benchmark/heart/qualify_copper_aos_capture.py"]
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture")
            path.chmod(0o755)
        np.zeros(7 * 277, dtype="<f4").tofile(args.fixture / "demanded_pdm_command.f32le")
        processes, actions, environments = [], [], []

        def start(argv, env, log, **kwargs):
            environments.append(env.copy())
            process = SimpleNamespace(pid=len(processes) + 100, returncode=None)
            process.poll = lambda: process.returncode
            process.send_signal = lambda value: actions.append(("signal", log.name, value))
            stream = log.open("w")
            stream.write("Capturing on" if log.name == "dumpcap.log" else "RTC initialized")
            stream.flush()
            if log.name == "dumpcap.log":
                (args.output / "wire.pcapng").write_bytes(b"mock capture")
            processes.append((process, log.name))
            return process, stream

        def stop(process, stream):
            process.returncode = -9 if abnormal_rtc_exit and Path(stream.name).name == "scao.log" else 0
            actions.append(("stop", Path(stream.name).name))
            stream.close()

        helper = SimpleNamespace(start=start, stop=stop, sha256_file=lambda path: "mock-hash",
                                 wait_for=lambda *args: None, wait_text=lambda *args: None,
                                 placed=lambda argv, cpus: argv,
                                 capture_thread_map=lambda path, processes: path.write_text("mock threads"))
        preparation = {"runtime_requirements": [
            {"block": "clwcBlock", "flags": {"enableClippingFeedback": 1, "enableNotClearingIntg": 0}},
            {"block": "tfcBlock", "flags": {"enableInHoVect": 1}}],
            "initialized_disabled_flags": [{"section": "CLWFC", "field": "enableR0L0", "expected": 0},
                                           {"section": "TFC", "field": "enableHoPsd", "expected": 0}]}

        def execute(argv, **kwargs):
            if Path(argv[0]).name == "hrtGmsPrint":
                section = argv[argv.index("-section") + 1]
                self.assertEqual(argv[1:], ["-host", "host", "-section", section, "-k", "0"])
                phase = "post-replay" if any(action == ("stop", "dumpcap.log") for action in actions) else "pre-ingress"
                actions.append(("snapshot", phase, section))
                if section == "CMDHANDLER":
                    mode, name = (5, "DESTROYED") if snapshot_failure == "post-state" and phase == "post-replay" else (4, "CORRECTING")
                    return SimpleNamespace(returncode=0, stdout=(
                        "GMS SECTION: gms.cmdHandler[0] (CMDHANDLER)\n"
                        f"overallMode : {mode}\noverallModeStr : {name}\n"))
                owner = "WCC.clwc" if section == "CLWFC" else "WCC.tfc"
                fields = {"enableClippingFeedback": 1, "enableNotClearingIntg": 0, "enableR0L0": 0} if section == "CLWFC" else {"enableInHoVect": 1, "enableHoPsd": 0}
                state = "RUNNING (3)"
                if snapshot_failure == "pre-owner" and phase == "pre-ingress":
                    owner = "other.clwc"
                if snapshot_failure == "post-state" and phase == "post-replay":
                    state = "DESTROYED (5)"
                output = f"Opening GMS file: /hrtGms:user:host\nGMS SECTION: gms.mock ({section})\nownerTag : {owner}\nblockState : {state}\n"
                output += "".join(f"{field} : {value}\n" for field, value in fields.items())
                return SimpleNamespace(returncode=0, stdout=output)
            if "-cmdName" in argv:
                name = argv[argv.index("-cmdName") + 1]
                actions.append(("control", name))
                if name == "ENABLE_HRT_FLAGS":
                    return SimpleNamespace(returncode=0, stdout="ack<0><ACCEPTED><>, status<1><WARNING><flag fanout>")
                return SimpleNamespace(returncode=0, stdout="ack<0><ACCEPTED><>, status<0><SUCCESS><>")
            if Path(argv[0]).name == "wfsSimulator" and source_failure:
                return SimpleNamespace(returncode=2, stdout="source failed")
            if "decode_std_dm_packets.py" in " ".join(argv):
                Path(argv[argv.index("--vectors") + 1]).write_bytes((args.fixture / "demanded_pdm_command.f32le").read_bytes())
                Path(argv[argv.index("--summary") + 1]).write_text(json.dumps({"packet_count": 7, "first_frame_id": 1, "last_frame_id": 7}))
            if "--dm-id-base" in argv:
                self.assertEqual(argv[argv.index("--dm-id-base") + 1], "1")
                Path(argv[argv.index("--summary") + 1]).write_text(json.dumps({
                    "qualified": True, "captured_wfs_packets": 224, "captured_wfs_frame_ids": list(range(7)),
                    "captured_dm_commands": 7, "dm_first_frame_id": 1, "dm_last_frame_id": 7}))
            return SimpleNamespace(returncode=0, stdout="mock success")

        patches = [patch("classic_placement.record_placement"), patch.object(RUNNER, "load_helpers", return_value=(helper, SimpleNamespace())),
                   patch.object(RUNNER, "validate_fixture"), patch.object(RUNNER, "guard_ports"),
                   patch.object(RUNNER, "write_config", return_value=preparation),
                   patch.object(RUNNER.shutil, "which", return_value=str(paths[0])),
                   patch.object(RUNNER.subprocess, "run", side_effect=execute),
                   patch.object(RUNNER.time, "sleep")]
        for context in patches:
            context.start()
            self.addCleanup(context.stop)
        return args, processes, actions, environments

    def test_mocked_secondary_telemetry_uses_public_client(self) -> None:
        args, processes, actions, environments = self.setup_mocked_run()
        args.telemetry_python = Path('/usr/bin/python3')
        report = RUNNER.run(args)
        self.assertTrue(report['functional_wire_qualified'], report['errors'])
        commands = [record for record in report['commands'] if record['log'] == 'telemetry.log']
        self.assertEqual(len(commands), 1)
        self.assertIn(str(RUNNER.ROOT / 'benchmark/classic_heart_telemetry.py'), commands[0]['argv'])
        self.assertTrue((args.output / 'telemetry.stop').exists())

    def test_mocked_spa_source_uses_the_selected_cube(self) -> None:
        args, _, _, _ = self.setup_mocked_run()
        args.sender = 'spa'
        helper = RUNNER.load_helpers.return_value[0]
        installation = object()
        helper.pipewire_installation = lambda *unused: installation
        with patch.object(RUNNER, 'replay_spa_source', return_value={'qualified': True}) as sender:
            report = RUNNER.run(args)
        self.assertTrue(report['functional_wire_qualified'], report['errors'])
        self.assertEqual(sender.call_args.args, (helper, installation, args, args.output, args.cube))
        self.assertFalse(any(row['log'] == 'wfs-simulator.log' for row in report['commands']))

    def test_mocked_success_records_flag_readback_and_unverified_initial_state(self) -> None:
        args, processes, actions, environments = self.setup_mocked_run()
        report = RUNNER.run(args)
        self.assertTrue(report["functional_wire_qualified"])
        self.assertFalse(report["qualified"])
        self.assertTrue(report["effective_flags_verified"])
        self.assertFalse(report["effective_initial_state_verified"])
        self.assertEqual(len(report["gms_snapshots"]), 4)
        self.assertEqual(len(report["gms_mode_snapshots"]), 2)
        self.assertTrue(all(snapshot["verified"] for snapshot in report["gms_snapshots"]))
        self.assertTrue(all(request["effective_value_verified"] for request in report["requested_flags"]))
        self.assertIn(str(args.heart_root / "source/aoTypes/bin/hrtGmsPrint"), report["sha256"])
        self.assertEqual(len(report["flag_warnings"]), 3)
        self.assertEqual(report["expected_wfs_packets"], 224)
        self.assertEqual(report["expected_dm_frame_ids"], list(range(1, 8)))
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))
        self.assertTrue(all(env["HRT_DEFER_WFS_INGRESS"] == "0" for env in environments))
        self.assertTrue(all(env["HRT_MEMORY_HUGEPAGES"] == "0" for env in environments))
        self.assertLess(actions.index(("stop", "dumpcap.log")), actions.index(("control", "SHUTDOWN")))
        self.assertEqual(json.loads((args.output / "report.json").read_text()), report)

    def mocked_corpus_run(self, clipping_count: int):
        args, processes, actions, _ = self.setup_mocked_run()
        args.frames = 28
        args.replay_corpus = self.root / "corpus"
        args.replay_corpus.mkdir()
        expected = np.zeros((28, 277), dtype="<f4")
        expected[-1, :15] = 0.8
        expected.tofile(args.replay_corpus / "demanded_pdm_command.f32le")
        original_execute = RUNNER.subprocess.run.side_effect

        def execute(argv, **kwargs):
            result = original_execute(argv, **kwargs)
            if Path(argv[0]).name == "hrtGmsPrint" and "CLWFC" in argv:
                result.stdout += f"pdmNumActsClipped : [  0] : {clipping_count}\n"
            if "decode_std_dm_packets.py" in " ".join(argv):
                Path(argv[argv.index("--vectors") + 1]).write_bytes(expected.tobytes())
            if "--dm-id-base" in argv:
                Path(argv[argv.index("--summary") + 1]).write_text(json.dumps({
                    "qualified": True, "captured_wfs_packets": 896,
                    "captured_wfs_frame_ids": list(range(28)), "captured_dm_commands": 28,
                    "dm_first_frame_id": 1, "dm_last_frame_id": 28}))
            return result

        with patch.object(RUNNER.subprocess, "run", side_effect=execute), patch(
                "classic_replay_corpus.validate_replay_corpus", return_value={"frames": 28}):
            return RUNNER.run(args), processes, actions

    def test_mocked_corpus_attests_final_clip_count_and_preserves_state_limit(self) -> None:
        report, processes, actions = self.mocked_corpus_run(15)
        self.assertTrue(report["functional_wire_qualified"])
        self.assertFalse(report["qualified"])
        self.assertEqual(report["final_clipped_actuators"], 15)
        self.assertEqual(report["final_expected_clipped_actuators"], 15)
        self.assertEqual(report["numerical"]["frames"], 28)
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))
        self.assertLess(actions.index(("stop", "dumpcap.log")), actions.index(("control", "SHUTDOWN")))

    def test_mocked_corpus_rejects_wrong_final_clip_count(self) -> None:
        report, processes, _ = self.mocked_corpus_run(14)
        self.assertFalse(report["functional_wire_qualified"])
        self.assertTrue(report["numerical"]["qualified"])
        self.assertIn("HEART final clipping counter differs from reference", report["errors"])
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))

    def test_snapshot_parser_rejects_missing_duplicate_wrong_flags_and_identity(self) -> None:
        valid = "GMS SECTION: gms.closedLoopWfc (CLWFC)\nownerTag : WCC.clwc\nblockState : RUNNING (3)\nenableR0L0 : 0\n"
        self.assertTrue(RUNNER.parse_gms_snapshot(valid, "CLWFC", {"enableR0L0": 0})["verified"])
        for invalid in (valid.replace("(CLWFC)", "(TFC)"),
                        valid.replace("WCC.clwc", "WCC.other"),
                        valid.replace("enableR0L0 : 0\n", ""),
                        valid + "enableR0L0 : 0\n", valid + valid,
                        valid.replace("enableR0L0 : 0", "enableR0L0 : 1"),
                        valid.replace("enableR0L0 : 0", "enableR0L0 : [0] : 0")):
            with self.subTest(invalid=invalid):
                self.assertFalse(RUNNER.parse_gms_snapshot(invalid, "CLWFC", {"enableR0L0": 0})["verified"])

    def test_mode_parser_requires_authoritative_index_and_both_mode_fields(self) -> None:
        valid = "GMS SECTION: gms.cmdHandler[0] (CMDHANDLER)\noverallMode : 4\noverallModeStr : CORRECTING\n"
        self.assertTrue(RUNNER.parse_gms_mode(valid)["verified"])
        for invalid in (valid.replace("[0]", "[1]"), valid + valid,
                        valid.replace("overallMode : 4", "overallMode : 3"),
                        valid.replace("CORRECTING", "RUNNING"),
                        valid.replace("overallMode : 4\n", ""),
                        valid + "overallMode : 4\n"):
            with self.subTest(invalid=invalid):
                self.assertFalse(RUNNER.parse_gms_mode(invalid)["verified"])

    def test_pre_ingress_readback_failure_prevents_source_and_cleans_rtc(self) -> None:
        args, processes, actions, _ = self.setup_mocked_run(snapshot_failure="pre-owner")
        report = RUNNER.run(args)
        self.assertFalse(report["functional_wire_qualified"])
        self.assertFalse(report["effective_flags_verified"])
        self.assertTrue(any("pre-ingress GMS" in error for error in report["errors"]))
        self.assertEqual(len(report["gms_snapshots"]), 2)
        self.assertFalse(any(Path(record["argv"][0]).name == "wfsSimulator" for record in report["commands"]))
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))
        self.assertIn(("control", "SHUTDOWN"), actions)

    def test_post_replay_readback_failure_retains_capture_and_cleans_rtc(self) -> None:
        args, processes, _, _ = self.setup_mocked_run(snapshot_failure="post-state")
        report = RUNNER.run(args)
        self.assertFalse(report["functional_wire_qualified"])
        self.assertFalse(report["effective_flags_verified"])
        self.assertTrue(any("post-replay GMS" in error for error in report["errors"]))
        self.assertEqual(report["physical"]["captured_wfs_packets"], 224)
        self.assertEqual(len(report["gms_snapshots"]), 4)
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))

    def test_mocked_source_failure_stops_processes_and_analyzes_capture(self) -> None:
        args, processes, actions, _ = self.setup_mocked_run(source_failure=True)
        report = RUNNER.run(args)
        self.assertFalse(report["functional_wire_qualified"])
        self.assertTrue(any("command failed" in error for error in report["errors"]))
        self.assertEqual(report["physical"]["captured_wfs_packets"], 224)
        self.assertTrue(all(process.returncode == 0 for process, _ in processes))
        self.assertLess(actions.index(("stop", "dumpcap.log")), actions.index(("control", "SHUTDOWN")))
        source = next(row for row in report["commands"] if row["log"] == "wfs-simulator.log")
        self.assertEqual(source["returncode"], 2)
        self.assertTrue((args.output / "wfs-simulator.log").is_file())

    def test_abnormal_rtc_exit_cannot_qualify_complete_capture(self) -> None:
        args, _, _, _ = self.setup_mocked_run(abnormal_rtc_exit=True)
        report = RUNNER.run(args)
        self.assertTrue(report["physical"]["qualified"])
        self.assertTrue(report["numerical"]["qualified"])
        self.assertFalse(report["functional_wire_qualified"])
        self.assertIn("scao.log: process exited with -9", report["errors"])

    def test_missing_preflight_file_records_failure_and_existing_output_is_guarded(self) -> None:
        args = RUNNER.arguments(self.options)
        helper = SimpleNamespace(sha256_file=lambda path: "hash")
        with patch.object(RUNNER, "load_helpers", return_value=(helper, SimpleNamespace())):
            report = RUNNER.run(args)
        self.assertFalse(report["functional_wire_qualified"])
        self.assertIn("required file is missing", report["errors"][0])
        self.assertTrue((args.output / "report.json").is_file())
        with self.assertRaisesRegex(ValueError, "output already exists"):
            RUNNER.run(args)


if __name__ == "__main__":
    unittest.main()
