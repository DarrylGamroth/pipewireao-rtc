#!/usr/bin/env python3
"""Run a full-frame Copper controller under pipewireao-rtc on a private core."""

from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

import numpy as np

from lab_placement import (LaunchError, parse_cpu_list, parse_thread_policy,
                           read_thread_profile, wrapper_argv)


RTC = Path(__file__).resolve().parents[1]
PIPEWIREAO_JLL_UUID = "cde84cf6-9a21-5ce0-b5e3-1526e778c30b"
# wfsSimulator requires readout < 95% of the frame period. At 2 ms, the
# highest integral frame rate it admits is 474 Hz.
MAX_RATE_HZ = 474
EQUIVALENCE_OUTPUTS = (
    ("mean", "pyramid:mean-pupil-intensity", 1,
     "org.calculon.ao.pyramid-mean-pupil-intensity/1"),
    ("correction", "control:correction", 253,
     "org.calculon.ao.controller-command/1"),
    ("controller-state", "control:controller-state", 253,
     "org.calculon.ao.controller-state/1"),
    ("constraint-feedback", "command:constraint-feedback", 277,
     "org.calculon.ao.pdm-constraint-feedback/1"),
)


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def git_state(path: Path) -> dict:
    """Record the source revision and dirty paths behind a selected artifact."""
    directory = path if path.is_dir() else path.parent
    def git(*arguments: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(directory), *arguments], text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    try:
        status = git("status", "--porcelain")
        return {"root": git("rev-parse", "--show-toplevel"),
                "revision": git("rev-parse", "HEAD"),
                "dirty": bool(status), "status_porcelain": status}
    except (OSError, subprocess.CalledProcessError) as error:
        return {"path": str(path), "unavailable": str(error)}


def require_physical_latencies(physical: dict, frames: int) -> None:
    for name in ("first_wfs_packet_to_dm_us", "terminal_wfs_packet_to_dm_us",
                 "source_first_to_terminal_us"):
        summary = physical.get(name)
        if not isinstance(summary, dict) or summary.get("count") != frames:
            raise RuntimeError(f"incomplete {name} latency distribution")
        for statistic in ("min", "p50", "p99", "max"):
            value = summary.get(statistic)
            if not isinstance(value, (int, float)) or not np.isfinite(value) or value < 0:
                raise RuntimeError(f"invalid {name} {statistic} latency: {value}")


def require_memory_record(record: dict, role: str, phase: str) -> None:
    observed = record.get("observed", {})
    backing = observed.get("page_backing", {})
    if (backing.get("available") is not True or backing.get("complete") is not True
            or backing.get("mappings", 0) < 1):
        raise RuntimeError(f"{role} page backing unavailable {phase}")
    rss = backing.get("kilobytes", {}).get("Rss")
    sizes = backing.get("resident_by_kernel_page_size_kilobytes", {})
    if not isinstance(rss, int) or sum(sizes.values()) != rss:
        raise RuntimeError(f"{role} page backing has incomplete resident accounting {phase}")
    if observed.get("smaps_rollup", {}).get("available") is not True:
        raise RuntimeError(f"{role} memory rollup unavailable {phase}")
    if observed.get("status", {}).get("vm_lck") is None:
        raise RuntimeError(f"{role} locked-memory amount unavailable {phase}")


def compare_algorithm_output(actual: np.ndarray, expected: np.ndarray,
                             frames: int, extent: int, field: str) -> float:
    if actual.size != expected.size or actual.size != frames * extent:
        raise RuntimeError(f"{field} Algorithm comparison has an unexpected extent")
    if not np.isfinite(actual).all():
        raise RuntimeError(f"{field} observed output contains non-finite values")
    if not np.isfinite(expected).all():
        raise RuntimeError(f"{field} direct Algorithm reference contains non-finite values")
    difference = np.abs(actual - expected)
    mismatches = np.flatnonzero(difference > 1e-6)
    if mismatches.size:
        index = int(mismatches[0])
        raise RuntimeError(
            f"{field} differs from direct Algorithm at frame {index // extent}, "
            f"element {index % extent}: expected {expected[index]}, "
            f"observed {actual[index]}, absolute error {difference[index]}"
        )
    return float(np.max(difference))


def use_installed_julia_libraries(output: Path, installation) -> Path:
    """Point the Julia JLL at the same PipeWireAO build as the private core."""
    depot = output / "julia-depot"
    overlay = depot / "native-artifact"
    files = {
        "lib/libpipewire-ao-0.3.so":
            installation.library_directory / "libpipewire-ao-0.3.so",
        "lib/spa-ao-0.2/libspa-ao.so":
            installation.spa_library_directory / "libspa-ao.so",
        "lib/spa-ao-0.2/support/libspa-support.so":
            installation.support_directory / "libspa-support.so",
    }
    for relative, installed in files.items():
        if not installed.is_file():
            raise RuntimeError(f"selected PipeWireAO library is absent: {installed}")
        destination = overlay / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.symlink_to(installed)
    override = depot / "artifacts/Overrides.toml"
    override.parent.mkdir(parents=True, exist_ok=True)
    override.write_text(f"[{PIPEWIREAO_JLL_UUID}]\n"
                        f"PipeWireAO = {json.dumps(str(overlay))}\n")
    return depot


