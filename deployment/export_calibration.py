#!/usr/bin/env python3
"""Export full-frame initial-calibration graphs and an optional RTC descriptor.

The default output contains graph assets only. ``--deployment`` adds the
standard RTC session and owner descriptor; it does not qualify acquisition.
Existing offset provenance retains its original claim.
"""

from __future__ import annotations

import argparse
import copy
from dataclasses import asdict
import json
from pathlib import Path
import re
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


def calibration_session(graph_records: list[dict], profile: str, engine: str,
                        rate: str) -> dict:
    """Compose the calibration graphs and application-owned acquisition endpoints."""
    extent = 352 if profile == "classic" else 64
    def repeated_port(name: str, direction: str, shape: tuple[int, ...],
                      schema: str, element_type: str) -> dict:
        result = science.port(name, direction, shape, schema, element_type)
        result["rate"] = rate
        return result

    raw = repeated_port("output_1", "output", (extent, extent), science.RAW_SCHEMA, "U16_LE")
    requested = repeated_port("output_1", "output", (277,), REQUESTED_SCHEMA, "F32_LE")
    command = repeated_port("input_1", "input", (277,), science.COMMAND_SCHEMA, "F32_LE")
    feedback = repeated_port("input_1", "input", (277,), FEEDBACK_SCHEMA, "F32_LE")
    sources = [
        {"ownership": "external", "node.name": "simulator-wfs", "ports": [raw]},
        {"ownership": "external", "node.name": "calibration-probe", "ports": [requested]},
    ]
    sinks = [
        {"ownership": "external", "node.name": "simulator-command", "ports": [command]},
        {"ownership": "external", "node.name": "calibration-feedback", "ports": [feedback]},
    ]
    wfs_record = next(record for record in graph_records if record["role"] == "wfs")
    command_record = next(record for record in graph_records if record["role"] == "command")
    for name, port_contract in zip(
            ("calibration-slopes", "calibration-flux", "calibration-validity")
            if profile == "classic" else
            ("calibration-reconstruction-pixels", "calibration-mean-pupil-intensity"),
            wfs_record["ports"][1:]):
        shape = tuple(port_contract["shape"])
        sinks.append({"ownership": "external", "node.name": name,
                      "ports": [repeated_port("input_1", "input", shape,
                                               port_contract["schema"],
                                               port_contract["element-type"])]})
    sinks.append({"ownership": "external", "node.name": "calibration-raw",
                  "ports": [repeated_port("input_1", "input", (extent, extent),
                                           science.RAW_SCHEMA, "U16_LE")]})

    graphs = []
    for record in graph_records:
        graph = {"node.name": record["node.name"], "ports": record["ports"]}
        if engine == "fgn":
            graph.update({"factory": "pipewireao.fgn-native",
                          "module": "libpipewire-module-ndarray-filter-chain",
                          "config.path": "${PIPEWIREAO_RTC_GRAPH_CALIBRATION_"
                                         + record["role"].upper() + "}"})
        else:
            graph.update({"ownership": "external", "run-control": "session"})
        graphs.append(graph)

    wfs = wfs_record
    command_graph = command_record
    wfs_node, command_node = wfs["node.name"], command_graph["node.name"]
    wfs_raw = wfs["ports"][0]["name"]
    requested_name = command_graph["ports"][0]["name"]
    demanded_name = command_graph["ports"][1]["name"]
    feedback_name = command_graph["ports"][2]["name"]
    outputs = wfs["ports"][1:]
    links = [
        {"output": f"simulator-wfs:output_1", "input": f"{wfs_node}:{wfs_raw}", "passive": True},
        {"output": "simulator-wfs:output_1", "input": "calibration-raw:input_1", "passive": False},
        {"output": "calibration-probe:output_1", "input": f"{command_node}:{requested_name}", "passive": True},
        {"output": f"{command_node}:{demanded_name}", "input": "simulator-command:input_1", "passive": False},
        {"output": f"{command_node}:{feedback_name}", "input": "calibration-feedback:input_1", "passive": False},
    ]
    response_names = ("calibration-slopes", "calibration-flux", "calibration-validity") \
        if profile == "classic" else \
        ("calibration-reconstruction-pixels", "calibration-mean-pupil-intensity")
    links.extend({"output": f"{wfs_node}:{port['name']}",
                  "input": f"{sink}:input_1", "passive": False}
                 for port, sink in zip(outputs, response_names))
    return {
        "profile": "development", "execution": "complete-frame", "authority": "none",
        "claim": "development-characterization", "rate": rate,
        "sources": sources, "graphs": graphs, "sinks": sinks,
        "execution-groups": [{"name": "calibration", "nodes": [item["node.name"] for item in graphs]}],
        "properties": {}, "parameters": {}, "observations": [], "links": links,
    }


