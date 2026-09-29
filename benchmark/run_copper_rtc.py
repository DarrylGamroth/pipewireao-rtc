#!/usr/bin/env python3
"""Run the full-frame Copper FGN graph under pipewireao-rtc on a private core."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import subprocess
import sys
import time

import numpy as np


RTC = Path(__file__).resolve().parents[1]


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
    parser.add_argument("--frames", type=int, default=16)
    parser.add_argument("--reference-vectors", type=Path,
                        help="optional demanded-um.f32 from the matched FGN full-frame replay")
    args = parser.parse_args()
    if not 1 <= args.frames <= 1024:
        parser.error("--frames must be in 1..1024")
    output = args.output_dir.resolve()
    if output.exists():
        parser.error(f"output directory already exists: {output}")
    scripts = args.algorithms_root.resolve() / "scripts"
    sys.path.insert(0, str(scripts))
    from run_fgn_copper_fullframe_live import (  # noqa: PLC0415
        command, compile_observer, make_environment, pipewire_installation,
        require, start, stop, wait_for, wait_text,
    )

    installation = pipewire_installation(None, args.pipewire_prefix)
    bundle = require(args.fgn_bundle, "FGN Copper bundle")
    heart = require(args.heart_plugin, "HEART SPA plugin")
    cube = require(args.cube, "Copper FITS cube")
    simulator = require(args.wfs_simulator, "wfsSimulator")
    rtc_bin = require(args.rtc_bin, "pipewireao-rtc executable")
    output.mkdir(parents=True)
    env = make_environment(output, heart, 474, installation)
    observer_bin = compile_observer(output, env, 474, installation)
    subprocess.run(
        [sys.executable, str(RTC / "benchmark/render_revolt_copper_graph.py"),
         "--algorithms-root", str(args.algorithms_root),
         "--heart-config", str(args.heart_config),
         "--fgn-bundle", str(bundle), "--clipping-feedback",
         "--output-dir", str(output)],
        check=True,
    )
    env["PIPEWIREAO_RTC_GRAPH_COPPER_NATIVE"] = str(
        output / "revolt-copper-rtc-graph.conf"
    )
    processes = []
    report = {"frames": args.frames, "rate_hz": 474, "readout_us": 2000,
              "fixture": str(RTC / "fixtures/revolt-copper-native-development.conf"),
              "cube": str(cube), "bundle": str(bundle), "qualified": False}
    try:
        daemon, daemon_log = start(
            [str(installation.daemon), "-c", "fgn-copper-live.conf"],
            env, output / "daemon.log", cwd=installation.working_directory,
        )
        processes.append((daemon, daemon_log, None))
        wait_for("private PipeWireAO socket",
                 lambda: (Path(env["XDG_RUNTIME_DIR"]) / "pipewire-ao-0").exists(), 15)
        observer, observer_log = start(
            [str(observer_bin), "--csv", str(output / "demanded.csv"),
             "--vectors", str(output / "demanded-um.f32"),
             "--max-records", str(args.frames + 4)],
            env, output / "observer.log", stdin=True,
        )
        processes.append((observer, observer_log, "q"))
        wait_text(output / "observer.log", "CONNECT_ACCEPTED", process=observer)
        rtc, rtc_log = start(
            [str(rtc_bin), "--config",
             str(RTC / "fixtures/revolt-copper-native-development.conf"),
             "--hold"], env, output / "rtc.log", stdin=True,
        )
        processes.append((rtc, rtc_log, "quit\n"))
        wait_text(output / "rtc.log", "RUNNING", 30, rtc)
        command([str(installation.tool("pwao-dump")), "-r", "pipewire-ao-0"], env)
        (output / "input.fits").symlink_to(cube)
        replay, replay_log = start(
            [str(simulator), "-file", "input.fits", "-tPort", "6000",
             "-period", repr(1.0 / 474), "-readout", "2000", "-lines", "32",
             "-numFrames", str(args.frames)],
            env, output / "wfs-simulator.log", cwd=output,
        )
        processes.append((replay, replay_log, None))
        replay.wait(timeout=args.frames / 474 + 15)
        if replay.returncode != 0:
            raise RuntimeError("wfsSimulator failed")
        # The observer flushes its FILE streams when it stops. The matched
        # Copper runner also allows one second for queued graph output here.
        time.sleep(1.0)
        stop(rtc, rtc_log, control="quit\n")
        processes.remove((rtc, rtc_log, "quit\n"))
        if rtc.returncode != 0 or "OFFLINE" not in (output / "rtc.log").read_text():
            raise RuntimeError("RTC did not unload cleanly")
        stop(observer, observer_log, control="q")
        processes.remove((observer, observer_log, "q"))
        with (output / "demanded.csv").open(newline="") as stream:
            sequences = [int(row["sequence"]) for row in csv.DictReader(stream)]
        if sequences != list(range(args.frames)):
            raise RuntimeError(f"demanded command delivery is not contiguous: {sequences}")
        demanded = np.fromfile(output / "demanded-um.f32", dtype="<f4")
        if demanded.size != args.frames * 277:
            raise RuntimeError(f"demanded vector count is {demanded.size // 277}, expected {args.frames}")
        if args.reference_vectors is not None:
            reference = np.fromfile(args.reference_vectors, dtype="<f4")[:demanded.size]
            if reference.size != demanded.size:
                raise RuntimeError("reference has too few demanded vectors")
            difference = float(np.max(np.abs(demanded - reference)))
            report["max_reference_difference_um"] = difference
            if not np.isfinite(difference) or difference > 1e-6:
                raise RuntimeError(f"RTC demanded vectors differ from FGN reference by {difference} µm")
        report["qualified"] = True
        print(json.dumps(report, indent=2))
    finally:
        for process, stream, control in reversed(processes):
            stop(process, stream, control=control)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
