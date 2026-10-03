"""Portable method-owner tests; acquisition and Julia execution are mocked."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import calibration_method as m
from test_calibration_campaign import recipe


class MethodTests(unittest.TestCase):
    def test_method_declarations(self):
        for kind in (None, "zonal", "hadamard", "modal", "spatial_sine"):
            value = dict(version=1, run=7, order="reverse")
            if kind:
                value["probe_basis"] = dict(kind=kind)
            if kind == "modal":
                value["probe_basis"].update(positive_commands=[[1, 0]], mode_amplitudes=[1])
            if kind == "spatial_sine":
                value["probe_basis"].update(actuator_positions=[[0, 0]], spatial_frequencies=[[1, 0]],
                    mode_amplitudes=[1, 1], normalization="peak", minimum_sampled_peak=.01)
            self.assertEqual(m.validate_method(value), value)
        for change in (dict(version=True), dict(version=1.0), dict(run=True), dict(run=0),
                       dict(run=2**64), dict(order="shuffle"), dict(extra=1),
                       dict(probe_basis=dict(kind="modal")), dict(probe_basis=None),
                       dict(probe_basis=dict(kind="zonal", amplitudes=[1])),
                       dict(probe_basis=dict(kind="unknown"))):
            with self.subTest(change=change), self.assertRaises(ValueError):
                m.validate_method({**dict(version=1, run=1, order="forward"), **change})

    def test_identity_changes_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "file").write_bytes(b"first")
            identity = m.file_identity(root)
            m.check_identity(root, identity)
            (root / "file").write_bytes(b"second")
            with self.assertRaises(ValueError):
                m.check_identity(root, identity)
            (root / "alias").symlink_to(root / "file")
            with self.assertRaises(ValueError):
                m.file_identity(root)

    def test_retained_payloads_are_required_and_finite(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            (base / "calibration").mkdir()
            bindings = {name: dict(file=file) for name, file in
                        (("background", "bg.f32le"), ("reference-slopes", "ref.f32le"), ("active", "active.u8"))}
            payloads = [bytes(495616), bytes(1504), bytes([1] * 188)]
            for binding, data in zip(bindings.values(), payloads):
                (base / "calibration" / binding["file"]).write_bytes(data)
            with patch.object(m.deploy, "profile", return_value={}), patch.object(m.export_hil, "campaign_json", return_value={}), \
                    patch.object(m.export_hil, "classic_snapshot", return_value=({}, {}, bindings)), \
                    patch.object(m.export_hil, "validate_startup_bindings") as validation:
                self.assertEqual(m.retained_startup(base, Path("/opt/pipewireao"))[:3], tuple(payloads))
                validation.assert_called_once()
                (base / "calibration/bg.f32le").write_bytes(b"\x00\x00\xc0\x7f" * (352 * 352))
                with self.assertRaises(ValueError):
                    m.retained_startup(base, Path("/opt/pipewireao"))
                (base / "calibration/bg.f32le").unlink()
                with self.assertRaises(ValueError):
                    m.retained_startup(base, Path("/opt/pipewireao"))

    def fixture(self, root):
        base = root / "base"
        base.mkdir()
        (base / "preserved").write_bytes(b"immutable")
        recipe_path, method_path = root / "recipe.json", root / "method.json"
        recipe_path.write_text(json.dumps(recipe()))
        method_path.write_text(json.dumps(dict(version=1, run=91, order="reverse", probe_basis=dict(kind="hadamard"))))
        return SimpleNamespace(base_package=base, recipe=recipe_path, method=method_path, output=root / "output",
            runtime=root / "runtime", aoc_source=root / "aoc", rtc_binary=root / "rtc", calibration_binary=root / "calibrate",
            prefix=Path("/opt/pipewireao"), julia="julia-test")

    def fake_stage_base(self, base, output, recipe, stage, background, references, active, aoc, prefix):
        self.assertEqual(stage, "interaction")
        self.assertEqual((background, references, active), (b"background", b"references", b"active"))
        output.mkdir()
        return output

    def fake_export(self, arguments):
        self.assertEqual(arguments.illumination, "lamp")
        self.assertEqual(arguments.calibration_stage, "interaction")
        hil = arguments.output / "hil"
        hil.mkdir(parents=True)
        (hil / "calibration_client.jl").write_text("# frozen installed client\n")
        return arguments.output / "provenance.json"

    def fake_analysis(self, action, output, package, julia, timeout, **options):
        self.assertEqual(julia, "julia-test")
        if action == "prepare":
            self.assertEqual(json.loads((output / "method.json").read_text())["run"], 91)
            (output / "interaction-plan.json").write_text('{"fixture":true}\n')
        else:
            self.assertEqual(options["seal"], m.science.sha256(output / "prepared-identity.json"))
            m.science.write_json(output / "candidate-response.json", dict(status="complete-unaccepted-candidate"))

    def fake_acquire(self, package, evidence, runtime, recipe, stage):
        self.assertTrue((evidence.parent / "interaction-plan.json").is_file())
        self.assertTrue((evidence.parent / "prepared-identity.json").is_file())
        self.assertFalse(evidence.exists())
        result = dict(restoration_confirmed=True, release_confirmed=True, shutdown_confirmed=True,
                      timing_ns=dict(startup_readiness=11, acquisition=22, public_shutdown=33))
        evidence.mkdir()
        m.science.write_json(evidence / "stage-result.json", result)
        return result

    def owner_patches(self, analysis=None, acquire=None):
        return (patch.object(m, "retained_startup", return_value=(b"background", b"references", b"active", {})),
                patch.object(m.campaign, "stage_base", side_effect=self.fake_stage_base),
                patch.object(m.export_calibration, "export", side_effect=self.fake_export),
                patch.object(m, "analysis", side_effect=analysis or self.fake_analysis),
                patch.object(m.campaign, "run_stage", side_effect=acquire or self.fake_acquire))

    def test_thin_owner_frozen_inputs_and_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.fixture(Path(temporary))
            patches = self.owner_patches()
            with patches[0], patches[1], patches[2], patches[3], patches[4]:
                report = json.loads(m.method(args).read_text())
            self.assertEqual(report["phase"], "complete-candidate")
            self.assertEqual(report["timing_ns"]["acquisition"], 22)
            self.assertGreaterEqual(report["timing_ns"]["preparation"], 0)
            self.assertGreaterEqual(report["timing_ns"]["reduction"], 0)
            self.assertEqual((args.base_package / "preserved").read_bytes(), b"immutable")
            self.assertEqual((args.output / "input-recipe.json").read_bytes(), args.recipe.read_bytes())
            seal = json.loads((args.output / "prepared-identity.json").read_text())
            self.assertIn("analysis/calibration_client.jl", seal["files"])
            self.assertIn("orchestration-sources/calibration_method.py", seal["files"])

    def test_changed_plan_rejected_before_reduction(self):
        def changed(*args):
            result = self.fake_acquire(*args)
            (args[1].parent / "interaction-plan.json").write_text("changed")
            return result
        with tempfile.TemporaryDirectory() as temporary:
            args = self.fixture(Path(temporary))
            patches = self.owner_patches(acquire=changed)
            with patches[0], patches[1], patches[2], patches[3] as analysis, patches[4], self.assertRaises(ValueError):
                m.method(args)
            self.assertEqual(analysis.call_count, 1)
            report = json.loads((args.output / "method-result.json").read_text())
            self.assertIn("prepared input changed", report["failure"])
            self.assertTrue(report["stage"]["shutdown_confirmed"])

    def test_failed_preparation_is_durable_without_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = self.fixture(Path(temporary))
            patches = self.owner_patches(analysis=lambda *a, **k: (_ for _ in ()).throw(ValueError("invalid public basis")))
            with patches[0], patches[1], patches[2], patches[3], patches[4] as launch, self.assertRaises(ValueError):
                m.method(args)
            launch.assert_not_called()
            report = json.loads((args.output / "method-result.json").read_text())
            self.assertEqual(report["phase"], "preparing")
            self.assertIn("invalid public basis", report["failure"])

    def test_failed_acquisition_does_not_reduce(self):
        def incomplete(*args):
            result = self.fake_acquire(*args)
            result["shutdown_confirmed"] = False
            return result
        with tempfile.TemporaryDirectory() as temporary:
            args = self.fixture(Path(temporary))
            patches = self.owner_patches(acquire=incomplete)
            with patches[0], patches[1], patches[2], patches[3] as analysis, patches[4], self.assertRaises(ValueError):
                m.method(args)
            self.assertEqual(analysis.call_count, 1)
            report = json.loads((args.output / "method-result.json").read_text())
            self.assertIn("lifecycle incomplete", report["failure"])
            self.assertFalse((args.output / "candidate-response.json").exists())

    def test_new_paths_and_supported_prefix(self):
        for scenario in ("existing-output", "dangling-output", "inside-base", "existing-runtime", "runtime-in-base", "runtime-in-output", "prefix"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                args = self.fixture(Path(temporary))
                if scenario == "existing-output":
                    args.output.mkdir()
                elif scenario == "dangling-output":
                    args.output.symlink_to(args.output.parent / "missing")
                elif scenario == "inside-base":
                    args.output = args.base_package / "new"
                elif scenario == "existing-runtime":
                    args.runtime.mkdir()
                elif scenario == "runtime-in-base":
                    args.runtime = args.base_package / "new"
                elif scenario == "runtime-in-output":
                    args.runtime = args.output / "new"
                else:
                    args.prefix = Path("/another-prefix")
                with self.assertRaises(ValueError), patch.object(m, "retained_startup") as load:
                    m.method(args)
                load.assert_not_called()


if __name__ == "__main__":
    unittest.main()
