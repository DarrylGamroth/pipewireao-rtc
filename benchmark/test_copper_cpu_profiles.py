"""CPU0-free contracts for maintained Copper placement profiles."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest


BENCHMARK = Path(__file__).resolve().parent
sys.path.insert(0, str(BENCHMARK))
import run_copper_baseline as baseline  # noqa: E402


PROFILE_NAMES = (
    "ryzen-6800h-copper.json",
    "ryzen-6800h-copper-all-loops.json",
    "ryzen-6800h-rtc-copper-native.json",
    "ryzen-6800h-rtc-copper-julia.json",
)
PROCESS_CPUS = "2,4,6,8,10,14"
RESERVED = {0, 1}


def read_profile(name: str) -> dict:
    return json.loads((BENCHMARK / "profiles" / name).read_text())


def loop_cpu(role: dict, name: str) -> str:
    matches = [item for item in role["required_thread_placements"]
               if item.get("name") == name]
    if len(matches) != 1:
        raise AssertionError(f"expected one {name!r} placement, found {len(matches)}")
    return matches[0]["cpus"]


class CopperCpuProfileTests(unittest.TestCase):
    def test_baseline_launch_defaults_reserve_cpus_zero_and_one(self) -> None:
        self.assertEqual(baseline.DEFAULT_RTC_CPUS, PROCESS_CPUS)
        self.assertEqual(baseline.DEFAULT_JULIA_PIN_CPUS, "4,6")
        self.assertEqual(baseline.DEFAULT_OBSERVER_CPUS, "14")
        self.assertEqual(baseline.DEFAULT_HEART_CPU_MAP,
                         BENCHMARK / "profiles/ryzen-6800h-classic.cpu")
        self.assertEqual(baseline.DEFAULT_HEART_THREAD_MAP,
                         BENCHMARK / "profiles/ryzen-6800h-classic.threads")
        self.assertTrue(RESERVED.isdisjoint(map(int, baseline.DEFAULT_RTC_CPUS.split(","))))

    def test_every_profile_excludes_reserved_cpus_and_keeps_source_on_twelve(self) -> None:
        for name in PROFILE_NAMES:
            with self.subTest(profile=name):
                roles = read_profile(name)["roles"]
                for role_name, role in roles.items():
                    cpus = set(map(int, role["cpus"].split(",")))
                    self.assertTrue(RESERVED.isdisjoint(cpus), role_name)
                    for placement in role["required_thread_placements"]:
                        thread_cpus = set(map(int, placement["cpus"].split(",")))
                        self.assertTrue(RESERVED.isdisjoint(thread_cpus),
                                        (role_name, placement))
                if "simulator" in roles:
                    self.assertEqual(roles["simulator"]["cpus"], "12")

    def test_heart_worker_layout_and_counts_are_preserved(self) -> None:
        expected = {
            "HOP0.wfs.w": "2", "HOP0.proc.w": "4", "HOP0.recon.w": "6",
            "WCC.tfc.w": "8", "WCC.clwc.w": "8", "WCC.dm0.w": "10",
            "MON.perf": "14", "MON.aoLoop": "14",
        }
        for name in PROFILE_NAMES[:2]:
            with self.subTest(profile=name):
                role = read_profile(name)["roles"]["heart-rtc"]
                actual = {item["name"]: item["cpus"]
                          for item in role["required_thread_placements"]}
                self.assertEqual(actual, expected)
                self.assertEqual(role["required_policy_counts"],
                                 {"fifo:15": 7, "fifo:20": 1})

    def test_baseline_loops_match_the_named_process_layout(self) -> None:
        for name in PROFILE_NAMES[:2]:
            with self.subTest(profile=name):
                roles = read_profile(name)["roles"]
                self.assertEqual(loop_cpu(roles["daemon"], "rtc-data-loop"), "2")
                self.assertEqual(loop_cpu(roles["pipewire-ao-daemon"], "rtc-data-loop"), "2")
                self.assertEqual(loop_cpu(roles["island"], "data-loop.0"), "4")
                self.assertEqual(loop_cpu(roles["fgn-command-observer"], "data-loop.0"), "14")
                self.assertEqual(loop_cpu(roles["observer"], "data-loop.0"), "14")
                self.assertEqual(loop_cpu(roles["adapter"], "data-loop.0"), "8")
                self.assertEqual(loop_cpu(roles["julia-heart-std-dm-command-adapter"],
                                          "data-loop.0"), "8")
                julia_pins = [item["cpus"] for item in roles["island"]["required_thread_placements"]
                              if item.get("name") == "julia"]
                self.assertEqual(julia_pins, ["4", "6"])

    def test_strict_baseline_emits_housekeeping_parent_and_profile_loop_requests(self) -> None:
        profile = baseline.read_thread_profile(
            BENCHMARK / "profiles/ryzen-6800h-copper-all-loops.json")
        loops = {
            role: baseline.required_data_loop(profile, role, name)
            for role, name in (("daemon", "rtc-data-loop"),
                               ("observer", "data-loop.0"),
                               ("adapter", "data-loop.0"),
                               ("fgn-command-observer", "data-loop.0"),
                               ("julia-heart-std-dm-command-adapter", "data-loop.0"))
        }
        fgn = ["python", "run_fgn_copper_fullframe_live.py", "--rtc-cpus",
               PROCESS_CPUS, "--lab-loop-cpu", str(next(iter(loops["daemon"][0])))]
        fgn.extend(("--lab-loop-rt-priority", str(loops["daemon"][1])))
        jfg_environment = {"JULIA_RTC_OBSERVER_CPUS": baseline.observer_environment(profile)}
        baseline.configure_all_loop_requests(fgn, jfg_environment, loops)
        emitted = baseline.fgn_launch_command(fgn)

        self.assertEqual(emitted[:3], ["taskset", "--cpu-list", "14"])
        self.assertEqual(emitted[3:5], ["python", "run_fgn_copper_fullframe_live.py"])
        self.assertIn(("--observer-loop-cpus", "14"), list(zip(emitted, emitted[1:])))
        self.assertIn(("--adapter-loop-cpus", "8"), list(zip(emitted, emitted[1:])))
        self.assertEqual(jfg_environment["JULIA_RTC_OBSERVER_CPUS"], "14")
        self.assertEqual(jfg_environment["JULIA_RTC_LAB_DAEMON_LOOP_CPU"], "2")
        self.assertEqual(jfg_environment["JULIA_RTC_LAB_OBSERVER_LOOP_CPUS"], "14")
        self.assertEqual(jfg_environment["JULIA_RTC_LAB_ADAPTER_LOOP_CPUS"], "8")

    def test_strict_profile_preflight_rejects_missing_all_loop_flag(self) -> None:
        import argparse

        class CaptureParser(argparse.ArgumentParser):
            def error(self, message: str) -> None:
                raise ValueError(message)

        with self.assertRaisesRegex(ValueError, "requires --configure-all-loops"):
            baseline.require_strict_all_loops(CaptureParser(), Path("profile.json"), False)
        baseline.require_strict_all_loops(argparse.ArgumentParser(), Path("profile.json"), True)
        baseline.require_strict_all_loops(argparse.ArgumentParser(), None, False)

    def test_fgn_parent_accepts_the_profile_observer_envelope(self) -> None:
        self.assertEqual(baseline.fgn_launch_command(["runner"], "10,14"),
                         ["taskset", "--cpu-list", "10,14", "runner"])

    def test_direct_rtc_profiles_match_process_and_thread_roles(self) -> None:
        for name in PROFILE_NAMES[2:]:
            with self.subTest(profile=name):
                roles = read_profile(name)["roles"]
                self.assertEqual(roles["daemon"]["cpus"], PROCESS_CPUS)
                self.assertEqual(roles["daemon"]["required_thread_placements"][0]["cpus"], "2")
                self.assertEqual(roles["rtc"]["cpus"], PROCESS_CPUS)
                self.assertEqual(roles["observer"]["cpus"], "14")
                self.assertEqual(roles["adapter"]["cpus"], "8")
                self.assertEqual(loop_cpu(roles["adapter"], "data-loop.0"), "8")
                self.assertEqual(roles["simulator"]["cpus"], "12")
        julia = read_profile(PROFILE_NAMES[3])["roles"]["island"]
        self.assertEqual(julia["cpus"], PROCESS_CPUS)
        self.assertEqual([item["cpus"] for item in julia["required_thread_placements"]],
                         ["4", "4", "6"])


if __name__ == "__main__":
    unittest.main()
