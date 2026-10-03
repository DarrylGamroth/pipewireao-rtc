#!/usr/bin/env python3
"""Export two ordinary full-frame graphs for explicit initial calibration.

The selected installed profile supplies the exact WFS processing and PDM
constraints. These are graph assets, not a runnable deployment or evidence of
operational acquisition. Existing offset provenance retains its original claim.
"""

from __future__ import annotations

import argparse
import copy
from dataclasses import asdict
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import deploy
import export as science


REQUESTED_SCHEMA = "org.calculon.ao.requested-pdm-command/1"
FEEDBACK_SCHEMA = "org.calculon.ao.pdm-constraint-feedback/1"


def spa_json(value, indent: int = 0) -> str:
    """Emit standard assignment syntax also accepted by the maintained JFG reader."""
    padding = "    " * indent
    if isinstance(value, dict):
        entries = ["    " * (indent + 1) + json.dumps(key) + " = " + spa_json(item, indent + 1)
                   for key, item in value.items()]
        return "{\n" + "\n".join(entries) + "\n" + padding + "}"
    if isinstance(value, (list, tuple)):
        return "[ " + " ".join(spa_json(item, indent) for item in value) + " ]"
    return json.dumps(value, allow_nan=False)


def split_graph(source: dict, profile: str, engine: str, name: str) -> dict[str, dict]:
    """Select whole maintained node declarations without changing algorithms."""
    graph = source["filter.graph"]
    labels = ("pixel-calibration-u16-f32",
              "shack-hartmann-image-f32" if profile == "classic" else
              "pyramid-pixel-image-f32" if engine == "fgn" else "pyramid-pupil-image-f32",
              "pdm-command-f32")
    selected = []
    for label in labels:
        matches = [node for node in graph["nodes"] if node.get("label") == label]
        if len(matches) != 1:
            raise ValueError(f"calibration requires one maintained {label} node")
        selected.append(matches[0])
    pixel, wfs, command = selected
    if command["config"].get("actuator_count") != 277:
        raise ValueError("selected calibration requires 277 physical actuator commands")
    expected_shape = 352 if profile == "classic" else 64
    if any(node["config"].get(key) != expected_shape for node in (pixel, wfs)
           for key in ("image_rows", "image_columns")):
        raise ValueError("selected full-frame WFS detector geometry differs")
    measurement_geometry = {"subaperture_count": 188, "subaperture_rows": 22,
                            "subaperture_columns": 22} if profile == "classic" else {
                            "pupil_rows": 30, "pupil_columns": 30}
    if any(wfs["config"].get(key) != value for key, value in measurement_geometry.items()):
        raise ValueError("selected full-frame WFS measurement geometry differs")
    mask = wfs["config"].get("pupil_mask")
    if profile == "copper" and mask is not None and (len(mask) != 900 or not all(value is True for value in mask)):
        raise ValueError("selected Copper requires all 900 pupil coordinates")
    if len({node["name"] for node in graph["nodes"]}) != len(graph["nodes"]):
        raise ValueError("maintained graph node names must be unique")
    link = {"output": pixel["name"] + ":calibrated", "input": wfs["name"] + ":image"}
    if sum(item == link for item in graph["links"]) != 1:
        raise ValueError("maintained graph requires the exact pixel-to-WFS link")

    result = {}
    for role, nodes, links, outputs in (
            ("wfs", [pixel, wfs], [link],
             [wfs["name"] + ":" + port for port in
              (("slopes", "flux", "validity") if profile == "classic" else
               ("reconstruction-pixels", "mean-pupil-intensity"))]),
            ("command", [command], [],
             [command["name"] + ":demanded", command["name"] + ":constraint-feedback"])):
        value = copy.deepcopy(source)
        # Feedback delay and controller startup bindings belong to the ordinary
        # science graph. Each calibration graph has independent frame ingress.
        for key in list(value):
            if key.startswith(("pipewireao.feedback.", "pipewireao.startup-parameter.")):
                del value[key]
        value["node.name"] = name + "-" + role
        selected_names = {node["name"] for node in nodes}
        value["filter.graph"].update({
            "nodes": copy.deepcopy(nodes), "links": copy.deepcopy(links),
            "inputs": [port for port in graph["inputs"] if port.split(":", 1)[0] in selected_names]
                      if role == "wfs" else [command["name"] + ":requested"],
            "outputs": outputs})
        result[role] = value
    return result