def julia_pin_cpu_arguments(argv: list[str]) -> list[str]:
    """Preserve only one explicit pin-cpus option from the existing JFG owner."""
    occurrences = [index for index, argument in enumerate(argv)
                   if argument == "--pin-cpus" or argument.startswith("--pin-cpus=")]
    if len(occurrences) > 1:
        raise ValueError("existing Julia owner has duplicate --pin-cpus options")
    if not occurrences:
        return []
    index = occurrences[0]
    argument = argv[index]
    if argument == "--pin-cpus":
        if index + 1 >= len(argv) or not argv[index + 1] or argv[index + 1].startswith("--"):
            raise ValueError("existing Julia owner --pin-cpus requires a nonempty value")
        value = argv[index + 1]
    else:
        _, value = argument.split("=", 1)
        if not value:
            raise ValueError("existing Julia owner --pin-cpus requires a nonempty value")
    return ["--pin-cpus", value]


def deployment_descriptor(package: Path, base: Path, specification: dict,
                          graph_records: list[dict], profile: str, engine: str,
                          session: dict, prefix: Path, *, illumination: str = "lamp",
                          stage: str = "interaction", capture_max_bytes: int | None = None) -> dict:
    """Emit the existing deployment contract for the opt-in calibration topology."""
    simulator = next((owner for owner in specification["owners"]
                      if owner["role"] == specification.get("source-owner")), None)
    if simulator is None:
        raise ValueError("calibration deployment descriptor requires an existing HIL source owner")
    if engine == "jfg" and not any(owner["role"] == "julia" for owner in specification["owners"]):
        raise ValueError("JFG calibration descriptor requires the existing Julia owner contract")
    if engine == "fgn":
        environment = specification.setdefault("environment", {})
        environment.update({
            "PIPEWIREAO_RTC_GRAPH_CALIBRATION_WFS": "@RUNTIME@/wfs.conf",
            "PIPEWIREAO_RTC_GRAPH_CALIBRATION_COMMAND": "@RUNTIME@/command.conf",
        })

    simulator["argv"] = list(simulator["argv"])
    entrypoint = "@PACKAGE@/hil/calibration_owner.jl"
    for index, argument in enumerate(simulator["argv"]):
        if argument.endswith("/hil/simulator.jl"):
            simulator["argv"][index] = entrypoint
            break
    else:
        raise ValueError("HIL source owner has no maintained simulator entrypoint")
    simulator["argv"].extend(["--calibration-socket", "@RUNTIME@/calibration.sock"])
    simulator["argv"].extend(["--illumination", illumination, "--calibration-stage", stage])
    if capture_max_bytes is not None:
        simulator["argv"].extend(["--capture-directory", "@RUNTIME@/captured",
                                  "--capture-max-bytes", str(capture_max_bytes)])
    if profile == "classic":
        simulator["argv"].extend(["--wfs-active", "@PACKAGE@/calibration/wfs-active.u8"])

    specification["name"] += "-calibration"
    specification["session"] = "session.conf.in"
    specification["client"].setdefault("simulator", "client-simulator.conf.in")
    clients = base / "client-simulator.conf.in"
    if clients.is_file():
        shutil.copy2(clients, package / clients.name)
    if "core.conf.in" not in {path.name for path in package.iterdir()}:
        shutil.copy2(base / "core.conf.in", package / "core.conf.in")
    old_julia = next((owner for owner in specification["owners"] if owner["role"] == "julia"), None)
    if engine == "jfg":
        pin_arguments = julia_pin_cpu_arguments(old_julia["argv"])
        old_placement = specification["placement"].pop("julia")
        old_client = specification["client"].pop("julia")
        specification["owners"] = [owner for owner in specification["owners"]
                                    if owner["role"] != "julia"]
        for record in graph_records:
            role = "julia-" + record["role"]
            argv = list(record["owner_arguments"])
            argv.extend(pin_arguments)
            owner = {"role": role, "argv": argv,
                     "environment": dict(old_julia["environment"])}
            markers = {key: role + "." + key for key in
                       ("prepared", "connect", "connected", "quit")}
            owner.update(markers)
            for option, marker in (("--prepared-event", "prepared"),
                                   ("--connect-request", "connect"),
                                   ("--connect-reply", "connected"),
                                   ("--quit-request", "quit")):
                owner["argv"].extend([option, "@RUNTIME@/" + markers[marker]])
            specification["owners"].append(owner)
            specification["placement"][role] = copy.deepcopy(old_placement)
            specification["client"][role] = old_client
    for client in set(specification["client"].values()):
        path = base / client
        if path.is_file():
            shutil.copy2(path, package / client)
    science.write_json(package / "session.conf.in", session)
    specification["artifacts"] = {
        str(path.relative_to(package)): science.sha256(path)
        for path in sorted(package.rglob("*"))
        if path.is_file() and path.name != "deployment.conf"
    }
    science.write_json(package / "deployment.conf", specification)
    deploy.profile(package / "deployment.conf", prefix)
    return specification


