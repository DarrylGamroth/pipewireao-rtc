#!/usr/bin/env python3
"""Run the RTC-ARCH-019 Copper post-install baseline sequentially.

This is an orchestration record, not another graph runner.  It invokes the
maintained HEART, FGN, and JFG runners with one fixed Copper fixture, retains
their raw records, and fails closed unless every replay delivers every frame.
"""

from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import resource
import shutil
import struct
import subprocess
import sys
from typing import Any

from lab_placement import LaunchError, parse_cpu_list, parse_thread_policy, read_thread_profile


ROOT = Path(__file__).resolve().parents[1]
WORKSPACES = ROOT.parent
JFG = WORKSPACES / "JuliaFilterGraph.jl"
FGN = WORKSPACES / "calculon-algorithms-main-copper"
FGN_FULLFRAME = WORKSPACES / "calculon-algorithms-copper-fullframe"
HEART = Path("/home/dgamroth/workspaces/codex/heart/heart-copper-comparison")
CUBE = JFG / "benchmark/data/revolt-copper-aos-openloop-1024f-u16.fits"
EXPECTED_CUBE_SHA256 = "880e46b8e45c848a8c2df74e5591731ea161ac7009a02ad29e2fc79f6fd06abf"
VECTOR_TOLERANCE_UM = 1e-6


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_state(path: Path) -> dict[str, Any]:
    def capture(*args: str) -> str:
        return subprocess.check_output(args, cwd=path, text=True).strip()
    try:
        return {"path": str(path), "revision": capture("git", "rev-parse", "HEAD"),
                "dirty": bool(capture("git", "status", "--porcelain")),
                "status_porcelain": capture("git", "status", "--porcelain")}
    except (OSError, subprocess.CalledProcessError) as error:
        return {"path": str(path), "unavailable": str(error)}


def archive_source_state(root: Path, destination: Path) -> dict[str, Any]:
    """Retain dirty tracked changes and small untracked source files."""
    destination.mkdir(parents=True)
    patch = subprocess.check_output(["git", "diff", "--binary", "HEAD"], cwd=root)
    patch_path = destination / "working-tree.patch"
    patch_path.write_bytes(patch)
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root,
    ).split(b"\0")
    records: list[dict[str, Any]] = []
    for encoded in filter(None, untracked):
        relative = Path(os.fsdecode(encoded))
        source = root / relative
        if (relative.parts[0] not in {"benchmark", "benchmarks", "scripts", "src",
                                   "source", "docs", "doc", "fixtures", "config"}
                or source.is_symlink() or not source.is_file()
                or source.suffix not in {".py", ".jl", ".sh", ".md", ".toml", ".conf", ".json"}):
            continue
        record: dict[str, Any] = {"path": str(relative), "sha256": sha256(source),
                                  "bytes": source.stat().st_size}
        if source.stat().st_size <= 1_048_576:
            copy = destination / "untracked" / relative
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, copy)
            record["archive"] = str(copy)
        records.append(record)
    return {"patch": str(patch_path), "patch_sha256": sha256(patch_path),
            "untracked": records}


def command_record(argv: list[str], cwd: Path, log: Path, overrides: dict[str, str] | None = None) -> dict[str, Any]:
    environment = os.environ.copy(); environment.update(overrides or {})
    completed = subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, check=False, env=environment)
    log.write_text(completed.stdout)
    return {"argv": argv, "cwd": str(cwd), "returncode": completed.returncode,
            "combined_output": str(log), "environment_overrides": overrides or {}}


