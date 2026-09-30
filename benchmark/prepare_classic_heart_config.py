#!/usr/bin/env python3
"""Prepare an unchanged-HEART Classic replay configuration and provenance.

This overlay retains the original 277-element HEART representation. It does
not execute HEART, generate calibration data, or establish numerical/timing
equivalence. See CLASSIC_MATCHED_REVIEW.md for the selected comparison law.
"""

from __future__ import annotations

import argparse
import copy
from decimal import Decimal
import hashlib
import json
import math
from pathlib import Path
import re

import yaml


# Deliberately bounded to classic_config_sim.yaml and the supported overlay
# keys inspected in HEART source/config/src/hrtConfig.c. Reject other profiles.
SECTION_KEYS = {
    "ADDRS": "BLOCK_ADDRS PERFORMANCE_MONITOR LOOP_MONITOR SRT SRT_RPG_HO SRT_OPT_HO HRT_HO_PIPE TEL_SOCKET_STREAM_BASE_ADDR TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR",
    "CB": "CAPACITY TELEMETRY_SOCKET_STREAMS TELEMETRY_FILE_STREAMS",
    "GEN": "MODAL_CTRL GRAD_NOISE_COVARIANCE_ENABLED GRAD_NOISE_COVARIANCE_PERIOD_SEC HO_POLC LO_POLC UNCTRL_MODE_SIZE UNCTRL_MODE_GAIN WC_SHAPE_TO_UNCTRL_MODE_FILE UNCTRL_MODE_TO_WC_SHAPE_FILE UNCTRL_MODE_REMOVAL OPTICAL_GAIN_OPT_ENABLED PIXEL_THRESHOLD_OPT_ENABLED OPTICAL_GAIN_APPLICATION OPTICAL_GAIN_DITHER_INJECTION",
    "HO": "RECONSTRUCTED_VECT_SIZE WFS_COUNT WFS_SIZE SUBAP_TOTAL WFS_TYPE SHWFS_SUBAP_SIZE SHWFS_SUBAP_LOCATION_FILE OPTICAL_GAIN_INITIAL WFS_HARDWARE GLOBAL_NORM_FLAG BIAS_FILE SUBAP_THRES_FLUX SUBAP_THRES_PIXEL NCPA_GRADS_FILE SUBAP_MASK_INITIAL_FILE GRAD_COEFF_INITIAL_FILE SHWFS_GRAD_TYPE RECON_TYPE HO_CONTROL_MATRIX_FILE",
    "LO": "WFS_COUNT RECONSTRUCTED_VECT_SIZE",
    "DM": "PDM_COUNT PDM_SIZES VDM_COUNT VDM_SIZES PDM_DIAMETER PDM_ACTUATOR_MAP_FILE TT_COUNT PDM_HARDWARE PDM_CLIPPINGS_FILE VDM_EXTRAPOLATION_FILE PDM_TO_LO_PROJECTION_FILE PDM_SYS_FLAT_FILE PDM_OFFSETS_FILE PDM_SLEW_RATE_LIMIT",
    "TELOFF": "TELOFF_COUNT",
    "TFC": "TFC_INIT_GAIN_FILTER TFC_HO_PSD TFC_HO_TEMPORAL_FILTER TFC_LO_TEMPORAL_FILTER TFC_HO_NCPA_REF_VEC_FILEPATH",
    "SUM": "SUM_SYNC_TIMEOUT",
    "CLWC": "CLWC_DM_SCALAR CLWC_DM_LEAK_PARAM",
}
RECORD_KEYS = {
    "BLOCK_ADDRS": "name ipStr cmdPort port",
    "PERFORMANCE_MONITOR": "ipStr port", "LOOP_MONITOR": "IPSTR PORT",
    "SRT": "SERVER_IP SERVER_PORT RPG_IP OPT_IP", "SRT_RPG_HO": "WFS_NUM RECON_PORT",
    "SRT_OPT_HO": "WFS_NUM PIXEL_THRESHOLD_PORT OPTICAL_GAIN_PORT",
    "HRT_HO_PIPE": "WFS_NUM IP GRAD_COV_PORT MAX_PIXEL_PORT DITHER_AMPLITUDE_PORT",
    "TEL_SOCKET_STREAM_BASE_ADDR": "IPSTR PORT", "CAPACITY": "tagName capacity",
    "TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR": "IPSTR PORT",
    "TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR": "IPSTR PORT",
    "TELEMETRY_SOCKET_STREAMS": "tagName decimate pollPeriod",
    "TELEMETRY_FILE_STREAMS": "tagName decimate pollPeriod",
    "WFS_SIZE": "WFS_NUM ROWS COLS FIRSTROW FIRSTCOL", "SUBAP_TOTAL": "WFS_NUM NUM",
    "SHWFS_SUBAP_SIZE": "WFS_NUM ROWS COLS", "OPTICAL_GAIN_INITIAL": "WFS_NUM X Y",
    "WFS_HARDWARE": "WFS_NUM DETECTOR_TYPE CONNECTION_STR FPS EXPOSURE_TIME GAIN TRIG_TYPE",
    "PDM_SIZES": "PDM_NUM SIZE", "VDM_SIZES": "VDM_NUM SIZE SIZE_FULL NUM_OF_PDM",
    "PDM_DIAMETER": "PDM_NUM SIZE",
    "PDM_HARDWARE": "PDM_NUM WC_TYPE CONNECTION_STR SCALE_FACTOR BYTE_ORDER",
    "PDM_SLEW_RATE_LIMIT": "PDM_NUM EXISTS LIMIT_FILE INITIAL_SHAPE_FILE",
    "TFC_INIT_GAIN_FILTER": "HO LO",
    "TFC_HO_PSD": "EXISTS SELECTION_MATRIX_FILE NUM_PTS SEG_TO_AVG SHAPE_AVG",
    "TFC_HO_TEMPORAL_FILTER": "EXISTS ORDER COEFF_FILE MODAL_GAIN_FILE ZONAL_GAIN",
    "TFC_LO_TEMPORAL_FILTER": "EXISTS ORDER COEFF_FILE GAIN_FILE",
}
CALIBRATIONS = {
    "SHWFS_SUBAP_LOCATION_FILE": "cblueROIoffsets.csv",
    "BIAS_FILE": "wfs_dark_unscaled.fits",
    "SUBAP_THRES_FLUX": "threshold_1000_188.fits",
    "SUBAP_THRES_PIXEL": "calPixThresh_20.fits",
    "NCPA_GRADS_FILE": "slopeOffsets.fits",
    "SUBAP_MASK_INITIAL_FILE": "validSubapMask.csv",
    "GRAD_COEFF_INITIAL_FILE": "cBluePixelCoefs.fits",
    "PDM_ACTUATOR_MAP_FILE": "dmActuatorMap_277.csv",
    "PDM_CLIPPINGS_FILE": "dm_clipping_277_0.8.csv",
    "VDM_EXTRAPOLATION_FILE": "dmExtrapolationMatrixTT.sparse",
}


