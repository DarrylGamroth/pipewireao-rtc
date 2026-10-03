"""Installed HIL transformation preserves the calibrated science contract."""

import copy
import hashlib
import json
import math
import shutil
import struct
import tempfile
import tomllib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import export
import export_hil
import export_calibration
import calibration_campaign


class MeasuredFixture:
    """Small synthetic evidence in the existing campaign schema; no live RTC."""

    def __init__(self, root, engine):
        self.root = root
        self.campaign = root / "campaign"
        self.campaign.mkdir()
        self.engine = engine
        self.origins = [[0, 0] for _ in range(188)]
        self.mask = bytes([1] * 184 + [0] * 4)
        self.recipe = calibration_campaign.validate_recipe({
            "version": 1, "dark_frames": 16, "training_frames": 16, "qualification_frames": 16,
            "reference": [0.0] * 277, "candidate_mask": [True] * 188,
            "seeds": dict(zip(("dark", "training", "qualification", "interaction"), range(4))),
            "lamp_magnitude": 0.5, "minimum_flux": [2000.0] * 188, "adc_upper_rail": 4095,
            "maximum_reference_residual": 0.1, "amplitudes": [0.125] * 277, "frames_per_probe": 2,
            "settling": {"kind": "discard_exposures", "frames": 1},
            "request_timeout_ns": 20_000_000_000, "stage_timeout_seconds": 180})
        self.payloads = {name: bytes(math.prod(shape) * {"Bool": 1, "F32_LE": 4, "F64_LE": 8}[element])
                         for name, (element, shape, _) in export_hil.MEASURED_ARTIFACTS.items()}
        self.payloads["measured-background.f32le"] = struct.pack("<f", 3.25) * (352 * 352)
        self.payloads["measured-reference-slopes.f32le"] = struct.pack("<f", 0.125) * 376
        self.payloads["measured-active.u8"] = self.mask
        self.result = {"version": 1, "phase": "complete-candidate", "stages": {}, "artifacts": {}}
        for name, payload in self.payloads.items():
            (self.campaign / name).write_bytes(payload)
            self.result["artifacts"][name] = hashlib.sha256(payload).hexdigest()
        self.write(self.campaign / "recipe.json", self.recipe)
        self.write(self.campaign / "interaction-plan.json", {"version": 1, "reference": [0.0] * 277, "measurements": 376})
        for stage, seed in self.recipe["seeds"].items():
            active = bytes([1] * 188) if stage in ("dark", "training") else self.mask
            background = bytes(495616) if stage == "dark" else self.payloads["measured-background.f32le"]
            references = bytes(1504) if stage in ("dark", "training") else self.payloads["measured-reference-slopes.f32le"]
            base = self.campaign / (stage + "-base")
            provenance, spec, graph = self.package(base, active, background, references)
            provenance["hil"] = {"backend": "cpu"}
            provenance["campaign_stage_inputs"] = {"recipe": self.recipe}
            self.write(base / "provenance.json", provenance)
            self.hash_package(base, spec)
            package = self.campaign / (stage + "-package")
            shutil.copytree(base, package)
            (package / "hil").mkdir()
            (package / "hil/plant.toml").write_text(self.model(seed, 0.5))
            wfs = copy.deepcopy(graph)
            wfs["filter.graph"]["nodes"] = graph["filter.graph"]["nodes"][:2]
            self.write(package / "graphs/wfs.conf.in", wfs)
            (package / "calibration/wfs-active.u8").write_bytes(active)
            self.write(package / "provenance.json", {"source_provenance": provenance,
                "source_provenance_sha256": export.sha256(base / "provenance.json"),
                "source_graph_sha256": export.sha256(base / "graphs/graph.conf.in"),
                "source_deployment_sha256": export.sha256(base / "deployment.conf")})
            deployed_spec = copy.deepcopy(spec)
            if engine == "jfg":
                deployed_spec["owners"][0]["role"] = "julia-wfs"
            self.hash_package(package, deployed_spec)
            detector = next(node for node in tomllib.loads(self.model(seed, 0.5))["nodes"] if node["name"] == "detector")["config"]
            startup = {"version": 1, "profile": "classic", "backend": "cpu", "calibration_stage": stage,
                "illumination": "dark" if stage == "dark" else "lamp", "command_transport_units": "micrometre OPD",
                "plant_command_units": "metre OPD", "graph_sha256": export.sha256(package / "hil/plant.toml"),
                "detector_config": detector, "wfs_active": list(map(bool, active)),
                "wfs_active_sha256": hashlib.sha256(active).hexdigest()}
            requests = [{"request": {"version": 1, "run": 1, "serial": serial,
                "action": {"kind": action, "figure": [0.0] * 277}},
                "reply": {"version": 1, "run": 1, "serial": serial,
                "result": {"kind": kind, "clipped": False, "figure": [0.0] * 277}}}
                for serial, action, kind in ((2, "adopt", "adopted"), (5, "restore", "restored"))]
            record = {"stage": stage, "restoration_confirmed": True, "release_confirmed": True,
                "shutdown_confirmed": True, "launcher_exit": 0, "startup_report": startup}
            if stage != "interaction":
                record["requests"] = requests
            self.result["stages"][stage] = record
            evidence = self.campaign / (stage + "-evidence")
            evidence.mkdir()
            self.write(evidence / "stage-result.json", record)
        hashes = self.result["artifacts"]
        for stage, report in {
            "dark": {"status": "valid", "units": "ADC", "background_sha256": hashes["measured-background.f32le"],
                     "variance_sha256": hashes["measured-dark-variance.f64le"]},
            "training": {"status": "valid", "reference_sha256": hashes["measured-reference-slopes.f32le"],
                         "mask_sha256": hashes["measured-active.u8"], "eligible": list(map(bool, self.mask))},
            "qualification": {"status": "qualified-frozen-reference", "mask_reselection": False},
            "interaction": {"status": "valid-structured-estimate", "shape": [376, 277], "layout": "ROW_MAJOR",
                            "sha256": hashes["measured-interaction-matrix.f32le"]},
        }.items():
            self.write(self.campaign / (stage + "-evidence/analysis.json"), report)
        self.write(self.campaign / "campaign-result.json", self.result)
        self.target = root / "target"
        self.provenance, self.specification, self.graph = self.package(
            self.target, bytes([1] * 188), bytes(495616), bytes(1504))
        (self.target / "hil").mkdir()
        (self.target / "hil/plant.toml").write_text(self.model(90, 1.0))

    @staticmethod
    def write(path, value):
        path.write_text(json.dumps(value) + "\n")

    @staticmethod
    def hash_package(package, spec):
        spec = copy.deepcopy(spec)
        spec["artifacts"] = {str(path.relative_to(package)): export.sha256(path)
                             for path in package.rglob("*") if path.is_file() and path.name != "deployment.conf"}
        MeasuredFixture.write(package / "deployment.conf", spec)

    @staticmethod
    def model(seed, magnitude):
        return ('schema_version=1\nname="synthetic"\n[[nodes]]\nname="atmosphere"\n[nodes.config]\n'
                'atmosphere_step=0.1\nr0=0.15\n[[nodes]]\nname="shwfs"\n[nodes.config]\n'
                f'source_magnitude={magnitude}\nn_pix_subap=22\n[[nodes]]\nname="detector"\n[nodes.config]\n'
                f'rng_seed={seed}\nrows=352\ncolumns=352\nphoton_noise=true\nreadout_noise=true\n'
                'exposure_duration_s=0.001896\ngain=15.848931924611133\nbits=12\n')

    def package(self, package, active, background, references):
        (package / "calibration").mkdir(parents=True)
        (package / "graphs").mkdir()
        parameters = [export.asdict(value) for value in export.classic_parameters()]
        for item in parameters:
            count = math.prod(item["shape"])
            payload = bytes(count * export.TYPE_BYTES[item["element_type"]])
            if item["name"] == "background": payload = background
            elif item["name"] == "reference-slopes": payload = references
            elif item["name"] == "active": payload = active
            elif item["name"] == "subaperture-origins": payload = b"".join(struct.pack("<II", *pair) for pair in self.origins)
            (package / "calibration" / item["file"]).write_bytes(payload)
        construction = []
        if self.engine == "fgn":
            construction = [{**item, "sha256": export.sha256(package / "calibration" / item["file"])}
                            for item in parameters if item["element_type"] != "F32_LE"]
            parameters = [item for item in parameters if item["element_type"] == "F32_LE"]
        wfs_config = {"image_rows": 352, "image_columns": 352, "subaperture_count": 188,
                      "subaperture_rows": 22, "subaperture_columns": 22, "initial_subaperture_origins": self.origins,
                      "active": list(map(bool, active)), "coordinate_scale": 1.0, "flux_threshold": 0.0}
        graph = {"filter.graph": {"nodes": [
            {"name": "pixel-calibration", "label": "pixel-calibration-u16-f32", "config": {"image_rows": 352, "image_columns": 352}},
            {"name": "shack-hartmann", "label": "shack-hartmann-image-f32", "config": wfs_config},
            {"name": "pdm-command", "label": "pdm-command-f32", "config": {"actuator_count": 277}}]}}
        argv = ["julia", "run_island.jl"]
        for item in parameters:
            if self.engine == "fgn":
                graph["pipewireao.startup-parameter." + item["endpoint"]] = "@PACKAGE@/calibration/" + item["file"]
            else:
                argv.extend(["--parameter", item["name"], export.JULIA_TYPES[item["element_type"]],
                             ",".join(map(str, item["shape"])), "@PACKAGE@/calibration/" + item["file"]])
        self.write(package / "graphs/graph.conf.in", graph)
        provenance = {"profile": "classic", "engine": self.engine, "mode": "frame", "parameters": parameters,
                      "construction_parameters": construction, "prepared_profile": {"subaperture_origins": self.origins}}
        specification = {"owners": [] if self.engine == "fgn" else [{"role": "julia", "argv": argv}]}
        self.write(package / "provenance.json", provenance)
        self.hash_package(package, specification)
        return provenance, specification, graph

    def preserve(self):
        # Strict JSON is valid SPA-JSON. Avoid an installed parser dependency in
        # these synthetic unit fixtures; production uses the maintained writer.
        with patch.object(export_calibration, "spa_json", side_effect=json.dumps):
            return export_hil.operational_calibration(self.target, self.specification, self.provenance,
                                                      Path("/not-installed"), self.campaign)

    def update_record(self, stage):
        self.write(self.campaign / (stage + "-evidence/stage-result.json"), self.result["stages"][stage])
        self.write(self.campaign / "campaign-result.json", self.result)

    def replace_recipe(self, recipe):
        """Keep source identities consistent when exercising recipe rejection."""
        self.write(self.campaign / "recipe.json", recipe)
        for stage in self.result["stages"]:
            base = self.campaign / (stage + "-base")
            package = self.campaign / (stage + "-package")
            provenance = json.loads((base / "provenance.json").read_text())
            provenance["campaign_stage_inputs"]["recipe"] = recipe
            self.write(base / "provenance.json", provenance)
            self.hash_package(base, json.loads((base / "deployment.conf").read_text()))
            deployed = json.loads((package / "provenance.json").read_text())
            deployed.update(source_provenance=provenance,
                            source_provenance_sha256=export.sha256(base / "provenance.json"),
                            source_deployment_sha256=export.sha256(base / "deployment.conf"))
            self.write(package / "provenance.json", deployed)
            self.hash_package(package, json.loads((package / "deployment.conf").read_text()))

    def export_arguments(self, operational=True):
        # Build a recorded-input package and small source-package placeholders.
        # Export subprocesses are spied/mocked, never launched by these tests.
        shutil.rmtree(self.target / "hil")
        for name in ("aoc", "aos", "adapter", "pwao", "fga", "plant"):
            source = self.root / name
            source.mkdir()
            (source / "Project.toml").write_text(f'name="{name}"\n')
        plant = self.root / "plant"
        (plant / "graphs").mkdir()
        (plant / "graphs/revolt_classic_hil_grid_gaussian.toml").write_text(self.model(90, 1.0))
        args = SimpleNamespace(output=self.root / "published", base_package=self.target,
            aoc_root=self.root / "aoc", aos_root=self.root / "aos", plant_root=plant,
            adapter_root=self.root / "adapter", pipewireao_jl_root=self.root / "pwao",
            calibration_algorithms_root=self.root / "fga", backend="cpu", rate_hz=10,
            frames=16, dark_frames=256, pipewire_prefix=Path("/not-installed"),
            operational_calibration=self.campaign if operational else None)
        session_args = SimpleNamespace(profile="classic", engine=self.engine, mode="frame", rate_hz=10, readout_us=100)
        matrix = export.Parameter("reconstructor", "reconstruction:reconstructor", "F32_LE", (221, 376), "reconstructor.f32le")
        self.write(self.target / "session.conf.in", export.session(session_args, matrix, "science"))
        self.write(self.target / "core.conf.in", {"context.properties": {"context.data-loops": [
            {"loop.name": name} for name in ("rtc-data-loop", "source-loop", "sink-loop")]}})
        self.specification.update({"core": "core.conf.in", "client": {}, "placement": {}, "name": "test", "source-owner": "fits"})
        if self.engine == "jfg":
            project = self.target / "jfg/deployment/Project.toml"
            project.parent.mkdir(parents=True)
            project.write_text('[deps]\nPipeWireAO="uuid"\n[sources]\nJuliaFilterGraph={path="../julia/JuliaFilterGraph"}\n')
        self.hash_package(self.target, self.specification)
        return args


