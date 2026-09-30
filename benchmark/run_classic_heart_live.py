#!/usr/bin/env python3
"""Run the seven-frame Classic HEART wire and command comparison sequentially.

HEART remains unchanged and uses ordinary progressive stdWfs input. This short
functional check does not qualify capacity, latency percentiles, or physical
operation. Command acknowledgements are retained separately from flag readback.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare_classic_heart_config import write_config
from run_classic_live import WORKSPACE, compare_commands, load_script


GMS_SECTIONS = {"clwcBlock": "CLWFC", "tfcBlock": "TFC"}
BOUNDARY_BUFFERS = ("cbHoGrad0", "cbHoVect0", "cbDmErr0", "cbClUnclipped0", "cbDmCmd0")
PORTS = (5000, 5001, 5002, 5003, 5004, 5005, 5006, 5007,
         5100, 5101, 5102, 5103, 5104, 5105, 5106, 5107, 5108, 5109, 6000, 6100,
         6200, 6201, 6202, 6300, 6301)


def arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("fixture", "cube", "output", "heart-root", "calibration-root"):
        parser.add_argument(f"--{option}", type=Path, required=True)
    parser.add_argument("--source-config", type=Path,
                        help="default: calibration-root/config/classic_config_sim.yaml")
    parser.add_argument("--frames", type=int, default=7)
    parser.add_argument("--replay-corpus", type=Path,
                        help="validated repeated FITS and continuous controller references")
    parser.add_argument("--dump-boundaries", action="store_true",
                        help="dump existing HEART circular buffers after capture, before shutdown")
    parser.add_argument("--rate-hz", type=int, default=10)
    parser.add_argument("--readout-us", type=int, default=2000)
    parser.add_argument("--rows-per-packet", type=int, default=11)
    parser.add_argument("--rtc-cpus")
    parser.add_argument("--source-cpus")
    parser.add_argument("--cpu-map", type=Path)
    parser.add_argument("--thread-map", type=Path)
    parser.add_argument("--fgn-root", type=Path, default=WORKSPACE / "calculon-algorithms-progressive-requal")
    parser.add_argument("--jfg-root", type=Path, default=WORKSPACE / "JuliaFilterGraph-progressive-requal")
    args = parser.parse_args(argv)
    if not 1 <= args.frames <= (28 if args.replay_corpus else 7):
        parser.error("Classic gate requires 1..7 frames, or at most 28 with --replay-corpus")
    if args.replay_corpus and args.frames % 7:
        parser.error("--replay-corpus requires 7, 14, 21, or 28 frames")
    if args.rate_hz < 1 or args.readout_us < 1 or args.readout_us * args.rate_hz >= 950000:
        parser.error("readout must be positive and below 95% of the frame period")
    if args.rows_per_packet < 1 or 352 % args.rows_per_packet:
        parser.error("rows-per-packet must be a positive divisor of 352")
    if args.rows_per_packet * 352 * 2 > 8024:
        parser.error("rows-per-packet exceeds wfsSimulator's 8024-byte payload limit")
    if (args.cpu_map is None) != (args.thread_map is None):
        parser.error("--cpu-map and --thread-map must be supplied together")
    for name in ("rtc_cpus", "source_cpus"):
        value = getattr(args, name)
        if value is not None and (not value or not re.fullmatch(r"\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*", value)):
            parser.error(f"--{name.replace('_', '-')} must be a Linux CPU list")
        if value is not None:
            for item in value.split(","):
                first, _, last = item.partition("-")
                if last and int(last) < int(first):
                    parser.error("CPU ranges must be ascending")
    if args.source_config is None:
        args.source_config = args.calibration_root / "config/classic_config_sim.yaml"
    return args


def guard_ports() -> None:
    """Refuse occupied TCP/UDP ports without sending commands to another RTC."""
    for port in PORTS:
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            with socket.socket(socket.AF_INET, kind) as probe:
                try:
                    probe.bind(("0.0.0.0", port))
                except OSError as error:
                    protocol = "TCP" if kind == socket.SOCK_STREAM else "UDP"
                    raise RuntimeError(f"required {protocol} port {port} is unavailable: {error}") from error


def command_listener_ready(process) -> bool:
    if process.poll() is not None:
        raise RuntimeError(f"scaoTemplate exited with {process.returncode}; see scao.log")
    for table in (Path("/proc/net/tcp"), Path("/proc/net/tcp6")):
        if table.exists():
            for line in table.read_text().splitlines()[1:]:
                fields = line.split()
                if len(fields) >= 4 and fields[3] == "0A" and int(fields[1].rsplit(":", 1)[1], 16) == 5001:
                    return True
    return False


def heart_command(client: Path, command: str, section: str | None = None,
                  field: str | None = None, value: int | None = None) -> list[str]:
    argv = [str(client), "-cmdName", command, "-address", "127.0.0.1", "-port", "5001"]
    if command == "ENABLE_HRT_FLAGS":
        if section not in GMS_SECTIONS.values() or field is None or value not in (0, 1):
            raise ValueError("flag command requires a verified GMS section, field, and 0/1 value")
        argv.extend(["-configEnableHrtFlag", str(value), "-configEnableHrtFlagField", field,
                     "-configEnableHrtFlagSec", section])
    return argv


def acknowledged(returncode: int | None, text: str) -> bool:
    return (returncode == 0 and "ack<0><ACCEPTED>" in text
            and "status<0><SUCCESS>" in text)


def boundary_dump_command(client: Path, buffer: str, destination: Path) -> list[str]:
    if buffer not in BOUNDARY_BUFFERS or destination.suffix != ".fits" or destination.exists():
        raise ValueError("boundary dump requires a supported buffer and new FITS destination")
    # Zero requests every retained bucket. The implementation interprets a
    # nonzero interval as buckets, despite the legacy client's seconds label.
    return heart_command(client, "DUMP_BUFFER") + [
        "-circularBufferName", buffer, "-configDumpBufferInterval", "0",
        "-configDumpBufferFile", str(destination.resolve())]


def parse_gms_snapshot(text: str, section: str, expected: dict[str, int]) -> dict:
    """Validate existing hrtGmsPrint scalar output; fail closed on ambiguity."""
    owners = {"CLWFC": "WCC.clwc", "TFC": "WCC.tfc"}
    if section not in owners:
        raise ValueError(f"unsupported GMS snapshot section: {section}")
    errors = []
    headers = re.findall(r"^GMS SECTION:\s*(\S+)\s+\(([^)]+)\)\s*$", text, re.MULTILINE)
    if len(headers) != 1 or headers[0][1] != section:
        errors.append(f"expected one GMS section of type {section}")
    values = {}
    for field in ("ownerTag", "blockState", *expected):
        matches = re.findall(rf"^\s*{re.escape(field)}\s*:\s*([^\n]+?)\s*$", text, re.MULTILINE)
        if len(matches) != 1:
            errors.append(f"{section}.{field}: expected one scalar value")
        else:
            values[field] = matches[0]
    if values.get("ownerTag") != owners[section]:
        errors.append(f"{section}.ownerTag: expected {owners[section]}")
    # HEART publishes this field before completing state transitions. Retain
    # it as metadata; CMDHANDLER.overallMode attests correction mode instead.
    flags = {}
    for field, value in expected.items():
        actual = values.get(field)
        if actual in ("0", "1"):
            flags[field] = int(actual)
        if actual != str(value):
            errors.append(f"{section}.{field}: expected {value}, read {actual!r}")
    return {"section_tag": headers[0][0] if len(headers) == 1 else None,
            "section": section, "owner": values.get("ownerTag"),
            "block_state": values.get("blockState"), "expected_flags": expected,
            "flags": flags, "verified": not errors, "errors": errors}


def parse_gms_mode(text: str) -> dict:
    """Read the mode published after successful template command fanout."""
    errors = []
    headers = re.findall(r"^GMS SECTION:\s*(\S+)\s+\(([^)]+)\)\s*$", text, re.MULTILINE)
    if headers != [("gms.cmdHandler[0]", "CMDHANDLER")]:
        errors.append("expected CMDHANDLER section gms.cmdHandler[0]")
    values = {}
    for field, expected in (("overallMode", "4"), ("overallModeStr", "CORRECTING")):
        matches = re.findall(rf"^\s*{field}\s*:\s*([^\n]+?)\s*$", text, re.MULTILINE)
        if len(matches) != 1 or matches[0] != expected:
            errors.append(f"CMDHANDLER.{field}: expected one {expected} value")
        if len(matches) == 1:
            values[field] = matches[0]
    return {"section": "CMDHANDLER", "values": values,
            "verified": not errors, "errors": errors}


def parse_clipping_count(text: str) -> int:
    matches = re.findall(r"^\s*pdmNumActsClipped\s*:\s*\[\s*0\]\s*:\s*(\d+)\s*$",
                         text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError("expected one HEART DM0 clipping count")
    return int(matches[0])


class CommandLog:
    """Retain command output and completion status, including failed startup."""

    def __init__(self, directory: Path, env: dict, runtime: Path, report: dict):
        self.directory, self.env, self.runtime, self.report = directory, env, runtime, report

    def record(self, argv: list[str], log_name: str, kind: str = "command") -> dict:
        record = {"argv": argv, "cwd": str(self.runtime), "log": log_name,
                  "kind": kind, "returncode": None, "status": "starting"}
        self.report["commands"].append(record)
        return record

    def run(self, argv: list[str], log_name: str, timeout: float = 30,
            required: bool = True) -> tuple[dict, str]:
        record = self.record(argv, log_name)
        text = ""
        try:
            result = subprocess.run(argv, cwd=self.runtime, env=self.env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=timeout, check=False)
            text = result.stdout
            record.update(returncode=result.returncode,
                          status="success" if result.returncode == 0 else "failed")
        except subprocess.TimeoutExpired as error:
            text = error.stdout or ""
            if isinstance(text, bytes):
                text = text.decode("utf-8", errors="replace")
            record.update(status="timed_out", error=str(error))
        except OSError as error:
            record.update(status="failed_to_launch", error=str(error))
        (self.directory / log_name).write_text(text, encoding="utf-8")
        if required and record["status"] != "success":
            raise RuntimeError(f"command {record['status']}: {argv[0]}; see {log_name}")
        return record, text


def load_helpers(args):
    scripts = args.fgn_root.resolve() / "scripts"
    sys.path.insert(0, str(scripts))
    return (load_script("classic_heart_transport", scripts / "run_fgn_copper_fullframe_live.py"),
            load_script("classic_heart_fixture", scripts / "qualify_fgn_revolt_classic.py"))


def validate_fixture(args, helper, qualifier) -> None:
    profile = qualifier.load_prepared_profile(args.fixture / "prepared-profile.toml")
    if (profile.detector_height, profile.detector_width, profile.frame_count,
            profile.subaperture_count, profile.controlled_vdm_size,
            profile.full_vdm_size, profile.pdm_size) != (352, 352, 7, 188, 221, 277, 277):
        raise ValueError("prepared fixture is not the seven-frame Classic geometry")
    if any(abs(actual - expected) > 1e-6 for actual, expected in (
            (profile.clwc_loop_gain, -0.3), (profile.clwc_pole, 0.99),
            (profile.clwc_anti_windup_gain, 0.99))):
        raise ValueError("prepared fixture does not use the selected HEART comparison controller")
    if (args.fixture / "demanded_pdm_command.f32le").stat().st_size != 7 * 277 * 4:
        raise ValueError("direct command reference must contain seven 277-element vectors")
    if args.replay_corpus:
        from classic_replay_corpus import validate_replay_corpus
        validate_replay_corpus(args.replay_corpus.resolve(), args.fixture.resolve(),
                              args.cube.resolve(), args.frames)
        return
    pixels = helper.primary_image(args.cube, axes=(352, 352, 7), bitpix=16)
    exported = np.fromfile(args.fixture / "raw-frames.u16le", dtype="<u2")
    if not np.array_equal(pixels.ravel(), exported):
        raise ValueError("FITS cube differs from the prepared fixture detector pixels")


def run(args: argparse.Namespace) -> dict:
    directory = args.output.resolve()
    if args.output.is_symlink() or directory.exists():
        raise ValueError(f"output already exists: {args.output}")
    directory.mkdir(parents=True)
    runtime = directory / "runtime"
    (runtime / "config").mkdir(parents=True)
    env = os.environ.copy()
    env["HRT_DEFER_WFS_INGRESS"] = "0"
    # This development host has no reserved hugetlb pool. Use HEART's existing
    # ordinary-page option; record it rather than changing host memory policy.
    env["HRT_MEMORY_HUGEPAGES"] = "0"
    # Map files are an explicit pair; do not inherit a different host placement.
    env.pop("HRT_CPU_MACHINE_FILE", None)
    env.pop("HRT_THREAD_MAP_FILE", None)
    report = {
        "role": "heart", "frames": args.frames, "rate_hz": args.rate_hz,
        "readout_us": args.readout_us, "rows_per_packet": args.rows_per_packet,
        "expected_wfs_packets": args.frames * (352 // args.rows_per_packet),
        "expected_wfs_frame_ids": list(range(args.frames)),
        "expected_dm_frame_ids": list(range(1, args.frames + 1)),
        "receiver_mode": "ordinary progressive stdWfs UDP",
        "heart_controller_size": 277, "physical_command_size": 277,
        "scope": "short functional wire comparison; no capacity or percentile performance claim",
        "qualified": False, "functional_wire_qualified": False,
        "effective_flags_verified": False,
        "effective_flags_note": "requires pre-ingress and post-replay hrtGmsPrint flags with owner identity and separate CMDHANDLER correction-mode readback",
        "effective_initial_state_verified": False,
        "effective_initial_state_note": "controller internal zero-state readback is unavailable in this runner",
        "gms_snapshots": [], "gms_mode_snapshots": [],
        "commands": [], "requested_flags": [], "flag_warnings": [],
        "sha256": {}, "errors": [], "environment": {
            "HRT_DEFER_WFS_INGRESS": "0", "HRT_MEMORY_HUGEPAGES": "0"},
        "placement": {"rtc_cpus": args.rtc_cpus, "source_cpus": args.source_cpus},
    }
    expected_commands = ((args.replay_corpus / "demanded_pdm_command.f32le")
                         if args.replay_corpus else args.fixture / "demanded_pdm_command.f32le")
    recorder = CommandLog(directory, env, runtime, report)
    helper = None
    processes = []
    rtc = None
    shutdown_attempted = False
    client = args.heart_root.resolve() / "source/template/bin/scaoTemplateCmdClient"
    gms_print = args.heart_root.resolve() / "source/aoTypes/bin/hrtGmsPrint"

    def start(argv: list[str], log_name: str):
        record = recorder.record(argv, log_name, "process")
        try:
            process, stream = helper.start(argv, env, directory / log_name, cwd=runtime)
        except Exception as error:
            record.update(status="failed_to_launch", error=str(error))
            raise
        record.update(status="running", pid=process.pid)
        processes.append((process, stream, record))
        return process, stream

    def control(command: str, log_name: str, required: bool = True):
        record, text = recorder.run(heart_command(client, command), log_name, required=required)
        record["heart_acknowledged"] = acknowledged(record["returncode"], text)
        if required and not record["heart_acknowledged"]:
            raise RuntimeError(f"HEART {command} did not report accepted SUCCESS; see {log_name}")
        return record

    def snapshot_flags(phase: str):
        failed = []
        log_name = f"gms-{phase}-cmdhandler.log"
        record, text = recorder.run([str(gms_print), "-host", "host", "-section", "CMDHANDLER", "-k", "0"],
                                    log_name, required=False)
        mode = parse_gms_mode(text)
        mode.update(phase=phase, log=log_name)
        if record["status"] != "success":
            mode["errors"].append(f"hrtGmsPrint command status: {record['status']}")
            mode["verified"] = False
        report["gms_mode_snapshots"].append(mode)
        failed.extend(mode["errors"])
        expected = {section: {} for section in GMS_SECTIONS.values()}
        for request in report["requested_flags"]:
            expected[request["section"]][request["field"]] = request["requested_value"]
        for flag in preparation.get("initialized_disabled_flags", []):
            expected[flag["section"]][flag["field"]] = flag["expected"]
        for section, flags in expected.items():
            log_name = f"gms-{phase}-{section.lower()}.log"
            record, text = recorder.run([str(gms_print), "-host", "host", "-section", section, "-k", "0"],
                                        log_name, required=False)
            parsed = parse_gms_snapshot(text, section, flags)
            if args.replay_corpus and phase == "post-replay" and section == "CLWFC":
                report["final_clipped_actuators"] = parse_clipping_count(text)
            parsed.update(phase=phase, log=log_name)
            if record["status"] != "success":
                parsed["errors"].append(f"hrtGmsPrint command status: {record['status']}")
                parsed["verified"] = False
            record["gms_verified"] = parsed["verified"]
            report["gms_snapshots"].append(parsed)
            failed.extend(parsed["errors"])
        report["effective_flags_verified"] = (len(report["gms_snapshots"]) == 4
                                              and all(item["verified"] for item in report["gms_snapshots"])
                                              and len(report["gms_mode_snapshots"]) == 2
                                              and all(item["verified"] for item in report["gms_mode_snapshots"]))
        for request in report["requested_flags"]:
            request["effective_value_verified"] = report["effective_flags_verified"]
        if failed:
            raise RuntimeError(f"{phase} GMS flag/state readback failed: " + "; ".join(failed))

    def analyze_capture():
        for port, name in ((6000, "wfs-packets.tsv"), (6100, "dm-packets.tsv")):
            recorder.run(["tshark", "-r", str(directory / "wire.pcapng"), "-Y", f"udp.port=={port}",
                          "-T", "fields", "-e", "frame.time_epoch", "-e", "udp.length", "-e", "data.data"], name)
        recorder.run([sys.executable, str(decoder), str(directory / "dm-packets.tsv"),
                      "--vectors", str(directory / "dm-wire-um.f32"),
                      "--summary", str(directory / "dm-summary.json")], "decode-dm.log")
        # Retain the common qualifier's raw descriptive capture statistics.
        # They are not promoted to a seven-frame percentile performance claim.
        packet_command = [sys.executable, str(packet_qualifier), "--fits", str(args.cube.resolve()),
                          "--frames", str(args.frames), "--period", repr(1 / args.rate_hz),
                          "--readout-us", str(args.readout_us), "--lines", str(args.rows_per_packet),
                          "--wfs-packets", str(directory / "wfs-packets.tsv"),
                          "--dm-summary", str(directory / "dm-summary.json"), "--dm-id-base", "1",
                          "--summary", str(directory / "physical-summary.json")]
        packet_record, _ = recorder.run(packet_command, "qualify-packets.log", required=False)
        if (directory / "physical-summary.json").is_file():
            report["physical"] = json.loads((directory / "physical-summary.json").read_text())
        numerical = compare_commands(directory / "dm-wire-um.f32",
                                     expected_commands, args.frames,
                                     reference_frames=expected_commands.stat().st_size // (277 * 4))
        report["numerical"] = numerical
        if args.replay_corpus:
            expected = np.fromfile(expected_commands, dtype="<f4").reshape(-1, 277)[args.frames - 1]
            expected_clips = int(np.count_nonzero(np.abs(expected) >= np.float32(0.8)))
            report["final_expected_clipped_actuators"] = expected_clips
            if report.get("final_clipped_actuators") != expected_clips:
                raise RuntimeError("HEART final clipping counter differs from reference")
        (directory / "numerical-summary.json").write_text(json.dumps(numerical, indent=2) + "\n")
        if packet_record["returncode"] != 0 or not report.get("physical", {}).get("qualified"):
            raise RuntimeError("physical packet check failed; see physical-summary.json and qualify-packets.log")
        if (not numerical["qualified"] or numerical["max_absolute_error_um"] > 1e-6
                or numerical["clipping_decision_mismatches"]):
            raise RuntimeError("physical commands differ from the direct reference; see numerical-summary.json")
        report["functional_wire_qualified"] = not report["errors"]
        # Effective flags and internal initial state are separate obligations.
        report["qualified"] = (report["functional_wire_qualified"] and report["effective_flags_verified"]
                               and report["effective_initial_state_verified"])

    try:
        helper, qualifier = load_helpers(args)
        scao = args.heart_root.resolve() / "source/template/bin/scaoTemplate"
        simulator = args.heart_root.resolve() / "source/testServer/bin/wfsSimulator"
        scripts = args.jfg_root.resolve() / "benchmark/heart"
        decoder = scripts / "decode_std_dm_packets.py"
        packet_qualifier = scripts / "qualify_copper_aos_capture.py"
        for path in (scao, client, simulator, gms_print, args.cube, args.source_config,
                     args.fixture / "prepared-profile.toml", args.fixture / "raw-frames.u16le",
                     args.fixture / "demanded_pdm_command.f32le", decoder, packet_qualifier):
            if not path.is_file():
                raise ValueError(f"required file is missing: {path}")
            report["sha256"][str(path.resolve())] = helper.sha256_file(path)
        for path in (scao, client, simulator, gms_print):
            if not os.access(path, os.X_OK):
                raise ValueError(f"required binary is not executable: {path}")
        for tool in ("dumpcap", "tshark"):
            resolved = shutil.which(tool)
            if resolved is None:
                raise ValueError(f"required capture tool is unavailable: {tool}")
            report["sha256"][resolved] = helper.sha256_file(Path(resolved))
        for name in ("rtc_cpus", "source_cpus"):
            value = getattr(args, name)
            if value is not None:
                cpus = set(helper.parse_cpu_mask(value))
                if not cpus <= os.sched_getaffinity(0):
                    raise ValueError(f"{name} exceeds available process CPUs")
        validate_fixture(args, helper, qualifier)
        if args.replay_corpus:
            from classic_replay_corpus import validate_replay_corpus
            report["replay_corpus"] = validate_replay_corpus(
                args.replay_corpus.resolve(), args.fixture.resolve(), args.cube.resolve(), args.frames)
        report["sha256"][str(expected_commands.resolve())] = helper.sha256_file(expected_commands)
        guard_ports()
        preparation = write_config(args.source_config, args.calibration_root,
                                   1 / args.rate_hz, runtime / "config/classic_matched.yaml")
        report["configuration"] = preparation
        (runtime / "input.fits").symlink_to(args.cube.resolve())
        if args.cpu_map is not None:
            for source, target, variable in (
                    (args.cpu_map, "host.cpu", "HRT_CPU_MACHINE_FILE"),
                    (args.thread_map, "host.threads", "HRT_THREAD_MAP_FILE")):
                if not source.is_file():
                    raise ValueError(f"required placement file is missing: {source}")
                destination = runtime / "config" / target
                shutil.copy2(source, destination)
                env[variable] = str(destination)
                report["environment"][variable] = str(destination)
                report["sha256"][str(source.resolve())] = helper.sha256_file(source)
        validate_command = [sys.executable, str(packet_qualifier), "--validate-inputs",
                            "--fits", str(args.cube.resolve()), "--frames", str(args.frames),
                            "--period", repr(1 / args.rate_hz), "--readout-us", str(args.readout_us),
                            "--lines", str(args.rows_per_packet)]
        recorder.run(validate_command, "validate-inputs.log")
        rtc, rtc_stream = start(helper.placed([str(scao), "-shm", "-config",
                                             "config/classic_matched.yaml"], args.rtc_cpus), "scao.log")
        helper.wait_for("HEART TCP command listener", lambda: command_listener_ready(rtc), 30)
        control("INIT", "cmd-init.log")
        control("RUN", "cmd-run.log")
        for requirement in preparation["runtime_requirements"]:
            block = requirement.get("block")
            if block not in GMS_SECTIONS:
                continue
            section = GMS_SECTIONS[block]
            for field, value in requirement["flags"].items():
                log_name = f"flag-{section.lower()}-{field}.log"
                record, text = recorder.run(heart_command(client, "ENABLE_HRT_FLAGS", section, field, value),
                                            log_name, required=False)
                request = {"section": section, "field": field, "requested_value": value,
                           "log": log_name, "acknowledged": acknowledged(record["returncode"], text),
                           "effective_value_verified": False}
                record["heart_acknowledged"] = request["acknowledged"]
                report["requested_flags"].append(request)
                if not request["acknowledged"]:
                    report["flag_warnings"].append(f"{section}.{field}: command not acknowledged as SUCCESS; see {log_name}")
        control("CORRECT", "cmd-correct.log")
        snapshot_flags("pre-ingress")
        helper.capture_thread_map(directory / "thread-map-before-replay.txt", [("HEART", rtc)])
        capture, capture_stream = start(
            ["dumpcap", "-p", "-i", "any", "-f", "udp port 6000 or udp port 6100",
             "-w", str(directory / "wire.pcapng")], "dumpcap.log")
        helper.wait_text(directory / "dumpcap.log", "Capturing on", 30, capture)
        source = helper.placed([str(simulator), "-file", "input.fits", "-tPort", "6000",
                                "-period", repr(1 / args.rate_hz), "-readout", str(args.readout_us),
                                "-lines", str(args.rows_per_packet), "-numFrames", str(args.frames)], args.source_cpus)
        recorder.run(source, "wfs-simulator.log", timeout=args.frames / args.rate_hz + 30)
        time.sleep(0.5)
        if rtc.poll() is not None:
            raise RuntimeError("scaoTemplate exited during replay; see scao.log")
        if capture.poll() is not None:
            raise RuntimeError("dumpcap exited during replay; see dumpcap.log")
        # Stop capture before shutdown can emit a zero/flat command.
        capture.send_signal(signal.SIGINT)
        helper.stop(capture, capture_stream)
        snapshot_flags("post-replay")
        if args.dump_boundaries:
            report["boundary_dumps"] = []
            for buffer in BOUNDARY_BUFFERS:
                destination = directory / f"{buffer}.fits"
                record, text = recorder.run(boundary_dump_command(client, buffer, destination),
                                            f"dump-{buffer}.log")
                record["heart_acknowledged"] = acknowledged(record["returncode"], text)
                if not record["heart_acknowledged"] or not destination.is_file():
                    raise RuntimeError(f"HEART {buffer} dump did not report SUCCESS and create its file")
                report["boundary_dumps"].append({
                    "buffer": buffer, "file": str(destination),
                    "sha256": helper.sha256_file(destination),
                    "scope": "post-capture diagnostic; shape, finiteness and frame alignment require separate validation"})
        shutdown_attempted = True
        control("SHUTDOWN", "cmd-shutdown.log")
        helper.stop(rtc, rtc_stream)
    except (Exception, KeyboardInterrupt) as error:
        report["errors"].append(str(error))
    finally:
        # Keep shutdown-generated commands outside the replay capture even on
        # source/control failures, then ask the RTC to shut down normally.
        for process, stream, record in processes:
            if record["log"] == "dumpcap.log" and process.poll() is None:
                try:
                    process.send_signal(signal.SIGINT)
                    helper.stop(process, stream)
                except Exception as error:
                    report["errors"].append(f"capture cleanup failed: {error}")
        if rtc is not None and rtc.poll() is None and not shutdown_attempted:
            try:
                control("SHUTDOWN", "cmd-shutdown-finally.log", required=False)
            except Exception as error:
                report["errors"].append(f"shutdown failed: {error}")
        for process, stream, record in reversed(processes):
            try:
                helper.stop(process, stream)
                record.update(returncode=process.returncode,
                              status="exited" if process.returncode == 0 else "abnormal_exit")
                if process.returncode != 0:
                    report["errors"].append(f"{record['log']}: process exited with {process.returncode}")
            except Exception as error:
                record.update(status="cleanup_failed", error=str(error))
                report["errors"].append(f"process cleanup failed: {error}")
                report["functional_wire_qualified"] = False
                report["qualified"] = False
                try:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=5)
                    record["returncode"] = process.returncode
                except Exception as fallback_error:
                    report["errors"].append(f"process kill failed: {fallback_error}")
                finally:
                    stream.close()
    try:
        if (directory / "wire.pcapng").is_file():
            analyze_capture()
    except Exception as error:
        report["errors"].append(str(error))
    finally:
        for name in ("wire.pcapng", "dm-wire-um.f32", "physical-summary.json", "numerical-summary.json"):
            path = directory / name
            if path.is_file() and helper is not None:
                try:
                    report["sha256"][str(path)] = helper.sha256_file(path)
                except Exception as error:
                    report["errors"].append(f"artifact hash failed for {name}: {error}")
                    report["functional_wire_qualified"] = False
                    report["qualified"] = False
        (directory / "report.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    return report


def main() -> None:
    report = run(arguments())
    print(json.dumps({"functional_wire_qualified": report["functional_wire_qualified"],
                      "qualified": report["qualified"], "effective_flags_verified": report["effective_flags_verified"],
                      "errors": report["errors"]}, indent=2))
    if not report["functional_wire_qualified"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
