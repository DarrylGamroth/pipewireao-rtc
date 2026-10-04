#!/usr/bin/env python3
"""Characterize bounded Copper precision and response linearity candidates."""

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
import copper_reference as reference
import deploy
import export as science
import export_calibration
import export_hil


PRODUCTS = ("measured-background.f32le", "measured-dark-variance.f64le",
            "measured-reference-pixels.f32le", "measured-reference-variance.f64le",
            "qualification-mean.f64le")
STAGES = reference.STAGES


def validate_recipe(value):
    fields = {"version", "actuator", "amplitudes", "repeats", "frames_per_batch",
              "reference", "seed", "lamp_magnitude", "settling", "adc_upper_rail",
              "request_timeout_ns", "stage_timeout_seconds"}
    if not isinstance(value, dict) or set(value) != fields or type(value["version"]) is not int or value["version"] != 1:
        raise ValueError("declare the complete Version 1 Copper quality recipe")
    acquisition.positive_integer(value["actuator"], "actuator", 277)
    repeats = acquisition.positive_integer(value["repeats"], "repeats", 4)
    if repeats < 2:
        raise ValueError("repeats require at least two cycles")
    count = acquisition.positive_integer(value["frames_per_batch"], "frames per batch", 16)
    if count < 2:
        raise ValueError("each batch requires at least two exposures")
    if type(value["seed"]) is not int or not 0 <= value["seed"] < 2**32:
        raise ValueError("seed must be a UInt32 integer")
    if type(value["lamp_magnitude"]) not in (int, float) or not math.isfinite(value["lamp_magnitude"]):
        raise ValueError("lamp magnitude must be finite")
    amplitudes = value["amplitudes"]
    if not isinstance(amplitudes, list) or not 1 <= len(amplitudes) <= 3:
        raise ValueError("declare one to three amplitudes")
    if not isinstance(value["reference"], list) or len(value["reference"]) != 277:
        raise ValueError("reference requires 277 physical coordinates")
    try:
        converted = [acquisition.wire_float32(x) for x in amplitudes if type(x) in (int, float)]
        physical = [acquisition.wire_float32(x) for x in value["reference"] if type(x) in (int, float)]
    except (OverflowError, struct.error) as error:
        raise ValueError("quality commands require finite Float32 values") from error
    if len(converted) != len(amplitudes) or any(x <= 0 for x in converted) or any(a >= b for a, b in zip(converted, converted[1:])):
        raise ValueError("amplitudes must be distinct ascending positive Float32 values")
    if len(physical) != 277:
        raise ValueError("reference requires 277 finite Float32 values")
    rule = value["settling"]
    if isinstance(rule, dict) and set(rule) == {"kind", "frames"} and rule["kind"] == "discard_exposures":
        acquisition.positive_integer(rule["frames"], "settling frames", 4096)
    elif isinstance(rule, dict) and set(rule) == {"kind", "duration_ns"} and rule["kind"] == "model_time":
        acquisition.positive_integer(rule["duration_ns"], "settling duration", 2**63 - 1)
    else:
        raise ValueError("Copper quality requires completed exposure or model-time settling")
    acquisition.positive_integer(value["adc_upper_rail"], "ADC upper rail", 65535)
    acquisition.positive_integer(value["request_timeout_ns"], "operation timeout", 30_000_000_000)
    acquisition.positive_integer(value["stage_timeout_seconds"], "stage timeout", 1800)
    result = copy.deepcopy(value)
    result["amplitudes"] = converted
    result["reference"] = physical
    return result


def schedule(recipe):
    batches = []
    actuator = recipe["actuator"] - 1
    center = recipe["reference"][actuator]
    for amplitude in recipe["amplitudes"]:
        plus = acquisition.wire_float32(center + amplitude)
        minus = acquisition.wire_float32(center - amplitude)
        if not plus > center > minus:
            raise ValueError("Float32 probe perturbation collapsed at the selected reference")
    def append(label, repeat, amplitude, sign):
        figure = recipe["reference"].copy()
        if sign:
            figure[actuator] = acquisition.wire_float32(figure[actuator] + sign * amplitude)
        batches.append({"label": label, "repeat": repeat, "amplitude": amplitude,
                        "sign": sign, "figure": figure, "frames": recipe["frames_per_batch"]})
    for repeat in range(recipe["repeats"]):
        append("null_start", repeat, None, 0)
        amplitudes = recipe["amplitudes"] if repeat % 2 == 0 else reversed(recipe["amplitudes"])
        signs = (1, -1) if repeat % 2 == 0 else (-1, 1)
        for amplitude in amplitudes:
            for sign in signs:
                append("positive" if sign > 0 else "negative", repeat, amplitude, sign)
        append("null_end", repeat, None, 0)
    if len(batches) > 32:
        raise ValueError("quality schedule exceeds 32 batches")
    acquisition.validate_batches([{"figure": x["figure"], "frames": x["frames"]} for x in batches])
    return batches