class OperationalOffsetsTests(unittest.TestCase):
    def test_reuses_complete_producer_recipe_contract_before_adoption(self):
        cases = {
            "missing-fields": None,
            "training_frames": 1,
            "settling": {"kind": "sleep", "seconds": 1},
            "adc_upper_rail": 65535,
            "minimum_flux": [0.0] * 188,
            "amplitudes": [1e-99] * 277,
            "request_timeout_ns": 0,
        }
        for engine in ("fgn", "jfg"):
            for field, value in cases.items():
                with self.subTest(engine=engine, field=field), tempfile.TemporaryDirectory() as directory:
                    fixture = MeasuredFixture(Path(directory), engine)
                    # The positive fixture itself must satisfy the producer,
                    # independently of the importer's successful-path checks.
                    self.assertEqual(calibration_campaign.validate_recipe(fixture.recipe), fixture.recipe)
                    recipe = copy.deepcopy(fixture.recipe)
                    if field == "missing-fields":
                        recipe = {key: recipe[key] for key in (
                            "version", "reference", "candidate_mask", "seeds", "lamp_magnitude")}
                    else:
                        recipe[field] = value
                    fixture.replace_recipe(recipe)
                    before = {str(p): export.sha256(p) for p in fixture.target.rglob("*") if p.is_file()}
                    with self.assertRaises(ValueError):
                        fixture.preserve()
                    self.assertEqual(before, {str(p): export.sha256(p) for p in fixture.target.rglob("*") if p.is_file()})

    def test_export_branch_never_calls_detector_calibration_and_publishes_fresh_output(self):
        for engine in ("fgn", "jfg"):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                fixture = MeasuredFixture(Path(directory), engine)
                args = fixture.export_arguments()
                before = {str(p): export.sha256(p) for parent in (fixture.campaign, fixture.target)
                          for p in parent.rglob("*") if p.is_file()}
                with patch.object(export_hil.deploy, "profile", side_effect=lambda path, prefix: json.loads(path.read_text())), \
                        patch.object(export_calibration, "spa_json", side_effect=json.dumps), \
                        patch.object(export_hil.subprocess, "run") as run, \
                        patch.object(export_hil.science, "revision", return_value="synthetic"), \
                        patch.object(export_hil, "simulated_calibration", side_effect=AssertionError("fixture branch called")) as simulated:
                    result = export_hil.export_hil(args)
                simulated.assert_not_called()
                self.assertTrue(all(not any("calibrate_detector.jl" in str(argument) for argument in call.args[0]) for call in run.call_args_list))
                self.assertEqual(result, args.output / "deployment.conf")
                provenance = json.loads((args.output / "provenance.json").read_text())
                self.assertEqual(provenance["hil"]["operational_calibration"]["mode"], "operational-measured-offsets")
                self.assertNotIn("simulated_calibration", provenance["hil"])
                self.assertEqual(before, {str(p): export.sha256(p) for parent in (fixture.campaign, fixture.target)
                                         for p in parent.rglob("*") if p.is_file()})
                self.assertTrue((args.output / "hil/calibrate_detector.jl").is_file())
                for name in ("calibration_owner.jl", "calibration_acquisition.jl", "calibration_server.jl", "calibration_client.jl"):
                    self.assertEqual(export.sha256(args.output / "hil" / name), export.sha256(export_hil.ROOT / "hil" / name))

    def test_failed_export_leaves_no_candidate_or_mutated_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MeasuredFixture(Path(directory), "fgn")
            args = fixture.export_arguments()
            path = fixture.campaign / "measured-reference-slopes.f32le"
            path.write_bytes(bytes(1504))  # Deliberately leave the recorded hash stale.
            before = {str(p): export.sha256(p) for parent in (fixture.campaign, fixture.target)
                      for p in parent.rglob("*") if p.is_file()}
            with patch.object(export_hil.deploy, "profile", side_effect=lambda path, prefix: json.loads(path.read_text())), \
                    patch.object(export_hil.subprocess, "run") as run:
                with self.assertRaisesRegex(ValueError, "hash differs"):
                    export_hil.export_hil(args)
            run.assert_not_called()
            self.assertFalse(args.output.exists())
            self.assertFalse(list(args.output.parent.glob(".rtc-hil-export-*")))
            self.assertEqual(before, {str(p): export.sha256(p) for parent in (fixture.campaign, fixture.target)
                                     for p in parent.rglob("*") if p.is_file()})

    def test_default_export_still_selects_historical_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = MeasuredFixture(Path(directory), "fgn")
            args = fixture.export_arguments(operational=False)
            with patch.object(export_hil.deploy, "profile", side_effect=lambda path, prefix: json.loads(path.read_text())), \
                    patch.object(export_hil.subprocess, "run"), \
                    patch.object(export_hil.science, "revision", return_value="synthetic"), \
                    patch.object(export_hil, "simulated_calibration", return_value={"mode": "historical-simulated-offset-fixture"}) as simulated, \
                    patch.object(export_hil, "operational_calibration", side_effect=AssertionError("measured branch called")) as measured:
                export_hil.export_hil(args)
            simulated.assert_called_once()
            measured.assert_not_called()
            provenance = json.loads((args.output / "provenance.json").read_text())
            self.assertEqual(provenance["hil"]["simulated_calibration"]["mode"], "historical-simulated-offset-fixture")
            self.assertNotIn("operational_calibration", provenance["hil"])

    def test_unsupported_profile_engine_and_backend_rejected(self):
        for profile, engine, backend in (("copper", "fgn", "cpu"), ("classic", "fgn", "cuda"),
                                          ("classic", "jfg", "amdgpu"), ("classic", "other", "cpu")):
            with self.subTest(profile=profile, engine=engine, backend=backend), tempfile.TemporaryDirectory() as directory:
                fixture = MeasuredFixture(Path(directory), "fgn")
                args = fixture.export_arguments()
                args.backend = backend
                fixture.provenance.update({"profile": profile, "engine": engine})
                fixture.write(fixture.target / "provenance.json", fixture.provenance)
                with patch.object(export_hil.deploy, "profile", return_value=fixture.specification), \
                        patch.object(export_hil.subprocess, "run") as run:
                    with self.assertRaisesRegex(ValueError, "Classic CPU"):
                        export_hil.export_hil(args)
                run.assert_not_called()
                self.assertFalse(args.output.exists())

    def test_preserves_exact_bytes_maps_and_inputs_for_both_engines(self):
        for engine in ("fgn", "jfg"):
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as directory:
                fixture = MeasuredFixture(Path(directory), engine)
                source_before = {str(p): export.sha256(p) for p in fixture.campaign.rglob("*") if p.is_file()}
                original = {p.name: export.sha256(p) for p in (fixture.target / "calibration").iterdir()}
                with patch.object(export_hil, "simulated_calibration", side_effect=AssertionError("must not synthesize offsets")):
                    report = fixture.preserve()
                for name, source in (("background", "measured-background.f32le"), ("reference-slopes", "measured-reference-slopes.f32le"), ("active", "measured-active.u8")):
                    item = next(value for value in report["target_bindings"].values() if value["name"] == name)
                    self.assertEqual((fixture.target / item["path"]).read_bytes(), fixture.payloads[source])
                    self.assertEqual(export.sha256(fixture.target / item["path"]), report["artifacts"][source]["sha256"])
                changed = {"background.f32le", "reference-slopes.f32le", "active-subapertures.u8"}
                self.assertTrue(all(export.sha256(fixture.target / "calibration" / name) == digest
                                    for name, digest in original.items() if name not in changed))
                self.assertEqual(source_before, {str(p): export.sha256(p) for p in fixture.campaign.rglob("*") if p.is_file()})
                self.assertEqual(report["mode"], "operational-measured-offsets")
                self.assertIn("not established", report["reconstructor_acceptance"])
                self.assertEqual(report["target_differences"][0]["settings"]["detector.rng_seed"]["target"], 90)
                graph = json.loads((fixture.target / "graphs/graph.conf.in").read_text())
                self.assertEqual(graph["filter.graph"]["nodes"][1]["config"]["active"], list(map(bool, fixture.mask)))

    def test_rejects_payloads_and_hashes_before_adoption(self):
        for case in ("missing", "symlink", "stale", "extent", "nan", "infinity", "bad-mask", "empty-mask", "matrix-extent", "variance-nan"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                fixture = MeasuredFixture(Path(directory), "fgn")
                name = "measured-background.f32le"
                if "mask" in case: name = "measured-active.u8"
                if case == "matrix-extent": name = "measured-interaction-matrix.f32le"
                if case == "variance-nan": name = "measured-dark-variance.f64le"
                path = fixture.campaign / name
                data = path.read_bytes()
                if case == "missing": path.unlink()
                elif case == "symlink":
                    path.unlink(); path.symlink_to(fixture.target / "calibration/background.f32le")
                elif case == "stale": path.write_bytes(bytes(len(data)))
                else:
                    if case in ("extent", "matrix-extent"): data = data[:-1]
                    elif case == "nan": data = struct.pack("<f", float("nan")) + data[4:]
                    elif case == "infinity": data = struct.pack("<f", float("inf")) + data[4:]
                    elif case == "variance-nan": data = struct.pack("<d", float("nan")) + data[8:]
                    elif case == "bad-mask": data = bytes([2]) + data[1:]
                    elif case == "empty-mask": data = bytes(188)
                    path.write_bytes(data)
                    fixture.result["artifacts"][name] = export.sha256(path)
                    fixture.write(fixture.campaign / "campaign-result.json", fixture.result)
                before = export.sha256(fixture.target / "calibration/background.f32le")
                with self.assertRaises(ValueError): fixture.preserve()
                self.assertEqual(before, export.sha256(fixture.target / "calibration/background.f32le"))

    def test_rejects_incomplete_nonzero_and_unbound_campaigns(self):
        for case in ("version", "phase", "stage-missing", "lifecycle", "launcher", "record-stale", "reference", "actual-reference", "actual-clipped", "uncorrelated", "seed", "noise", "analysis-shape", "analysis-layout", "analysis-hash", "json-duplicate", "json-nan", "json-oversize"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                fixture = MeasuredFixture(Path(directory), "fgn")
                stage = fixture.result["stages"]["training"]
                if case == "version": fixture.result["version"] = True
                elif case == "phase": fixture.result["phase"] = "candidate"
                elif case == "stage-missing": del fixture.result["stages"]["dark"]
                elif case == "lifecycle": stage["release_confirmed"] = False
                elif case == "launcher": stage["launcher_exit"] = 1
                elif case == "record-stale": stage["launcher_exit"] = 4
                elif case == "reference":
                    fixture.recipe["reference"][0] = 0.1; fixture.write(fixture.campaign / "recipe.json", fixture.recipe)
                elif case == "actual-reference": stage["requests"][0]["reply"]["result"]["figure"][0] = 0.1
                elif case == "actual-clipped": stage["requests"][0]["reply"]["result"]["clipped"] = True
                elif case == "uncorrelated": stage["requests"][0]["reply"]["serial"] = 99
                elif case == "seed": stage["startup_report"]["detector_config"]["rng_seed"] = 999
                elif case == "noise": stage["startup_report"]["detector_config"]["photon_noise"] = False
                elif case.startswith("analysis-"):
                    path = fixture.campaign / "interaction-evidence/analysis.json"
                    report = json.loads(path.read_text())
                    field = case.removeprefix("analysis-")
                    report[{"hash": "sha256"}.get(field, field)] = {"shape": [277, 376], "layout": "COLUMN_MAJOR", "hash": "0" * 64}[field]
                    fixture.write(path, report)
                fixture.write(fixture.campaign / "campaign-result.json", fixture.result)
                if case != "record-stale": fixture.update_record("training")
                if case == "json-duplicate": (fixture.campaign / "campaign-result.json").write_text('{"version":1,"version":1}')
                elif case == "json-nan": (fixture.campaign / "campaign-result.json").write_text('{"version":NaN}')
                elif case == "json-oversize": (fixture.campaign / "campaign-result.json").write_bytes(bytes(2 * 1024 * 1024 + 1))
                with self.assertRaises(ValueError): fixture.preserve()

    def test_rejects_target_mismatches_and_conflicting_bindings(self):
        for engine in ("fgn", "jfg"):
            for case in ("detector", "exposure", "geometry", "threshold-config", "origins", "coordinates", "thresholds", "parameter-shape", "parameter-layout", "duplicate-descriptor", "binding-missing", "binding-conflicting", "binding-duplicate", "construction-mask"):
                with self.subTest(engine=engine, case=case), tempfile.TemporaryDirectory() as directory:
                    fixture = MeasuredFixture(Path(directory), engine)
                    graph = fixture.graph
                    if case in ("detector", "exposure"):
                        model = fixture.model(90, 1.0).replace('gain=15.848931924611133', 'gain=1.0') if case == "detector" else fixture.model(90, 1.0).replace('exposure_duration_s=0.001896', 'exposure_duration_s=0.002')
                        (fixture.target / "hil/plant.toml").write_text(model)
                    elif case == "geometry": graph["filter.graph"]["nodes"][1]["config"]["subaperture_rows"] = 21
                    elif case == "threshold-config": graph["filter.graph"]["nodes"][1]["config"]["flux_threshold"] = 1.0
                    elif case == "origins": graph["filter.graph"]["nodes"][1]["config"]["initial_subaperture_origins"] = [[1, 1]] * 188
                    elif case in ("coordinates", "thresholds"):
                        item = next(p for p in fixture.provenance["parameters"] if p["name"] == case)
                        path = fixture.target / "calibration" / item["file"]
                        path.write_bytes(struct.pack("<f", 1.0) + path.read_bytes()[4:])
                    elif case == "parameter-shape": fixture.provenance["parameters"][0]["shape"] = [1]
                    elif case == "parameter-layout": fixture.provenance["parameters"][0]["layout"] = "COLUMN_MAJOR"
                    elif case == "duplicate-descriptor": fixture.provenance["parameters"].append(copy.deepcopy(fixture.provenance["parameters"][0]))
                    elif case == "construction-mask": graph["filter.graph"]["nodes"][1]["config"]["active"] = [False] * 188
                    elif engine == "fgn":
                        key = "pipewireao.startup-parameter.pixel-calibration:background"
                        if case == "binding-missing": del graph[key]
                        elif case == "binding-conflicting": graph[key] = "@PACKAGE@/calibration/thresholds.f32le"
                    else:
                        argv = fixture.specification["owners"][0]["argv"]
                        index = argv.index("--parameter")
                        if case == "binding-missing": del argv[index:index + 5]
                        elif case == "binding-conflicting": argv[index + 4] = "@PACKAGE@/calibration/thresholds.f32le"
                        elif case == "binding-duplicate": argv.extend(argv[index:index + 5])
                    fixture.write(fixture.target / "graphs/graph.conf.in", graph)
                    if engine == "fgn" and case == "binding-duplicate":
                        path = fixture.target / "graphs/graph.conf.in"
                        path.write_text(path.read_text()[:-2] + ',"pipewireao.startup-parameter.pixel-calibration:background":"other"}\n')
                    with self.assertRaises(ValueError): fixture.preserve()



class HILExportTests(unittest.TestCase):
    def test_default_simulated_calibration_calls_existing_detector_script_and_labels_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory)
            (package / "hil").mkdir()
            (package / "calibration").mkdir()
            (package / "calibration/background.f32le").write_bytes(bytes(4))
            inputs = {"artifacts": {"background": {"path": "../calibration/background.f32le"}}}

            def calibrate(command, **kwargs):
                MeasuredFixture.write(package / "hil/calibration-result.json", {"dark_frames": 256, "artifacts": {}})

            with patch.object(export_hil, "calibration_inputs", return_value=inputs), \
                    patch.object(export_hil, "adopt_simulated_calibration"), \
                    patch.object(export_hil.subprocess, "run", side_effect=calibrate) as run:
                report = export_hil.simulated_calibration(package, {}, {"profile": "classic"},
                                                         Path("/unused"), "julia", 256)
            run.assert_called_once()
            self.assertIn(str(package / "hil/calibrate_detector.jl"), run.call_args.args[0])
            self.assertEqual(report["mode"], "historical-simulated-offset-fixture")

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
                    self.assertEqual(value["deps"]["AdaptiveOpticsCalibration"],
                                     export_hil.PACKAGE_UUIDS["AdaptiveOpticsCalibration"])
                    self.assertEqual(value["sources"]["AdaptiveOpticsCalibration"]["path"],
                                     "packages/AdaptiveOpticsCalibration")
                    self.assertEqual(value["compat"]["AdaptiveOpticsCalibration"], "0.17")
                    self.assertEqual(value["compat"]["julia"], "1.12")
                    self.assertEqual(value["sources"][plant]["path"], f"packages/{plant}")
                    self.assertEqual(value["sources"]["PipeWireAO"]["path"], "packages/PipeWireAO")
                    self.assertEqual(value["sources"]["FilterGraphAlgorithms"]["path"], "packages/FilterGraphAlgorithms")
                    other = "REVOLTCopperSim" if plant == "REVOLTClassicSim" else "REVOLTClassicSim"
                    self.assertNotIn(other, value["deps"])
                    self.assertEqual("CUDA" in value["deps"], backend == "cuda")
                    self.assertEqual("AMDGPU" in value["deps"], backend == "amdgpu")

    def test_aoc_package_copy_includes_public_package_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "AdaptiveOpticsCalibration"
            (source / "src").mkdir(parents=True)
            (source / "ext").mkdir()
            (source / "Project.toml").write_text(
                'name = "AdaptiveOpticsCalibration"\n'
                'uuid = "3c8b5851-926e-4ebb-af30-f8544b98d45f"\n')
            (source / "src/AdaptiveOpticsCalibration.jl").write_text("module AdaptiveOpticsCalibration\nend\n")
            destination = root / "package/hil/packages/AdaptiveOpticsCalibration"
            export_hil.copy_package(source, destination)
            self.assertEqual((destination / "Project.toml").read_text(), (source / "Project.toml").read_text())
            self.assertTrue((destination / "src/AdaptiveOpticsCalibration.jl").is_file())

    def test_hil_export_cli_requires_aoc_source_root(self):
        arguments = ["--output", "/tmp/export", "--base-package", "/tmp/base",
                     "--aos-root", "/src/aos", "--plant-root", "/src/plant",
                     "--adapter-root", "/src/adapter", "--pipewireao-jl-root", "/src/pwao",
                     "--calibration-algorithms-root", "/src/fga"]
        parsed = export_hil.arguments([*arguments, "--aoc-root", "/src/aoc"])
        self.assertEqual(parsed.aoc_root, Path("/src/aoc"))
        self.assertIsNone(parsed.operational_calibration)
        parsed = export_hil.arguments([*arguments, "--aoc-root", "/src/aoc", "--operational-calibration", "/data/campaign"])
        self.assertEqual(parsed.operational_calibration, Path("/data/campaign"))
        with self.assertRaises(SystemExit):
            export_hil.arguments(arguments)

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