class UniqueLoader(yaml.SafeLoader):
    """Safe YAML aliases are accepted; duplicate keys are never discarded."""


def _mapping(loader: UniqueLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str) or key in result:
            raise ValueError(f"duplicate or non-string YAML key: {key!r}")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)


def _yaml_text(source: Path) -> str:
    # The distributed Classic YAML contains tab-indented comments. Expand
    # indentation only, preserving tabs inside scalar values and source bytes.
    return re.sub(r"(?m)^[ \t]+", lambda m: m.group().expandtabs(8),
                  source.read_text(encoding="utf-8"))


def load_config(source: Path) -> tuple[list, dict]:
    document = yaml.load(_yaml_text(source), Loader=UniqueLoader)
    if not isinstance(document, list):
        raise ValueError("expected a list of HEART configuration sections")
    sections = {}
    for entry in document:
        if not isinstance(entry, dict) or len(entry) != 1:
            raise ValueError("each HEART section must be a single dictionary")
        name, values = next(iter(entry.items()))
        if name in sections or name not in {"ALIASES", *SECTION_KEYS}:
            raise ValueError(f"duplicate or unrecognized HEART section: {name}")
        if not isinstance(values, dict):
            raise ValueError(f"{name} must be a dictionary")
        sections[name] = values
        if name == "ALIASES":
            if any(isinstance(v, (dict, list)) for v in values.values()):
                raise ValueError("Classic aliases must contain scalar values")
            continue
        for key, value in values.items():
            if key not in SECTION_KEYS[name].split():
                raise ValueError(f"unrecognized configuration key: {name}.{key}")
            if isinstance(value, list):
                fields = RECORD_KEYS.get(key)
                if fields is None and (key.endswith("FILE") or key in CALIBRATIONS):
                    fields = ("WFS_NUM FILE" if name == "HO" else
                              "VDM_NUM FILE" if key == "VDM_EXTRAPOLATION_FILE" else "PDM_NUM FILE")
                if fields is None or not value:
                    raise ValueError(f"unrecognized or empty records: {name}.{key}")
                for record in value:
                    if (not isinstance(record, dict) or not record
                            or set(record) - set(fields.split())
                            or any(isinstance(v, (dict, list)) for v in record.values())):
                        raise ValueError(f"unrecognized record fields: {name}.{key}")
            elif isinstance(value, dict):
                raise ValueError(f"unexpected dictionary: {name}.{key}")
    missing = {"ALIASES", *SECTION_KEYS} - sections.keys()
    if missing:
        raise ValueError(f"missing required sections: {sorted(missing)}")
    return document, sections


