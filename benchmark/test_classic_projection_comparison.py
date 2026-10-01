import unittest
from run_classic_projection_comparison import cases


class ProjectionComparisonTests(unittest.TestCase):
    def test_every_condition_is_present_and_variant_order_is_counterbalanced(self):
        result = list(cases([100, 250], 3))
        self.assertEqual(len(result), 12)
        self.assertEqual(len(set(result)), 12)
        for repeat in range(1, 4):
            for rate in (100, 250):
                self.assertEqual({variant for r, hz, variant in result if (r, hz) == (repeat, rate)},
                                 {"baseline", "candidate"})
        self.assertEqual(result[:4], [(1, 100, "baseline"), (1, 100, "candidate"),
                                     (1, 250, "candidate"), (1, 250, "baseline")])
        self.assertEqual(result[4:8], [(2, 250, "baseline"), (2, 250, "candidate"),
                                     (2, 100, "candidate"), (2, 100, "baseline")])

        for rate in (100, 250):
            first = [variant for repeat, hz, variant in result if hz == rate][::2]
            self.assertEqual(first, [first[0], "candidate" if first[0] == "baseline" else "baseline", first[0]])

    def test_reverse_variants_checks_opposite_pair_order(self):
        original = list(cases([100, 250], 1))
        reverse = list(cases([100, 250], 1, reverse_variants=True))
        self.assertEqual(reverse, [original[1], original[0], original[3], original[2]])


if __name__ == "__main__":
    unittest.main()
