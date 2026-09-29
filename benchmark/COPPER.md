# Copper post-install baseline

## RTC development configuration

The RTC has maintained complete-frame fixtures for
[`REVOLT Classic (native FGN)`](../fixtures/revolt-classic-native-development.conf),
[`REVOLT Classic (Julia)`](../fixtures/revolt-classic-julia-development.conf),
[`REVOLT Copper (native FGN)`](../fixtures/revolt-copper-native-development.conf),
and [`REVOLT Copper (JuliaFilterGraph)`](../fixtures/revolt-copper-julia-development.conf).
The Copper fixtures use the existing HEART WFS source and demanded-command
observer from the matched comparison at 474 Hz. The graph input is a 64 × 64
U16 detector image; the observed 277-element Float32 command is in
micrometres. The observer is non-actuating. Optional Standard-DM conversion
and wire capture are attached by the companion launcher after the RTC reaches
`RUNNING`; these measurement links are outside RTC configuration and ownership.

The managed JuliaFilterGraph island prepares the calibration matched to this
Copper workload, publishes the graph at the selected rate, and enables RTC
session run control. `run_copper_rtc.py --controller julia` launches it before the RTC,
uses the same HEART WFS and observer, and checks ordered delivery and optional
command-vector equivalence. It maps Julia's PipeWireAO JLL to the selected
PipeWireAO installation and uses one OpenBLAS thread by default, as the
matched Julia Copper runner does. `--julia-blas-threads` permits a recorded
diagnostic comparison. The runner's Julia path requires the managed provider
in the JuliaFilterGraph sibling repository.

For numerical equivalence, `--equivalence-observations` exposes mean pupil
intensity, controller correction, controller state, and PDM constraint feedback
from either graph. The runner links four additional non-actuating observers,
replays the same FITS frames, and compares those four outputs and the demanded
command with the direct Calculon complete-frame oracle. It also runs the
oracle's independent controller-recurrence, reset, clipping, and feedback
checks. These diagnostic links and observers change graph scheduling and are
for numerical validation, not latency measurement. Use a fresh output path:

```sh
python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/native-equivalence \
  --controller native --frames 16 --command-limit-um 0.2 \
  --equivalence-observations \
  --direct-oracle-bin /path/to/revolt_copper_fullframe_oracle

python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/julia-equivalence \
  --controller julia --frames 16 --command-limit-um 0.2 \
  --equivalence-observations \
  --direct-oracle-bin /path/to/revolt_copper_fullframe_oracle
```

At 474 Hz on 2026-09-29, both 16-frame clipped runs delivered every ordered
command with zero WFS drops, buffer starvations, or simulator overruns. All 16
frames had clipped actuators. Native matched the direct oracle exactly at all
five observed boundaries. Julia's largest differences were 0 for mean,
6.855 × 10⁻⁷ for correction, 7.153 × 10⁻⁷ for controller state,
2.981 × 10⁻⁸ µm for constraint feedback, and 1.491 × 10⁻⁸ µm for demanded
command. The checker reported zero recurrence, clipping, and feedback error
in the direct path. Raw reports are
`~/.cache/rtc-copper-native-direct-oracle-checker-clip-16-20260929/report.json`
and
`~/.cache/rtc-copper-julia-direct-oracle-checker-clip-16-20260929/report.json`.
The RTC worktree was replayed again after the latest/hold changes, using the
same commands above. The native and Julia reports are
`~/.cache/rtc-copper-rtc-final-native-16-20260929/report.json` and
`~/.cache/rtc-copper-rtc-final-julia-16-20260929/report.json`. Both passed
16/16 ordered commands, direct-oracle comparison, and zero WFS frame drops,
buffer starvations, and simulator timer overruns. The native differences were
zero at all five observed boundaries; the Julia differences matched the
earlier tolerances above.
The direct path calls the maintained Calculon algorithms with the same
prepared matrices, so this establishes execution-path equivalence for this
input and configuration, not independent scientific validation of those
algorithms.

