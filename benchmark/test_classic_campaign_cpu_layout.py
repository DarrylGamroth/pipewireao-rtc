"""CPU-zero reservation and Classic worker placement contract."""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_classic_campaign import command


ROOT = Path(__file__).resolve().parents[1]
RESERVED = {0, 1}


def option(argv: list[str], name: str) -> str:
    return argv[argv.index(name) + 1]


class ClassicCampaignCpuLayoutTests(unittest.TestCase):
    def test_standard_commands_reserve_cpus_zero_and_one(self) -> None:
        expected_rtc = "2,4,6,8,10,14"
        for path in ("fgn-frame", "jfg-frame", "fgn-row", "jfg-row"):
            with self.subTest(path=path):
                argv = command(path, Path("/corpus"), Path("/run"), 250, 2000, 63)
                self.assertEqual(option(argv, "--rtc-cpus"), expected_rtc)
                self.assertEqual(option(argv, "--source-cpus"), "12")
                self.assertEqual(option(argv, "--lab-loop-cpu"), "2")
                self.assertEqual(option(argv, "--adapter-loop-cpu"), "8")
                self.assertTrue(RESERVED.isdisjoint(map(int, expected_rtc.split(","))))

    def test_julia_node_and_worker_affinities_follow_layout(self) -> None:
        for workers, expected in ((0, "4,14"), (2, "4,14,6,10")):
            argv = command("jfg-row", Path("/corpus"), Path("/run"),
                           250, 2000, 63, workers=workers)
            self.assertEqual(option(argv, "--node-loop-cpu"), "4")
            pins = option(argv, "--julia-pin-cpus")
            self.assertEqual(pins, expected)
            self.assertTrue(RESERVED.isdisjoint(map(int, pins.split(","))))
            self.assertNotIn(8, map(int, pins.split(",")))
            self.assertEqual(option(argv, "--row-workers"), str(workers))

    def test_heart_workers_and_auxiliary_roles_exclude_reserved_cpus(self) -> None:
        argv = command("heart", Path("/corpus"), Path("/run"), 250, 2000, 63)
        self.assertEqual(option(argv, "--rtc-cpus"), "2,4,6,8,10,14")
        self.assertEqual(option(argv, "--source-cpus"), "12")
        profile = Path(option(argv, "--cpu-map"))
        self.assertEqual(profile, ROOT / "benchmark/profiles/ryzen-6800h-classic.cpu")
        text = profile.read_text()
        entries = {key: value.strip() for key, value in
                   re.findall(r"^([\w.]+)\s*=\s*\{\s*([^}]+)\s*\}$", text, re.M)}
        worker_keys = ("HOP0.wfs.w", "HOP0.proc.w", "HOP0.recon.w",
                       "WCC.tfc.w", "WCC.clwc.w", "WCC.dm0.w")
        worker_cpus = {int(entries[key]) for key in worker_keys}
        self.assertEqual(worker_cpus, {2, 4, 6, 8, 10})
        self.assertTrue(RESERVED.isdisjoint(worker_cpus))
        self.assertEqual(entries["HOP0.wfs.pxStat"], "14")
        self.assertEqual(entries["HOP0.proc.gOpt"], "14")
        self.assertEqual(entries["WCC.clwc.pdm0"], "14")
        self.assertEqual(entries["WCC.tfc.w"], entries["WCC.clwc.w"])
        self.assertIn("TFC and CLWC", text)


if __name__ == "__main__":
    unittest.main()
