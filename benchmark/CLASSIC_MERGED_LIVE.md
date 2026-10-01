# Merged Classic live comparison

## Experiment contract, 2026-10-01

Verify the merged FGN/JFG scientific graphs against the unchanged HEART
Classic reference, then measure how much processing is hidden within detector
readout. This is a laboratory comparison using the existing direct launcher;
it does not introduce systemd RTC units.

Scientific revisions at ingress are JFG `4a75677` and FGN `518a578`, with RTC
campaign harness `7e44310`. The JFG/FGN diagnostic-only additions follow the
separated FGN graph and compact JFG completion changes. The native runtime is
the existing `/opt/pipewireao` deployment. HEART remains unchanged.

The fixture and 1,029-frame corpus are the same matched Classic calibration
and seven images repeated 147 times as the numerical comparison. Both graphs
retain gain −0.3, pole/anti-windup gain 0.99 and limits ±0.8 µm. The source is
unchanged `wfsSimulator`, with 32 packets of 11 rows per 352 × 352 frame.

### Ordered phases

1. Three windows per path/rate for HEART, FGN frame and JFG frame at 100 and
   250 Hz, with 2,000 µs nominal readout.
2. Three windows per path/rate for HEART, FGN row and JFG row at those same
   rates/readout. FGN/JFG use zero helpers in this baseline.
3. Adaptive repeated capacity measurements near delivery/deadline failure.
   Retain the fixed-readout series separately; when rate requires a shorter
   readout, record that changed condition explicitly and keep it below the
   frame period. Report finite tested bounds, not an indefinite maximum.
4. Separate bounded diagnostic windows to inspect completed SH/MVM work
   before the terminal packet, callback execution and scheduler delay.
   Instrumented latencies do not replace normal measurements.
5. Run the maintained live property/reconstructor update qualifications
   separately from performance windows. Keep their HIL/build-tree scope
   distinct from the installed matched UDP comparison.

HEART's stdWfs handler remains progressive in every phase. “Frame” describes
the FGN/JFG receiver condition; it does not describe a new HEART handler.

### Placement and qualification

All latency windows request session-owned zero CPU latency through the
existing `rtc` group, record effective readback, and use the existing CPU and
FIFO placement/admission checks. The orchestrator uses housekeeping CPU 14;
replays run sequentially. No cyclictest, global C-state/IRQ tuning or systemd
deployment policy is added.