The same fixtures also exercise source completion, reset, atomic controller
property replacement, and reconstructor replacement. `--control-cycle`
replays four measured frames, submits a half-scale reconstructor and the
gain/pole/anti-windup transaction, then sends eight conditioning frames at
10 Hz. It requires the host's requested and active reconstructor sequences
to agree before a second reset and the final four measured frames at 474 Hz.
All 16 offered frames and commands must arrive in order; the conditioning
commands are retained in the raw files and excluded only from the direct
before/after numerical comparison. This conditioning phase is necessary
because a parameter submission does not establish its adoption boundary.

```sh
python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/native-control-cycle \
  --controller native --frames 8 --command-limit-um 0.2 \
  --equivalence-observations --control-cycle \
  --direct-oracle-bin /path/to/revolt_copper_fullframe_oracle

python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/julia-control-cycle \
  --controller julia --frames 8 --command-limit-um 0.2 \
  --equivalence-observations --control-cycle \
  --direct-oracle-bin /path/to/revolt_copper_fullframe_oracle
```

The 2026-09-29 runs delivered 16/16 commands through each controller, with
zero WFS drops, buffer starvations, or simulator overruns. Native adopted
reconstructor sequence 3 and matched the direct Algorithm bitwise at all five
observed boundaries. Julia adopted sequence 2; its largest correction and
state differences were 1.490 × 10⁻⁷ and 1.565 × 10⁻⁷. The reports are
`~/.cache/rtc-copper-control-cycle-native-8-verified-20260929/report.json` and
`~/.cache/rtc-copper-control-cycle-julia-8-verified-20260929/report.json`.
Julia used the focused GC-safe `pw_ndarray_filter_run` change in
`PipeWireAO.jl`. Without it, the Julia parameter worker stalled in GC and
only the first conditioning command arrived; a captured thread stack is in
`~/.cache/rtc-copper-control-cycle-julia-8-stack-20260929/julia-gdb-stacks.txt`.
The explicit RTC parameter-source trigger on session start is also required:
without it, the replacement did not reach JuliaFilterGraph during conditioning.
These are functional development replays, not latency benchmarks.

The RTC runner also accepts an opt-in per-role placement contract. The
[native](profiles/ryzen-6800h-rtc-copper-native.json) and
[Julia](profiles/ryzen-6800h-rtc-copper-julia.json) examples describe this
workstation's CPU set, expected thread counts, FIFO83 data loop, and FIFO20
pixel sender. They are separate because the RTC has one additional parameter
thread when it owns the native graph. Before starting the sender, the runner
checks that every requested CPU and scheduler policy is available, generates
an explicit eventfd/FIFO83/CPU 0 daemon data loop with
`mem.mlock-all=false`, and verifies each live daemon, observer, RTC, and
optional Julia-island and Standard-DM-adapter thread against the selected
profile. It verifies them
again after replay. The Julia owner receives `JULIA_RTC_PIN_CPUS` through its
maintained ThreadPinning interface. A changed or unavailable thread layout
fails the run; the JSON records name the failed process and thread.
Each placement record also retains `VmLck`, `/proc/PID/smaps_rollup`, and a
read-only `/proc/PID/smaps` summary of resident memory by reported kernel
page size and huge-page category. A strict run fails before ingress if the
page-backing record is unavailable. The mapping page-size total is an
observation of the kernel's VMA report; `AnonHugePages` and hugetlb fields
are kept separately because a VMA page-size label alone does not establish
the exact backing of every resident page.
One 16-frame strict wire replay per controller passed from clean launcher
revision `1623a2b` on 2026-09-29. Both before-ingress and after-replay
snapshots were complete for every inspected process. The raw reports are
`~/.cache/rtc-copper-native-pagebacking-final-16-20260929/report.json` and
`~/.cache/rtc-copper-julia-pagebacking-final-16-20260929/report.json`.
These short runs validate the recording path, not the memory behavior of a
long replay.

