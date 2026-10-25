# GPI calibrated multi-corrector integration — 2026-10-24

This record covers the data-only provisional GPI simulation, shared controller,
three named command ports, typed UInt16 camera, calibrated parameter adoption,
GUI presentation and private native lifecycle qualification. It does not
qualify GPI hardware, measured influence functions, calibrated stage angles,
physical actuator limits, AMDGPU execution or a 2 kHz deadline.

## Source and execution boundaries

| Owner | Source used |
| --- | --- |
| AdaptiveOpticsSim | `a0c2ee173a60962197ce59583cab54bda45aa516` |
| AdaptiveOpticsSimPipeWireHIL | `f5fa45c21f790efe327c472bec012d6c40b22779` |
| JuliaFilterGraph / FilterGraphAlgorithms | `d7efe01` |
| PipeWireAORTC scientific/native cohort | `fd53f7f` (includes `3ce777a`, `cc12a46`, `a0daf30`) |
| PipeWireAORTC native optical observer/test helper | `6ae02f4` |
| GUI | `f25990a867fcb09c2966d0b5fd9d5564045699a5` |
| Instrument source | `fdb1224` calibrated integration; `eeaa617` native session-control grant; `aa45f31` characterization and operating limits |

Julia 1.13.2 and CUDA.jl 6.4.2 were used. Source validation uses a separate
coordinated environment; no package resolution/downgrade was performed. Native
applications use git-archived, hash-verified package trees in an isolated local
registry/cohort and the supported deployment-manifest preparation path. Source
`path` entries were not admitted by weakening deployment seals. The installed
Classic application and original dirty GUI main worktree were not modified.

Native qualification uses the existing SDK at
`/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021` and exact private
cores/systemd owner cohorts. These checks never connect to the desktop core.

## Calibration and optical results

The [source receipt](calibration-receipt-source.yaml) binds the final UInt16
prescription, source/concrete graph hashes, recipe and all FITS hashes. Its
scope is simulation-local Gaussian mirrors and provisional ADC, not measured
instrument calibration. It retains 1,663 of 1,810 modal coordinates from 11,104
selected pupil pixels, using ±20 nm probes and TSVD relative cutoff 0.05.
Piston-removed pupil-RMS weighting sets inverse weights to zero below
√eps(Float32). The fitted woofer tip/tilt ramps have 2.153% relative fit error;
the coupled projection condition is 2.583. These characterize this model.

All 27 startup parameters are initialized through production FITS preparation,
with exact element type, shape, reversed FITS axis convention and content hash.
The new 3D coefficient-bank roundtrip is covered by [axis tests](fits-axis-tests.log).
Modified receipt-bound FITS bytes are rejected before optical preparation, even
when shape and logical values remain unchanged.

[CPU optical replay](loop-cpu.yaml) runs the actual exported active controller
for tip/tilt, focus, astigmatism and mixed disturbances. It records all 48 RMS
samples and the exact controller properties. These noise-free small-disturbance
checks are separate from noisy atmosphere, capture, native delivery and timing.

## Software checks and reviewed changes

- [CPU optical model](optical-cpu-tests.log): 57 assertions; ADC layout/type,
  clipping, ties-to-even rounding and transport: 21 assertions.
- [Controller composition](controller-cpu-tests.log): 47 assertions, including
  independent mirror/stage outputs, metre units, clipping/offset feedback,
  non-unit-pole recurrence, reset and failure publication.
- Typed camera [same-case failure before](camera-before.log) and
  [CPU pass after](camera-cpu-tests.log): 8 new +69 existing assertions.
- [CUDA layout stream/capture](camera-cuda-tests.log): 60 assertions, including
  changed inputs, fixed addresses, ties, saturation, padding and reset.
- [Nonfinite CUDA probe](camera-cuda-nonfinite.log): expected KernelException in
  a fresh process for the exact affine/clamp/round/UInt16 path. NaN is not silently
  turned into a healthy detector code. The failed context was discarded.
- [HIL CPU selector](hil-cpu-tests.log): 1,099 assertions/64 testsets; 42 new typed
  UInt16 checks cover scalar/named ordinary and held-calibration exchange,
  exact 0/255/16383/65535 codes, row-major packing, matching wire type and warmed
  zero-allocation staging. Commands remain Float32.
- [FGA review selector](fga-cpu-tests.log): 208 assertions; generic vector-offset
  parameters reuse existing transaction ownership.
- [JFG parameter transactions](parameter-transaction-tests.log): 21 assertions.
- [Shared RTC selectors](rtc-focused-tests.log): 582 assertions across export,
  graph references, named HIL declarations, instrument schemas, AOS owner
  configuration and scientific session integration. These include Classic
  regression coverage alongside the new named-corrector paths.
