"""Physical delivery failures must survive absent downstream science reports."""
import json
from pathlib import Path
import tempfile
import unittest

from run_classic_platform_campaign import read_case_reports


class CaseReportTests(unittest.TestCase):
    def fixture(self, directory, *, exact, arithmetic=None, heart=False):
        report = {"qualified": exact, "process_returncodes": [0, 0]}
        if heart:
            report["commands"] = [{"kind": "process", "returncode": 0}]
            report["functional_wire_qualified"] = exact
        (directory/"report.json").write_text(json.dumps(report))
        (directory/"physical-summary.json").write_text(json.dumps({"qualified": exact}))
        if arithmetic is not None:
            (directory/"arithmetic-acceptance.json").write_text(json.dumps(arithmetic))

    def test_delivery_failure_is_false_when_science_report_is_missing(self):
        for path in ("fgn-row", "jfg-row", "heart"):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                self.fixture(directory, exact=False, heart=path == "heart")
                record = {}
                read_case_reports(record, directory, path)
                self.assertIs(record["exact_wire_delivery"], False)
                self.assertIsNone(record["science_passed"])
                self.assertTrue(record["normal_child_exit"])
                self.assertNotIn("arithmetic-acceptance.json", record)

    def test_exact_delivery_cannot_supply_missing_science_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory, exact=True)
            record = {}
            read_case_reports(record, directory, "fgn-frame")
            self.assertTrue(record["exact_wire_delivery"])
            self.assertIsNone(record["science_passed"])

    def test_heart_requires_both_arithmetic_and_exact_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory, exact=True, heart=True, arithmetic={
                "arithmetic_consistency_passed": True, "exact_model_passed": False})
            record = {}
            read_case_reports(record, directory, "heart")
            self.assertFalse(record["science_passed"])

    def test_complete_reports_preserve_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory, exact=True, arithmetic={"arithmetic_consistency_passed": True})
            record = {}
            read_case_reports(record, directory, "jfg-frame")
            self.assertTrue(record["science_passed"])
            self.assertTrue(record["normal_child_exit"])
            self.assertTrue(record["functional_passed"])


if __name__ == "__main__":
    unittest.main()