```sh
python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/native-strict \
  --controller native --frames 1024 \
  --placement-profile benchmark/profiles/ryzen-6800h-rtc-copper-native.json \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32

python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/julia-strict \
  --controller julia --frames 1024 \
  --placement-profile benchmark/profiles/ryzen-6800h-rtc-copper-julia.json \
  --julia-pin-cpus 0,2 \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32
```

These host-specific profiles are an optional development experiment. The
pixel sender's launch policy is preflighted, but its own threads cannot yet
be inspected before it starts sending. The RTC fixture owns only the path to
the non-actuating demanded-command observer. `--wire-capture` adds a second,
companion-owned demanded-command link to the maintained Standard-DM adapter
and then to the HEART Standard-DM sink. The runner removes both links before
RTC unload. This keeps the fixture's declared rate contract intact while
providing packet-level egress evidence.

```sh
python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/native-wire \
  --controller native --frames 1024 --wire-capture \
  --placement-profile benchmark/profiles/ryzen-6800h-rtc-copper-native.json \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32

python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/julia-wire \
  --controller julia --frames 1024 --wire-capture \
  --placement-profile benchmark/profiles/ryzen-6800h-rtc-copper-julia.json \
  --julia-pin-cpus 0,2 \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32
```

Wire qualification requires the expected WFS and Standard-DM packet counts,
ordered identities, matching FITS payload and command vectors, no WFS drops
or simulator overruns, and the same numerical-reference check as the demanded
observer. The report retains the capture, decoded vectors, physical packet
summary, source revisions, selected artifact and calibration hashes, placement
records, and startup and replay intervals. Its latency distributions run from
the first or terminal WFS UDP packet to Standard-DM UDP egress. These are
software packet boundaries, not a physical camera or DM measurement.

One 1,024-frame wire run per controller passed at 474 Hz on 2026-09-29.
The native run had first-packet → DM p50/p99 of 1,164/1,402 µs and
terminal-packet → DM p50/p99 of 166/403 µs. The Julia run had
1,169/1,501 µs and 171/504 µs respectively. Each delivered 1,024 ordered
commands, had zero source drops, buffer starvations, and simulator overruns,
and matched Standard-DM wire vectors to demanded vectors within
1.491 × 10⁻⁸ µm. Raw reports are
`~/.cache/rtc-copper-native-wire-1024-20260929/report.json` and
`~/.cache/rtc-copper-julia-wire-1024-20260929/report.json`.
These individual runs show that both managed paths reach the wire boundary;
three independent qualified runs per controller are still needed for a
comparative latency claim.

A second 1,024-frame replay of each controller used committed launcher
revision `b799f74` with a clean RTC worktree and the finite, nonnegative
latency check enabled. Both again passed exact delivery, offered schedule,
reference vectors, wire-vector agreement, before/after placement, and clean
unload. Native first-packet → DM p50/p99 was 1,150/1,355 µs and terminal
p50/p99 was 153/358 µs. Julia first-packet p50/p99 was 1,152/1,275 µs and
terminal p50/p99 was 152/279 µs. The raw reports are
`~/.cache/rtc-copper-native-wire-committed-1024-20260929/report.json` and
`~/.cache/rtc-copper-julia-wire-committed-1024-20260929/report.json`.
Ambient load was not controlled across the four runs, so these values do not
establish a comparative ranking.

Three further independent 1,024-frame managed replays per controller passed
the strict placement, page-backing, numerical, ordered-delivery, schedule,
and Standard-DM wire checks at 474 Hz. Runs alternated native and Julia. The
table shows each run's percentile in sequence; times are microseconds and
are not pooled.

