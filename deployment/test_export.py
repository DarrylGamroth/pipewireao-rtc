"""Exporter contracts; optional real generator matrix uses explicit prerequisites."""

import json
import os
from pathlib import Path
import shutil
import tempfile
from types import SimpleNamespace
import unittest

import deploy
import export


class ExportContracts(unittest.TestCase):
    def test_all_session_contracts_keep_exact_science_shapes_and_parameter_routes(self):
        for profile in ("classic", "copper"):
            for engine in ("fgn", "jfg"):
                for mode in ("frame", "row"):
                    with self.subTest(profile=profile, engine=engine, mode=mode):
                        classic = profile == "classic"
                        matrix = export.Parameter("reconstructor", "reconstruction:reconstructor" if classic
                                                  else "reconstruct:reconstructor", "F32_LE",
                                                  (221, 376) if classic else (253, 3600), "matrix.f32",
                                                  "org.calculon.ao.shwfs-reconstructor/1" if classic
                                                  else "org.calculon.ao.pwfs-reconstructor/1")
                        args = SimpleNamespace(profile=profile, engine=engine, mode=mode,
                                               rate_hz=1000, readout_us=800)
                        value = export.session(args, matrix, "science-graph")
                        rows = (11 if classic else 32) if mode == "row" else (352 if classic else 64)
                        width = 352 if classic else 64
                        source, publisher = value["sources"]
                        self.assertEqual(source["ports"][0]["shape"], [rows, width])
                        self.assertEqual(source["ports"][0]["rate"], f"{1000 * width // rows}/1")
                        self.assertFalse(source["args"]["api.fits.loop"])
                        self.assertEqual(publisher["ports"][0]["shape"], list(matrix.shape))
                        self.assertEqual(value["graphs"][0]["ports"][1]["shape"], list(matrix.shape))
                        self.assertEqual(value["parameters"], {})
                        self.assertEqual(value["links"][1]["input"],
                                         "science-graph:" + (matrix.endpoint if engine == "fgn" else matrix.name))
                        self.assertTrue(value["links"][1]["passive"])
                        self.assertEqual(value["sinks"][0]["ports"][0]["shape"], [277])
                        self.assertEqual(value["sinks"][0]["ports"][0]["schema"], export.COMMAND_SCHEMA)
                        self.assertEqual(value["graphs"][0].get("ownership"), "external" if engine == "jfg" else None)

    def test_native_transform_retains_science_and_declares_feedback_and_stopped_owner(self):
        source = '{\n    node.name = original\n    filter.graph = {\n nodes = [ { props = { gain = -0.3 pole = 0.99 } } ]\n links = []\n outputs = [ "extra:output" ]\n }\n}\n'
        parameter = export.Parameter("reconstructor", "reconstruction:reconstructor", "F32_LE",
                                     (221, 376), "reconstructor.f32le")
        origins = export.Parameter("origins", "shack-hartmann:subaperture-origins", "U32_LE", (188, 2), "origins.u32le")
        active = export.Parameter("active", "shack-hartmann:active", "Bool", (188,), "active.u8")
        graph = export.native_graph(source, [parameter, origins, active], "classic", "installed-graph")
        self.assertIn("gain = -0.3 pole = 0.99", graph)
        self.assertIn('"pdm-command:demanded" "vdm-feedback-to-controller:controller-constraint-feedback"', graph)
        self.assertNotIn('"extra:output"', graph)
        self.assertIn('"pipewireao.feedback.closed-loop-correction:constraint-feedback"', graph)
        self.assertIn('"pipewireao.startup-parameter.reconstruction:reconstructor"', graph)
        self.assertIn("pipewireao.run-control = true", graph)
        self.assertIn("pipewireao.reset-control = true", graph)
        self.assertNotIn("pipewireao.startup-parameter.shack-hartmann:subaperture-origins", graph)
        self.assertNotIn("pipewireao.startup-parameter.shack-hartmann:active", graph)

    def test_native_classic_active_flags_are_preserved_in_constructor_fields(self):
        for source in ("config = { coordinate_scale = 1.0 }", "config = { active = null }"):
            graph = export.classic_active_mask(source, b"\x01\x00\x01")
            self.assertIn("active = [ true false true ]", graph)
            self.assertNotIn("active = null", graph)
        with self.assertRaises(ValueError):
            export.classic_active_mask("config = {}", b"\x01")

    def test_unexpected_graph_output_declarations_reject_export(self):
        for source in ("filter.graph = {}", "outputs = [] outputs = []"):
            with self.assertRaisesRegex(ValueError, "expected one"):
                export.terminal_outputs(source, ["command:demanded"])

    def test_parameter_size_and_boolean_encoding_are_checked_before_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            parameter = export.Parameter("active", "measure:active", "Bool", (2,), "active.u8")
            for payload in (b"\x00", b"\x00\x02"):
                (root / parameter.file).write_bytes(payload)
                with self.assertRaises(ValueError):
                    export.validate_parameter(root, parameter)
            (root / parameter.file).write_bytes(b"\x00\x01")
            export.validate_parameter(root, parameter)

    def test_existing_output_and_invalid_timing_reject_before_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            existing = SimpleNamespace(output=path)
            with self.assertRaisesRegex(ValueError, "must be new"):
                export.export(existing)
            for rate, readout in ((0, 1), (1000, 0), (1000, 1000)):
                invalid = SimpleNamespace(output=path / "new", rate_hz=rate, readout_us=readout)
                with self.assertRaises(ValueError):
                    export.export(invalid)
            self.assertFalse((path / "new").exists())


