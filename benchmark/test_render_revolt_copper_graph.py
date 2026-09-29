"""Focused checks for the test-only Copper graph observation variant."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).with_name("render_revolt_copper_graph.py")
SPEC = importlib.util.spec_from_file_location("render_revolt_copper_graph", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
RENDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RENDER)


class CopperObservationTests(unittest.TestCase):
    def test_exposes_scientific_outputs_once(self) -> None:
        graph = ('        outputs = [\n'
                 '            "command:demanded"\n'
                 '            "feedback-to-controller:controller-constraint-feedback"\n'
                 '        ]\n')
        extended = RENDER.expose_equivalence_outputs(graph)
        for name in ("pyramid:mean-pupil-intensity", "control:correction",
                     "control:controller-state", "command:constraint-feedback"):
            self.assertEqual(extended.count(f'"{name}"'), 1)
        self.assertIn('"command:demanded"', extended)
        self.assertIn('"feedback-to-controller:controller-constraint-feedback"', extended)
        with self.assertRaisesRegex(ValueError, "no unique unmodified feedback output"):
            RENDER.expose_equivalence_outputs(extended)


if __name__ == "__main__":
    unittest.main()