def compile_equivalence_observers(output: Path, env: dict, installation,
                                  jfg_root: Path, rate_hz: int) -> dict[str, Path]:
    source = jfg_root / "scripts/julia_fits_command_observer.c"
    if "OBSERVER_NODE_NAME" not in source.read_text():
        raise RuntimeError("selected FITS observer does not support distinct node names")
    pkg = env.copy()
    pkg["PKG_CONFIG_PATH"] = str(installation.pkgconfig_directory)
    flags = subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "libpipewire-ao-0.3"],
        env=pkg, text=True,
    ).split()
    binaries = {}
    for name, _, extent, schema in EQUIVALENCE_OUTPUTS:
        binary = output / f"observer-{name}"
        node_name = f"rtc-copper-{name}-observer"
        subprocess.run(
            ["cc", "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-DALLOW_INVALID_PTS", f"-DCOMMAND_ELEMENTS={extent}",
             f"-DCOMMAND_RATE_HZ={rate_hz}", f'-DCOMMAND_SCHEMA="{schema}"',
             f'-DOBSERVER_NODE_NAME="{node_name}"', str(source), *flags,
             "-o", str(binary)], env=env, check=True,
        )
        binaries[name] = binary
    return binaries


def wfs_counters(dump: str) -> dict[str, int]:
    nodes = [entry for entry in json.loads(dump)
             if entry.get("type") == "PipeWire:Interface:Node"
             and entry.get("info", {}).get("props", {}).get("node.name")
             == "rtc-heart-wfs-row-source"]
    if len(nodes) != 1:
        raise RuntimeError(f"expected one HEART WFS node, found {len(nodes)}")
    params = nodes[0]["info"]["params"]
    names = {item["id"]: item["name"] for item in params["PropInfo"]}
    values = params["Props"][0]
    counters = {names[key]: value for key, value in values.items() if key in names}
    required = {"heart.std-wfs.datagrams-received",
                "heart.std-wfs.datagrams-rejected",
                "heart.std-wfs.frames-published",
                "heart.std-wfs.frames-dropped",
                "heart.std-wfs.buffer-starvations"}
    if not required <= counters.keys():
        raise RuntimeError(f"HEART WFS counters missing: {sorted(required - counters.keys())}")
    return counters


def capture_placement(output: Path, phase: str, processes: dict, env: dict,
                      profile: dict | None = None, profile_sha256: str | None = None) -> dict:
    inspector = RTC / "benchmark/lab_placement.py"
    records = {}
    for role, process in processes.items():
        path = output / f"placement-{phase}-{role}.json"
        if profile is None:
            argv = [sys.executable, str(inspector), "inspect", "--pid", str(process.pid),
                    "--output", str(path)]
        else:
            contract = profile["roles"][role]
            argv = [sys.executable, str(inspector), "verify", "--role", role,
                    "--pid", str(process.pid), "--cpus", contract["cpus"],
                    "--leader-policy", contract["leader_policy"], "--output", str(path)]
            for policy in sorted({contract["leader_policy"],
                                  *contract["required_policy_counts"],
                                  *(item["policy"] for item in contract["required_thread_placements"])}):
                argv.extend(("--allowed-thread-policy", policy))
            for policy, count in contract["required_policy_counts"].items():
                argv.extend(("--required-thread-policy", f"{policy}={count}"))
        completed = subprocess.run(argv, env=env, capture_output=True, text=True)
        records[role] = str(path)
        if completed.returncode:
            detail = json.loads(path.read_text()).get("error") if path.is_file() else completed.stderr
            raise RuntimeError(f"{role} placement failed {phase}: {detail}; record: {path}")
        if profile_sha256 is not None:
            verified = json.loads(path.read_text())
            actual = verified.get("requested", {}).get("thread_profile_sha256")
            if actual != profile_sha256:
                raise RuntimeError(f"{role} placement profile changed {phase}: {path}")
            require_memory_record(verified, role, phase)
    return records


def placement_contract(profile: dict, role: str) -> tuple[set[int], tuple[str, int]]:
    contract = profile["roles"][role]
    return parse_cpu_list(contract["cpus"]), parse_thread_policy(contract["leader_policy"])


def placed_argv(profile: dict | None, role: str, argv: list[str]) -> list[str]:
    if profile is None:
        return argv
    cpus, (policy, priority) = placement_contract(profile, role)
    return wrapper_argv(argv, cpus, policy, priority)


