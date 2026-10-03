"""Calibration graph selection retains deployed science and absolute commands."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

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
    def test_acceptance_mask_matches_deployed_active_parameter(self):
        source = fixture("classic", "fgn")
        graph = export_calibration.split_graph(source, "classic", "fgn", "calibration")["wfs"]
        configured = [True] * 188
        configured[85] = False
        graph["filter.graph"]["nodes"][1]["config"]["active"] = configured
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "calibration").mkdir()
            self.assertEqual(export_calibration.classic_active(graph, [], package), bytes(configured))
            # A supplied public parameter replaces the constructor seed.
            supplied = bytes([1, 0] + [1] * 186)
            (package / "calibration/active.u8").write_bytes(supplied)
            parameter = export.Parameter("active", "measure:active", "Bool", (188,), "active.u8")
            self.assertEqual(export_calibration.classic_active(graph, [parameter], package), supplied)
            for invalid in (bytes(188), bytes([2]) * 188, bytes([1]) * 187, bytes([1]) * 189):
                (package / "calibration/active.u8").write_bytes(invalid)
                with self.assertRaises(ValueError):
                    export_calibration.classic_active(graph, [parameter], package)
            with self.assertRaises(ValueError):
                export_calibration.classic_active(graph, [parameter, parameter], package)
            for invalid in (None, [True], [1] * 188, [False] * 188):
                graph["filter.graph"]["nodes"][1]["config"]["active"] = invalid
                with self.assertRaises(ValueError):
                    export_calibration.classic_active(graph, [], package)

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

    def test_initial_calibration_session_has_exact_external_boundaries_and_links(self):
        for engine in ("fgn", "jfg"):
            for profile in ("classic", "copper"):
                with self.subTest(engine=engine, profile=profile):
                    graphs = export_calibration.split_graph(
                        fixture(profile, engine), profile, engine, "calibration")
                    records = [{"role": role, "node.name": graph["node.name"],
                                "ports": export_calibration.boundary_contract(
                                    graph, profile, role, engine)}
                               for role, graph in graphs.items()]
                    session = export_calibration.calibration_session(records, profile, engine, "10/1")
                    self.assertEqual(session["execution"], "complete-frame")
                    self.assertEqual([item["node.name"] for item in session["sources"]],
                                     ["simulator-wfs", "calibration-probe"])
                    self.assertEqual([item["node.name"] for item in session["sinks"]],
                                     ["simulator-command", "calibration-feedback"] +
                                     (["calibration-slopes", "calibration-flux", "calibration-validity"]
                                      if profile == "classic" else
                                      ["calibration-reconstruction-pixels",
                                       "calibration-mean-pupil-intensity"]) + ["calibration-raw"])
                    self.assertTrue(all(item["ownership"] == "external"
                                        for item in session["sources"] + session["sinks"]))
                    if engine == "fgn":
                        self.assertTrue(all(item["factory"] == "pipewireao.fgn-native"
                                            for item in session["graphs"]))
                        graph_by_role = {item["node.name"].rsplit("-", 1)[-1]: item
                                         for item in session["graphs"]}
                        self.assertEqual(graph_by_role["wfs"]["config.path"],
                                         "${PIPEWIREAO_RTC_GRAPH_CALIBRATION_WFS}")
                        self.assertEqual(graph_by_role["command"]["config.path"],
                                         "${PIPEWIREAO_RTC_GRAPH_CALIBRATION_COMMAND}")
                    else:
                        self.assertTrue(all(item["ownership"] == "external" and
                                            item["run-control"] == "session"
                                            for item in session["graphs"]))
                        self.assertTrue(all("config.path" not in item for item in session["graphs"]))
                    edges = {(item["output"], item["input"]) for item in session["links"]}
                    self.assertEqual(len(edges), len(session["links"]))
                    wfs_name, command_name = (item["node.name"] for item in session["graphs"])
                    self.assertIn(("simulator-wfs:output_1", f"{wfs_name}:{records[0]['ports'][0]['name']}"), edges)
                    self.assertIn(("simulator-wfs:output_1", "calibration-raw:input_1"), edges)
                    self.assertIn(("calibration-probe:output_1",
                                   f"{command_name}:{records[1]['ports'][0]['name']}"), edges)
                    self.assertIn((f"{command_name}:{records[1]['ports'][1]['name']}",
                                   "simulator-command:input_1"), edges)
                    self.assertIn((f"{command_name}:{records[1]['ports'][2]['name']}",
                                   "calibration-feedback:input_1"), edges)
                    for index, name in enumerate(session["sinks"][2:-1], start=1):
                        self.assertIn((f"{wfs_name}:{records[0]['ports'][index]['name']}",
                                       f"{name['node.name']}:input_1"), edges)
                    self.assertEqual(session["sources"][1]["ports"][0]["schema"],
                                     export_calibration.REQUESTED_SCHEMA)
                    self.assertEqual(session["sinks"][1]["ports"][0]["schema"],
                                     export_calibration.FEEDBACK_SCHEMA)
                    self.assertTrue(all(port["rate"] == "10/1"
                                        for item in session["sources"] + session["sinks"]
                                        for port in item["ports"]))

    def test_deployment_descriptor_reuses_hil_source_owner_and_splits_julia_roles(self):
        for engine in ("fgn", "jfg"):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                base, package = root / "base", root / "package"
                for path in (base / "bin", base / "hil", package / "bin", package / "graphs",
                             package / "calibration", package / "hil"):
                    path.mkdir(parents=True, exist_ok=True)
                (base / "core.conf.in").write_text("{}\n")
                (base / "bin/pipewireao-rtc").write_text("stale inherited runner\n")
                (package / "bin/pipewireao-rtc").write_text("explicit selected runner\n")
                (base / "client-simulator.conf.in").write_text("{}\n")
                (base / "client-julia.conf.in").write_text("{}\n")
                (package / "hil/calibration_acquisition.jl").write_text("module CalibrationAcquisition end\n")
                (package / "hil/calibration_owner.jl").write_text("# planned owner\n")
                (package / "wfs.conf").write_text("{}\n")
                (package / "command.conf").write_text("{}\n")
                owners = [{"role": "simulator", "argv": ["julia", "@PACKAGE@/hil/simulator.jl",
                          "--prepared-event", "@RUNTIME@/simulator.prepared"],
                          "environment": {}, "prepared": "simulator.prepared", "connect": "simulator.connect",
                          "connected": "simulator.connected", "quit": "simulator.quit",
                          "control-request": "simulator.control.request",
                          "control-reply": "simulator.control.reply"}]
                placements = {role: {"cpus": [1], "leader-cpu": 1, "rt-priority": 0,
                                     "threads": [], "locked-bytes": 0}
                              for role in ("core", "rtc", "simulator")}
                clients = {"core": "client-simulator.conf.in", "rtc": "client-simulator.conf.in",
                           "simulator": "client-simulator.conf.in"}
                specification = {"name": "revolt-classic-calibration", "session": "old-session.conf.in",
                                 "core": "core.conf.in", "client": clients, "placement": placements,
                                 "owners": owners, "source-owner": "simulator", "environment": {},
                                 "artifacts": {}, "cpu-latency-us": None}
                records = [{"role": role, "node.name": f"calibration-{role}",
                            "owner_arguments": ["julia", "--session-run-control", "--graph",
                                                f"@PACKAGE@/graphs/{role}.conf.in"]}
                           for role in ("wfs", "command")]
                old_julia_placement = None
                if engine == "jfg":
                    owner = {"role": "julia", "argv": ["julia", "--pin-cpus", "14,10",
                             "--feedback", "old-feedback"], "environment": {},
                             "prepared": "julia.prepared", "connect": "julia.connect",
                             "connected": "julia.connected", "quit": "julia.quit"}
                    specification["owners"].append(owner)
                    placements["julia"] = dict(placements["rtc"])
                    old_julia_placement = copy.deepcopy(placements["julia"])
                    clients["julia"] = "client-julia.conf.in"
                with patch.object(export_calibration.deploy, "profile",
                                  side_effect=lambda path, prefix: json.loads(path.read_text())):
                    result = export_calibration.deployment_descriptor(
                        package, base, specification, records, "classic", engine,
                        {"profile": "development", "execution": "complete-frame", "rate": "10/1",
                         "sources": [], "graphs": [], "sinks": [], "links": []},
                        Path("/opt/pipewireao"))
                owner_by_role = {item["role"]: item for item in result["owners"]}
                if engine == "fgn":
                    self.assertEqual(result["environment"]["PIPEWIREAO_RTC_GRAPH_CALIBRATION_WFS"],
                                     "@RUNTIME@/wfs.conf")
                    self.assertEqual(result["environment"]["PIPEWIREAO_RTC_GRAPH_CALIBRATION_COMMAND"],
                                     "@RUNTIME@/command.conf")
                else:
                    self.assertNotIn("PIPEWIREAO_RTC_GRAPH_CALIBRATION_WFS", result["environment"])
                runner_hash = export.sha256(package / "bin/pipewireao-rtc")
                self.assertEqual(package.joinpath("bin/pipewireao-rtc").read_text(),
                                 "explicit selected runner\n")
                self.assertEqual(result["artifacts"]["bin/pipewireao-rtc"], runner_hash)
                self.assertEqual(owner_by_role["simulator"]["argv"][1],
                                 "@PACKAGE@/hil/calibration_owner.jl")
                self.assertEqual(owner_by_role["simulator"]["argv"][-4:],
                                 ["--calibration-socket", "@RUNTIME@/calibration.sock",
                                  "--wfs-active", "@PACKAGE@/calibration/wfs-active.u8"])
                self.assertNotIn("julia", result["client"] if engine == "jfg" else {})
                if engine == "jfg":
                    self.assertEqual({role for role in owner_by_role if role.startswith("julia-")},
                                     {"julia-wfs", "julia-command"})
                    self.assertTrue(all("--session-run-control" in owner_by_role[role]["argv"]
                                        for role in ("julia-wfs", "julia-command")))
                    for role in ("julia-wfs", "julia-command"):
                        argv = owner_by_role[role]["argv"]
                        pin_index = argv.index("--pin-cpus")
                        self.assertEqual(argv[pin_index + 1], "14,10")
                        self.assertEqual(argv.count("--pin-cpus"), 1)
                        self.assertNotIn("--feedback", argv)
                        self.assertEqual(result["placement"][role], old_julia_placement)

    def test_julia_pin_cpus_are_preserved_only_once_and_reject_malformed_options(self):
        self.assertEqual(export_calibration.julia_pin_cpu_arguments(["julia"]), [])
        self.assertEqual(export_calibration.julia_pin_cpu_arguments(
            ["julia", "--pin-cpus", "14,10", "--feedback", "old-feedback"]),
            ["--pin-cpus", "14,10"])
        self.assertEqual(export_calibration.julia_pin_cpu_arguments(
            ["julia", "--pin-cpus=14,10"]), ["--pin-cpus", "14,10"])
        for argv in (["julia", "--pin-cpus", "14,10", "--pin-cpus", "12,8"],
                     ["julia", "--pin-cpus"],
                     ["julia", "--pin-cpus", ""],
                     ["julia", "--pin-cpus", "--feedback"],
                     ["julia", "--pin-cpus="]):
            with self.subTest(argv=argv), self.assertRaisesRegex(ValueError, "--pin-cpus"):
                export_calibration.julia_pin_cpu_arguments(argv)

    def test_deployment_descriptor_rejects_missing_hil_source_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base, package = root / "base", root / "package"
            (base / "bin").mkdir(parents=True)
            (package / "bin").mkdir(parents=True)
            (package / "session.conf.in").write_text("{}\n")
            (base / "core.conf.in").write_text("{}\n")
            (base / "bin/pipewireao-rtc").write_text("runner\n")
            specification = {"owners": [], "source-owner": "simulator", "client": {},
                             "placement": {}, "name": "calibration"}
            with self.assertRaisesRegex(ValueError, "existing HIL source owner"):
                export_calibration.deployment_descriptor(
                    package, base, specification, [], "classic", "fgn", {}, Path("/opt/pw"))

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

    def test_calibration_binary_is_required_only_for_deployment_and_copied_with_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "new-parent" / "export"
            args = SimpleNamespace(output=output, deployment=True,
                                   base_package=root / "missing-base",
                                   calibration_binary=root / "missing-rtc-calibrate",
                                   rtc_binary=root / "pipewireao-rtc")
            with self.assertRaisesRegex(ValueError, "--calibration-binary"):
                export_calibration.export(args)
            self.assertFalse(output.exists())
            self.assertFalse(output.parent.exists())
            args.calibration_binary.mkdir()
            with self.assertRaisesRegex(ValueError, "--calibration-binary"):
                export_calibration.export(args)
            self.assertFalse(output.parent.exists())
            args.calibration_binary.rmdir()
            args.calibration_binary.write_bytes(b"compiled calibration CLI\n")
            with self.assertRaisesRegex(ValueError, "--rtc-binary"):
                export_calibration.export(args)
            self.assertFalse(output.exists())
            self.assertFalse(output.parent.exists())
            args.rtc_binary.mkdir()
            with self.assertRaisesRegex(ValueError, "--rtc-binary"):
                export_calibration.export(args)
            self.assertFalse(output.exists())
            self.assertFalse(output.parent.exists())
            self.assertIsNone(export_calibration.selected_calibration_binary(
                SimpleNamespace(deployment=False)))
            self.assertIsNone(export_calibration.selected_rtc_binary(
                SimpleNamespace(deployment=False, rtc_binary=root / "missing")))
            parsed = export_calibration.arguments(["--base-package", str(root / "base"),
                "--output", str(root / "assets"), "--pipewire-prefix", str(root / "prefix"),
                "--rtc-binary", str(root / "rtc")])
            self.assertIsNone(parsed.calibration_binary)
            self.assertEqual(parsed.rtc_binary, root / "rtc")

            source = root / "rtc-calibrate"
            source.write_bytes(b"compiled calibration CLI\n")
            destination = root / "package"
            (destination / "bin").mkdir(parents=True)
            record = export_calibration.copy_calibration_binary(destination, source)
            self.assertEqual(record["path"], "bin/rtc-calibrate")
            copied = destination / record["path"]
            self.assertEqual(copied.read_bytes(), source.read_bytes())
            self.assertEqual(record["sha256"], export.sha256(copied))

            runner = root / "current-pipewireao-rtc"
            runner.write_bytes(b"current RTC runner\n")
            runner_record = export_calibration.copy_rtc_binary(destination, runner)
            copied_runner = destination / runner_record["path"]
            self.assertEqual(runner_record["path"], "bin/pipewireao-rtc")
            self.assertEqual(copied_runner.read_bytes(), runner.read_bytes())
            self.assertEqual(runner_record["sha256"], export.sha256(copied_runner))


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