def require_exact(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def json_file(path: Path) -> dict[str, Any]:
    require_exact(path.is_file(), f"required result is absent: {path}")
    value = json.loads(path.read_text())
    require_exact(isinstance(value, dict), f"result is not a JSON object: {path}")
    return value


def require_heart(run: Path, frames: int) -> dict[str, Any]:
    report = json_file(run / "qualification.json")
    require_exact(report.get("qualified") is True, "HEART capture is not qualified")
    require_exact(report.get("captured_wfs_packets") == frames * 2,
                  "HEART did not capture exactly two WFS packets per frame")
    require_exact(report.get("captured_dm_commands") == frames,
                  "HEART did not capture exactly one DM command per frame")
    return report


def require_fgn(run: Path, frames: int, daemon_sha256: str,
                module_sha256: str) -> dict[str, Any]:
    report = json_file(run / "report.json")
    physical = json_file(run / "physical-summary.json")
    require_exact(report.get("qualified") is True and not report.get("errors"),
                  "FGN runner did not qualify exact delivery")
    require_exact(report.get("requested_frames") == frames and
                  report.get("demanded_vectors") == frames and report.get("dm_vectors") == frames,
                  "FGN report does not contain exactly one demanded and DM vector per frame")
    require_exact(physical.get("qualified") is True and
                  physical.get("captured_wfs_packets") == frames * 2 and
                  physical.get("captured_dm_commands") == frames,
                  "FGN physical capture is not an exact delivery")
    provenance = report.get("provenance", report)
    require_exact(provenance.get("pipewire_mode") == "installed-prefix" and
                  provenance.get("pipewire_daemon_sha256") == daemon_sha256 and
                  provenance.get("ndarray_filter_chain_sha256") == module_sha256,
                  "FGN used a different native PipeWireAO daemon or filter module")
    return physical


def require_jfg(report_path: Path, frames: int) -> tuple[dict[str, Any], dict[str, Any]]:
    report = json_file(report_path)
    qualification = report.get("qualification")
    require_exact(isinstance(qualification, dict) and qualification.get("passed") is True,
                  "JFG runner did not qualify exact delivery")
    require_exact(report.get("requested_frames") == frames and
                  report.get("std_wfs_packet_count") == frames * 2 and
                  report.get("std_dm_packet_count") == frames,
                  "JFG report does not contain exact WFS and DM delivery")
    physical_path = Path(report["physical_summary"])
    physical = json_file(physical_path)
    require_exact(physical.get("qualified") is True,
                  "JFG physical capture is not qualified")
    return report, physical


def paths_under(directory: Path) -> list[str]:
    return [str(path) for path in sorted(directory.rglob("*")) if path.is_file() or path.is_symlink()]


WFS_HEADER = struct.Struct("<4B8HIQII")
DM_HEADER = struct.Struct("<4BHHQII")


def capture_times(path: Path, count: int, *, kind: str,
                  dm_id_base: int = 0) -> list[Decimal]:
    """Read capture-order times after checking packet identity in each slot."""
    require_exact(kind in ("wfs", "dm"), f"unknown packet kind: {kind}")
    header = WFS_HEADER if kind == "wfs" else DM_HEADER
    times: list[Decimal] = []
    with path.open(encoding="ascii") as packets:
        for ordinal, line in enumerate(packets):
            fields = line.rstrip("\n").split("\t")
            require_exact(len(fields) == 3, f"expected three TSV fields in {path}")
            field, _, packet_hex = fields
            try:
                timestamp = Decimal(field)
            except InvalidOperation as error:
                raise RuntimeError(f"invalid packet timestamp in {path}") from error
            require_exact(timestamp.is_finite() and timestamp >= 0,
                          f"nonfinite or negative packet timestamp in {path}")
            require_exact(len(packet_hex) >= 2 * header.size,
                          f"short {kind} header at packet {ordinal + 1} in {path}")
            try:
                packet_header = bytes.fromhex(packet_hex[:2 * header.size])
            except ValueError as error:
                raise RuntimeError(f"invalid {kind} header at packet {ordinal + 1} in {path}") from error
            decoded = header.unpack(packet_header)
            if kind == "wfs":
                sequence, datagrams, frame_id = decoded[10], decoded[11], decoded[-2]
                require_exact((frame_id, sequence, datagrams) ==
                              (ordinal // 2, ordinal % 2 + 1, 2),
                              f"WFS packet identity/order mismatch at packet {ordinal + 1} in {path}")
            else:
                sequence, datagrams, frame_id = decoded[2], decoded[3], decoded[-2]
                require_exact((frame_id, sequence, datagrams) ==
                              (dm_id_base + ordinal, 1, 1),
                              f"DM packet identity/order mismatch at packet {ordinal + 1} in {path}")
            times.append(timestamp)
    require_exact(len(times) == count, f"expected {count} packet timestamps in {path}")
    require_exact(all(a <= b for a, b in zip(times, times[1:])),
                  f"packet timestamps regress in {path}")
    return times


def latency_summary_us(values: list[Decimal]) -> dict[str, float | int]:
    require_exact(bool(values), "empty capture latency window")
    ordered = sorted(values)

    def percentile(fraction: float) -> float:
        position = (len(ordered) - 1) * fraction
        low, high = math.floor(position), math.ceil(position)
        return float(ordered[low] + (ordered[high] - ordered[low]) *
                     Decimal(str(position - low)))

    return {"count": len(values), "min": float(ordered[0]),
            "p50": percentile(0.50), "p99": percentile(0.99),
            "max": float(ordered[-1])}


def capture_latency_phases(wfs_path: Path, dm_path: Path, frames: int,
                           *, dm_id_base: int) -> dict[str, Any]:
    """Summarize capture-order packet pairs with explicit identity checks."""
    wfs = capture_times(wfs_path, 2 * frames, kind="wfs")
    dm = capture_times(dm_path, frames, kind="dm", dm_id_base=dm_id_base)
    first = [(dm[index] - wfs[2 * index]) * 1_000_000 for index in range(frames)]
    terminal = [(dm[index] - wfs[2 * index + 1]) * 1_000_000
                for index in range(frames)]
    readout = [(wfs[2 * index + 1] - wfs[2 * index]) * 1_000_000
               for index in range(frames)]
    require_exact(all(value >= 0 for value in terminal),
                  "DM packet preceded its terminal WFS packet")
    intervals = {"first_wfs_packet_to_dm_us": first,
                 "terminal_wfs_packet_to_dm_us": terminal,
                 "first_to_terminal_wfs_us": readout}
    return {
        "first_frame": {name: float(values[0]) for name, values in intervals.items()},
        "frames_2_through_10": ({name: latency_summary_us(values[1:10])
                                for name, values in intervals.items()}
                               if frames >= 10 else None),
        "frames_101_onward": ({name: latency_summary_us(values[100:])
                              for name, values in intervals.items()}
                             if frames > 100 else None),
        "all_frames": {name: latency_summary_us(values)
                       for name, values in intervals.items()},
    }


def require_placement(paths: dict[str, dict[str, Path]],
                      profile_sha256: str | None = None) -> dict[str, dict[str, str]]:
    verified: dict[str, dict[str, str]] = {}
    for phase, roles in paths.items():
        verified[phase] = {}
        for role, path in roles.items():
            report = json_file(path)
            require_exact(report.get("outcome") == "verified",
                          f"{role} placement is not verified at {phase}: {path}")
            if profile_sha256 is not None:
                require_exact(report.get("requested", {}).get("thread_profile_sha256") == profile_sha256,
                              f"{role} used a different thread profile at {phase}: {path}")
            verified[phase][role] = str(path)
    return verified


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="new directory for the immutable baseline record")
    parser.add_argument("--repeats", type=int, default=1,
                        help="sequential repetitions of the fixed workload (default: 1)")
    parser.add_argument("--mode", choices=("row", "fullframe"), default="row",
                        help="FGN ingress mode; row is the selected baseline")
    parser.add_argument("--frames", type=int, default=1024)
    parser.add_argument("--jfg-graph-warmup", choices=("offline", "none"), default="offline",
                        help="recorded JFG first-use policy (default: offline)")
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--heart-root", type=Path, default=HEART)
    parser.add_argument("--revolt-config-dir", type=Path,
                        default=Path("/home/dgamroth/workspaces/codex/heart/revolt-rtc/config"))
    parser.add_argument("--wfs-simulator", type=Path,
                        default=HEART / "source/testServer/bin/wfsSimulator")
    parser.add_argument("--fgn-root", type=Path, default=FGN)
    parser.add_argument("--fgn-fullframe-root", type=Path, default=FGN_FULLFRAME)
    parser.add_argument("--jfg-root", type=Path, default=JFG)
    parser.add_argument("--heart-cpu-map", type=Path, default=JFG / "benchmark/heart/affinity/ryzen-6800h.cpu")
    parser.add_argument("--heart-thread-map", type=Path, default=JFG / "benchmark/heart/affinity/ryzen-6800h.threads")
    parser.add_argument("--source-core", default="12")
    parser.add_argument("--source-rt-priority", default="20")
    parser.add_argument("--rtc-cpus", default="0,2,4,6,8,10,14")
    parser.add_argument("--verify-placement", action="store_true",
                        help="verify declared process envelopes before ingress and after replay")
    parser.add_argument("--strict-placement-profile", type=Path,
                        help="host-specific thread profile enforced by every pre-ingress verifier")
    parser.add_argument("--julia-pin-cpus", default="0,2",
                        help="CPU list for the two Julia island threads when verifying placement")
    args = parser.parse_args()
    if not 1 <= args.frames <= 1024:
        parser.error("--frames must be in 1..1024")
    if args.repeats < 1:
        parser.error("--repeats must be positive")

    output = args.output_dir.resolve()
    if output.exists():
        parser.error(f"--output-dir already exists: {output}")
    cube = (args.jfg_root / "benchmark/data/revolt-copper-aos-openloop-1024f-u16.fits").resolve()
    fgn_runner = args.fgn_root / ("scripts/run_fgn_copper_row_live.py" if args.mode == "row"
                                  else "scripts/run_fgn_copper_fullframe_live.py")
    native_daemon = args.pipewire_prefix / "bin/pipewire-ao"
    native_module = (args.pipewire_prefix / "lib/x86_64-linux-gnu/pipewire-ao-0.3"
                     / "libpipewire-module-ndarray-filter-chain.so")
    required = (cube, native_daemon, native_module,
                args.pipewire_prefix / "lib/x86_64-linux-gnu/spa-ao-0.2/heart/libspa-heart.so",
                args.heart_root / "source/template/bin/scaoTemplate",
                args.jfg_root / "benchmark/heart/run_copper_aos_matched.sh",
                args.jfg_root / "benchmark/heart/compare_command_vectors.py",
                args.jfg_root / "benchmark/heart/qualify_copper_aos_capture.py",
                args.jfg_root / "benchmark/heart/copper_config_aos_matched.yaml",
                args.jfg_root / "scripts/pipewire_harness.jl",
                args.fgn_root / "scripts/run_fgn_copper_row_live.py",
                args.fgn_root / "scripts/run_fgn_copper_fullframe_live.py",
                args.fgn_fullframe_root / "target/release/libcalculon_fgn_bundle.so",
                args.jfg_root / "benchmark/run_shared_copper_fits.jl", args.wfs_simulator,
                args.heart_cpu_map, args.heart_thread_map, Path(__file__).resolve())
    for path in required:
        if not path.exists():
            parser.error(f"required path is absent: {path}")
    if not args.revolt_config_dir.is_dir():
        parser.error(f"REVOLT configuration directory is absent: {args.revolt_config_dir}")
    if sha256(cube) != EXPECTED_CUBE_SHA256:
        parser.error(f"Copper FITS SHA-256 differs from selected fixture: {cube}")
    verifier = ROOT / "benchmark/lab_placement.py"
    if args.verify_placement and not verifier.is_file():
        parser.error(f"placement verifier is absent: {verifier}")
    thread_profile = None
    thread_profile_sha256 = None
    fgn_loop: tuple[int, int] | None = None
    if args.strict_placement_profile is not None:
        if not args.verify_placement:
            parser.error("--strict-placement-profile requires --verify-placement")
        thread_profile = args.strict_placement_profile.resolve()
        try:
            profile = read_thread_profile(thread_profile)
        except LaunchError as error:
            parser.error(str(error))
        required_roles = {"heart-rtc", "pipewire-ao-daemon", "fgn-command-observer",
                          "julia-heart-std-dm-command-adapter", "daemon", "island", "observer", "adapter"}
        if set(profile["roles"]) != required_roles:
            parser.error(f"strict thread profile must define exactly {sorted(required_roles)}")
        loop_rules = [rule for rule in profile["roles"]["pipewire-ao-daemon"]["required_thread_placements"]
                      if parse_thread_policy(rule["policy"])[0] == "fifo" and rule["count"] == 1
                      and len(parse_cpu_list(rule["cpus"])) == 1]
        if len(loop_rules) != 1:
            parser.error("strict profile requires one pinned FIFO daemon data-loop placement")
        fgn_loop = (next(iter(parse_cpu_list(loop_rules[0]["cpus"]))),
                    parse_thread_policy(loop_rules[0]["policy"])[1])
        thread_profile_sha256 = sha256(thread_profile)
    try:
        source_cpus = parse_cpu_list(args.source_core)
        rtc_cpus = parse_cpu_list(args.rtc_cpus)
        julia_pin_cpus = parse_cpu_list(args.julia_pin_cpus)
        source_priority = int(args.source_rt_priority)
    except (argparse.ArgumentTypeError, ValueError) as error:
        parser.error(f"invalid CPU or source-priority setting: {error}")
    if not 1 <= source_priority <= 99:
        parser.error("source RT priority must be in 1..99")
    allowed_cpus = set(os.sched_getaffinity(0))
    declared_cpus = source_cpus | rtc_cpus | (julia_pin_cpus if args.verify_placement else set())
    if not declared_cpus <= allowed_cpus:
        parser.error(f"declared CPUs unavailable to launcher: {sorted(declared_cpus - allowed_cpus)}")
    source_probe = subprocess.run(
        ["taskset", "-c", args.source_core, "chrt", "-f", str(source_priority), "true"],
        text=True, capture_output=True, check=False,
    )
    if source_probe.returncode:
        parser.error(f"source FIFO placement preflight failed: {source_probe.stderr.strip()}")

    output.mkdir(parents=True)
    rtprio_limit = resource.getrlimit(resource.RLIMIT_RTPRIO)
    memlock_limit = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    manifest: dict[str, Any] = {
        "profile": "RTC-ARCH-019 step 1 post-install Copper baseline",
        "qualification_scope": "exact delivery, numerical parity, broad process envelopes",
        "rtc_dev_019_qualified": False,
        "mode": args.mode, "repeats": args.repeats, "frames": args.frames,
        "frame_rate_hz": 474, "readout_us": 2000, "clipping_feedback": True,
        "jfg_graph_warmup": args.jfg_graph_warmup,
        "verify_placement": args.verify_placement,
        "strict_placement_profile": str(thread_profile) if thread_profile else None,
        "strict_placement_profile_sha256": thread_profile_sha256,
        "command_limit_um": 0.8, "fits": str(cube), "fits_sha256": sha256(cube),
        "host": {"uname": platform.uname()._asdict(),
                 "launcher_affinity": sorted(allowed_cpus),
                 "rtprio_limit": list(rtprio_limit),
                 "memlock_limit_bytes": list(memlock_limit),
                 "source_fifo_preflight": {"cpus": sorted(source_cpus),
                                           "priority": source_priority,
                                           "returncode": source_probe.returncode}},
        "source_revisions": {name: git_state(path) for name, path in
                             (("rtc_deployment", ROOT), ("jfg", args.jfg_root),
                              ("fgn", args.fgn_root), ("fgn_fullframe", args.fgn_fullframe_root),
                              ("pipewireao_core", WORKSPACES / "pipewire"),
                              ("heart", args.heart_root))},
        "source_archives": {name: archive_source_state(path, output / "source-state" / name)
                            for name, path in (("rtc_deployment", ROOT), ("jfg", args.jfg_root),
                                               ("fgn", args.fgn_root),
                                               ("fgn_fullframe", args.fgn_fullframe_root),
                                               ("heart", args.heart_root))},
        "inherited_runtime_environment": {
            key: value for key, value in sorted(os.environ.items())
            if key.startswith(("JULIA_RTC_", "PIPEWIREAO_", "HRT_", "OPENBLAS_", "OMP_"))
            or key in {"JULIA_NUM_THREADS", "LD_LIBRARY_PATH", "XDG_RUNTIME_DIR"}
        },
        "revolt_config_sha256": {str(path): sha256(path) for path in
                                 sorted(args.revolt_config_dir.iterdir()) if path.is_file()},
        "binary_sha256": {str(path): sha256(path) for path in
                          (*required, *((verifier,) if args.verify_placement else ())) if path.is_file()},
        "runs": [], "qualified": False,
    }
    manifest_path = output / "manifest.json"
    try:
        for index in range(1, args.repeats + 1):
            run = output / f"run-{index:03d}"
            run.mkdir()
            heart_dir, fgn_dir = run / "heart", run / "fgn"
            jfg_report = run / "jfg.json"
            period = repr(1.0 / 474)
            heart_mode = "progressive" if args.mode == "row" else "deferred"
            jfg_mode = "progressive" if args.mode == "row" else "frame"
            jfg_env = {"JULIA_RTC_DAEMON_CPUS": args.rtc_cpus, "JULIA_RTC_ISLAND_CPUS": args.rtc_cpus,
                       "JULIA_RTC_ADAPTER_CPUS": args.rtc_cpus, "JULIA_RTC_SIMULATOR_CPUS": args.source_core,
                       "JULIA_RTC_SIMULATOR_RT_PRIORITY": args.source_rt_priority}
            heart_env: dict[str, str] = {}
            fgn_env: dict[str, str] = {}
            if args.verify_placement:
                heart_env = {"PIPEWIREAO_RTC_PLACEMENT_VERIFY": str(verifier),
                             "PIPEWIREAO_RTC_HEART_CPUS": args.rtc_cpus}
                jfg_env.update({"JULIA_RTC_PLACEMENT_VERIFY": str(verifier),
                                "JULIA_RTC_PIN_CPUS": args.julia_pin_cpus,
                                "JULIA_RTC_OBSERVER_CPUS": ",".join(
                                    str(cpu) for cpu in sorted(os.sched_getaffinity(0)))})
            if thread_profile is not None:
                for environment in (heart_env, fgn_env, jfg_env):
                    environment["PIPEWIREAO_RTC_THREAD_PROFILE"] = str(thread_profile)
            commands = {
                "heart": [str(args.jfg_root / "benchmark/heart/run_copper_aos_matched.sh"),
                          "--frames", str(args.frames), "--period", period, "--readout-us", "2000",
                          "--command-limit-um", "0.8", "--output", str(heart_dir), "--fits", str(cube),
                          "--heart-root", str(args.heart_root), "--revolt-config", str(args.revolt_config_dir),
                          "--wfs-simulator", str(args.wfs_simulator),
                          "--cpu-map", str(args.heart_cpu_map), "--thread-map", str(args.heart_thread_map),
                          "--source-core", args.source_core, "--source-rt-priority", args.source_rt_priority,
                          "--ingress-mode", heart_mode],
                "fgn": [sys.executable, str(fgn_runner),
                        "--output-dir", str(fgn_dir), "--frames", str(args.frames), "--rate-hz", "474",
                        "--readout-us", "2000", "--clipping-feedback", "--command-limit-um", "0.8",
                        "--pipewire-prefix", str(args.pipewire_prefix),
                        "--rtc-cpus", args.rtc_cpus, "--source-cpu", args.source_core,
                        "--source-rt-priority", args.source_rt_priority,
                        "--plugin", str(args.fgn_fullframe_root / "target/release/libcalculon_fgn_bundle.so"),
                        "--heart-plugin", str(args.pipewire_prefix / "lib/x86_64-linux-gnu/spa-ao-0.2/heart/libspa-heart.so"),
                        "--config-dir", str(args.revolt_config_dir), "--cube", str(cube),
                        "--wfs-simulator", str(args.wfs_simulator)],
                "jfg": ["julia", "--startup-file=no", f"--project={args.jfg_root / 'benchmark'}",
                        str(args.jfg_root / "benchmark/run_shared_copper_fits.jl"), "--fits", str(cube),
                        "--native-prefix", str(args.pipewire_prefix), "--profile", "matched",
                        "--revolt-config-dir", str(args.revolt_config_dir), "--pixel-source", "heart-wfs",
                        "--heart-plugin", str(args.pipewire_prefix / "lib/x86_64-linux-gnu/spa-ao-0.2/heart/libspa-heart.so"),
                        "--wfs-simulator", str(args.wfs_simulator), "--frames", str(args.frames),
                        "--frame-rate-hz", "474", "--readout-us", "2000", "--clipping-feedback", "true",
                        "--command-limit-um", "0.8", "--ingress-mode", jfg_mode,
                        "--graph-warmup", args.jfg_graph_warmup,
                        "--island-threads", "2", "--cpu-workers", "0",
                        "--std-wfs-port", "65310", "--std-dm-port", "65311",
                        "--output", str(jfg_report)],
            }
            if args.verify_placement:
                commands["fgn"].extend(("--placement-verify", str(verifier)))
            if fgn_loop is not None:
                commands["fgn"].extend(("--lab-loop-cpu", str(fgn_loop[0]),
                                        "--lab-loop-rt-priority", str(fgn_loop[1])))
            record: dict[str, Any] = {"index": index, "commands": {}}
            manifest["runs"].append(record)
            for name in ("heart", "fgn", "jfg"):
                result = command_record(commands[name],
                                        args.jfg_root if name in ("heart", "jfg") else args.fgn_root,
                                        run / f"{name}.runner.log",
                                        jfg_env if name == "jfg" else heart_env if name == "heart" else fgn_env)
                record["commands"][name] = result
                require_exact(result["returncode"] == 0, f"{name} runner failed; see {result['combined_output']}")
            heart = require_heart(heart_dir, args.frames)
            fgn = require_fgn(fgn_dir, args.frames,
                              sha256(native_daemon), sha256(native_module))
            jfg, jfg_physical = require_jfg(jfg_report, args.frames)
            if args.verify_placement:
                fgn_report = json_file(fgn_dir / "report.json")
                fgn_placement = fgn_report.get("placement", {})
                jfg_placement = jfg.get("placement_reports", {})
                placement_paths = {
                    "heart": {phase: {"scaoTemplate": heart_dir / f"heart-placement-{phase}.json"}
                              for phase in ("before-ingress", "after-replay")},
                    "fgn": {phase: {role: Path(path) for role, path in
                                    fgn_placement.get(key, {}).items()}
                            for phase, key in (("before-ingress", "pre_ingress_verification"),
                                               ("after-replay", "post_replay_verification"))},
                    "jfg": {phase: {role: Path(path) for role, path in
                                    jfg_placement.get(key, {}).items()}
                            for phase, key in (("before-ingress", "before_ingress"),
                                               ("after-replay", "after_replay"))},
                }
                expected_roles = {"heart": {"scaoTemplate"},
                                  "fgn": {"daemon", "observer", "adapter"},
                                  "jfg": {"daemon", "island", "observer", "adapter"}}
                for system, phases in placement_paths.items():
                    for phase, roles in phases.items():
                        require_exact(set(roles) == expected_roles[system],
                                      f"{system} placement roles missing at {phase}")
                record["placement"] = {system: require_placement(phases, thread_profile_sha256)
                                       for system, phases in placement_paths.items()}
            record["runner_reports"] = {"heart": str(heart_dir / "qualification.json"),
                                        "fgn": str(fgn_dir / "report.json"), "jfg": str(jfg_report)}
            comparisons: dict[str, str] = {}
            compare = args.jfg_root / "benchmark/heart/compare_command_vectors.py"
            pairs = {
                "heart_to_jfg": [str(heart_dir / "std-dm-vectors.f32"), str(jfg["std_dm_vectors"]),
                                 "--heart-summary", str(heart_dir / "std-dm-summary.json"),
                                 "--julia-csv", str(jfg["command_csv"]), "--heart-frame-id-offset", "-1"],
                "fgn_to_jfg": [str(fgn_dir / "dm-wire-um.f32"), str(jfg["std_dm_vectors"]),
                               "--heart-summary", str(fgn_dir / "dm-summary.json"),
                               "--julia-csv", str(jfg["command_csv"])],
            }
            for name, pair in pairs.items():
                target = run / f"{name}.json"
                result = command_record([sys.executable, str(compare), *pair], args.jfg_root, target)
                require_exact(result["returncode"] == 0, f"{name} vector comparison failed")
                comparison = json.loads(target.read_text())
                metrics = comparison["frame_id_matched"]
                require_exact(comparison["matched_commands"] == args.frames and
                              metrics["max_absolute_um"] <= VECTOR_TOLERANCE_UM,
                              f"{name} vectors differ by more than {VECTOR_TOLERANCE_UM} um")
                comparisons[name] = str(target)
            record["qualification"] = {"heart": heart, "fgn": fgn, "jfg": jfg_physical,
                                        "comparisons": comparisons}
            record["latency_phases"] = {
                "heart": capture_latency_phases(heart_dir / "std-wfs-packets.tsv",
                                                 heart_dir / "std-dm-packets.tsv", args.frames,
                                                 dm_id_base=1),
                "fgn": capture_latency_phases(fgn_dir / "wfs-packets.tsv",
                                               fgn_dir / "dm-packets.tsv", args.frames,
                                               dm_id_base=0),
                "jfg": capture_latency_phases(run / "jfg-wfs-packets.tsv",
                                               run / "jfg-dm-packets.tsv", args.frames,
                                               dm_id_base=0),
            }
        manifest["qualified"] = True
        manifest["latency_summaries"] = [
            {name: {key: values.get(key)
                    for key in ("first_wfs_packet_to_dm_us", "terminal_wfs_packet_to_dm_us")}
             for name, values in entry["qualification"].items() if name != "comparisons"}
            for entry in manifest["runs"]
        ]
    except Exception as error:
        manifest["error"] = str(error)
        raise
    finally:
        manifest["output_paths"] = [str(manifest_path), *paths_under(output)]
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        print(manifest_path)


if __name__ == "__main__":
    main()
