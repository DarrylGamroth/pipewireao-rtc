# Copper first-frame packet timing

[`copper_frame_phases_20260929.json`](data/copper_frame_phases_20260929.json)
recomputes per-frame packet intervals from four previously qualified Copper
manifests: the three-repeat row-block and complete-frame replays from
2026-09-28 and the single strict-placement replay of each mode from
2026-09-29. The report retains each manifest and packet-TSV SHA-256. The
command below regenerates it from those raw captures:

```sh
python3 benchmark/report_copper_phases.py \
  ~/.cache/rtc-deployment-installed-row-placement-3x-20260928/manifest.json \
  ~/.cache/rtc-deployment-installed-fullframe-placement-3x-20260928/manifest.json \
  ~/.cache/rtc-dev-019-strict-row-1024-20260929/manifest.json \
  ~/.cache/rtc-dev-019-strict-fullframe-1024-20260929/manifest.json \
  --output benchmark/data/copper_frame_phases_20260929.json
```

The extractor accepts only a qualified manifest. It requalifies the current
WFS and DM captures against the FITS image and Standard-DM packet contract,
checks frame IDs and packet sequence in capture order, then pairs the two WFS
timestamps and one DM timestamp for every frame. It rejects missing or
time-regressing packets and checks its all-frame count, min, p50, p99, and max
against the original qualifier within 1 µs for each timing statistic. The JSON
records hashes of the current captures, manifests, and requalification scripts.
The older manifests did not record capture hashes at qualification time, so
this cannot prove the packet files are byte-for-byte unchanged since those
original runs. Frame 1 is reported
separately from frames 2–10 and frames 101–1024. Times below are
**terminal WFS packet → DM packet**, in microseconds. Each range spans three
independent runs and is not a pooled percentile.

All 24 present owner captures across the eight retained runs passed the current
FITS-payload and Standard-DM requalification before the phase report was
written.

| Ingress | RTC | Frame 1 | Frames 101–1024 p50 |
| --- | --- | ---: | ---: |
| Row blocks | HEART | 782–913 | 184–206 |
| Row blocks | FGN | 173–214 | 181–186 |
| Row blocks | JFG | 476–699 | 131–184 |
| Complete frame | HEART | 1,710–1,757 | 312–341 |
| Complete frame | FGN | 509–760 | 215–267 |
| Complete frame | JFG | 593–713 | 155–202 |

The later strict-placement single runs showed the same broad first-frame
pattern: row-block frame 1 was 780 µs HEART, 186 µs FGN, and 550 µs JFG;
complete-frame frame 1 was 1,668 µs HEART, 494 µs FGN, and 624 µs JFG.
The JSON includes first-packet → DM, readout interval, and all-frame
distributions for every run.

**Interpretation.** These are first *transported* frame observations, not a
measurement of Julia compilation or one algorithm's first call. JFG used
`--graph-warmup offline` in all four manifests, and the 2026-09-28 runs had
CPU-saturating background Julia processes and different observed scheduling
policies. The current host remains similarly loaded. The first-frame excess
may include graph activation, demand scheduling, memory faults, and packet
transport. The retained data cannot assign it to one mechanism or support an
uncontended cross-RTC latency ranking. The orchestrator now records these
phase summaries on future qualified runs and accepts
`--jfg-graph-warmup none` for a separate cold-graph experiment.
