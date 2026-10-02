#!/usr/bin/env python3
"""Compose a simulated-offset AOS package with unchanged HEART and SPA UDP bridges."""
from __future__ import annotations

import argparse
import array
import copy
import importlib.util
import json
import math
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile

import yaml

import deploy
import export as science
from export_hil import copy_package

ROOT = Path(__file__).resolve().parent
RAW_SCHEMA = "org.heart.std-wfs.raw-pixels/1"
COMMAND_SCHEMA = "org.heart.std-dm.actuator-command/1"
WORKERS = {"HOP0.wfs.w": 4, "HOP0.proc.w": 6, "HOP0.recon.w": 8,
           "WCC.tfc.w": 10, "WCC.clwc.w": 10, "WCC.dm0.w": 14}


def readout_interval(instrument: str, requested: int | None, rate: int) -> int:
    # These are the selected finite CPU fixture settings, not a camera model
    # or a proven minimum inter-packet delay for HEART.
    readout = (2000 if instrument == "copper" else 0) if requested is None else requested
    if type(rate) is not int or rate <= 0:
        raise ValueError("wall rate must be a positive integer")
    if type(readout) is not int or not 0 <= readout * rate < 950000:
        raise ValueError("readout must be nonnegative and below 95% of the frame period")
    return readout


