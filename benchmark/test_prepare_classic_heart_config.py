"""Focused preparation checks; these do not execute or qualify HEART."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

import yaml


SCRIPT = Path(__file__).with_name("prepare_classic_heart_config.py")
SPEC = importlib.util.spec_from_file_location("prepare_classic_heart_config", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


def assert_heart_dialect(content: str) -> None:
    """Check line forms required by inspected daoConfig_getAlias/ArrayDict.

    This is a source-based syntax regression, not a native parser execution.
    Generic YAML loading alone cannot establish HEART parser compatibility.
    """
    section = None
    for line in content.splitlines():
        stripped = line.strip()
        if stripped in ("---", "...", "]"):
            continue
        if stripped.startswith("- "):
            if not re.fullmatch(r"- [A-Z_]+:", stripped):
                raise ValueError("HEART requires flow record braces, not block sequence records")
            section = stripped[2:-1]
            continue
        tokens = re.findall(r'"[^"\n]*"|[-:,\[\]{}]|[^\s"\-:,\[\]{}]+', stripped)
        if len(tokens) >= 40:
            raise ValueError("HEART line exceeds the 40-token tokenizer limit")
        if section == "ALIASES":
            if len(tokens) != 4 or tokens[1] != ":" or not tokens[2].startswith("&"):
                raise ValueError("HEART ALIASES requires KEY: &anchor VALUE")
        elif stripped.startswith("{"):
            if not stripped.endswith(("}", "},")):
                raise ValueError("HEART requires a complete flow record")
        elif len(tokens) == 2 and tokens[1] == ":":
            raise ValueError("HEART array key must have '[' immediately after ':'")



def fits_matrix(rows: int = 277, cols: int = 376) -> bytes:
    cards = ["SIMPLE  =                    T", "BITPIX  =                  -32",
             "NAXIS   =                    2", f"NAXIS1  = {cols:20d}",
             f"NAXIS2  = {rows:20d}", "END"]
    header = "".join(card.ljust(80) for card in cards).encode("ascii").ljust(2880, b" ")
    return header + bytes(rows * cols * 4)


class ClassicConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        config = self.root / "config"
        config.mkdir()
        self.sections = {
            "ALIASES": {"WFS_STDWFS": 1, "WFS_TRIG_SELF": 0, "WC_STDDM": 1},
            "ADDRS": {"BLOCK_ADDRS": [
                {"name": "wfs", "ipStr": "localhost", "cmdPort": 6000, "port": 6000},
                {"name": "dmOut", "ipStr": "localhost", "cmdPort": 6100, "port": 6100}]},
            "CB": {"CAPACITY": [{"tagName": "cbHoGrad#", "capacity": 50}]},
            "GEN": {"MODAL_CTRL": 0, "HO_POLC": 1, "LO_POLC": 0,
                    "UNCTRL_MODE_SIZE": 2, "UNCTRL_MODE_GAIN": -1},
            "HO": {"RECONSTRUCTED_VECT_SIZE": 277, "WFS_COUNT": 1, "WFS_TYPE": 0,
                   "GLOBAL_NORM_FLAG": 0, "SHWFS_GRAD_TYPE": 0, "RECON_TYPE": 0,
                   "WFS_SIZE": [{"WFS_NUM": 0, "ROWS": 352, "COLS": 352, "FIRSTROW": 0, "FIRSTCOL": 0}],
                   "SUBAP_TOTAL": [{"WFS_NUM": 0, "NUM": 188}],
                   "SHWFS_SUBAP_SIZE": [{"WFS_NUM": 0, "ROWS": 22, "COLS": 22}],
                   "WFS_HARDWARE": [{"WFS_NUM": 0, "DETECTOR_TYPE": 1,
                                     "CONNECTION_STR": ":6000", "FPS": 10.0,
                                     "EXPOSURE_TIME": 100.0, "GAIN": 1.0, "TRIG_TYPE": 0}]},
            "LO": {"WFS_COUNT": 0, "RECONSTRUCTED_VECT_SIZE": 3},
            "DM": {"PDM_COUNT": 1, "VDM_COUNT": 1, "TT_COUNT": 0,
                   "PDM_SIZES": [{"PDM_NUM": 0, "SIZE": 277}],
                   "VDM_SIZES": [{"VDM_NUM": 0, "SIZE": 277, "SIZE_FULL": 277, "NUM_OF_PDM": 1}],
                   "PDM_HARDWARE": [{"PDM_NUM": 0, "WC_TYPE": 1, "CONNECTION_STR": ":6100",
                                     "SCALE_FACTOR": 1.0, "BYTE_ORDER": 0}]},
            "TELOFF": {"TELOFF_COUNT": 0}, "TFC": {"TFC_HO_PSD": [{"EXISTS": 1}]},
            "SUM": {"SUM_SYNC_TIMEOUT": 0.1},
            "CLWC": {"CLWC_DM_SCALAR": 1.0, "CLWC_DM_LEAK_PARAM": 0.99},
        }
        for key, filename in PREPARE.CALIBRATIONS.items():
            is_ho = key in PREPARE.SECTION_KEYS["HO"].split()
            section = self.sections["HO" if is_ho else "DM"]
            index = "WFS_NUM" if is_ho else "VDM_NUM" if key == "VDM_EXTRAPOLATION_FILE" else "PDM_NUM"
            section[key] = [{index: 0, "FILE": f"./config/{filename}"}]
            (config / filename).write_bytes(b"unchanged calibration fixture\n")
        (config / "REVOLT2_CM_lab_20240917.fits").write_bytes(fits_matrix())
        (config / "dmExtrapolationMatrixTT.sparse").write_text(
            "# fixture header only; no numerical equivalence claim\n"
            "Sparse: rows=277 cols=277 nnz=12597 name=dmExTT\n")
        (config / "dm_clipping_277_0.8.csv").write_text(
            "2 277 1 float\n" + ",".join(["0.8"] * 277) + "\n" + ",".join(["-0.8"] * 277))
        self.source = self.root / "source.yaml"
        self.save_source()

    def save_source(self) -> None:
        self.source.write_text(yaml.safe_dump([{k: v} for k, v in self.sections.items()], sort_keys=False))

    def prepare(self, period: float = 0.002) -> tuple[dict, dict]:
        content, report = PREPARE.prepare_config(self.source, self.root, period)
        sections = {key: value for section in yaml.safe_load(content) for key, value in section.items()}
        return sections, report

    def test_geometry_and_science_calibration_preserved(self) -> None:
        output, report = self.prepare()
        for key in ("RECONSTRUCTED_VECT_SIZE", "WFS_SIZE", "SUBAP_TOTAL", "SHWFS_SUBAP_SIZE"):
            self.assertEqual(output["HO"][key], self.sections["HO"][key])
        self.assertEqual(output["DM"]["VDM_SIZES"], self.sections["DM"]["VDM_SIZES"])
        self.assertEqual(output["DM"]["PDM_SIZES"], self.sections["DM"]["PDM_SIZES"])
        self.assertEqual(output["CB"], self.sections["CB"])
        self.assertEqual(output["ALIASES"], self.sections["ALIASES"])
        self.assertEqual(report["geometry"]["control_matrix_shape"], [277, 376])
        for record in report["calibrations"].values():
            self.assertEqual(record["sha256"], hashlib.sha256(Path(record["path"]).read_bytes()).hexdigest())
        self.assertEqual(Path(output["HO"]["HO_CONTROL_MATRIX_FILE"][0]["FILE"]).name,
                         "REVOLT2_CM_lab_20240917.fits")
        self.assertEqual(len(report["calibrations"]), 11)

    def test_flags_gain_pole_and_rate(self) -> None:
        output, report = self.prepare()
        for key in ("HO_POLC", "LO_POLC", "UNCTRL_MODE_REMOVAL", "OPTICAL_GAIN_APPLICATION",
                    "OPTICAL_GAIN_DITHER_INJECTION", "OPTICAL_GAIN_OPT_ENABLED", "PIXEL_THRESHOLD_OPT_ENABLED",
                    "GRAD_NOISE_COVARIANCE_ENABLED"):
            self.assertEqual(output["GEN"][key], 0)
        self.assertEqual(output["GEN"]["UNCTRL_MODE_SIZE"], 2)
        self.assertEqual(output["HO"]["OPTICAL_GAIN_INITIAL"], [{"WFS_NUM": 0, "X": 1.0, "Y": 1.0}])
        self.assertEqual(output["TFC"]["TFC_HO_PSD"], [{"EXISTS": 0}])
        self.assertEqual(output["TFC"]["TFC_INIT_GAIN_FILTER"], [{"HO": -0.3, "LO": 0.0}])
        self.assertEqual(output["CLWC"]["CLWC_DM_LEAK_PARAM"], 0.99)
        hardware = output["HO"]["WFS_HARDWARE"][0]
        self.assertEqual((hardware["FPS"], hardware["EXPOSURE_TIME"]), (500.0, 2.0))
        self.assertEqual((hardware["DETECTOR_TYPE"], hardware["CONNECTION_STR"]), (1, ":6000"))
        self.assertEqual(output["DM"]["PDM_HARDWARE"][0]["CONNECTION_STR"], ":6100")
        for key in ("PDM_SYS_FLAT_FILE", "PDM_OFFSETS_FILE"):
            self.assertEqual(output["DM"][key][0]["FILE"], "")
        self.assertEqual(output["DM"]["PDM_SLEW_RATE_LIMIT"][0]["EXISTS"], 0)
        flags = report["runtime_requirements"][0]["flags"]
        self.assertEqual(flags["enableClippingFeedback"], 1)
        self.assertEqual(flags["enableNotClearingIntg"], 0)
        self.assertIn("not run", report["status"])

    def test_unused_telemetry_selections_removed_and_reported(self) -> None:
        # Former overlay retained paused recorders / GUI streams without a
        # consumer. The native run failed on their shutdown flushes. Missing
        # tag arrays mean zero streams in setTelemetryForFile/ForWeb.
        baseline, baseline_report = self.prepare()
        selected = [{"tagName": "cbHoGrad#", "decimate": 0, "pollPeriod": 0.1}]
        for key in ("TELEMETRY_FILE_STREAMS", "TELEMETRY_SOCKET_STREAMS"):
            self.sections["CB"][key] = selected.copy()
        self.save_source()
        self.assertGreater(len(self.sections["CB"]["TELEMETRY_FILE_STREAMS"]), 0)
        output, report = self.prepare()
        self.assertEqual(output["CB"]["CAPACITY"], self.sections["CB"]["CAPACITY"])
        self.assertEqual(output["CB"], baseline["CB"])
        self.assertEqual(report["calibrations"], baseline_report["calibrations"])
        changes = {change["key"]: change for change in report["effective_changes"]}
        for key in ("TELEMETRY_FILE_STREAMS", "TELEMETRY_SOCKET_STREAMS"):
            self.assertNotIn(key, output["CB"])
            self.assertEqual(changes[f"CB.{key}"],
                             {"key": f"CB.{key}", "before": selected, "after": None})
        self.assertIn("native observation", report["telemetry"]["scope"])

    def test_secondary_stream_addresses_use_existing_nonprivileged_keys(self) -> None:
        for key in ("TEL_SOCKET_STREAM_SRT_TO_HRT_BASE_ADDR", "TEL_SOCKET_STREAM_HRT_TO_SRT_BASE_ADDR"):
            self.sections["ADDRS"][key] = [{"IPSTR": "localhost", "PORT": 0}]
        self.save_source()
        output, report = self.prepare()
        changes = {change["key"]: change for change in report["effective_changes"]}
        for suffix, port in (("SRT_TO_HRT", 6200), ("HRT_TO_SRT", 6300)):
            key = f"TEL_SOCKET_STREAM_{suffix}_BASE_ADDR"
            self.assertEqual(output["ADDRS"][key], [{"IPSTR": "localhost", "PORT": port}])
            self.assertEqual(changes[f"ADDRS.{key}"]["before"][0]["PORT"], 0)
        self.assertIn("no configuration selection gate", report["telemetry"]["secondary_streams"])

    def test_absent_optional_features_do_not_get_invalid_setter_requests(self) -> None:
        output, report = self.prepare()
        flags = {field: value for item in report["runtime_requirements"]
                 for field, value in item.get("flags", {}).items()}
        self.assertNotIn("enableR0L0", flags)
        self.assertNotIn("enableHoPsd", flags)
        self.assertEqual(output["TFC"]["TFC_HO_PSD"], [{"EXISTS": 0}])
        self.assertNotIn("CLWC_R0_L0", output["CLWC"])
        initialized = {item["field"]: item for item in report["initialized_disabled_flags"]}
        self.assertEqual(set(initialized), {"enableR0L0", "enableHoPsd"})
        for item in initialized.values():
            self.assertEqual(item["expected"], 0)
            self.assertFalse(item["effective_value_verified"])
            self.assertTrue(item["command_omitted_reason"])

    def test_aliases_resolve_without_scalar_replacement(self) -> None:
        text = self.source.read_text().replace("WFS_STDWFS: 1", "WFS_STDWFS: &std 1").replace("DETECTOR_TYPE: 1", "DETECTOR_TYPE: *std")
        self.source.write_text(text)
        output, _ = self.prepare()
        self.assertEqual(output["ALIASES"]["WFS_STDWFS"], 1)
        self.assertEqual(output["HO"]["WFS_HARDWARE"][0]["DETECTOR_TYPE"], 1)

    def test_heart_alias_regression_fails_before_and_passes_after(self) -> None:
        # The observed native failure was safe_dump dropping '&' declarations.
        # Keep the former serialization as fail-before evidence in this test.
        output, _ = self.prepare()
        document = [{key: values} for key, values in output.items()]
        former = yaml.safe_dump(document, sort_keys=False, explicit_start=True, explicit_end=True)
        with self.assertRaisesRegex(ValueError, "ALIASES requires"):
            assert_heart_dialect(former)
        content = PREPARE.serialize_config(document, self.source)
        assert_heart_dialect(content)
        self.assertEqual(yaml.safe_load(content), yaml.safe_load(former))

    def test_heart_record_regression_fails_before_and_passes_after(self) -> None:
        output, _ = self.prepare()
        document = [{key: values} for key, values in output.items() if key != "ALIASES"]
        former = yaml.safe_dump(document, sort_keys=False)
        with self.assertRaisesRegex(ValueError, "array key must have"):
            assert_heart_dialect(former)
        content = PREPARE.serialize_config(document, self.source)
        assert_heart_dialect(content)
        self.assertIn('BLOCK_ADDRS: [\n        { name: "wfs"', content)
        self.assertEqual(yaml.safe_load(content), yaml.safe_load(former))

    def test_retains_original_anchor_names_and_uses_double_quoted_strings(self) -> None:
        self.source.write_text(self.source.read_text().replace("WFS_STDWFS: 1", "WFS_STDWFS: &wfsStdWfs 1"))
        content, _ = PREPARE.prepare_config(self.source, self.root, 0.1)
        self.assertIn("WFS_STDWFS: &wfsStdWfs 1", content)
        self.assertIn('CONNECTION_STR: ":6000"', content)
        self.assertIn('FILE: ""', content)
        self.assertNotIn("''", content)
        assert_heart_dialect(content)

    def test_exponent_notation_is_emitted_as_decimal_and_strings_fail_closed(self) -> None:
        self.sections["ALIASES"]["SMALL_FLOAT"] = 1e-5
        self.save_source()
        content, _ = PREPARE.prepare_config(self.source, self.root, 0.1)
        self.assertIn("SMALL_FLOAT: &classic_SMALL_FLOAT 0.00001", content)
        assert_heart_dialect(content)
        self.assertEqual(yaml.safe_load(content)[0]["ALIASES"]["SMALL_FLOAT"], 1e-5)
        for value in ('escaped"quote', "back\\slash", "line\nbreak"):
            self.sections["ALIASES"]["UNSUPPORTED_STRING"] = value
            self.save_source()
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "HEART YAML strings"):
                self.prepare()

    def test_native_scalar_bounds_and_negative_alias_fail_closed(self) -> None:
        for value in ("x" * 128, 10 ** 128, -0.1):
            self.sections["ALIASES"]["UNSUPPORTED_VALUE"] = value
            self.save_source()
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "HEART"):
                self.prepare()

    def test_duplicate_and_unknown_keys_and_sections_rejected(self) -> None:
        original = self.source.read_text()
        for text in (original + "- OTHER: {}\n", original.replace("HO_POLC: 1", "HO_POLC: 1\n    HO_POLC: 0"),
                     original.replace("HO_POLC: 1", "STREAMING_FLAG: 0"),
                     original.replace("DETECTOR_TYPE: 1", "DETECTOR_TYPE: 1\n      FULLFRAME: 1")):
            with self.subTest(text=text[-100:]):
                self.source.write_text(text)
                with self.assertRaises((ValueError, yaml.YAMLError)):
                    self.prepare()

    def test_missing_sections_and_science_fields_rejected(self) -> None:
        del self.sections["TFC"]
        self.save_source()
        with self.assertRaisesRegex(ValueError, "missing required sections"):
            self.prepare()
        self.sections["TFC"] = {}
        del self.sections["HO"]["BIAS_FILE"]
        self.save_source()
        with self.assertRaisesRegex(ValueError, "BIAS_FILE"):
            self.prepare()

    def test_wrong_geometry_and_compact_heart_representation_rejected(self) -> None:
        self.sections["DM"]["VDM_SIZES"][0]["SIZE"] = 221
        self.save_source()
        with self.assertRaisesRegex(ValueError, "VDM_SIZES"):
            self.prepare()

    def test_numeric_booleans_cannot_substitute_geometry(self) -> None:
        self.sections["HO"]["WFS_COUNT"] = True
        self.save_source()
        with self.assertRaisesRegex(ValueError, "WFS_COUNT"):
            self.prepare()

    def test_period_validation(self) -> None:
        for period in (0, -0.1, float("inf"), float("nan"), True, 1e-320, 1e308):
            with self.subTest(period=period), self.assertRaises(ValueError):
                self.prepare(period)

    def test_missing_and_escaped_paths_rejected(self) -> None:
        self.sections["HO"]["BIAS_FILE"][0]["FILE"] = "../config/wfs_dark_unscaled.fits"
        self.save_source()
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.prepare()
        self.sections["HO"]["BIAS_FILE"][0]["FILE"] = str(self.root / "config/wfs_dark_unscaled.fits")
        outside = self.root.parent / (self.root.name + "_outside.fits")
        outside.write_bytes(b"outside")
        self.addCleanup(outside.unlink)
        bias = self.root / "config/wfs_dark_unscaled.fits"
        bias.unlink()
        bias.symlink_to(outside)
        self.save_source()
        with self.assertRaisesRegex(ValueError, "inside calibration root"):
            self.prepare()

    def test_matrix_dimensions_and_payload_rejected(self) -> None:
        cm = self.root / "config/REVOLT2_CM_lab_20240917.fits"
        for content in (fits_matrix(221), fits_matrix()[:2880]):
            cm.write_bytes(content)
            with self.assertRaisesRegex(ValueError, "control matrix"):
                self.prepare()

    def test_clipping_calibration_is_not_regenerated(self) -> None:
        clipping = self.root / "config/dm_clipping_277_0.8.csv"
        clipping.write_text(clipping.read_text().replace("0.8", "0.7"))
        with self.assertRaisesRegex(ValueError, "clipping calibration"):
            self.prepare()

    def test_new_output_only_and_provenance(self) -> None:
        destination = self.root / "matched.yaml"
        report = PREPARE.write_config(self.source, self.root, 0.01, destination)
        self.assertEqual(json.loads(destination.with_suffix(".json").read_text()), report)
        self.assertEqual(report["output"]["sha256"], hashlib.sha256(destination.read_bytes()).hexdigest())
        self.assertEqual(report["source"]["sha256"], hashlib.sha256(self.source.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, "must be new"):
            PREPARE.write_config(self.source, self.root, 0.01, destination)
        another = self.root / "another.yaml"
        with self.assertRaisesRegex(ValueError, "must be new"):
            PREPARE.write_config(self.source, self.root, 0.01, another, destination.with_suffix(".json"))
        self.assertFalse(another.exists())

    def test_cli_seconds_and_failure_leave_no_output(self) -> None:
        destination = self.root / "cli.yaml"
        command = [sys.executable, str(SCRIPT), "--source", str(self.source),
                   "--calibration-root", str(self.root), "--period", "0.002", "--output", str(destination)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(destination.with_suffix(".json").read_text())["fps"], 500.0)
        invalid = self.root / "invalid.yaml"
        result = subprocess.run(command[:-3] + ["nan", "--output", str(invalid)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(invalid.exists())


if __name__ == "__main__":
    unittest.main()