- Native source contracts: the [same offline check failed before](session-contract-before.log)
  and [passed after](session-contract-after.log) the explicit session-control
  grant. Fifteen checks cover native grants, external ports, preserved internal
  feedback, group membership and passive/active link boundaries; the 47 numerical
  composition checks also pass.
- AOS algorithm-graph selector: 897 assertions; named held calibration reuses
  production complete-set validation and fail-stop/reset ownership.
- Earlier native held-calibration selector: 795 assertions, including delayed,
  missing and duplicate multi-command responses; all owned resources closed.

Independent review reconstructed the weighted inverse R=W(DW)⁺, reference−Ry₀,
pupil-major flattening, fitted ramp/complement basis, complete command-set
adoption and reset. No unresolved equation or ordering defect was found.
The final typed-frame patch received independent review in both RTC and HIL.

| Finding | Disposition |
| --- | --- |
| GPI-001 | **Confirmed, fixed:** FITS writer transposed only rank2; rank3 temporal banks had incorrect axis ordering. Writer reverses all axes; rectangular/rank3/vector roundtrips pass. |
| GPI-002 | **Confirmed, fixed:** Float32 camera buffer remained despite UInt16 wire format. Existing layout now has a typed output contract; HIL preserves exact UInt16 frames without re-quantizing. Same-case fail-before/pass-after retained. |
| GPI-003 | **Confirmed, fixed:** array validator checked graph/prescription but not every FITS hash. All receipt artifact hashes are now checked before preparation; same-shape modification rejects. |
| GPI-004 | **Confirmed, fixed in application authoring:** external session telemetry declared the controller's internal constraint-feedback output. FilterGraphPipeWire intentionally removes that alias from native ports. The declared endpoint never appeared, preventing all-link admission. Removed that optional queue/link/port while preserving internal antiwindup feedback. Failed cohort cleanup was confirmed; final native gate results follow below. |
| GPI-005 | **Hypothesis rejected on CUDA:** UInt16 conversion might conceal NaN. Exact fresh-process probe raises KernelException; no speculative production fix was made. |
| GPI-006 | **Confirmed, fixed:** the external controller graph lacked `run-control=session`. Native policy rejected the missing explicit grant after owners connected. Added the same grant as Classic, preserved failure/cleanup evidence and added fail-before/pass-after offline contract checks. |

## GUI boundary

Pyramid overlays use verified RTC-published instrument geometry and exact
source/schema/shape identity. Both DM panels use published command maps and metre
OPD units. Existing generic X–Y charts show the two stage coefficients. No GPI
renderer or GUI-owned calibration/science calculation was added. Small metre
values remain visible in readouts and colour ranges.

GUI checks passed 595 library, 282 native (15 ignored), 12 import and 151 Julia
fixture assertions; focused DM checks passed 97. Browser flows passed 28 each at
DPR 1 and 2; WASM/browser builds and dependency-exclusion checks passed. Formatting
passed; Clippy used documented pre-existing `chunks_exact`/deprecation baseline
exemptions. Actual calibrated instrument metadata resolved all 9 GPI panels.
This is software presentation/hydration evidence, not interactive physical GUI
acceptance or browser transport deployment.

## Final native and noisy/performance gates

### Noisy atmosphere and completed-step throughput

[Final CUDA evidence](noisy-timing-cuda.yaml) passed 7/7 checks over 4,096
production noisy driver steps (2.048 s model time). Paired trailing means were
1,010.49 nm uncorrected and 53.9665 nm residual: ratio 0.0534063. CPU's separate
128-step realization gave 825.59 nm → 52.453 nm, ratio 0.06353375. Backend RNG/initial
atmospheres differ; these are separate functional observations, not a controlled
backend correction-quality comparison.

The timed boundary is one sequential completed CUDA plant step, HIL host-frame
copy, UInt16 controller input copy, CPU JFG processing, command and feedback
copies. It excludes native PipeWire transport, GUI, RMS reductions, receipt
writing and pacing. After 256 warmup steps per reset, three 1,024-step repetitions
gave 119.526/119.789/119.870 Hz; medians 8.289/8.269/8.242 ms, p90
8.920/8.942/8.962 ms, maxima 12.271/11.621/12.461 ms. Each measured repetition
advanced model sequence 256→1280, allocated 7,962,624 host bytes and reported no
GC time. This is a shared-workstation, closed-loop throughput sample; it does
not establish maximum capacity, fixed-arrival latency, p99 tails or 2 kHz
deadlines. OS/kernel, CPU allowance, BLAS configuration, GPU/runtime versions,
competing processes, source hashes, raw durations and GC deltas are retained.

YAML.jl emitted invalid implicit indentation for leading-space `ps` headers.
The [original report](noisy-timing-cuda-original.txt) is preserved; the parsed
copy changes only three `|` block indicators to `|2`, leaving every numerical
value and snapshot line unchanged. The CPU48 report has the same documented
syntax-only normalization. Future runner snapshots encode process output as
arrays of single lines, avoiding this upstream writer limitation.

