"""Validate retained HIL evidence without starting a deployment."""

import array
import copy
import hashlib
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import check_hil
from check_hil import validate_report


class HILEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        frames = root / "frames.u16le"
        commands = root / "commands.f32le"
        frames.write_bytes(bytes(16))
        values = array.array("f", [0.1e-6] * 554)
        if sys.byteorder != "little":
            values.byteswap()
        commands.write_bytes(values.tobytes())
        self.report = {
            "failure": None, "completed": True,
            "completed_frames": 2, "completed_commands": 2,
            "sequences": [1, 2], "model_period_ns": 100,
            "model_timestamps_ns": [0, 100], "exposure_ns": 50,
            "command_limit_tolerance_um": 5e-7,
            "source_published_ns": [1000, 1100],
            "command_received_ns": [1010, 1120],
            "source_to_command_latency_ns": [10, 20],
            "frame": {"layout": "ROW_MAJOR", "element_type": "U16_LE",
                      "shape": [2, 2], "file": str(frames),
                      "sha256": hashlib.sha256(frames.read_bytes()).hexdigest()},
            "command": {"transport_to_plant_scale": 1e-6,
                        "recorded_units": "metre OPD", "file": str(commands),
                        "sha256": hashlib.sha256(commands.read_bytes()).hexdigest()},
        }

    def test_complete_correlated_report(self):
        validate_report(self.report, 2)

    def test_count_sequence_units_and_timing_reject(self):
        for key, value in (("completed_commands", 1), ("sequences", [1, 3]),
                           ("model_timestamps_ns", [0, 200]),
                           ("source_to_command_latency_ns", [10, 21]),
                           ("failure", "source failed"), ("exposure_ns", 101)):
            with self.subTest(key=key):
                report = copy.deepcopy(self.report)
                report[key] = value
                with self.assertRaises(AssertionError):
                    validate_report(report, 2)

    def test_heart_schema_and_unit_pair(self):
        report = copy.deepcopy(self.report)
        report["transport"] = "heart"
        report["frame"]["schema"] = "org.heart.std-wfs.raw-pixels/1"
        report["command"].update(schema="org.heart.std-dm.actuator-command/1",
                                 transport_units="metre OPD", transport_to_plant_scale=1.0)
        validate_report(report, 2)
        for key,value in (("transport_to_plant_scale",1e-6),("transport_units","micrometre OPD"),
                          ("schema","org.calculon.ao.demanded-pdm-command/1")):
            bad = copy.deepcopy(report)
            bad["command"][key] = value
            with self.assertRaises(AssertionError):
                validate_report(bad,2)

    def test_corrupt_payload_rejects(self):
        Path(self.report["frame"]["file"]).write_bytes(bytes(15))
        with self.assertRaises(AssertionError):
            validate_report(self.report, 2)

    def test_nan_command_rejects_even_with_valid_hash(self):
        path = Path(self.report["command"]["file"])
        values = array.array("f", [float("nan")] * 554)
        if sys.byteorder != "little":
            values.byteswap()
        path.write_bytes(values.tobytes())
        self.report["command"]["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaises(AssertionError):
            validate_report(self.report, 2)

    def test_early_clean_return_cannot_qualify(self):
        root = Path(self.temporary.name)
        (root / "provenance.json").write_text('{"hil":{"frames":2}}')
        runner = SimpleNamespace(source_owner={}, package=root, record={"admitted": False},
                                 check=lambda: None, run=lambda: None)
        args = SimpleNamespace(deployment=root / "deployment.conf", output=root / "evidence")
        with patch.object(check_hil.deploy, "Deployment", return_value=runner):
            with self.assertRaisesRegex(AssertionError, "before all checks"):
                check_hil.qualify(args)

    def test_diagnostic_copy_failure_still_stops_owned_processes(self):
        root = Path(self.temporary.name)
        (root / "provenance.json").write_text('{"hil":{"frames":2}}')
        native = root / "runtime/heart/native"
        native.mkdir(parents=True)
        (native / "heart.log").write_text("diagnostic")
        stop = MagicMock()
        runner = SimpleNamespace(source_owner={}, package=root, runtime=root / "runtime",
                                 record={"admitted": False}, check=lambda: None, stop=stop)
        runner.run = lambda: runner.stop()
        args = SimpleNamespace(deployment=root / "deployment.conf", output=root / "evidence")
        with patch.object(check_hil.deploy, "Deployment", return_value=runner), \
                patch.object(check_hil.shutil, "copy2", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                check_hil.qualify(args)
        stop.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
