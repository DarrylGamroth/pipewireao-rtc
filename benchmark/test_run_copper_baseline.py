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
    def test_source_timing_accepts_defaults_and_value_below_95_percent(self) -> None:
        RUNNER.validate_source_timing(474, 2000)
        RUNNER.validate_source_timing(10_000, 94)

    def test_source_timing_rejects_out_of_range_rate_and_readout_at_or_above_95_percent(self) -> None:
        for rate_hz in (0, 10_001):
            with self.subTest(rate_hz=rate_hz), self.assertRaisesRegex(
                    ValueError, "--rate-hz must be in 1..10000"):
                RUNNER.validate_source_timing(rate_hz, 1)
        with self.assertRaisesRegex(ValueError, "--readout-us must be positive"):
            RUNNER.validate_source_timing(1, 0)
        for readout_us in (95, 96):
            with self.subTest(readout_us=readout_us), self.assertRaisesRegex(
                    ValueError, "less than 95% of the frame period"):
                RUNNER.validate_source_timing(10_000, readout_us)

    def test_collect_all_runs_remaining_runners_and_records_failure(self) -> None:
        names = ("heart", "fgn", "jfg")
        returned = {
            "heart": {"returncode": 1, "combined_output": "heart.log"},
            "fgn": {"returncode": 0, "combined_output": "fgn.log"},
            "jfg": {"returncode": 0, "combined_output": "jfg.log"},
        }
        invoked: list[str] = []
        recorded: dict[str, dict] = {}

        def execute(name: str) -> dict:
            invoked.append(name)
            return returned[name]

        with self.assertRaisesRegex(RuntimeError, "heart runner failed"):
            RUNNER.execute_runners(names, execute, recorded, collect_all=True)
        self.assertEqual(invoked, list(names))
        self.assertEqual(recorded, returned)

    def test_runner_execution_remains_fail_fast_by_default(self) -> None:
        names = ("heart", "fgn", "jfg")
        invoked: list[str] = []
        recorded: dict[str, dict] = {}

        def execute(name: str) -> dict:
            invoked.append(name)
            return {"returncode": 1, "combined_output": "heart.log"}

        with self.assertRaisesRegex(RuntimeError, "heart runner failed"):
            RUNNER.execute_runners(names, execute, recorded, collect_all=False)
        self.assertEqual(invoked, ["heart"])
        self.assertEqual(set(recorded), {"heart"})

    def test_heart_config_template_override_is_optional_and_resolved(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            default_template = root / "benchmark/heart/copper_config_aos_matched.yaml"
            default_template.parent.mkdir(parents=True)
            default_template.write_text("default")
            override = root / "custom.yaml"
            override.write_text("custom")

            self.assertEqual(RUNNER.resolve_heart_config_template(root, None),
                             default_template.resolve())
            resolved = RUNNER.resolve_heart_config_template(root, override)
            self.assertEqual(resolved, override.resolve())
            self.assertEqual(RUNNER.heart_config_template_args(None), [])
            self.assertEqual(RUNNER.heart_config_template_args(resolved),
                             ["--config-template", str(resolved)])

    def test_heart_config_template_override_must_be_readable_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(ValueError, "not a readable file"):
                RUNNER.resolve_heart_config_template(Path(temporary), Path(temporary) / "missing.yaml")

    def test_pinned_data_loop_requires_named_single_cpu_fifo_rule(self) -> None:
        profile = {"roles": {"island": {"cpus": "0,2", "required_thread_placements": [
            {"name": "data-loop.0", "policy": "fifo:83", "cpus": "0", "count": 1},
        ]}}}
        self.assertEqual(RUNNER.pinned_data_loop(profile, "island", "data-loop.0"),
                         (0, 83))
        profile["roles"]["island"]["required_thread_placements"][0]["cpus"] = "0,2"
        with self.assertRaisesRegex(ValueError, "one pinned FIFO island data-loop"):
            RUNNER.pinned_data_loop(profile, "island", "data-loop.0")

    def test_required_data_loop_preserves_exact_profile_mask(self) -> None:
        profile = {"roles": {"observer": {"cpus": "0-3", "required_thread_placements": [
            {"name": "data-loop.0", "policy": "fifo:83", "cpus": "0,2", "count": 1},
        ]}}}
        self.assertEqual(RUNNER.required_data_loop(profile, "observer", "data-loop.0"),
                         ({0, 2}, 83))
        self.assertEqual(RUNNER.comma_cpu_list({2, 0}), "0,2")
        profile["roles"]["observer"]["required_thread_placements"][0]["cpus"] = "0,4"
        with self.assertRaisesRegex(ValueError, "exceed the process envelope"):
            RUNNER.required_data_loop(profile, "observer", "data-loop.0")

    def test_single_command_link_requires_wire_vectors_without_observer_claim(self) -> None:
        report = {"qualified": True, "errors": [], "requested_frames": 3,
                  "dm_vectors": 3, "demanded_vectors": None,
                  "command_topology": {"mode": "single-command-link"},
                  "pipewire_mode": "installed-prefix", "pipewire_daemon_sha256": "daemon",
                  "ndarray_filter_chain_sha256": "module"}
        physical = {"qualified": True, "captured_wfs_packets": 6,
                    "captured_dm_commands": 3}
        with patch.object(RUNNER, "json_file", side_effect=[report, physical]):
            self.assertEqual(RUNNER.require_fgn(Path("run"), 3, "daemon", "module"), physical)
        report["demanded_vectors"] = 3
        with patch.object(RUNNER, "json_file", side_effect=[report, physical]):
            with self.assertRaisesRegex(RuntimeError, "cannot claim demanded"):
                RUNNER.require_fgn(Path("run"), 3, "daemon", "module")
        report["command_topology"] = {"mode": "observer-fanout"}
        report["demanded_vectors"] = None
        with patch.object(RUNNER, "json_file", side_effect=[report, physical]):
            with self.assertRaisesRegex(RuntimeError, "observer report"):
                RUNNER.require_fgn(Path("run"), 3, "daemon", "module")

    def test_single_command_link_flags_are_passed_for_row_mode_runners(self) -> None:
        commands = {"fgn": ["run_fgn_copper_row_live.py"],
                    "jfg": ["run_shared_copper_fits.jl", "--ingress-mode", "progressive"]}
        RUNNER.add_single_command_link_flags(commands, True)
        self.assertEqual(commands["fgn"][-1], "--single-command-link")
        self.assertEqual(commands["jfg"][-2:], ["--single-command-link", "true"])

    def test_jfg_single_link_report_still_requires_exact_physical_qualification(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            physical_path = root / "physical.json"
            report_path = root / "report.json"
            physical_path.write_text(json.dumps({"qualified": True}))
            report_path.write_text(json.dumps({
                "requested_frames": 3, "std_wfs_packet_count": 6,
                "std_dm_packet_count": 3,
                "qualification": {"passed": True},
                "physical_summary": str(physical_path),
                "command_topology": {"mode": "single-command-link"},
            }))
            report, physical = RUNNER.require_jfg(report_path, 3)
            self.assertEqual(report["command_topology"]["mode"], "single-command-link")
            self.assertIs(physical["qualified"], True)
            report["std_dm_packet_count"] = 2
            report_path.write_text(json.dumps(report))
            with self.assertRaisesRegex(RuntimeError, "exact WFS and DM delivery"):
                RUNNER.require_jfg(report_path, 3)

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
