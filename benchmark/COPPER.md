# Copper post-install baseline

`run_copper_baseline.py` runs the existing HEART, FGN, and JFG Copper runners
serially for either row-block or full-frame ingress. It does not create graph
configuration or schedule graph work.

The selected workload is the shared Copper FITS cube with SHA-256
`880e46b8e45c848a8c2df74e5591731ea161ac7009a02ad29e2fc79f6fd06abf`,
474 Hz, 2,000 µs readout, two 32-row WFS datagrams per frame, 1,024 frames,
clipping feedback, and a ±0.8 µm command limit. Use three independent replays
for a comparison; the one-replay default is for diagnosis.

```sh
python3 benchmark/run_copper_baseline.py \
  --mode row --repeats 3 --verify-placement \
  --output-dir /path/to/new/copper-baseline
```

`--frames N` permits a finite diagnostic replay from 1 through 1,024 frames.
`--mode fullframe` selects the sibling full-frame runners. The output
directory must not already exist.

Each run is fail-closed. HEART must qualify its WFS and Standard-DM capture;
FGN and JFG must report their own exact delivery qualifications; every replay
must contain two WFS packets and one ordered DM vector per requested frame.
The orchestrator uses JFG's `compare_command_vectors.py` helper to compare
HEART→JFG and FGN→JFG vectors by frame identity. It accepts a maximum
absolute difference of at most 1 × 10⁻⁶ µm for every requested frame.

Before creating an output directory, the runner checks the requested CPU set
against its available CPUs and probes that the selected simulator can start
at the requested SCHED_FIFO priority. `--verify-placement` makes each runner
capture live process and thread state before ingress and after replay. The
baseline requires every declared role report to say `verified` before it
qualifies latency. These are broad process-envelope checks: the current
profile has no required RT-thread counts or owner-supplied proof of every
worker pin. They do not yet satisfy the full RTC-DEV-019 placement contract.

`manifest.json` retains each command and working directory, runner logs,
source revisions and working-tree patches, hashes of selected scripts,
binaries, calibration files, and FITS data, qualification and vector
comparison records, and every output path. Small untracked source files are
copied into `source-state`. It emits latency summaries only after exact
delivery, numerical parity, and selected placement checks pass. The capture
boundaries are software WFS packet ingress and Standard-DM packet egress;
they do not establish a physical camera-to-DM or real-time claim.

JFG and FGN both use `/opt/pipewireao` and the installed HEART plugin. The
orchestrator checks the FGN daemon and ndarray module hashes against that
prefix before reporting latency. HEART runs its own native controller, using
the same selected wfsSimulator executable.

## Retained 2026-09-28 replays

The two manifests are
`~/.cache/rtc-deployment-installed-row-placement-3x-20260928/manifest.json`
and
`~/.cache/rtc-deployment-installed-fullframe-placement-3x-20260928/manifest.json`.
Both report three qualified 1,024-frame runs per RTC using the installed
PipeWireAO daemon and ndarray module. Every run captured 2,048 WFS packets and
1,024 ordered Standard-DM commands. Within each mode, the largest HEART↔JFG
vector difference was 4.564 × 10⁻⁸ µm; FGN↔JFG was at most 2.981 × 10⁻⁸ µm.
Comparing row and full-frame command arrays within each RTC gave zero
difference for HEART and at most 2.981 × 10⁻⁸ µm for FGN and JFG.

Each range is the minimum and maximum of the three **per-run** percentiles;
the runs were not pooled. Times are microseconds.

| Ingress | RTC | First packet → DM p50 | Terminal packet → DM p50 | Terminal packet → DM p99 |
| --- | --- | ---: | ---: | ---: |
| Row blocks | HEART | 1,183–1,200 | 186–205 | 278–292 |
| Row blocks | FGN | 1,175–1,182 | 180–187 | 329–339 |
| Row blocks | JFG | 1,131–1,181 | 130–184 | 308–356 |
| Full frame | HEART | 1,318–1,342 | 319–342 | 534–556 |
| Full frame | FGN | 1,203–1,263 | 205–267 | 390–497 |
| Full frame | JFG | 1,154–1,201 | 155–202 | 411–446 |

The configured 2,000 µs readout produces two 32-row WFS packets separated by
about 996 µs at the capture boundary (row run 1 median). The observed
row-block p99 improvement in each implementation is consistent with useful
work overlapping that packet interval. The p50 benefit is smaller for FGN and
mixed for JFG. These runs do not isolate which operation executes during
readout.

The observed scheduling policies differ. HEART has many FIFO5/10/15/20
threads; the FGN daemon data loop is `SCHED_OTHER`; the JFG island data loop
is FIFO83. The sampled HEART process showed 120,832 KiB of explicit huge
pages; the sampled FGN daemon and JFG island showed none. Three unrelated VS
Code Julia analysis processes were observed using full CPU cores during the
series (the ambient snapshots are retained beside the manifests). Fixed
HEART→FGN→JFG run order and this host activity prevent a clean cross-RTC
latency ranking. The exact delivery and numerical comparisons remain valid.

The retained series used the then-current dirty source trees, recorded by
revision and dirty filenames. The runner now archives working-tree patches
and small untracked source files for future replays. Its first-use startup
distribution and strict RTC-DEV-019 thread-placement proof remain to be
measured.
