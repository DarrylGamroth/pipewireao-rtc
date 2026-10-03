"""Calibration graph selection retains deployed science and absolute commands."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import deploy
import export
import export_calibration


def fixture(profile, engine):
    classic = profile == "classic"
    height = 352 if classic else 64
    nodes = [
        {"name": "pixel", "label": "pixel-calibration-u16-f32", "config": {
            "image_rows": height, "image_columns": height, "initial_flat": None}},
        {"name": "measure", "label": "shack-hartmann-image-f32" if classic else
         "pyramid-pixel-image-f32" if engine == "fgn" else "pyramid-pupil-image-f32",
         "config": {"image_rows": height, "image_columns": height,
                    "subaperture_count": 188, "subaperture_rows": 22, "subaperture_columns": 22,
                    "pupil_rows": 30, "pupil_columns": 30,
                    "reference_slopes": None, "active": [True, False]}},
        {"name": "reconstruct", "label": "reconstructor", "config": {}},
        {"name": "integrate", "label": "closed-loop-correction-f32", "config": {}},
        {"name": "flat", "label": "pdm-system-flat-f32", "config": {}},
        {"name": "command", "label": "pdm-command-f32", "config": {
            "actuator_count": 277, "lower_limit": -0.8, "upper_limit": 0.8,
            "slew_limit": None, "quantization_origin": None}}]
    return {"node.name": "science", "pipewireao.feedback.integrate:constraint-feedback": "feedback",
            "pipewireao.startup-parameter.reconstruct:reconstructor": "matrix.f32",
            "pipewireao.startup-parameter.pixel:background": "background.f32",
            "pipewireao.run-control": True, "filter.graph": {
                "nodes": nodes, "workers": {"helpers": 0},
                "links": [{"output": "pixel:calibrated", "input": "measure:image"}],
                "inputs": ["pixel:raw", "pixel:background", "measure:coordinates",
                           "reconstruct:reconstructor", "integrate:constraint-feedback", "flat:system-flat"],
                "outputs": ["command:demanded"]}}


class CalibrationGraphContracts(unittest.TestCase):
    def test_graph_encoder_uses_standard_assignments_for_julia_reader(self):
        text = export_calibration.spa_json({"node.name": "test", "filter.graph": {
            "nodes": [{"config": {"active": [True, False], "reference": None}}], "inputs": []}})
        self.assertIn('"node.name" = "test"', text)
        self.assertIn('"active" = [ true false ]', text)
        self.assertIn('"reference" = null', text)
        self.assertNotIn('"node.name":', text)

    def test_four_selected_graphs_preserve_nodes_and_remove_controller_and_flat(self):
        for profile in ("classic", "copper"):
            for engine in ("fgn", "jfg"):
                with self.subTest(profile=profile, engine=engine):
                    source = fixture(profile, engine)
                    before = copy.deepcopy(source)
                    graphs = export_calibration.split_graph(source, profile, engine, "calibration")
                    self.assertEqual(source, before)
                    wfs, command = graphs["wfs"], graphs["command"]
                    self.assertEqual(wfs["filter.graph"]["nodes"], source["filter.graph"]["nodes"][:2])
                    self.assertEqual(command["filter.graph"]["nodes"], source["filter.graph"]["nodes"][-1:])
                    self.assertEqual(wfs["filter.graph"]["inputs"], source["filter.graph"]["inputs"][:3])
                    self.assertEqual(command["filter.graph"]["inputs"], ["command:requested"])
                    self.assertEqual(command["filter.graph"]["outputs"], ["command:demanded", "command:constraint-feedback"])
                    self.assertEqual(command["filter.graph"]["links"], [])
                    self.assertEqual(wfs["filter.graph"]["outputs"],
                                     ["measure:slopes", "measure:flux", "measure:validity"] if profile == "classic" else
                                     ["measure:reconstruction-pixels", "measure:mean-pupil-intensity"])
                    for graph in graphs.values():
                        self.assertEqual(graph["filter.graph"]["workers"], {"helpers": 0})
                        self.assertTrue(graph["pipewireao.run-control"])
                        self.assertFalse(any(key.startswith(("pipewireao.feedback.", "pipewireao.startup-parameter."))
                                             for key in graph))

    def test_owner_preloads_only_retained_wfs_parameters_and_warms_published_outputs(self):
        graph = export_calibration.split_graph(fixture("classic", "jfg"), "classic", "jfg", "calibration")["wfs"]
        parameters = [export.Parameter("background", "pixel:background", "F32_LE", (352, 352), "background.f32"),
                      export.Parameter("reconstructor", "reconstruct:reconstructor", "F32_LE", (221, 376), "matrix.f32")]
        selected = export_calibration.graph_parameters(graph, [export.asdict(item) for item in parameters])
        self.assertEqual(selected, parameters[:1])
        argv = export_calibration.julia_arguments(graph, selected, "wfs", "10/1", "/opt/julia/bin/julia")
        offset = argv.index("--parameter")
        self.assertEqual(argv[offset:offset + 5], ["--parameter", "background", "Float32", "352,352",
                                                "@PACKAGE@/calibration/background.f32"])
        self.assertNotIn("--feedback", argv)
        self.assertNotIn("matrix.f32", " ".join(argv))
        self.assertEqual(argv[-6:], ["--warmup-output", "slopes", "--warmup-output", "flux", "--warmup-output", "validity"])

    def test_boundary_schemas_and_shape_order_match_declarations(self):
        for engine in ("fgn", "jfg"):
            for profile in ("classic", "copper"):
                graphs = export_calibration.split_graph(fixture(profile, engine), profile, engine, "calibration")
                ports = export_calibration.boundary_contract(graphs["wfs"], profile, "wfs", engine)
                self.assertEqual(ports[1]["shape"], [188, 2] if profile == "classic" else [4, 900])
                self.assertEqual(ports[-1]["element-type"], "BOOL8" if profile == "classic" else "F32_LE")
                command = export_calibration.boundary_contract(graphs["command"], profile, "command", engine)
                self.assertEqual([item["schema"] for item in command], [export_calibration.REQUESTED_SCHEMA,
                                  export.COMMAND_SCHEMA, export_calibration.FEEDBACK_SCHEMA])
                self.assertTrue(all(item["shape"] == [277] for item in command))

    def test_ambiguous_topology_and_geometry_reject(self):
        for change in ("duplicate", "missing-link", "bad-detector", "bad-command", "bad-measurements"):
            with self.subTest(change=change):
                source = fixture("classic", "fgn")
                nodes = source["filter.graph"]["nodes"]
                if change == "duplicate":
                    nodes.append(copy.deepcopy(nodes[0]))
                elif change == "missing-link":
                    source["filter.graph"]["links"] = []
                elif change == "bad-detector":
                    nodes[0]["config"]["image_rows"] = 64
                elif change == "bad-measurements":
                    nodes[1]["config"]["subaperture_count"] = 187
                else:
                    nodes[-1]["config"]["actuator_count"] = 221
                with self.assertRaises(ValueError):
                    export_calibration.split_graph(source, "classic", "fgn", "calibration")

    def test_existing_output_rejects_before_reading_source(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "must be new"):
                export_calibration.export(SimpleNamespace(output=Path(directory)))


@unittest.skipUnless(os.environ.get("RTC_CALIBRATION_EXPORT_BASE_ROOT") and
                     os.environ.get("RTC_CALIBRATION_EXPORT_PREFIX"),
                     "real matrix requires four installed RTC_CALIBRATION_EXPORT_BASE_ROOT packages and PREFIX")
class InstalledCalibrationGraphMatrix(unittest.TestCase):
    def test_four_exports_preserve_deployed_nodes_arrays_and_provenance(self):
        root = Path(os.environ["RTC_CALIBRATION_EXPORT_BASE_ROOT"])
        prefix = Path(os.environ["RTC_CALIBRATION_EXPORT_PREFIX"])
        with tempfile.TemporaryDirectory(prefix="rtc-calibration-export-matrix-") as directory:
            for profile in ("classic", "copper"):
                for engine in ("fgn", "jfg"):
                    with self.subTest(profile=profile, engine=engine):
                        base = root / f"{profile}-{engine}-final"
                        output = Path(directory) / f"{profile}-{engine}"
                        specification = deploy.profile(base / "deployment.conf", prefix)
                        before = json.loads((base / "provenance.json").read_text())
                        source = deploy.decode(base / "graphs/graph.conf.in", prefix)
                        path = export_calibration.export(SimpleNamespace(base_package=base, output=output, pipewire_prefix=prefix))
                        provenance = json.loads(path.read_text())
                        self.assertEqual(provenance["source_provenance"], before)
                        self.assertEqual(provenance["operational_acquisition"], "not-established")
                        self.assertFalse((output / "deployment.conf").exists())
                        self.assertFalse(provenance["additional_system_flat"])
                        for record in provenance["graphs"]:
                            graph = deploy.decode(output / record["file"], prefix)
                            for node in graph["filter.graph"]["nodes"]:
                                self.assertEqual(node, next(item for item in source["filter.graph"]["nodes"] if item["name"] == node["name"]))
                            for parameter in record["parameters"]:
                                payload = output / "calibration" / parameter["file"]
                                self.assertEqual(payload.read_bytes(), (base / "calibration" / parameter["file"]).read_bytes())
                                if engine == "fgn":
                                    self.assertEqual(graph["pipewireao.startup-parameter." + parameter["endpoint"]],
                                                     "@PACKAGE@/calibration/" + parameter["file"])
                            if engine == "jfg":
                                self.assertEqual(record["owner_arguments"][0], next(owner for owner in specification["owners"]
                                                 if owner["role"] == "julia")["argv"][0])
                                self.assertNotIn("--feedback", record["owner_arguments"])
                                if os.environ.get("RTC_CALIBRATION_EXPORT_CHECK_JULIA") == "1":
                                    argv = [argument.replace("@PACKAGE@", str(output)).replace("@REMOTE@", "pipewire-ao-0")
                                            for argument in record["owner_arguments"]]
                                    result = subprocess.run([*argv, "--check"], capture_output=True, text=True,
                                                            timeout=90, env={**os.environ, "OPENBLAS_NUM_THREADS": "1"})
                                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                                    self.assertIn("JULIA_FILTER_GRAPH_CHECKED", result.stdout)
                        self.assertNotIn("reconstructor", [item["name"] for item in provenance["parameters"]])
                        for relative, digest in provenance["artifacts"].items():
                            self.assertEqual(export.sha256(output / relative), digest)


if __name__ == "__main__":
    unittest.main()
