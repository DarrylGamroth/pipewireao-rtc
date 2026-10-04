"""Portable Copper quality policy tests; no live owner is launched."""

import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import copper_quality as quality


def recipe():
    return {"version": 1, "actuator": 139, "amplitudes": [0.02, 0.04, 0.08],
            "repeats": 2, "frames_per_batch": 8, "reference": [0.0] * 277,
            "seed": 444, "lamp_magnitude": 5.752574989159953,
            "settling": {"kind": "discard_exposures", "frames": 1},
            "adc_upper_rail": 16383, "request_timeout_ns": 30_000_000_000,
            "stage_timeout_seconds": 300}


class CopperQualityTests(unittest.TestCase):
    def test_explicit_recipe_and_balanced_schedule(self):
        source = recipe()
        declared = quality.validate_recipe(source)
        plan = quality.schedule(declared)
        self.assertEqual(len(plan), 16)
        self.assertEqual([entry["label"] for entry in plan[:8]],
                         ["null_start", "positive", "negative", "positive",
                          "negative", "positive", "negative", "null_end"])
        self.assertEqual([entry["amplitude"] for entry in plan[9:15]],
                         [declared["amplitudes"][2]] * 2 +
                         [declared["amplitudes"][1]] * 2 +
                         [declared["amplitudes"][0]] * 2)
        self.assertEqual([entry["sign"] for entry in plan[9:15]], [-1, 1] * 3)
        self.assertEqual([entry["figure"][138] for entry in (plan[0], plan[1], plan[2])],
                         [0.0, declared["amplitudes"][0], -declared["amplitudes"][0]])
        self.assertTrue(all(entry["frames"] == 8 and len(entry["figure"]) == 277 for entry in plan))
        declared["reference"][0] = 3
        self.assertEqual(source["reference"][0], 0.0)

    def test_invalid_recipe_rejects_before_any_output(self):
        changes = [lambda r: r.update(version=True), lambda r: r.update(actuator=0),
                   lambda r: r.update(actuator=278), lambda r: r.update(repeats=1),
                   lambda r: r.update(repeats=5), lambda r: r.update(frames_per_batch=1),
                   lambda r: r.update(frames_per_batch=17), lambda r: r.update(seed=True),
                   lambda r: r.update(seed=2**32), lambda r: r.update(amplitudes=[]),
                   lambda r: r.update(amplitudes=[.02, .02]),
                   lambda r: r.update(amplitudes=[.02, .01]),
                   lambda r: r.update(amplitudes=[1e-100]),
                   lambda r: r.update(amplitudes=[.02, .04, .08, .16]),
                   lambda r: r.update(reference=[0.0]*276),
                   lambda r: r["reference"].__setitem__(0, float("nan")),
                   lambda r: r.update(lamp_magnitude=float("inf")),
                   lambda r: r.update(settling={"kind": "immediate"}),
                   lambda r: r.update(stage_timeout_seconds=1801),
                   lambda r: r.update(request_timeout_ns=30_000_000_001),
                   lambda r: r.update(extra=True)]
        for change in changes:
            with self.subTest(change=change):
                value = recipe()
                change(value)
                with self.assertRaises(ValueError):
                    quality.validate_recipe(value)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bad.json").write_text(json.dumps({"version": 1}))
            arguments = type("Args", (), {"recipe": root / "bad.json", "output": root / "output"})()
            with patch.object(quality.reference, "validate_base", side_effect=AssertionError("unexpected preparation")):
                with self.assertRaises(ValueError):
                    quality.campaign(arguments)
            self.assertFalse(arguments.output.exists())

    def test_schedule_is_bounded_at_four_repeats_three_amplitudes(self):
        value = recipe()
        value["repeats"] = 4
        plan = quality.schedule(quality.validate_recipe(value))
        self.assertEqual(len(plan), 32)
        self.assertEqual(sum(entry["frames"] for entry in plan), 256)

    def test_schedule_rejects_probe_that_rounds_to_reference(self):
        value = recipe()
        value["reference"][138] = 1_000_000.0
        with self.assertRaisesRegex(ValueError, "collapsed"):
            quality.schedule(quality.validate_recipe(value))

    def test_seal_rejects_changed_and_added_package_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "training-package"
            package.mkdir()
            (package / "helper.jl").write_text("source\n")
            seal = {"version": 1, "files": {"training-package/helper.jl":
                                             quality.science.sha256(package / "helper.jl")}}
            quality.check_seal(root, seal)
            (package / "helper.jl").write_text("changed\n")
            with self.assertRaises(ValueError):
                quality.check_seal(root, seal)
            (package / "helper.jl").write_text("source\n")
            (package / "added.jl").write_text("added\n")
            with self.assertRaises(ValueError):
                quality.check_seal(root, seal)

    def test_report_admission_rejects_changed_identity_status_and_product(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            evidence = root / "training-evidence"
            evidence.mkdir()
            (root / "training-package/hil").mkdir(parents=True)
            helper = root / "training-package/hil/calibration_quality_analysis.jl"
            helper.write_text("helper\n")
            (root / "reference-candidate/training-evidence").mkdir(parents=True)
            producer = root / "reference-candidate/training-evidence/analysis.json"
            producer.write_text("{}\n")
            (root / "measured-reference-pixels.f32le").write_bytes(bytes(14400))
            (root / "quality-inputs.json").write_text("{}\n")
            value = quality.validate_recipe({**recipe(), "amplitudes": [.02],
                                             "frames_per_batch": 2})
            plan = quality.schedule(value)
            quality.science.write_json(root / "recipe.json", value)
            quality.science.write_json(root / "schedule.json", plan)
            captures = []
            for probe, batch in enumerate(plan):
                serial = 4 + 3 * probe
                path = evidence / "captured" / str(serial) / "manifest.json"
                path.parent.mkdir(parents=True)
                path.write_text("{}\n")
                captures.append({"probe": probe, "figure": batch["figure"],
                                 "completion": {"manifest": f"{serial}/manifest.json",
                                                "sha256": quality.science.sha256(path)}})
            quality.science.write_json(evidence / "stage-result.json", {"captures": captures})
            artifacts = []
            expected = {"batch-means.f64le": ([len(plan), 3600], "normalized pixel"),
                        "batch-variances.f64le": ([len(plan), 3600], "normalized pixel squared"),
                        "derivative-repeats.f64le": ([1, 2, 3600], "normalized pixel per micrometre OPD"),
                        "derivative-means.f64le": ([1, 3600], "normalized pixel per micrometre OPD")}
            for name, (shape, units) in expected.items():
                size = 8
                for dimension in shape:size *= dimension
                path = root / name
                path.write_bytes(bytes(size))
                artifacts.append(dict(path=name, sha256=quality.science.sha256(path),
                                      bytes=size, shape=shape, element_type="F64_LE",
                                      layout="ROW_MAJOR", units=units))
            report = dict(version=1, profile="copper", status="characterized-candidate",
                          public_methods=["Diagnostics.RepeatedResponseMoments",
                                          "InteractionMatrices.ZonalPushPull"],
                          scope="descriptive one-direction candidate; no interaction-matrix, inverse, correction or rate acceptance",
                          actuator=value["actuator"], samples_per_batch=2,
                          analysis_source_sha256=quality.science.sha256(helper),
                          batches=[{key: batch[key] for key in ("label", "repeat", "amplitude", "sign")}
                                   | {"probe": probe} for probe, batch in enumerate(plan)],
                          amplitudes=[{}], artifacts=artifacts,
                          inputhashes={"quality_inputs_sha256": quality.science.sha256(root / "quality-inputs.json"),
                                       "recipe_sha256": quality.science.sha256(root / "recipe.json"),
                                       "schedule_sha256": quality.science.sha256(root / "schedule.json"),
                                       "stage_result_sha256": quality.science.sha256(evidence / "stage-result.json"),
                                       "producing_reference_analysis_sha256": quality.science.sha256(producer),
                                       "measured_reference_sha256": quality.science.sha256(root / "measured-reference-pixels.f32le"),
                                       "capture_manifest_sha256": [item["completion"]["sha256"] for item in captures]})
            path = evidence / "analysis.json"
            quality.science.write_json(path, report)
            products, _ = quality.analysis_products(root, evidence, value, plan)
            self.assertEqual(set(products), set(expected))
            for change in (lambda r: r.update(version=True),
                           lambda r: r["batches"][0].update(probe=True),
                           lambda r: r["batches"][0].update(repeat=True),
                           lambda r: r["batches"][0].update(sign=True),
                           lambda r: r.update(status="complete"),
                           lambda r: r["inputhashes"].update(recipe_sha256="wrong"),
                           lambda r: r["artifacts"].append({"path": "extra"})):
                bad = copy.deepcopy(report)
                change(bad)
                quality.science.write_json(path, bad)
                with self.assertRaises(ValueError):
                    quality.analysis_products(root, evidence, value, plan)
            quality.science.write_json(path, report)
            (root / "batch-means.f64le").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                quality.analysis_products(root, evidence, value, plan)


if __name__ == "__main__":
    unittest.main()