def graph_parameters(graph: dict, parameters: list[dict]) -> list[science.Parameter]:
    inputs = set(graph["filter.graph"]["inputs"])
    return [science.Parameter(**{**item, "shape": tuple(item["shape"])})
            for item in parameters if item["endpoint"] in inputs]


def julia_arguments(graph: dict, parameters: list[science.Parameter], role: str,
                    rate: str, executable: str) -> list[str]:
    """Use the maintained full-frame owner CLI, with no integrator feedback."""
    argv = [executable, "--startup-file=no", "--threads=2,0",
            "--project=@PACKAGE@/jfg/deployment", "@PACKAGE@/jfg/deployment/run_island.jl",
            "--graph", f"@PACKAGE@/graphs/{role}.conf.in", "--name", graph["node.name"],
            "--remote", "@REMOTE@", "--rate", rate, "--boundary-layout", "row-major",
            "--session-run-control", "--fifo-inputs", "--execution", "complete-frame"]
    if any(node["label"] == "pyramid-pupil-image-f32" for node in graph["filter.graph"]["nodes"]):
        argv.extend(["--algorithm", "FilterGraphAlgorithms.PyramidPupilImageF32"])
    for parameter in parameters:
        argv.extend(["--parameter", parameter.endpoint.split(":", 1)[1],
                     science.JULIA_TYPES[parameter.element_type],
                     ",".join(map(str, parameter.shape)), "@PACKAGE@/calibration/" + parameter.file])
    for endpoint in graph["filter.graph"]["outputs"]:
        argv.extend(["--warmup-output", endpoint.split(":", 1)[1]])
    return argv


def boundary_contract(graph: dict, profile: str, role: str, engine: str) -> list[dict]:
    """Describe public array contracts; node-qualified FGN endpoints are retained."""
    nodes = graph["filter.graph"]["nodes"]
    endpoint = lambda node, leaf: node["name"] + ":" + leaf if engine == "fgn" else leaf
    if role == "command":
        return [science.port(endpoint(nodes[0], leaf), direction, (277,), schema)
                for leaf, direction, schema in (("requested", "input", REQUESTED_SCHEMA),
                    ("demanded", "output", science.COMMAND_SCHEMA),
                    ("constraint-feedback", "output", FEEDBACK_SCHEMA))]
    extent = 352 if profile == "classic" else 64
    value = [science.port(endpoint(nodes[0], "raw"), "input", (extent, extent), science.RAW_SCHEMA, "U16_LE")]
    measurements = (("slopes", (188, 2), "shack-hartmann-slopes", "F32_LE"),
                    ("flux", (188,), "shack-hartmann-flux", "F32_LE"),
                    ("validity", (188,), "shack-hartmann-validity", "BOOL8")) if profile == "classic" else (
                    ("reconstruction-pixels", (4, 900), "pyramid-reconstruction-pixels", "F32_LE"),
                    ("mean-pupil-intensity", (1,), "pyramid-mean-pupil-intensity", "F32_LE"))
    value.extend(science.port(endpoint(nodes[1], leaf), "output", shape,
                             "org.calculon.ao." + schema + "/1", element_type)
                 for leaf, shape, schema, element_type in measurements)
    return value


