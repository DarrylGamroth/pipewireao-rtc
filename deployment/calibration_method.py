#!/usr/bin/env python3
"""Acquire one declared Classic CPU probe method; publish an unaccepted candidate."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace

import calibration_campaign as campaign
import deploy
import export as science
import export_calibration
import export_hil


ROOT = Path(__file__).resolve().parent


def validate_method(value):
    required = {"version", "run", "order"}
    if not isinstance(value, dict) or not required <= value.keys() or value.keys() - required - {"probe_basis"}:
        raise ValueError("method requires version, run, order and optional probe_basis")
    if type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("unsupported method version")
    campaign.positive_integer(value["run"], "method run", 2**64 - 1)
    if value["order"] not in ("forward", "reverse"):
        raise ValueError("method order must be forward or reverse")
    if "probe_basis" in value:
        basis = value["probe_basis"]
        if not isinstance(basis, dict):
            raise ValueError("probe_basis must be an object")
        fields = {"zonal": {"kind"}, "hadamard": {"kind"},
                  "modal": {"kind", "positive_commands", "mode_amplitudes"},
                  "spatial_sine": {"kind", "actuator_positions", "spatial_frequencies",
                                   "mode_amplitudes", "normalization", "minimum_sampled_peak"}}
        kind = basis.get("kind")
        if not isinstance(kind, str) or kind not in fields or set(basis) != fields[kind]:
            raise ValueError("unknown or incomplete probe basis declaration")
        # Numerical geometry/amplitude admission belongs to the public AOC client.
    return value


def file_identity(root):
    """Hash ordinary immutable package files; reject symlinks, including parents."""
    root = root.absolute()
    if any(path.is_symlink() for path in (root, *root.parents)) or not root.is_dir():
        raise ValueError("package must be an ordinary directory")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"package symlink is unsupported: {path}")
        if path.is_file():
            result[str(path.relative_to(root))] = science.sha256(path)
    return result


def check_identity(root, identity):
    if file_identity(root) != identity:
        raise ValueError("frozen package file identity changed")


def retained_startup(base, prefix):
    specification = deploy.profile(base / "deployment.conf", prefix)
    provenance = export_hil.campaign_json(base, "provenance.json")
    snapshot, graph, bindings = export_hil.classic_snapshot(base, provenance, prefix)
    export_hil.validate_startup_bindings(base, specification, provenance, graph, bindings)
    payloads = []
    for name, element, shape in (("background", "F32_LE", (352, 352)),
                                  ("reference-slopes", "F32_LE", (188, 2)),
                                  ("active", "Bool", (188,))):
        binding = bindings[name]
        path = export_hil.campaign_file(base, "calibration/" + binding["file"], 1024 * 1024)
        if "sha256" in binding and science.sha256(path) != binding["sha256"]:
            raise ValueError(f"retained startup binding hash differs: {name}")
        payloads.append(export_hil.finite_payload(path, element, shape))
    return (*payloads, snapshot)


def analysis(action, output, package, julia, timeout, *, seal=None):
    argv = [julia, "--startup-file=no", "--threads=2,0", "--project=" + str(package / "hil"),
            str(output / "analysis/calibration_method_analysis.jl"), action, str(output), str(package)]
    if seal is not None:
        argv.append(seal)
    with (output / (action + ".stdout")).open("w") as stdout, (output / (action + ".stderr")).open("w") as stderr:
        subprocess.run(argv, stdout=stdout, stderr=stderr, check=True, timeout=timeout,
                       env={**os.environ, "OPENBLAS_NUM_THREADS": "1"})


def method(arguments):
    started = time.perf_counter_ns()
    if sys.byteorder != "little":
        raise ValueError("method packed results require a little-endian host")
    prefix = arguments.prefix.resolve()
    if prefix != Path("/opt/pipewireao"):
        raise ValueError("maintained run_stage currently supports /opt/pipewireao only")
    recipe = campaign.validate_recipe(export_hil.campaign_json(arguments.recipe.absolute().parent, arguments.recipe.name))
    declaration = validate_method(export_hil.campaign_json(arguments.method.absolute().parent, arguments.method.name))
    base = arguments.base_package.absolute()
    output = arguments.output.resolve()
    aoc = arguments.aoc_source.resolve()
    if arguments.output.is_symlink() or output.exists() or output.is_relative_to(base.resolve()) or output.is_relative_to(aoc):
        raise ValueError("method output must be new and outside source packages")
    runtime = arguments.runtime.absolute()
    resolved_runtime = runtime.resolve()
    if (runtime.exists() or runtime.is_symlink() or resolved_runtime.is_relative_to(base.resolve()) or
            resolved_runtime.is_relative_to(aoc) or resolved_runtime.is_relative_to(output) or
            output.is_relative_to(resolved_runtime)):
        raise ValueError("method runtime must be new and separate from source packages and output")
    identity = file_identity(base)
    background, references, active, snapshot = retained_startup(base, prefix)
    output.mkdir(parents=True)
    record = {"version": 1, "phase": "preparing", "scope": "Classic CPU simulated method acquisition; unaccepted candidate",
              "timing_ns": {"preparation": None, "startup_readiness": None, "acquisition": None,
                            "public_shutdown": None, "reduction": None, "total": None}}
    try:
        science.write_json(output / "recipe.json", recipe)
        science.write_json(output / "method.json", declaration)
        shutil.copy2(arguments.recipe, output / "input-recipe.json")
        shutil.copy2(arguments.method, output / "input-method.json")
        science.write_json(output / "base-identity.json", {"files": identity, "startup_snapshot": snapshot,
                           "source_recipe_sha256": science.sha256(arguments.recipe),
                           "source_method_sha256": science.sha256(arguments.method)})
        base_copy = campaign.stage_base(base, output / "method-base", recipe, "interaction", background,
                                       references, active, aoc, prefix)
        package = output / "package"
        export_calibration.export(SimpleNamespace(base_package=base_copy, output=package, pipewire_prefix=prefix,
            deployment=True, rtc_binary=arguments.rtc_binary, calibration_binary=arguments.calibration_binary,
            illumination="lamp", calibration_stage="interaction", capture_max_bytes=None))
        scripts = output / "analysis"
        scripts.mkdir()
        shutil.copy2(ROOT / "hil/calibration_method_analysis.jl", scripts)
        shutil.copy2(package / "hil/calibration_client.jl", scripts)
        sources = output / "orchestration-sources"
        sources.mkdir()
        for module in (sys.modules[__name__], campaign, deploy, science, export_calibration, export_hil):
            shutil.copy2(Path(module.__file__), sources)
        analysis("prepare", output, package, arguments.julia, recipe["stage_timeout_seconds"])
        check_identity(base, identity)
        frozen = {str(path.relative_to(output)): science.sha256(path) for path in sorted(output.iterdir()) if path.is_file()}
        frozen.update({str(path.relative_to(output)): science.sha256(path) for path in sorted(scripts.iterdir()) if path.is_file()})
        frozen.update({str(path.relative_to(output)): science.sha256(path) for path in sorted(sources.iterdir()) if path.is_file()})
        package_identity = file_identity(package)
        science.write_json(output / "prepared-identity.json", {"files": frozen, "package_files": package_identity})
        seal = science.sha256(output / "prepared-identity.json")
        record["prepared_identity_sha256"] = seal
        record["timing_ns"]["preparation"] = time.perf_counter_ns() - started
        record["phase"] = "acquiring"
        acquired = campaign.run_stage(package, output / "evidence", runtime, recipe, "interaction")
        record["stage"] = acquired
        record["timing_ns"].update({key: acquired["timing_ns"][key] for key in ("startup_readiness", "acquisition", "public_shutdown")})
        if not all(acquired.get(key) is True for key in ("restoration_confirmed", "release_confirmed", "shutdown_confirmed")) or acquired.get("failure"):
            raise ValueError("method acquisition lifecycle incomplete")
        if science.sha256(output / "prepared-identity.json") != seal:
            raise ValueError("prepared identity changed")
        for relative, expected in frozen.items():
            if science.sha256(output / relative) != expected:
                raise ValueError(f"prepared input changed: {relative}")
        check_identity(package, package_identity)
        check_identity(base, identity)
        reduced = time.perf_counter_ns()
        try:
            analysis("reduce", output, package, arguments.julia, recipe["stage_timeout_seconds"], seal=seal)
        finally:
            record["timing_ns"]["reduction"] = time.perf_counter_ns() - reduced
        record["candidate"] = export_hil.campaign_json(output, "candidate-response.json")
        record["phase"] = "complete-candidate"
    except BaseException as error:
        record["failure"] = repr(error)
        raise
    finally:
        if record["timing_ns"]["preparation"] is None:
            record["timing_ns"]["preparation"] = time.perf_counter_ns() - started
        evidence = output / "evidence/stage-result.json"
        if evidence.is_file() and "stage" not in record:
            record["stage"] = json.loads(evidence.read_text())
            record["timing_ns"].update({key: record["stage"].get("timing_ns", {}).get(key) for key in ("startup_readiness", "acquisition", "public_shutdown")})
        record["timing_ns"]["total"] = time.perf_counter_ns() - started
        deploy.atomic_record(output / "method-result.json", record)
    return output / "method-result.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("base-package", "recipe", "method", "output", "aoc-source", "rtc-binary", "calibration-binary", "runtime"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--julia", default="julia")
    print(method(parser.parse_args(argv)))


if __name__ == "__main__":
    main()
