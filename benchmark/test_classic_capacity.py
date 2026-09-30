"""Synthetic finite-window classification checks; no live runner or benchmark."""
import copy
import tempfile
import shutil
import subprocess
import unittest
from pathlib import Path

from classic_capacity import WFS, classify_manifest, classify_window, source_pacing_from_packets


def sample(rate=100, repeat=1, path="fgn-row"):
    directory = f"/synthetic/{path}-{rate}-{repeat}"
    report = {"frames": 63, "qualified": True, "functional_wire_qualified": True,
              "process_returncodes": [0, 0],
              "placement_request": {"daemon_loop_cpu": 0, "adapter_loop_cpu": 4, "fifo_priority": 83},
              "arithmetic_acceptance": {"arithmetic_consistency_passed": True, "exact_model_passed": True}}
    run = {"path": path, "directory": directory, "repeat": repeat, "rate_hz": rate,
           "readout_us": 2000, "returncode": 0, "report": report,
           "command": ["runner", "--numerical-acceptance", "source-arithmetic"],
           "exact_wire_delivery": True,
           "latency": {"all": {"first_to_dm_us": {"count": 63, "max": .5e6 / rate}},
                       "deadline_exceeded_count": 0}}
    def snapshot(name, cpu, priority=83):
        return {"available": True, "threads": [{"name": name, "affinity": [cpu],
                "scheduler": {"policy": "fifo", "priority": priority}}]}
    placements = {"daemon": snapshot("rtc-data-loop", 0), "adapter": snapshot("data-loop.0", 4)}
    evidence = {"numerical": {"qualified": False, "failed_values": 2, "max_absolute_error_um": 1.3e-6,
                               "clipping_decision_mismatches": 0},
                "placement_before": placements, "placement_after": copy.deepcopy(placements),
                "source_pacing": {"achieved_source_rate_hz": rate, "complete_source_window": True}}
    if path == "heart":
        evidence["heart_cpu_map"] = "HOP0.proc.w = { 2 }\n"
        evidence["placement_before"] = {"heart": snapshot("HOP0.proc.w", 2, 15)}
        evidence["placement_after"] = copy.deepcopy(evidence["placement_before"])
    return run, evidence


def campaign(samples, minimum_windows=3):
    manifest = {"requested": {"frames": 63, "workers": 0, "layout": "shared"},
                "runs": [run for run, _ in samples]}
    evidence = {run["directory"]: data for run, data in samples}
    return classify_manifest(manifest, evidence, minimum_windows=minimum_windows)