def classic_active(graph: dict, parameters: list, package: Path) -> bytes:
    """Bind acceptance to the exact active parameter used by the WFS owner."""
    node = next(node for node in graph["filter.graph"]["nodes"]
                if node["label"] == "shack-hartmann-image-f32")
    endpoint = node["name"] + ":active"
    supplied = [parameter for parameter in parameters if parameter.endpoint == endpoint]
    if len(supplied) > 1:
        raise ValueError("Classic has duplicate active parameters")
    if supplied:
        values = (package / "calibration" / supplied[0].file).read_bytes()
        if any(value not in (0, 1) for value in values):
            raise ValueError("Classic active parameter requires zero/one bytes")
    else:
        configured = node["config"].get("active")
        if configured is None or any(type(value) is not bool for value in configured):
            raise ValueError("Classic requires an explicit deployed active selection")
        values = bytes(configured)
    if len(values) != 188 or not any(values):
        raise ValueError("Classic active selection requires 188 entries and at least one active ROI")
    return values


def selected_calibration_binary(arguments) -> Path | None:
    """Require the installed calibration CLI only for deployment exports."""
    if not getattr(arguments, "deployment", False):
        return None
    source = getattr(arguments, "calibration_binary", None)
    if source is None or not source.is_file():
        raise ValueError("--deployment requires an existing --calibration-binary")
    return source.resolve()


def selected_rtc_binary(arguments) -> Path | None:
    """Require an explicitly selected RTC runner for deployment exports."""
    if not getattr(arguments, "deployment", False):
        return None
    source = getattr(arguments, "rtc_binary", None)
    if source is None or not source.is_file():
        raise ValueError("--deployment requires an existing --rtc-binary")
    return source.resolve()


def copy_calibration_binary(package: Path, source: Path) -> dict:
    relative_path = "bin/rtc-calibrate"
    destination = package / relative_path
    science.copy_file(source, destination)
    return {"path": relative_path, "sha256": science.sha256(destination)}


def copy_rtc_binary(package: Path, source: Path) -> dict:
    relative_path = "bin/pipewireao-rtc"
    destination = package / relative_path
    science.copy_file(source, destination)
    return {"path": relative_path, "sha256": science.sha256(destination)}


