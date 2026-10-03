#!/usr/bin/env python3
"""Attach a held AOS plant to an installed complete-frame scientific profile."""

from __future__ import annotations

import argparse
import copy
from dataclasses import asdict
import json
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
    return {"source": "simulated detector and zero-command plant", "report": "hil/calibration-result.json",
            "report_sha256": science.sha256(result_path), "replaced_artifact_sha256": original,
            "artifacts": result["artifacts"],
            "retained_calibration": "recorded reconstructor and projections; hybrid, convergence unqualified"}


def export_hil(args) -> Path:
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
        executable = str(Path(shutil.which("julia") or "missing-julia").resolve())
        subprocess.run([executable, "--startup-file=no", "--threads=1,0", f"--project={package / 'hil'}",
                        "-e", "using Pkg; Pkg.instantiate(; update_registry=false, allow_autoprecomp=false)"], check=True, timeout=1800)
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
                              "calibration_algorithms_revision": science.revision(args.calibration_algorithms_root),
                              "simulated_calibration": calibration,
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
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    return parser.parse_args(argv)


if __name__ == "__main__":
    try:
        print(export_hil(arguments()))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"HIL export rejected: {error}", file=sys.stderr)
        raise SystemExit(1)