### Extreme small signals: retained failed absolute-WFE gates

Clipped-stage optical spillover passed on CPU/CUDA with 1.552568% pupil-OPD
relative error. The [CPU48](probes-cpu-48.yaml) and
[CUDA48](probes-cuda-48.yaml) runs each retain 42 passed/2 failed assertions.
The failures concern the absolute residual ratio < 0.8 for 10/20 nm tweeter
coefficients, which inject only 0.2406/0.4812 nm global pupil RMS.

The [256-step CUDA follow-up](probes-cuda-256.yaml) retained 35 passed/1 failed:
10 nm coefficient → 0.19855 nm residual, ratio 0.8253. The
[bounded 1,024-step follow-up](weak-cuda-1024.yaml) retained 2 passed/1 failed:
0.24059 nm injected → 0.67607 nm residual. A separate identically reset flat loop
evolved similarly and reached a late 8-frame mean 0.67137 nm (range
0.67121–0.67158 nm). The earlier 48-frame window was still settling, and even the
256-frame result cannot establish long-time subnanometre absolute correction.

**Observed:** the absolute-WFE criterion fails at this extreme signal level,
and the noiseless flat baseline is nonzero and evolves slowly. **Not
established:** its cause, a stationary quantization floor, or poor incremental
weak-signal correction. Scalar RMS histories do not determine
RMS(residual_weak−residual_flat); paired OPD fields were not retained. No gain,
ADC scale, numerical threshold or calibration coefficient was tuned to make
these tests pass. The demonstrated operating claim is the finite noisy
atmospheric correction above, not subnanometre absolute sensitivity.

### Native lifecycle

- [CPU Ready/Quit](native-ready-quit-cpu.json): completed; Quit acknowledged,
  observed shutdown 24.397 s within 320 s budget. All 14
  [cleanup checks](native-ready-quit-cpu-cleanup.json) passed.
- [CPU Stop/Start/Quit](native-stop-start-cpu.json): coherent complete sets
  before/after restart, same generation; shutdown 23.327 s and all 14
  [cleanup checks](native-stop-start-cpu-cleanup.json) passed.
- [CUDA plant / CPU controller Stop/Start/Quit](native-stop-start-cuda.json):
  coherent camera+three commands at sequences 2/34 around held cursor 32,
  same generation 1; shutdown 25.627 s and all 14
  [cleanup checks](native-stop-start-cuda-cleanup.json) passed. Model rate 2 kHz,
  functional test pacing 10 Hz; roles 6/7 were separate from CPU roles 2/3.

- [CPU required-link loss/fresh recovery](native-link-loss-cpu.json): the exact
  removed graph→tip/tilt link was the first fault. Native policy shut the
  application down after an uncertain 5 s Hold acknowledgement, and emergency
  cleanup completed. A fresh session, invocation and every owner incarnation
  delivered a coherent complete set and cleaned up. This is fail-closed process
  removal, not a confirmed safe Hold.
- [Native CUDA optical check](native-optical-cuda.json): 128 paired RMS samples,
  with one expected capacity-one telemetry gap, reduced trailing means from
  1,271.955 nm to 53.829 nm (ratio 0.04232) after a 32-sample settling prefix.
  Camera, three commands and RMS reached a common acquisition identity. Quit
  was acknowledged, shutdown took 25.839 s and all 14
  [cleanup checks](native-optical-cuda-cleanup.json) passed.

- [CPU controller loss/fresh recovery](native-controller-loss-cpu.json): completed.
  Killing the controller removed a required incident link; native policy shut
  down after an uncertain Hold acknowledgement. Emergency process cleanup and
  fresh-session recovery passed, with distinct session/owner incarnations and
  a coherent camera/three-command set. This also proves process removal, not
  a confirmed safe Hold.

The [complete CPU lifecycle matrix](native-lifecycle-cpu.log) passed 101/101
assertions. The [final ownership audit](native-owned-cleanup-audit.json) covers
all ten private cohorts and 60 unit names: no owned PID or private socket
remained, and every unit was inactive with no installed fragment. The fault
harness left two stopped manager aliases and 16 failed-unit cache entries;
only those verified test aliases/cache entries were manually removed after
recording their targets. Process/cgroup/owner cleanup had already completed.
This manual harness cleanup is separate from the lifecycle receipts.

Frozen numerical runners are retained in [this archive](runners.tar.gz);
their byte hashes match each report's `runner_sha256`. The current maintained
instrument selector includes the final strict UInt16 and bounded weak follow-up
paths; the archive preserves earlier exact drivers without leaving superseded
implementations on the active test surface.
