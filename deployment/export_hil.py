#!/usr/bin/env python3
"""Attach a held AOS plant to an installed complete-frame scientific profile."""

from __future__ import annotations

import argparse
import copy
from dataclasses import asdict
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tempfile
import tomllib

import deploy
import export as science


ROOT = Path(__file__).resolve().parent
PACKAGE_UUIDS = {
    "AdaptiveOpticsCalibration": "3c8b5851-926e-4ebb-af30-f8544b98d45f",
    "AdaptiveOpticsSim": "002fb5eb-ad68-44a0-adbe-b299bfc2febc",
    "AdaptiveOpticsSimPipeWireHIL": "355e2bce-7765-4934-ac1c-873e1c98ec3d",
    "REVOLTClassicSim": "c09822aa-3d1e-4a1e-903c-d4d0f13badd1",
    "REVOLTCopperSim": "1e096dfd-8d59-466f-967d-e58cf577fca9",
}

# The automatic Classic campaign's existing packed wire contracts. Its result
# contains hashes rather than typed descriptors; these extents come from the
# maintained Classic acquisition and reduction contracts, not inferred files.
MEASURED_ARTIFACTS = {
    "measured-background.f32le": ("F32_LE", (352, 352), "ADC"),
    "measured-reference-slopes.f32le": ("F32_LE", (188, 2), "detector coordinate"),
    "measured-active.u8": ("Bool", (188,), "eligible ROI"),
    "measured-dark-variance.f64le": ("F64_LE", (352, 352), "ADC squared"),
    "measured-interaction-matrix.f32le": ("F32_LE", (376, 277), "detector coordinate / micrometre OPD"),
}


def campaign_file(root: Path, relative: str, maximum: int) -> Path:
    """Admit bounded ordinary files without following any input symlink."""
    path = root / relative
    if (Path(relative).is_absolute() or ".." in Path(relative).parts or
            any(parent.is_symlink() for parent in (path, *path.parents)) or
            not path.is_file() or path.stat().st_size > maximum):
        raise ValueError(f"missing, symlinked or oversized calibration input: {path}")
    return path


