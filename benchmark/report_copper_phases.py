#!/usr/bin/env python3
"""Extract first-frame and later-frame timing from qualified Copper captures."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from run_copper_baseline import JFG, capture_latency_phases, require_exact, sha256


def requalify_capture(wfs: Path, dm: Path, manifest: dict, published: dict,
                      dm_id_base: int) -> None:
    """Revalidate present packets; older manifests lack qualification-time hashes."""
    scripts = JFG / "benchmark/heart"
    with tempfile.TemporaryDirectory(prefix="copper-phase-qualify-") as temporary:
        root = Path(temporary)
        dm_summary = root / "dm.json"
        decoder = [sys.executable, str(scripts / "decode_std_dm_packets.py"), str(dm),
                   "--vectors", str(root / "dm.f32"), "--summary", str(dm_summary)]
        qualifier = [
            sys.executable, str(scripts / "qualify_copper_aos_capture.py"),
            "--fits", manifest["fits"], "--frames", str(manifest["frames"]),
            "--period", str(published["period_s"]),
            "--readout-us", str(published["readout_us"]),
            "--lines", str(published["lines_per_datagram"]),
            "--wfs-packets", str(wfs), "--dm-summary", str(dm_summary),
            "--dm-id-base", str(dm_id_base), "--summary", str(root / "qualification.json"),
        ]
        for command in (decoder, qualifier):
            result = subprocess.run(command, capture_output=True, text=True, check=False)
            require_exact(result.returncode == 0,
                          f"current packet qualification failed for {wfs}: {result.stderr or result.stdout}")
        require_exact(json.loads((root / "qualification.json").read_text())["qualified"] is True,
                      f"current packet qualification failed for {wfs}")


def summarize_manifest(path: Path) -> dict:
    manifest = json.loads(path.read_text())
    require_exact(manifest.get("qualified") is True, f"unqualified manifest: {path}")
    frames = manifest["frames"]
    runs = []
    warmup_modes = set()
    for run in manifest["runs"]:
        argv = run["commands"]["jfg"]["argv"]
        require_exact("--graph-warmup" in argv,
                      f"JFG warmup policy is not recorded in {path}")
        warmup_modes.add(argv[argv.index("--graph-warmup") + 1])
        root = Path(run["runner_reports"]["heart"]).parent.parent
        owners = {}
        for owner, wfs, dm in (
            ("heart", root / "heart/std-wfs-packets.tsv", root / "heart/std-dm-packets.tsv"),
            ("fgn", root / "fgn/wfs-packets.tsv", root / "fgn/dm-packets.tsv"),
            ("jfg", root / "jfg-wfs-packets.tsv", root / "jfg-dm-packets.tsv"),
        ):
            published = run["qualification"][owner]
            dm_id_base = 1 if owner == "heart" else 0
            requalify_capture(wfs, dm, manifest, published, dm_id_base)
            phases = capture_latency_phases(wfs, dm, frames, dm_id_base=dm_id_base)
            for boundary in ("first_wfs_packet_to_dm_us", "terminal_wfs_packet_to_dm_us"):
                for percentile in ("min", "p50", "p99", "max"):
                    require_exact(
                        abs(phases["all_frames"][boundary][percentile]
                            - published[boundary][percentile]) < 1.0,
                        f"capture timing differs from qualified {owner} summary in {path}",
                    )
                require_exact(phases["all_frames"][boundary]["count"] ==
                              published[boundary]["count"],
                              f"capture count differs from qualified {owner} summary in {path}")
            owners[owner] = {
                "wfs": str(wfs), "wfs_sha256": sha256(wfs),
                "dm": str(dm), "dm_sha256": sha256(dm), "phases": phases,
            }
        runs.append({"index": run["index"], "owners": owners})
    require_exact(len(warmup_modes) == 1, f"JFG warmup policy changed within {path}")
    return {"manifest": str(path), "manifest_sha256": sha256(path),
            "mode": manifest["mode"], "frames": frames,
            "historical_capture_integrity": "qualification-time capture hashes unavailable; current captures checked against retained summaries and packet identities",
            "requalification_scripts_sha256": {
                name: sha256(JFG / "benchmark/heart" / name)
                for name in ("decode_std_dm_packets.py", "qualify_copper_aos_capture.py")
            },
            "jfg_graph_warmup": warmup_modes.pop(), "runs": runs}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", nargs="+", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = {"qualified_manifests": [summarize_manifest(path.resolve())
                                      for path in args.manifest]}
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