| Controller | First WFS packet → DM p50 | First packet p99 | Terminal packet → DM p50 | Terminal packet p99 |
| --- | --- | --- | --- | --- |
| Native FGN | 1,239 / 1,149 / 1,236 | 1,377 / 1,287 / 1,371 | 241 / 152 / 236 | 376 / 289 / 373 |
| JuliaFilterGraph | 1,156 / 1,132 / 1,139 | 1,265 / 1,407 / 1,226 | 159 / 135 / 140 | 270 / 410 / 227 |

Every run produced 1,024 ordered observer and Standard-DM commands with zero
WFS drops, buffer starvations, and simulator timer overruns. Native commands
matched the saved FGN vectors exactly; Julia's maximum difference was
2.981 × 10⁻⁸ µm. Wire vectors differed from observer demands by at most
1.491 × 10⁻⁸ µm. The six raw reports and summary are under
`~/.cache/rtc-managed-copper-wire-series-20260929/`. The recorded RTC
source revision is `24d24f4`; its sole untracked path during these runs was
generated `benchmark/__pycache__/` bytecode, now ignored by Git. The
cross-run spread remains substantial, and competing host load was not
controlled or sampled throughout the runs. This is repeatability evidence for
the managed complete-frame paths, not a defensible native-versus-Julia ranking.

One 1,024-frame replay per controller passed this profile at 474 Hz on
2026-09-29. Both produced 1,024 contiguous demanded commands with zero WFS
drops, buffer starvations, or simulator timer overruns. The native vectors
matched the saved FGN vectors exactly; Julia's maximum absolute difference
was 2.9802322387695312 × 10⁻⁸ µm. Every declared live role passed its
before-ingress and after-replay thread check. The raw reports are
`~/.cache/rtc-copper-native-strict-1024-20260929/report.json` and
`~/.cache/rtc-copper-julia-strict-1024-20260929/report.json`. An earlier
native attempt with an incomplete RTC thread contract failed before image
ingress and named its unexpected FIFO83 thread. These replays validate the
placement gate on this host; they are not a three-repeat latency comparison.

Render the Copper graph and its startup calibration parameters from the
maintained FGN generator and the same HEART configuration used by the
comparison:

```sh
python3 benchmark/render_revolt_copper_graph.py \
  --algorithms-root ../calculon-algorithms-main-copper \
  --heart-config ../../heart/revolt-rtc/config \
  --fgn-bundle ../calculon-algorithms-copper-fullframe/target/release/libcalculon_fgn_bundle.so \
  --clipping-feedback \
  --output-dir /path/to/copper-rtc-artifacts
```

The script prints `PIPEWIREAO_RTC_GRAPH_COPPER_NATIVE` for the RTC fixture.
It writes the module arguments, four prepared F32 calibration payloads (eight
when `--clipping-feedback` is selected), and a
parameter manifest under `--output-dir`. Keep that directory available for the
whole session: the FGN host maps the calibration files during graph creation.
The selected fixture rate, generated graph rate, and external WFS source rate
must agree. The external source and observer must be running on the selected
private PipeWire core before loading the RTC fixture. The RTC owns the FGN
graph and its two links; it does not create those external endpoints.

`run_copper_rtc.py` starts those external endpoints on a private core, loads
and controls the graph and links through `pipewireao-rtc`, replays the common
FITS cube with `wfsSimulator`, and requires one contiguous demanded command per
frame. An optional reference file checks every command value:

```sh
python3 benchmark/run_copper_rtc.py \
  --output-dir /path/to/new/copper-rtc-replay \
  --frames 1024 \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32
```

To run the Julia graph through the same RTC lifecycle and input source:

```sh
python3 benchmark/run_copper_rtc.py \
  --controller julia \
  --jfg-root ../JuliaFilterGraph.jl \
  --output-dir /path/to/new/copper-julia-rtc-replay \
  --frames 1024 \
  --reference-vectors /path/to/matched/fgn/demanded-um.f32
```