def classic_config_helper():
    path = ROOT.parent / "benchmark/prepare_classic_heart_config.py"
    spec = importlib.util.spec_from_file_location("prepare_classic_heart_config", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_offset_fits(source: Path, destination: Path, shape: list[int]) -> None:
    """Wrap the existing ROW_MAJOR F32 payload in a primary floating FITS image."""
    data = source.read_bytes()
    if len(data) != 4 * math.prod(shape):
        raise ValueError("offset extent differs from its declared shape")
    values = array.array("f", data)
    if sys.byteorder != "little":
        values.byteswap()
    if not all(math.isfinite(value) for value in values):
        raise ValueError("offset contains nonfinite values")
    cards = [("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", str(len(shape)))]
    cards += [(f"NAXIS{index}", str(value)) for index, value in enumerate(reversed(shape), 1)]
    header = "".join(f"{name:<8}= {value:>20}".ljust(80) for name, value in cards) + "END".ljust(80)
    encoded = header.encode("ascii")
    payload = b"".join(struct.pack(">f", value) for value in values)
    destination.write_bytes(encoded + b" " * (-len(encoded) % 2880) + payload + b"\0" * (-len(payload) % 2880))


def normalize_aliases(text: str) -> str:
    """Remove only byte-identical duplicate aliases in the maintained Copper template."""
    lines, aliases = [], {}
    in_aliases = False
    for line in text.splitlines(keepends=True):
        if re.match(r"^- ALIASES:", line):
            in_aliases = True
        elif re.match(r"^- [A-Z_]+:", line):
            in_aliases = False
        match = re.match(r"\s*([A-Z_]+):\s*&", line) if in_aliases else None
        if match:
            key = match.group(1)
            if key in aliases:
                if line.strip() != aliases[key]:
                    raise ValueError(f"conflicting duplicated HEART alias: {key}")
                continue
            aliases[key] = line.strip()
        lines.append(line)
    return "".join(lines)


def prepare_heart_configuration(package: Path, base: Path, source: Path,
                                calibration_root: Path, rate: int) -> dict:
    provenance = json.loads((base / "provenance.json").read_text())
    instrument = provenance["profile"]
    helper = classic_config_helper()
    if instrument == "classic":
        text, prepared = helper.prepare_config(source, calibration_root, 1 / rate)
    else:
        text = normalize_aliases(helper._yaml_text(source))
        prepared = {"runtime_requirements": [], "calibrations": {}}
    document = yaml.load(text, Loader=helper.UniqueLoader)
    sections = {next(iter(entry)): next(iter(entry.values())) for entry in document}
    ho, dm = sections["HO"], sections["DM"]
    shape = [352, 352] if instrument == "classic" else [64, 64]
    detector = ho["WFS_SIZE"]
    if (len(detector) != 1 or detector[0]["WFS_NUM"] != 0
            or [detector[0]["ROWS"], detector[0]["COLS"]] != shape
            or ho["WFS_TYPE"] != (0 if instrument == "classic" else 1)):
        raise ValueError("HEART template detector differs from the simulated profile")
    if dm["PDM_COUNT"] != 1 or dm["PDM_SIZES"] != [{"PDM_NUM": 0, "SIZE": 277}]:
        raise ValueError("HEART template requires one 277-actuator PDM")
    calibration = package / "heart/calibration"
    calibration.mkdir(parents=True)
    generated = provenance["hil"]["simulated_calibration"]["artifacts"]
    background = generated["background"]
    write_offset_fits(base / "hil" / background["path"], calibration / "simulated-background.fits", shape)
    ho["BIAS_FILE"] = [{"WFS_NUM": 0, "FILE": "./config/simulated-background.fits"}]
    # No recorded dark/sky/gain offsets may survive into the simulated detector.
    for key in ("DARK_FILE", "SKY_FILE", "FLAT_FILE"):
        ho.pop(key, None)
    if instrument == "classic":
        descriptor = generated["reference_slopes"]
        write_offset_fits(base / "hil" / descriptor["path"], calibration / "simulated-references.fits", [188, 2])
        ho["NCPA_GRADS_FILE"] = [{"WFS_NUM": 0, "FILE": "./config/simulated-references.fits"}]
    else:
        ho["NCPA_GRADS_FILE"] = [{"WFS_NUM": 0, "FILE": ""}]
    dm["PDM_SYS_FLAT_FILE"] = [{"PDM_NUM": 0, "FILE": ""}]
    dm["PDM_OFFSETS_FILE"] = [{"PDM_NUM": 0, "FILE": ""}]
    sections["TFC"]["TFC_HO_NCPA_REF_VEC_FILEPATH"] = ""
    hardware = ho["WFS_HARDWARE"][0]
    hardware.update(DETECTOR_TYPE=1, CONNECTION_STR=":6000", FPS=float(rate),
                    EXPOSURE_TIME=provenance["hil"]["exposure_ns"] / 1e6, GAIN=1.0, TRIG_TYPE=0)
    dm["PDM_HARDWARE"][0].update(WC_TYPE=1, CONNECTION_STR=":6100", SCALE_FACTOR=1.0, BYTE_ORDER=0)
    for key in ("TELEMETRY_FILE_STREAMS", "TELEMETRY_SOCKET_STREAMS"):
        sections["CB"].pop(key, None)
    # Snapshot only calibration files referenced by the actual native configuration.
    retained = {}
    def files(value):
        if isinstance(value, list):
            for child in value: files(child)
        elif isinstance(value, dict):
            for key, child in value.items():
                if (key == "FILE" or key.endswith("_FILE") or key.endswith("FILEPATH")) and isinstance(child, str) and child:
                    target = calibration / Path(child).name
                    if not target.exists():
                        original = Path(child) if Path(child).is_absolute() else calibration_root / child
                        original = original.resolve(strict=True)
                        if not original.is_relative_to(calibration_root.resolve()) or not original.is_file():
                            raise ValueError(f"native calibration escapes its root: {child}")
                        shutil.copy2(original, target)
                        retained[str(original)] = science.sha256(original)
                    elif target.name not in ("simulated-background.fits", "simulated-references.fits"):
                        original = Path(child) if Path(child).is_absolute() else calibration_root / child
                        if science.sha256(original.resolve(strict=True)) != science.sha256(target):
                            raise ValueError(f"native calibration basename collision: {child}")
                    value[key] = "./config/" + target.name
                else: files(child)
    for name, value in sections.items():
        if name != "ALIASES": files(value)
    # Use the maintained line-oriented emitter; generic YAML is incompatible with daoConfig.
    normalized = package / "heart/source-normalized.yaml"
    normalized.write_text(normalize_aliases(helper._yaml_text(source)))
    (package / "heart/config.yaml.in").write_text(helper.serialize_config(document, normalized))
    normalized.unlink()
    if not prepared["runtime_requirements"]:
        prepared["runtime_requirements"] = [{"block": "clwcBlock", "control": "ENABLE_HRT_FLAGS", "flags": {
            "enableClippingFeedback": 1, "enableNotClearingIntg": 0, "enableFigureDmVector": 0,
            "enableDmOffset": 0, "enableDmDisturbance": 0, "enableDmDither": 0,
            "enableLoCmdAggre": 0, "enableWCOptimize": 0, "enableUnctrlModeFeedback": 0,
            "enablePOLFeedback": 0}}, {"block": "tfcBlock", "control": "ENABLE_HRT_FLAGS", "flags": {"enableInHoVect": 1, "enableOutDmErrs": 1, "enablePOLFeedback": 0}}]
    science.write_json(package / "heart/requirements.json", prepared)
    return {"source_configuration": str(source), "source_sha256": science.sha256(source),
            "retained_calibration": retained, "generated_offsets": generated,
            "command_convention": "matched numerical command interpreted as OPD; physical calibration unqualified",
            "static_offset": "zero simulated figure; empty native flat/offset files",
            "detector_roi": {"row": detector[0]["FIRSTROW"], "column": detector[0]["FIRSTCOL"]}}


def bridge_session(instrument: str, rate: int) -> dict:
    shape = [352, 352] if instrument == "classic" else [64, 64]
    def node(name, port, direction, element, shape, schema):
        return {"ownership": "external", "node.name": name, "ports": [{"name": port,
                "direction": direction, "element-type": element, "shape": shape, "schema": schema,
                "rate": f"{rate}/1"}]}
    return {"profile": "development", "execution": "external-rtc", "authority": "none",
            "claim": "development-characterization", "rate": f"{rate}/1",
            "sources": [node("simulator-wfs", "output_1", "output", "U16_LE", shape, RAW_SCHEMA),
                        node("heart-dm-source", "command", "output", "F32_LE", [277], COMMAND_SCHEMA)],
            "graphs": [], "sinks": [node("heart-wfs-sink", "frame", "input", "U16_LE", shape, RAW_SCHEMA),
                                     node("simulator-command", "input_1", "input", "F32_LE", [277], COMMAND_SCHEMA)],
            "execution-groups": [], "properties": {}, "parameters": {}, "observations": [],
            "links": [{"output": "simulator-wfs:output_1", "input": "heart-wfs-sink:frame", "passive": False},
                      {"output": "heart-dm-source:command", "input": "simulator-command:input_1", "passive": False}]}


def export(args):
    base, output = args.base_package.resolve(), args.output.resolve()
    specification = deploy.profile(base / "deployment.conf", args.pipewire_prefix)
    provenance = json.loads((base / "provenance.json").read_text())
    if provenance.get("engine") != "fgn" or provenance.get("hil", {}).get("backend") != "cpu":
        raise ValueError("initial HEART HIL export requires a corrected FGN CPU HIL base")
    instrument = provenance["profile"]
    if instrument not in ("classic", "copper") or "simulated_calibration" not in provenance["hil"]:
        raise ValueError("HEART requires a maintained simulated-offset calibration base")
    rate = provenance["hil"]["wall_rate_hz"]
    readout_us = readout_interval(instrument, args.readout_us, rate)
    if output.exists(): raise ValueError("export output must be new")
    paths = deploy.installed_paths(args.pipewire_prefix)
    plugin = paths["spa"] / "heart/libspa-heart.so"
    if not plugin.is_file(): raise ValueError("installed HEART SPA plugin is missing")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rtc-heart-export-", dir=output.parent) as temporary:
        package = Path(temporary) / "package"
        shutil.copytree(base, package, ignore=shutil.ignore_patterns("__pycache__", "systemd"))
        for name in ("pipewireao-rtc-deploy", "placement.py", "pipewireao-rtc@.service.in"):
            (package / "bin" / name).unlink(missing_ok=True)
        shutil.rmtree(package / "graphs")
        (package / "heart/bin").mkdir(parents=True)
        for name in ("scaoTemplate", "scaoTemplateCmdClient"):
            source = args.heart_root / "source/template/bin" / name
            if not source.is_file() or not source.stat().st_mode & 0o111:
                raise ValueError(f"missing native HEART executable: {source}")
            shutil.copy2(source, package / "heart/bin" / name)
        shutil.copy2(args.rtc_binary, package / "bin/pipewireao-rtc")
        for name in ("simulator.jl", "owner_protocol.jl", "heart_owner.py"):
            shutil.copy2(ROOT / "hil" / name, package / "hil" / name)
        if args.adapter_root is not None:
            adapter = args.adapter_root.resolve(strict=True)
            installed_adapter = package / "hil/packages/AdaptiveOpticsSimPipeWireHIL"
            if (adapter / "Project.toml").read_bytes() != (installed_adapter / "Project.toml").read_bytes():
                raise ValueError("adapter override requires the base package's exact dependency declaration")
            shutil.rmtree(installed_adapter)
            copy_package(adapter, installed_adapter)
            provenance["hil"]["adapter_revision"] = science.revision(adapter)
            provenance["hil"]["adapter_source"] = str(adapter)
        config = prepare_heart_configuration(package, base, args.heart_source_config.resolve(),
                                            args.calibration_root.resolve(), rate)
        science.write_json(package / "session.conf.in", bridge_session(instrument, rate))
        core = deploy.decode(package / specification["core"], args.pipewire_prefix)
        core["context.spa-libs"]["api.heart.*"] = "heart/libspa-heart"
        shape = 352 if instrument == "classic" else 64
        rows = 11 if instrument == "classic" else 32
        core["context.objects"] += [{"factory": "spa-node-factory", "args": {
            "factory.name": "api.heart.std-wfs.sink", "node.name": "heart-wfs-sink",
            "node.loop.name": "rtc-data-loop", "node.virtual": True, "object.linger": True,
            "api.heart.std-wfs.destination-address": "127.0.0.1", "api.heart.std-wfs.port": 6000,
            "api.heart.std-wfs.source": 0, "api.heart.std-wfs.pixel-type": "raw",
            "api.heart.std-wfs.width": shape, "api.heart.std-wfs.height": shape,
            "api.heart.std-wfs.roi-row-offset": config["detector_roi"]["row"],
            "api.heart.std-wfs.roi-column-offset": config["detector_roi"]["column"],
            "api.heart.std-wfs.frame-rate": f"{rate}/1", "api.heart.std-wfs.network-byte-order": False,
            "api.heart.std-wfs.pixels-per-datagram": rows * shape,
            "api.heart.std-wfs.rows-per-datagram": True, "api.heart.std-wfs.readout-time": readout_us}},
            {"factory": "spa-node-factory", "args": {"factory.name": "api.heart.std-dm.source",
            "node.name": "heart-dm-source", "node.loop.name": "rtc-data-loop", "node.virtual": True,
            "object.linger": True, "api.heart.std-dm.bind-address": "127.0.0.1",
            "api.heart.std-dm.port": 6100, "api.heart.std-dm.target-id": 0,
            "api.heart.std-dm.actuator-count": 277, "api.heart.std-dm.frame-rate": f"{rate}/1"}}]
        science.write_json(package / specification["core"], core)
        # The external RTC's Rust process owns links and controls only. It has
        # no scientific data-loop worker to inherit from the FGN base profile.
        rtc_client = deploy.decode(package / specification["client"]["rtc"], args.pipewire_prefix)
        rtc_client["context.properties"].pop("context.data-loops", None)
        rtc_client["context.modules"] = [module for module in rtc_client["context.modules"]
                                         if module["name"] != "libpipewire-module-rt"]
        science.write_json(package / "client-heart-rtc.conf.in", rtc_client)
        specification["client"]["rtc"] = "client-heart-rtc.conf.in"
        specification["placement"]["rtc"] = {
            "cpus": [14], "leader-cpu": 14, "rt-priority": 0,
            "threads": [], "locked-bytes": 0}
        cpu = (ROOT.parent / "benchmark/profiles/ryzen-6800h-classic.cpu").read_text()
        # Retain the established single-worker stages while assigning separate simulator/bridge cores.
        replacement = {"HOP0.wfs.w": "4", "HOP0.proc.w": "6", "HOP0.recon.w": "8",
                       "WCC.tfc.w": "10", "WCC.clwc.w": "10", "WCC.dm0.w": "14",
                       "HOP0.wfs.pxStat": "3", "HOP0.proc.gOpt": "3", "WCC.clwc.pdm0": "3",
                       "HOP0": "4, 6, 8", "WCC": "10, 14", "CMDS": "3", "TELM": "3", "MON": "3"}
        for name, cpus in replacement.items():
            cpu, count = re.subn(r"(?m)^" + re.escape(name) + r"\s*=\s*\{[^}]*\}", name + " = { " + cpus + " }", cpu)
            if count != 1: raise ValueError(f"expected one native CPU group: {name}")
        (package / "heart/host.cpu").write_text(cpu)
        shutil.copy2(ROOT.parent / "benchmark/profiles/ryzen-6800h-classic.threads", package / "heart/host.threads")
        science.write_json(package / "heart/placement.json", {"cpus": [3,4,6,8,10,14],
            "allowed_priorities": [5,10,15,20], "workers": [{"name": name, "cpus": [cpu], "policy": 1, "priority": 15} for name,cpu in WORKERS.items()]})
        markers = {name: "heart." + name for name in ("prepared", "connect", "connected", "quit")}
        argv = [sys.executable, "@PACKAGE@/hil/heart_owner.py", "--executable", "@PACKAGE@/heart/bin/scaoTemplate",
                "--client", "@PACKAGE@/heart/bin/scaoTemplateCmdClient", "--config", "@PACKAGE@/heart/config.yaml.in",
                "--runtime", "@RUNTIME@/heart/native", "--cpu-map", "@PACKAGE@/heart/host.cpu",
                "--thread-map", "@PACKAGE@/heart/host.threads", "--requirements", "@PACKAGE@/heart/requirements.json",
                "--calibration-root", "@PACKAGE@/heart/calibration", "--placement", "@PACKAGE@/heart/placement.json",
                "--control-request", "@RUNTIME@/heart.control.request", "--control-reply", "@RUNTIME@/heart.control.reply"]
        for option,key in (("--prepared-event","prepared"),("--connect-request","connect"),("--connect-reply","connected"),("--quit-request","quit")):
            argv += [option, "@RUNTIME@/" + markers[key]]
        simulator = copy.deepcopy(specification["owners"][0])
        simulator["argv"] += ["--transport", "heart", "--controller-request", "@RUNTIME@/heart.control.request",
                              "--controller-reply", "@RUNTIME@/heart.control.reply"]
        specification["owners"] = [{"role":"heart", "argv":argv, "environment":{
            "HRT_MEMORY_HUGEPAGES":"0", "HRT_DEFER_WFS_INGRESS":"0"}, **markers}, simulator]
        specification["placement"]["simulator"] = {"cpus":[12], "leader-cpu":12, "rt-priority":0, "threads":[], "locked-bytes":0}
        specification["placement"]["heart"] = {"cpus":[3,4,6,8,10,14], "leader-cpu":3, "rt-priority":0, "threads":[], "locked-bytes":0}
        specification["client"]["heart"] = "client-simulator.conf.in"
        specification["environment"] = {}
        specification["name"] = f"revolt-{instrument}-heart-hil-cpu"
        provenance["engine"] = "heart"
        provenance["hil"].update(command_unit="metre OPD", plant_command_scale=1.0, transport="heart")
        provenance["heart"] = {**config, "revision":science.revision(args.heart_root), "plugin_sha256":science.sha256(plugin),
                               "readout_us":readout_us,"packet_rows":rows,
                               "numeric_equivalence":"not established by finite HIL deployment"}
        science.write_json(package / "provenance.json", provenance)
        specification["artifacts"] = {str(p.relative_to(package)):science.sha256(p) for p in sorted(package.rglob("*")) if p.is_file() and p.name != "deployment.conf"}
        science.write_json(package / "deployment.conf", specification)
        deploy.profile(package / "deployment.conf", args.pipewire_prefix)
        package.rename(output)
    return output / "deployment.conf"


def arguments(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ("base-package","output","heart-root","heart-source-config","calibration-root"):
        parser.add_argument("--"+name, type=Path, required=True)
    parser.add_argument("--rtc-binary",type=Path,default=ROOT.parent/'target/release/pipewireao-rtc')
    parser.add_argument("--pipewire-prefix",type=Path,default=Path('/opt/pipewireao'))
    parser.add_argument("--readout-us", type=int,
                        help="packet readout interval; defaults to 0 us for Classic, 2000 us for Copper")
    parser.add_argument("--adapter-root", type=Path,
                        help="snapshot a compatible transport adapter into the base's resolved environment")
    return parser.parse_args(argv)


if __name__=='__main__':
    print(export(arguments()))