def export(arguments) -> Path:
    output = arguments.output.resolve()
    if output.exists():
        raise ValueError(f"export output must be new: {output}")
    calibration_binary = selected_calibration_binary(arguments)
    rtc_binary = selected_rtc_binary(arguments)
    base = arguments.base_package.resolve()
    specification = deploy.profile(base / "deployment.conf", arguments.pipewire_prefix)
    provenance = json.loads((base / "provenance.json").read_text())
    profile, engine = provenance["profile"], provenance["engine"]
    illumination = getattr(arguments, "illumination", "lamp")
    stage = getattr(arguments, "calibration_stage", "interaction")
    capture_max_bytes = getattr(arguments, "capture_max_bytes", None)
    if illumination not in ("dark", "lamp"):
        raise ValueError("illumination must be dark or lamp")
    if not isinstance(stage, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", stage):
        raise ValueError("calibration stage must be a simple 1..64 character identifier")
    if capture_max_bytes is not None:
        if (type(capture_max_bytes) is not int or not 1 <= capture_max_bytes <= 4096 * 250252
                or profile != "classic" or not getattr(arguments, "deployment", False)):
            raise ValueError("capture requires Classic deployment and a bounded positive payload budget")
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
        if getattr(arguments, "deployment", False):
            if not (base / "hil/calibration_acquisition.jl").is_file():
                raise ValueError("calibration deployment descriptor requires calibration_acquisition.jl in the HIL package")
            shutil.copytree(base / "hil", package / "hil")
            # The exporter owns these orchestration sources. Preserve the base's
            # scientific packages/manifest, but do not deploy a stale owner from
            # an earlier exported fixture under a new protocol descriptor.
            for filename in ("calibration_owner.jl", "calibration_acquisition.jl",
                             "calibration_server.jl", "calibration_client.jl"):
                shutil.copy2(Path(__file__).parent / "hil" / filename, package / "hil" / filename)
            (package / "bin").mkdir()
            calibration_command = copy_calibration_binary(package, calibration_binary)
            rtc_runner = copy_rtc_binary(package, rtc_binary)
        if engine == "fgn":
            shutil.copytree(base / "lib", package / "lib")
        else:
            shutil.copytree(base / "jfg", package / "jfg")
            # Installed HIL owners use this maintained local transport package
            # through their unchanged Project/Manifest relative source path.
            transport = base / "hil/packages/PipeWireAO"
            if transport.is_dir() and not (package / "hil/packages/PipeWireAO").exists():
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
        if getattr(arguments, "deployment", False) and profile == "classic":
            active = classic_active(graphs["wfs"], parameters, package)
            (package / "calibration/wfs-active.u8").write_bytes(active)
        science.write_json(package / "provenance.json", {
            "profile": profile, "engine": engine, "mode": "frame", "rate": session["rate"],
            "artifact_scope": "initial-calibration-graph-assets",
            "operational_acquisition": "not-established",
            "requested_commands": "absolute prepared physical-actuator figures including reference",
            "additional_system_flat": False, "layout": "row-major",
            "calibration_stage": stage, "illumination": illumination,
            "capture_max_payload_bytes": capture_max_bytes,
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
        if getattr(arguments, "deployment", False):
            provenance_path = package / "provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["deployment_descriptor"] = "deployment.conf"
            provenance["deployment_entrypoint"] = (
                "hil/calibration_owner.jl" if (package / "hil/calibration_owner.jl").is_file()
                else "missing: hil/calibration_owner.jl")
            provenance["artifact_scope"] = "initial-calibration-graphs-and-deployment-descriptor"
            provenance["calibration_command"] = calibration_command
            provenance["rtc_runner"] = rtc_runner
            science.write_json(provenance_path, provenance)
            session = calibration_session(records, profile, engine, session["rate"])
            deployment_descriptor(package, base, specification, records, profile,
                                   engine, session, arguments.pipewire_prefix,
                                   illumination=illumination, stage=stage,
                                   capture_max_bytes=capture_max_bytes)
        package.rename(output)
    return output / "provenance.json"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-package", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, required=True)
    parser.add_argument("--deployment", action="store_true",
                        help="also export an initial calibration session and deployment descriptor")
    parser.add_argument("--calibration-binary", type=Path,
                        help="compiled rtc-calibrate executable required with --deployment")
    parser.add_argument("--rtc-binary", type=Path,
                        help="compiled pipewireao-rtc executable required with --deployment")
    parser.add_argument("--illumination", choices=("dark", "lamp"), default="lamp")
    parser.add_argument("--calibration-stage", default="interaction")
    parser.add_argument("--capture-max-bytes", type=int,
                        help="enable finite Classic raw/WFS capture with this cumulative payload budget")
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
