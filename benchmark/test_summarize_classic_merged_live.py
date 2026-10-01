"""Offline tests for merged Classic campaign normalization and QoS exclusions."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from summarize_classic_merged_live import _apply_qos_admission, _zero_qos_gate, read_manifests


class MergedLiveSummaryTests(unittest.TestCase):
    def manifests(self, root, hashes=("same", "same"), rates=(100, 250), readouts=(2000, 2000), workers=(0, 0)):
        paths = []
        for index, (digest, rate, readout, worker) in enumerate(zip(hashes, rates, readouts, workers)):
            path = root / f"manifest-{index}.json"
            run = {"path": "fgn-frame", "rate_hz": rate, "readout_us": readout,
                   "repeat": 1, "mode": "latency0", "diagnostic": False,
                   "directory": str(root / f"run-{index}"),
                   "cpu_latency_request": {"requested_us": 0, "effective_during_us": 0},
                   "report.json": {"frames": 1029, "row_workers": worker,
                                   "sha256": {"/immutable/plugin.so": digest}}}
            path.write_text(json.dumps({"requested": {"diagnostic": False, "modes": ["latency0"], "frames": 1029},
                                        "runs": [run]}))
            paths.append(path)
        return paths

    def test_changed_build_is_not_a_repeated_series(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary), hashes=("original", "changed"))
            with self.assertRaisesRegex(ValueError, "incompatible source, binary"):
                read_manifests(paths)

    def test_changed_workers_are_not_combined_percentiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary), workers=(0, 3))
            with self.assertRaisesRegex(ValueError, "incompatible source, binary"):
                read_manifests(paths)

    def test_changed_numerical_policy_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary))
            changed = json.loads(paths[1].read_text())
            changed["runs"][0]["command"] = ["--numerical-acceptance", "source-arithmetic"]
            paths[1].write_text(json.dumps(changed))
            with self.assertRaisesRegex(ValueError, "incompatible source, binary"):
                read_manifests(paths)

    def test_different_backend_fixtures_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary))
            for index, path in enumerate(paths):
                content = json.loads(path.read_text())
                run = content["runs"][0]
                run["path"] = ("fgn-frame", "jfg-frame")[index]
                run["arithmetic-acceptance.json"] = {"fixture_sha256": {"reconstructor": str(index)}}
                path.write_text(json.dumps(content))
            with self.assertRaisesRegex(ValueError, "incompatible scientific fixture"):
                read_manifests(paths)

    def test_missing_post_delivery_arithmetic_is_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary))
            content = json.loads(paths[0].read_text())
            content["runs"][0]["arithmetic-acceptance.json"] = {"fixture_sha256": {"reconstructor": "same"}}
            paths[0].write_text(json.dumps(content))
            merged, _, _ = read_manifests(paths)
            self.assertEqual(len(merged["runs"]), 2)
            self.assertNotIn("arithmetic", merged["runs"][1])

    def test_capacity_readout_law_is_explicit_and_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary), rates=(500, 1000), readouts=(1700, 850))
            with self.assertRaisesRegex(ValueError, "mixed readouts"):
                read_manifests(paths)
            merged, _, _ = read_manifests(paths, .85)
            self.assertEqual(merged["readout_contract"]["fraction"], .85)
            with self.assertRaisesRegex(ValueError, "readout differs"):
                read_manifests(paths, .8)

    def test_duplicate_window_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.manifests(Path(temporary))
            with self.assertRaisesRegex(ValueError, "duplicate run directory"):
                read_manifests([paths[0], paths[0]])

    def test_missing_qos_record_is_retained_as_unobserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "manifest.json"
            run = {
                "path": "fgn-frame", "rate_hz": 500, "readout_us": 1700,
                "repeat": 1, "mode": "latency0", "diagnostic": False,
                "directory": str(root / "run"), "report.json": {"frames": 1029},
            }
            manifest_path.write_text(json.dumps({
                "requested": {"diagnostic": False, "modes": ["latency0"], "frames": 1029},
                "runs": [run],
            }))
            normalized, _, _ = read_manifests([manifest_path])
            self.assertIsNone(normalized["runs"][0].get("cpu_latency_request"))
            self.assertIsNone(_zero_qos_gate(normalized["runs"][0])["passed"])

    def test_unadmitted_qos_windows_are_excluded_from_capacity(self):
        windows = []
        run_index = {}
        for repeat in range(1, 4):
            directory = f"/synthetic/fgn-frame-500-{repeat}"
            run = {"directory": directory, "repeat": repeat, "cpu_latency_request": None}
            run_index[(directory, repeat)] = run
            windows.append({
                "directory": directory, "repeat": repeat,
                "status": "passed", "delivery_status": "passed", "deadline_status": "passed",
                "conditions": {"frames": 1029, "readout_us": 1700},
                "gates": {"exact_wire_delivery": {"passed": True}}, "reasons": [],
            })
        rate = {
            "rate_hz": 500, "windows": windows, "required_windows": 3,
            "duplicate_windows": False, "status": "passed", "delivery_status": "passed",
            "deadline_status": "passed", "eligible_windows": 3, "excluded_windows": 0,
            "unassessed_windows": 0,
            "contracts": {"delivery": {"status": "passed"}, "deadline": {"status": "passed"}},
        }
        series = {"path": "fgn-frame", "rates": [rate], "contracts": {}}
        classified = {"series": [series]}
        _apply_qos_admission(classified, run_index)
        self.assertEqual(rate["status"], "insufficient_windows")
        self.assertEqual(rate["excluded_windows"], 3)
        self.assertTrue(all(window["status"] == "excluded" for window in windows))
        self.assertTrue(all(window["gates"]["zero_qos_admission"]["passed"] is None
                            for window in windows))
        self.assertIsNone(series["contracts"]["deadline"]["highest_tested_passing_rate_hz"])

    def test_nonzero_effective_qos_is_not_admitted(self):
        result = _zero_qos_gate({
            "cpu_latency_request": {"requested_us": 0, "effective_during_us": 2_000_000_000}
        })
        self.assertFalse(result["passed"])

    def test_nonzero_requested_qos_is_rejected_as_a_mixed_campaign(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "manifest.json"
            run = {
                "path": "fgn-frame", "rate_hz": 500, "readout_us": 1700,
                "repeat": 1, "mode": "latency0", "diagnostic": False,
                "directory": str(root / "run"),
                "cpu_latency_request": {"requested_us": 100, "effective_during_us": 100},
                "report.json": {"frames": 1029},
            }
            manifest_path.write_text(json.dumps({
                "requested": {"diagnostic": False, "modes": ["latency0"], "frames": 1029},
                "runs": [run],
            }))
            with self.assertRaisesRegex(ValueError, "nonzero CPU-latency QoS"):
                read_manifests([manifest_path])


if __name__ == "__main__":
    unittest.main()