def export(arguments) -> Path:
    output = arguments.output.resolve()
    if output.exists():
        raise ValueError(f"export output must be new: {output}")
    base = arguments.base_package.resolve()
    specification = deploy.profile(base / "deployment.conf", arguments.pipewire_prefix)
    provenance = json.loads((base / "provenance.json").read_text())
    profile, engine = provenance["profile"], provenance["engine"]
    if profile not in ("classic", "copper") or engine not in ("fgn", "jfg") or provenance["mode"] != "frame":
        raise ValueError("initial calibration requires selected full-frame Classic/Copper FGN/JFG science")
    session = deploy.decode(base / specification["session"], arguments.pipewire_prefix)
    if session["execution"] != "complete-frame":
        raise ValueError("initial calibration requires complete-frame science")
    source_path = base / "graphs/graph.conf.in"
    source = deploy.decode(source_path, arguments.pipewire_prefix)
    name = f"revolt-{profile}-{engine}-initial-calibration"
    graphs = split_graph(source, profile, engine, name)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rtc-calibration-export-", dir=output.parent) as temporary:
        package = Path(temporary) / "package"
        (package / "graphs").mkdir(parents=True)
        (package / "calibration").mkdir()
        if engine == "fgn":
            shutil.copytree(base / "lib", package / "lib")
        else:
            shutil.copytree(base / "jfg", package / "jfg")
            # Installed HIL owners use this maintained local transport package
            # through their unchanged Project/Manifest relative source path.
            transport = base / "hil/packages/PipeWireAO"
            if transport.is_dir():
                shutil.copytree(transport, package / "hil/packages/PipeWireAO")
        records = []
        parameters = []
        for role, graph in graphs.items():
            selected = graph_parameters(graph, provenance["parameters"])
            for parameter in selected:
                science.copy_file(base / "calibration" / parameter.file, package / "calibration" / parameter.file)
                science.validate_parameter(package / "calibration", parameter)
                if engine == "fgn":
                    if parameter.element_type != "F32_LE":
                        raise ValueError("native startup parameters require F32_LE")
                    graph["pipewireao.startup-parameter." + parameter.endpoint] = "@PACKAGE@/calibration/" + parameter.file
            parameters.extend(selected)
            path = f"graphs/{role}.conf.in"
            (package / path).write_text(spa_json(graph) + "\n")
            record = {"role": role, "file": path, "node.name": graph["node.name"],
                      "ports": boundary_contract(graph, profile, role, engine),
                      "parameters": [asdict(parameter) for parameter in selected]}
            if engine == "jfg":
                owner = next(item for item in specification["owners"] if item["role"] == "julia")
                record["owner_arguments"] = julia_arguments(graph, selected, role, session["rate"], owner["argv"][0])
            records.append(record)
        retained_nodes = {node["name"] for graph in graphs.values() for node in graph["filter.graph"]["nodes"]}
        science.write_json(package / "provenance.json", {
            "profile": profile, "engine": engine, "mode": "frame", "rate": session["rate"],
            "artifact_scope": "initial-calibration-graph-assets",
            "operational_acquisition": "not-established",
            "requested_commands": "absolute prepared physical-actuator figures including reference",
            "additional_system_flat": False, "layout": "row-major",
            "source_deployment_sha256": science.sha256(base / "deployment.conf"),
            "source_graph_sha256": science.sha256(source_path),
            "source_provenance_sha256": science.sha256(base / "provenance.json"),
            "source_provenance": provenance,
            "rtc_revision": science.revision(Path(__file__).resolve().parents[1]),
            "exporter_sha256": science.sha256(Path(__file__).resolve()),
            "parameter_initialization": "owner-preload",
            "parameters": [{**asdict(parameter), "sha256": science.sha256(package / "calibration" / parameter.file)}
                           for parameter in parameters],
            "construction_parameters": [item for item in provenance.get("construction_parameters", [])
                                        if item["endpoint"].split(":", 1)[0] in retained_nodes],
            "graphs": records,
            "artifacts": {str(path.relative_to(package)): science.sha256(path)
                          for path in sorted(package.rglob("*")) if path.is_file()}})
        package.rename(output)
    return output / "provenance.json"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-package", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    try:
        print(export(arguments(argv)))
    except (OSError, ValueError, KeyError, deploy.DeploymentError, subprocess.SubprocessError) as error:
        print(f"calibration export rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