class CapacityTests(unittest.TestCase):
    def test_repeated_pass_keeps_historical_numerical_failures(self):
        result = campaign([sample(repeat=n) for n in range(1, 4)])
        series = result["series"][0]
        self.assertEqual(series["contracts"]["deadline"]["highest_tested_passing_rate_hz"], 100)
        self.assertIsNone(series["contracts"]["deadline"]["first_tested_failure_upper_bound_hz"])
        for window in series["rates"][0]["windows"]:
            self.assertFalse(window["historical_1e_minus_6"]["passed"])
            self.assertTrue(window["gates"]["science_acceptance"]["passed"])

    def test_underdrive_is_excluded_and_not_failure_upper_bound(self):
        samples = [sample(100, n) for n in range(1, 4)]
        for n in range(1, 4):
            run, evidence = sample(200, n)
            evidence["source_pacing"]["achieved_source_rate_hz"] = 180
            samples.append((run, evidence))
        series = campaign(samples)["series"][0]
        self.assertEqual(series["contracts"]["deadline"]["highest_tested_passing_rate_hz"], 100)
        self.assertIsNone(series["contracts"]["deadline"]["first_tested_failure_upper_bound_hz"])
        self.assertEqual(series["rates"][1]["excluded_windows"], 3)
        self.assertEqual(series["rates"][1]["windows"][0]["gates"]["source_pacing"]["status"], "underdriven")

    def test_repeated_eligible_deadline_failure_sets_finite_upper_bound(self):
        samples = [sample(100, n) for n in range(1, 4)]
        for n in range(1, 4):
            run, evidence = sample(200, n)
            if n == 2:
                run["latency"]["deadline_exceeded_count"] = 1
                run["latency"]["all"]["first_to_dm_us"]["max"] = 5001
            samples.append((run, evidence))
        series = campaign(samples)["series"][0]
        self.assertEqual(series["contracts"]["deadline"]["first_tested_failure_upper_bound_hz"], 200)
        self.assertEqual(series["rates"][1]["status"], "failed")
        self.assertEqual(series["highest_tested_exact_delivery_rate_hz"], 200)
        self.assertEqual(series["highest_tested_deadline_clean_rate_hz"], 100)
        self.assertIsNone(series["contracts"]["delivery"]["first_tested_failure_upper_bound_hz"])

    def test_normal_exit_and_placement_failures_are_separate_exclusions(self):
        run, evidence = sample()
        run["report"]["process_returncodes"] = [0, 1]
        result = classify_window(run, {}, evidence)
        self.assertEqual(result["status"], "excluded")
        self.assertFalse(result["gates"]["normal_child_exit"]["passed"])
        run["report"]["process_returncodes"] = [0, 0]
        evidence["placement_after"]["adapter"]["threads"][0]["affinity"] = [6]
        result = classify_window(run, {}, evidence)
        self.assertEqual(result["status"], "excluded")
        self.assertFalse(result["gates"]["rtc_placement"]["passed"])

    def test_heart_needs_exact_model_in_addition_to_broad_bound(self):
        run, evidence = sample(path="heart")
        self.assertEqual(classify_window(run, {}, evidence)["status"], "passed")
        run["report"]["arithmetic_acceptance"]["exact_model_passed"] = False
        result = classify_window(run, {}, evidence)
        self.assertEqual(result["status"], "failed")
        self.assertFalse(result["gates"]["science_acceptance"]["passed"])

    def test_strict_policy_does_not_use_arithmetic_success(self):
        run, evidence = sample()
        run["command"] = ["runner"]
        result = classify_window(run, {}, evidence)
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["gates"]["science_acceptance"]["policy"], "strict")

    def test_unknown_load_or_missing_science_never_passes(self):
        run, evidence = sample()
        evidence["source_pacing"] = {}
        self.assertEqual(classify_window(run, {}, evidence)["status"], "excluded")
        run, evidence = sample()
        evidence.pop("numerical")
        self.assertEqual(classify_window(run, {}, evidence)["status"], "unassessed")

    def test_average_pacing_tolerance_is_explicit_and_symmetric(self):
        run, evidence = sample()
        for achieved in (99, 101):
            evidence["source_pacing"]["achieved_source_rate_hz"] = achieved
            self.assertEqual(classify_window(run, {}, evidence)["status"], "passed")
        for achieved in (98.99, 101.01):
            evidence["source_pacing"]["achieved_source_rate_hz"] = achieved
            self.assertEqual(classify_window(run, {}, evidence)["status"], "excluded")
            self.assertEqual(classify_window(run, {}, evidence, pacing_tolerance=.02)["status"], "passed")

    def test_single_window_and_duplicate_evidence_do_not_satisfy_repeats(self):
        self.assertEqual(campaign([sample()])["series"][0]["rates"][0]["status"], "insufficient_windows")
        first = sample()
        self.assertEqual(campaign([first, copy.deepcopy(first), sample(repeat=2)])["series"][0]["rates"][0]["status"], "incomparable_windows")
        with self.assertRaises(ValueError):
            campaign([sample()], minimum_windows=1)

    def test_missing_or_contradictory_deadline_evidence_is_unassessed(self):
        run, evidence = sample()
        run["latency"]["all"]["first_to_dm_us"]["count"] = 62
        self.assertEqual(classify_window(run, {}, evidence)["status"], "unassessed")
        run, evidence = sample()
        run["latency"]["all"]["first_to_dm_us"]["max"] = 10001
        self.assertEqual(classify_window(run, {}, evidence)["status"], "unassessed")

    def test_delivery_failure_with_measured_ingress_is_not_hidden_by_launcher_exit(self):
        run, evidence = sample()
        run["exact_wire_delivery"] = False
        run["returncode"] = 1
        run["latency"] = {}
        result = classify_window(run, {}, evidence)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["gates"]["normal_child_exit"]["passed"])

    def test_source_rate_can_be_measured_when_no_dm_was_delivered(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wfs-packets.tsv"
            lines = []
            for frame in range(2):
                for packet in range(1, 33):
                    fields = [0] * 16
                    fields[10], fields[11], fields[-2] = packet, 32, frame
                    stamp = 100 + frame * .01 + (packet - 1) * .00005
                    lines.append(f"{stamp:.8f}\t0\t{WFS.pack(*fields).hex()}\n")
            path.write_text("".join(lines))
            result = source_pacing_from_packets(directory, 2)
            self.assertEqual(result["achieved_source_rate_hz"], 100)
            path.write_text("".join(lines[:-1]))
            with self.assertRaises(ValueError):
                source_pacing_from_packets(directory, 2)


    @unittest.skipUnless(shutil.which("zstd"), "zstd executable unavailable")
    def test_zstd_complete_corrupt_and_incomplete_packet_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wfs-packets.tsv.zst"
            lines = []
            for frame in range(2):
                for packet in range(1, 33):
                    fields = [0] * 16
                    fields[10], fields[11], fields[-2] = packet, 32, frame
                    stamp = 100 + frame * .01 + (packet - 1) * .00005
                    lines.append(f"{stamp:.8f}\t0\t{WFS.pack(*fields).hex()}\n")
            def compressed(content):
                return subprocess.run(["zstd", "-q", "-c"], input=content.encode(),
                                      stdout=subprocess.PIPE, check=True).stdout
            complete = compressed("".join(lines))
            path.write_bytes(complete)
            self.assertEqual(source_pacing_from_packets(directory, 2)["achieved_source_rate_hz"], 100)
            for content in (complete[:-2], b"not a zstd frame", compressed("".join(lines[:-1]))):
                path.write_bytes(content)
                with self.assertRaises(ValueError):
                    source_pacing_from_packets(directory, 2)


if __name__ == "__main__":
    unittest.main()
