"""Check artifact rejection and the rounding primitive used by the analysis."""

import importlib.util
from pathlib import Path
import tempfile
import unittest

import numpy as np


SPEC = importlib.util.spec_from_file_location(
    "analyze_classic_heart_boundaries",
    Path(__file__).with_name("analyze_classic_heart_boundaries.py"),
)
ANALYSIS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYSIS)


class FitsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "capture.fits"

    def write_image(self, values, extra_cards=()):
        fields = [("SIMPLE", "T"), ("BITPIX", "-32"), ("NAXIS", "3"),
                  ("NAXIS1", "1"), ("NAXIS2", "3"), ("NAXIS3", "2")]
        cards = [f"{key:<8}= {value:>20}".ljust(80)
                 for key, value in (*fields, *extra_cards)]
        header = ("".join(cards) + "END".ljust(80)).encode("ascii").ljust(2880, b" ")
        self.path.write_bytes(header + np.asarray(values, dtype=">f4").tobytes().ljust(2880, b"\0"))

    def test_big_endian_order_and_negative_zero_preserved(self):
        values = np.array([1, 2, 3, -0.0, -5, 6], dtype=np.float32).reshape(2, 3, 1)
        self.write_image(values)
        actual, metadata = ANALYSIS.read_fits(self.path, (2, 3, 1))
        np.testing.assert_array_equal(actual.view(np.uint32), values.view(np.uint32))
        self.assertEqual(metadata["shape"], [2, 3, 1])

    def test_wrong_shape_and_scaling_rejected(self):
        self.write_image(range(6))
        with self.assertRaisesRegex(ValueError, "shape"):
            ANALYSIS.read_fits(self.path, (3, 2, 1))
        self.write_image(range(6), (("BSCALE", "2"),))
        with self.assertRaisesRegex(ValueError, "scaling"):
            ANALYSIS.read_fits(self.path, (2, 3, 1))

    def test_nonfinite_and_duplicate_cards_rejected(self):
        self.write_image([1, 2, 3, 4, 5, np.nan])
        with self.assertRaisesRegex(ValueError, "nonfinite"):
            ANALYSIS.read_fits(self.path, (2, 3, 1))
        self.write_image(range(6), (("NAXIS1", "1"),))
        with self.assertRaisesRegex(ValueError, "duplicate"):
            ANALYSIS.read_fits(self.path, (2, 3, 1))

    def test_truncation_and_extra_image_rejected(self):
        self.write_image(range(6))
        original = self.path.read_bytes()
        self.path.write_bytes(original[:-1])
        with self.assertRaisesRegex(ValueError, "truncated"):
            ANALYSIS.read_fits(self.path, (2, 3, 1))
        self.path.write_bytes(original + bytes(2880))
        with self.assertRaisesRegex(ValueError, "extent"):
            ANALYSIS.read_fits(self.path, (2, 3, 1))


class ArithmeticTests(unittest.TestCase):
    def test_fmaf_retains_product_cancelled_by_separate_rounding(self):
        # Exact result: (1 + ε)(1 − ε) − 1 = −ε², ε = 2⁻²³.
        epsilon = np.float32(2 ** -23)
        a, b = np.float32(1) + epsilon, np.float32(1) - epsilon
        self.assertEqual(a * b - np.float32(1), np.float32(0))
        self.assertEqual(ANALYSIS.Fma()(a, b, np.float32(-1)), np.float32(-(2 ** -46)))

    def test_fmaf_rounds_halfway_to_even(self):
        half_ulp = np.float32(2 ** -24)
        above_half = np.nextafter(half_ulp, np.float32(np.inf))
        actual = ANALYSIS.Fma()(np.float32(1), np.float32(1), [half_ulp, above_half])
        expected = np.array([1, np.nextafter(np.float32(1), np.float32(np.inf))], dtype=np.float32)
        np.testing.assert_array_equal(actual, expected)

    def test_bit_comparison_distinguishes_signed_zero(self):
        result = ANALYSIS.compare(np.array([-0.0], dtype=np.float32),
                                  np.array([0.0], dtype=np.float32))
        self.assertEqual(result["unequal_bits"], 1)
        self.assertEqual(result["max_absolute_difference"], 0)


if __name__ == "__main__":
    unittest.main()
