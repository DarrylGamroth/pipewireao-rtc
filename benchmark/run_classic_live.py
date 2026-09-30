#!/usr/bin/env python3
"""Replay the pinned Classic FITS corpus through a developed frame or row RTC.

The shared fixture comes from the maintained Rust profile exporter. This runner
loads the existing nine-node graph and adapters; it implements no AO algorithms.
The initial gate uses the seven recorded frames. Long controller trajectories
and performance characterization are separate checks.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
import importlib.util
import json
from pathlib import Path
import re
import sys
import time

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
PARAMETERS = (
    ("pixel-calibration:background", "background.f32le", 352 * 352 * 4),
    ("shack-hartmann:subaperture-origins", "subaperture-origins.u32le", 188 * 2 * 4),
    ("shack-hartmann:coordinates", "shack-hartmann-coordinates.f32le", 484 * 2 * 4),
    ("shack-hartmann:reference-slopes", "reference-slopes.f32le", 188 * 2 * 4),
    ("shack-hartmann:thresholds", "thresholds.f32le", 188 * 2 * 4),
    ("shack-hartmann:active", "active-subapertures.u8", 188),
    ("reconstruction:reconstructor", "reconstructor.f32le", 221 * 376 * 4),
    ("controller-to-vdm:controller-to-vdm", "controller-to-vdm.f32le", 221 * 221 * 4),
    ("vdm-to-pdm:active-to-full", "active-to-full-vdm.f32le", 277 * 221 * 4),
    ("vdm-to-pdm:vdm-to-pdm", "vdm-to-pdm.f32le", 277 * 277 * 4),
    ("pdm-feedback-to-vdm:full-to-active", "full-to-active-vdm.f32le", 221 * 277 * 4),
    ("pdm-feedback-to-vdm:pdm-to-vdm", "pdm-to-vdm.f32le", 277 * 277 * 4),
    ("vdm-feedback-to-controller:vdm-to-controller", "vdm-to-controller.f32le", 221 * 221 * 4),
)


def load_script(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot import {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def wait_capture_ready(helper, directory: Path, capture) -> None:
    # dumpcap reports this after opening input, initializing and flushing output.
    # Its earlier "Capturing on" banner precedes capture-loop initialization.
    helper.wait_text(directory / "dumpcap.log",
                     f"File: {directory / 'wire.pcapng'}", 30, capture)


def replay_spa_source(helper, installation, args, directory: Path, cube: Path) -> dict:
    from run_classic_spa_sender import run_sender
    if args.sender_spa_directory is not None:
        installation = replace(installation,
                               spa_library_directory=args.sender_spa_directory.resolve(strict=True))
    return run_sender(helper=helper, installation=installation,
                      directory=directory / 'spa-sender', cube=cube, frames=args.frames,
                      rate_hz=args.rate_hz, readout_us=args.readout_us,
                      rows_per_packet=args.rows_per_packet, source_cpus=args.source_cpus)


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError(f"expected one configuration insertion point: {old!r}")
    return text.replace(old, new, 1)


def cleanup_replay(helper, stop_files, processes, report):
    """Request graceful exit and retain failures without skipping other children."""
    for marker in stop_files:
        try:
            marker.touch(exist_ok=True)
        except Exception as error:
            report["errors"].append(f"stop request failed for {marker}: {error}")
    for process, log in reversed(processes):
        try:
            if Path(str(getattr(log, "name", ""))).name == "node.log":
                # Trace/report serialization is off the frame path and may
                # specialize on first use. Allow it to finish before signals.
                helper.wait_for("Julia node graceful report", lambda: process.poll() is not None, 90)
            helper.stop(process, log)
        except Exception as error:
            report["errors"].append(f"cleanup failed for PID {process.pid}: {error}")
            try:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            except Exception as fallback_error:
                report["errors"].append(f"kill failed for PID {process.pid}: {fallback_error}")
            finally:
                try:
                    log.close()
                except Exception as close_error:
                    report["errors"].append(f"log close failed for PID {process.pid}: {close_error}")
    report["process_returncodes"] = [process.returncode for process, _ in processes]
    if report["errors"]:
        report["qualified"] = False


def compare_commands(actual_path: Path, expected_path: Path, frames: int,
                     *, reference_frames: int = 7) -> dict:
    actual = np.fromfile(actual_path, dtype="<f4")
    expected = np.fromfile(expected_path, dtype="<f4")
    if (not 1 <= frames <= reference_frames or actual.size != frames * 277
            or expected.size != reference_frames * 277):
        raise ValueError("command recordings do not have the declared frame extents")
    expected = expected[:frames * 277]
    if not np.all(np.isfinite(actual)) or not np.all(np.isfinite(expected)):
        raise ValueError("nonfinite command in comparison")
    difference = np.abs(actual.astype(np.float64) - expected.astype(np.float64))
    scale = np.maximum(1.0, np.maximum(np.abs(actual), np.abs(expected)))
    failures = (difference > 1e-6) & (difference / scale > 1e-6)
    limit = np.float32(0.8)
    return {
        "qualified": not bool(np.any(failures)), "frames": frames,
        "criterion": "abs <= 1e-6 OR abs/max(abs(actual),abs(expected),1) <= 1e-6; native microns",
        "max_absolute_error_um": float(difference.max()),
        "failed_values": int(np.count_nonzero(failures)),
        "actual_values_at_limit": int(np.count_nonzero(np.abs(actual) >= limit)),
        "expected_values_at_limit": int(np.count_nonzero(np.abs(expected) >= limit)),
        "unclipped_expected_values": int(np.count_nonzero(np.abs(expected) < limit)),
        "failed_unclipped_values": int(np.count_nonzero(failures & (np.abs(expected) < limit))),
        "clipping_decision_mismatches": int(np.count_nonzero(
            (np.abs(actual) >= limit) != (np.abs(expected) >= limit))),
    }


def compare_feedback_snapshot(snapshot: dict | None, expected_path: Path, frames: int) -> dict:
    if not isinstance(snapshot, dict) or snapshot.get("unit") != "micron":
        raise ValueError("Julia owner omitted final constraint feedback snapshot")
    actual = np.asarray(snapshot.get("values"), dtype=np.float32)
    reference = np.fromfile(expected_path, dtype="<f4")
    if reference.size % 221 or not 1 <= frames <= reference.size // 221:
        raise ValueError("invalid constraint feedback reference extent")
    expected = reference.reshape(-1, 221)[frames - 1]
    if actual.shape != (221,) or not np.all(np.isfinite(actual)) or not np.all(np.isfinite(expected)):
        raise ValueError("invalid final Julia constraint feedback")
    error = np.abs(actual.astype(np.float64) - expected.astype(np.float64))
    return {"unit": "micron", "max_absolute_error": float(error.max()),
            "actual_nonzero_values": int(np.count_nonzero(actual)),
            "expected_nonzero_values": int(np.count_nonzero(expected)),
            "qualified": bool(np.all(error <= 1e-6)),
            "boundary": snapshot.get("boundary")}


def source_counters(log: str) -> dict | None:
    records = re.findall(
        r"HEART_WFS_DIAG name=rtc-heart-wfs-row-source .*?received=(\d+) "
        r"rejected=(\d+) blocks=(\d+) frames=(\d+) dropped=(\d+) starvations=(\d+)",
        log,
    )
    if len(records) != 1:
        return None
    return dict(zip(("received", "rejected", "blocks", "frames", "dropped", "starvations"),
                    map(int, records[0])))


def expected_source_counters(mode: str, frames: int, rows_per_packet: int) -> dict:
    packets = frames * (352 // rows_per_packet)
    return {"received": packets, "rejected": 0,
            "blocks": packets if mode == "row" else 0,
            "frames": frames, "dropped": 0, "starvations": 0}


def validate_node_report(report: dict, mode: str, frames: int) -> None:
    callbacks = frames * (32 if mode == "row" else 1)
    if (report.get("status") != "stopped" or
            report.get("callback_count") != callbacks or
            report.get("feedback_bridge_failed") is not False or "error" in report):
        raise RuntimeError("Julia owner did not attest successful callbacks and feedback")
    # Row callbacks are arrivals, not command publications. The separate wire
    # and adapter checks must attest exactly one ordered DM command per frame.
    if mode == "row" and (report.get("mode") != "row" or
                          report.get("callbacks_per_frame") != 32):
        raise RuntimeError("Julia owner did not attest Classic row execution")


def configure_source(text: str, mode: str) -> str:
    text = replace_once(text, "api.heart.std-wfs.width = 64", "api.heart.std-wfs.width = 352")
    text = replace_once(text, "api.heart.std-wfs.height = 64", "api.heart.std-wfs.height = 352")
    if mode == "row":
        text = replace_once(text, "context.properties = {",
                            "context.properties = {\n    link.max-buffers = 64")
        text = replace_once(text, "api.heart.std-wfs.output-mode = frame",
                            "api.heart.std-wfs.output-mode = row-block\n"
                            "            api.heart.std-wfs.row-block-rows = 11")
        # Explicit ndarray-schema is the frame-only raw-pixel adapter option.
        # Row mode already declares its canonical row-block schema.
        text = replace_once(text, "api.heart.std-wfs.ndarray-schema = org.calculon.ao.raw-detector-pixels/1", "")
    return text


def install_graph(helper, qualifier, directory: Path, fixture: Path,
                  plugin: Path, rate: int, mode: str = "frame") -> tuple[str, str]:
    graph_path = directory / "graph.conf"
    profile = qualifier.load_prepared_profile(fixture / "prepared-profile.toml")
    if (profile.detector_height, profile.detector_width, profile.frame_count,
            profile.subaperture_count, profile.controlled_vdm_size,
            profile.full_vdm_size, profile.pdm_size) != (352, 352, 7, 188, 221, 277, 277):
        raise ValueError("prepared fixture is not the pinned Classic geometry")
    if abs(profile.clwc_anti_windup_gain - 0.99) > 1e-6:
        raise ValueError("Classic HEART comparison requires anti-windup gain 0.99")
    graph = (qualifier.resolve_row_feedback_config(plugin, profile, 11, 0, 7)
             if mode == "row" else qualifier.resolve_config(plugin, profile, 0, 7))
    # The deployed startup-artifact interface accepts F32 only. The developed
    # SHWFS declaration also accepts origins and active state at construction.
    # Use those public fields for these two typed parameters, checking the
    # exported origin array against the profile rather than dropping its data.
    origins = np.fromfile(fixture / "subaperture-origins.u32le", dtype="<u4")
    if not np.array_equal(origins, np.asarray(profile.subaperture_origins, dtype=np.uint32).ravel()):
        raise ValueError("exported origins differ from the prepared profile")
    active = np.fromfile(fixture / "active-subapertures.u8", dtype=np.uint8)
    if active.size != 188 or np.any(active > 1):
        raise ValueError("invalid exported active mask")
    active_field = "active = [ " + " ".join(
        "true" if value else "false" for value in active) + " ]"
    graph = (replace_once(graph, "active = null", active_field) if mode == "row"
             else replace_once(graph, "coordinate_scale = 1.0",
                               "coordinate_scale = 1.0\n                    " + active_field))
    # The scientific port rate must match the offered rate, not the fixture's
    # original 10 Hz. Preserve the parameter values and graph topology.
    graph = graph.replace(
        f"rate = [ {profile.frame_rate[0]} {profile.frame_rate[1]} ]",
        f"rate = [ {rate} 1 ]",
    )
    graph, count = re.subn(
        r"outputs = \[.*?\]",
        'outputs = [ "pdm-command:demanded" '
        '"vdm-feedback-to-controller:controller-constraint-feedback" ]',
        graph, flags=re.S,
    )
    if count != 1:
        raise ValueError("Classic topology must have one output boundary")
    graph_path.write_text(graph)
    body = graph.split("filter.graph = ", 1)[1].rsplit("\n}", 1)[0]
    startup = []
    for port, name, size in PARAMETERS:
        parameter = fixture / name
        if parameter.stat().st_size != size:
            raise ValueError(f"invalid prepared parameter extent: {parameter}")
        if name in ("subaperture-origins.u32le", "active-subapertures.u8"):
            continue
        if mode == "row":
            port = port.replace("shack-hartmann:", "reconstruction:")
        startup.append(
            f"            {helper.spa_quote('pipewireao.startup-parameter.' + port)}"
            f" = {helper.spa_quote(str(parameter))}"
        )
    graph_name = "calculon-revolt-classic-" + ("row" if mode == "row" else "fullframe")
    module = """    {
        name = libpipewire-module-ndarray-filter-chain
        args = {
            node.name = %s
            node.reliable = true
            pipewireao.fifo-inputs = true
%s
            "pipewireao.feedback.closed-loop-correction:constraint-feedback" =
                "vdm-feedback-to-controller:controller-constraint-feedback"
            filter.graph = %s
        }
    }