Both modes load a complete-frame graph and observe demanded commands before
Standard-DM conversion. `--reference-vectors` compares every Float32 command
with the first requested frames of the saved native replay at a maximum
absolute difference of 1 × 10⁻⁶ µm. The output report also requires two WFS
datagrams and one ordered command per frame, with no WFS drops or buffer
starvation. A 16-frame replay on 2026-09-29 qualified in each mode against
the same saved native vectors: native maximum difference 0 and Julia maximum
difference 2.9802322387695312 × 10⁻⁸ µm. These short runs establish the RTC
configuration and numerical boundary; they do not establish loss-free
operation at a sustained offered load or camera-to-DM latency.

`--rate-hz` selects the offered rate and updates the fixture, source, observer,
graph, and simulator together. Its admitted range is 1–474 Hz: HEART's
`wfsSimulator` requires its 2 ms readout to be less than 95% of the frame
period, which excludes 475 Hz and above. The report records the rate,
WFS counters, Julia callback count when applicable, command identities,
numerical-comparison status, pre-ingress and post-replay process placement,
and post-unload link count. It distinguishes delivery from the simulator's
offered-schedule check; `qualified` requires both, plus any requested vector
comparison. A failed delivery check leaves numerical comparison unevaluated.
An attempted 500 Hz replay exited before ingress at that `wfsSimulator`
validation check; it says nothing about the controller's independent capacity.

The initial managed Julia runs inherited Julia's eight OpenBLAS threads.
At 474 Hz, one uninstrumented 1,024-frame replay published all WFS frames and
invoked all Julia callbacks, but the observer received 1,022 commands. At
100 Hz, another replay invoked all callbacks but missed one observer command.
An aligned PipeWireAO trace at 100 Hz localized four further missed commands:
callbacks for frames 769, 841, 930, and 1006 took 10–32 ms, each produced an
output, and the next frame completed roughly 0.1–0.2 ms later. The observer
received the newer frame but not the delayed one; frames 931 and 932 also
failed to enter Julia during the longest stall. The trace is retained under
`~/.cache/rtc-copper-tracehooks-aligned-100hz-1024-20260929/`.

With one OpenBLAS thread, four independent 1,024-frame managed Julia replays
at 474 Hz through the selected PipeWireAO installation delivered all commands
and matched the saved FGN vectors within 2.981 × 10⁻⁸ µm. Three further
one-thread replays with the prior Julia JLL also passed. An eight-thread replay
with the aligned library missed 15 observer commands and eight Julia inputs.
The repeated A/B result implicates BLAS thread count on this loaded host;
the exact source of the long callback stalls still needs a scheduler or
thread-level profile. The four aligned passing reports are retained under
`~/.cache/rtc-copper-julia-aligned-blas1-474hz-1024-{a,b,c,d}-20260929/`.
One native 1,024-frame replay passed the new delivery, schedule, and vector
checks under `~/.cache/rtc-copper-native-schedule-474hz-1024-a-20260929/`.
These are complete-frame demanded-command observations, not
pixel-ingress-to-Standard-DM-egress latency or a general maximum-rate claim.

The retained run at
`~/.cache/rtc-copper-managed-1024-20260929/report.json` delivered 1,024
contiguous commands at 474 Hz, matched the saved full-frame FGN commanded
vectors exactly (`max_reference_difference_um = 0.0`), and stopped and unloaded
the RTC cleanly. This verifies RTC-managed graph loading, startup parameters,
links, and the demanded-command data boundary. That earlier invocation did
not select the later `--wire-capture` path; the three-way comparison below
retains its own complete-path measurements.