def file_snapshot(paths):
    result = {}
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError("input must be a regular file: " + str(path))
        result[str(path.resolve())] = science.sha256(path)
    return result


def tree_files(root):
    if root.is_symlink() or not root.is_dir():
        raise ValueError("input tree must be an owned directory: " + str(root))
    return sorted(path for path in root.rglob("*") if path.is_file() or path.is_symlink())


def validate_candidate(candidate, base, recipe):
    """Recheck the complete producing campaign and its report-to-byte identity."""
    result_path = candidate / "reference-result.json"
    record = json.loads(result_path.read_text())
    original = reference.validate_recipe(json.loads((candidate / "recipe.json").read_text()))
    if (record.get("phase") != "complete-candidate" or record.get("profile") != "copper" or
            set(record.get("stages", {})) != set(STAGES) or
            record.get("recipe_sha256") != science.sha256(candidate / "recipe.json")):
        raise ValueError("reference candidate must be a complete Copper campaign")
    if (not acquisition.same_figure(original["reference"], recipe["reference"]) or
            original["lamp_magnitude"] != recipe["lamp_magnitude"] or
            original["adc_upper_rail"] != recipe["adc_upper_rail"]):
        raise ValueError("reference candidate differs in reference, lamp or ADC rail")
    if record.get("copy_inputs", {}).get("base_descriptor_sha256") != science.sha256(base / "deployment.conf"):
        raise ValueError("reference candidate requires the same science base fixture")
    helper = candidate / "training-package/hil/calibration_reference_analysis.jl"
    helper_sha = science.sha256(helper)
    products, reports = {}, {}
    for stage in STAGES:
        evidence = candidate / (stage + "-evidence")
        stage_result = json.loads((evidence / "stage-result.json").read_text())
        if (not stage_result.get("restoration_confirmed") or not stage_result.get("release_confirmed") or
                not stage_result.get("shutdown_confirmed") or stage_result.get("failure")):
            raise ValueError("reference candidate has an incomplete stage")
        new_products, report_sha = reference.analysis_products(candidate, evidence, stage, original, helper_sha)
        if record["stages"][stage].get("analysis_sha256") != report_sha:
            raise ValueError("reference campaign report digest differs")
        products.update(new_products)
        reports[str(evidence / "analysis.json")] = report_sha
    if products != record.get("artifacts"):
        raise ValueError("reference campaign artifacts differ")
    reference.check_products(candidate, products, reports)
    training_base = candidate / "training-base"
    training_provenance = json.loads((training_base / "provenance.json").read_text())
    base_provenance = json.loads((base / "provenance.json").read_text())
    if (training_provenance.get("profile"), training_provenance.get("engine"),
            training_provenance.get("mode")) != (base_provenance.get("profile"),
            base_provenance.get("engine"), base_provenance.get("mode")):
        raise ValueError("reference candidate uses a different science graph")
    if science.sha256(training_base / "graphs/graph.conf.in") != science.sha256(base / "graphs/graph.conf.in"):
        raise ValueError("reference candidate graph differs from selected science base")
    base_bindings = {path.name: path for path in (base / "calibration").iterdir() if path.is_file()}
    training_bindings = {path.name: path for path in (training_base / "calibration").iterdir() if path.is_file()}
    if set(base_bindings) != set(training_bindings):
        raise ValueError("reference candidate science bindings differ")
    background_name = next(item["file"] for item in base_provenance["parameters"]
                           if item["name"] == "background")
    for name in base_bindings.keys() - {background_name}:
        if science.sha256(base_bindings[name]) != science.sha256(training_bindings[name]):
            raise ValueError("reference candidate science binding differs: " + name)
    if science.sha256(training_bindings[background_name]) != products["measured-background.f32le"]:
        raise ValueError("reference candidate training background differs")
    base_model = tomllib.loads((base / "hil/plant.toml").read_text())
    training_model = tomllib.loads((training_base / "hil/plant.toml").read_text())
    def fixture(model):
        model = copy.deepcopy(model)
        nodes = {node["name"]: node["config"] for node in model["nodes"]}
        nodes["detector"].pop("rng_seed")
        nodes["pwfs"].pop("source_magnitude")
        return model
    if fixture(base_model) != fixture(training_model):
        raise ValueError("reference candidate plant or detector noise fixture differs")
    return record, original