PREREQUISITES = ("RTC_EXPORT_ALGORITHMS_ROOT", "RTC_EXPORT_JFG_ROOT", "RTC_EXPORT_FGN_BUNDLE",
                 "RTC_EXPORT_CLASSIC_CALIBRATION", "RTC_EXPORT_COPPER_CALIBRATION", "RTC_EXPORT_RTC_BINARY")


@unittest.skipUnless(all(os.environ.get(name) for name in PREREQUISITES),
                     "real generator matrix needs explicit RTC_EXPORT_* prerequisite paths")
class MaintainedGeneratorMatrix(unittest.TestCase):
    def test_all_eight_packages_validate_relocate_and_detect_modified_artifacts(self):
        with tempfile.TemporaryDirectory(prefix="rtc-export-matrix-") as directory:
            root = Path(directory)
            for profile in ("classic", "copper"):
                for engine in ("fgn", "jfg"):
                    for mode in ("frame", "row"):
                        with self.subTest(profile=profile, engine=engine, mode=mode):
                            output = root / f"{profile}-{engine}-{mode}"
                            argv = ["--output", str(output), "--profile", profile, "--engine", engine,
                                    "--mode", mode, "--rate-hz", "1000", "--readout-us", "800"]
                            for key in PREREQUISITES:
                                argv.extend(["--" + key.removeprefix("RTC_EXPORT_").lower().replace("_", "-"),
                                             os.environ[key]])
                            path = export.export(export.arguments(argv))
                            specification = deploy.profile(path, Path("/opt/pipewireao"))
                            self.assertEqual(specification["name"], f"revolt-{profile}-{engine}-{mode}")
                            self.assertNotIn("deployment.conf", specification["artifacts"])
                            for asset in specification["artifacts"]:
                                self.assertFalse({"benchmark", "benchmarks", "tests", "test", ".git", "compiled"}
                                                 & set(Path(asset).parts), asset)
                            science = json.loads((output / "provenance.json").read_text())
                            matrix = next(item for item in science["parameters"] if item["name"] == "reconstructor")
                            self.assertEqual(matrix["shape"], [221, 376] if profile == "classic" else [253, 3600])
                            relocated = root / "relocated" / output.name
                            shutil.copytree(output, relocated)
                            deploy.profile(relocated / "deployment.conf", Path("/opt/pipewireao"))
                            parameter = relocated / "calibration" / matrix["file"]
                            with parameter.open("r+b") as payload:
                                original = payload.read(1)
                                payload.seek(0)
                                payload.write(bytes([original[0] ^ 1]))
                            with self.assertRaisesRegex(deploy.DeploymentError, "artifact hash mismatch"):
                                deploy.profile(relocated / "deployment.conf", Path("/opt/pipewireao"))


if __name__ == "__main__":
    unittest.main()