A comparison window requires exact ordered WFS and DM delivery, selected
source-arithmetic acceptance (plus HEART's exact wire model), matching
clipping decisions, normal child exits, placement and achieved mean source
rate within 1%. Preserve strict 10⁻⁶ diagnostics and rejected windows. Keep
delivery and frame-period deadline acceptance separate.

Measure captured first-WFS-packet → captured DM UDP packet and captured
terminal-WFS-packet → DM. Report all-frame and after-first-100 distributions
separately, retaining per-frame intervals and each window's percentiles rather
than pooling windows. JIT preparation precedes ingress; that alone does not
prove every measured callback is warm. This camera-packet boundary excludes
exposure and physical DM response.

### Evidence

Fresh campaign directories under `/tmp/rtc-classic-merged-*` retain source,
binary/configuration/calibration hashes, requested/effective placement, QoS,
wire captures, per-frame intervals, numerical/clipping checks and failures.
Completed evidence is compressed and retained under `~/.cache/` before
temporary artifacts are removed.

The first seven-frame preflight pointed at the 1,029-frame corpus manifest
and was rejected before ingress with “corpus frame count differs from
manifest”. The failed attempt is retained as a harness input mismatch; it
does not establish an RTC delivery failure. Subsequent windows use the full
matching 1,029-frame corpus.

## Results

The following baseline and capacity checkpoints used the initial placement:
daemon/FGN on CPU 0, JFG on 2, adapter on 4, and HEART's WFS worker on 0.
They remain historical observations. Following the user's correction, the
maintained Classic launcher excludes CPUs 0/1, places daemon/FGN on 2, JFG
on 4, adapter on 8, source on 12 and housekeeping on 14. HEART's workers use
2/4/6/8/8/10; its two short controller stages share core 8. No old window is
relabeled with this new placement or merged into its capacity series.

### Complete-frame receiver baseline

All 18 windows passed exact delivery, selected source-arithmetic acceptance, clipping classification, placement, child exit and frame-period deadline checks: 18,522 DM commands and 592,704 WFS packets. Each window has 1,029 frames; the table reports ranges across three window percentiles after excluding the first 100 only for this steady-state view. All-frame distributions and deadlines are retained in the summary.

| Receiver / graph | Rate (Hz) | Terminal → DM p50 (µs) | p99 (µs) |
| --- | ---: | ---: | ---: |
| fgn-frame | 100 | 252.1–256.3 | 278.3–319.6 |
| heart | 100 | 85.8–86.1 | 99.5–100.9 |
| jfg-frame | 100 | 248.4–254.8 | 281.6–328.7 |
| fgn-frame | 250 | 249.1–252.7 | 262.0–299.4 |
| heart | 250 | 84.3–84.9 | 93.4–98.5 |
| jfg-frame | 250 | 247.8–256.5 | 268.2–280.3 |

HEART processes progressively; FGN/JFG wait for the complete image in this phase. These are whole-receiver comparisons with different execution modes, not language-only algorithm timings. The strict historical 10⁻⁶ diagnostic is preserved separately; selected arithmetic acceptance does not establish application accuracy.

Evidence: `/tmp/rtc-classic-merged-frame1029-20261001/summary.json`, archived with the executed harness and failed preflight at `~/.cache/rtc-classic-merged-live-20261001/frame1029.tar.zst`. Rebuildable per-window Julia compiled caches were removed after completion; configuration, manifests, source provenance, captures and checks remain.

### Row-block receiver baseline

All 18 windows passed the same delivery/science/placement/exit/deadline gates, adding 18,522 commands. The session interruption occurred after fifteen completed windows; three remaining windows were run in a fresh continuation directory with identical recorded source revisions. Original records remain unchanged.

| Receiver / graph | Rate (Hz) | Terminal → DM p50 (µs) | p99 (µs) |
| --- | ---: | ---: | ---: |
| fgn-row | 100 | 66.4–66.6 | 78.5–83.8 |
| heart | 100 | 85.7–86.6 | 103.0–115.3 |
| jfg-row | 100 | 59.7–61.4 | 68.5–80.4 |
| fgn-row | 250 | 66.7–66.9 | 75.0–87.2 |
| heart | 250 | 83.8–85.7 | 97.6–109.5 |
| jfg-row | 250 | 58.9–61.4 | 63.8–70.4 |

These figures use three per-window percentile ranges with 929 retained samples each. All 1,029 frames per window remain in delivery and deadline checks. Smaller terminal latency supports a faster end of frame; it does not quantify hidden SH/MVM work because frame and progressive implementations have different arithmetic/cost. Separate traces establish completion during readout.

Evidence: `/tmp/rtc-classic-merged-row1029-20261001/summary.json`, both manifests and captures archived at `~/.cache/rtc-classic-merged-live-20261001/row1029.tar.zst`. No Julia GC collections were observed in these normal windows; whole connect/run/close allocation counters do not establish callback allocation freedom.

Capacity uses a separate camera schedule: `readout_us = floor(850000 / rate_hz)`. Its rate bounds must not be combined with the fixed 2,000 µs baseline. All five receiver/graph configurations receive the same schedule at each rate.



### Capacity checkpoint: 500 Hz

All fifteen windows delivered 15,435 ordered DM commands with admitted source
pixels/rate, selected science, normal child exits and placement. All five
configurations nevertheless fail the strict repeated all-frame deadline
contract: at least one window per configuration has a frame-zero miss. In the
first repeat, all five misses occur on frame zero only; subsequent frames meet
the 2,000 µs period. Other launches vary. This shared startup pattern is an
observation, not an identified scheduler, frequency, JIT or buffer cause.

Readout is 1,700 µs under the separate 0.85-period camera law. The 500 Hz
windows establish a finite exact-delivery lower bound, not a loss limit or
deadline-clean rate. All-frame and post-first-100 percentiles remain distinct.
Evidence: `~/.cache/rtc-classic-merged-live-20261001/capacity500.tar.zst`.

### Capacity checkpoint: 1,000 Hz

HEART and both complete-frame receivers delivered all 1,029 commands in each
of three windows. Both progressive PipeWire receivers lost whole frames in
all three windows. Their source received every valid WFS datagram with no
rejected packets; frame admission failed when fewer than 32 loanable buffers
were available. The first FGN window delivered 799 frames and recorded 230
reservation starvations; JFG delivered 818 and recorded 211. The actual
negotiated pool in subsequent instrumented windows was 64 buffers.

Exact delivery and deadlines differ: both full-frame receivers missed every
1 ms deadline, despite eventually delivering every command. HEART had a small
number of deadline misses. Readout is 850 µs under the separate capacity camera
law. These finite windows establish delivery bounds, not an operating rate.
Missing numerical reports after physical delivery failure remain missing.
Evidence: `~/.cache/rtc-classic-merged-live-20261001/capacity1000.tar.zst`.

### Work completed during readout

A separate 252-frame, 250 Hz, 2,000 µs diagnostic passed wire, selected science,
placement and exit checks for HEART, FGN row and JFG row. FGN/JFG scheduler
traces and callback completeness also qualified. Instrumented latency is not
substituted for the ordinary baseline above.

| Path | Completed SH subapertures before terminal | Completed MVM input pairs before terminal |
| --- | ---: | ---: |
| HEART | 184 / 188 in all 252 frames | at least 176 / 188 in all 252 frames |
| FGN row | at least 184 / 188 in all 252 frames | at least 184 / 188 in all 252 frames |
| JFG row | at least 184 / 188 in 251 frames; 166 in frame zero | same counts as SH |

FGN/JFG bounds follow synchronous callback completion, the reviewed ROI order,
and the endpoint realtime/monotonic clock envelope. With a further 10 µs clock
margin, FGN counts remain unchanged; JFG frame 171 drops from 184 to 176
subapertures/pairs. JFG's overall range remains 166–184. HEART uses its native receive timestamp
immediately after terminal `daoUdp_recv`, rather than the captured packet
timestamp; its MVM has 277 padded rows versus 221 controlled coordinates in
FGN/JFG. Counts demonstrate useful computation during readout, without
constituting equal instruction costs or physical camera timing.

Raw traces, SHA-attested analyses and the independent handoff analysis are
archived at `~/.cache/rtc-classic-merged-live-20261001/diagnostics.tar.zst`.
All 8,064 JFG callback bodies showed zero increments in the recorded Julia
allocation-byte, GC-pause and GC-time counters; those counters also remained
unchanged from the first body start through the final body end. This measures
the traced graph-body/process-counter boundary, excluding startup, initial
property adoption and native allocations. The whole connect/run/close scope
allocated 4,671,120 bytes with zero collections. The separately produced
`jfg-gc-body-summary.json` retains both scopes and trace/report hashes.
See [the handoff review](CLASSIC_ROW_HANDOFF_REVIEW.md) for the observed empty
downstream activations and ownership constraints. A separate adapter CPU
placement experiment retains the developed graphs and transport contracts;
sharing a CPU does not make separate processes share a PipeWire data-loop.

### Adapter placement experiment

Moving the adapter onto the graph CPU did not establish loss-free 1,000 Hz
operation. All three FGN windows and all three JFG windows still dropped
whole frames; FGN's first two windows delivered 673 and 666 of 1,029 commands,
compared with 799 in the first original separate-core window. JFG's first two
delivered 792 and 777. These are separate layout conditions, not a pooled
capacity series. The maintained layout keeps the adapter on a distinct core.
No scientific algorithm or source-buffer ownership contract was changed.

The old-layout 2,000 Hz campaign was interrupted after the CPU 0 correction.
Two completed failed windows remain, alongside explicit interruption metadata;
they do not satisfy the three-window capacity contract. The next receiver was
terminated during preparation. No further CPU 0 replay was launched.

### Corrected placement: 250 Hz baseline

A fresh fixed-condition series used the maintained CPU0/1-free layout above:
three 1,029-frame windows for each of the five paths, 2,000 µs nominal readout,
zero FGN/JFG helpers, and session-owned zero CPU latency. All 474 recorded
before/after RTC thread-affinity entries exclude CPUs 0 and 1. This is owned
thread placement, not operating-system core isolation.

All twelve FGN/JFG windows passed exact ordered delivery, selected science,
clipping classification, placement, normal exit and all-frame 4 ms deadlines.
HEART passed two windows; its first failed ordered delivery with 1,028 commands,
repeated frame ID 19, and absent IDs 20, 21 and 1,029. The failure remains in
the series and prevents a three-window HEART delivery qualification.

| Path | Qualified windows | Terminal → DM p50 (µs) | p99 (µs) |
| --- | ---: | ---: | ---: |
| HEART | 2 / 3 | 85.4–85.8 | 95.1–105.7 |
| FGN frame | 3 / 3 | 252.4–253.1 | 272.6–293.2 |
| JFG frame | 3 / 3 | 248.2–265.6 | 272.2–325.6 |
| FGN row | 3 / 3 | 67.0–67.6 | 75.5–78.5 |
| JFG row | 3 / 3 | 59.1–59.4 | 67.7–69.5 |

These are ranges of qualified-window percentiles after the first 100 frames;
delivery and deadline gates use every frame. HEART's two-window conditional
range does not hide or replace its failed window. These figures must not be
pooled with the historical CPU0 layout or its capacity observations.

HEART's first concrete in-window error is in its WFS handler: duplicate packet
sequence 5, then circular-buffer discontinuity and invalid downstream data.
The capture contains all 32,928 valid offered packets with matching FITS pixels.
Capture completeness does not establish successful socket receipt. The receive
buffer was truncated from 262,144 to 212,992 bytes, but no socket-drop counter
establishes overflow. Neither buffer overflow nor CPU8 controller sharing is
a confirmed cause. The independent review retains the error chain and the
next discriminating measurements.

The [compact evidence](data/classic_cpu0_free_baseline_20261001.json) retains
source/harness hashes, placement hashes, per-window gates and strict numerical
diagnostics. Raw evidence and the executed harness are archived separately
under `~/.cache/rtc-classic-merged-live-20261001/cpu0-free-baseline250.tar.zst`.
The compact record includes its archive SHA-256. The remaining 750 Hz,
interrupted 2,000 Hz and adapter-placement captures, recovered executed sources,
late diagnostic sidecars and resolved live-update child logs are retained in
`final-historical-sidecars.tar.zst` in the same directory. Live UNIX sockets
are excluded by tar; they are process endpoints, not retained test evidence.

### Live properties and reconstructor replacement

The maintained `live_private_core` integration test with
`PIPEWIREAO_RTC_LIVE_SCOPE=revolt` passed against the current FGN/JFG sources.
Both providers delivered all ten simulated commands, exercised gain/pole
updates while running, adopted the replacement reconstructor at sequence 8,
recovered from the invalid initial shape, and passed restart, source-end,
ownership and cleanup assertions. The producer deliberately waits for each
command. This establishes software adoption/recovery under the maintained
closed-loop HIL test, not paced UDP handoff latency or update deadlines.

The test uses 277 controller coordinates and the build-tree daemon; the
matched UDP fixture above uses 221 controlled coordinates and `/opt/pipewireao`.
The retained test log is `/tmp/rtc-classic-merged-live-update-20261001.log`;
graphs and child logs are retained via
`/tmp/rtc-classic-merged-live-update-20261001/private-core`. Its existing
retention environment variable contains `LATEST_HOLD` in its name, but the
selected executable scope was exclusively `revolt`.

The Cargo build succeeded with an existing future-incompatibility warning for
transitive `proc-macro-error2` 2.0.1. This is retained with the toolchain report;
no dependency upgrade or future-compiler compatibility claim is made.
