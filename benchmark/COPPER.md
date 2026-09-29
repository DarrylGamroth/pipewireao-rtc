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
micrometres. The observer is non-actuating. The Standard-DM conversion and
wire output used by the three-way baseline are outside this RTC fixture.

The managed JuliaFilterGraph island prepares the calibration matched to this
Copper workload, publishes the graph at the selected rate, and enables RTC
session run control. `run_copper_rtc.py --controller julia` launches it before the RTC,
uses the same HEART WFS and observer, and checks ordered delivery and optional
command-vector equivalence. It maps Julia's PipeWireAO JLL to the selected
PipeWireAO installation and uses one OpenBLAS thread by default, as the
matched Julia Copper runner does. `--julia-blas-threads` permits a recorded
diagnostic comparison. The runner's Julia path requires the managed provider
in the JuliaFilterGraph sibling repository.

The RTC runner also accepts an opt-in per-role placement contract. The
[native](profiles/ryzen-6800h-rtc-copper-native.json) and
[Julia](profiles/ryzen-6800h-rtc-copper-julia.json) examples describe this
workstation's CPU set, expected thread counts, FIFO83 data loop, and FIFO20
pixel sender. They are separate because the RTC has one additional parameter
thread when it owns the native graph. Before starting the sender, the runner
checks that every requested CPU and scheduler policy is available, generates
an explicit eventfd/FIFO83/CPU 0 daemon data loop with
`mem.mlock-all=false`, and verifies each live daemon, observer, RTC, and
optional Julia-island thread against the selected profile. It verifies them
again after replay. The Julia owner receives `JULIA_RTC_PIN_CPUS` through its
maintained ThreadPinning interface. A changed or unavailable thread layout
fails the run; the JSON records name the failed process and thread.

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
be inspected before it starts sending. The managed RTC fixture ends at the
non-actuating demanded-command observer, so it does not provide Standard-DM
wire egress or pixel-to-DM latency distributions. The three-way baseline
runner remains the source of those complete-path measurements.

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
links, and the demanded-command data boundary. The script does not send a
Standard-DM command or measure pixel-ingress-to-DM-egress latency; the
three-way comparison below retains those measurements.

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