def source_snapshot(base, aoc, candidate, arguments):
    sources = [Path(module.__file__) for module in
               (acquisition, reference, deploy, science, export_calibration, export_hil)]
    sources.append(Path(__file__))
    sources.extend((Path(__file__).parent / "hil").glob("*.jl"))
    sources.extend((arguments.rtc_binary, arguments.calibration_binary,
                    arguments.recipe,
                    candidate / "recipe.json", candidate / "reference-result.json",
                    candidate / "training-package/hil/calibration_reference_analysis.jl"))
    sources.extend(base.rglob("*"))
    sources.extend(tree_files(aoc))
    sources.extend(tree_files(candidate / "training-base"))
    for stage in STAGES:
        sources.extend((candidate / (stage + "-evidence") / "analysis.json",
                        candidate / (stage + "-evidence") / "stage-result.json"))
    sources.extend(candidate / name for name in PRODUCTS)
    return file_snapshot(path for path in sources if path.is_file() or path.is_symlink())


def check_snapshot(snapshot):
    if file_snapshot(Path(path) for path in snapshot) != snapshot:
        raise ValueError("frozen quality input changed")


def check_seal(output, seal):
    paths = {str(path.relative_to(output)) for path in tree_files(output / "training-package")}
    declared = {name for name in seal["files"] if name.startswith("training-package/")}
    if paths != declared:
        raise ValueError("prepared package file set changed")
    for name, expected in seal["files"].items():
        path = output / name
        if path.is_symlink() or not path.is_file() or science.sha256(path) != expected:
            raise ValueError("sealed quality input changed: " + name)


