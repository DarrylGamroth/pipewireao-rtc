"""Installed HIL transformation preserves the calibrated science contract."""

import copy
import hashlib
import struct
import tempfile
import tomllib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import export
import export_hil


class HILExportTests(unittest.TestCase):
    def test_simulated_offsets_describe_same_classic_estimator_for_both_owners(self):
        for engine in ("fgn", "jfg"):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                package = Path(directory)
                (package / "calibration").mkdir()
                parameters = [export.asdict(value) for value in export.classic_parameters()]
                origins = [[0, 132], [0, 154]]
                (package / "calibration/subaperture-origins.u32le").write_bytes(
                    b"".join(struct.pack("<II", *pair) for pair in origins))
                (package / "calibration/active-subapertures.u8").write_bytes(bytes([1, 0]))
                config = {"image_rows": 352, "image_columns": 352,
                          "subaperture_rows": 22, "subaperture_columns": 22,
                          "initial_subaperture_origins": origins if engine == "fgn" else None,
                          "active": [True, False] if engine == "fgn" else None}
                graph = {"filter.graph": {"nodes": [{"label": "shack-hartmann-image-f32", "config": config}]}}
                provenance = {"profile": "classic", "engine": engine, "parameters": parameters,
                              "prepared_profile": {"subaperture_origins": origins}}
                before = copy.deepcopy(provenance)
                with patch.object(export_hil.deploy, "decode", return_value=graph):
                    value = export_hil.calibration_inputs(package, provenance, Path("/opt/pipewireao"))
                self.assertEqual(provenance, before)
                self.assertEqual(value["shack_hartmann"]["subaperture_origins"], origins)
                self.assertEqual(value["shack_hartmann"]["active"], [True, False])
                self.assertEqual(value["artifacts"]["background"]["path"], "../calibration/background.f32le")
                self.assertEqual(value["artifacts"]["reference_slopes"]["shape"], [188, 2])
                self.assertEqual(value["shack_hartmann"]["coordinates"]["layout"], "ROW_MAJOR")

    def test_copper_simulated_background_reaches_native_and_julia_graphs(self):
        for engine in ("fgn", "jfg"):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                package = Path(directory)
                for name in ("hil", "graphs", "calibration"):
                    (package / name).mkdir()
                (package / "hil/plant.toml").write_text("simulation-only-model\n")
                (package / "graphs/graph.conf.in").write_text(
                    '{\n    filter.graph = { inputs = [\n            "calibrate:raw"\n] }\n}\n')
                provenance = {"profile": "copper", "engine": engine, "parameters": [{
                    "name": "system-flat", "endpoint": "system-flat:system-flat", "element_type": "F32_LE",
                    "shape": [277], "file": "parameter-system-flat.f32", "schema": ""}]}
                specification = {"owners": [{"role": "julia", "argv": ["julia", "run_island.jl"]}]}
                inputs = export_hil.calibration_inputs(package, provenance, Path("/opt/pipewireao"))
                self.assertEqual(set(inputs["artifacts"]), {"background", "system_flat"})
                result = {"version": 1, "profile": "copper", "model_sha256": export.sha256(package / "hil/plant.toml"),
                          "artifacts": {}}
                for name, descriptor in inputs["artifacts"].items():
                    values = bytes(4 * (4096 if name == "background" else 277))
                    (package / "hil" / descriptor["path"]).write_bytes(values)
                    result["artifacts"][name] = {**descriptor, "sha256": hashlib.sha256(values).hexdigest()}
                export_hil.adopt_simulated_calibration(package, specification, provenance, inputs, result)
                background = next(item for item in provenance["parameters"] if item["name"] == "background")
                self.assertEqual(background["file"], "parameter-background.f32")
                text = (package / "graphs/graph.conf.in").read_text()
                if engine == "fgn":
                    self.assertIn('"pipewireao.startup-parameter.calibrate:background"', text)
                else:
                    self.assertIn('"calibrate:background"', text)
                    self.assertEqual(specification["owners"][0]["argv"][-5:], [
                        "--parameter", "background", "Float32", "64,64", "@PACKAGE@/calibration/parameter-background.f32"])
                with self.assertRaisesRegex(ValueError, "hash differs"):
                    result["artifacts"]["background"]["sha256"] = "0" * 64
                    export_hil.adopt_simulated_calibration(package, specification, provenance, inputs, result)

    def test_simulated_calibration_rejects_wrong_model_before_binding(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "hil").mkdir()
            (package / "hil/plant.toml").write_text("installed-model\n")
            specification, provenance = {"owners": []}, {"profile": "classic"}
            before = copy.deepcopy(specification)
            with self.assertRaisesRegex(ValueError, "installed plant"):
                export_hil.adopt_simulated_calibration(package, specification, provenance,
                                                      {"artifacts": {}}, {"version": 1, "profile": "classic"})
            self.assertEqual(specification, before)

    def test_amdgpu_helpers_inherit_deployment_affinity(self):
        for backend in ("cpu", "cuda", "amdgpu"):
            value = export_hil.simulator_environment(backend)
            self.assertEqual(value["OPENBLAS_NUM_THREADS"], "1")
            self.assertEqual(value["JULIA_NUM_THREADS"], "1,0")
            self.assertEqual(value.get("HSA_OVERRIDE_CPU_AFFINITY_DEBUG"),
                             "0" if backend == "amdgpu" else None)

    def test_four_complete_frame_compositions_keep_science_and_live_routes(self):
        for profile in ("classic", "copper"):
            for engine in ("fgn", "jfg"):
                with self.subTest(profile=profile, engine=engine):
                    matrix = export.Parameter("reconstructor", "reconstruction:reconstructor", "F32_LE",
                                              (221, 376) if profile == "classic" else (253, 3600), "matrix.f32")
                    args = SimpleNamespace(profile=profile, engine=engine, mode="frame", rate_hz=10, readout_us=100)
                    base = export.session(args, matrix, "science")
                    before = copy.deepcopy(base)
                    value = export_hil.hil_session(base)
                    self.assertEqual(base, before)
                    self.assertEqual(value["graphs"], base["graphs"])
                    self.assertEqual(value["sources"][1], base["sources"][1])
                    self.assertEqual(value["parameters"], {})
                    self.assertEqual(value["links"][1], base["links"][1])
                    self.assertEqual(value["execution-groups"][0]["nodes"], ["science"])
                    self.assertTrue(value["links"][0]["passive"])
                    self.assertEqual(value["sources"][0]["ports"][0]["element-type"], "U16_LE")
                    self.assertEqual(value["sinks"][0]["ports"][0]["schema"], export.COMMAND_SCHEMA)
                    self.assertEqual(value["links"][2]["input"], "simulator-command:input_1")

    def test_row_composition_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "complete-frame"):
            export_hil.hil_session({"execution": "row-block"})

    def test_core_loops_match_hil_device_placement(self):
        loops = [{"loop.name": name, "thread.affinity": [cpu]} for name, cpu in
                 (("rtc-data-loop", 2), ("source-loop", 12), ("sink-loop", 8))]
        base = {"context.properties": {"context.data-loops": loops, "core.name": "@REMOTE@"},
                "context.modules": [{"name": "libpipewire-module-client-node"}]}
        before = copy.deepcopy(base)
        value = export_hil.hil_core(base)
        self.assertEqual(base, before)
        self.assertEqual(value["context.properties"]["context.data-loops"], [loops[0]])
        self.assertEqual(value["context.modules"], base["context.modules"])
        with self.assertRaisesRegex(ValueError, "maintained"):
            export_hil.hil_core(value)

    def test_model_period_change_preserves_exposure_and_physics(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plant.toml"
            text = ('[[nodes]]\nname="atmosphere"\n[nodes.config]\n'
                    'atmosphere_step=0.002\nr0=0.15\n'
                    '[[nodes]]\nname="detector"\n[nodes.config]\n'
                    'exposure_duration_s=0.002\ngain=1000.0\n')
            path.write_text(text)
            result, exposure = export_hil.plant_configuration(path, 100)
            self.assertEqual(exposure, 2_000_000)
            before, after = tomllib.loads(text), tomllib.loads(result)
            after["nodes"][0]["config"]["atmosphere_step"] = 0.002
            self.assertEqual(before, after)
            self.assertEqual(path.read_text(), text)
            with self.assertRaisesRegex(ValueError, "exposure"):
                export_hil.plant_configuration(path, 1000)

    def test_backend_dependencies_are_optional_and_selected_plant_is_portable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "hil").mkdir()
            for backend in ("cpu", "cuda", "amdgpu"):
                for plant in ("REVOLTClassicSim", "REVOLTCopperSim"):
                    export_hil.environment(root, plant, backend)
                    value = tomllib.loads((root / "hil/Project.toml").read_text())
                    self.assertEqual(value["sources"][plant]["path"], f"packages/{plant}")
                    self.assertEqual(value["sources"]["PipeWireAO"]["path"], "packages/PipeWireAO")
                    self.assertEqual(value["sources"]["FilterGraphAlgorithms"]["path"], "packages/FilterGraphAlgorithms")
                    other = "REVOLTCopperSim" if plant == "REVOLTClassicSim" else "REVOLTClassicSim"
                    self.assertNotIn(other, value["deps"])
                    self.assertEqual("CUDA" in value["deps"], backend == "cuda")
                    self.assertEqual("AMDGPU" in value["deps"], backend == "amdgpu")

    def test_julia_owner_uses_same_portable_transport_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = root / "jfg/deployment/Project.toml"
            project.parent.mkdir(parents=True)
            project.write_text('[deps]\nPipeWireAO="uuid"\n[sources]\nJuliaFilterGraph={path="../julia/JuliaFilterGraph"}\n')
            export_hil.julia_owner_environment(root)
            value = tomllib.loads(project.read_text())
            self.assertEqual(value["sources"]["PipeWireAO"]["path"], "../../hil/packages/PipeWireAO")
            self.assertEqual(value["sources"]["JuliaFilterGraph"]["path"], "../julia/JuliaFilterGraph")
            with self.assertRaisesRegex(ValueError, "already overrides"):
                export_hil.julia_owner_environment(root)


if __name__ == "__main__":
    unittest.main()