""" % (graph_name, "\n".join(startup), body)
    config_path = directory / "config/fgn-copper-live.conf"
    config_path.write_text(replace_once(
        config_path.read_text(), "]\n\ncontext.objects = [",
        module + "]\n\ncontext.objects = [",
    ))
    return graph_name, "pixel-calibration:raw"


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=("fgn", "jfg"), required=True)
    parser.add_argument("--mode", choices=("frame", "row"), default="frame")
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--cube", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=7)
    parser.add_argument("--replay-corpus", type=Path,
                        help="validated repeated FITS and continuous controller references")
    parser.add_argument("--numerical-acceptance", choices=("strict", "source-arithmetic"), default="strict")
    parser.add_argument("--rate-hz", type=int, default=10)
    parser.add_argument("--readout-us", type=int, default=2000)
    parser.add_argument("--rows-per-packet", type=int, default=11)
    installation = parser.add_mutually_exclusive_group()
    installation.add_argument("--pipewire-prefix", type=Path)
    installation.add_argument("--pipewire-root", type=Path)
    parser.add_argument("--fgn-root", type=Path, default=WORKSPACE / "calculon-algorithms-progressive-requal")
    parser.add_argument("--jfg-root", type=Path, default=WORKSPACE / "JuliaFilterGraph-progressive-requal")
    parser.add_argument("--plugin", type=Path, required=True)
    parser.add_argument("--heart-plugin", type=Path, required=True)
    parser.add_argument("--heart-plugin-sha256", required=True)
    parser.add_argument("--wfs-simulator", type=Path, required=True)
    parser.add_argument("--sender", choices=("wfs-simulator", "spa"), default="wfs-simulator")
    parser.add_argument("--sender-spa-directory", type=Path,
                        help="private source plugin directory for SPA sender qualification")
    parser.add_argument("--rtc-cpus")
    parser.add_argument("--source-cpus")
    parser.add_argument("--lab-loop-cpu", type=int)
    parser.add_argument("--lab-loop-rt-priority", type=int, default=83)
    parser.add_argument("--adapter-loop-cpu", type=int)
    parser.add_argument("--node-loop-cpu", type=int)
    parser.add_argument("--julia-pin-cpus")
    parser.add_argument("--row-workers", type=int, default=0)
    parser.add_argument("--matrix-layout", choices=("shared", "sharded"), default="shared")
    parser.add_argument("--trace-callbacks", type=int, default=0)
    parser.add_argument("--callback-trace", type=Path)
    args = parser.parse_args()
    if not 1 <= args.frames <= (1029 if args.replay_corpus else 7):
        parser.error("Classic gate requires 1..7 frames, or at most 1029 with --replay-corpus")
    if args.replay_corpus and args.frames % 7:
        parser.error("--replay-corpus requires a multiple of seven frames")
    if args.row_workers < 0 or args.trace_callbacks < 0:
        parser.error("worker and trace capacities must be nonnegative")
    if args.lab_loop_cpu is not None and not 1 <= args.lab_loop_rt_priority <= 99:
        parser.error("loop priority must be in 1..99")
    if args.rate_hz < 1 or args.readout_us < 1 or args.readout_us * args.rate_hz >= 950000:
        parser.error("readout must be positive and below 95% of the frame period")
    if args.rows_per_packet < 1 or 352 % args.rows_per_packet:
        parser.error("rows-per-packet must be a positive divisor of 352")
    if args.rows_per_packet * 352 * 2 > 8024:
        parser.error("rows-per-packet exceeds wfsSimulator's 8024-byte payload limit")
    if args.mode == "row" and args.rows_per_packet != 11:
        parser.error("the qualified Classic row graph requires 11 rows per packet")
    return args


def main():
    args = arguments()
    sys.path.insert(0, str(args.fgn_root.resolve() / "scripts"))
    helper = load_script("classic_live_transport", args.fgn_root / "scripts/run_fgn_copper_fullframe_live.py")
    qualifier = load_script("classic_graph_qualifier", args.fgn_root / "scripts/qualify_fgn_revolt_classic.py")
    directory, fixture, cube = args.output.resolve(), args.fixture.resolve(), args.cube.resolve()
    expected_commands = fixture / "demanded_pdm_command.f32le"
    reference_frames = 7
    corpus_manifest = None
    if args.replay_corpus:
        from classic_replay_corpus import validate_replay_corpus
        corpus_manifest = validate_replay_corpus(args.replay_corpus.resolve(), fixture, cube, args.frames)
        expected_commands = args.replay_corpus.resolve() / "demanded_pdm_command.f32le"
        reference_frames = expected_commands.stat().st_size // (277 * 4)
    if directory.exists():
        raise ValueError(f"output already exists: {directory}")
    helper.verify_abi7(args.plugin)
    helper.verify_heart_plugin(args.heart_plugin, args.heart_plugin_sha256)
    installation = helper.pipewire_installation(
        args.pipewire_root, args.pipewire_prefix or
        (None if args.pipewire_root else Path("/opt/pipewireao")))
    directory.mkdir(parents=True)
    env = helper.make_environment(directory, args.heart_plugin.resolve(), args.rate_hz, installation,
                                  args.lab_loop_cpu, args.lab_loop_rt_priority if args.lab_loop_cpu is not None else None)
    env["HEART_RTC_DIAG"] = "1"
    helper.use_native_julia_libraries(directory, installation, env)
    config = directory / "config/fgn-copper-live.conf"
    config.write_text(configure_source(config.read_text(), args.mode))
    # Only one DM consumer. The feedback ports are host-local, not PipeWire links.
    adapter_env = helper.reliable_adapter_environment(env)
    if args.adapter_loop_cpu is not None:
        adapter_env, _ = helper.private_client_environment(
            adapter_env, directory, installation, "adapter",
            helper.ClientDataLoopRequest((args.adapter_loop_cpu,), args.lab_loop_rt_priority))
    node_env = helper.reliable_adapter_environment(env)
    if args.node_loop_cpu is not None:
        node_env, _ = helper.private_client_environment(
            node_env, directory, installation, "node",
            helper.ClientDataLoopRequest((args.node_loop_cpu,), args.lab_loop_rt_priority))
    if args.julia_pin_cpus:
        node_env["JULIA_RTC_PIN_CPUS"] = args.julia_pin_cpus
    report = {
        "role": args.role, "receiver_mode": "row-block" if args.mode == "row" else "complete-frame", "frames": args.frames,
        "rate_hz": args.rate_hz, "readout_us": args.readout_us,
        "rows_per_packet": args.rows_per_packet, "qualified": False,
        "scope": "live transport and numerical characterization; performance claims require repeated campaign",
        "placement_request": {"rtc_cpus": args.rtc_cpus, "source_cpus": args.source_cpus,
                              "daemon_loop_cpu": args.lab_loop_cpu, "adapter_loop_cpu": args.adapter_loop_cpu,
                              "node_loop_cpu": args.node_loop_cpu, "fifo_priority": args.lab_loop_rt_priority,
                              "julia_pin_cpus": args.julia_pin_cpus},
        "row_workers": args.row_workers, "matrix_layout": args.matrix_layout,
        "sha256": {str(path): helper.sha256_file(path) for path in
                   (cube, args.plugin, args.heart_plugin, args.wfs_simulator,
                    fixture / "prepared-profile.toml")},
        "parameter_sha256": {name: helper.sha256_file(fixture / name)
                             for _, name, _ in PARAMETERS},
        "errors": [],
        "replay_corpus": corpus_manifest,
        "command_reference_sha256": helper.sha256_file(expected_commands),
        "pipewire_provenance": helper.pipewire_provenance(
            installation, installation.module_directory / "libpipewire-module-ndarray-filter-chain.so"),
    }
    processes = []
    stop_files = []
    try:
        if args.role == "fgn":
            graph_name, raw_port = install_graph(helper, qualifier, directory, fixture, args.plugin.resolve(), args.rate_hz, args.mode)
            command_port = "pdm-command:demanded"
        else:
            graph_name = "julia-revolt-classic-" + ("row" if args.mode == "row" else "fullframe")
            raw_port, command_port = "raw", "demanded"
        report["daemon_configuration_sha256"] = helper.sha256_file(config)
        if args.role == "fgn":
            report["resolved_graph_sha256"] = helper.sha256_file(directory / "graph.conf")
        daemon, log = helper.start(helper.placed([str(installation.daemon), "-c", config.name], args.rtc_cpus), env, directory / "daemon.log", cwd=installation.working_directory)
        processes.append((daemon, log))
        def socket_ready():
            if daemon.poll() is not None:
                raise RuntimeError(f"PipeWireAO exited with {daemon.returncode}; see daemon.log")
            return (Path(env["XDG_RUNTIME_DIR"]) / helper.REMOTE).exists()
        helper.wait_for("private PipeWireAO socket", socket_ready)
        if args.role == "jfg":
            node_stop = directory / "node.stop"
            stop_files.append(node_stop)
            node, log = helper.start(helper.placed([
                "julia", "--startup-file=no", f"--project={args.jfg_root / 'benchmark'}", f"--threads={args.row_workers + 2},0",
                str(args.jfg_root / "benchmark/run_classic_pipewire_node.jl"),
                "--fixture", str(fixture), "--remote", helper.REMOTE,
                "--rate-hz", str(args.rate_hz), "--stop-file", str(node_stop),
                "--mode", args.mode, "--row-workers", str(args.row_workers),
                "--matrix-layout", args.matrix_layout,
                *(["--trace-callbacks", str(args.trace_callbacks), "--callback-trace",
                   str(args.callback_trace or directory / "callback-trace.csv")] if args.trace_callbacks else []),
                "--report", str(directory / "node-report.json"),
            ], args.rtc_cpus), node_env, directory / "node.log")
            processes.append((node, log))
            helper.wait_text(directory / "node.log", "CONNECT_ACCEPTED", 90, node)
        adapter_stop = directory / "adapter.stop"
        stop_files.append(adapter_stop)
        adapter, log = helper.start(helper.placed([
            "julia", "--startup-file=no", f"--project={args.jfg_root / 'benchmark'}", "--threads=2",
            str(args.jfg_root / "scripts/heart_std_dm_command_adapter.jl"), helper.REMOTE,
            str(adapter_stop), str(args.rate_hz), "277", str(directory / "adapter-sequences.csv"),
        ], args.rtc_cpus), adapter_env, directory / "adapter.log")
        processes.append((adapter, log))
        helper.wait_text(directory / "adapter.log", "CONNECT_ACCEPTED", 90, adapter)
        helper.links(installation.tool("pwao-link"), env, [
            ("rtc-heart-wfs-row-source:output", f"{graph_name}:{raw_port}"),
            (f"{graph_name}:{command_port}", "julia-heart-std-dm-command-adapter:demanded"),
            ("julia-heart-std-dm-command-adapter:standard-dm", "rtc-heart-std-dm-sink:command"),
        ])
        helper.wait_text(directory / "adapter.log", "PREPARED", 60, adapter)
        if args.role == "jfg":
            helper.wait_text(directory / "node.log", "PREPARED", 60, node)
        (directory / "graph-before-replay.json").write_text(helper.command([str(installation.tool("pwao-dump")), "-r", helper.REMOTE], env))
        placement_processes = [("daemon", daemon), ("adapter", adapter)]
        if args.role == "jfg":
            placement_processes.append(("node", node))
        from classic_placement import record_placement
        record_placement(directory, "before", placement_processes, args)
        helper.capture_thread_map(directory / "thread-map-before-replay.txt", placement_processes)
        capture, log = helper.start(["dumpcap", "-p", "-i", "any", "-f", "udp port 6000 or udp port 6100", "-w", str(directory / "wire.pcapng")], env, directory / "dumpcap.log")
        processes.append((capture, log))
        wait_capture_ready(helper, directory, capture)
        (directory / "input.fits").symlink_to(cube)
        source = helper.placed([str(args.wfs_simulator.resolve()), "-file", "input.fits", "-tPort", "6000", "-period", repr(1 / args.rate_hz), "-readout", str(args.readout_us), "-lines", str(args.rows_per_packet), "-numFrames", str(args.frames)], args.source_cpus)
        report["source_command"] = source
        if args.sender == 'spa':
            report['spa_sender'] = replay_spa_source(helper, installation, args, directory, cube)
            report['source_command'] = report['spa_sender']['source_command']
        else:
            (directory / "wfs-simulator.log").write_text(helper.command(source, env, cwd=directory, timeout=args.frames / args.rate_hz + 30))
        time.sleep(0.5)
        record_placement(directory, "after", placement_processes, args)
        helper.stop(capture, log)
        for port, name in ((6000, "wfs-packets.tsv"), (6100, "dm-packets.tsv")):
            (directory / name).write_text(helper.command(["tshark", "-r", str(directory / "wire.pcapng"), "-Y", f"udp.port=={port}", "-T", "fields", "-e", "frame.time_epoch", "-e", "udp.length", "-e", "data.data"], env))
        scripts = args.jfg_root / "benchmark/heart"
        helper.command([sys.executable, str(scripts / "decode_std_dm_packets.py"), str(directory / "dm-packets.tsv"), "--vectors", str(directory / "dm-wire-um.f32"), "--summary", str(directory / "dm-summary.json")], env)
        helper.command([sys.executable, str(scripts / "qualify_copper_aos_capture.py"), "--fits", str(cube), "--frames", str(args.frames), "--period", repr(1 / args.rate_hz), "--readout-us", str(args.readout_us), "--lines", str(args.rows_per_packet), "--wfs-packets", str(directory / "wfs-packets.tsv"), "--dm-summary", str(directory / "dm-summary.json"), "--dm-id-base", "0", "--summary", str(directory / "physical-summary.json")], env)
        numerical = compare_commands(directory / "dm-wire-um.f32", expected_commands,
                                     args.frames, reference_frames=reference_frames)
        (directory / "numerical-summary.json").write_text(json.dumps(numerical, indent=2) + "\n")
        numerical_passed = numerical["qualified"]
        if args.numerical_acceptance == "source-arithmetic":
            from classic_numerical_acceptance import acceptance_for_wire
            acceptance = acceptance_for_wire(fixture, np.fromfile(expected_commands, dtype="<f4").reshape(-1, 277)[:args.frames],
                                             directory / "dm-wire-um.f32", args.frames, args.role, args.mode)
            (directory / "arithmetic-acceptance.json").write_text(json.dumps(acceptance, indent=2) + "\n")
            report["arithmetic_acceptance"] = acceptance
            numerical_passed = acceptance["arithmetic_consistency_passed"]
        if not numerical_passed or numerical["clipping_decision_mismatches"]:
            raise RuntimeError("physical command comparison failed; see numerical-summary.json")
        report["qualified"] = True
    except Exception as error:
        report["errors"].append(str(error))
        raise
    finally:
        cleanup_replay(helper, stop_files, processes, report)
        if report["qualified"]:
            try:
                helper.validate_adapter_sequences(directory / "adapter-sequences.csv", args.frames)
                if args.role == "jfg":
                    node_report = json.loads((directory / "node-report.json").read_text())
                    validate_node_report(node_report, args.mode, args.frames)
                    if args.replay_corpus:
                        report["final_constraint_feedback"] = compare_feedback_snapshot(
                            node_report.get("final_constraint_feedback"),
                            args.replay_corpus / "controller-constraint-feedback.f32le", args.frames)
                        if not report["final_constraint_feedback"]["qualified"]:
                            raise RuntimeError("final Julia constraint feedback differs from reference")
                if any(process.returncode != 0 for process, _ in processes):
                    raise RuntimeError("a replay process exited unsuccessfully")
            except Exception as error:
                report["qualified"] = False
                report["errors"].append(str(error))
        counters = source_counters((directory / "daemon.log").read_text()) if (directory / "daemon.log").exists() else None
        report["source_counters"] = counters
        if report["qualified"] and counters != expected_source_counters(args.mode, args.frames, args.rows_per_packet):
            report["qualified"] = False
            report["errors"].append("source counters missing or do not attest loss-free delivery")
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["qualified"]:
        raise RuntimeError("Classic replay failed qualification; see report.json")


if __name__ == "__main__":
    main()
