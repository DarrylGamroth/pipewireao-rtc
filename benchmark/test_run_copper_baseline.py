"""Packet-boundary phase summaries for the qualified Copper baseline."""

from __future__ import annotations

from decimal import Decimal
import importlib.util
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


BENCHMARK = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCHMARK))
SPEC = importlib.util.spec_from_file_location("run_copper_baseline", BENCHMARK / "run_copper_baseline.py")
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)
REPORT_SPEC = importlib.util.spec_from_file_location(
    "report_copper_phases", BENCHMARK / "report_copper_phases.py")
assert REPORT_SPEC is not None and REPORT_SPEC.loader is not None
REPORT = importlib.util.module_from_spec(REPORT_SPEC)
REPORT_SPEC.loader.exec_module(REPORT)


class CapturePhaseTests(unittest.TestCase):
    @staticmethod
    def write_packets(path: Path, times: list[Decimal], *, kind: str,
                      dm_id_base: int = 0) -> None:
        lines = []
        for ordinal, timestamp in enumerate(times):
            if kind == "wfs":
                fields = [0] * 16
                fields[10:12] = [ordinal % 2 + 1, 2]
                fields[14] = ordinal // 2
                header = struct.pack("<4B8HIQII", *fields)
            else:
                fields = [0] * 9
                fields[2:4] = [1, 1]
                fields[7] = dm_id_base + ordinal
                header = struct.pack("<4BHHQII", *fields)
            lines.append(f"{timestamp:.9f}\t{len(header)}\t{header.hex()}\n")
        path.write_text("".join(lines))

    def test_first_frame_is_separate_from_frames_after_100(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            wfs_path = Path(temporary) / "wfs.tsv"
            dm_path = Path(temporary) / "dm.tsv"
            wfs = []
            dm = []
            for frame in range(120):
                first = Decimal(1000) + Decimal(frame) / 474
                wfs.extend((first, first + Decimal("0.001")))
                dm.append(first + (Decimal("0.0018") if frame == 0
                                   else Decimal("0.0013")))
            self.write_packets(wfs_path, wfs, kind="wfs")
            self.write_packets(dm_path, dm, kind="dm")
            result = RUNNER.capture_latency_phases(wfs_path, dm_path, 120, dm_id_base=0)
            self.assertEqual(result["first_frame"]["terminal_wfs_packet_to_dm_us"], 800)
            self.assertEqual(result["frames_2_through_10"]["terminal_wfs_packet_to_dm_us"]["p99"], 300)
            self.assertEqual(result["frames_101_onward"]["terminal_wfs_packet_to_dm_us"]["count"], 20)
            self.assertEqual(result["frames_101_onward"]["terminal_wfs_packet_to_dm_us"]["p99"], 300)

    def test_rejects_missing_and_early_dm_packets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            wfs_path = Path(temporary) / "wfs.tsv"
            dm_path = Path(temporary) / "dm.tsv"
            self.write_packets(wfs_path, [Decimal("1"), Decimal("1.001")], kind="wfs")
            self.write_packets(dm_path, [Decimal("1.002")], kind="dm")
            with self.assertRaisesRegex(RuntimeError, "expected 4 packet timestamps"):
                RUNNER.capture_latency_phases(wfs_path, dm_path, 2, dm_id_base=0)
            self.write_packets(wfs_path, [Decimal("1"), Decimal("1.001"),
                                          Decimal("2"), Decimal("2.001")], kind="wfs")
            self.write_packets(dm_path, [Decimal("1.0005"), Decimal("2.002")], kind="dm")
            with self.assertRaisesRegex(RuntimeError, "DM packet preceded"):
                RUNNER.capture_latency_phases(wfs_path, dm_path, 2, dm_id_base=0)

    def test_rejects_reordered_wfs_and_dm_identities(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            wfs_path = Path(temporary) / "wfs.tsv"
            dm_path = Path(temporary) / "dm.tsv"
            self.write_packets(wfs_path, [Decimal("1"), Decimal("1.001")], kind="wfs")
            self.write_packets(dm_path, [Decimal("1.002")], kind="dm")
            lines = wfs_path.read_text().splitlines(keepends=True)
            wfs_path.write_text("".join(reversed(lines)))
            with self.assertRaisesRegex(RuntimeError, "WFS packet identity/order mismatch"):
                RUNNER.capture_latency_phases(wfs_path, dm_path, 1, dm_id_base=0)
            self.write_packets(wfs_path, [Decimal("1"), Decimal("1.001")], kind="wfs")
            with self.assertRaisesRegex(RuntimeError, "DM packet identity/order mismatch"):
                RUNNER.capture_latency_phases(wfs_path, dm_path, 1, dm_id_base=1)

    def test_manifest_gate_and_recomputed_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "run-001"
            for owner in ("heart", "fgn"):
                (root / owner).mkdir(parents=True)
            wfs = [Decimal("1"), Decimal("1.001"), Decimal("2"), Decimal("2.001")]
            dm = [Decimal("1.0013"), Decimal("2.0013")]
            for wfs_path, dm_path in (
                (root / "heart/std-wfs-packets.tsv", root / "heart/std-dm-packets.tsv"),
                (root / "fgn/wfs-packets.tsv", root / "fgn/dm-packets.tsv"),
                (root / "jfg-wfs-packets.tsv", root / "jfg-dm-packets.tsv"),
            ):
                self.write_packets(wfs_path, wfs, kind="wfs")
                self.write_packets(dm_path, dm, kind="dm",
                                   dm_id_base=1 if wfs_path.parent.name == "heart" else 0)
            published = {
                "first_wfs_packet_to_dm_us": {"count": 2, "min": 1300, "p50": 1300,
                                               "p99": 1300, "max": 1300},
                "terminal_wfs_packet_to_dm_us": {"count": 2, "min": 300, "p50": 300,
                                                  "p99": 300, "max": 300},
            }
            manifest = {
                "qualified": True, "frames": 2, "mode": "row",
                "runs": [{
                    "index": 1,
                    "runner_reports": {"heart": str(root / "heart/qualification.json")},
                    "commands": {"jfg": {"argv": ["julia", "--graph-warmup", "offline"]}},
                    "qualification": {owner: published for owner in ("heart", "fgn", "jfg")},
                }],
            }
            path = Path(temporary) / "manifest.json"
            path.write_text(json.dumps(manifest))
            with patch.object(REPORT, "requalify_capture"):
                result = REPORT.summarize_manifest(path)
            self.assertEqual(result["runs"][0]["owners"]["heart"]["phases"]["first_frame"]
                             ["terminal_wfs_packet_to_dm_us"], 300)
            manifest["qualified"] = False
            path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(RuntimeError, "unqualified manifest"):
                REPORT.summarize_manifest(path)


if __name__ == "__main__":
    unittest.main()
