"""Tests for numerical acceptance formulas and source-derived arithmetic models."""
import tempfile
import unittest
from pathlib import Path

import numpy as np

from classic_numerical_acceptance import (acceptance_for_wire, U32, controller_model, dot_reference,
                                          gamma, propagated_controller_bound, require_active_subapertures,
                                          sensor_model, strict_gate, within_bound)


class NumericalAcceptanceTests(unittest.TestCase):
    def test_active_mask_requires_exact_extent_and_all_ones(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for values in (np.ones(187, dtype="u1"), np.zeros(188, dtype="u1"),
                           np.full(188, 2, dtype="u1")):
                values.tofile(fixture / "active-subapertures.u8")
                with self.assertRaisesRegex(ValueError, "188 active"):
                    require_active_subapertures(fixture)
            np.ones(188, dtype="u1").tofile(fixture / "active-subapertures.u8")
            require_active_subapertures(fixture)

    def test_gamma_comes_from_operation_count(self):
        self.assertEqual(gamma(0), 0)
        self.assertEqual(gamma(752), 752 * U32 / (1 - 752 * U32))
        with self.assertRaises(ValueError):
            gamma(-1)
        with self.assertRaises(ValueError):
            gamma(2 ** 24)

    def test_dot_bound_handles_cancellation_and_rejects_corruption(self):
        matrix = np.array([[1, 1, 1]], np.float32)
        inputs = np.array([[2 ** 24, 1, -(2 ** 24)]], np.float32)
        reference, bound = dot_reference(matrix, inputs)
        rounded = np.float32(np.float32(inputs[0, 0] + inputs[0, 1]) + inputs[0, 2])
        self.assertEqual(reference[0, 0], 1)
        self.assertTrue(within_bound(abs(rounded - reference), bound)["passed"])
        self.assertFalse(within_bound(2 * bound, bound)["passed"])

    def test_historical_threshold_stays_failed(self):
        self.assertFalse(strict_gate(np.array([1.2516975402832031e-6]), np.array([0.]))["passed"])
        self.assertTrue(strict_gate(np.array([1e-6]), np.array([0.]))["passed"])

    def test_nonfinite_and_negative_bounds_rejected(self):
        for error, bound in ((np.array([np.nan]), np.ones(1)),
                             (np.zeros(1), np.array([-1.])),
                             (np.zeros(1), np.array([np.inf]))):
            with self.assertRaises(ValueError):
                within_bound(error, bound)

    def test_heart_scalar_tail_precedes_lane_fold(self):
        pixels = np.zeros((1, 352, 352), np.float32)
        pixels[0, 0, 0] = 2 ** 24
        # The final four of the 484 row-major subaperture pixels are scalar.
        pixels[0, 21, 18:20] = 1
        args = (pixels, np.array([[0, 0]]), np.ones((484, 2), np.float32),
                np.array([[0, 1]], np.float32), np.zeros((1, 2), np.float32))
        # Width is fixed to the Classic 188-subaperture contract at return.
        args = (pixels, np.zeros((188, 2), dtype=int), args[2],
                np.tile(args[3], (188, 1)), np.zeros((188, 2), np.float32))
        _, heart_flux = sensor_model(*args, heart=True)
        _, rust_flux = sensor_model(*args, heart=False)
        np.testing.assert_array_equal(heart_flux, np.full((1, 188), 2 ** 24 + 2, np.float32))
        np.testing.assert_array_equal(rust_flux, np.full((1, 188), 2 ** 24, np.float32))

    def test_saturation_and_state_rounding_stay_inside_propagation_bound(self):
        scalars = np.array([-.3, .99, .99, -.8, .8], np.float32)
        rng = np.random.default_rng(73)
        residual = rng.uniform(-1, 1, (120, 4)).astype(np.float32)
        residual[:, 0] = 1  # Exercise repeated positive clipping feedback.
        other = np.nextafter(residual, np.float32(np.inf))
        rust, feedback, ra = controller_model(residual, scalars)
        heart, _, rb = controller_model(other, scalars, heart=True)
        self.assertGreater(np.count_nonzero(feedback), 0)
        bound = propagated_controller_bound(residual, other, ra, rb, scalars)
        self.assertTrue(within_bound(abs(rust.astype(float) - heart.astype(float)), bound)["passed"])
        self.assertFalse(within_bound(abs(rust.astype(float) - heart.astype(float)) + 2 * bound, bound)["passed"])

    def test_wire_envelope_rejects_command_corruption_and_flux_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            def save(name, value, dtype="<f4"):
                np.asarray(value, dtype=dtype).tofile(fixture / name)
            save("active-subapertures.u8", np.ones(188), "u1")
            pixels = np.full((7, 352, 352), 100, np.float32)
            save("raw-frames.u16le", pixels, "<u2")
            save("calibrated_pixels.f32le", pixels)
            save("background.f32le", np.zeros((352, 352)))
            save("subaperture-origins.u32le", np.zeros((188, 2)), "<u4")
            x, y = np.meshgrid(np.arange(22) - 10.5, np.arange(22) - 10.5)
            save("shack-hartmann-coordinates.f32le", np.stack([x, y], axis=-1))
            save("thresholds.f32le", np.tile([20, 1000], (188, 1)))
            save("reference-slopes.f32le", np.zeros((188, 2)))
            save("reconstructor.f32le", np.eye(221, 376) * .01)
            e = np.eye(277, 221)
            save("active-to-full-vdm.f32le", e)
            save("full-to-active-vdm.f32le", e.T)
            for name, width in (("controller-to-vdm", 221), ("vdm-to-controller", 221),
                                ("vdm-to-pdm", 277), ("pdm-to-vdm", 277)):
                save(name + ".f32le", np.eye(width))
            save("scalars.f32le", [-.3, .99, .99, -.8, .8])
            zeros = np.zeros((8, 277), np.float32)
            result = acceptance_for_wire(fixture, zeros, zeros, 8, "test", "complete-frame")
            self.assertTrue(result["arithmetic_consistency_passed"])
            exact = acceptance_for_wire(fixture, zeros, zeros, 8, "heart", "progressive")
            self.assertTrue(exact["exact_model_passed"])
            one_ulp = zeros.copy()
            one_ulp[0, 0] = np.nextafter(np.float32(0), np.float32(1))
            exact = acceptance_for_wire(fixture, zeros, one_ulp, 8, "heart", "progressive")
            self.assertFalse(exact["exact_model_passed"])
            corrupted = zeros.copy()
            corrupted[0, 0] = .01
            result = acceptance_for_wire(fixture, zeros, corrupted, 8, "test", "complete-frame")
            self.assertFalse(result["arithmetic_consistency_passed"])
            save("thresholds.f32le", np.tile([20, 48400], (188, 1)))
            with self.assertRaisesRegex(ValueError, "ambiguous"):
                acceptance_for_wire(fixture, zeros, zeros, 8, "test", "complete-frame")

    def test_controller_rejects_unproved_coefficient_range(self):
        with self.assertRaises(ValueError):
            controller_model(np.ones((2, 1), np.float32), np.array([-.3, .99, 1.1, -.8, .8], np.float32))


if __name__ == "__main__":
    unittest.main()
