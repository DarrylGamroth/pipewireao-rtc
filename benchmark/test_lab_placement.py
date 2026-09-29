"""Focused, privilege-free tests for the laboratory placement launcher."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


LAUNCHER = Path(__file__).with_name("lab_placement.py")
SPEC = importlib.util.spec_from_file_location("lab_placement", LAUNCHER)
assert SPEC is not None and SPEC.loader is not None
LAB_PLACEMENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LAB_PLACEMENT)


class LabPlacementTests(unittest.TestCase):
    def test_page_backing_accounts_for_resident_mapping_sizes(self) -> None:
        smaps = """1000-2000 rw-p 00000000 00:00 0
KernelPageSize:        4 kB
Rss:                  12 kB
AnonHugePages:         0 kB
2000-3000 rw-p 00000000 00:00 0
KernelPageSize:     2048 kB
Rss:                2048 kB
AnonHugePages:      2048 kB
Private_Hugetlb:       0 kB
"""
        summary = LAB_PLACEMENT.summarize_page_backing(smaps)
        self.assertEqual(summary["mappings"], 2)
        self.assertEqual(summary["kilobytes"]["Rss"], 2060)
        self.assertEqual(summary["kilobytes"]["AnonHugePages"], 2048)
        self.assertEqual(summary["resident_by_kernel_page_size_kilobytes"],
                         {"4": 12, "2048": 2048})
        self.assertTrue(summary["complete"])
        self.assertFalse(LAB_PLACEMENT.summarize_page_backing(
            "1000-2000 rw-p 00000000 00:00 0\nKernelPageSize: 4 kB\n"
        )["complete"])
        self.assertFalse(LAB_PLACEMENT.summarize_page_backing(
            "1000-2000 rw-p 00000000 00:00 0\nRss: 4 kB\n"
        )["complete"])
        self.assertTrue(LAB_PLACEMENT.read_page_backing(os.getpid())["available"])

    def run_launcher(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(LAUNCHER), *arguments], text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def start_dummy_process(self) -> subprocess.Popen[str]:
        return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"], text=True)

    def test_rejects_cpu_unavailable_to_launcher_without_opening_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, gate = root / "record.json", root / "gate"
            unavailable = max(os.sched_getaffinity(0)) + 1_000_000
            completed = self.run_launcher(
                "run", "--role", "dummy", "--cpus", str(unavailable), "--policy", "other",
                "--ready-file", str(root / "ready"), "--gate-file", str(gate), "--output", str(output),
                "--", sys.executable, "-c", "raise SystemExit(99)",
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(gate.exists())
            record = json.loads(output.read_text())
            self.assertEqual(record["outcome"], "failed")
            self.assertIn("unavailable", record["error"])

    def test_creates_gate_only_after_ready_and_records_threads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, gate, output = root / "ready", root / "gate", root / "record.json"
            cpu = min(os.sched_getaffinity(0))
            child = (
                "from pathlib import Path; import sys, time; "
                "ready, gate = map(Path, sys.argv[1:3]); ready.write_text('warmed'); "
                "time.sleep(.2); "
                "raise SystemExit(0 if gate.exists() else 8)"
            )
            completed = self.run_launcher(
                "run", "--role", "dummy", "--cpus", str(cpu), "--policy", "other",
                "--ready-file", str(ready), "--gate-file", str(gate), "--output", str(output),
                "--", sys.executable, "-c", child, str(ready), str(gate),
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(gate.exists())
            record = json.loads(output.read_text())
            self.assertEqual(record["outcome"], "completed")
            snapshot = record["snapshots"]["before_gate"]
            self.assertTrue(snapshot["available"])
            self.assertTrue(snapshot["threads"])
            for thread in snapshot["threads"]:
                self.assertEqual(thread["scheduler"], {
                    "policy": "other", "priority": 0, "reset_on_fork": False,
                })
                self.assertTrue(set(thread["affinity"]) <= {cpu})

    def test_scheduler_reset_on_fork_flag_preserves_base_policy(self) -> None:
        flag = LAB_PLACEMENT.SCHED_RESET_ON_FORK
        self.assertEqual(LAB_PLACEMENT.scheduler_details(os.SCHED_OTHER | flag), ("other", True))
        self.assertEqual(LAB_PLACEMENT.scheduler_details(os.SCHED_FIFO | flag), ("fifo", True))

    def test_verify_records_an_already_running_process(self) -> None:
        process = self.start_dummy_process()
        try:
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "record.json"
                cpus = LAB_PLACEMENT.format_cpu_list(set(os.sched_getaffinity(0)))
                completed = self.run_launcher(
                    "verify", "--role", "dummy", "--pid", str(process.pid), "--cpus", cpus,
                    "--leader-policy", "other", "--output", str(output),
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                record = json.loads(output.read_text())
                self.assertEqual(record["outcome"], "verified")
                self.assertTrue(record["observed"]["available"])
                self.assertTrue(record["observed"]["page_backing"]["available"])
                self.assertGreater(record["observed"]["page_backing"]["mappings"], 0)
                self.assertEqual(record["requested"]["pid"], process.pid)
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_verify_rejects_live_affinity_and_policy_mismatches(self) -> None:
        process = self.start_dummy_process()
        try:
            available = sorted(os.sched_getaffinity(0))
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                if len(available) > 1:
                    affinity_output = root / "affinity.json"
                    affinity = self.run_launcher(
                        "verify", "--role", "dummy", "--pid", str(process.pid),
                        "--cpus", str(available[0]), "--leader-policy", "other",
                        "--output", str(affinity_output),
                    )
                    self.assertNotEqual(affinity.returncode, 0)
                    self.assertIn("outside declared CPUs", json.loads(affinity_output.read_text())["error"])
                policy_output = root / "policy.json"
                policy = self.run_launcher(
                    "verify", "--role", "dummy", "--pid", str(process.pid),
                    "--cpus", LAB_PLACEMENT.format_cpu_list(set(available)),
                    "--leader-policy", "fifo:20", "--output", str(policy_output),
                )
                self.assertNotEqual(policy.returncode, 0)
                self.assertIn("leader policy requires fifo:20", json.loads(policy_output.read_text())["error"])
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_rejects_thread_that_escapes_declared_cpu_before_gate(self) -> None:
        available = sorted(os.sched_getaffinity(0))
        if len(available) < 2:
            self.skipTest("this host exposes only one CPU to the test process")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, gate, output = root / "ready", root / "gate", root / "record.json"
            declared, escaped = available[:2]
            child = "\n".join((
                "from pathlib import Path",
                "import os, sys, threading, time",
                "ready = Path(sys.argv[1])",
                f"escaped = {escaped}",
                "started = threading.Event()",
                "release = threading.Event()",
                "worker = threading.Thread(target=lambda: (os.sched_setaffinity(threading.get_native_id(), {escaped}), started.set(), release.wait()))",
                "worker.start()",
                "started.wait()",
                "ready.write_text('warmed')",
                "time.sleep(5)",
            ))
            completed = self.run_launcher(
                "run", "--role", "dummy", "--cpus", str(declared), "--policy", "other",
                "--ready-file", str(ready), "--gate-file", str(gate), "--output", str(output),
                "--", sys.executable, "-c", child, str(ready),
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(gate.exists())
            record = json.loads(output.read_text())
            self.assertIn("outside declared CPUs", record["error"])
            observed = record["snapshots"]["before_gate"]["threads"]
            self.assertTrue(any(escaped in thread["affinity"] for thread in observed))

    def test_qualified_handshake_captures_live_post_run_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, gate = root / "ready", root / "gate"
            finished, release, output = root / "finished", root / "release", root / "record.json"
            cpu = min(os.sched_getaffinity(0))
            child = "\n".join((
                "from pathlib import Path",
                "import sys, time",
                "ready, gate, finished, release = map(Path, sys.argv[1:5])",
                "def wait_for(path):",
                "    while not path.exists(): time.sleep(.01)",
                "ready.write_text('warmed')",
                "wait_for(gate)",
                "finished.write_text('ingress complete')",
                "wait_for(release)",
            ))
            completed = self.run_launcher(
                "run", "--role", "dummy", "--cpus", str(cpu), "--policy", "other", "--qualified",
                "--ready-file", str(ready), "--gate-file", str(gate), "--finished-file", str(finished),
                "--release-file", str(release), "--output", str(output),
                "--", sys.executable, "-c", child, str(ready), str(gate), str(finished), str(release),
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(release.exists())
            record = json.loads(output.read_text())
            self.assertEqual(record["outcome"], "completed")
            self.assertTrue(record["snapshots"]["after_run"]["available"])
            self.assertTrue(record["snapshots"]["after_run"]["threads"])

    def test_mixed_thread_policy_rules_do_not_infer_thread_roles(self) -> None:
        snapshot = {
            "pid": 101,
            "threads": [
                {"tid": 101, "affinity": [4], "affinity_list": "4",
                 "scheduler": {"policy": "other", "priority": 0}},
                {"tid": 102, "affinity": [4], "affinity_list": "4",
                 "scheduler": {"policy": "fifo", "priority": 20}},
            ],
        }
        LAB_PLACEMENT.verify_snapshot(
            snapshot, {4}, ("other", 0), {("other", 0), ("fifo", 20)}, {("fifo", 20): 1}
        )
        with self.assertRaisesRegex(LAB_PLACEMENT.LaunchError, "required exactly 2"):
            LAB_PLACEMENT.verify_snapshot(
                snapshot, {4}, ("other", 0), {("other", 0), ("fifo", 20)}, {("fifo", 20): 2}
            )

    def test_thread_profile_requires_exact_policy_and_affinity_counts(self) -> None:
        profile = {"schema_version": 1, "roles": {"graph": {
            "cpus": "4-5", "leader_policy": "other",
            "required_policy_counts": {"fifo:83": 1},
            "required_thread_placements": [
                {"policy": "fifo:83", "cpus": "4", "count": 1},
                {"policy": "other", "cpus": "5", "count": 1},
            ],
        }}}
        snapshot = {"pid": 101, "threads": [
            {"tid": 101, "affinity": [5], "scheduler": {"policy": "other", "priority": 0}},
            {"tid": 102, "affinity": [4], "scheduler": {"policy": "fifo", "priority": 83}},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "profile.json"
            path.write_text(json.dumps(profile))
            parsed = LAB_PLACEMENT.read_thread_profile(path)
        LAB_PLACEMENT.verify_thread_profile(snapshot, "graph", {4, 5}, ("other", 0), parsed)
        snapshot["threads"][1]["affinity"] = [4, 5]
        with self.assertRaisesRegex(LAB_PLACEMENT.LaunchError, "profile requires exactly 1"):
            LAB_PLACEMENT.verify_thread_profile(snapshot, "graph", {4, 5}, ("other", 0), parsed)
        snapshot["threads"][1]["affinity"] = [4]
        snapshot["threads"][1]["scheduler"]["priority"] = 0
        with self.assertRaisesRegex(LAB_PLACEMENT.LaunchError, "has 0 fifo:83 threads"):
            LAB_PLACEMENT.verify_thread_profile(snapshot, "graph", {4, 5}, ("other", 0), parsed)

    def test_verify_rejects_missing_role_profile_and_records_failure(self) -> None:
        process = self.start_dummy_process()
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                profile = root / "profile.json"
                profile.write_text(json.dumps({"schema_version": 1, "roles": {"other-role": {
                    "cpus": LAB_PLACEMENT.format_cpu_list(set(os.sched_getaffinity(0))),
                    "leader_policy": "other", "required_policy_counts": {},
                    "required_thread_placements": [],
                }}}))
                output = root / "record.json"
                completed = subprocess.run(
                    [sys.executable, str(LAUNCHER), "verify", "--role", "dummy", "--pid", str(process.pid),
                     "--cpus", LAB_PLACEMENT.format_cpu_list(set(os.sched_getaffinity(0))),
                     "--leader-policy", "other", "--output", str(output)],
                    env={**os.environ, LAB_PLACEMENT.THREAD_PROFILE_ENV: str(profile)},
                    text=True, capture_output=True, check=False,
                )
                self.assertNotEqual(completed.returncode, 0)
                record = json.loads(output.read_text())
                self.assertEqual(record["outcome"], "failed")
                self.assertIn("no contract for role dummy", record["error"])
        finally:
            process.terminate()
            process.wait(timeout=5)

    def test_qualified_handshake_withholds_release_after_post_run_drift(self) -> None:
        available = sorted(os.sched_getaffinity(0))
        if len(available) < 2:
            self.skipTest("this host exposes only one CPU to the test process")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready, gate = root / "ready", root / "gate"
            finished, release, output = root / "finished", root / "release", root / "record.json"
            declared, escaped = available[:2]
            child = "\n".join((
                "from pathlib import Path",
                "import os, sys, time",
                "ready, gate, finished = map(Path, sys.argv[1:4])",
                f"escaped = {escaped}",
                "def wait_for(path):",
                "    while not path.exists(): time.sleep(.01)",
                "ready.write_text('warmed')",
                "wait_for(gate)",
                "os.sched_setaffinity(0, {escaped})",
                "finished.write_text('ingress complete')",
                "time.sleep(5)",
            ))
            completed = self.run_launcher(
                "run", "--role", "dummy", "--cpus", str(declared), "--policy", "other", "--qualified",
                "--ready-file", str(ready), "--gate-file", str(gate), "--finished-file", str(finished),
                "--release-file", str(release), "--output", str(output),
                "--", sys.executable, "-c", child, str(ready), str(gate), str(finished),
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertFalse(release.exists())
            record = json.loads(output.read_text())
            self.assertIn("outside declared CPUs", record["error"])
            self.assertTrue(record["snapshots"]["after_run"]["available"])


if __name__ == "__main__":
    unittest.main()
