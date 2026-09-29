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


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


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
    parser.add_argument("--frames", type=int, default=16)
    parser.add_argument("--rate-hz", type=int, default=474,
                        help="offered frame rate; the 2 ms wfsSimulator readout permits at most 474 Hz")
    parser.add_argument("--reference-vectors", type=Path,
                        help="optional demanded-um.f32 from the matched FGN full-frame replay")
    args = parser.parse_args()
    if not 1 <= args.frames <= 1024:
        parser.error("--frames must be in 1..1024")
    if not 1 <= args.rate_hz <= MAX_RATE_HZ:
        parser.error(f"--rate-hz must be in 1..{MAX_RATE_HZ} for the 2 ms readout")
    if args.julia_blas_threads < 1:
        parser.error("--julia-blas-threads must be positive")
    if args.controller == "native" and args.julia_blas_threads != 1:
        parser.error("--julia-blas-threads applies only to --controller julia")
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
        require, start, stop, wait_for, wait_text,
    )

    installation = pipewire_installation(None, args.pipewire_prefix)
    heart = require(args.heart_plugin, "HEART SPA plugin")
    cube = require(args.cube, "Copper FITS cube")
    simulator = require(args.wfs_simulator, "wfsSimulator")
    rtc_bin = require(args.rtc_bin, "pipewireao-rtc executable")
    bundle = require(args.fgn_bundle, "FGN Copper bundle") if args.controller == "native" else None
    jfg_root = args.jfg_root.resolve()
    pipewireao_julia_root = args.pipewireao_julia_root.resolve()
    island_script = jfg_root / "scripts/run_pipewire_island.jl"
    deployment_project = jfg_root / "deployment/Project.toml"
    if args.controller == "julia":
        require(island_script, "JuliaFilterGraph PipeWire island script")
        require(deployment_project, "JuliaFilterGraph deployment project")
        require(pipewireao_julia_root / "Project.toml", "local PipeWireAO.jl project")
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
    if args.controller == "native":
        subprocess.run(
            [sys.executable, str(RTC / "benchmark/render_revolt_copper_graph.py"),
             "--algorithms-root", str(args.algorithms_root),
             "--heart-config", str(args.heart_config),
             "--fgn-bundle", str(bundle), "--clipping-feedback",
             "--rate-hz", str(args.rate_hz),
             "--output-dir", str(output)],
            check=True,
        )
        env["PIPEWIREAO_RTC_GRAPH_COPPER_NATIVE"] = str(
            output / "revolt-copper-rtc-graph.conf"
        )
    processes = []
    island_quit_request = output / "julia-island.quit"
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
              "cube": str(cube), "qualified": False,
              "delivery_qualified": False, "schedule_qualified": False,
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
    if args.controller == "julia":
        report["jfg_root"] = str(jfg_root)
        report["jfg_script_sha256"] = sha256_file(island_script)
        report["julia_blas_threads"] = args.julia_blas_threads
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
        if args.controller == "julia":
            depot = use_installed_julia_libraries(output, installation)
            report["julia_artifact_overlay"] = str(depot / "native-artifact")
            env.update({
                "JULIA_DEPOT_PATH": os.pathsep.join((
                    str(depot), os.environ.get("JULIA_DEPOT_PATH") or
                    str(Path.home() / ".julia"),
                )),
                "JULIA_LOAD_PATH": f"{pipewireao_julia_root}:@:@stdlib",
                "JULIA_RTC_WORKLOAD": "copper-fits-full-frame-feedback",
                "JULIA_RTC_COPPER_CONFIG_DIR": str(args.heart_config.resolve()),
                "JULIA_RTC_FRAME_RATE": str(args.rate_hz),
                "JULIA_RTC_INGRESS_MODE": "frame",
                "JULIA_RTC_CPU_WORKERS": "0",
                "OPENBLAS_NUM_THREADS": str(args.julia_blas_threads),
                "JULIA_RTC_COMMAND_LIMIT_UM": "0.8",
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
        report["placement"] = {
            "before_ingress": capture_placement(
                output, "before-ingress", placement_processes, env, profile,
                profile_sha256,
            ),
        }
        (output / "input.fits").symlink_to(cube)
        replay, replay_log = start(
            placed_argv(profile, "simulator",
                        [str(simulator), "-file", "input.fits", "-tPort", "6000",
                         "-period", repr(1.0 / args.rate_hz), "-readout", "2000", "-lines", "32",
                         "-numFrames", str(args.frames)]),
            env, output / "wfs-simulator.log", cwd=output,
        )
        processes.append((replay, replay_log, None))
        replay.wait(timeout=args.frames / args.rate_hz + 15)
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
        dump = command(
            [str(installation.tool("pwao-dump")), "-r", "pipewire-ao-0", "--raw"], env,
        )
        (output / "pipewire-after-replay.json").write_text(dump)
        report["wfs_counters"] = wfs_counters(dump)
        report["placement"]["after_replay"] = capture_placement(
            output, "after-replay", placement_processes, env, profile,
            profile_sha256,
        )
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
        report["qualified"] = True
        print(json.dumps(report, indent=2))
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        if args.controller == "julia":
            island_quit_request.touch(exist_ok=True)
        for process, stream, control in reversed(processes):
            stop(process, stream, control=control)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
