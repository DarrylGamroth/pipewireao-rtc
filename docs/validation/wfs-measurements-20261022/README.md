# Headless WFS measurements and generic X/Y — 2026-10-22

## Delivered boundary

FilterGraphAlgorithms 0.7.1 adds an ordinary CPU
`shack-hartmann-summary-f32` node. It runs in the existing external JFG owner,
not the lifecycle runner or GUI. Classic connects its existing slopes, flux
and validity to this node and exports an eight-element F32 summary through an
ordinary capacity-one copy/drop-oldest observation queue. No additional
management daemon, scientific reference, feedback path or GUI-specific
transport was introduced.

The fields are total count, valid count, mean valid flux, uncentered X/Y slope
RMS, combined RMS, mean X and mean Y. Input units are preserved. Classic mean
slopes are detector-pixel centroid measurements, not calibrated physical
tip/tilt or focus. Float64 accumulation precedes the final Float32 conversion.
The preparation count bound 1…2²⁴ preserves exact Float32 counts. Invalid rows
are excluded; zero valid rows or nonfinite valid inputs retain counts and
publish NaN aggregates without failing the science graph.

The existing GUI SHWFS readouts decode that packet directly, including its
published combined RMS. GUI WFS reductions and attack/decay smoothing were
removed. An optional fifth coherent Summary member joins detector, slopes,
flux and validity with exact source identity, Header sequence/PTS, reset and
format guards. Missing summaries display unavailable values, including counts.
Explicit preview data remain separate.

Generic X/Y is an additive `xy_axes` declaration on the existing `time_series`
view. It reuses bounded history, source admission, persistence and egui_plot.
Both coordinates come from one sample. Classic's TOML selects summary channels
6/7 for mean-slope X/Y, and 2 for mean-flux history. No Classic, GPI or SPIDERS
renderer was added. Equal scale, latest marker, trail, pointer wheel zoom,
crosshair and source/axis settings are available.

## Revisions and immutable package selection

| Surface | Revision |
| --- | --- |
| Scientific monorepo | `12e894941e76cb69a97e56694daf01b0740b0115` |
| FilterGraphAlgorithms 0.7.1 tree | `f455990e23cdd3193f707a9e8c8cb2ce3aaf92f8` |
| GUI | `44c919030e4905f8eb66d1a027d400510c42d16c` |
| Classic application | `7989bcf`, from `9d855c7` |
| RTC integration base | `a4f4fce` |
| Julia | 1.13.2 |

The package is registered in the existing private local Julia registry, backed
by an immutable bare monorepo mirror under
`~/.local/share/classic-review-20261020/packages/JuliaFilterGraph.git`.
Classic's only changed locked dependency is FilterGraphAlgorithms 0.7.0 →
0.7.1. AOS 0.2.2, ClassicSim 0.2.4, shared HIL 0.2.2, RTC 0.2.4 and every
other Manifest entry are unchanged. There are no checkout overrides.

The calibration identity remains
`sha256:1837924beaf3a198726c096cfc3922d30529935be3f73974a1979169cb2962e4`.
Calibration files, commands, gains, limits, ADC thresholds, atmosphere and
model period remain unchanged. The normal saved application still selects
CUDA; all task execution uses separately sealed CPU copies with empty CUDA/
ROCm visibility. No GPU experiment or GPU qualification was performed.

## Software and CPU verification

- 651 checks in the deployed package closure, followed by 427 focused checks
  after exact-count boundary validation. These include independent BigFloat
  mathematics, invalid/zero-valid inputs, immutable inputs, aliases/shapes,
  strided arrays, graph metadata and zero warmed allocations. See
  `sh-summary-deployed-tests.log` and `sh-summary-bounded-count-tests.log`.
- 576 GUI library, 276 desktop and 12 integration tests pass. One library
  and 15 opt-in desktop tests remain ignored. Real headless egui tests cover
  X/Y navigation, saved axes, direct owner summaries and unavailable counts.
  WASM/browser-host compilation, dependency exclusions, 151 Julia fixture
  checks and parsing the actual Classic profile pass. Browser runtime and
  manual rendered interaction are not claimed. Strict Clippy retains existing
  Rust 1.99 DM chunk and atomic deprecation lints; allowing those baseline
  classes passes. See `receipt.json` and the retained GUI logs.
- Classic offline preparation passes 71 assertions and verifies all 44 sealed
  assets without starting science or loading GPU modules/libraries. See
  `offline.log` and `offline-check.json`.
- The maintained `test/integration/classic_wfs_summary.jl` passes **2,618/2,618**
  assertions in two native 32-frame CPU generations separated by Reset. All
  32 frames of detector, demanded command, slopes, flux, validity and summary
  are captured per generation. The independent row-major oracle matches all
  summary bits; all six streams share acquisition identity and Header
  sequence/PTS. Native detector replay is exact under the retained and checked
  20-plan FFT execution witness. All common original controller graph outputs
  remain bitwise identical, and warmed process calls allocate zero bytes.
  Native Stop and final Quit/process/cgroup cleanup pass. See `managed.log`,
  `wfs-summary-result.json`, `final-launch.json` and `gpu-audit.json`.