def serialize_config(document: list, source: Path) -> str:
    """Emit the line-oriented HEART YAML subset, rather than generic YAML.

    daoConfig_getAlias requires ``KEY: &anchor VALUE`` in ALIASES;
    daoConfig_getArrayDict requires ``KEY: [`` and assigns record IDs at ``{``.
    daoStr_separateTokensYaml recognizes double quotes and splits minus signs,
    including the minus in exponential numeric notation. Preserve source
    anchor names and emit records in flow syntax with decimal numeric values.
    """
    anchors = {}
    events = list(yaml.parse(_yaml_text(source)))
    for position, event in enumerate(events):
        if isinstance(event, yaml.events.ScalarEvent) and event.value == "ALIASES":
            index = position + 2  # skip the value's MappingStartEvent
            while index < len(events) and isinstance(events[index], yaml.events.ScalarEvent):
                key, value = events[index:index + 2]
                if isinstance(value, yaml.events.ScalarEvent) and value.anchor is not None:
                    anchors[key.value] = value.anchor
                index += 2
            break

    def scalar(value: object) -> str:
        if isinstance(value, str):
            # HEART does not decode YAML escape sequences or single quotes.
            if any(ord(character) < 32 or character in '\\"' for character in value):
                raise ValueError("HEART YAML strings cannot contain controls, backslashes, or double quotes")
            if len(value.encode("utf-8")) >= 128:
                raise ValueError("HEART YAML scalar exceeds its 128-byte value buffer")
            return json.dumps(value, ensure_ascii=False)
        if type(value) is int:
            result = str(value)
        elif type(value) is float and math.isfinite(value):
            result = format(Decimal(str(value)), "f")
        else:
            raise ValueError(f"unsupported HEART YAML scalar: {value!r}")
        if len(result) >= 128:
            raise ValueError("HEART YAML scalar exceeds its 128-byte value buffer")
        return result

    lines = ["---"]
    used_anchors = set()
    for entry in document:
        name, values = next(iter(entry.items()))
        lines.append(f"- {name}:")
        for key, value in values.items():
            if name == "ALIASES":
                anchor = anchors.get(key, f"classic_{key}")
                if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", anchor)
                        or anchor in used_anchors or len(anchor) >= 63):
                    raise ValueError(f"unsupported or duplicated HEART alias anchor: {anchor}")
                used_anchors.add(anchor)
                if type(value) in (int, float) and value < 0:
                    raise ValueError("HEART ALIASES cannot represent a negative numeric value")
                lines.append(f"    {key}: &{anchor} {scalar(value)}")
            elif isinstance(value, list):
                lines.append(f"    {key}: [")
                for index, record in enumerate(value):
                    fields = ", ".join(f"{field}: {scalar(item)}" for field, item in record.items())
                    suffix = "," if index + 1 < len(value) else ""
                    lines.append(f"        {{ {fields} }}{suffix}")
                lines.append("    ]")
            else:
                lines.append(f"    {key}: {scalar(value)}")
    lines.append("...")
    if any(len(line.encode("utf-8")) + 1 >= 1152 for line in lines):
        raise ValueError("generated line exceeds HEART's 1152-byte configuration buffer")
    result = "\n".join(lines) + "\n"
    if yaml.safe_load(result) != document:
        raise ValueError("HEART YAML serialization changed configuration values")
    return result


