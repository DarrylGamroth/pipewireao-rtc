"""Checks for the latest/hold raw-timing report validator."""

from __future__ import annotations

import csv
from pathlib import Path
import tempfile
import unittest

from report_latest_hold import validate_and_summarize


class LatestHoldReportTests(unittest.TestCase):
    def make_csv(self, path: Path, gap: bool = False) -> None:
        with path.open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("path", "identity", "callback_count", "callback_ns",
                             "queue_ns", "receipt_ns"))
            for index in range(2500):
                callback = 1_000_000_000 + index * 10_000_000
                writer.writerow(("slow", 15 + index, 101 + index * 10,
                                 callback, callback + 100, callback + 400))
            for index in range(25_000):
                callback = 1_000_000_000 + index * 1_000_000
                identity = 1000 + index + (1 if gap and index >= 10_000 else 0)
                writer.writerow(("primary", identity, 101 + index,
                                 callback, callback + 100, callback + 400))
            for index in range(1000):
                writer.writerow(("overhead", 0, 0, 0, index + 1, index + 26))

    def test_complete_paired_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "timing.csv"
            self.make_csv(path)
            report = validate_and_summarize(path)
            self.assertEqual(report["slow"]["queue_to_receipt_ns"]["count"], 2000)
            self.assertEqual(report["primary"]["queue_to_receipt_ns"]["count"], 20_000)
            self.assertEqual(report["clock_two_reads_ns"]["p99"], 25)

    def test_missing_primary_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "timing.csv"
            self.make_csv(path, gap=True)
            with self.assertRaisesRegex(ValueError, "noncontiguous primary identity"):
                validate_and_summarize(path)


if __name__ == "__main__":
    unittest.main()