def analysis_products(output, evidence, recipe, plan):
    """Admit only the declared producer report and its exact numerical bytes."""
    report_path = evidence / "analysis.json"
    if report_path.is_symlink() or not report_path.is_file():
        raise ValueError("quality analysis report is missing or linked")
    report = json.loads(report_path.read_text())
    if (type(report.get("version")) is not int or report["version"] != 1 or
            report.get("profile") != "copper" or
            report.get("status") != "characterized-candidate" or
            report.get("public_methods") != ["Diagnostics.RepeatedResponseMoments",
                                              "InteractionMatrices.ZonalPushPull"] or
            report.get("scope") != "descriptive one-direction candidate; no interaction-matrix, inverse, correction or rate acceptance" or
            report.get("actuator") != recipe["actuator"] or
            report.get("samples_per_batch") != recipe["frames_per_batch"] or
            report.get("analysis_source_sha256") != science.sha256(output / "training-package/hil/calibration_quality_analysis.jl")):
        raise ValueError("quality report differs from the declared analysis")
    stage_path = evidence / "stage-result.json"
    stage = json.loads(stage_path.read_text())
    captures = stage.get("captures", [])
    if (len(captures) != len(plan) or len(report.get("batches", [])) != len(plan) or
            len(report.get("amplitudes", [])) != len(recipe["amplitudes"])):
        raise ValueError("quality report or stage omits scheduled probes")
    manifest_hashes = []
    def same_amplitude(first, second):
        if first is None or second is None:
            return first is None and second is None
        return (type(first) in (int, float) and type(second) in (int, float) and
                acquisition.wire_float32(first) == acquisition.wire_float32(second))
    for probe, (capture, batch, batch_report) in enumerate(zip(captures, plan, report["batches"])):
        if (any(type(batch_report.get(name)) is not int for name in ("probe", "repeat", "sign")) or
                capture["probe"] != probe or capture["figure"] != batch["figure"] or
                batch_report["probe"] != probe or batch_report["label"] != batch["label"] or
                batch_report["repeat"] != batch["repeat"] or batch_report["sign"] != batch["sign"] or
                not same_amplitude(batch_report["amplitude"], batch["amplitude"])):
            raise ValueError("quality report probe association differs")
        completion = capture["completion"]
        path = evidence / "captured" / completion["manifest"]
        if path.is_symlink() or science.sha256(path) != completion["sha256"]:
            raise ValueError("quality capture manifest changed")
        manifest_hashes.append(completion["sha256"])
    expected_hashes = {"quality_inputs_sha256": science.sha256(output / "quality-inputs.json"),
                       "recipe_sha256": science.sha256(output / "recipe.json"),
                       "schedule_sha256": science.sha256(output / "schedule.json"),
                       "stage_result_sha256": science.sha256(stage_path),
                       "producing_reference_analysis_sha256": science.sha256(output / "reference-candidate/training-evidence/analysis.json"),
                       "measured_reference_sha256": science.sha256(output / "measured-reference-pixels.f32le"),
                       "capture_manifest_sha256": manifest_hashes}
    if report.get("inputhashes") != expected_hashes:
        raise ValueError("quality report input identities differ")
    batches, amplitudes, repeats = len(plan), len(recipe["amplitudes"]), recipe["repeats"]
    expected = {
        "batch-means.f64le": ([batches, 3600], "normalized pixel"),
        "batch-variances.f64le": ([batches, 3600], "normalized pixel squared"),
        "derivative-repeats.f64le": ([amplitudes, repeats, 3600], "normalized pixel per micrometre OPD"),
        "derivative-means.f64le": ([amplitudes, 3600], "normalized pixel per micrometre OPD"),
    }
    records = report.get("artifacts")
    if not isinstance(records, list) or len(records) != len(expected) or {item.get("path") for item in records} != set(expected):
        raise ValueError("quality report must declare exactly four numerical artifacts")
    products = {}
    for item in records:
        name = item["path"]
        shape, units = expected[name]
        size = math.prod(shape) * 8
        path = output / name
        if (set(item) != {"path", "sha256", "bytes", "shape", "element_type", "layout", "units"} or
                (item["shape"], item["bytes"], item["element_type"], item["layout"], item["units"]) !=
                (shape, size, "F64_LE", "ROW_MAJOR", units) or path.is_symlink() or
                path.stat().st_size != size or science.sha256(path) != item["sha256"]):
            raise ValueError("quality artifact differs from producing report: " + name)
        products[name] = item["sha256"]
    return products, science.sha256(report_path)


def copy_candidate(candidate, output):
    for name in PRODUCTS:
        shutil.copy2(candidate / name, output / name)
    provenance = output / "reference-candidate"
    provenance.mkdir()
    for name in ("recipe.json", "reference-result.json"):
        shutil.copy2(candidate / name, provenance / name)
    for stage in STAGES:
        origin = candidate / (stage + "-evidence")
        destination = provenance / (stage + "-evidence")
        destination.mkdir()
        for name in ("analysis.json", "stage-result.json"):
            shutil.copy2(origin / name, destination / name)


