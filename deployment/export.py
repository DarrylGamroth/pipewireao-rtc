#!/usr/bin/env python3
"""Prepare installed recorded-input REVOLT profiles without starting processes.

Scientific generators are used at export time only. The resulting package
contains ordinary graph configurations, calibration arrays and owner code.
"""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass, replace
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
RAW_SCHEMA = "org.calculon.ao.raw-detector-pixels/1"
ROW_SCHEMA = "org.calculon.ao.raw-pixel-row-block/1"
COMMAND_SCHEMA = "org.calculon.ao.demanded-pdm-command/1"
TYPE_BYTES = {"F32_LE": 4, "U16_LE": 2, "U32_LE": 4, "U8": 1, "Bool": 1}
JULIA_TYPES = {"F32_LE": "Float32", "U16_LE": "UInt16", "U32_LE": "UInt32",
               "U8": "UInt8", "Bool": "Bool"}


@dataclass(frozen=True)
class Parameter:
    name: str
    endpoint: str
    element_type: str
    shape: tuple[int, ...]
    file: str
    schema: str = ""


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_file(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise ValueError(f"missing export prerequisite: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=True)


def write_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def generator(root: Path, name: str):
    """Import the selected maintained build-time generator from its own tree."""
    source = root / "scripts" / f"{name}.py"
    if not source.is_file():
        raise ValueError(f"missing maintained scientific generator: {source}")
    specification = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(specification)
    previous = sys.path[:]
    sys.path.insert(0, str(source.parent))
    sys.modules[name] = module
    try:
        specification.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    return module


def validate_parameter(directory: Path, parameter: Parameter) -> None:
    path = directory / parameter.file
    expected = math.prod(parameter.shape) * TYPE_BYTES[parameter.element_type]
    if not path.is_file() or path.stat().st_size != expected:
        raise ValueError(f"{parameter.name} requires {expected} bytes for "
                         f"{parameter.element_type}{parameter.shape}: {path}")
    if parameter.element_type == "Bool" and any(value > 1 for value in path.read_bytes()):
        raise ValueError(f"{parameter.name} Bool payload requires zero/one bytes")


def classic_parameters() -> list[Parameter]:
    return [
        Parameter("background", "pixel-calibration:background", "F32_LE", (352, 352), "background.f32le"),
        Parameter("subaperture-origins", "shack-hartmann:subaperture-origins", "U32_LE", (188, 2), "subaperture-origins.u32le"),
        Parameter("coordinates", "shack-hartmann:coordinates", "F32_LE", (484, 2), "shack-hartmann-coordinates.f32le"),
        Parameter("reference-slopes", "shack-hartmann:reference-slopes", "F32_LE", (188, 2), "reference-slopes.f32le"),
        Parameter("thresholds", "shack-hartmann:thresholds", "F32_LE", (188, 2), "thresholds.f32le"),
        Parameter("active", "shack-hartmann:active", "Bool", (188,), "active-subapertures.u8"),
        Parameter("reconstructor", "reconstruction:reconstructor", "F32_LE", (221, 376), "reconstructor.f32le", "org.calculon.ao.shwfs-reconstructor/1"),
        Parameter("controller-to-vdm", "controller-to-vdm:controller-to-vdm", "F32_LE", (221, 221), "controller-to-vdm.f32le"),
        Parameter("active-to-full", "vdm-to-pdm:active-to-full", "F32_LE", (277, 221), "active-to-full-vdm.f32le"),
        Parameter("vdm-to-pdm", "vdm-to-pdm:vdm-to-pdm", "F32_LE", (277, 277), "vdm-to-pdm.f32le"),
        Parameter("full-to-active", "pdm-feedback-to-vdm:full-to-active", "F32_LE", (221, 277), "full-to-active-vdm.f32le"),
        Parameter("pdm-to-vdm", "pdm-feedback-to-vdm:pdm-to-vdm", "F32_LE", (277, 277), "pdm-to-vdm.f32le"),
        Parameter("vdm-to-controller", "vdm-feedback-to-controller:vdm-to-controller", "F32_LE", (221, 221), "vdm-to-controller.f32le"),
    ]


def prepare_science(arguments, output: Path) -> tuple[str | None, list[Parameter], dict]:
    calibration = output / "calibration"
    calibration.mkdir()
    # Scientific generators need a concrete plugin spelling while resolving
    # their own placeholders. Bind the package location after that validation.
    plugin_token = Path("INSTALL_PACKAGE_FGN_BUNDLE")
    if arguments.profile == "classic":
        module = generator(arguments.algorithms_root, "qualify_fgn_revolt_classic")
        source = arguments.classic_calibration
        profile = module.load_prepared_profile(source / "prepared-profile.toml")
        geometry = (profile.detector_height, profile.detector_width,
                    profile.subaperture_count, profile.subaperture_height,
                    profile.subaperture_width, profile.controlled_vdm_size,
                    profile.full_vdm_size, profile.pdm_size)
        if geometry != (352, 352, 188, 22, 22, 221, 277, 277):
            raise ValueError(f"selected matched Classic geometry differs: {geometry}")
        if (profile.clwc_loop_gain, profile.clwc_pole, profile.clwc_anti_windup_gain) != (-0.3, 0.99, 0.99):
            raise ValueError("selected Classic controller coefficients differ from maintained JFG feedback graph")
        if any(value != -0.8 for value in profile.pdm_lower_limits) or any(value != 0.8 for value in profile.pdm_upper_limits):
            raise ValueError("selected Classic clipping bounds differ from maintained feedback graph")
        parameters = classic_parameters()
        for parameter in parameters:
            copy_file(source / parameter.file, calibration / parameter.file)
            validate_parameter(calibration, parameter)
        copy_file(source / "prepared-profile.toml", calibration / "prepared-profile.toml")
        binary_origins = tuple(value[0] for value in struct.iter_unpack("<I", (calibration / "subaperture-origins.u32le").read_bytes()))
        if binary_origins != tuple(value for origin in profile.subaperture_origins for value in origin):
            raise ValueError("Classic binary origins differ from the prepared-profile construction origins")
        profile = replace(profile, frame_rate=(arguments.rate_hz, 1))
        if arguments.mode == "frame":
            graph = module.resolve_config(plugin_token, profile)
        else:
            graph = module.resolve_row_feedback_config(plugin_token, profile, 11)
        metadata = {"generator": "qualify_fgn_revolt_classic", "prepared_profile": asdict(profile),
                    "prepared_profile_sha256": sha256(source / "prepared-profile.toml")}
    else:
        module = generator(arguments.algorithms_root, "run_fgn_copper_fullframe_live")
        sources, manifest = module.prepare_artifacts(calibration, arguments.copper_calibration, clipping_feedback=True)
        parameters = [Parameter(item["name"], item["port"], "F32_LE", tuple(item["shape"]),
                                item["path"].name, item["schema"]) for item in sources]
        if arguments.mode == "row":
            module = generator(arguments.algorithms_root, "run_fgn_copper_row_live")
        graph = module.graph_config(plugin_token, arguments.rate_hz, clipping_feedback=True, command_limit_um=0.8)
        metadata = {"generator": module.__name__, "parameter_metadata": {
            name: {key: value for key, value in record.items() if key != "path"}
            for name, record in manifest.items()}}
        metadata["source_calibration"] = {name: sha256(arguments.copper_calibration / name) for name in (
            "controlMatrix_250modes_bench_new2025_06_23_1617.fits",
            "dm0ModesToActuators_250new.fits", "dm0ActuatorsToModes_250new.fits", "aligned_flat.fits")}
    for parameter in parameters:
        validate_parameter(calibration, parameter)
    if arguments.engine == "fgn":
        if arguments.profile == "classic":
            graph = classic_active_mask(graph, (calibration / "active-subapertures.u8").read_bytes())
        graph = graph.replace(str(plugin_token), json.dumps("@PACKAGE@/lib/" + arguments.fgn_bundle.name)[1:-1])
        # The installed native startup-artifact interface admits F32 only.
        # Origins and active flags are resolved into public construction fields.
        metadata["construction_parameters"] = [
            {**asdict(parameter), "sha256": sha256(calibration / parameter.file)}
            for parameter in parameters if parameter.element_type != "F32_LE"]
        for parameter in parameters:
            if parameter.element_type != "F32_LE":
                (calibration / parameter.file).unlink()
        parameters = [parameter for parameter in parameters if parameter.element_type == "F32_LE"]
    else:
        graph = None
    return graph, parameters, metadata


def classic_active_mask(graph: str, values: bytes) -> str:
    if not values or any(value > 1 for value in values):
        raise ValueError("Classic active mask requires zero/one bytes")
    declaration = "active = [ " + " ".join("true" if value else "false" for value in values) + " ]"
    if re.search(r"\bactive\s*=\s*null", graph):
        graph, count = re.subn(r"\bactive\s*=\s*null", lambda _: declaration, graph)
    else:
        graph, count = re.subn(r"coordinate_scale\s*=\s*1\.0", lambda match: declaration + "\n                    " + match.group(0), graph)
    if count != 1:
        raise ValueError("Classic graph has no unique maintained active-mask construction field")
    return graph


def terminal_outputs(graph: str, outputs: list[str]) -> str:
    replacement = "outputs = [ " + " ".join(json.dumps(name) for name in outputs) + " ]"
    graph, count = re.subn(r"\boutputs\s*=\s*\[.*?\]", lambda _: replacement, graph, flags=re.S)
    if count != 1:
        raise ValueError(f"expected one maintained external output declaration, found {count}")
    return graph


def native_graph(graph: str, parameters: list[Parameter], profile: str, name: str) -> str:
    input_feedback = "closed-loop-correction:constraint-feedback" if profile == "classic" else "control:constraint-feedback"
    output_feedback = "vdm-feedback-to-controller:controller-constraint-feedback" if profile == "classic" else "feedback-to-controller:controller-constraint-feedback"
    demanded = "pdm-command:demanded" if profile == "classic" else "command:demanded"
    graph = terminal_outputs(graph, [demanded, output_feedback])
    graph, count = re.subn(r"node\.name\s*=\s*[^\s\n]+", "node.name = " + name, graph, count=1)
    if count != 1:
        raise ValueError("maintained graph requires a node.name")
    startup = "\n".join("    " + json.dumps("pipewireao.startup-parameter." + parameter.endpoint) +
                        " = " + json.dumps("@PACKAGE@/calibration/" + parameter.file)
                        for parameter in parameters if parameter.element_type == "F32_LE")
    properties = ("    node.loop.name = rtc-data-loop\n"
                  "    node.reliable = true\n    pipewireao.fifo-inputs = true\n"
                  "    pipewireao.run-control = true\n    pipewireao.reset-control = true\n" +
                  startup + "\n    " + json.dumps("pipewireao.feedback." + input_feedback) +
                  " = " + json.dumps(output_feedback) + "\n")
    return graph.replace("    filter.graph =", properties + "    filter.graph =", 1)


def copy_julia(root: Path, output: Path) -> None:
    ignored = shutil.ignore_patterns(".git", "test", "tests", "benchmark", "benchmarks",
                                     "compiled", "__pycache__", "*.ji", "*.so", "*.o", "docs", ".github")
    for name in ("FilterGraphAlgorithms", "FilterGraphPipeWire", "JuliaFilterGraph"):
        source = root / "julia" / name
        if not (source / "Project.toml").is_file():
            raise ValueError(f"missing Julia scientific owner package: {source}")
        shutil.copytree(source, output / "jfg/julia" / name, ignore=ignored, symlinks=False)
    for name in ("Project.toml", "Manifest.toml", "run_island.jl", "startup.jl"):
        copy_file(root / "deployment" / name, output / "jfg/deployment" / name)


def julia_owner(arguments, output: Path, parameters: list[Parameter], name: str) -> tuple[dict, str]:
    fixtures = {("classic", "frame"): "rtc-classic-full-frame-feedback.conf",
                ("classic", "row"): "rtc-classic-row-feedback.conf",
                ("copper", "frame"): "rtc-latency-copper-full-frame-feedback.conf",
                ("copper", "row"): "progressive-rtc-latency-copper-feedback.conf"}
    source = arguments.jfg_root / "fixtures/pipewire" / fixtures[arguments.profile, arguments.mode]
    graph = source.read_text()
    demanded = "pdm-command:demanded" if arguments.profile == "classic" else "command:demanded"
    feedback = "vdm-feedback-to-controller:controller-constraint-feedback" if arguments.profile == "classic" else "feedback-to-controller:controller-constraint-feedback"
    graph = terminal_outputs(graph, [demanded, feedback])
    graph = re.sub(r"node\.name\s*=\s*[^\s\n]+", "node.name = " + name, graph, count=1)
    copy_julia(arguments.jfg_root, output)
    extent = 221 if arguments.profile == "classic" else 253
    parameters = list(parameters)
    for leaf, endpoint, shape in (
            ("shape-to-hidden", "closed-loop-correction:shape-to-hidden", (1, extent)),
            ("hidden-to-shape", "closed-loop-correction:hidden-to-shape", (extent, 1))):
        parameter = Parameter(leaf, endpoint, "F32_LE", shape, leaf + ".f32le")
        (output / "calibration" / parameter.file).write_bytes(bytes(math.prod(shape) * 4))
        parameters.append(parameter)
    executable = shutil.which("julia")
    if executable is None:
        raise ValueError("Julia executable is an unresolved deployment prerequisite")
    argv = [str(Path(executable).resolve()), "--startup-file=no", "--threads=2,0",
            "--project=@PACKAGE@/jfg/deployment", "@PACKAGE@/jfg/deployment/run_island.jl",
            "--graph", "@RUNTIME@/graph.conf", "--name", name, "--remote", "@REMOTE@",
            "--rate", f"{arguments.rate_hz}/1", "--boundary-layout", "row-major",
            "--session-run-control", "--fifo-inputs", "--execution",
            "row-block" if arguments.mode == "row" else "complete-frame", "--pin-cpus", "14,10",
            "--feedback", "constraint-feedback", "controller-constraint-feedback",
            "--warmup-output", "demanded", "--warmup-output", "controller-constraint-feedback"]
    if arguments.profile == "copper" and arguments.mode == "frame":
        argv.extend(["--algorithm", "FilterGraphAlgorithms.PyramidPupilImageF32",
                     "--algorithm", "FilterGraphAlgorithms.PyramidPupilReconstructorF32"])
    if arguments.mode == "row":
        argv.extend(["--row-workers", "0", "--matrix-layout", "shared"])
    for parameter in parameters:
        argv.extend(["--parameter", parameter.name, JULIA_TYPES[parameter.element_type],
                     ",".join(map(str, parameter.shape)), "@PACKAGE@/calibration/" + parameter.file])
    markers = {"prepared": "julia.prepared", "connect": "julia.connect",
               "connected": "julia.connected", "quit": "julia.quit"}
    for option, marker in (("--prepared-event", "prepared"), ("--connect-request", "connect"),
                           ("--connect-reply", "connected"), ("--quit-request", "quit")):
        argv.extend([option, "@RUNTIME@/" + markers[marker]])
    owner = {"role": "julia", "argv": argv, "environment": {"OPENBLAS_NUM_THREADS": "1"}, **markers}
    return owner, graph


def port(name: str, direction: str, shape: tuple[int, ...], schema: str,
         element_type: str = "F32_LE", *, parameter: bool = False, rate: int | None = None) -> dict:
    value = {"name": name, "direction": direction, "element-type": element_type,
             "shape": list(shape), "schema": schema}
    if parameter:
        value["parameter"] = True
    if rate is not None:
        value["rate"] = f"{rate}/1"
    return value


def session(arguments, reconstructor: Parameter, graph_name: str, detector_profile: str | None = None) -> dict:
    height = width = 352 if arguments.profile == "classic" else 64
    rows = (11 if arguments.profile == "classic" else 32) if arguments.mode == "row" else height
    block_rate = arguments.rate_hz * (height // rows)
    schema = ROW_SCHEMA if arguments.mode == "row" else RAW_SCHEMA
    image_shape = (rows, width)
    source_args = {"api.fits.path": "${PIPEWIREAO_RTC_FITS_PATH}", "api.fits.hdu": 1,
                   "api.fits.sample-rank": 2, "api.fits.rate": f"{arguments.rate_hz}/1",
                   "api.fits.schema": schema, "api.fits.io-mode": "file",
                   "api.fits.prefault": False, "api.fits.loop": False,
                   "api.fits.readiness": "timerfd", "api.fits.layout": "row-major", "api.fits.output-mode":
                   "row-block" if arguments.mode == "row" else "frame", "node.loop.name": "source-loop"}
    if arguments.mode == "row":
        source_args.update({"api.fits.row-block-rows": rows,
                            "api.fits.simulated-readout-time-ns": arguments.readout_us * 1000,
                            "api.fits.profile": detector_profile or f"revolt-{arguments.profile}"})
    elif detector_profile:
        source_args["api.fits.profile"] = detector_profile
    source = {"factory": "api.fits.source", "module": "libpipewire-module-spa-node-factory",
              "node.name": "recorded-source", "plugin.path": "${PIPEWIREAO_FITS_PLUGIN}",
              "args": source_args, "ports": [port("output", "output", image_shape, schema, "U16_LE", rate=block_rate)]}
    parameter_source = {"factory": "pipewireao.runtime-parameter", "node.name": "rtc-reconstructor",
                        "ports": [port("output_1", "output", reconstructor.shape, reconstructor.schema, parameter=True)]}
    raw = ("pixel-calibration:raw" if arguments.profile == "classic" else "calibrate:raw") if arguments.engine == "fgn" else "raw"
    demanded = ("pdm-command:demanded" if arguments.profile == "classic" else "command:demanded") if arguments.engine == "fgn" else "demanded"
    parameter_name = reconstructor.endpoint if arguments.engine == "fgn" else reconstructor.name
    graph = {"node.name": graph_name, "ports": [
        port(raw, "input", image_shape, schema, "U16_LE", rate=block_rate),
        port(parameter_name, "input", reconstructor.shape, reconstructor.schema, parameter=True),
        port(demanded, "output", (277,), COMMAND_SCHEMA)]}
    if arguments.engine == "fgn":
        graph.update({"factory": "pipewireao.fgn-native", "module": "libpipewire-module-ndarray-filter-chain",
                      "config.path": "${PIPEWIREAO_RTC_GRAPH_DEPLOYMENT}"})
    else:
        graph.update({"ownership": "external", "run-control": "session"})
    sink = {"factory": "api.pipewireao.discard", "module": "libpipewire-module-spa-node-factory",
            "node.name": "command-discard", "plugin.path": "${PIPEWIREAO_DISCARD_PLUGIN}",
            "args": {"node.loop.name": "sink-loop"}, "ports": [port("in", "input", (277,), COMMAND_SCHEMA)]}
    parameter_endpoint = f"{graph_name}:{parameter_name}"
    return {"profile": "development", "execution": "row-block" if arguments.mode == "row" else "complete-frame",
            "authority": "none", "claim": "development-characterization", "rate": f"{arguments.rate_hz}/1",
            "sources": [source, parameter_source], "graphs": [graph], "sinks": [sink],
            "execution-groups": [{"name": "controller", "nodes": ["recorded-source", graph_name, "command-discard"]}],
            # Both scientific owners preload the calibrated matrix before
            # ingress. Keep its live-update route without resubmitting the
            # same value during the first progressive sample.
            "properties": {}, "parameters": {},
            "observations": [], "links": [
                {"output": "recorded-source:output", "input": f"{graph_name}:{raw}", "passive": False},
                {"output": "rtc-reconstructor:output_1", "input": parameter_endpoint, "passive": True},
                {"output": f"{graph_name}:{demanded}", "input": "command-discard:in", "passive": False}]}


def placement(cpus: list[int], fifo_cpus: list[int], *, julia: bool = False) -> dict:
    threads = [{"cpus": [cpu], "policy": "fifo", "priority": 83, "count": 1} for cpu in fifo_cpus]
    if julia:
        threads.append({"cpus": [10], "policy": "other", "priority": 0, "count": 1})
    return {"cpus": cpus, "leader-cpu": 14, "rt-priority": 83,
            "threads": threads, "locked-bytes": 0}


def revision(root: Path) -> str | None:
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                            capture_output=True, text=True, timeout=10)
    return result.stdout.strip() if result.returncode == 0 else None


def export(arguments) -> Path:
    output = arguments.output.resolve()
    if output.exists():
        raise ValueError(f"export output must be new: {output}")
    if not 1 <= arguments.rate_hz <= 1_000_000_000:
        raise ValueError("rate-hz must be positive and at most 1000000000")
    if arguments.readout_us <= 0 or arguments.readout_us * 1000 * arguments.rate_hz >= 1_000_000_000:
        raise ValueError("readout-us must be positive and shorter than the frame period")
    required = arguments.classic_calibration if arguments.profile == "classic" else arguments.copper_calibration
    if required is None or not required.is_dir():
        raise ValueError(f"{arguments.profile} requires its prepared calibration directory")
    if arguments.engine == "fgn" and (arguments.fgn_bundle is None or not arguments.fgn_bundle.is_file()):
        raise ValueError("FGN requires a built scientific bundle file")
    if arguments.engine == "jfg" and (arguments.jfg_root is None or not arguments.jfg_root.is_dir()):
        raise ValueError("JFG requires its maintained scientific owner root")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rtc-export-", dir=output.parent) as temporary:
        package = Path(temporary) / "package"
        package.mkdir()
        graph, parameters, science = prepare_science(arguments, package)
        name = f"revolt-{arguments.profile}-{arguments.engine}-{arguments.mode}"
        graph_name = name + "-graph"
        owners = []
        placements = {"core": placement([2, 8, 12, 14], [2, 8, 12]),
                      "rtc": placement([2, 14], [2])}
        clients = {"core": "client-rtc.conf.in", "rtc": "client-rtc.conf.in"}
        if arguments.engine == "fgn":
            copy_file(arguments.fgn_bundle, package / "lib" / arguments.fgn_bundle.name)
            graph = native_graph(graph, parameters, arguments.profile, graph_name)
        else:
            owner, graph = julia_owner(arguments, package, parameters, graph_name)
            owners.append(owner)
            placements["rtc"] = placement([2, 14], [])
            placements["julia"] = placement([4, 10, 14], [4], julia=True)
            clients["julia"] = "client-julia.conf.in"
        (package / "graphs").mkdir()
        (package / "graphs/graph.conf.in").write_text(graph)
        reconstructor = next(parameter for parameter in parameters if parameter.name == "reconstructor")
        detector_profile = science.get("prepared_profile", {}).get("detector_profile")
        write_json(package / "session.conf.in", session(arguments, reconstructor, graph_name, detector_profile))
        for template in {"core.conf.in", *clients.values()}:
            copy_file(ROOT / "templates" / template, package / template)
        copy_file(arguments.rtc_binary, package / "bin/pipewireao-rtc")
        science.update({"profile": arguments.profile, "engine": arguments.engine, "mode": arguments.mode,
                        "rtc_revision": revision(ROOT.parent),
                        "exporter_sha256": sha256(Path(__file__).resolve()),
                        "parameter_initialization": "owner-preload",
                        "algorithms_revision": revision(arguments.algorithms_root),
                        "algorithms_generator_sha256": sha256(arguments.algorithms_root / "scripts" / (science["generator"] + ".py")),
                        "parameters": [asdict(parameter) for parameter in parameters],
                        "runtime_requires": ["selected PipeWireAO prefix", "recorded FITS input"]})
        if arguments.engine == "jfg":
            science["jfg_revision"] = revision(arguments.jfg_root)
            science["runtime_requires"].append("instantiated jfg/deployment Project/Manifest dependencies")
            science["julia_version"] = subprocess.check_output([owners[0]["argv"][0], "--version"], text=True, timeout=10).strip()
        write_json(package / "provenance.json", science)
        artifacts = {str(path.relative_to(package)): sha256(path) for path in sorted(package.rglob("*")) if path.is_file()}
        specification = {"version": 1, "name": name, "session": "session.conf.in", "core": "core.conf.in",
                         "client": clients, "placement": placements, "owners": owners,
                         "environment": {"PIPEWIREAO_RTC_GRAPH_DEPLOYMENT": "@RUNTIME@/graph.conf",
                                         "PIPEWIREAO_RTC_PARAMETER_RECONSTRUCTOR": "@PACKAGE@/calibration/" + reconstructor.file},
                         "artifacts": artifacts, "cpu-latency-us": None}
        write_json(package / "deployment.conf", specification)
        package.rename(output)
    return output / "deployment.conf"


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=("classic", "copper"), required=True)
    parser.add_argument("--engine", choices=("fgn", "jfg"), required=True)
    parser.add_argument("--mode", choices=("frame", "row"), required=True)
    parser.add_argument("--rate-hz", type=int, required=True)
    parser.add_argument("--readout-us", type=int, required=True)
    parser.add_argument("--algorithms-root", type=Path, required=True)
    parser.add_argument("--jfg-root", type=Path)
    parser.add_argument("--fgn-bundle", type=Path)
    parser.add_argument("--classic-calibration", type=Path)
    parser.add_argument("--copper-calibration", type=Path)
    parser.add_argument("--rtc-binary", type=Path, required=True)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    try:
        print(export(arguments(argv)))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"export rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