def campaign_json(root: Path, relative: str) -> dict:
    # Existing final campaign records are about 150 KiB. Two MiB admits the
    # bounded four-stage protocol records without loading arbitrary JSON data.
    path = campaign_file(root, relative, 2 * 1024 * 1024)

    def invalid_constant(value):
        raise ValueError(f"nonfinite calibration JSON constant: {value}")

    def finite_float(value):
        converted = float(value)
        if not math.isfinite(converted):
            raise ValueError("nonfinite calibration JSON number")
        return converted

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate calibration JSON field: {key}")
            result[key] = value
        return result

    value = json.loads(path.read_bytes(), parse_constant=invalid_constant, parse_float=finite_float, object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError(f"calibration record requires an object: {relative}")
    return value


def finite_payload(path: Path, element: str, shape: tuple) -> bytes:
    data = path.read_bytes()
    width = {"Bool": 1, "F32_LE": 4, "F64_LE": 8, "U32_LE": 4}[element]
    if len(data) != math.prod(shape) * width:
        raise ValueError(f"wrong calibration payload shape: {path.name}")
    if element == "Bool":
        if any(value > 1 for value in data) or not any(data):
            raise ValueError("active mask requires 188 Boolean entries and an observable ROI")
    elif element in ("F32_LE", "F64_LE"):
        code = "<f" if element == "F32_LE" else "<d"
        if not all(math.isfinite(value[0]) for value in struct.iter_unpack(code, data)):
            raise ValueError(f"nonfinite calibration payload: {path.name}")
    return data


def classic_bindings(provenance: dict) -> dict:
    """Resolve one canonical descriptor per parameter or construction field."""
    expected = {item.name: asdict(item) for item in science.classic_parameters()}
    bindings = {}
    for item in provenance["parameters"] + provenance.get("construction_parameters", []):
        name = item["name"]
        if name in bindings or any(value["endpoint"] == item["endpoint"] for value in bindings.values()):
            raise ValueError("duplicate Classic calibration parameter bindings")
        if name in expected:
            canonical = expected[name]
            if (any(item.get(key) != canonical[key] for key in ("file", "endpoint", "element_type", "schema")) or
                    tuple(item.get("shape", [])) != tuple(canonical["shape"]) or item.get("layout", "ROW_MAJOR") != "ROW_MAJOR"):
                raise ValueError(f"incompatible Classic calibration descriptor: {name}")
        bindings[name] = item
    if not {"background", "reference-slopes", "active", "subaperture-origins", "coordinates", "thresholds"} <= bindings.keys():
        raise ValueError("missing Classic calibration bindings")
    if "system-flat" in bindings:
        raise ValueError("nonzero/system-flat command origins are not supported for measured offsets")
    if set(bindings) != set(expected):
        raise ValueError("measured offsets require the bounded Classic parameter set")
    return bindings


def classic_snapshot(package: Path, provenance: dict, prefix: Path) -> tuple[dict, dict, dict]:
    """Normalize only engine construction fields and cadence for comparison."""
    bindings = classic_bindings(provenance)
    graph_path = campaign_file(package, "graphs/graph.conf.in", 2 * 1024 * 1024)
    graph = deploy.decode(graph_path, prefix)
    nodes = graph["filter.graph"]["nodes"]
    if len({node["name"] for node in nodes}) != len(nodes):
        raise ValueError("duplicate Classic graph node names")
    selected = {}
    for label in ("pixel-calibration-u16-f32", "shack-hartmann-image-f32", "pdm-command-f32"):
        matches = [node for node in nodes if node.get("label") == label]
        if len(matches) != 1:
            raise ValueError(f"Classic requires one {label} node")
        selected[label] = matches[0]
        endpoint_node = {"pixel-calibration-u16-f32": "pixel-calibration", "shack-hartmann-image-f32": "shack-hartmann",
                         "pdm-command-f32": "pdm-command"}[label]
        if matches[0]["name"] != endpoint_node:
            raise ValueError("Classic parameter endpoint differs from graph node")
    if any("system-flat" in node["name"] or "system-flat" in node.get("label", "") for node in nodes):
        raise ValueError("system-flat command origins are not supported for measured offsets")
    wfs = selected["shack-hartmann-image-f32"]
    config = wfs["config"]
    origins = config.get("initial_subaperture_origins")
    if origins is None:
        binding = bindings["subaperture-origins"]
        path = campaign_file(package, "calibration/" + binding["file"], 1504)
        origins = [list(pair) for pair in struct.iter_unpack("<II", finite_payload(path, "U32_LE", (188, 2)))]
    if (len(origins) != 188 or any(len(pair) != 2 or any(type(x) is not int or x < 0 for x in pair) for pair in origins) or
            origins != provenance["prepared_profile"]["subaperture_origins"]):
        raise ValueError("Classic estimator origins differ from prepared profile")
    if any(row + 22 > 352 or column + 22 > 352 for row, column in origins):
        raise ValueError("Classic estimator ROI lies outside detector")
    if provenance["engine"] == "fgn":
        packed_origins = b"".join(struct.pack("<II", *pair) for pair in origins)
        if bindings["subaperture-origins"].get("sha256") != hashlib.sha256(packed_origins).hexdigest():
            raise ValueError("Classic construction origins hash differs from binding")
    if provenance["engine"] == "jfg":
        origin_path = campaign_file(package, "calibration/" + bindings["subaperture-origins"]["file"], 1504)
        binary_origins = [list(pair) for pair in struct.iter_unpack("<II", finite_payload(origin_path, "U32_LE", (188, 2)))]
        if origins != binary_origins:
            raise ValueError("Classic construction and startup origins differ")
    configured = config.get("active")
    if configured is not None:
        if len(configured) != 188 or not all(type(value) is bool for value in configured) or not any(configured):
            raise ValueError("invalid Classic construction active mask")
        active = bytes(configured)
        if provenance["engine"] == "fgn" and bindings["active"].get("sha256") != hashlib.sha256(active).hexdigest():
            raise ValueError("Classic construction mask hash differs from binding")
        if provenance["engine"] == "jfg":
            path = campaign_file(package, "calibration/" + bindings["active"]["file"], 188)
            if finite_payload(path, "Bool", (188,)) != active:
                raise ValueError("Classic construction and startup masks differ")
    else:
        binding = bindings["active"]
        active = finite_payload(campaign_file(package, "calibration/" + binding["file"], 188), "Bool", (188,))
    snapshot = {"subaperture_origins": origins}
    for label, node in selected.items():
        snapshot[label] = {key: value for key, value in node["config"].items()
                           if key not in ("rate", "active", "initial_subaperture_origins")}
    geometry = snapshot["shack-hartmann-image-f32"]
    if any(geometry.get(key) != value for key, value in {
            "image_rows": 352, "image_columns": 352, "subaperture_count": 188,
            "subaperture_rows": 22, "subaperture_columns": 22}.items()):
        raise ValueError("incompatible Classic estimator geometry")
    for name in ("coordinates", "thresholds"):
        binding = bindings[name]
        path = campaign_file(package, "calibration/" + binding["file"], 4096)
        finite_payload(path, binding["element_type"], tuple(binding["shape"]))
        snapshot[name + "_sha256"] = science.sha256(path)
    return snapshot, graph, bindings


def validate_startup_bindings(package: Path, specification: dict, provenance: dict, graph: dict, bindings: dict,
                              owner_role: str = "julia", graph_relative: str = "graphs/graph.conf.in") -> None:
    """Reject conflicting startup arguments before any output is published."""
    if provenance["engine"] == "fgn":
        text = (package / graph_relative).read_text()
        for name in ("background", "reference-slopes", "coordinates", "thresholds"):
            binding = bindings[name]
            key = "pipewireao.startup-parameter." + binding["endpoint"]
            if (text.count(key) != 1 or graph.get(key) != "@PACKAGE@/calibration/" + binding["file"]):
                raise ValueError(f"invalid FGN startup binding: {name}")
        if "pipewireao.startup-parameter." + bindings["active"]["endpoint"] in text:
            raise ValueError("FGN active selection must use its construction field")
    elif provenance["engine"] == "jfg":
        owners = [owner for owner in specification["owners"] if owner["role"] == owner_role]
        if len(owners) != 1:
            raise ValueError("JFG requires one science owner")
        argv = owners[0]["argv"]
        supplied = {}
        for index, argument in enumerate(argv):
            if argument.startswith("--parameter="):
                raise ValueError("unsupported JFG parameter spelling")
            if argument == "--parameter":
                values = argv[index + 1:index + 5]
                if len(values) != 4 or values[0] in supplied:
                    raise ValueError("duplicate or incomplete JFG startup binding")
                supplied[values[0]] = values[1:]
        for name in ("background", "reference-slopes", "coordinates", "thresholds", "active", "subaperture-origins"):
            binding = bindings[name]
            expected = [science.JULIA_TYPES[binding["element_type"]], ",".join(map(str, binding["shape"])),
                        "@PACKAGE@/calibration/" + binding["file"]]
            if supplied.get(name) != expected:
                raise ValueError(f"invalid JFG startup binding: {name}")
    else:
        raise ValueError("measured offsets require Classic FGN or JFG")


def zero_reference(value) -> bool:
    return (isinstance(value, list) and len(value) == 277 and
            all(type(x) in (int, float) and math.isfinite(x) and x == 0 for x in value))


def operational_calibration(package: Path, specification: dict, provenance: dict,
                            prefix: Path, campaign: Path) -> dict:
    """Preserve measured offsets; this does not select or accept a reconstructor."""
    # The campaign imports this exporter when preparing stages. Defer the
    # import so its maintained producer validators are available after loading.
    import calibration_campaign

    if provenance["profile"] != "classic" or provenance["engine"] not in ("fgn", "jfg"):
        raise ValueError("measured offsets currently require Classic CPU FGN/JFG")
    campaign = campaign.absolute()
    result = campaign_json(campaign, "campaign-result.json")
    recipe = calibration_campaign.validate_recipe(campaign_json(campaign, "recipe.json"))
    if (type(result.get("version")) is not int or result["version"] != 1 or
            result.get("phase") != "complete-candidate" or result.get("failure") or
            set(result.get("stages", {})) != {"dark", "training", "qualification", "interaction"} or
            set(result.get("artifacts", {})) != set(MEASURED_ARTIFACTS)):
        raise ValueError("operational calibration requires a complete version-1 candidate campaign")
    if not zero_reference(recipe["reference"]):
        raise ValueError("measured offsets support only an actual zero 277-command reference")
    payloads = {}
    artifacts = {}
    for name, (element, shape, units) in MEASURED_ARTIFACTS.items():
        path = campaign_file(campaign, name, 1024 * 1024)
        payloads[name] = finite_payload(path, element, shape)
        if science.sha256(path) != result["artifacts"][name]:
            raise ValueError(f"measured calibration hash differs: {name}")
        artifacts[name] = {"sha256": result["artifacts"][name], "shape": list(shape),
                           "element_type": element, "layout": "ROW_MAJOR", "units": units}
    target_snapshot, graph, bindings = classic_snapshot(package, provenance, prefix)
    validate_startup_bindings(package, specification, provenance, graph, bindings)
    target_model = tomllib.loads((package / "hil/plant.toml").read_text())
    target_nodes = {node["name"]: node for node in target_model["nodes"]}
    target_detector = target_nodes["detector"]["config"]
    calibration_campaign.validate_detector_rail(target_detector, recipe)
    sources = {}
    differences = []
    measured_mask = payloads["measured-active.u8"]
    for stage, record in result["stages"].items():
        disk_record = campaign_json(campaign, stage + "-evidence/stage-result.json")
        if (disk_record != record or record.get("stage") != stage or record.get("failure") or record.get("recovery_failure") or
                any(record.get(key) is not True for key in ("restoration_confirmed", "release_confirmed", "shutdown_confirmed")) or
                type(record.get("launcher_exit")) is not int or record["launcher_exit"] != 0):
            raise ValueError(f"campaign stage lifecycle is not confirmed: {stage}")
        startup = record["startup_report"]
        model_path = campaign_file(campaign, stage + "-package/hil/plant.toml", 1024 * 1024)
        source_model = tomllib.loads(model_path.read_text())
        source_nodes = {node["name"]: node for node in source_model["nodes"]}
        detector = source_nodes["detector"]["config"]
        calibration_campaign.validate_detector_rail(detector, recipe)
        if (type(startup.get("version")) is not int or startup["version"] != 1 or startup.get("profile") != "classic" or startup.get("backend") != "cpu" or
                startup.get("failure") or startup.get("calibration_stage") != stage or
                startup.get("illumination") != ("dark" if stage == "dark" else "lamp") or
                startup.get("command_transport_units") != "micrometre OPD" or startup.get("plant_command_units") != "metre OPD" or
                startup.get("graph_sha256") != science.sha256(model_path) or startup.get("detector_config") != detector or
                detector.get("photon_noise") is not True or detector.get("readout_noise") is not True or
                detector.get("rng_seed") != recipe["seeds"][stage] or
                source_nodes["shwfs"]["config"]["source_magnitude"] != recipe["lamp_magnitude"]):
            raise ValueError(f"campaign detector/illumination snapshot differs: {stage}")
        if ({k: v for k, v in detector.items() if k != "rng_seed"} !=
                {k: v for k, v in target_detector.items() if k != "rng_seed"}):
            raise ValueError("target detector/exposure configuration differs from measured source")
        # Normal science uses atmosphere illumination. The campaign uses a lamp
        # or dark boundary; only declared cadence, seed and magnitude may differ
        # in the model. No optical geometry or detector setting changes silently.
        source_comparable = copy.deepcopy(source_model)
        target_comparable = copy.deepcopy(target_model)
        changes = {}
        for node, field in (("detector", "rng_seed"), ("atmosphere", "atmosphere_step"), ("shwfs", "source_magnitude")):
            source_config = next(n for n in source_comparable["nodes"] if n["name"] == node)["config"]
            target_config = next(n for n in target_comparable["nodes"] if n["name"] == node)["config"]
            changes[node + "." + field] = {"source": source_config.pop(field), "target": target_config.pop(field)}
        if source_comparable != target_comparable:
            raise ValueError("target plant geometry/physics differs from measured source")
        base_relative = stage + "-base"
        source_package = campaign / base_relative
        source_provenance = campaign_json(campaign, base_relative + "/provenance.json")
        source_deployment = campaign_json(campaign, base_relative + "/deployment.conf")
        if (source_provenance.get("profile") != "classic" or source_provenance.get("mode") != "frame" or
                source_provenance.get("engine") not in ("fgn", "jfg") or source_provenance.get("hil", {}).get("backend") != "cpu" or
                source_provenance.get("campaign_stage_inputs", {}).get("recipe") != recipe):
            raise ValueError(f"incompatible source campaign package: {stage}")
        snapshot, source_graph, source_bindings = classic_snapshot(source_package, source_provenance, prefix)
        validate_startup_bindings(source_package, source_deployment, source_provenance, source_graph, source_bindings)
        if snapshot != target_snapshot:
            raise ValueError("target detector/ROI coordinates or thresholds differ from measured source")
        for relative in ("provenance.json", "graphs/graph.conf.in", "calibration/" + source_bindings["coordinates"]["file"],
                         "calibration/" + source_bindings["thresholds"]["file"]):
            path = campaign_file(source_package, relative, 2 * 1024 * 1024)
            if source_deployment["artifacts"].get(relative) != science.sha256(path):
                raise ValueError(f"stale source package binding: {stage}/{relative}")
        expected_active = (bytes(recipe["candidate_mask"]) if stage in ("dark", "training") else measured_mask)
        wfs = next(node for node in source_graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32")
        actual_active = (bytes(wfs["config"]["active"]) if "active" in wfs["config"] else
                         finite_payload(campaign_file(source_package, "calibration/" + source_bindings["active"]["file"], 188), "Bool", (188,)))
        if (actual_active != expected_active or startup.get("wfs_active") != list(map(bool, expected_active)) or
                startup.get("wfs_active_sha256") != hashlib.sha256(expected_active).hexdigest()):
            raise ValueError(f"source active mask differs: {stage}")
        deployed_relative = stage + "-package"
        deployed_provenance = campaign_json(campaign, deployed_relative + "/provenance.json")
        deployed_specification = campaign_json(campaign, deployed_relative + "/deployment.conf")
        if (deployed_provenance.get("source_provenance_sha256") != science.sha256(source_package / "provenance.json") or
                deployed_provenance.get("source_graph_sha256") != science.sha256(source_package / "graphs/graph.conf.in") or
                deployed_provenance.get("source_deployment_sha256") != science.sha256(source_package / "deployment.conf") or
                deployed_provenance.get("source_provenance") != source_provenance):
            raise ValueError(f"deployed campaign source identity differs: {stage}")
        for relative in ("hil/plant.toml", "graphs/wfs.conf.in", "calibration/wfs-active.u8"):
            path = campaign_file(campaign / deployed_relative, relative, 2 * 1024 * 1024)
            if deployed_specification["artifacts"].get(relative) != science.sha256(path):
                raise ValueError(f"stale deployed campaign binding: {stage}/{relative}")
        deployed_wfs = deploy.decode(campaign / deployed_relative / "graphs/wfs.conf.in", prefix)
        # The validator reads the graph text to detect duplicate native fields.
        # For a split calibration package its WFS graph has the existing name.
        validate_startup_bindings(campaign / deployed_relative, deployed_specification, source_provenance,
                                  deployed_wfs, source_bindings, owner_role="julia-wfs", graph_relative="graphs/wfs.conf.in")
        source_wfs_nodes = [node for node in source_graph["filter.graph"]["nodes"]
                            if node["label"] in ("pixel-calibration-u16-f32", "shack-hartmann-image-f32")]
        if (deployed_wfs["filter.graph"]["nodes"] != source_wfs_nodes or
                (campaign / deployed_relative / "calibration/wfs-active.u8").read_bytes() != expected_active):
            raise ValueError(f"deployed estimator differs from source package: {stage}")
        for name in ("background", "reference-slopes", "coordinates", "thresholds"):
            relative = "calibration/" + source_bindings[name]["file"]
            path = campaign_file(campaign / deployed_relative, relative, 495616)
            if (path.read_bytes() != (source_package / relative).read_bytes() or
                    deployed_specification["artifacts"].get(relative) != science.sha256(path)):
                raise ValueError(f"deployed estimator parameter differs: {stage}/{name}")
        for name, expected in (("background", bytes(495616) if stage == "dark" else payloads["measured-background.f32le"]),
                               ("reference-slopes", bytes(1504) if stage in ("dark", "training") else payloads["measured-reference-slopes.f32le"])):
            path = campaign_file(source_package, "calibration/" + source_bindings[name]["file"], 495616)
            if path.read_bytes() != expected or source_deployment["artifacts"].get("calibration/" + path.name) != science.sha256(path):
                raise ValueError(f"source startup offsets differ: {stage}/{name}")
        if stage != "interaction":
            for action, kind in (("adopt", "adopted"), ("restore", "restored")):
                requests = [entry for entry in record["requests"] if entry["request"]["action"]["kind"] == action]
                if len(requests) != 1:
                    raise ValueError("missing actual calibration reference command")
                entry = requests[0]
                request, reply = entry["request"], entry["reply"]
                completion = reply["result"]
                if (any(type(request.get(key)) is not int or type(reply.get(key)) is not int or request.get(key) != reply.get(key)
                        for key in ("version", "run", "serial")) or request["version"] != 1 or
                        not zero_reference(request["action"].get("figure")) or completion.get("kind") != kind or
                        completion.get("clipped") is not False or not zero_reference(completion.get("figure"))):
                    raise ValueError("actual calibration reference is nonzero, clipped or unconfirmed")
        sources[stage] = {"deployment_sha256": science.sha256(source_package / "deployment.conf"),
                          "provenance_sha256": science.sha256(source_package / "provenance.json"),
                          "graph_sha256": science.sha256(source_package / "graphs/graph.conf.in"),
                          "model_sha256": science.sha256(model_path), "detector_config": detector,
                          "illumination": startup["illumination"],
                          "stage_result_sha256": science.sha256(campaign / (stage + "-evidence/stage-result.json")),
                          "analysis_sha256": science.sha256(campaign_file(campaign, stage + "-evidence/analysis.json", 2 * 1024 * 1024)),
                          "deployed_wfs_sha256": science.sha256(campaign / deployed_relative / "graphs/wfs.conf.in"),
                          "deployed_deployment_sha256": science.sha256(campaign / deployed_relative / "deployment.conf")}
        differences.append({"stage": stage, "settings": changes, "illumination": {
            "source": startup["illumination"], "target": "atmosphere"}})
    plan = campaign_json(campaign, "interaction-plan.json")
    if type(plan.get("version")) is not int or plan["version"] != 1 or not zero_reference(plan.get("reference")) or plan.get("measurements") != 376:
        raise ValueError("interaction plan does not bind the zero reference")
    dark = campaign_json(campaign, "dark-evidence/analysis.json")
    training = campaign_json(campaign, "training-evidence/analysis.json")
    qualification = campaign_json(campaign, "qualification-evidence/analysis.json")
    interaction = campaign_json(campaign, "interaction-evidence/analysis.json")
    if (dark.get("status") != "valid" or dark.get("units") != "ADC" or
            dark.get("background_sha256") != artifacts["measured-background.f32le"]["sha256"] or
            dark.get("variance_sha256") != artifacts["measured-dark-variance.f64le"]["sha256"] or
            training.get("status") != "valid" or training.get("reference_sha256") != artifacts["measured-reference-slopes.f32le"]["sha256"] or
            training.get("mask_sha256") != artifacts["measured-active.u8"]["sha256"] or training.get("eligible") != list(map(bool, measured_mask)) or
            qualification.get("status") != "qualified-frozen-reference" or qualification.get("mask_reselection") is not False or
            interaction.get("status") != "valid-structured-estimate" or interaction.get("shape") != [376, 277] or
            interaction.get("layout") != "ROW_MAJOR" or interaction.get("sha256") != artifacts["measured-interaction-matrix.f32le"]["sha256"]):
        raise ValueError("measured artifact analysis identity/shape/layout differs")
    original = {str(p.relative_to(package)): science.sha256(p) for p in sorted(package.glob("calibration/*")) if p.is_file()}
    original_graph = science.sha256(package / "graphs/graph.conf.in")
    for name, source in (("background", "measured-background.f32le"), ("reference-slopes", "measured-reference-slopes.f32le"),
                         ("active", "measured-active.u8")):
        binding = bindings[name]
        (package / "calibration" / binding["file"]).write_bytes(payloads[source])
        binding["sha256"] = artifacts[source]["sha256"]
    wfs = next(node for node in graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32")
    if provenance["engine"] == "fgn" or "active" in wfs["config"]:
        import export_calibration
        wfs["config"]["active"] = list(map(bool, measured_mask))
        (package / "graphs/graph.conf.in").write_text(export_calibration.spa_json(graph) + "\n")
    final_snapshot, final_graph, final_bindings = classic_snapshot(package, provenance, prefix)
    validate_startup_bindings(package, specification, provenance, final_graph, final_bindings)
    if final_snapshot != target_snapshot:
        raise ValueError("measured offset adoption changed estimator settings")
    return {"mode": "operational-measured-offsets", "source": str(campaign),
            "campaign_result_sha256": science.sha256(campaign / "campaign-result.json"),
            "recipe_sha256": science.sha256(campaign / "recipe.json"),
            "interaction_plan_sha256": science.sha256(campaign / "interaction-plan.json"),
            "artifacts": artifacts, "source_stages": sources, "target_differences": differences,
            "reference_command": recipe["reference"], "reference_units": "micrometre OPD",
            "runtime_command_origin": "zero physical reference; no additional system-flat; controller state starts at zero",
            "original_base_artifact_sha256": original, "original_target_graph_sha256": original_graph,
            "target_estimator": target_snapshot, "target_model_sha256": science.sha256(package / "hil/plant.toml"),
            "target_graph_sha256": science.sha256(package / "graphs/graph.conf.in"),
            "target_bindings": {name: {**bindings[name], "path": "calibration/" + bindings[name]["file"]}
                                for name in ("background", "reference-slopes", "active")},
            "reconstructor_acceptance": "not established; reconstructor and coordinate maps retained from base",
            "scientific_correction": "not established by offset preservation"}


def plant_configuration(path: Path, rate: int) -> tuple[str, int]:
    """Change only declared model cadence, retaining instrument exposure/physics."""
    text = path.read_text()
    graph = tomllib.loads(text)
    atmosphere = next(node for node in graph["nodes"] if node["name"] == "atmosphere")
    detector = next(node for node in graph["nodes"] if node["name"] == "detector")
    exposure = round(detector["config"]["exposure_duration_s"] * 1_000_000_000)
    period = round(1_000_000_000 / rate)
    if exposure <= 0 or exposure > period:
        raise ValueError("instrument exposure must be positive and no longer than model period")
    if atmosphere["config"]["atmosphere_step"] <= 0:
        raise ValueError("instrument model has invalid atmosphere step")
    text, count = re.subn(r"(?m)^atmosphere_step\s*=\s*[^\n]+$",
                         f"atmosphere_step = {period / 1_000_000_000:.12g}", text)
    if count != 1:
        raise ValueError("expected one instrument atmosphere step")
    return text, exposure


def hil_session(base: dict) -> dict:
    value = copy.deepcopy(base)
    if value.get("execution") != "complete-frame":
        raise ValueError("HIL currently requires complete-frame science")
    source = value["sources"][0]
    sink = value["sinks"][0]
    source_name, source_port = source["node.name"], source["ports"][0]["name"]
    sink_name, sink_port = sink["node.name"], sink["ports"][0]["name"]
    source["ports"][0]["name"] = "output_1"
    sink["ports"][0]["name"] = "input_1"
    value["sources"][0] = {"ownership": "external", "node.name": "simulator-wfs",
                           "ports": source["ports"]}
    value["sinks"][0] = {"ownership": "external", "node.name": "simulator-command",
                         "ports": sink["ports"]}
    for link in value["links"]:
        if link["output"] == f"{source_name}:{source_port}":
            link["output"] = "simulator-wfs:output_1"
            link["passive"] = True
        if link["input"] == f"{sink_name}:{sink_port}":
            link["input"] = "simulator-command:input_1"
    for group in value["execution-groups"]:
        group["nodes"] = [name for name in group["nodes"] if name not in (source_name, sink_name)]
    return value


def copy_package(source: Path, destination: Path) -> None:
    if not (source / "Project.toml").is_file():
        raise ValueError(f"missing simulator package: {source}")
    destination.mkdir(parents=True)
    for name in ("Project.toml", "src", "ext", "graphs", "LICENSE", "LICENSE.md"):
        entry = source / name
        if entry.is_dir():
            shutil.copytree(entry, destination / name, symlinks=False)
        elif entry.is_file():
            shutil.copy2(entry, destination / name)


def hil_core(base: dict) -> dict:
    """Remove recorded device loops from the simulated device composition."""
    value = copy.deepcopy(base)
    properties = value["context.properties"]
    loops = properties["context.data-loops"]
    if {loop["loop.name"] for loop in loops} != {"rtc-data-loop", "source-loop", "sink-loop"}:
        raise ValueError("base core requires the maintained RTC, source and sink loops")
    properties["context.data-loops"] = [loop for loop in loops if loop["loop.name"] == "rtc-data-loop"]
    return value


def environment(package: Path, plant: str, backend: str) -> None:
    project = tomllib.loads((ROOT / "hil/Project.toml").read_text())
    dependencies = dict(project["deps"])
    for name in ("REVOLTClassicSim", "REVOLTCopperSim"):
        dependencies.pop(name, None)
    dependencies.update({name: PACKAGE_UUIDS[name] for name in
                         ("AdaptiveOpticsCalibration", "AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL", plant)})
    compat = dict(project.get("compat", {}))
    for name in ("REVOLTClassicSim", "REVOLTCopperSim"):
        if name != plant:
            compat.pop(name, None)
    compat["AdaptiveOpticsCalibration"] = "0.17"
    if backend == "cuda":
        dependencies["CUDA"] = "052768ef-5323-5732-b1bb-66c8b64840ba"
        compat["CUDA"] = "6"
    elif backend == "amdgpu":
        dependencies["AMDGPU"] = "21141c5a-9bdb-4563-92ae-f87d6854732e"
        compat["AMDGPU"] = "2.7"
    text = "[deps]\n" + "".join(f'{name} = {json.dumps(uuid)}\n' for name, uuid in sorted(dependencies.items()))
    text += "\n[sources]\n" + "".join(f'{name} = {{path = "packages/{name}"}}\n' for name in
                                       ("AdaptiveOpticsCalibration", "AdaptiveOpticsSim", "AdaptiveOpticsSimPipeWireHIL",
                                        "PipeWireAO", "FilterGraphAlgorithms", plant))
    text += "\n[compat]\n" + "".join(f'{name} = {json.dumps(version)}\n' for name, version in sorted(compat.items()))
    (package / "hil/Project.toml").write_text(text)


def julia_owner_environment(package: Path) -> None:
    """Use the same installed transport package for both external owners."""
    project = package / "jfg/deployment/Project.toml"
    text = project.read_text()
    definition = tomllib.loads(text)
    if "PipeWireAO" in definition.get("sources", {}):
        raise ValueError("base Julia owner already overrides PipeWireAO; inspect that source before export")
    if text.count("[sources]\n") != 1:
        raise ValueError("base Julia owner requires one sources table")
    project.write_text(text.replace(
        "[sources]\n", '[sources]\nPipeWireAO = {path = "../../hil/packages/PipeWireAO"}\n', 1,
    ))


def simulator_environment(backend: str) -> dict[str, str]:
    value = {"OPENBLAS_NUM_THREADS": "1", "JULIA_NUM_THREADS": "1,0"}
    if backend == "amdgpu":
        # ROCr otherwise ignores the inherited deployment mask for helpers.
        value["HSA_OVERRIDE_CPU_AFFINITY_DEBUG"] = "0"
    return value


def calibration_inputs(package: Path, provenance: dict, prefix: Path) -> dict:
    """Describe the existing RTC estimator without importing instrument offsets."""
    instrument = provenance["profile"]
    parameters = {item["name"]: item for item in provenance["parameters"]}

    def artifact(name: str, units: str) -> dict:
        item = parameters[name]
        return {"path": "../calibration/" + item["file"], "shape": list(item["shape"]),
                "element_type": item["element_type"], "layout": "ROW_MAJOR", "units": units}

    background = (artifact("background", "ADC") if instrument == "classic" else
                  {"path": "../calibration/parameter-background.f32", "shape": [64, 64],
                   "element_type": "F32_LE", "layout": "ROW_MAJOR", "units": "ADC"})
    result = {"version": 1, "profile": instrument, "artifacts": {"background": background}}
    if instrument == "copper":
        result["artifacts"]["system_flat"] = artifact("system-flat", "micrometre OPD")
        return result
    graph = deploy.decode(package / "graphs/graph.conf.in", prefix)["filter.graph"]
    nodes = [node for node in graph["nodes"] if node.get("label") == "shack-hartmann-image-f32"]
    if len(nodes) != 1:
        raise ValueError("Classic calibration requires one complete-image Shack-Hartmann estimator")
    config = nodes[0]["config"]
    active = config.get("active")
    if active is None:
        values = (package / "calibration" / parameters["active"]["file"]).read_bytes()
        if any(value > 1 for value in values):
            raise ValueError("Classic active mask requires zero/one bytes")
        active = [bool(value) for value in values]
    origins = config.get("initial_subaperture_origins")
    if origins is None:
        path = package / "calibration" / parameters["subaperture-origins"]["file"]
        origins = [list(pair) for pair in struct.iter_unpack("<II", path.read_bytes())]
    if origins != provenance["prepared_profile"]["subaperture_origins"]:
        raise ValueError("Classic estimator origins differ from prepared profile")
    result["artifacts"]["reference_slopes"] = artifact("reference-slopes", "detector coordinate")
    result["artifacts"]["optical_flat"] = {
        "path": "../calibration/simulated-optical-flat.f32le", "shape": background["shape"],
        "element_type": "F32_LE", "layout": "ROW_MAJOR", "units": "ADC"}
    result["shack_hartmann"] = {
        "detector_height": config["image_rows"], "detector_width": config["image_columns"],
        "subaperture_height": config["subaperture_rows"], "subaperture_width": config["subaperture_columns"],
        "subaperture_origins": origins,
        "coordinates": artifact("coordinates", "detector coordinate"),
        "thresholds": artifact("thresholds", "ADC"), "active": active,
    }
    return result


def adopt_simulated_calibration(package: Path, specification: dict, provenance: dict,
                               inputs: dict, result: dict) -> None:
    """Validate generated offsets and bind the same arrays in either graph owner."""
    if (result.get("version") != 1 or result.get("profile") != provenance["profile"] or
            result.get("model_sha256") != science.sha256(package / "hil/plant.toml")):
        raise ValueError("simulated calibration does not describe the installed plant")
    if set(result.get("artifacts", {})) != set(inputs["artifacts"]):
        raise ValueError("simulated calibration artifact set differs from the request")
    for name, descriptor in inputs["artifacts"].items():
        actual = result["artifacts"][name]
        if any(actual.get(key) != value for key, value in descriptor.items()):
            raise ValueError(f"simulated calibration descriptor differs for {name}")
        path = (package / "hil" / descriptor["path"]).resolve()
        if path.parent != (package / "calibration").resolve():
            raise ValueError("simulated calibration must remain in package calibration directory")
        parameter = science.Parameter(name, "", descriptor["element_type"], tuple(descriptor["shape"]), path.name)
        science.validate_parameter(path.parent, parameter)
        if science.sha256(path) != actual.get("sha256"):
            raise ValueError(f"simulated calibration hash differs for {name}")
    if provenance["profile"] == "copper":
        parameter = science.Parameter("background", "calibrate:background", "F32_LE", (64, 64),
                                      "parameter-background.f32")
        if any(item["name"] == "background" for item in provenance["parameters"]):
            raise ValueError("Copper base has a background parameter; inspect its initialization")
        provenance["parameters"].append(asdict(parameter))
        if provenance["engine"] == "fgn":
            graph = package / "graphs/graph.conf.in"
            text = graph.read_text()
            if text.count("    filter.graph =") != 1:
                raise ValueError("Copper graph requires one filter.graph declaration")
            initialization = ('    "pipewireao.startup-parameter.calibrate:background" = '
                              '"@PACKAGE@/calibration/parameter-background.f32"\n')
            graph.write_text(text.replace("    filter.graph =", initialization + "    filter.graph =", 1))
        else:
            graph = package / "graphs/graph.conf.in"
            text = graph.read_text()
            declaration = '"calibrate:raw"\n'
            if text.count(declaration) != 1:
                raise ValueError("Copper Julia graph requires one raw input declaration")
            graph.write_text(text.replace(declaration,
                                          declaration + '            "calibrate:background"\n', 1))
            owner = next(owner for owner in specification["owners"] if owner["role"] == "julia")
            owner["argv"] += ["--parameter", "background", "Float32", "64,64",
                              "@PACKAGE@/calibration/parameter-background.f32"]


def simulated_calibration(package: Path, specification: dict, provenance: dict,
                          prefix: Path, executable: str, dark_frames: int) -> dict:
    inputs = calibration_inputs(package, provenance, prefix)
    input_path, result_path = package / "hil/calibration-input.json", package / "hil/calibration-result.json"
    science.write_json(input_path, inputs)
    original = {name: science.sha256(package / "hil" / item["path"])
                if (package / "hil" / item["path"]).is_file() else None
                for name, item in inputs["artifacts"].items()}
    subprocess.run([executable, "--startup-file=no", "--threads=1,0", f"--project={package / 'hil'}",
                    str(package / "hil/calibrate_detector.jl"), "--graph", str(package / "hil/plant.toml"),
                    "--profile", provenance["profile"], "--specification", str(input_path),
                    "--output", str(result_path), "--dark-frames", str(dark_frames)],
                   check=True, timeout=1800)
    result = json.loads(result_path.read_text())
    if result.get("dark_frames") != dark_frames:
        raise ValueError("simulated calibration dark count differs from the request")
    adopt_simulated_calibration(package, specification, provenance, inputs, result)
    return {"mode": "historical-simulated-offset-fixture", "source": "simulated detector and zero-command plant", "report": "hil/calibration-result.json",
            "report_sha256": science.sha256(result_path), "replaced_artifact_sha256": original,
            "artifacts": result["artifacts"],
            "retained_calibration": "recorded reconstructor and projections; hybrid, convergence unqualified"}


def export_hil(args) -> Path:
    if args.output.is_symlink():
        raise ValueError("export output must be new")
    output = args.output.resolve()
    if output.exists():
        raise ValueError("export output must be new")
    if not 1 <= args.rate_hz <= 500 or not 1 <= args.frames <= 256:
        raise ValueError("rate must be 1..500 Hz and finite batch 1..256 frames")
    if not 1 <= args.dark_frames <= 4096:
        raise ValueError("dark calibration must use 1..4096 exposures")
    base = args.base_package.resolve()
    specification = deploy.profile(base / "deployment.conf", args.pipewire_prefix)
    provenance = json.loads((base / "provenance.json").read_text())
    if provenance.get("mode") != "frame" or provenance.get("profile") not in ("classic", "copper"):
        raise ValueError("base must be a maintained Classic/Copper complete-frame package")
    if "hil" in provenance:
        raise ValueError("base must be a recorded-input package, not a previous HIL export")
    operational = getattr(args, "operational_calibration", None)
    if operational is not None and (provenance["profile"] != "classic" or args.backend != "cpu" or provenance["engine"] not in ("fgn", "jfg")):
        raise ValueError("operational measured offsets currently require Classic CPU FGN/JFG")
    if operational is not None:
        _, base_graph, base_bindings = classic_snapshot(base, provenance, args.pipewire_prefix)
        validate_startup_bindings(base, specification, provenance, base_graph, base_bindings)
        for name, binding in base_bindings.items():
            if provenance["engine"] == "fgn" and name in ("active", "subaperture-origins"):
                continue  # Native construction fields can have no retained file.
            path = campaign_file(base, "calibration/" + binding["file"], 2 * 1024 * 1024)
            finite_payload(path, binding["element_type"], tuple(binding["shape"]))
    instrument = provenance["profile"]
    plant = "REVOLTClassicSim" if instrument == "classic" else "REVOLTCopperSim"
    model_source = args.plant_root / "graphs" / f"revolt_{instrument}_hil_grid_gaussian.toml"
    model, exposure = plant_configuration(model_source, args.rate_hz)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rtc-hil-export-", dir=output.parent) as temporary:
        package = Path(temporary) / "package"
        shutil.copytree(base, package, ignore=shutil.ignore_patterns("__pycache__", "input.fits", "systemd"))
        # Installation adds an unhashed launcher; the new install owns its copy.
        for name in ("pipewireao-rtc-deploy", "placement.py", "pipewireao-rtc@.service.in"):
            (package / "bin" / name).unlink(missing_ok=True)
        session = hil_session(json.loads((package / "session.conf.in").read_text()))
        session["rate"] = f"{args.rate_hz}/1"
        for item in session["sources"] + session["graphs"] + session["sinks"]:
            for port in item["ports"]:
                if "rate" in port:
                    port["rate"] = session["rate"]
        science.write_json(package / "session.conf.in", session)
        for path in package.glob("graphs/*.conf.in"):
            text = re.sub(r"\brate\s*=\s*\[\s*\d+\s+1\s*\]", f"rate = [ {args.rate_hz} 1 ]", path.read_text())
            path.write_text(text)
        for owner in specification["owners"]:
            if "--rate" in owner["argv"]:
                owner["argv"][owner["argv"].index("--rate") + 1] = session["rate"]
        (package / "hil").mkdir()
        for path in (ROOT / "hil").glob("*.jl"):
            if not path.name.startswith("test_"):
                shutil.copy2(path, package / "hil" / path.name)
        for name, path in (("AdaptiveOpticsCalibration", args.aoc_root),
                           ("AdaptiveOpticsSim", args.aos_root),
                           ("AdaptiveOpticsSimPipeWireHIL", args.adapter_root),
                           ("PipeWireAO", args.pipewireao_jl_root),
                           ("FilterGraphAlgorithms", args.calibration_algorithms_root), (plant, args.plant_root)):
            copy_package(path.resolve(), package / "hil/packages" / name)
        (package / "hil/plant.toml").write_text(model)
        environment(package, plant, args.backend)
        if operational is not None:
            calibration = operational_calibration(package, specification, provenance, args.pipewire_prefix, operational)
        executable = str(Path(shutil.which("julia") or "missing-julia").resolve())
        subprocess.run([executable, "--startup-file=no", "--threads=1,0", f"--project={package / 'hil'}",
                        "-e", "using Pkg; Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)"], check=True, timeout=1800)
        if operational is None:
            calibration = simulated_calibration(package, specification, provenance, args.pipewire_prefix,
                                                executable, args.dark_frames)
        if args.backend != "cpu":
            backend_package = "CUDA" if args.backend == "cuda" else "AMDGPU"
            # Optional backend compilation belongs to package preparation, not
            # the source owner's bounded readiness/admission wait.
            subprocess.run([executable, "--startup-file=no", "--threads=1,0", f"--project={package / 'hil'}",
                            "-e", f"using Pkg; Pkg.precompile([{json.dumps(backend_package)}])"],
                           check=True, timeout=1800)
        if provenance["engine"] == "jfg":
            julia_owner_environment(package)
            subprocess.run([executable, "--startup-file=no", "--threads=1,0",
                            f"--project={package / 'jfg/deployment'}", "-e",
                            "using Pkg; Pkg.resolve(); Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)"],
                           check=True, timeout=1800)
        markers = {"prepared": "simulator.prepared", "connect": "simulator.connect", "connected": "simulator.connected",
                   "quit": "simulator.quit", "control-request": "simulator.control.request", "control-reply": "simulator.control.reply"}
        argv = [executable, "--startup-file=no", "--threads=1,0", "--project=@PACKAGE@/hil", "@PACKAGE@/hil/simulator.jl",
                "--profile", instrument, "--backend", args.backend, "--graph", "@PACKAGE@/hil/plant.toml",
                "--rate", str(args.rate_hz), "--exposure-ns", str(exposure), "--frames", str(args.frames),
                "--remote", "@REMOTE@", "--output", "@RUNTIME@/simulator-result.json"]
        for option, marker in (("--prepared-event", "prepared"), ("--connect-request", "connect"), ("--connect-reply", "connected"),
                               ("--quit-request", "quit"), ("--control-request", "control-request"), ("--control-reply", "control-reply")):
            argv += [option, "@RUNTIME@/" + markers[marker]]
        specification["owners"].append({"role": "simulator", "argv": argv,
                                         "environment": simulator_environment(args.backend), **markers})
        specification["source-owner"] = "simulator"
        specification["name"] = f"revolt-{instrument}-{provenance['engine']}-hil-{args.backend}"
        specification["placement"]["simulator"] = {"cpus": [6, 14], "leader-cpu": 6, "rt-priority": 0,
                                                       "threads": [], "locked-bytes": 0}
        # FITS and discard loops no longer exist in this external device pair.
        specification["placement"]["core"] = science.placement([2, 14], [2] if provenance["engine"] == "fgn" else [])
        core_path = package / specification["core"]
        science.write_json(core_path, hil_core(deploy.decode(core_path, args.pipewire_prefix)))
        specification["client"]["simulator"] = "client-simulator.conf.in"
        shutil.copy2(ROOT / "templates/client-simulator.conf.in", package / "client-simulator.conf.in")
        provenance["hil"] = {"backend": args.backend, "wall_rate_hz": args.rate_hz,
                              "model_period_ns": round(1_000_000_000 / args.rate_hz), "exposure_ns": exposure,
                              "frames": args.frames, "frame_encoding": "UInt16 ADC codes, row-major",
                              "command_unit": "micrometre OPD", "plant_command_scale": 1e-6,
                              "instrument_model": "provisional grid-Gaussian HSDM277",
                              "aos_revision": science.revision(args.aos_root), "plant_revision": science.revision(args.plant_root),
                              "adaptive_optics_calibration_revision": science.revision(args.aoc_root),
                              "adapter_revision": science.revision(args.adapter_root), "original_model_sha256": science.sha256(model_source),
                              "pipewireao_jl_revision": science.revision(args.pipewireao_jl_root),
                              "base_deployment_sha256": science.sha256(base / "deployment.conf"),
                              "base_provenance_sha256": science.sha256(base / "provenance.json"),
                              "base_graph_sha256": science.sha256(base / "graphs/graph.conf.in"),
                              "calibration_algorithms_revision": science.revision(args.calibration_algorithms_root),
                              ("operational_calibration" if operational is not None else "simulated_calibration"): calibration,
                              "scientific_convergence": "not established by deployment exchange"}
        provenance["runtime_requires"] = ["selected PipeWireAO prefix", "Julia resolved HIL environment", "selected simulator device"]
        science.write_json(package / "provenance.json", provenance)
        specification["artifacts"] = {str(path.relative_to(package)): science.sha256(path) for path in sorted(package.rglob("*"))
                                        if path.is_file() and path.name != "deployment.conf"}
        science.write_json(package / "deployment.conf", specification)
        deploy.profile(package / "deployment.conf", args.pipewire_prefix)
        package.rename(output)
    return output / "deployment.conf"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("output", "base-package", "aoc-root", "aos-root", "plant-root", "adapter-root", "pipewireao-jl-root",
                 "calibration-algorithms-root"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--backend", choices=("cpu", "cuda", "amdgpu"), default="cpu")
    parser.add_argument("--rate-hz", type=int, default=10)
    parser.add_argument("--frames", type=int, default=16)
    parser.add_argument("--dark-frames", type=int, default=256)
    parser.add_argument("--operational-calibration", type=Path,
                        help="preserve measured offsets from a completed Classic CPU candidate campaign directory")
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    return parser.parse_args(argv)


if __name__ == "__main__":
    try:
        print(export_hil(arguments()))
    except (OSError, ValueError, KeyError, TypeError, deploy.DeploymentError, subprocess.SubprocessError) as error:
        print(f"HIL export rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