def campaign(arguments):
    started = time.perf_counter_ns()
    if sys.byteorder != "little":
        raise ValueError("packed capture requires a little-endian host")
    recipe = validate_recipe(json.loads(arguments.recipe.read_text()))
    plan = schedule(recipe)
    base = arguments.base_package.resolve()
    candidate = arguments.reference_candidate.resolve()
    aoc = arguments.aoc_source.resolve()
    reference.validate_base(base, arguments.pipewire_prefix, recipe)
    validate_candidate(candidate, base, recipe)
    for relative in ("src/reference_frames/dark_frame_moments.jl", "src/diagnostics/repeated_response_moments.jl"):
        if not (aoc / relative).is_file():
            raise ValueError("AOC reference and response methods are required")
    output = arguments.output.absolute()
    if output.exists() or output.is_symlink() or arguments.runtime.exists() or arguments.runtime.is_symlink():
        raise ValueError("quality output and runtime roots must be fresh")
    snapshot = source_snapshot(base, aoc, candidate, arguments)
    output.mkdir(parents=True)
    science.write_json(output / "recipe.json", recipe)
    science.write_json(output / "schedule.json", plan)
    copy_candidate(candidate, output)
    record = {"version": 1, "phase": "candidate", "profile": "copper",
              "scope": "CPU measured precision/linearity characterization candidate only; no reference adoption, inverse, correction or cadence acceptance",
              "source_files": snapshot, "reference_candidate_sha256": science.sha256(candidate / "reference-result.json")}
    try:
        def check_inputs():
            if source_snapshot(base, aoc, candidate, arguments) != snapshot:
                raise ValueError("quality source, candidate or science base changed")
            if science.sha256(output / "recipe.json") != recipe_sha or science.sha256(output / "schedule.json") != schedule_sha:
                raise ValueError("quality recipe or schedule changed")
            if file_snapshot(output / name for name in PRODUCTS) != product_snapshot:
                raise ValueError("copied reference candidate changed")
            if file_snapshot(tree_files(output / "reference-candidate")) != candidate_snapshot:
                raise ValueError("copied candidate provenance changed")
            if science.sha256(output / "quality-inputs.json") != seal_sha:
                raise ValueError("quality input seal changed")
            check_seal(output, seal)
        recipe_sha = science.sha256(output / "recipe.json")
        schedule_sha = science.sha256(output / "schedule.json")
        product_snapshot = file_snapshot(output / name for name in PRODUCTS)
        candidate_snapshot = file_snapshot(tree_files(output / "reference-candidate"))
        check_snapshot(snapshot)
        training = {"seeds": {"training": recipe["seed"]}, "lamp_magnitude": recipe["lamp_magnitude"],
                    "adc_upper_rail": recipe["adc_upper_rail"]}
        prepared = reference.stage_base(base, output / "training-base", training, "training",
                                        (output / "measured-background.f32le").read_bytes(),
                                        aoc, arguments.pipewire_prefix)
        package = output / "training-package"
        total_bytes = sum(item["frames"] * acquisition.capture_contract("copper")[1]
                          for item in plan)
        export_calibration.export(SimpleNamespace(base_package=prepared, output=package,
            pipewire_prefix=arguments.pipewire_prefix, deployment=True,
            rtc_binary=arguments.rtc_binary, calibration_binary=arguments.calibration_binary,
            illumination="lamp", calibration_stage="training", capture_max_bytes=total_bytes))
        seal_files = [output / "recipe.json", output / "schedule.json"]
        seal_files.extend(output / name for name in PRODUCTS)
        seal_files.extend(tree_files(output / "reference-candidate"))
        seal_files.extend(tree_files(package))
        seal = {"version": 1, "files": {str(path.relative_to(output)): science.sha256(path)
                                        for path in seal_files}}
        science.write_json(output / "quality-inputs.json", seal)
        seal_sha = science.sha256(output / "quality-inputs.json")
        record["quality_inputs_sha256"] = seal_sha
        check_inputs()
        evidence = output / "training-evidence"
        record["stage"] = acquisition.run_stage(package, evidence, arguments.runtime / "training",
            recipe, "training", batches=[{"figure": item["figure"], "frames": item["frames"]}
                                        for item in plan])
        check_inputs()
        analysis_started = time.perf_counter_ns()
        result = subprocess.run([arguments.julia, "--startup-file=no", "--threads=1,0",
            "--project=" + str(package / "hil"), str(package / "hil/calibration_quality_analysis.jl"),
            str(output), str(evidence)], capture_output=True, text=True,
            timeout=recipe["stage_timeout_seconds"], env={**os.environ, "OPENBLAS_NUM_THREADS": "1"})
        (evidence / "analysis.stdout").write_text(result.stdout)
        (evidence / "analysis.stderr").write_text(result.stderr)
        record["analysis_wall_ns"] = time.perf_counter_ns() - analysis_started
        result.check_returncode()
        check_inputs()
        products, report_sha = analysis_products(output, evidence, recipe, plan)
        record["artifacts"] = products
        record["analysis_sha256"] = report_sha
        record["phase"] = "complete-candidate"
    except BaseException as error:
        record["phase"] = "failed-candidate"
        record["failure"] = repr(error)
        raise
    finally:
        record["timing_ns"] = {"total_campaign": time.perf_counter_ns() - started}
        deploy.atomic_record(output / "quality-result.json", record)
    return output / "quality-result.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("base-package", "output", "recipe", "aoc-source", "rtc-binary",
                   "calibration-binary", "runtime", "reference-candidate"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--julia", default="julia")
    arguments = parser.parse_args(argv)
    if arguments.pipewire_prefix.resolve() != Path("/opt/pipewireao"):
        parser.error("this campaign currently qualifies only /opt/pipewireao")
    print(campaign(arguments))


if __name__ == "__main__":
    main()
