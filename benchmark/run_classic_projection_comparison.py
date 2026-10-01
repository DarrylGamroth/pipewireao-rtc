#!/usr/bin/env python3
"""Interleave unchanged and candidate Julia checkouts under the Classic QoS gate."""
import argparse
import hashlib
from pathlib import Path
import subprocess

import run_classic_platform_campaign as platform


def cases(rates, repetitions, reverse_variants=False):
    indexed_rates = list(enumerate(rates))
    for repeat in range(repetitions):
        for index, rate in indexed_rates if repeat % 2 == 0 else indexed_rates[::-1]:
            variants = ("baseline", "candidate") if (repeat + index + reverse_variants) % 2 == 0 else ("candidate", "baseline")
            for variant in variants:
                yield repeat + 1, rate, variant


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-jfg-root", type=Path, required=True)
    parser.add_argument("--candidate-jfg-root", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--rates", type=int, nargs="+", default=[100, 250])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--reverse-variants", action="store_true", help="reverse each baseline/candidate pair")
    parser.add_argument("--frames", type=int, default=1029)
    parser.add_argument("--readout-us", type=int, default=2000)
    args = parser.parse_args()
    if not 1 <= args.frames <= 1029 or args.frames % 7 or args.repeats < 1:
        parser.error("frames must be a positive multiple of seven through 1029; repeats must be positive")
    if args.readout_us <= 0 or any(rate <= 0 or rate * args.readout_us >= 950000 for rate in args.rates):
        parser.error("readout must be positive and below 95% of each frame period")
    roots = {variant: getattr(args, variant + "_jfg_root").resolve(strict=True)
             for variant in ("baseline", "candidate")}
    if roots["baseline"] == roots["candidate"]:
        parser.error("baseline and candidate checkouts must differ")
    args.diagnostic, args.current_latency = False, 0
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {"scope": "finite software replay; interleaved Julia projection comparison",
                "requested": {key: str(value) if isinstance(value, Path) else value
                              for key, value in vars(args).items()},
                "source_revisions": {variant: platform.source_revisions(root) for variant, root in roots.items()},
                "initial_platform": platform.snapshot(), "runs": [],
                "harness_sha256": {str(Path(__file__)): hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                                   str(Path(platform.__file__)): hashlib.sha256(Path(platform.__file__).read_bytes()).hexdigest()}}
    source_archive = args.output / "source"
    source_archive.mkdir()
    # Preserve tracked edits and any new source, without copying build caches.
    for variant, root in roots.items():
        (source_archive / (variant + ".diff")).write_bytes(
            subprocess.check_output(["git", "-C", str(root), "diff", "HEAD", "--binary"]))
        new_files = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"])
        for relative in new_files.decode().split("\0"):
            if not relative.endswith((".jl", ".py", ".toml")):
                continue
            path = source_archive / variant / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((root / relative).read_bytes())
    platform.write_json(args.output / "manifest.json", manifest)
    for repeat, rate, variant in cases(args.rates, args.repeats, args.reverse_variants):
        args.jfg_root, args.current_rate = roots[variant], rate
        case = args.output / f"{variant}-jfg-row-{rate}hz-latency0-r{repeat}"
        print("START " + case.name, flush=True)
        result = platform.run_case("jfg-row", case, args)
        result.update(variant=variant, mode="latency0", repeat=repeat, jfg_root=str(args.jfg_root))
        manifest["runs"].append(result)
        platform.write_json(args.output / "manifest.json", manifest)
        print(f"DONE {case.name}: qualified={result['comparison_qualified']} errors={result['errors']}", flush=True)
        if not result["comparison_qualified"] or not result.get("case_group_empty"):
            raise SystemExit("failed replay retained; stop before another case")


if __name__ == "__main__":
    main()