A later uninstrumented 1,024-frame replay at
`~/.cache/rtc-copper-managed-main-a4ed874-20260929/` missed demanded-command
sequences 539, 546, and 618. Its `wfsSimulator` log reported six timer-overrun
events, but no WFS source counter snapshot was taken, so the loss location is
unknown. The managed runner now archives a post-replay PipeWire dump and
reports received/rejected datagrams, published/dropped WFS frames, buffer
starvations, and missing or repeated command identities. Twelve subsequent
1,024-frame replays under
`~/.cache/rtc-copper-diagnostics-{1024,repeat-*,series-*}-20260929/`
each received 2,048 WFS datagrams, published 1,024 frames with zero WFS drops,
delivered 1,024 ordered commands, and matched the saved FGN command vectors
exactly. None logged a simulator timer overrun. These passes do not explain the
earlier failure or establish loss-free operation under all host loads.

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
against its available CPUs and probes permission to start a process on the
source CPU at the requested SCHED_FIFO priority. With
`--verify-placement`, each runner captures live process and thread state
before ingress and after replay. The baseline requires `verified` for every
declared role before qualifying latency. These are broad process-envelope
checks: the current profile has no required RT-thread counts or owner-supplied
proof of every worker pin. They do not yet satisfy the full RTC-DEV-019
placement contract.

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

[First-frame packet timing](COPPER_FIRST_FRAME.md) separates frame 1 from
frames 2–10 and 101–1024 using these qualified captures and the later
strict-placement single runs. It records the initial transported-frame cost
without attributing it to JIT compilation or one graph operation.

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

## Opt-in strict placement experiment, 2026-09-29

The [Ryzen Copper thread profile](profiles/ryzen-6800h-copper.json) now adds
required scheduler and affinity counts to each runner's live pre-ingress and
post-replay verification. An initial 16-frame attempt failed before the FGN
pixel source started: its daemon had zero FIFO83 threads. An opt-in FGN daemon
configuration first acquired FIFO83 but kept a broad CPU mask; placing
`context.data-loops` inside `context.properties` then produced one
`rtc-data-loop` at FIFO83 on CPU 0. The FGN topology reported the WFS source
and DM sink on that loop. The strict verifier observed the same policy and
affinity before ingress and after replay.

The retained row-block and full-frame manifests are
`~/.cache/rtc-dev-019-strict-row-1024-20260929/manifest.json` and
`~/.cache/rtc-dev-019-strict-fullframe-1024-20260929/manifest.json`. Each
contains one 1,024-frame HEART, FGN, and JFG run at 474 Hz with 2,000 µs
readout. All six runs passed their strict role-profile checks, captured 2,048
WFS packets, and emitted 1,024 ordered DM commands. The largest HEART↔JFG
vector difference was 4.563 × 10⁻⁸ µm; FGN↔JFG was 2.981 × 10⁻⁸ µm. The
opt-in FGN configuration explicitly selects an eventfd loop, FIFO83, CPU 0,
and `mem.mlock-all=false`; its observed `VmLck` was 44 KiB for row-block and
60 KiB for full-frame ingress.

These are single functional replays. They do not establish a new latency
ranking: three unrelated CPU-saturating Julia processes remained runnable
with masks covering the RTC cores. The profile checks policy and affinity,
but does not prove each thread's algorithmic role. Julia owner pin identity,
complete explicit PipeWireAO loop and memory settings for every process,
first-use characterization, and at least three uncontended repetitions per
mode remain open for RTC-DEV-019.

## Repeated strict-placement series, 2026-09-29

The follow-up manifests are
`~/.cache/rtc-copper-strict-row-3x-20260929/manifest.json` and
`~/.cache/rtc-copper-strict-fullframe-3x-20260929/manifest.json`.
Each mode has three sequential 1,024-frame HEART, FGN, and JFG replays with
the same FITS cube, 474 Hz offered rate, 2,000 µs readout, clipping feedback,
and strict Ryzen thread profile. All 18 RTC executions qualified: each
captured 2,048 WFS packets, emitted 1,024 ordered Standard-DM commands,
passed pre-ingress and post-replay role-profile checks, and passed the
numerical vector comparison. The largest HEART↔JFG difference was
4.563 × 10⁻⁸ µm and FGN↔JFG was 2.980 × 10⁻⁸ µm, rounded to four
significant figures.

