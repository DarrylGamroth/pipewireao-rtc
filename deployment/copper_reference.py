#!/usr/bin/env python3
"""Acquire Copper dark/reference candidates through the deployed calibration owner.

The resulting reference is characterized, not adopted or scientifically accepted.
Numerical calculations use the package's public AOC analysis helper.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
import tomllib
from types import SimpleNamespace

import calibration_campaign as acquisition
import deploy
import export as science
import export_calibration
import export_hil


STAGES = ("dark", "training", "qualification")


def input_snapshot(base, aoc):
    """Bind exactly the repeated cold copy inputs, including added/removed files."""
    source = {}
    for name in ("Project.toml", "src", "ext", "graphs", "LICENSE", "LICENSE.md"):
        entry = aoc / name
        paths = entry.rglob("*") if entry.is_dir() else (entry,)
        for path in paths:
            if path.is_file():
                source[str(path.relative_to(aoc))] = science.sha256(path)
    helpers = {path.name: science.sha256(path) for path in (Path(__file__).parent / "hil").glob("*.jl")
               if not path.name.startswith("test_")}
    return {"base_descriptor_sha256": science.sha256(base / "deployment.conf"),
            "aoc_files": source, "helpers": helpers}


def check_products(output, products, reports):
    for name, expected in products.items():
        path = output / name
        if path.is_symlink() or science.sha256(path) != expected:
            raise ValueError("measured candidate changed: " + name)
    for path, expected in reports.items():
        if Path(path).is_symlink() or science.sha256(Path(path)) != expected:
            raise ValueError("producing analysis report changed")


def analysis_products(output, evidence, stage, recipe, helper_sha):
    """Admit produced bytes against the successful public numerical report."""
    path = evidence / "analysis.json"
    if path.is_symlink():
        raise ValueError("analysis report must be an owned regular file")
    report = json.loads(path.read_text())
    method = "ReferenceFrames.DarkFrameMoments" if stage == "dark" else "Diagnostics.RepeatedResponseMoments"
    identities = report["input_identities"]
    if ((report["profile"], report["stage"], report["status"], report["public_method"], report["samples"]) !=
            ("copper", stage, "valid-candidate", method, recipe[stage + "_frames"]) or
            report["analysis_source_sha256"] != helper_sha or
            identities["recipe_sha256"] != science.sha256(output / "recipe.json") or
            identities["stage_result_sha256"] != science.sha256(evidence / "stage-result.json")):
        raise ValueError("numerical report differs from the declared stage")
    expected = {
        "dark": {"measured-background.f32le": (16384, [64, 64], "F32_LE", "ADC"),
                 "measured-dark-variance.f64le": (32768, [64, 64], "F64_LE", "ADC squared")},
        "training": {"measured-reference-pixels.f32le": (14400, [3600], "F32_LE", "normalized pixel"),
                     "measured-reference-variance.f64le": (28800, [3600], "F64_LE", "normalized pixel squared")},
        "qualification": {"qualification-mean.f64le": (28800, [3600], "F64_LE", "normalized pixel")},
    }[stage]
    records = report["artifacts"]
    if len(records) != len(expected) or {item["path"] for item in records} != set(expected):
        raise ValueError("numerical report must declare the exact candidate artifacts")
    hashes = {}
    for item in records:
        size, shape, element, units = expected[item["path"]]
        candidate = output / item["path"]
        if (item["bytes"], item["shape"], item["element_type"], item["layout"], item["units"]) != (size, shape, element, "ROW_MAJOR", units):
            raise ValueError("candidate artifact contract differs")
        if candidate.is_symlink() or candidate.stat().st_size != size or science.sha256(candidate) != item["sha256"]:
            raise ValueError("candidate bytes differ from producing analysis")
        hashes[item["path"]] = item["sha256"]
    return hashes, science.sha256(path)


def validate_recipe(value):
    fields = {"version", "dark_frames", "training_frames", "qualification_frames",
              "seeds", "lamp_magnitude", "reference", "settling", "adc_upper_rail",
              "request_timeout_ns", "stage_timeout_seconds"}
    if not isinstance(value, dict) or set(value) != fields or type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("declare the complete Version 1 Copper reference recipe")
    for stage in STAGES:
        count = acquisition.positive_integer(value[stage + "_frames"], stage + " frames", 64)
        if count < 2:
            raise ValueError("reference moments require at least two exposures")
    seeds = value["seeds"]
    if not isinstance(seeds, dict) or set(seeds) != set(STAGES):
        raise ValueError("declare one detector seed per stage")
    if any(type(seed) is not int or not 0 <= seed <= 2**32 - 1 for seed in seeds.values()) or len(set(seeds.values())) != 3:
        raise ValueError("declare three distinct UInt32 detector seeds")
    if type(value["lamp_magnitude"]) not in (int, float) or not math.isfinite(value["lamp_magnitude"]):
        raise ValueError("lamp magnitude must be finite")
    reference = value["reference"]
    if not isinstance(reference, list) or len(reference) != 277 or any(type(x) not in (int, float) or not math.isfinite(x) for x in reference):
        raise ValueError("reference requires 277 finite physical coordinates")
    rule = value["settling"]
    if isinstance(rule, dict) and set(rule) == {"kind", "frames"} and rule["kind"] == "discard_exposures":
        acquisition.positive_integer(rule["frames"], "settling frames", 4096)
    elif isinstance(rule, dict) and set(rule) == {"kind", "duration_ns"} and rule["kind"] == "model_time":
        acquisition.positive_integer(rule["duration_ns"], "settling duration", 2**63 - 1)
    else:
        raise ValueError("Copper requires completed exposure settling")
    acquisition.positive_integer(value["adc_upper_rail"], "ADC upper rail", 65535)
    acquisition.positive_integer(value["request_timeout_ns"], "operation timeout", 30_000_000_000)
    acquisition.positive_integer(value["stage_timeout_seconds"], "stage timeout", 3600)
    result = copy.deepcopy(value)
    try:
        result["reference"] = [acquisition.wire_float32(x) for x in reference]
    except (OverflowError, struct.error) as error:
        raise ValueError("reference must be representable as Float32") from error
    return result


def validate_base(base, prefix, recipe):
    specification = deploy.profile(base / "deployment.conf", prefix)
    provenance = json.loads((base / "provenance.json").read_text())
    if (provenance["profile"] != "copper" or provenance["engine"] not in ("fgn", "jfg") or
            provenance["mode"] != "frame" or provenance.get("hil", {}).get("backend") != "cpu"):
        raise ValueError("reference acquisition requires complete-frame Copper CPU science")
    source = next(owner for owner in specification["owners"] if owner["role"] == specification["source-owner"])
    argv = source["argv"]
    if argv.count("--backend") != 1 or argv[argv.index("--backend") + 1] != "cpu":
        raise ValueError("source owner must declare the CPU backend")
    graph = deploy.decode(base / "graphs/graph.conf.in", prefix)
    export_calibration.split_graph(graph, "copper", provenance["engine"], "reference-validation")
    bindings = [item for item in provenance["parameters"] if item["name"] == "background"]
    if len(bindings) != 1 or (bindings[0]["element_type"], bindings[0]["shape"]) != ("F32_LE", [64, 64]):
        raise ValueError("Copper requires one 64×64 Float32 background binding")
    pixel = next(node for node in graph["filter.graph"]["nodes"] if node["label"] == "pixel-calibration-u16-f32")
    filename = bindings[0]["file"]
    if (not isinstance(filename, str) or filename in ("", ".", "..") or Path(filename).name != filename or
            bindings[0]["endpoint"] != pixel["name"] + ":background" or
            (base / "calibration" / filename).is_symlink()):
        raise ValueError("background must bind the declared detector plane in the calibration directory")
    project = tomllib.loads((base / "hil/Project.toml").read_text())
    if project.get("sources", {}).get("AdaptiveOpticsCalibration") != {"path": "packages/AdaptiveOpticsCalibration"}:
        raise ValueError("base must declare its local AOC numerical dependency")
    detector = next(node["config"] for node in tomllib.loads((base / "hil/plant.toml").read_text())["nodes"] if node["name"] == "detector")
    if type(detector["bits"]) is not int or detector["bits"] != 14:
        raise ValueError("this Copper reference increment requires the declared 14-bit detector")
    acquisition.validate_detector_rail(detector, recipe)
    return specification, provenance, bindings[0]


def stage_base(base, output, recipe, stage, background, aoc_source, prefix):
    """Change only declared stage settings, background and cold helper sources."""
    if stage not in STAGES:
        raise ValueError("unknown reference stage")
    _, provenance, binding = validate_base(base, prefix, recipe)
    if len(background) != 64 * 64 * 4 or not all(math.isfinite(x[0]) for x in struct.iter_unpack("<f", background)):
        raise ValueError("background requires 4096 finite Float32 ADC values")
    if output.exists() or output.is_symlink():
        raise ValueError("each reference stage base must be fresh")
    shutil.copytree(base, output)
    path = output / "calibration" / binding["file"]
    path.write_bytes(background)
    if "sha256" in binding:
        binding["sha256"] = science.sha256(path)
    model_path = output / "hil/plant.toml"
    model = acquisition.set_model_setting(model_path.read_text(), "pwfs", "source_magnitude", recipe["lamp_magnitude"])
    model = acquisition.set_model_setting(model, "detector", "rng_seed", recipe["seeds"][stage])
    model_path.write_text(model)
    target = output / "hil/packages/AdaptiveOpticsCalibration"
    shutil.rmtree(target)
    export_hil.copy_package(aoc_source, target)
    for helper in (Path(__file__).parent / "hil").glob("*.jl"):
        if not helper.name.startswith("test_"):
            shutil.copy2(helper, output / "hil" / helper.name)
    provenance["reference_campaign_inputs"] = {
        "stage": stage, "recipe": recipe,
        "source_deployment_sha256": science.sha256(base / "deployment.conf"),
        "background_sha256": science.sha256(path),
        "aoc_revision": science.revision(aoc_source),
        "aoc_files": {str(p.relative_to(target)): science.sha256(p) for p in sorted(target.rglob("*")) if p.is_file()},
        "qualification": "measured candidate only; no reference adoption, interaction matrix, inverse or correction acceptance",
        "historical_fixture": "Only the background is replaced; other base offset provenance remains historical."
    }
    science.write_json(output / "provenance.json", provenance)
    specification = json.loads((output / "deployment.conf").read_text())
    specification["artifacts"] = {str(p.relative_to(output)): science.sha256(p) for p in sorted(output.rglob("*")) if p.is_file() and p.name != "deployment.conf"}
    science.write_json(output / "deployment.conf", specification)
    deploy.profile(output / "deployment.conf", prefix)
    return output


def campaign(arguments):
    started = time.perf_counter_ns()
    if sys.byteorder != "little":
        raise ValueError("packed capture requires a little-endian host")
    recipe = validate_recipe(json.loads(arguments.recipe.read_text()))
    base = arguments.base_package.resolve()
    validate_base(base, arguments.pipewire_prefix, recipe)
    aoc = arguments.aoc_source.resolve()
    for relative in ("src/reference_frames/dark_frame_moments.jl", "src/diagnostics/repeated_response_moments.jl"):
        if not (aoc / relative).is_file():
            raise ValueError("AOC dark and repeated-response algorithms are required")
    source_paths = [Path(module.__file__) for module in
                    (acquisition, deploy, science, export_calibration, export_hil)]
    source_paths.extend((Path(__file__), Path(__file__).parent / "hil/calibration_reference_analysis.jl"))
    source_hashes = {str(path.resolve()): science.sha256(path) for path in source_paths}
    snapshot = input_snapshot(base, aoc)
    output = arguments.output.absolute()
    if output.exists() or output.is_symlink() or arguments.runtime.exists() or arguments.runtime.is_symlink():
        raise ValueError("candidate and runtime roots must be fresh")
    output.mkdir(parents=True)
    science.write_json(output / "recipe.json", recipe)
    recipe_sha = science.sha256(output / "recipe.json")
    record = {"version": 1, "phase": "candidate", "stages": {}, "profile": "copper",
              "source_files": source_hashes, "copy_inputs": snapshot, "recipe_sha256": recipe_sha,
              "scope": "CPU measured dark/reference candidates; no scientific acceptance, activation, interaction matrix or cadence qualification"}
    background = bytes(64 * 64 * 4)
    products, reports = {}, {}
    def check_inputs():
        if input_snapshot(base, aoc) != snapshot or science.sha256(output / "recipe.json") != recipe_sha:
            raise ValueError("reference campaign copy inputs or recipe changed")
        if any(science.sha256(Path(path)) != expected for path, expected in source_hashes.items()):
            raise ValueError("reference campaign source changed")
        check_products(output, products, reports)
    try:
        for stage in STAGES:
            check_inputs()
            count = recipe[stage + "_frames"]
            prepared = stage_base(base, output / (stage + "-base"), recipe, stage, background, aoc, arguments.pipewire_prefix)
            package = output / (stage + "-package")
            export_calibration.export(SimpleNamespace(base_package=prepared, output=package,
                pipewire_prefix=arguments.pipewire_prefix, deployment=True,
                rtc_binary=arguments.rtc_binary, calibration_binary=arguments.calibration_binary,
                illumination="dark" if stage == "dark" else "lamp", calibration_stage=stage,
                capture_max_bytes=count * 22596))
            evidence = output / (stage + "-evidence")
            check_inputs()
            record["stages"][stage] = acquisition.run_stage(package, evidence, arguments.runtime / stage,
                recipe, stage, frames=count)
            check_inputs()
            analysis_started = time.perf_counter_ns()
            result = subprocess.run([arguments.julia, "--startup-file=no", "--threads=1,0",
                "--project=" + str(package / "hil"), str(package / "hil/calibration_reference_analysis.jl"),
                stage, str(output), str(evidence)], capture_output=True, text=True,
                timeout=recipe["stage_timeout_seconds"], env={**os.environ, "OPENBLAS_NUM_THREADS": "1"})
            (evidence / "analysis.stdout").write_text(result.stdout)
            (evidence / "analysis.stderr").write_text(result.stderr)
            record["stages"][stage]["analysis_wall_ns"] = time.perf_counter_ns() - analysis_started
            result.check_returncode()
            new_products, report_sha = analysis_products(output, evidence, stage, recipe,
                source_hashes[str((Path(__file__).parent / "hil/calibration_reference_analysis.jl").resolve())])
            if stage == "qualification":
                comparison = json.loads((evidence / "analysis.json").read_text())["comparison"]
                if comparison["reference_sha256"] != products["measured-reference-pixels.f32le"]:
                    raise ValueError("qualification differs from frozen training reference")
            products.update(new_products)
            reports[str(evidence / "analysis.json")] = report_sha
            record["stages"][stage]["analysis_sha256"] = report_sha
            if stage == "dark":
                background = (output / "measured-background.f32le").read_bytes()
        check_inputs()
        record["phase"] = "complete-candidate"
    except BaseException as error:
        record["phase"] = "failed-candidate"
        record["failure"] = repr(error)
        raise
    finally:
        record["artifacts"] = products
        record["timing_ns"] = {"total_campaign": time.perf_counter_ns() - started}
        deploy.atomic_record(output / "reference-result.json", record)
    return output / "reference-result.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("base-package", "output", "recipe", "aoc-source", "rtc-binary", "calibration-binary", "runtime"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--julia", default="julia")
    arguments = parser.parse_args(argv)
    if arguments.pipewire_prefix.resolve() != Path("/opt/pipewireao"):
        parser.error("this increment qualifies only /opt/pipewireao")
    print(campaign(arguments))


if __name__ == "__main__":
    main()