def preflight_placement(profile: dict, roles: set[str]) -> tuple[int, int]:
    available = set(os.sched_getaffinity(0))
    for role in sorted(roles):
        cpus, (policy, priority) = placement_contract(profile, role)
        contract = profile["roles"][role]
        if role != "simulator":
            counted = set(contract["required_policy_counts"])
            used = {contract["leader_policy"],
                    *(item["policy"] for item in contract["required_thread_placements"])}
            if not used <= counted:
                raise LaunchError(f"{role} profile must count every permitted thread policy")
        missing = cpus - available
        if missing:
            raise LaunchError(f"{role} requested unavailable CPUs: {sorted(missing)}")
        probe = subprocess.run(wrapper_argv(["true"], cpus, policy, priority),
                               capture_output=True, text=True)
        if probe.returncode:
            raise LaunchError(f"{role} scheduler/affinity preflight failed: {probe.stderr.strip()}")
    loops = [item for item in profile["roles"]["daemon"]["required_thread_placements"]
             if item["count"] == 1 and item["policy"].startswith("fifo:")
             and len(parse_cpu_list(item["cpus"])) == 1]
    if len(loops) != 1:
        raise LaunchError("daemon profile needs exactly one pinned FIFO data-loop placement")
    loop = loops[0]
    return next(iter(parse_cpu_list(loop["cpus"]))), parse_thread_policy(loop["policy"])[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--algorithms-root", type=Path,
                        default=RTC.parent / "calculon-algorithms-main-copper")
    parser.add_argument("--heart-config", type=Path,
                        default=RTC.parent.parent / "heart/revolt-rtc/config")
    parser.add_argument("--fgn-bundle", type=Path,
                        default=RTC.parent / "calculon-algorithms-copper-fullframe/target/release/libcalculon_fgn_bundle.so")
    parser.add_argument("--heart-plugin", type=Path,
                        default=RTC.parent / "pipewireao-spa-plugin-heart/build-main-row-block/spa/plugins/heart/libspa-heart.so")
    parser.add_argument("--wfs-simulator", type=Path,
                        default=RTC.parent.parent / "heart/heart-copper-comparison/source/testServer/bin/wfsSimulator")
    parser.add_argument("--cube", type=Path,
                        default=RTC.parent / "JuliaFilterGraph.jl/benchmark/data/revolt-copper-aos-openloop-1024f-u16.fits")
    parser.add_argument("--rtc-bin", type=Path, default=RTC / "target/debug/pipewireao-rtc")
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--controller", choices=("native", "julia"), default="native",
                        help="controller implementation to admit through the RTC")
    parser.add_argument("--jfg-root", type=Path,
                        default=RTC.parent / "JuliaFilterGraph.jl",
                        help="JuliaFilterGraph worktree providing the external controller")
    parser.add_argument("--pipewireao-julia-root", type=Path,
                        default=RTC.parent / "PipeWireAO.jl",
                        help="local PipeWireAO.jl package for the Julia provider")
    parser.add_argument("--julia-blas-threads", type=int, default=1,
                        help="OpenBLAS threads in the Julia controller (default: 1)")
    parser.add_argument("--placement-profile", type=Path,
                        help="opt-in role/thread contract; reject mismatches before image ingress")
    parser.add_argument("--julia-pin-cpus",
                        help="comma-separated CPU for each of the two Julia threads in placement mode")
    parser.add_argument("--wire-capture", action="store_true",
                        help="link the Standard-DM adapter and qualify WFS-to-DM UDP latency")
    parser.add_argument("--equivalence-observations", action="store_true",
                        help="expose Copper state outputs for a direct-Algorithm comparison")
    parser.add_argument("--direct-oracle-bin", type=Path,
                        help="direct Calculon Copper oracle executable for state comparison")
    parser.add_argument("--command-limit-um", type=float, default=0.8)
    parser.add_argument("--frames", type=int, default=16)
    parser.add_argument("--rate-hz", type=int, default=474,
                        help="offered frame rate; the 2 ms wfsSimulator readout permits at most 474 Hz")
    parser.add_argument("--reference-vectors", type=Path,
                        help="optional demanded-um.f32 from the matched FGN full-frame replay")
    args = parser.parse_args()
    script_started_ns = time.monotonic_ns()
    if not 1 <= args.frames <= 1024:
        parser.error("--frames must be in 1..1024")
    if not 1 <= args.rate_hz <= MAX_RATE_HZ:
        parser.error(f"--rate-hz must be in 1..{MAX_RATE_HZ} for the 2 ms readout")
    if args.julia_blas_threads < 1:
        parser.error("--julia-blas-threads must be positive")
    if not np.isfinite(args.command_limit_um) or args.command_limit_um <= 0:
        parser.error("--command-limit-um must be finite and positive")
    if args.controller == "native" and args.julia_blas_threads != 1:
        parser.error("--julia-blas-threads applies only to --controller julia")
    if args.equivalence_observations and args.placement_profile is not None:
        parser.error("diagnostic observers are not yet in a strict placement profile")
    if args.equivalence_observations and args.direct_oracle_bin is None:
        parser.error("--equivalence-observations requires --direct-oracle-bin")
    if args.direct_oracle_bin is not None and not args.equivalence_observations:
        parser.error("--direct-oracle-bin requires --equivalence-observations")
    if args.julia_pin_cpus and (args.controller != "julia" or args.placement_profile is None):
        parser.error("--julia-pin-cpus requires Julia and --placement-profile")
    if args.controller == "julia" and args.placement_profile and not args.julia_pin_cpus:
        parser.error("Julia placement requires --julia-pin-cpus")
    output = args.output_dir.resolve()
    if output.exists():
        parser.error(f"output directory already exists: {output}")
    profile = None
    loop_cpu = loop_priority = None
    if args.placement_profile is not None:
        try:
            profile = read_thread_profile(args.placement_profile.resolve())
            roles = {"daemon", "observer", "rtc", "simulator"}
            if args.controller == "julia":
                roles.add("island")
            if args.wire_capture:
                roles.add("adapter")
            absent = roles - profile["roles"].keys()
            if absent:
                raise LaunchError(f"placement profile lacks roles: {sorted(absent)}")
            if args.controller == "julia":
                pin_cpus = parse_cpu_list(args.julia_pin_cpus)
                ordered_pins = [int(item) for item in args.julia_pin_cpus.split(",")]
                if len(ordered_pins) != 2 or len(pin_cpus) != 2:
                    raise LaunchError("Julia placement requires two distinct ordered pin CPUs")
                if not pin_cpus <= parse_cpu_list(profile["roles"]["island"]["cpus"]):
                    raise LaunchError("Julia pin CPUs exceed the island process CPU mask")
            loop_cpu, loop_priority = preflight_placement(profile, roles)
        except (LaunchError, ValueError, KeyError, TypeError, argparse.ArgumentTypeError) as error:
            parser.error(f"placement preflight failed: {error}")
    scripts = args.algorithms_root.resolve() / "scripts"
    sys.path.insert(0, str(scripts))
    from run_fgn_copper_fullframe_live import (  # noqa: PLC0415
        command, compile_observer, make_environment, pipewire_installation,
        prepare_artifacts, require, start, stop, validate_adapter_sequences,
        wait_for, wait_text,
    )

    installation = pipewire_installation(None, args.pipewire_prefix)
    heart = require(args.heart_plugin, "HEART SPA plugin")
    cube = require(args.cube, "Copper FITS cube")
    simulator = require(args.wfs_simulator, "wfsSimulator")
    rtc_bin = require(args.rtc_bin, "pipewireao-rtc executable")
    direct_oracle_bin = (require(args.direct_oracle_bin, "direct Copper Algorithm oracle")
                         if args.direct_oracle_bin is not None else None)
    direct_oracle_checker = (require(args.algorithms_root / "scripts/check_direct_copper_oracle.py",
                                     "direct Copper Algorithm checker")
                             if args.equivalence_observations else None)
    bundle = require(args.fgn_bundle, "FGN Copper bundle") if args.controller == "native" else None
    jfg_root = args.jfg_root.resolve()
    pipewireao_julia_root = args.pipewireao_julia_root.resolve()
    island_script = jfg_root / "scripts/run_pipewire_island.jl"
    deployment_project = jfg_root / "deployment/Project.toml"
    if args.controller == "julia":
        require(island_script, "JuliaFilterGraph PipeWire island script")
        require(deployment_project, "JuliaFilterGraph deployment project")
        require(pipewireao_julia_root / "Project.toml", "local PipeWireAO.jl project")
    adapter_script = jfg_root / "scripts/heart_std_dm_command_adapter.jl"
    qualifier_script = jfg_root / "benchmark/heart/qualify_copper_aos_capture.py"
    decoder_script = jfg_root / "benchmark/heart/decode_std_dm_packets.py"
    if args.wire_capture:
        for path, description in ((adapter_script, "Standard-DM adapter"),
                                  (qualifier_script, "WFS/DM capture qualifier"),
                                  (decoder_script, "Standard-DM decoder")):
            require(path, description)
        for program in ("dumpcap", "tshark"):
            if shutil.which(program) is None:
                parser.error(f"--wire-capture requires {program}")
    output.mkdir(parents=True)
    env = make_environment(output, heart, args.rate_hz, installation,
                           loop_cpu, loop_priority)
    if profile is not None:
        env["PIPEWIREAO_RTC_THREAD_PROFILE"] = str(args.placement_profile.resolve())
        daemon_config = (output / "config/fgn-copper-live.conf").read_text()
        required_settings = ("mem.mlock-all = false", "loop.idle = eventfd",
                             f"loop.rt-prio = {loop_priority}",
                             f"thread.affinity = [ {loop_cpu} ]",
                             "name = libpipewire-module-rt")
        if any(setting not in daemon_config for setting in required_settings):
            raise RuntimeError("generated daemon config lacks a requested loop or memory setting")
    observer_bin = compile_observer(output, env, args.rate_hz, installation)
    diagnostic_bins = (compile_equivalence_observers(
        output, env, installation, jfg_root, args.rate_hz,
    ) if args.equivalence_observations else {})
    if args.controller == "native":
        render_argv = [sys.executable, str(RTC / "benchmark/render_revolt_copper_graph.py"),
                       "--algorithms-root", str(args.algorithms_root),
                       "--heart-config", str(args.heart_config),
                       "--fgn-bundle", str(bundle), "--clipping-feedback",
                       "--rate-hz", str(args.rate_hz),
                       "--command-limit-um", str(args.command_limit_um),
                       "--output-dir", str(output)]
        if args.equivalence_observations:
            render_argv.append("--equivalence-observations")
        subprocess.run(
            render_argv,
            check=True,
        )
        env["PIPEWIREAO_RTC_GRAPH_COPPER_NATIVE"] = str(
            output / "revolt-copper-rtc-graph.conf"
        )
    processes = []
    diagnostic_observers = {}
    measurement_links: list[tuple[str, str]] = []
    island_quit_request = output / "julia-island.quit"
    adapter_stop = output / "adapter.stop"
    fixture = require(RTC / f"fixtures/revolt-copper-{args.controller}-development.conf",
                      f"Copper {args.controller} RTC fixture")
    if args.rate_hz != 474:
        rate_fixture = output / fixture.name
        original = fixture.read_text()
        anchor = "rate = 474/1"
        if original.count(anchor) != 1:
            raise RuntimeError(f"unexpected rate declaration in {fixture}")
        rate_fixture.write_text(original.replace(anchor, f"rate = {args.rate_hz}/1"))
        fixture = rate_fixture
    report = {"frames": args.frames, "rate_hz": args.rate_hz, "readout_us": 2000,
              "controller": args.controller, "fixture": str(fixture),
              "wire_capture": args.wire_capture,
              "command_limit_um": args.command_limit_um,
              "equivalence_observations": args.equivalence_observations,
              "cube": str(cube), "qualified": False,
              "delivery_qualified": False, "schedule_qualified": False,
              "wire_qualified": False if args.wire_capture else None,
              "numerical_comparison": "not_evaluated" if args.reference_vectors is not None
              else "not_requested"}
    profile_sha256 = sha256_file(args.placement_profile) if profile is not None else None
    if profile is not None:
        report["placement_profile"] = str(args.placement_profile.resolve())
        report["placement_profile_sha256"] = profile_sha256
        report["requested_placement"] = {role: profile["roles"][role]
                                          for role in sorted(roles)}
        report["daemon_config_sha256"] = sha256_file(output / "config/fgn-copper-live.conf")
    report["pipewire_prefix"] = str(args.pipewire_prefix.resolve())
    report["source_revisions"] = {
        "rtc": git_state(RTC),
        "calculon": git_state(args.algorithms_root),
        "bundle": git_state(args.fgn_bundle),
        "heart": git_state(simulator),
        "heart_plugin": git_state(heart),
        "jfg": git_state(jfg_root),
        "pipewireao_julia": git_state(pipewireao_julia_root),
    }
    artifacts = (rtc_bin, installation.daemon,
                 installation.module_directory / "libpipewire-module-ndarray-filter-chain.so",
                 installation.tool("pwao-link"), installation.tool("pwao-dump"),
                 observer_bin, simulator, heart, fixture,
                 output / "config/fgn-copper-live.conf")
    report["artifact_sha256"] = {str(path): sha256_file(path) for path in artifacts}
    report["calibration_sha256"] = {
        str(path): sha256_file(path)
        for path in sorted(args.heart_config.resolve().iterdir()) if path.is_file()
    }
    report["input_sha256"] = sha256_file(cube)
    report["heart_plugin_sha256"] = sha256_file(heart)
    report["pipewire_library_sha256"] = sha256_file(
        installation.library_directory / "libpipewire-ao-0.3.so"
    )
    if args.reference_vectors is not None:
        report["reference_vectors"] = str(args.reference_vectors.resolve())
    if bundle is not None:
        report["bundle"] = str(bundle)
        report["bundle_sha256"] = sha256_file(bundle)
        report["artifact_sha256"][str(output / "revolt-copper-rtc-graph.conf")] = (
            sha256_file(output / "revolt-copper-rtc-graph.conf")
        )
    if direct_oracle_bin is not None:
        report["direct_oracle_bin"] = str(direct_oracle_bin)
        report["direct_oracle_sha256"] = sha256_file(direct_oracle_bin)
    if args.controller == "julia":
        report["jfg_root"] = str(jfg_root)
        report["jfg_script_sha256"] = sha256_file(island_script)
        report["julia_blas_threads"] = args.julia_blas_threads
    if args.wire_capture:
        report["adapter_script_sha256"] = sha256_file(adapter_script)
        report["qualifier_script_sha256"] = sha256_file(qualifier_script)
        report["decoder_script_sha256"] = sha256_file(decoder_script)
    placement_processes = {}
    try:
        daemon, daemon_log = start(
            placed_argv(profile, "daemon",
                        [str(installation.daemon), "-c", "fgn-copper-live.conf"]),
            env, output / "daemon.log", cwd=installation.working_directory,
        )
        processes.append((daemon, daemon_log, None))
        placement_processes["daemon"] = daemon
        wait_for("private PipeWireAO socket",
                 lambda: (Path(env["XDG_RUNTIME_DIR"]) / "pipewire-ao-0").exists(), 15)
        observer, observer_log = start(
            placed_argv(profile, "observer",
                        [str(observer_bin), "--csv", str(output / "demanded.csv"),
                         "--vectors", str(output / "demanded-um.f32"),
                         "--max-records", str(args.frames + 4)]),
            env, output / "observer.log", stdin=True,
        )
        processes.append((observer, observer_log, "q"))
        placement_processes["observer"] = observer
        wait_text(output / "observer.log", "CONNECT_ACCEPTED", process=observer)
        for name, _, _, _ in (EQUIVALENCE_OUTPUTS
                              if args.equivalence_observations else ()):
            diagnostic, diagnostic_log = start(
                [str(diagnostic_bins[name]), "--csv", str(output / f"{name}.csv"),
                 "--vectors", str(output / f"{name}.f32"),
                 "--max-records", str(args.frames + 4)],
                env, output / f"observer-{name}.log", stdin=True,
            )
            processes.append((diagnostic, diagnostic_log, "q"))
            diagnostic_observers[name] = (diagnostic, diagnostic_log)
            placement_processes[f"observer-{name}"] = diagnostic
            wait_text(output / f"observer-{name}.log", "CONNECT_ACCEPTED",
                      process=diagnostic)
        if args.controller == "julia" or args.wire_capture:
            depot = use_installed_julia_libraries(output, installation)
            report["julia_artifact_overlay"] = str(depot / "native-artifact")
            env.update({
                "JULIA_DEPOT_PATH": os.pathsep.join((
                    str(depot), os.environ.get("JULIA_DEPOT_PATH") or
                    str(Path.home() / ".julia"),
                )),
                "JULIA_LOAD_PATH": f"{pipewireao_julia_root}:@:@stdlib",
                "OPENBLAS_NUM_THREADS": str(args.julia_blas_threads),
            })
        if args.wire_capture:
            adapter, adapter_log = start(
                placed_argv(profile, "adapter",
                            ["julia", "--startup-file=no", "--threads=2",
                             f"--project={jfg_root / 'benchmark'}", str(adapter_script),
                             "pipewire-ao-0", str(adapter_stop), str(args.rate_hz),
                             "277", str(output / "adapter-sequences.csv")]),
                env, output / "adapter.log", cwd=jfg_root,
            )
            processes.append((adapter, adapter_log, None))
            placement_processes["adapter"] = adapter
            wait_text(output / "adapter.log", "CONNECT_ACCEPTED", 60, adapter)
        if args.controller == "julia":
            env.update({
                "JULIA_RTC_WORKLOAD": "copper-fits-full-frame-feedback",
                "JULIA_RTC_COPPER_CONFIG_DIR": str(args.heart_config.resolve()),
                "JULIA_RTC_FRAME_RATE": str(args.rate_hz),
                "JULIA_RTC_INGRESS_MODE": "frame",
                "JULIA_RTC_CPU_WORKERS": "0",
                "JULIA_RTC_COMMAND_LIMIT_UM": str(args.command_limit_um),
                "JULIA_RTC_EQUIVALENCE_OBSERVATIONS": (
                    "1" if args.equivalence_observations else "0"
                ),
                "JULIA_ISLAND_QUIT_REQUEST": str(island_quit_request),
                "JULIA_RTC_MANAGED_NODE_NAME": "calculon-revolt-copper-fullframe",
                "JULIA_RTC_MANAGED_REMOTE": "pipewire-ao-0",
            })
            if profile is not None:
                env["JULIA_RTC_PIN_CPUS"] = args.julia_pin_cpus
            island, island_log = start(
                placed_argv(profile, "island",
                            ["julia", "--startup-file=no",
                             "--threads=2,0" if profile is not None else "--threads=2",
                             f"--project={jfg_root / 'deployment'}", str(island_script),
                             "progressive-rtc-benchmark"]),
                env, output / "julia-island.log", cwd=jfg_root,
            )
            processes.append((island, island_log, None))
            placement_processes["island"] = island
            wait_text(output / "julia-island.log", "JULIA_ISLAND_CONNECT_ACCEPTED", 60,
                      island)
        rtc, rtc_log = start(
            placed_argv(profile, "rtc",
                        [str(rtc_bin), "--config", str(fixture), "--hold"]),
            env, output / "rtc.log", stdin=True,
        )
        processes.append((rtc, rtc_log, "quit\n"))
        placement_processes["rtc"] = rtc
        wait_text(output / "rtc.log", "RUNNING", 30, rtc)
        command([str(installation.tool("pwao-dump")), "-r", "pipewire-ao-0"], env)
        if args.equivalence_observations:
            for name, source_port, _, _ in EQUIVALENCE_OUTPUTS:
                public_port = (source_port if args.controller == "native" else
                               {"mean": "mean-pupil-intensity",
                                "correction": "correction",
                                "controller-state": "controller-state",
                                "constraint-feedback": "constraint-feedback"}[name])
                source = f"calculon-revolt-copper-fullframe:{public_port}"
                sink = f"rtc-copper-{name}-observer:input_1"
                command([str(installation.tool("pwao-link")), "-r", "pipewire-ao-0",
                         "-w", "-L", source, sink], env)
                measurement_links.append((source, sink))
                wait_text(output / f"observer-{name}.log", "STREAMING", 15,
                          diagnostic_observers[name][0])
            report["measurement_links"] = list(measurement_links)
        if args.wire_capture:
            demanded_port = ("command:demanded" if args.controller == "native"
                             else "demanded")
            pairs = (
                (f"calculon-revolt-copper-fullframe:{demanded_port}",
                 "julia-heart-std-dm-command-adapter:demanded"),
                ("julia-heart-std-dm-command-adapter:standard-dm",
                 "rtc-heart-std-dm-sink:command"),
            )
            link_tool = str(installation.tool("pwao-link"))
            for source_port, sink_port in pairs:
                command([link_tool, "-r", "pipewire-ao-0", "-w", "-L",
                         source_port, sink_port], env)
                measurement_links.append((source_port, sink_port))
            listed = command([link_tool, "-r", "pipewire-ao-0", "-l"], env)
            if any(source_port not in listed or sink_port not in listed
                   for source_port, sink_port in pairs):
                raise RuntimeError("Standard-DM measurement link did not appear")
            report["measurement_links"] = list(measurement_links)
            wait_text(output / "adapter.log", "PREPARED", 60, adapter)
        graph_ready_ns = time.monotonic_ns()
        report["placement"] = {
            "before_ingress": capture_placement(
                output, "before-ingress", placement_processes, env, profile,
                profile_sha256,
            ),
        }
        if args.wire_capture:
            capture, capture_log = start(
                ["dumpcap", "-p", "-i", "any", "-f",
                 "udp port 6000 or udp port 6100", "-w", str(output / "wire.pcapng")],
                env, output / "dumpcap.log",
            )
            processes.append((capture, capture_log, None))
            wait_text(output / "dumpcap.log", "Capturing on", 15, capture)
        (output / "input.fits").symlink_to(cube)
        replay, replay_log = start(
            placed_argv(profile, "simulator",
                        [str(simulator), "-file", "input.fits", "-tPort", "6000",
                         "-period", repr(1.0 / args.rate_hz), "-readout", "2000", "-lines", "32",
                         "-numFrames", str(args.frames)]),
            env, output / "wfs-simulator.log", cwd=output,
        )
        source_launched_ns = time.monotonic_ns()
        report["startup_intervals_ms"] = {
            "script_to_graph_ready": (graph_ready_ns - script_started_ns) / 1e6,
            "graph_ready_to_source_launch": (source_launched_ns - graph_ready_ns) / 1e6,
        }
        processes.append((replay, replay_log, None))
        replay.wait(timeout=args.frames / args.rate_hz + 15)
        report["replay_elapsed_ms"] = (time.monotonic_ns() - source_launched_ns) / 1e6
        if replay.returncode != 0:
            raise RuntimeError("wfsSimulator failed")
        overruns = re.findall(r"Timer\[0\] overrun: (\d+)",
                              (output / "wfs-simulator.log").read_text(errors="replace"))
        report["simulator_timer_overrun_events"] = len(overruns)
        report["simulator_timer_overrun_periods"] = sum(map(int, overruns))
        report["schedule_qualified"] = not overruns
        # The observer flushes its FILE streams when it stops. The matched
        # Copper runner also allows one second for queued graph output here.
        time.sleep(1.0)
        if args.wire_capture:
            stop(capture, capture_log)
            processes.remove((capture, capture_log, None))
        dump = command(
            [str(installation.tool("pwao-dump")), "-r", "pipewire-ao-0", "--raw"], env,
        )
        (output / "pipewire-after-replay.json").write_text(dump)
        report["wfs_counters"] = wfs_counters(dump)
        report["placement"]["after_replay"] = capture_placement(
            output, "after-replay", placement_processes, env, profile,
            profile_sha256,
        )
        for source_port, sink_port in reversed(measurement_links):
            command([str(installation.tool("pwao-link")), "-r", "pipewire-ao-0",
                     "-d", source_port, sink_port], env)
        measurement_links.clear()
        stop(rtc, rtc_log, control="quit\n")
        processes.remove((rtc, rtc_log, "quit\n"))
        if rtc.returncode != 0 or "OFFLINE" not in (output / "rtc.log").read_text():
            raise RuntimeError("RTC did not unload cleanly")
        after_unload = command(
            [str(installation.tool("pwao-dump")), "-r", "pipewire-ao-0", "--raw"], env,
        )
        (output / "pipewire-after-unload.json").write_text(after_unload)
        nodes = {item.get("info", {}).get("props", {}).get("node.name")
                 for item in json.loads(after_unload)
                 if item.get("type") == "PipeWire:Interface:Node"}
        required_external = {"rtc-heart-wfs-row-source", "julia-fits-command-observer"}
        if args.controller == "julia":
            required_external.add("calculon-revolt-copper-fullframe")
        if args.wire_capture:
            required_external.update(("julia-heart-std-dm-command-adapter",
                                      "rtc-heart-std-dm-sink"))
        if args.equivalence_observations:
            required_external.update(f"rtc-copper-{name}-observer"
                                     for name, _, _, _ in EQUIVALENCE_OUTPUTS)
        if not required_external <= nodes:
            raise RuntimeError("RTC unload removed an external Copper endpoint: "
                               f"{sorted(required_external - nodes)}")
        if args.controller == "native" and "calculon-revolt-copper-fullframe" in nodes:
            raise RuntimeError("RTC-owned native Copper graph survived unload")
        remaining_links = [item for item in json.loads(after_unload)
                           if item.get("type") == "PipeWire:Interface:Link"]
        report["post_unload_links"] = len(remaining_links)
        if remaining_links:
            raise RuntimeError("RTC-owned Copper links survived unload")
        stop(observer, observer_log, control="q")
        processes.remove((observer, observer_log, "q"))
        for name, (diagnostic, diagnostic_log) in diagnostic_observers.items():
            stop(diagnostic, diagnostic_log, control="q")
            processes.remove((diagnostic, diagnostic_log, "q"))
            if diagnostic.returncode != 0:
                raise RuntimeError(f"{name} observer did not stop cleanly")
        if args.wire_capture:
            adapter_stop.touch()
            stop(adapter, adapter_log)
            processes.remove((adapter, adapter_log, None))
            if adapter.returncode != 0:
                raise RuntimeError("Standard-DM adapter did not stop cleanly")
            validate_adapter_sequences(output / "adapter-sequences.csv", args.frames)
            report["adapter_callbacks"] = args.frames
        if args.controller == "julia":
            island_quit_request.touch()
            stop(island, island_log)
            processes.remove((island, island_log, None))
            if island.returncode != 0:
                raise RuntimeError("JuliaFilterGraph island did not stop cleanly")
            island_text = (output / "julia-island.log").read_text(errors="replace")
            callbacks = re.findall(r"JULIA_FULL_FRAME_RESULT callbacks=(\d+)", island_text)
            if len(callbacks) != 1:
                raise RuntimeError("JuliaFilterGraph island did not report one callback count")
            report["julia_callbacks"] = int(callbacks[0])
            report["wfs_frames_without_julia_callback"] = (
                args.frames - report["julia_callbacks"]
            )
        with (output / "demanded.csv").open(newline="") as stream:
            sequences = [int(row["sequence"]) for row in csv.DictReader(stream)]
        counts = Counter(sequences)
        expected = set(range(args.frames))
        missing = sorted(expected - counts.keys())
        repeated = sorted(sequence for sequence, count in counts.items() if count > 1)
        unexpected = sorted(counts.keys() - expected)
        report["observed_commands"] = len(sequences)
        report["missing_sequences"] = missing
        report["repeated_sequences"] = repeated
        report["unexpected_sequences"] = unexpected
        counters = report["wfs_counters"]
        if (counters["heart.std-wfs.datagrams-received"] != 2 * args.frames
                or counters["heart.std-wfs.datagrams-rejected"] != 0
                or counters["heart.std-wfs.frames-published"] != args.frames
                or counters["heart.std-wfs.frames-dropped"] != 0
                or counters["heart.std-wfs.buffer-starvations"] != 0):
            raise RuntimeError(f"HEART WFS did not deliver every frame: {counters}; "
                               f"missing commands={missing}")
        if sequences != list(range(args.frames)):
            raise RuntimeError(
                "demanded command delivery is not contiguous: "
                f"observed={len(sequences)} missing={missing} "
                f"repeated={repeated} unexpected={unexpected}"
            )
        if args.equivalence_observations:
            report["equivalence_outputs"] = {}
            for name, _, extent, schema in EQUIVALENCE_OUTPUTS:
                with (output / f"{name}.csv").open(newline="") as stream:
                    observed = [int(row["sequence"]) for row in csv.DictReader(stream)]
                values = np.fromfile(output / f"{name}.f32", dtype="<f4")
                if observed != list(range(args.frames)) or values.size != args.frames * extent:
                    raise RuntimeError(f"{name} observations are incomplete or unordered")
                if not np.isfinite(values).all():
                    raise RuntimeError(f"{name} observations contain non-finite values")
                report["equivalence_outputs"][name] = {
                    "schema": schema, "extent": extent, "frames": args.frames,
                    "vectors": str(output / f"{name}.f32"),
                }
            oracle_dir = output / "direct-oracle"
            if args.controller == "julia":
                prepare_artifacts(output, args.heart_config.resolve(), True)
            command([str(direct_oracle_bin), "--run-dir", str(output),
                     "--output-dir", str(oracle_dir), "--frames", str(args.frames),
                     "--limit-um", str(args.command_limit_um)], env)
            references = {
                "mean": "mean.f32",
                "correction": "correction.f32",
                "controller-state": "controller-state.f32",
                "constraint-feedback": "constraint-feedback-um.f32",
            }
            report["algorithm_comparison"] = {}
            for name, oracle_file in references.items():
                extent = report["equivalence_outputs"][name]["extent"]
                actual = np.fromfile(output / f"{name}.f32", dtype="<f4")
                expected = np.fromfile(oracle_dir / oracle_file, dtype="<f4")
                report["algorithm_comparison"][name] = compare_algorithm_output(
                    actual, expected, args.frames, extent, name,
                )
            expected = np.fromfile(oracle_dir / "demanded-um.f32", dtype="<f4")
            actual = np.fromfile(output / "demanded-um.f32", dtype="<f4")
            report["algorithm_comparison"]["demanded"] = compare_algorithm_output(
                actual, expected, args.frames, 277, "demanded",
            )
            report["direct_checker"] = json.loads(command(
                [sys.executable, str(direct_oracle_checker), str(oracle_dir),
                 "--reference-demanded", str(output / "demanded-um.f32"),
                 "--limit-um", str(args.command_limit_um)], env,
            ))
            report["numerical_comparison"] = "passed"
        if args.controller == "julia" and report["julia_callbacks"] != args.frames:
            raise RuntimeError(
                "JuliaFilterGraph callback count does not match the requested frames: "
                f"{report['julia_callbacks']} != {args.frames}"
            )
        demanded = np.fromfile(output / "demanded-um.f32", dtype="<f4")
        if demanded.size != args.frames * 277:
            raise RuntimeError(f"demanded vector count is {demanded.size // 277}, expected {args.frames}")
        if not np.isfinite(demanded).all():
            raise RuntimeError("demanded command contains non-finite values")
        report["delivery_qualified"] = True
        if args.reference_vectors is not None:
            reference = np.fromfile(args.reference_vectors, dtype="<f4")[:demanded.size]
            if reference.size != demanded.size:
                raise RuntimeError("reference has too few demanded vectors")
            difference = float(np.max(np.abs(demanded - reference)))
            report["max_reference_difference_um"] = difference
            if not np.isfinite(difference) or difference > 1e-6:
                report["numerical_comparison"] = "failed"
                raise RuntimeError(f"RTC demanded vectors differ from FGN reference by {difference} µm")
            report["numerical_comparison"] = "passed"
        if not report["schedule_qualified"]:
            raise RuntimeError(
                "wfsSimulator missed its offered frame schedule: "
                f"{report['simulator_timer_overrun_events']} overrun events, "
                f"{report['simulator_timer_overrun_periods']} periods"
            )
        if args.wire_capture:
            for port, target in ((6000, "wfs-packets.tsv"), (6100, "dm-packets.tsv")):
                packets = command(
                    ["tshark", "-r", str(output / "wire.pcapng"),
                     "-Y", f"udp.port=={port}", "-T", "fields",
                     "-e", "frame.time_epoch", "-e", "udp.length", "-e", "data.data"],
                    env, cwd=output,
                )
                (output / target).write_text(packets)
            command(
                [sys.executable, str(decoder_script), str(output / "dm-packets.tsv"),
                 "--vectors", str(output / "dm-wire-um.f32"),
                 "--summary", str(output / "dm-summary.json")], env,
            )
            command(
                [sys.executable, str(qualifier_script), "--fits", str(cube),
                 "--frames", str(args.frames), "--period", repr(1.0 / args.rate_hz),
                 "--readout-us", "2000", "--lines", "32",
                 "--wfs-packets", str(output / "wfs-packets.tsv"),
                 "--dm-summary", str(output / "dm-summary.json"),
                 "--dm-id-base", "0", "--summary", str(output / "physical-summary.json")],
                env,
            )
            physical = json.loads((output / "physical-summary.json").read_text())
            if physical.get("qualified") is not True:
                raise RuntimeError("WFS/Standard-DM capture did not qualify")
            require_physical_latencies(physical, args.frames)
            # The adapter accepts micrometres and presents metres to HEART;
            # the Standard-DM UDP protocol encodes micrometres again.
            wire_micrometres = np.fromfile(output / "dm-wire-um.f32", dtype="<f4")
            if wire_micrometres.size != demanded.size:
                raise RuntimeError("Standard-DM wire vector extent differs from demand")
            wire_difference = float(np.max(np.abs(wire_micrometres - demanded)))
            report["max_wire_difference_um"] = wire_difference
            if not np.isfinite(wire_difference) or wire_difference > 1e-6:
                raise RuntimeError(f"Standard-DM wire vectors differ from demand by {wire_difference} µm")
            report["wire_qualified"] = True
            report["latency_us"] = {
                "first_wfs_packet_to_dm": physical["first_wfs_packet_to_dm_us"],
                "terminal_wfs_packet_to_dm": physical["terminal_wfs_packet_to_dm_us"],
                "source_first_to_terminal": physical["source_first_to_terminal_us"],
            }
            report["physical_summary"] = str(output / "physical-summary.json")
        report["qualified"] = True
        print(json.dumps(report, indent=2))
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        if args.controller == "julia":
            island_quit_request.touch(exist_ok=True)
        if args.wire_capture:
            adapter_stop.touch(exist_ok=True)
        if measurement_links:
            link_tool = str(installation.tool("pwao-link"))
            for source_port, sink_port in reversed(measurement_links):
                try:
                    command([link_tool, "-r", "pipewire-ao-0", "-d",
                             source_port, sink_port], env)
                except Exception as cleanup_error:
                    report.setdefault("cleanup_errors", []).append(
                        f"{source_port} -> {sink_port}: {cleanup_error}"
                    )
        for process, stream, control in reversed(processes):
            stop(process, stream, control=control)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