The [packet-level phase record](data/copper_strict_phases_20260929.json)
requalifies the current captures against FITS pixels and Standard-DM packets,
checks packet identity and capture order, and retains the hashes and per-run
first-frame and later-frame intervals. The table gives the minimum–maximum
range of the three **per-run** all-frame percentiles in microseconds. It does
not pool the runs.

| Ingress | RTC | First packet → DM p50 | Terminal packet → DM p50 | Terminal packet → DM p99 |
| --- | --- | ---: | ---: | ---: |
| Row blocks | HEART | 1,175–1,192 | 178–193 | 216–237 |
| Row blocks | FGN | 1,127–1,128 | 130–131 | 185–218 |
| Row blocks | JFG | 1,128–1,144 | 129–147 | 245–272 |
| Complete frame | HEART | 1,231–1,262 | 233–264 | 351–380 |
| Complete frame | FGN | 1,127–1,157 | 129–159 | 235–239 |
| Complete frame | JFG | 1,138–1,154 | 140–156 | 267–317 |

These runs close the repeated strict-profile delivery and packet-latency
measurement for both ingress modes on this host. Six CPU-saturating Julia
analysis processes were observed during the series; a
[post-series host snapshot](data/copper_strict_ambient_20260929.json) records
their PIDs, CPU usage, and affinity. The RTCs ran in fixed
HEART→FGN→JFG order, and the source still has no pre-ingress release gate.
The latency spread therefore does not establish an uncontended performance
ranking or the complete RTC-DEV-019 placement claim. Offline graph warmup was
used; cold-graph first use remains a separate experiment.

## Gated pixel-source experiment, 2026-09-29

The opt-in [Copper WFS source gate](COPPER_GATED_SOURCE.md) uses HEART's
unchanged synchronized simulator with a native companion pacer. It inspects
every live source and pacer thread before the first trigger and records the
offered trigger schedule. One final 1,024-frame row-block run and one
complete-frame run qualified for HEART, FGN, and JFG with exact WFS and DM
delivery, strict placement, and command-vector parity. The gated source
replaces the simulator's timer, so its latency samples form a separate
source-clock configuration from the timer-driven results above. The linked
record includes packet phases, trigger lateness, an earlier pre-ingress FGN
startup failure, and the remaining limits on a clean latency ranking.

The [laboratory placement record](LAB_PLACEMENT.md) now verifies named
HEART stage workers and PipeWireAO data loops on the Ryzen profile. Two
16-frame live replays passed the stronger profile, and retained 1,024-frame
snapshots were rechecked offline. A separate
[first-frame comparison](COPPER_FIRST_FRAME.md) records 1,024-frame gated
replays with JFG's explicit offline Graph warmup disabled. These checks
remain scoped to this host and the selected zero-worker JFG Copper graph.

## Explicit Julia island client loop

For the opt-in strict Ryzen profile, the launcher now takes the JFG island's
named `data-loop.0` CPU and FIFO priority from that profile. The JFG runner
renders a separate PipeWireAO `client.conf` for the island with CPU 0,
FIFO83, eventfd idle, and `mem.mlock-all=false`; it records the rendered
configuration hash. The other JFG runner processes retain their existing
client configuration.

One gated 16-frame row-block replay and one gated 16-frame complete-frame
replay qualified across HEART, FGN, and JFG at 474 Hz and 2,000 µs readout.
Each RTC received 32 WFS packets and emitted 16 ordered DM commands with
zero pixel-payload mismatches and passing command-vector comparison. The
named island loop was observed at CPU 0 / FIFO83 both before ingress and
after replay. The [client-loop evidence](data/copper_client_loop_evidence_20260929.json)
records the manifests, configuration hashes, and thread records. These short
runs establish configuration and functional compatibility, not an
uncontended latency result. Explicit client settings for the remaining
PipeWireAO processes are still open under RTC-DEV-019.