The baseline argument selected the canonical application while it was still
at `9d855c7`; its original graph SHA-256 was
`7fc51058799bccd60ccf8034652bd4df5faa9fb22d0c2c52caea573ac8bf6f2a`.
The application was fast-forwarded only after the successful run. This compares
the original graph topology and bindings under the otherwise identical loaded
package closure; the scientific measurement implementations were not changed.

Raw capture, identities, graphs, test applications, FFT witness and original
logs remain under
`~/workspaces/codex/worktrees/wfs-measurements-20261022/managed-final/`.
Earlier retained attempts are not passing gates: `managed.log` rejected an
incorrectly pre-created test stage before launching services; `managed-verified.log`
passed 1,217 checks before a missing test-only AlgorithmGraphs import stopped
detector replay. The harness was corrected, exact cleanup completed, and a
fresh full run produced the passing result above. No production tolerance or
scientific algorithm was changed to accommodate those harness errors.

## Live CPU deployment

The previous CPU session completed exact cleanup before replacement. The new
live application is a sealed copy of Classic `7989bcf`, with CPU backend,
10 Hz requested wall pacing, continuous exchanges and the unchanged 500 Hz
model period. Its root is
`~/.local/state/pipewireao/classic-cpu-wfs-live-20261022/`; the native session is
`pipewireao-session@e94c3bddc883.service`. The ordinary prefix remains
`~/.local/opt/pipewireao-classic-headless-20261021/`.

The GUI runs as `pipewireao-classic-cpu-wfs-gui-20261022.service`, using the
standalone stripped Glow-only binary `pipewireao-gui-44c9190-glow` with SHA-256
`6c595f54ca06d4a6d0d8096244a3b4e224adc663a77194700744e2419d2483bb`.
The exact eframe build fingerprint contains Glow and excludes Wgpu. Its launch
environment selects Mesa llvmpipe/software rendering and excludes accelerator
devices. The native RTC remains 0.2.4; no runner rebuild was needed.

Live read-only observation captures 32 samples on each of detector, slopes,
flux, validity and summary. All 32 common acquisition identities and Header
PTS match, and the independent eight-field oracle matches every summary bit.
With SHWFS rendering, the GUI has active subscriptions to all five sources;
`live-readouts-check.json` records that phase. After the GUI-disconnect check,
the final observation respects the restored panel selection: the summary chart
remains subscribed, while nonrendering detector/overlay panels do not request
their streams. `live-wfs-check.json` records the final selected-view phase.
The matching console logs are `live-readouts.log` and `live-reconnected.log`.
The process audit covers
core, parameter publisher, JFG, simulator, RTC and GUI, with no GPU device
handles or CUDA/HIP/NVIDIA/hardware graphics-driver mappings. See
`live-wfs-check.json`, `live-gpu-audit.json` and `live-identity.json`.

With the GUI process stopped and its nodes absent, a CLI client receives 16
distinct summary frames (generation 1, sequences 6422…6437), while native RTC
status remains Running. The GUI is then relaunched. This demonstrates GUI
independence with a CLI observer present, not an all-observers-absent timing
gate. See `headless-progress.json` and `headless-observation.json`.
The corresponding console result is `headless.log`.

The saved workspace and automatic session connection initially selected RTC
Session, so the SHWFS tab was not rendering and had no live detector/product
subscriptions. A session-local copy preserves the user's original workspace
file and opens SHWFS as an ordinary detached panel for the readout check. On
subsequent GUI restart the panel is docked in the restored workspace; select
its tab to resume its observations. The X/Y chart remains available in Charts.
This changes presentation state only; neither UI selection nor detached-window
lifetime is an RTC or analysis dependency.

An earlier headless-progress probe incorrectly treated the source Props
sequence as continuous telemetry. It is the last acknowledged source-control
snapshot and remained zero after Start. The successful probe instead reads
the actual published summary stream. Both earlier assertion logs are retained
under the raw task directory; they do not indicate a stalled source.

No rendered screenshot or manual operator interaction was available in this
deployment check. The GUI interaction/decoding tests and actual live source
subscriptions are separate evidence. The CPU RTC and software GUI are left
running; the task's temporary Rust build target has been removed.

## Limits

These are software, finite CPU simulation and observation checks. They do not
qualify wall cadence, deadlines, tail latency, GPU execution, physical devices,
physical modal calibration or other instrument deployments. A finite Float32
input near its maximum can overflow final combined RMS; the GUI rejects such
an infinite packet. Current Classic centroid ranges are far below that case.
Optional downstream observation is bounded; loss of a declared required core
queue or link retains the RTC's existing fault policy.

The [independent review](../../reviews/20261022-wfs-measurements/REVIEW.md)
records numerical/ownership checks and the two corrected X/Y settings defects.
