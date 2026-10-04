"""Portable policy and immutable preparation checks; no RTC is launched."""

import copy
import json
from pathlib import Path
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import copper_reference as reference
from test_export_calibration import fixture


def recipe():
    return {"version": 1, "dark_frames": 8, "training_frames": 8,
            "qualification_frames": 8, "seeds": {"dark": 11, "training": 22, "qualification": 33},
            "lamp_magnitude": 5.752574989159953, "reference": [0.0] * 277,
            "settling": {"kind": "discard_exposures", "frames": 1}, "adc_upper_rail": 16383,
            "request_timeout_ns": 30_000_000_000, "stage_timeout_seconds": 300}


class CopperReferenceTests(unittest.TestCase):
    def test_explicit_policy_is_copied_and_accepts_completed_model_time(self):
        original = recipe()
        result = reference.validate_recipe(original)
        result["seeds"]["dark"] = 55
        self.assertEqual(original["seeds"]["dark"], 11)
        original["settling"] = {"kind": "model_time", "duration_ns": 1}
        self.assertEqual(reference.validate_recipe(original)["settling"], original["settling"])

    def test_invalid_recipe_rejects_before_effects(self):
        changes = [lambda r: r.update(version=True), lambda r: r.update(dark_frames=1),
                   lambda r: r.update(training_frames=65), lambda r: r.update(qualification_frames=False),
                   lambda r: r.update(seeds={"dark": 1, "training": 1, "qualification": 2}),
                   lambda r: r["seeds"].update(dark=-1), lambda r: r["seeds"].update(training=2**32),
                   lambda r: r.update(lamp_magnitude=float("nan")),
                   lambda r: r.update(reference=[0] * 276), lambda r: r["reference"].__setitem__(0, float("inf")),
                   lambda r: r["reference"].__setitem__(0, 1e100), lambda r: r["reference"].__setitem__(0, 1e-100),
                   lambda r: r.update(settling={"kind": "immediate"}),
                   lambda r: r.update(settling={"kind": "discard_exposures", "frames": 0}),
                   lambda r: r.update(settling={"kind": "model_time", "duration_ns": False}),
                   lambda r: r.update(adc_upper_rail=65536), lambda r: r.update(request_timeout_ns=30_000_000_001),
                   lambda r: r.update(stage_timeout_seconds=0), lambda r: r.update(unexpected=True)]
        for change in changes:
            with self.subTest(change=change):
                value = recipe()
                change(value)
                with patch.object(reference.subprocess, "run", side_effect=AssertionError("unexpected effect")):
                    with self.assertRaises(ValueError):
                        reference.validate_recipe(value)
        for value in (None, [], {}, {"version": 1}):
            with self.assertRaises(ValueError):
                reference.validate_recipe(value)

    def base(self, root):
        base = root / "base"
        (base / "calibration").mkdir(parents=True)
        (base / "hil/packages/AdaptiveOpticsCalibration/src").mkdir(parents=True)
        (base / "hil/packages/AdaptiveOpticsCalibration/Project.toml").write_text('name = "AdaptiveOpticsCalibration"\n')
        (base / "graphs").mkdir()
        (base / "graphs/graph.conf.in").write_text("original graph\n")
        (base / "calibration/background.f32").write_bytes(bytes(16384))
        provenance = {"profile": "copper", "engine": "fgn", "mode": "frame", "hil": {"backend": "cpu"},
                      "parameters": [{"name": "background", "endpoint": "pixel:background", "element_type": "F32_LE",
                                      "shape": [64, 64], "file": "background.f32"}]}
        (base / "provenance.json").write_text(json.dumps(provenance))
        (base / "deployment.conf").write_text(json.dumps({"artifacts": {}}))
        (base / "hil/Project.toml").write_text('[sources]\nAdaptiveOpticsCalibration = {path = "packages/AdaptiveOpticsCalibration"}\n')
        (base / "hil/plant.toml").write_text('[[nodes]]\nname = "pwfs"\n[nodes.config]\nsource_magnitude = 7.0\n'
                                            '[[nodes]]\nname = "detector"\n[nodes.config]\nbits = 14\nrng_seed = 0\n')
        spec = {"source-owner": "simulator", "owners": [{"role": "simulator", "argv": ["julia", "--backend", "cpu"]}]}
        return base, provenance, spec

    def test_base_profile_background_endpoint_backend_and_rail(self):
        with tempfile.TemporaryDirectory() as tmp:
            base, provenance, spec = self.base(Path(tmp))
            with patch.object(reference.deploy, "profile", return_value=spec), patch.object(reference.deploy, "decode", return_value=fixture("copper", "fgn")):
                reference.validate_base(base, Path("/opt/pipewireao"), recipe())
                for change in (lambda p: p.update(profile="classic"), lambda p: p.update(mode="rows"),
                               lambda p: p["hil"].update(backend="cuda"),
                               lambda p: p["parameters"][0].update(shape=[4096]),
                               lambda p: p["parameters"][0].update(file="../outside.f32"),
                               lambda p: p["parameters"][0].update(endpoint="other:background")):
                    invalid = copy.deepcopy(provenance)
                    change(invalid)
                    (base / "provenance.json").write_text(json.dumps(invalid))
                    with self.assertRaises(ValueError):
                        reference.validate_base(base, Path("/opt/pipewireao"), recipe())
                (base / "provenance.json").write_text(json.dumps(provenance))
                spec["owners"][0]["argv"][-1] = "amdgpu"
                with self.assertRaises(ValueError):
                    reference.validate_base(base, Path("/opt/pipewireao"), recipe())
                spec["owners"][0]["argv"][-1] = "cpu"
                wrong_rail = recipe()
                wrong_rail["adc_upper_rail"] = 65535
                with self.assertRaises(ValueError):
                    reference.validate_base(base, Path("/opt/pipewireao"), wrong_rail)

    def test_preparation_preserves_graph_and_original_and_binds_measured_background(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base, _, spec = self.base(root)
            aoc = root / "aoc"
            (aoc / "src").mkdir(parents=True)
            (aoc / "Project.toml").write_text('name = "AdaptiveOpticsCalibration"\n')
            (aoc / "src/marker.jl").write_text("# selected source\n")
            before = {str(p.relative_to(base)): p.read_bytes() for p in base.rglob("*") if p.is_file()}
            background = struct.pack("<4096f", *([0.75] * 4096))
            with patch.object(reference.deploy, "profile", return_value=spec), patch.object(reference.deploy, "decode", return_value=fixture("copper", "fgn")), patch.object(reference.science, "revision", return_value="frozen"):
                output = reference.stage_base(base, root / "stage", recipe(), "training", background, aoc, Path("/opt/pipewireao"))
                self.assertEqual((output / "calibration/background.f32").read_bytes(), background)
                self.assertEqual((output / "graphs/graph.conf.in").read_bytes(), before["graphs/graph.conf.in"])
                self.assertEqual({str(p.relative_to(base)): p.read_bytes() for p in base.rglob("*") if p.is_file()}, before)
                import tomllib
                model = tomllib.loads((output / "hil/plant.toml").read_text())
                self.assertEqual(model["nodes"][0]["config"]["source_magnitude"], recipe()["lamp_magnitude"])
                self.assertEqual(model["nodes"][1]["config"]["rng_seed"], 22)
                record = json.loads((output / "provenance.json").read_text())["reference_campaign_inputs"]
                self.assertEqual(record["background_sha256"], reference.science.sha256(output / "calibration/background.f32"))
                with self.assertRaises(ValueError):
                    reference.stage_base(base, output, recipe(), "dark", background, aoc, Path("/opt/pipewireao"))
                for payload in (bytes(4), struct.pack("<f", float("nan")) * 4096):
                    with self.assertRaises(ValueError):
                        reference.stage_base(base, root / "bad", recipe(), "dark", payload, aoc, Path("/opt/pipewireao"))
                    self.assertFalse((root / "bad").exists())

    def test_bad_recipe_creates_no_output_and_launches_no_owner(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "recipe.json").write_text(json.dumps({"version": 1}))
            arguments = SimpleNamespace(recipe=root / "recipe.json", output=root / "output")
            with patch.object(reference.acquisition, "run_stage", side_effect=AssertionError("unexpected owner")):
                with self.assertRaises(ValueError):
                    reference.campaign(arguments)
            self.assertFalse(arguments.output.exists())

    def test_campaign_stage_order_background_and_analysis_failure_record(self):
        for fail_training in (False, True):
            with self.subTest(fail_training=fail_training), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "recipe.json").write_text(json.dumps(recipe()))
                aoc = root / "aoc/src"
                (aoc / "reference_frames").mkdir(parents=True)
                (aoc / "diagnostics").mkdir()
                (aoc / "reference_frames/dark_frame_moments.jl").write_text("# numerical fixture\n")
                (aoc / "diagnostics/repeated_response_moments.jl").write_text("# numerical fixture\n")
                arguments = SimpleNamespace(recipe=root / "recipe.json", base_package=root / "base",
                    output=root / "output", runtime=root / "runtime", aoc_source=root / "aoc",
                    pipewire_prefix=Path("/opt/pipewireao"), rtc_binary=root / "rtc",
                    calibration_binary=root / "calibrate", julia="julia")
                prepared = []
                captured = []
                def preparation(base, output, value, stage, background, *args):
                    prepared.append((stage, background))
                    return output
                def capture(package, evidence, runtime, value, stage, *, frames):
                    evidence.mkdir()
                    captured.append((stage, frames))
                    return {"restoration_confirmed": True, "release_confirmed": True, "shutdown_confirmed": True}
                background = struct.pack("<4096f", *([0.5] * 4096))
                def analysis(argv, **kwargs):
                    stage = argv[-3]
                    if stage == "dark":
                        (arguments.output / "measured-background.f32le").write_bytes(background)
                    (arguments.output / (stage + "-evidence/analysis.json")).write_text(json.dumps({"comparison": {"reference_sha256": "frozen"}}))
                    return subprocess.CompletedProcess(argv, 1 if fail_training and stage == "training" else 0,
                        stdout="{}\n", stderr="")
                def products(output, evidence, stage, *args):
                    name = "measured-background.f32le" if stage == "dark" else "measured-reference-pixels.f32le" if stage == "training" else "qualification-mean.f64le"
                    return {name: "frozen"}, "frozen"
                with patch.object(reference, "validate_base"), patch.object(reference, "stage_base", side_effect=preparation), \
                     patch.object(reference.export_calibration, "export"), patch.object(reference.acquisition, "run_stage", side_effect=capture), \
                     patch.object(reference.subprocess, "run", side_effect=analysis), patch.object(reference.science, "sha256", return_value="frozen"), \
                     patch.object(reference, "analysis_products", side_effect=products):
                    if fail_training:
                        with self.assertRaises(subprocess.CalledProcessError):
                            reference.campaign(arguments)
                    else:
                        reference.campaign(arguments)
                stages = ["dark", "training"] if fail_training else list(reference.STAGES)
                self.assertEqual([stage for stage, _ in prepared], stages)
                self.assertEqual(captured, [(stage, 8) for stage in stages])
                self.assertEqual(prepared[0][1], bytes(16384))
                self.assertTrue(all(payload == background for _, payload in prepared[1:]))
                record = json.loads((arguments.output / "reference-result.json").read_text())
                self.assertEqual(record["phase"], "failed-candidate" if fail_training else "complete-candidate")
                self.assertEqual("failure" in record, fail_training)
                self.assertTrue(all("analysis_wall_ns" in s for s in record["stages"].values()))

    def test_candidates_are_bound_to_the_producing_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evidence = root / "dark-evidence"
            evidence.mkdir()
            (root / "recipe.json").write_text(json.dumps(recipe()))
            (evidence / "stage-result.json").write_text("{}\n")
            descriptors = []
            for name, element, count, units in (("measured-background.f32le", "F32_LE", 16384, "ADC"),
                                                ("measured-dark-variance.f64le", "F64_LE", 32768, "ADC squared")):
                path = root / name
                path.write_bytes(bytes(count))
                descriptors.append({"path": name, "shape": [64, 64], "bytes": count, "element_type": element,
                                    "layout": "ROW_MAJOR", "units": units, "sha256": reference.science.sha256(path)})
            report = {"profile": "copper", "stage": "dark", "status": "valid-candidate", "samples": 8,
                      "public_method": "ReferenceFrames.DarkFrameMoments", "analysis_source_sha256": "source",
                      "input_identities": {"recipe_sha256": reference.science.sha256(root / "recipe.json"),
                                           "stage_result_sha256": reference.science.sha256(evidence / "stage-result.json")},
                      "artifacts": descriptors}
            (evidence / "analysis.json").write_text(json.dumps(report))
            products, report_sha = reference.analysis_products(root, evidence, "dark", recipe(), "source")
            reference.check_products(root, products, {str(evidence / "analysis.json"): report_sha})
            (root / "measured-background.f32le").write_bytes(struct.pack("<4096f", *([1.0] * 4096)))
            with self.assertRaises(ValueError):
                reference.analysis_products(root, evidence, "dark", recipe(), "source")
            with self.assertRaises(ValueError):
                reference.check_products(root, products, {str(evidence / "analysis.json"): report_sha})
            (root / "measured-background.f32le").write_bytes(bytes(16384))
            (evidence / "analysis.json").write_text("{}\n")
            with self.assertRaises(ValueError):
                reference.check_products(root, products, {str(evidence / "analysis.json"): report_sha})

    def test_freeze_detects_changed_base_aoc_and_added_helper(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base, _, _ = self.base(root)
            aoc = base / "hil/packages/AdaptiveOpticsCalibration"
            before = reference.input_snapshot(base, aoc)
            (base / "deployment.conf").write_text("{}\n")
            self.assertNotEqual(reference.input_snapshot(base, aoc), before)
            before = reference.input_snapshot(base, aoc)
            (aoc / "src/new.jl").write_text("# newly selected scientific source\n")
            self.assertNotEqual(reference.input_snapshot(base, aoc), before)
            before = reference.input_snapshot(base, aoc)
            with patch.object(Path, "glob", return_value=[aoc / "src/new.jl"]):
                self.assertNotEqual(reference.input_snapshot(base, aoc), before)


if __name__ == "__main__":
    unittest.main()