def _require(section: dict, key: str, expected: object) -> None:
    def matches(actual: object, wanted: object) -> bool:
        if type(actual) is not type(wanted):
            return False
        if isinstance(wanted, dict):
            return actual.keys() == wanted.keys() and all(matches(actual[k], v) for k, v in wanted.items())
        if isinstance(wanted, list):
            return len(actual) == len(wanted) and all(matches(a, b) for a, b in zip(actual, wanted))
        return actual == wanted

    if key not in section or not matches(section[key], expected):
        raise ValueError(f"Classic requires {key} = {expected!r}")


def _one(section: dict, key: str, index: str) -> dict:
    value = section.get(key)
    if not isinstance(value, list) or len(value) != 1 or value[0].get(index) != 0:
        raise ValueError(f"Classic requires one {key} record for {index}=0")
    return value[0]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _matrix_dimensions(path: Path) -> tuple[int, int]:
    """Inspect the primary FITS header without another package dependency."""
    cards = {}
    with path.open("rb") as stream:
        while True:
            block = stream.read(2880)
            if len(block) != 2880:
                raise ValueError("control matrix has an incomplete FITS header")
            for offset in range(0, 2880, 80):
                card = block[offset:offset + 80].decode("ascii")
                key = card[:8].strip()
                if key == "END":
                    if cards.get("NAXIS") != 2 or cards.get("BITPIX") not in (-32, -64):
                        raise ValueError("control matrix must be a two-axis floating FITS image")
                    dims = cards.get("NAXIS2"), cards.get("NAXIS1")
                    if dims != (277, 376):
                        raise ValueError(f"control matrix must be 277 x 376, found {dims}")
                    payload = 277 * 376 * (abs(cards["BITPIX"]) // 8)
                    if path.stat().st_size < stream.tell() + payload:
                        raise ValueError("control matrix FITS payload is truncated")
                    return dims
                if card[8:10] == "= " and key in {"NAXIS", "NAXIS1", "NAXIS2", "BITPIX"}:
                    if key in cards:
                        raise ValueError(f"duplicate control matrix FITS card: {key}")
                    cards[key] = int(card[10:].split("/", 1)[0].strip())


def prepare_config(source: Path, calibration_root: Path, period: float) -> tuple[str, dict]:
    if isinstance(period, bool) or not math.isfinite(period) or period <= 0:
        raise ValueError("period must be finite and positive, in seconds")
    fps, exposure = 1.0 / period, period * 1000.0
    if not math.isfinite(fps) or not math.isfinite(exposure):
        raise ValueError("derived FPS and exposure must be finite")
    root = calibration_root.resolve(strict=True)
    if not root.is_dir():
        raise ValueError("calibration root must be a directory")
    document, sections = load_config(source)
    before = copy.deepcopy(sections)
    ho, dm, gen, tfc = (sections[key] for key in ("HO", "DM", "GEN", "TFC"))
    for key, expected in {"RECONSTRUCTED_VECT_SIZE": 277, "WFS_COUNT": 1,
                          "WFS_TYPE": 0, "GLOBAL_NORM_FLAG": 0,
                          "SHWFS_GRAD_TYPE": 0, "RECON_TYPE": 0}.items():
        _require(ho, key, expected)
    _require(ho, "WFS_SIZE", [{"WFS_NUM": 0, "ROWS": 352, "COLS": 352, "FIRSTROW": 0, "FIRSTCOL": 0}])
    _require(ho, "SUBAP_TOTAL", [{"WFS_NUM": 0, "NUM": 188}])
    _require(ho, "SHWFS_SUBAP_SIZE", [{"WFS_NUM": 0, "ROWS": 22, "COLS": 22}])
    for key, expected in {"PDM_COUNT": 1, "VDM_COUNT": 1, "TT_COUNT": 0,
                          "PDM_SIZES": [{"PDM_NUM": 0, "SIZE": 277}],
                          "VDM_SIZES": [{"VDM_NUM": 0, "SIZE": 277, "SIZE_FULL": 277, "NUM_OF_PDM": 1}]}.items():
        _require(dm, key, expected)
    _require(gen, "MODAL_CTRL", 0)
    _require(sections["LO"], "WFS_COUNT", 0)
    _require(sections["TELOFF"], "TELOFF_COUNT", 0)
    for key, filename in CALIBRATIONS.items():
        section, index = (ho, "WFS_NUM") if key in SECTION_KEYS["HO"].split() else (dm, "VDM_NUM" if key == "VDM_EXTRAPOLATION_FILE" else "PDM_NUM")
        record = _one(section, key, index)
        if not isinstance(record.get("FILE"), str) or Path(record["FILE"]).name != filename:
            raise ValueError(f"Classic {key} must retain {filename}")
    for key, value in {"HO_POLC": 0, "LO_POLC": 0, "UNCTRL_MODE_REMOVAL": 0,
                       "GRAD_NOISE_COVARIANCE_ENABLED": 0, "OPTICAL_GAIN_OPT_ENABLED": 0,
                       "PIXEL_THRESHOLD_OPT_ENABLED": 0,
                       "OPTICAL_GAIN_APPLICATION": 0, "OPTICAL_GAIN_DITHER_INJECTION": 0}.items():
        gen[key] = value
    ho["HO_CONTROL_MATRIX_FILE"] = [{"WFS_NUM": 0, "FILE": "config/REVOLT2_CM_lab_20240917.fits"}]
    ho["OPTICAL_GAIN_INITIAL"] = [{"WFS_NUM": 0, "X": 1.0, "Y": 1.0}]
    _require(sections["ALIASES"], "WFS_STDWFS", 1)
    _require(sections["ALIASES"], "WFS_TRIG_SELF", 0)
    _require(sections["ALIASES"], "WC_STDDM", 1)
    hardware = _one(ho, "WFS_HARDWARE", "WFS_NUM")
    hardware.update(DETECTOR_TYPE=1, CONNECTION_STR=":6000", FPS=fps,
                    EXPOSURE_TIME=exposure, GAIN=1.0, TRIG_TYPE=0)
    _one(dm, "PDM_HARDWARE", "PDM_NUM").update(
        WC_TYPE=1, CONNECTION_STR=":6100", SCALE_FACTOR=1.0, BYTE_ORDER=0)
    for name, port in (("wfs", 6000), ("dmOut", 6100)):
        addresses = [row for row in sections["ADDRS"].get("BLOCK_ADDRS", []) if row.get("name") == name]
        if len(addresses) != 1:
            raise ValueError(f"missing or duplicated address: {name}")
        addresses[0].update(ipStr="localhost", cmdPort=port, port=port)
    # Empty file paths initialize zero system flat and no offset in CLWC.
    dm["PDM_SYS_FLAT_FILE"] = [{"PDM_NUM": 0, "FILE": ""}]
    dm["PDM_OFFSETS_FILE"] = [{"PDM_NUM": 0, "FILE": ""}]
    dm["PDM_SLEW_RATE_LIMIT"] = [{"PDM_NUM": 0, "EXISTS": 0}]
    tfc["TFC_INIT_GAIN_FILTER"] = [{"HO": -0.3, "LO": 0.0}]
    tfc["TFC_HO_PSD"] = [{"EXISTS": 0}]
    tfc["TFC_HO_TEMPORAL_FILTER"] = [{"EXISTS": 0, "ORDER": 2}]
    tfc["TFC_LO_TEMPORAL_FILTER"] = [{"EXISTS": 0, "ORDER": 2}]
    tfc["TFC_HO_NCPA_REF_VEC_FILEPATH"] = ""
    sections["CLWC"].update(CLWC_DM_SCALAR=1.0, CLWC_DM_LEAK_PARAM=0.99)
    # No file recorder or GUI consumer is launched for this wire replay.
    # hrtTemplate's absent tag arrays create zero selected telemetry streams.
    # Retain CAPACITY and all automatically registered scientific CBs.
    for key in ("TELEMETRY_FILE_STREAMS", "TELEMETRY_SOCKET_STREAMS"):
        sections["CB"].pop(key, None)
    # The template also creates secondary CB streams without a selection gate.
    # Use the existing Copper addresses instead of zero-initialized base ports.
    sections["ADDRS"]["TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR"] = [{"IPSTR": "localhost", "PORT": 6200}]
    sections["ADDRS"]["TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR"] = [{"IPSTR": "localhost", "PORT": 6300}]

    calibrations = {}

    def resolve_files(value: object, prefix: str) -> None:
        if isinstance(value, list):
            for i, child in enumerate(value):
                resolve_files(child, f"{prefix}[{i}]")
        elif isinstance(value, dict):
            for key, child in value.items():
                location = f"{prefix}.{key}"
                if (key == "FILE" or key.endswith("_FILE")) and isinstance(child, str) and child:
                    path = (root / child).resolve(strict=True)
                    if not path.is_relative_to(root) or not path.is_file():
                        raise ValueError(f"calibration must be a file inside calibration root: {child}")
                    value[key] = str(path)
                    calibrations[location] = {"path": str(path), "sha256": _sha256(path)}
                else:
                    resolve_files(child, location)

    for name, values in sections.items():
        if name != "ALIASES":
            resolve_files(values, name)
    cm = Path(ho["HO_CONTROL_MATRIX_FILE"][0]["FILE"])
    _matrix_dimensions(cm)
    extrap = Path(dm["VDM_EXTRAPOLATION_FILE"][0]["FILE"]).read_text()
    if not re.search(r"(?m)^Sparse: rows=277 cols=277 nnz=12597(?:\s|$)", extrap):
        raise ValueError("Classic requires the original 277 x 277 sparse extrapolator")
    clipping = Path(dm["PDM_CLIPPINGS_FILE"][0]["FILE"]).read_text().splitlines()
    if (len(clipping) != 3 or clipping[0].split() != ["2", "277", "1", "float"]
            or [list(map(float, row.split(","))) for row in clipping[1:]] != [[0.8] * 277, [-0.8] * 277]):
        raise ValueError("Classic clipping calibration must contain 277 limits of +/-0.8")
    output = serialize_config(document, source)
    changes = []
    for section, values in sections.items():
        for key in dict.fromkeys((*before[section], *values)):
            if key not in before[section] or key not in values or values[key] != before[section][key]:
                changes.append({"key": f"{section}.{key}", "before": before[section].get(key), "after": values.get(key)})
    flags = {"enableClippingFeedback": 1, "enableLoCmdAggre": 0,
             "enableWCOptimize": 0, "enableUnctrlModeFeedback": 0,
             "enableFigureDmVector": 0, "enableDmOffset": 0,
             "enableDmDisturbance": 0, "enableDmDither": 0,
             "enablePOLFeedback": 0, "enableNotClearingIntg": 0,
             "enableTtOffset": 0, "enableTtDisturbance": 0}
    report = {
        "status": "configuration preparation only; numerical and timing qualification not run",
        "source": {"path": str(source.resolve()), "sha256": _sha256(source)},
        "calibration_root": str(root), "calibrations": calibrations,
        "period_s": period, "fps": fps, "exposure_time_ms": exposure,
        "geometry": {"rows": 352, "cols": 352, "subapertures": 188,
                     "heart_controller_size": 277, "physical_commands": 277,
                     "control_matrix_shape": [277, 376]},
        "controller": {"gain": -0.3, "pole": 0.99, "clipping": [-0.8, 0.8],
                       "fgn_jfg_anti_windup_gain_required": 0.99},
        "ingress": "ordinary progressive stdWfs UDP; common external wfsSimulator at localhost:6000",
        "egress": "stdDM UDP 277 physical commands at localhost:6100",
        "effective_changes": changes,
        "telemetry": {
            "file_and_gui_streams": "disabled by omitting CB telemetry selections; scientific CAPACITY unchanged",
            "secondary_streams": "automatically registered by unchanged HEART; no configuration selection gate available",
            "srt_to_hrt_base": "localhost:6200", "hrt_to_srt_base": "localhost:6300",
            "scope": "short 1..7-frame replay; default secondary writer update windows are 40 dither frames and 100 max-pixel frames; lifecycle success still requires native observation",
        },
        "initialized_disabled_flags": [
            {"section": "CLWFC", "field": "enableR0L0", "expected": 0,
             "basis": "no CLWC_R0_L0 configuration; hrtClwcBlock initialization sets 0",
             "command_omitted_reason": "setter restarts unavailable modal statistics even for value 0",
             "effective_value_verified": False},
            {"section": "TFC", "field": "enableHoPsd", "expected": 0,
             "basis": "TFC_HO_PSD.EXISTS=0; hrtTfcBlock initialization sets 0",
             "command_omitted_reason": "setter rejects any request when HO PSD is not configured",
             "effective_value_verified": False},
        ],
        "runtime_requirements": [
            {"block": "clwcBlock", "control": "ENABLE_HRT_FLAGS",
             "flags": flags, "action": "set and capture effective flags before replay"},
            {"block": "tfcBlock", "control": "ENABLE_HRT_FLAGS",
             "flags": {"enablePOLFeedback": 0, "enableLoCmdAggre": 0,
                       "enableInLoVect": 0, "enableInLotVect": 0,
                       "enableInHotVect": 0, "enableFieldRotation": 0,
                       "enableLGSDefocus": 0, "enableLoOptimization": 0,
                       "enableHoOptimization": 0, "enableKalman": 0,
                       "enableInHoVect": 1, "enableOutDmErrs": 1},
             "action": "set and capture effective flags before replay"},
            {"action": "start each replay with zero controller state; enter correcting with enableNotClearingIntg=0; capture state and effective POL/PSD/optical gains"},
            {"action": "retain ordinary stdWfs streaming; do not request a new full-frame ingress gate"},
        ],
    }
    return output, report


def write_config(source: Path, calibration_root: Path, period: float,
                 output: Path, report_path: Path | None = None) -> dict:
    report_path = report_path if report_path is not None else output.with_suffix(".json")
    if output.resolve() == report_path.resolve():
        raise ValueError("configuration and report paths must differ")
    for path in (output, report_path):
        if path.exists() or path.is_symlink():
            raise ValueError(f"destination must be new: {path}")
        if not path.parent.is_dir():
            raise ValueError(f"destination parent does not exist: {path.parent}")
    content, report = prepare_config(source, calibration_root, period)
    report["output"] = {"path": str(output.resolve()),
                        "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest()}
    with output.open("x", encoding="utf-8") as stream:
        stream.write(content)
    with report_path.open("x", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write("\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--calibration-root", type=Path, required=True)
    parser.add_argument("--period", type=float, required=True, help="frame period in seconds")
    parser.add_argument("--output", type=Path, required=True, help="new HEART YAML destination")
    parser.add_argument("--report", type=Path, help="new JSON destination (default: output with .json suffix)")
    args = parser.parse_args()
    try:
        report = write_config(args.source, args.calibration_root, args.period, args.output, args.report)
    except (OSError, ValueError, yaml.YAMLError) as error:
        parser.error(str(error))
    print(json.dumps({"output": report["output"], "status": report["status"],
                      "runtime_requirements": report["runtime_requirements"]}, indent=2))


if __name__ == "__main__":
    main()
