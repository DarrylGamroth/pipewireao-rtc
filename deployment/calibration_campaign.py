#!/usr/bin/env python3
"""Run finite Classic calibration stages through public deployed endpoints."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
from types import SimpleNamespace
import tomllib

import deploy
import export as science
import export_calibration
import export_hil

PAYLOAD_BYTES = 250252
CHANNELS = {
    "raw": ("U16_LE", [352, 352], 247808),
    "slopes": ("F32_LE", [188, 2], 1504),
    "flux": ("F32_LE", [188], 752),
    "validity": ("BOOL8", [188], 188),
}
COPPER_CHANNELS = {
    "raw": ("U16_LE", [64, 64], 8192),
    "pixels": ("F32_LE", [4, 900], 14400),
    "intensity": ("F32_LE", [1], 4),
}
CAPTURE_FILENAMES = {
    "raw": "raw.u16le", "slopes": "slopes.f32le", "flux": "flux.f32le",
    "validity": "validity.u8", "pixels": "pixels.f32le", "intensity": "intensity.f32le",
}


def capture_contract(profile):
    """Select the caller-declared capture contract, never the incoming manifest."""
    if profile == "classic":
        return CHANNELS, PAYLOAD_BYTES
    if profile == "copper":
        return COPPER_CHANNELS, 22596
    raise ValueError("capture requires the declared Classic or Copper profile")


def digest(path):
    return science.sha256(Path(path))


def positive_integer(value, name, maximum):
    if type(value) is not int or not 1 <= value <= maximum:
        raise ValueError(f"{name} must be an integer in 1..{maximum}")
    return value


def wire_float32(value):
    converted = struct.unpack("<f", struct.pack("<f", value))[0]
    if not math.isfinite(converted) or value != 0 and converted == 0:
        raise ValueError("command value is not representable as finite non-underflowed Float32")
    return converted


def same_figure(first, second):
    return len(first) == len(second) and all(struct.pack("<f", x) == struct.pack("<f", y)
                                           for x, y in zip(first, second))


def validate_recipe(recipe):
    fields = {"version", "dark_frames", "training_frames", "qualification_frames", "seeds",
              "lamp_magnitude", "candidate_mask", "minimum_flux", "adc_upper_rail",
              "maximum_reference_residual", "reference", "amplitudes", "frames_per_probe",
              "settling", "request_timeout_ns", "stage_timeout_seconds"}
    if set(recipe) != fields or type(recipe["version"]) is not int or recipe["version"] != 1:
        raise ValueError("unsupported or incomplete campaign recipe")
    for name in ("dark_frames", "training_frames", "qualification_frames"):
        if not 2 <= positive_integer(recipe[name], name, 64):
            raise ValueError(f"{name} requires at least two samples")
    positive_integer(recipe["frames_per_probe"], "frames_per_probe", 64)
    positive_integer(recipe["request_timeout_ns"], "request_timeout_ns", 30_000_000_000)
    positive_integer(recipe["stage_timeout_seconds"], "stage_timeout_seconds", 3600)
    seeds = recipe["seeds"]
    if set(seeds) != {"dark", "training", "qualification", "interaction"}:
        raise ValueError("declare all four detector seeds")
    for value in seeds.values():
        if type(value) is not int or not 0 <= value <= 2**32 - 1:
            raise ValueError("detector seeds must be UInt32 integers")
    if len(set(seeds.values())) != 4:
        raise ValueError("stage detector samples require four distinct seeds")
    if len(recipe["candidate_mask"]) != 188 or not all(type(x) is bool for x in recipe["candidate_mask"]) or not any(recipe["candidate_mask"]):
        raise ValueError("declare a nonempty 188-position candidate mask")
    for field, count in (("minimum_flux", 188), ("reference", 277), ("amplitudes", 277)):
        values = recipe[field]
        if len(values) != count or not all(type(x) in (int, float) and math.isfinite(x) for x in values):
            raise ValueError(f"{field} requires {count} finite numbers")
        if field != "reference" and not all(x > 0 for x in values):
            raise ValueError(f"{field} must be positive")
    for field in ("lamp_magnitude", "maximum_reference_residual"):
        if type(recipe[field]) not in (int, float) or not math.isfinite(recipe[field]):
            raise ValueError(f"{field} must be finite")
    if recipe["maximum_reference_residual"] <= 0:
        raise ValueError("maximum_reference_residual must be positive detector pixels")
    positive_integer(recipe["adc_upper_rail"], "adc_upper_rail", 65535)
    recipe = copy.deepcopy(recipe)
    recipe["reference"] = [wire_float32(x) for x in recipe["reference"]]
    recipe["amplitudes"] = [wire_float32(x) for x in recipe["amplitudes"]]
    rule = recipe["settling"]
    if rule == {"kind": "immediate"}:
        pass
    elif set(rule) == {"kind", "frames"} and rule["kind"] == "discard_exposures":
        positive_integer(rule["frames"], "settling frames", 4096)
    elif set(rule) == {"kind", "duration_ns"} and rule["kind"] == "model_time":
        positive_integer(rule["duration_ns"], "settling duration", 2**63 - 1)
    else:
        raise ValueError("unsupported settling rule")
    return recipe


def validate_detector_rail(detector, recipe):
    """Require the declared calibration rail to match the deployed ADC."""
    if 2 ** detector["bits"] - 1 != recipe["adc_upper_rail"]:
        raise ValueError("declared ADC rail differs from deployed detector")


class Endpoint:
    """One pending request, one connection, finite I/O; never retry unknown effects."""
    def __init__(self, path, run, timeout_ns):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout_ns / 1e9)
        self.socket.connect(str(path))
        self.run, self.serial, self.timeout_ns = run, 0, timeout_ns
        self.records = []
        self.can_restore = False

    def request(self, action, expected):
        self.can_restore = False
        self.serial += 1
        request = {"version": 1, "run": self.run, "serial": self.serial,
                   "timeout_ns": self.timeout_ns, "action": action}
        payload = (json.dumps(request, allow_nan=False, separators=(",", ":")) + "\n").encode()
        if len(payload) > 16384:
            raise ValueError("request exceeds protocol limit")
        deadline = time.monotonic() + self.timeout_ns / 1e9
        self.socket.settimeout(max(0.0, deadline - time.monotonic()))
        self.socket.sendall(payload)
        reply = bytearray()
        while not reply.endswith(b"\n"):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("calibration request expired; outcome unknown")
            self.socket.settimeout(remaining)
            data = self.socket.recv(min(4096, 65537 - len(reply)))
            if not data or len(reply) + len(data) > 65536:
                raise ValueError("missing or oversized completion; outcome unknown")
            reply.extend(data)
        document = json.loads(reply)
        if time.monotonic() >= deadline:
            raise TimeoutError("late calibration completion; outcome unaccepted")
        if set(document) != {"version", "run", "serial", "result"} or any(
                type(document[key]) is not int or document[key] != request[key]
                for key in ("version", "run", "serial")):
            raise ValueError("uncorrelated completion; outcome unknown")
        self.records.append({"request": request, "reply": document})
        result = document["result"]
        if result.get("kind") == "failed":
            # The server promises invalid_evidence only before effects. Endpoint
            # failures retain fault/hold; they do not permit an operation retry.
            if set(result) == {"kind", "reason"} and result["reason"] == "invalid_evidence":
                if time.monotonic() >= deadline:
                    raise TimeoutError("calibration rejection validation expired")
                self.can_restore = True
            raise ValueError(f"calibration rejected {action['kind']}: {result}")
        fields = {
            "held": {"kind", "cursor"}, "adopted": {"kind", "cursor", "figure", "clipped"},
            "settled": {"kind", "cursor"}, "restored": {"kind", "figure", "clipped"},
            "released": {"kind"}, "captured": {"kind", "cursor", "manifest", "sha256", "frames", "bytes", "metadata_bytes"},
        }
        if result.get("kind") != expected or set(result) != fields[expected]:
            raise ValueError("malformed completion; outcome unknown")
        if "cursor" in result:
            cursor = result["cursor"]
            if set(cursor) != {"domain", "generation", "sequence", "model_ns"} or any(type(v) is not int or not 0 <= v < 2**64 for v in cursor.values()) or cursor["domain"] != 1 or cursor["generation"] < 1:
                raise ValueError("malformed cursor; outcome unknown")
        if "clipped" in result and (type(result["clipped"]) is not bool or not isinstance(result["figure"], list) or len(result["figure"]) != 277 or not all(type(x) in (int, float) and math.isfinite(x) for x in result["figure"])):
            raise ValueError("malformed command completion; outcome unknown")
        if time.monotonic() >= deadline:
            raise TimeoutError("calibration completion validation expired")
        self.can_restore = not (expected == "restored" and result["clipped"])
        return result

    def close(self):
        self.socket.close()


def verify_capture(root, completion, *, run, serial, stage, frames, after, startup,
                   profile="classic", probe=0):
    """Verify fixed-layout bulk evidence before any scientific consumption."""
    if type(probe) is not int or not 0 <= probe < 2**64:
        raise ValueError("expected probe must be a UInt64 integer")
    channels, payload_bytes = capture_contract(profile)
    if startup.get("profile") != profile:
        raise ValueError("capture startup differs from declared profile")
    for field in ("frames", "bytes", "metadata_bytes"):
        if type(completion[field]) is not int or completion[field] <= 0:
            raise ValueError("capture completion counts must be positive integers")
    relative = completion["manifest"]
    if relative != f"{serial}/manifest.json":
        raise ValueError("noncanonical capture path")
    path = root / relative
    size = path.stat().st_size
    if size != completion["metadata_bytes"] or size > 16384 + 4096 * frames:
        raise ValueError("capture metadata length mismatch")
    if any(p.is_symlink() for p in (root, root / str(serial), path)) or path.resolve().parent != (root / str(serial)).resolve() or digest(path) != completion["sha256"]:
        raise ValueError("capture manifest path or digest mismatch")
    manifest = json.loads(path.read_bytes())
    for name in ("version", "run", "serial", "probe", "frames", "bytes"):
        if type(manifest[name]) is not int:
            raise ValueError("capture header requires integer identities/counts")
    if (manifest["version"], manifest["run"], manifest["serial"], manifest["stage"], manifest["frames"]) != (1, run, serial, stage, frames):
        raise ValueError("capture identity mismatch")
    if manifest["probe"] != probe or manifest["profile"] != profile or manifest["illumination"] != startup["illumination"]:
        raise ValueError("capture stage settings mismatch")
    settings = {name: startup[name] for name in ("detector_config", "graph_sha256", "wfs_active_sha256")}
    if manifest["settings"] != settings or manifest["acquisition_domain_mapping"] != startup["acquisition_domain_mapping"]:
        raise ValueError("capture startup snapshot mismatch")
    if manifest["settings_sha256"] != startup["capture_settings_sha256"]:
        raise ValueError("capture settings digest mismatch")
    if completion["frames"] != frames:
        raise ValueError("capture payload budget mismatch")
    if manifest["bytes"] != frames * payload_bytes or completion["bytes"] != frames * payload_bytes:
        raise ValueError("capture length mismatch")
    if len(manifest["exposures"]) != frames:
        raise ValueError("capture sample count mismatch")
    domain = manifest["acquisition_domain_mapping"]
    if (type(domain["opaque_domain"]) is not int or domain["opaque_domain"] != 1 or
            len(domain["complete_domain"]) != 16 or not any(domain["complete_domain"]) or
            not all(type(value) is int and 0 <= value <= 255 for value in domain["complete_domain"])):
        raise ValueError("missing complete acquisition domain")
    expected_duration = round(startup["detector_config"]["exposure_duration_s"] * 1e9)
    if after["domain"] != 1 or after["generation"] != startup["acquisition_generation"]:
        raise ValueError("settled cursor differs from startup generation")
    previous = None
    for index, exposure in enumerate(manifest["exposures"], 1):
        if exposure["directory"] != str(index) or exposure["domain"] != 1 or exposure["generation"] < 1 or exposure["duration_ns"] < 1:
            raise ValueError("invalid exposure identity")
        if type(exposure["valid"]) is not bool:
            raise ValueError("invalid quality flag")
        if exposure["duration_ns"] != expected_duration:
            raise ValueError("capture exposure duration differs from detector configuration")
        for field in ("domain", "generation", "sequence", "start_model_ns", "duration_ns"):
            if type(exposure[field]) is not int or not 0 <= exposure[field] < 2**64:
                raise ValueError("invalid exposure integer fields")
        if index == 1 and (exposure["generation"] != after["generation"] or exposure["sequence"] != after["sequence"] + 1 or exposure["start_model_ns"] < after["model_ns"]):
            raise ValueError("capture does not follow settled cursor")
        if previous is not None and (exposure["generation"] != previous["generation"] or exposure["sequence"] != previous["sequence"] + 1 or exposure["start_model_ns"] < previous["start_model_ns"] + previous["duration_ns"]):
            raise ValueError("nonconsecutive or overlapping capture")
        previous = exposure
        if set(exposure["files"]) != set(channels):
            raise ValueError("missing capture channel")
        for name, (element, shape, size) in channels.items():
            record = exposure["files"][name]
            filename = CAPTURE_FILENAMES[name]
            payload = path.parent / str(index) / filename
            if record["path"] != filename or any(p.is_symlink() for p in (payload.parent, payload)) or (record["element_type"], record["shape"], record["layout"], record["bytes"]) != (element, shape, "ROW_MAJOR", size):
                raise ValueError("capture payload contract mismatch")
            if payload.stat().st_size != size or digest(payload) != record["sha256"]:
                raise ValueError("capture payload digest or length mismatch")
    final = {"domain": 1, "generation": previous["generation"], "sequence": previous["sequence"],
             "model_ns": previous["start_model_ns"] + previous["duration_ns"]}
    if completion["cursor"] != final or any(type(value) is not int for value in completion["cursor"].values()):
        raise ValueError("capture completion cursor mismatch")
    return manifest


def set_model_setting(text, node, field, value):
    sections = re.split(r"(?m)(?=^\[\[nodes\]\])", text)
    matches = [i for i, section in enumerate(sections) if re.search(rf'(?m)^name\s*=\s*"{re.escape(node)}"\s*$', section)]
    if len(matches) != 1:
        raise ValueError(f"expected one plant node {node}")
    index = matches[0]
    sections[index], count = re.subn(rf"(?m)^{re.escape(field)}\s*=\s*[^\n]+$", f"{field} = {value}", sections[index])
    if count != 1:
        raise ValueError(f"expected one {node}.{field}")
    return "".join(sections)


def stage_base(base, output, recipe, stage, background, references, active, aoc_source, prefix):
    """Prepare ordinary immutable startup arrays; original package stays untouched."""
    original = json.loads((base / "provenance.json").read_text())
    spec = deploy.profile(base / "deployment.conf", prefix)
    source = next(owner for owner in spec["owners"] if owner["role"] == spec["source-owner"])
    argv = source["argv"]
    if (original["profile"] != "classic" or original["mode"] != "frame" or
            original.get("hil", {}).get("backend") != "cpu" or argv.count("--backend") != 1 or
            argv[argv.index("--backend") + 1] != "cpu"):
        raise ValueError("automatic campaign currently requires complete-frame Classic CPU")
    shutil.copytree(base, output)
    provenance = copy.deepcopy(original)
    graph = deploy.decode(output / "graphs/graph.conf.in", prefix)
    wfs = next(node for node in graph["filter.graph"]["nodes"] if node["label"] == "shack-hartmann-image-f32")
    bindings = {item["name"]: item for item in provenance["parameters"] + provenance.get("construction_parameters", [])}
    for name, payload, expected in (("background", background, 495616), ("reference-slopes", references, 1504), ("active", active, 188)):
        if len(payload) != expected:
            raise ValueError(f"wrong startup extent for {name}")
        binding = bindings[name]
        (output / "calibration" / binding["file"]).write_bytes(payload)
        if "sha256" in binding:
            binding["sha256"] = digest(output / "calibration" / binding["file"])
    if "active" in wfs["config"]:
        wfs["config"]["active"] = [bool(value) for value in active]
    (output / "graphs/graph.conf.in").write_text(export_calibration.spa_json(graph) + "\n")
    model_path = output / "hil/plant.toml"
    model = set_model_setting(model_path.read_text(), "shwfs", "source_magnitude", recipe["lamp_magnitude"])
    model = set_model_setting(model, "detector", "rng_seed", recipe["seeds"][stage])
    detector = next(item for item in tomllib.loads(model)["nodes"] if item["name"] == "detector")["config"]
    validate_detector_rail(detector, recipe)
    model_path.write_text(model)
    target = output / "hil/packages/AdaptiveOpticsCalibration"
    shutil.rmtree(target)
    export_hil.copy_package(aoc_source, target)
    provenance["campaign_stage_inputs"] = {"stage": stage, "recipe": recipe,
        "source_deployment_sha256": digest(base / "deployment.conf"),
        "source_aoc_revision": science.revision(aoc_source),
        "source_aoc_files": {str(p.relative_to(target)): digest(p) for p in sorted(target.rglob("*")) if p.is_file()},
        "previous_offset_provenance": "historical base only; startup offsets replaced by campaign inputs"}
    science.write_json(output / "provenance.json", provenance)
    specification = json.loads((output / "deployment.conf").read_text())
    specification["artifacts"] = {str(p.relative_to(output)): digest(p) for p in sorted(output.rglob("*")) if p.is_file() and p.name != "deployment.conf"}
    science.write_json(output / "deployment.conf", specification)
    deploy.profile(output / "deployment.conf", prefix)
    return output


def wait_state(runtime, process, timeout, predicate):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state_path = runtime / "state.json"
        if state_path.is_file():
            state = json.loads(state_path.read_text())
            if state.get("pid") != process.pid:
                raise RuntimeError("runtime state belongs to a different launcher")
            if process.poll() is not None:
                raise RuntimeError("owned deployment exited before completion")
            if predicate(state):
                return state
            if state.get("error"):
                raise RuntimeError(f"deployment failed: {state['error']}")
        if process.poll() is not None:
            raise RuntimeError("deployment exited before required completion")
        time.sleep(0.025)  # Lifecycle readiness polling; never exposure/settling evidence.
    raise TimeoutError("deployment lifecycle deadline")


def validate_batches(batches):
    """Validate the finite wire commands before any output or owner is created."""
    if not isinstance(batches, list) or not 1 <= len(batches) <= 32:
        raise ValueError("batches require a list of 1..32 captures")
    result = []
    for batch in batches:
        if not isinstance(batch, dict) or set(batch) != {"figure", "frames"}:
            raise ValueError("batch requires exactly figure and frames")
        if not isinstance(batch["figure"], list) or len(batch["figure"]) != 277:
            raise ValueError("batch figure requires 277 physical coordinates")
        try:
            figure = [wire_float32(value) for value in batch["figure"]
                      if type(value) in (int, float)]
        except (OverflowError, struct.error) as error:
            raise ValueError("batch figure must be representable as Float32") from error
        if len(figure) != 277:
            raise ValueError("batch figure requires 277 finite numeric coordinates")
        result.append({"figure": figure,
                       "frames": positive_integer(batch["frames"], "batch frames", 64)})
        if result[-1]["frames"] < 2:
            raise ValueError("batch frames require at least two exposures")
    return result


def run_stage(package, output, runtime, recipe, stage, *, frames=None, batches=None):
    """Finish restore/release/public shutdown before returning immutable evidence."""
    if batches is not None:
        if frames is not None:
            raise ValueError("frames and batches are mutually exclusive")
        batches = validate_batches(batches)
    capture_profile = None
    if frames is not None or batches is not None:
        capture_profile = json.loads((package / "provenance.json").read_text())["profile"]
        capture_contract(capture_profile)
    if batches is not None and capture_profile != "copper":
        raise ValueError("batched capture requires Copper")
    if batches is not None:
        provenance = json.loads((package / "provenance.json").read_text())
        required = sum(batch["frames"] * capture_contract("copper")[1] for batch in batches)
        if provenance.get("capture_max_payload_bytes") != required:
            raise ValueError("exported capture budget differs from all batches")
    stage_started_ns = time.perf_counter_ns()
    stage_deadline = time.monotonic() + recipe["stage_timeout_seconds"] if batches is not None else None
    def remaining(limit):
        if stage_deadline is None:
            return limit
        value = min(limit, stage_deadline - time.monotonic())
        if value <= 0:
            raise TimeoutError("batched stage deadline expired")
        return value
    launcher = Path(deploy.__file__).resolve()
    common = [sys.executable, str(launcher), "control", "--runtime", str(runtime), "--"]
    env = {**os.environ, "OPENBLAS_NUM_THREADS": "1"}
    env.pop("PIPEWIRE_DEBUG", None)
    env.pop("PIPEWIREAO_DEBUG", None)
    command = [sys.executable, str(launcher), "run", "--deployment", str(package / "deployment.conf"),
               "--runtime", str(runtime), "--pipewire-prefix", "/opt/pipewireao"]
    output.mkdir()
    if runtime.exists() or runtime.is_symlink():
        raise ValueError("each campaign stage requires a fresh runtime directory")
    endpoint = None
    result = {"stage": stage, "run_argv": command, "restoration_confirmed": False,
              "release_confirmed": False, "shutdown_confirmed": False,
              "timing_ns": {"startup_readiness": None, "acquisition": None,
                            "public_shutdown": None, "total_stage": None},
              "timing_confirmed": {"startup_readiness": False, "acquisition": False,
                                    "public_shutdown": False}}
    process = None
    acquisition_started_ns = shutdown_started_ns = None
    with (output / "deployment.log").open("w") as log:
        startup_started_ns = time.perf_counter_ns()
        try:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            ready = wait_state(runtime, process, remaining(recipe["stage_timeout_seconds"]), lambda state: state.get("phase") == "running")
            ready_ns = time.perf_counter_ns()
            result["timing_ns"]["startup_readiness"] = ready_ns - startup_started_ns
            result["timing_confirmed"]["startup_readiness"] = True
            acquisition_started_ns = ready_ns
            instance = Path(ready["socket"]).parent
            result["ready"] = ready
            result["startup_report"] = json.loads((instance / "simulator-result.json").read_text())
            if frames is not None or batches is not None:
                endpoint = Endpoint(instance / "calibration.sock", 1,
                                    min(recipe["request_timeout_ns"],
                                        max(1, int(remaining(recipe["request_timeout_ns"] / 1e9) * 1e9)))
                                    if batches is not None else recipe["request_timeout_ns"])
                def request(action, expected):
                    if batches is not None:
                        endpoint.timeout_ns = min(recipe["request_timeout_ns"],
                                                  max(1, int(remaining(recipe["request_timeout_ns"] / 1e9) * 1e9)))
                    return endpoint.request(action, expected)
                held = request({"kind": "hold"}, "held")
                commands = batches if batches is not None else [{"figure": recipe["reference"], "frames": frames}]
                previous = held["cursor"]
                captures = result.setdefault("captures", []) if batches is not None else []
                if batches is not None:
                    (output / "captured").mkdir()
                for probe, batch in enumerate(commands):
                    adopted = request({"kind": "adopt", "probe": probe, "figure": batch["figure"]}, "adopted")
                    if adopted["clipped"] or not same_figure(adopted["figure"], batch["figure"]) or previous != adopted["cursor"]:
                        raise ValueError("figure adoption clipped or changed cursor")
                    settled = request({"kind": "settle", "probe": probe, "after": adopted["cursor"], "rule": recipe["settling"]}, "settled")
                    capture = request({"kind": "capture", "probe": probe, "after": settled["cursor"], "frames": batch["frames"]}, "captured")
                    captures.append({"probe": probe, "serial": endpoint.serial if batches is not None else 4,
                                     "figure": batch["figure"],
                                     "settled_cursor": settled["cursor"], "completion": capture})
                    if batches is not None:
                        serial = captures[-1]["serial"]
                        shutil.copytree(instance / "captured" / str(serial), output / "captured" / str(serial))
                        verify_capture(output / "captured", capture, run=1, serial=serial,
                                       stage=stage, frames=batch["frames"], after=settled["cursor"],
                                       startup=result["startup_report"], profile=capture_profile, probe=probe)
                        remaining(recipe["stage_timeout_seconds"])
                        previous = capture["cursor"]
                restored = request({"kind": "restore", "figure": recipe["reference"], "rule": recipe["settling"]}, "restored")
                if restored["clipped"] or not same_figure(restored["figure"], recipe["reference"]):
                    raise ValueError("reference restoration clipped or changed")
                result["restoration_confirmed"] = True
                request({"kind": "release"}, "released")
                result["release_confirmed"] = True
                result["timing_ns"]["acquisition"] = time.perf_counter_ns() - acquisition_started_ns
                result["timing_confirmed"]["acquisition"] = True
                result["requests"] = endpoint.records
                endpoint.close()
                endpoint = None
                remaining(recipe["stage_timeout_seconds"])
                if batches is None:
                    shutil.copytree(instance / "captured", output / "captured")
                    for item, batch in zip(captures, commands):
                        verify_capture(output / "captured", item["completion"], run=1,
                                       serial=item["serial"], stage=stage, frames=batch["frames"],
                                       after=item["settled_cursor"], startup=result["startup_report"],
                                       profile=capture_profile, probe=item["probe"])
                remaining(recipe["stage_timeout_seconds"])
                if batches is None:
                    result["capture"] = capture
            else:
                response = subprocess.run([str(package / "bin/rtc-calibrate"), "--endpoint", str(instance / "calibration.sock"), "--plan", str(output.parent / "interaction-plan.json")], env=env, capture_output=True, text=True, timeout=recipe["stage_timeout_seconds"])
                (output / "rtc-calibrate.json").write_text(response.stdout)
                (output / "rtc-calibrate.stderr").write_text(response.stderr)
                response.check_returncode()
                matrix_result = json.loads(response.stdout)
                if matrix_result["phase"] != "complete" or matrix_result["failure"] is not None or matrix_result["recovery_failure"] is not None or not matrix_result["restoration_confirmed"] or not matrix_result["resume_permitted"]:
                    raise ValueError("interaction stage did not restore and release")
                result["restoration_confirmed"] = result["release_confirmed"] = True
                result["timing_ns"]["acquisition"] = time.perf_counter_ns() - acquisition_started_ns
                result["timing_confirmed"]["acquisition"] = True
            shutdown_started_ns = time.perf_counter_ns()
            for arguments, expected in ((["session-stop"], "Ready"), (["quit"], None)):
                response = subprocess.run(common + arguments, env=env, capture_output=True, text=True, timeout=remaining(55))
                response.check_returncode()
                reply = json.loads(response.stdout)
                if not reply["ok"] or expected is not None and reply["state"] != expected:
                    raise ValueError("public shutdown rejected")
            process.wait(timeout=remaining(45))
            final = json.loads((runtime / "state.json").read_text())
            if process.returncode != 0 or final["phase"] != "stopped" or final.get("error") or final.get("cleanup_errors") or instance.exists():
                raise ValueError("deployment cleanup incomplete")
            result["shutdown_confirmed"] = True
            result["final"] = final
            result["timing_ns"]["public_shutdown"] = time.perf_counter_ns() - shutdown_started_ns
            result["timing_confirmed"]["public_shutdown"] = True
            remaining(recipe["stage_timeout_seconds"])
        except BaseException as error:
            failed_ns = time.perf_counter_ns()
            if result["timing_ns"]["startup_readiness"] is None:
                result["timing_ns"]["startup_readiness"] = failed_ns - startup_started_ns
            if acquisition_started_ns is not None and result["timing_ns"]["acquisition"] is None:
                result["timing_ns"]["acquisition"] = failed_ns - acquisition_started_ns
            if shutdown_started_ns is not None and result["timing_ns"]["public_shutdown"] is None:
                result["timing_ns"]["public_shutdown"] = failed_ns - shutdown_started_ns
            result["failure"] = repr(error)
            if endpoint is not None and endpoint.can_restore and not result["release_confirmed"]:
                try:
                    restored = endpoint.request({"kind": "restore", "figure": recipe["reference"], "rule": recipe["settling"]}, "restored")
                    if restored["clipped"] or not same_figure(restored["figure"], recipe["reference"]):
                        raise ValueError("abort reference restoration clipped or changed")
                    result["restoration_confirmed"] = True
                    endpoint.request({"kind": "release"}, "released")
                    result["release_confirmed"] = True
                except BaseException as recovery:
                    result["recovery_failure"] = repr(recovery)
            if endpoint is not None:
                result["requests"] = endpoint.records
            raise
        finally:
            if endpoint is not None:
                endpoint.close()  # Unknown outcomes retain owner fault/hold; no blind restore retry.
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=45)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            result["launcher_exit"] = process.returncode if process is not None else None
            finished_ns = time.perf_counter_ns()
            if acquisition_started_ns is not None and result["timing_ns"]["acquisition"] is None:
                result["timing_ns"]["acquisition"] = finished_ns - acquisition_started_ns
            if shutdown_started_ns is not None and result["timing_ns"]["public_shutdown"] is None:
                result["timing_ns"]["public_shutdown"] = finished_ns - shutdown_started_ns
            result["timing_ns"]["total_stage"] = finished_ns - stage_started_ns
            science.write_json(output / "stage-result.json", result)
    return result


def campaign(arguments):
    campaign_started_ns = time.perf_counter_ns()
    if sys.byteorder != "little":
        raise ValueError("campaign packed acquisition currently requires a little-endian host")
    recipe = validate_recipe(json.loads(arguments.recipe.read_text()))
    output = arguments.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("campaign output must be new")
    aoc = arguments.aoc_source.resolve()
    if not (aoc / "src/reference_frames/reference_frames.jl").is_file():
        raise ValueError("AOC ReferenceFrames source is required")
    output.mkdir(parents=True)
    science.write_json(output / "recipe.json", recipe)
    background, references = bytes(495616), bytes(1504)
    active = bytes(recipe["candidate_mask"])
    record = {"version": 1, "phase": "candidate", "stages": {}, "scope": "Classic CPU simulated calibration; no precision, correction or cadence acceptance"}
    try:
        for stage, frame_key in (("dark", "dark_frames"), ("training", "training_frames"), ("qualification", "qualification_frames"), ("interaction", None)):
            base = stage_base(arguments.base_package.resolve(), output / (stage + "-base"), recipe, stage, background, references, active, aoc, arguments.pipewire_prefix)
            package = output / (stage + "-package")
            frames = recipe[frame_key] if frame_key else None
            export_calibration.export(SimpleNamespace(base_package=base, output=package,
                pipewire_prefix=arguments.pipewire_prefix, deployment=True,
                rtc_binary=arguments.rtc_binary, calibration_binary=arguments.calibration_binary,
                illumination="dark" if stage == "dark" else "lamp", calibration_stage=stage,
                capture_max_bytes=frames * PAYLOAD_BYTES if frames else None))
            evidence = output / (stage + "-evidence")
            if stage == "dark":
                preparation = subprocess.run([arguments.julia, "--startup-file=no", "--project=" + str(package / "hil"),
                    str(Path(__file__).parent / "hil/calibration_campaign_analysis.jl"), "prepare",
                    str(output), str(output)], capture_output=True, text=True,
                    timeout=recipe["stage_timeout_seconds"])
                (output / "preparation.stdout").write_text(preparation.stdout)
                (output / "preparation.stderr").write_text(preparation.stderr)
                preparation.check_returncode()
            # Short independent runtime paths are necessary for AF_UNIX names.
            runtime = arguments.runtime / stage
            record["stages"][stage] = run_stage(package, evidence, runtime, recipe, stage, frames=frames)
            analysis = subprocess.run([arguments.julia, "--startup-file=no", "--project=" + str(package / "hil"),
                str(Path(__file__).parent / "hil/calibration_campaign_analysis.jl"), stage,
                str(output), str(evidence)], capture_output=True, text=True, timeout=recipe["stage_timeout_seconds"],
                env={**os.environ, "OPENBLAS_NUM_THREADS": "1"})
            (evidence / "analysis.stdout").write_text(analysis.stdout)
            (evidence / "analysis.stderr").write_text(analysis.stderr)
            analysis.check_returncode()
            if stage == "dark":
                background = (output / "measured-background.f32le").read_bytes()
            elif stage == "training":
                references = (output / "measured-reference-slopes.f32le").read_bytes()
                active = (output / "measured-active.u8").read_bytes()
        record["phase"] = "complete-candidate"
    except BaseException as error:
        record["failure"] = repr(error)
        raise
    finally:
        record["artifacts"] = {str(p.relative_to(output)): digest(p) for p in sorted(output.glob("measured-*")) if p.is_file()}
        record["timing_ns"] = {"total_campaign": time.perf_counter_ns() - campaign_started_ns}
        deploy.atomic_record(output / "campaign-result.json", record)
    return output / "campaign-result.json"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("base-package", "output", "recipe", "aoc-source", "rtc-binary", "calibration-binary", "runtime"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--pipewire-prefix", type=Path, default=Path("/opt/pipewireao"))
    parser.add_argument("--julia", default="julia")
    arguments = parser.parse_args(argv)
    if arguments.pipewire_prefix.resolve() != Path("/opt/pipewireao"):
        parser.error("this campaign currently qualifies the /opt/pipewireao deployment only")
    print(campaign(arguments))


if __name__ == "__main__":
    main()
