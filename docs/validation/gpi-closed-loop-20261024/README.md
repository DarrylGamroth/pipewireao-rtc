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

## Annular tweeter control and registered GUI geometry — 2026-10-25

RTC science source `aee7264`, observer helper `1e48575`, instrument calibration
`cbde133` (scope clarification `cd2c962`) and GUI `5267739` replace the earlier
provisional radial selection. The live runtime uses immutable package trees
listed in [the new source cohort](annular-20261025/runtime-sources.toml).

HEART's checked-in GPI2 matrices are random/zero placeholders; its 1,713 value is
not a measured actuator control mask. The explicitly provisional recipe now
selects centres in the registered annulus: 1,412 independent tweeter coordinates,
24 central and 280 outer-guard coordinates completed by the existing FGA
thin-plate algorithm, and 588 farther coordinates with zero correction. Guard
width is two actuator pitches. No measured health, physical limits, or as-built
slaving calibration is claimed. System flats and offsets remain independent.
The controller has 1,509 coordinates and retains 1,445 sensed modes. The
[calibration receipt](annular-20261025/calibration-receipt.yaml) binds all FITS bytes.

Runtime forward mapping is C followed by identity physical projection. Its
reverse uses identity physical mapping followed by the cold least-squares
F = C⁺, so guard-only clipping reaches the active coordinates. The direct rows
of C are identity, giving full column rank. No solver runs in the frame loop.
The fitted tip/tilt-coupled mirror excludes this zonal completion policy; review
found a potential stale-reverse alias in that combination, and an early tested
rejection now prevents it. The existing fitted woofer path remains unchanged.

[Completion checks](annular-20261025/completion-tests.log) pass 63 assertions,
including actual forward/clamp/reverse owners. Maximum Float32 affine component
error is 1.91×10⁻⁶; maximum coefficient is 1.322 and maximum completion row sum is
7.69. This can amplify peak guard demands. The bounded test produces 70 guard-only
clips at the existing ±1 µm limits (maximum request 1.098 µm) and 26.24 nm maximum
active reverse feedback. Physical-space projection identities hold; active-vector
Euclidean energy need not decrease under this nonorthogonal mapping.

The [quiet CUDA loop](annular-20261025/quiet-cuda.yaml) passes tip/tilt, focus,
astigmatism and mixed cases, with trailing residuals 0.142–0.174 nm for these
specific finite disturbances. The [4,096-frame noisy CUDA check](annular-20261025/noisy-cuda.yaml)
passes 4/4 assertions: trailing paired means 1,010.49 nm → 65.276 nm, ratio 0.06460.
The earlier selection gave 53.9665 nm for its recorded paired run. This is a
control-policy tradeoff, not evidence of improved correction quality or a
hardware-calibrated partition. New throughput and extreme-small-signal
qualification have not been established; earlier failures remain historical evidence.

[Controller composition](annular-20261025/controller-tests.log) passes 15 native
boundary plus 59 numerical assertions. [Feedback publication](annular-20261025/feedback-contract-tests.log)
passes 112 cold assertions; four producer-to-owned-queue links use the existing
required internal-link contract, while GUI readers remain optional behind
bounded copy/drop-oldest telemetry queues. [Typed observer checks](annular-20261025/observer-tests.log)
pass 38 assertions, including U8 role contracts. [CPU session-science checks](annular-20261025/session-science-tests.log)
pass 53 assertions across rectangular, Shack–Hartmann, pyramid and named-command
products. Registered-pupil validation is covered by [the instrument checks](annular-20261025/pupil-tests.log).

The generic GUI uses command-indexed Cartesian pupil coordinates and explicit
inner/outer optical radii, without inventing a circular mirror boundary. An
unregistered layout retains its grid without a fabricated aperture. Applied is
an independently declared observed product in µm OPD; demanded, limiter,
shape-control and constraint-feedback units remain m OPD. Health remains
unpublished. All nine actual application views hydrate; GUI tests pass 603
library, 282 native, 12 import and 151 Julia assertions, plus formatting,
WASM/browser checks and Clippy with existing baseline exemptions. Independent
review's finite-geometry overflow finding was fixed with ratio-first geometry,
wider display-interpolation intermediates and finite-shape regressions.

GUI follow-up `f8b882f` uses one centred generic **Data unavailable** label for
missing DM, ndarray and image data, removing duplicate headers/footers and
product-specific missing-source messages. Detailed diagnostics remain in
Settings. Focused missing-data, DM, array, image, status and instrument tests
pass, as do formatting and the matching native build. Its binary SHA256 is
`7be04c41dbecd92f44efe249d75ac9ad0016a9625e346a828dcf77c319a7cd1b`.

The [first replacement launch](annular-20261025/failed-start-analysis.json)
exceeded the existing 900 s startup deadline before Running. Its publication
error followed termination; it does not establish an earlier publication fault.
The publisher also crashed during exit. All owned resources were subsequently
[confirmed removed](annular-20261025/failed-start-cleanup.json), without manually
removing aliases. The candidate's CPUs 8/9 overlapped a concurrently running
Classic CPU application; this placement mistake was corrected to CPUs 14/15 for
the retry. The collision's contribution to preparation time is not independently
quantified. Neither the existing Classic nor the working GPI application was
stopped for that failed attempt.

The operator then authorized retiring the old GPI application during replacement
preparation. Its [Quit request](annular-20261025/old-gpi-retirement.log) had an
unknown outcome after the 8 s reply deadline; the service recorded a fault and
exited. Its [final ledger](annular-20261025/old-gpi-final-launch.json) confirms
emergency cleanup, and the [separate audit](annular-20261025/old-gpi-cleanup-audit.json)
confirms all owner PIDs/cgroups were absent. This proves process removal, not
clean native Quit. The stopped manager alias was then removed only after its
target was checked against this exact old deployment; its LoadState became
not-found with MainPID 0. Classic was preserved throughout.

The replacement CUDA session is Running as
`pipewireao-session@39b42bfdc81e.service`, invocation
`221288c72f054c309b45cd24c6c610aa`, using the same immutable science cohort and
10 Hz functional pacing. The [GUI process check](annular-20261025/gui-live-verification.json)
confirms the matching new binary is attached to that exact remote with three
running visible-view observation nodes. Software-renderer overrides are absent;
this does not by itself establish hardware rendering or manual visual acceptance.
The new application and GUI are left running; Classic's unit invocation remained
`e23f5c8b3e5142ccb11311f4d7c27550`.

[Native stream verification](annular-20261025/native-stream-verification.json)
passes all ten schemas/types/shapes with 35–37 distinct frames per stream. Eight
metadata-bearing streams reach a common acquisition domain/generation/sequence;
the tweeter's per-actuator role bytes match the actual calibrated C/P matrices
(1,412 direct, 304 extrapolated, 588 no correction). The woofer's mixed projection
honestly reports 97 unknown roles. Both Applied streams match 32 same-Header-sequence
demanded samples exactly after Float32 m→µm scaling. Applied has no acquisition
metadata, so this establishes Header association, not full domain/generation
identity for that product. Every exact observer incarnation was removed, with
the same session PID/invocation and source incarnation still Running.

The [initial verifier failure](annular-20261025/native-stream-verification-initial.json)
is retained: it incorrectly required the source's control/query-completion
snapshot cursor to track the live frame sequence. Source inspection confirmed
that this snapshot publishes on control completion while acquisition metadata
advances each frame. [Read-only postvalidation](annular-20261025/native-stream-postvalidation.log)
of the same capture passes the stable source/queue/session identities, current
generation, increasing frame sequences and observer-removal checks. No recapture,
production change or additional session control was used to obtain that result.

A later [read-only clipping capture](annular-20261025/clipping-native-analysis.json)
checks 32 aligned frames (sequences 7,055–7,093) against the provisional ±1 µm
OPD limits. Mean current clipping is 10.22/97 woofer actuators (10.53%),
28.09/1,412 directly controlled tweeter actuators (1.99%) and 27.69/304
extrapolated actuators (9.11%); none of the 588 no-correction actuators clip.
Maximum absolute pre-limiter requests reconstructed from demanded plus feedback
are 1.04469, 1.09578 and 1.12836 µm respectively. An independent
[exact-bound audit](annular-20261025/clipping-feedback-exact-audit.json) confirms
every nonzero feedback sample has demanded exactly at its signed Float32 limit.
These clips are real; the GUI's roughly 1.6 s hold/fade can show more recent clips
than are present in one frame. Completion reproduces the tweeter requests, with
maximum error 1.93×10⁻⁶ µm. Sampled wavefront means are 835.48 nm uncorrected and
63.70 nm corrected. These observations do not establish appropriate hardware
limits or diagnose the optimal woofer/tweeter allocation. All owned observers
were removed and the same session remained Running; no controls were changed.

## GPI offset controls and shared DM presentation — 2026-10-25

The existing `VectorOffsetF32` now publishes its adopted `current-offset` on
successful frames, with the requested command's acquisition metadata. Both
GPI mirrors expose this through capacity-one, copy/drop-oldest telemetry queues.
GUI consumers are optional and do not gate control-loop admission. Rejection
preserves both outputs; reset retains the adopted parameter. The existing
single-output numerical operation remains bitwise unchanged.

GPI's published instrument metadata now supplies Zernike and Fourier controls
for both mirrors. The generic GUI uses the declared RTC parameter, actuator
order, schema and units: offsets and demanded commands are metres OPD; Applied
remains independently declared micrometres OPD. Shape coefficients have a
50 nm range, with zero initial coefficients. No instrument-specific renderer,
unit inference, gain or stroke-limit change was introduced. The GUI's small-value
editor is tested by actually entering a 5 nm value through the widget.

DM maps, surfaces and colour bars now share ndarray's YAML palette catalog and
selector, including custom palettes; the default is blue–white–red. Circle
diameters use 96% of the nearest actuator spacing, computed once when preparing
the layout. Persistent correction-role outlines are optional and off by default;
hover information, selection and genuine clipping indications remain available.
Missing-data views retain one centred, generic message.

Both basis families make the exact full-precision GPI instrument publication
291,918 bytes. The common native/RTC/GUI bound is now 1 MiB, tested at and above
the boundary. The cold finite-JSON validator uses ordinary iteration for tuples
and named tuples instead of compiler expansion proportional to tuple length.
A normal-compiler declaration selector interrupted after about 292 s before this
change passes 69/69 in 75 s afterward; this is cold software-test evidence,
not a controlled performance benchmark or a frame-processing timing claim.

Source revisions are GUI `08e575c`, instruments `66005d8`, JFG/FGA `ababcd3`
and runtime RTC `48fd3c7`; the later RTC test-only `5caa6ba` replaces a stale
three-driver assertion with equality to the actual native template. The immutable
[runtime cohort](controls-20261025/runtime-sources.toml) records package trees.
The [frozen comparison](controls-20261025/gpi2-controls-frozen-comparison.log)
and [hashes](controls-20261025/gpi2-controls-frozen-hashes.json) establish that all
28 numerical nodes, 30 links, 29 inputs, ten existing outputs and 30 FITS files
are unchanged. Only two observational outputs were added. Historical calibration
receipts and their byte-bound YAML/context files are preserved; their recorded
graph hash describes the calibration graph, not this later telemetry export.
This scoped numerical reuse does not assert a new calibration measurement.

Software checks include [617 GUI library tests, one ignored](controls-20261025/gpi2-gui-palette-final-lib-tests.log),
formatting, Clippy, native build and WASM check; actual exported metadata resolves
[all nine GUI panels and both bases](controls-20261025/gpi2-gui-controls-final-hydration.log).
The [metre-unit feedback regression](controls-20261025/gpi2-gui-feedback-fail-before.log)
fails before and [passes after](controls-20261025/gpi2-gui-feedback-pass-after.log)
tolerance is scaled to the actual command bound, rather than a one-unit floor.
[FGA tests](controls-20261025/gpi2-offset-final-tests.log) cover output preservation,
alias rejection, metadata, reset and warmed zero allocation; the declaration
selector passes. GPI [controller](controls-20261025/gpi2-offset-controller.log)
and [native feedback contracts](controls-20261025/gpi2-offset-native-contract.log)
pass 76 and 180 assertions respectively.

The [full cold RTC run](controls-20261025/rtc-cold-suite.log) passed preceding
selectors and stopped at the stale driver-count assertion. The repaired
[native configuration selector](controls-20261025/native-configuration-tests.log)
passes 39/39; the [remaining four selectors](controls-20261025/rtc-cold-suite-remaining.log)
also pass. This is combined selector coverage, not an unbroken all-green suite
run. The initial Git `cat-file` diagnostic belongs to the passing missing-object
negative test. Two unchanged calibration-receipt-bound YAML files retain their
pre-existing formatting differences; changed authoring files pass formatting.

The [saved-frame optical analysis](controls-20261025/clipping-optical-analysis.json)
reconstructs the exact registered Gaussian mirrors and annular pupil on CPU.
Clipping changes the combined mirror OPD by 9.12 nm piston-removed RMS on average
in the retained 32-frame capture (6.75–14.84 nm range). This counterfactual OPD
difference is not a predicted closed-loop residual improvement.
[Allocation checks](controls-20261025/clipping-allocation-analysis.json) reproduce
the coupled woofer/stage coordinates to Float32 precision. The
[HEART comparison](controls-20261025/clipping-heart-limit-comparison.json) does
not establish hardware identity, ordering or phase-to-OPD conversion. The
[adjudicated conclusion](controls-20261025/clipping-scientific-conclusions.json)
is to retain the explicitly provisional ±1 µm OPD limits: the observed clips are
real, and these checks do not justify changing gains, allocation or hardware
limits merely to remove them from the display.

Independent read-only source review checked the two-output alias/rejection
semantics, metadata, units, counts, targets and queue declarations against the
generic GUI. It found one verification-script issue: the restore-attempt fence
was armed before observer negotiation. This was corrected to arm immediately
before an actual baseline request. The waiting script was stopped before any
native observers or controls attached; the corrected script then performed the
live gate. No additional production finding remained.

The replacement CUDA application is Running as
`pipewireao-session@461ad9bb9189.service`, invocation
`ffc6c76566dd4fef81146e446559514c`, PID 2660185. It uses CPUs 6/7, a 2 kHz model
and 10 Hz functional pacing, not a 2 kHz execution claim. The
[native offset roundtrip](controls-20261025/offset-roundtrip.json) confirms one
4 nm probe and one exact baseline restore per mirror, requested/active generations
1 then 2, with no rejected or unknown response. Each readback is bitwise equal
to the intended parameter and shares acquisition identity with camera, woofer,
tweeter and tip/tilt commands. The session identity is unchanged and every owned
observer is removed. This exercises the same native RTC parameter path as the
GUI; it does not claim a manual live mouse interaction.

The [final twelve-stream check](controls-20261025/native-stream-verification.json)
passes schemas/types/shapes, 35–37 distinct sequences per stream and a common
acquisition identity across the ten metadata-bearing products. Both adopted
offsets match the restored baseline bits. Both Applied products match 32
same-Header-sequence demanded frames after the declared m→µm conversion; their
Header-only association is not full acquisition-domain identity. The
[combined receipt](controls-20261025/native-controls-qualification.json) confirms
the same Running session, zero owned observers and no transient payload files.

The previous GPI `39b42bfdc81e` received exactly one native Quit. Its
[retirement record](controls-20261025/previous-retirement.json) retains an unknown
reply after the 8 s deadline and a service failure. Cleanup completed; the
[independent process/cgroup audit](controls-20261025/previous-cleanup-audit.json)
confirms every old owner and manager is gone. The exact stopped manager alias
was removed only after its target and PID were checked; it is now not-found.
This is confirmed process retirement, not a successful native Quit. The timeout
remains unresolved and was not retried or reclassified.

The [GUI verification](controls-20261025/gui-live-verification.json) confirms the
new binary SHA-256, exact replacement remote, three running visible-view
observers and absence of software-renderer overrides. The first GUI discovery
saw both GPI instances; it was restarted after old-session retirement so it
could select the sole matching GPI session. The new CUDA session and matching
GUI are left running. Classic retains PID 2432242 and invocation
`e23f5c8b3e5142ccb11311f4d7c27550`. No manual visual acceptance, hardware
qualification or real-time deadline claim is made.

## Controlled shape projection and coherent DM presentation — 2026-10-25

This increment supersedes the preceding GUI shape path. Physical engineering
offsets remain available separately. A shape request now enters independent
VDM coordinates before the existing calibrated completion and physical limits.
For completion matrix C and physical-to-VDM projection B, S selects the first
unit row for each independent coordinate: S·C = I. The adopted shape is S·B·p;
the existing C then completes the command. The least-squares clipping-feedback
projection is unchanged and is not substituted for this selector. Projection
occurs at parameter adoption; frame processing adds a cached vector.

The RTC derives the editable physical mask from that same calibrated projection
and publishes it with the basis. The GUI normalizes generated Zernike/Fourier
modes on those channels and preserves all other observed request bits, including
signed zero. Guard commands follow completion; inactive commands receive no
shape contribution. The Offset view displays the adopted shape request, not a
claim of physical device application. Native engineering offsets retain their
old post-completion parameter path. In the current native application the C/B
calibration aliases are fixed startup bindings, not independently editable live
parameters. Other graph owners must replace coupled calibration coherently and
regenerate publication when its selected coordinates change.

[Actual calibrated checks](shapes-20261025/dm-shape-actual-calibration-final-tests.log)
pass 36 assertions: woofer 97/97 editable channels, tweeter 1,412/2,304, and
Classic 212/277. A deliberately amplified guard is completed to 2.7 µm and
clamped to the unchanged 1 µm downstream limit in the
[graph check](shapes-20261025/gpi2-projected-shape-graph.log).
[Algorithm tests](shapes-20261025/gpi2-vdm-shape-unit.log) cover projection,
failure-atomic adoption, reset, aliases and warmed zero heap allocation.
The [native contracts](shapes-20261025/gpi2-shape-final-native-contract.log),
[controller](shapes-20261025/gpi2-shape-controller-tests.log),
[RTC publication](shapes-20261025/gpi2-shape-final-rtc-tests.log), and
[declarations](shapes-20261025/gpi2-shape-final-declaration-tests.log) pass.
The [frozen comparison](shapes-20261025/dm-shape-frozen-artifact-comparison.log)
confirms all 34 checked numerical calibration inputs/receipts remain identical.
No gain, stroke limit or calibration measurement changed. Both instruments pass
[fresh CPU export](shapes-20261025/dm-controlled-shape-final-cold-export.log).
Classic's source is updated generically; its separate live deployment is not.

Demand and clipping feedback now retain bounded four-frame histories and render
the newest observed exact matching pair. Frame identity, values, header and
revision advance together. Stale, invalid, disconnected or reincarnated sources
invalidate the history; an absent intersection still correctly reports
Unavailable. This cannot recover samples dropped before GUI observation.
The same regression [fails before](shapes-20261025/gpi2-gui-feedback-coherence-fail-before.log)
and [passes after](shapes-20261025/gpi2-gui-feedback-coherence-pass-after.log).

Actuator maps and surfaces use the same registered-coordinate fit with padding
for markers, hover and clipping rings, including conservative rotated height
extent. The fit checks cover Classic, GPI, rectangular viewports and pupils
beyond actuator centres, with [fail-before](shapes-20261025/gpi2-gui-fit-fail-before.log)
and [pass-after](shapes-20261025/gpi2-gui-fit-pass-after.log) evidence.
The actuator grid may physically extend beyond the optical pupil; the fit does
not move actuators or change registration to make those boundaries coincide.

Both instruments reference one authoring `colormaps/default.yaml`. Export copies
it into each self-contained application. The restored blue–white–red palette
uses the original muted blue, off-white and orange-red stops, with the same
built-in fallback. Additional Cividis, Plasma, Inferno, Magma, Turbo, Hot and
Copper tables carry source and licence notices. YAML definitions take precedence
over built-ins for maps, surfaces, colour bars and ndarray displays.

[GUI tests](shapes-20261025/gpi2-dm-final-gui-tests.log) pass 629 library tests
(one ignored), 283 binary tests (15 ignored) and 12 integration tests.
[Formatting](shapes-20261025/gpi2-dm-final-gui-format.log),
[native build](shapes-20261025/gpi2-dm-final-gui-build.log),
[WASM check](shapes-20261025/gpi2-dm-final-gui-wasm.log), and
[Clippy](shapes-20261025/gpi2-dm-final-gui-clippy.log) pass with the existing
vendor/deprecation lint allowances. An independent review found an external
signed-zero change could leave an older queued baseline; the same
[regression fails before](shapes-20261025/gpi2-shape-zero-bits-fail-before.log)
and [passes after](shapes-20261025/gpi2-shape-zero-bits-pass-after.log) bitwise
observation comparison. Independent algorithm review left no unresolved finding.
These are software checks, not hardware or deadline qualification.

The immutable [runtime cohort](shapes-20261025/runtime-sources.toml) records
RTC `4cb9b4f`, JFG/FGA `6dd6e84`, AOS `a0c2ee17`, HIL `f5fa45c2`, and
GPI2Sim `a12a6d5a`. GUI source is `eccefb5`; instrument source is `5ae24c8`.

The [native receipt](shapes-20261025/native-shape-qualification.json) records a
CUDA plant, CPU JFG controller and UInt16 `[242, 240]` camera. The model declares
2 kHz while this functional deployment is paced at 10 Hz. The new manager
`4774985dfca6`, invocation `16d89668f72f4f7a8d944e98f1ebc343`, PID 2990499
became active after 11 min 22 s of cold startup, within the unchanged deadline;
the [service timestamps](shapes-20261025/startup-service.txt) are observations,
not a controlled startup benchmark or a causal attribution.

Before any mutation, eight native streams establish the exact declared zero
shape defaults and original engineering FITS baselines. The
[roundtrip](shapes-20261025/native-shape-roundtrip.json) then probes one
controlled physical coordinate per mirror by 4 nm: zero-based woofer 0 and
tweeter 162. Each probe and its exact baseline restore is adopted, with requested
and active generation advancing together. No unknown/rejected outcome or
compensating submission occurs. Physical engineering readbacks remain unchanged.
The [fourteen-stream check](shapes-20261025/native-stream-verification.json)
observes 35–36 distinct sequences per stream. Twelve metadata-bearing streams
share domain `a0000000000000000000000000000000`, generation 1, sequence 2178;
Applied carries headers only. Thirty-two paired Applied samples per mirror
exactly match demanded metres divided by Float32 `1e-6`, with zero error in µm.
Tweeter roles match 1,412 controlled / 304 extrapolated / 588 inactive; woofer's
97 correction roles remain unknown. All four shape/engineering readbacks
match baseline bits, and all owned observers and temporary payloads are removed.

The previous GPI `461ad9bb9189` receives exactly one native Quit. Its
[retirement receipt](shapes-20261025/previous-retirement.json) preserves the
unknown reply and retained service failure. Cleanup completes and the
[process/cgroup audit](shapes-20261025/previous-cleanup-audit.json) confirms
all owners and the manager are absent. The stopped manager alias is removed only
after its target and PID are checked; LoadState is now not-found. This does not
resolve or reclassify the native Quit timeout.

The initial GUI stream check [fails](shapes-20261025/gui-before-waypipe-reconnect.log)
with no GUI nodes while the old waypipe display is stalled. After the operator
reports restarting waypipe, only the GUI is restarted on `wayland-sRK0etWWY9`.
The [final GUI receipt](shapes-20261025/gui-live-verification.json) confirms the
exact new remote, binary SHA-256, three running visible-view observers and no
software-renderer overrides. This is not manual visual acceptance or proof of
hardware rendering. GPI and its GUI are left running. Classic retains PID
2432242 and invocation `e23f5c8b3e5142ccb11311f4d7c27550` throughout.

## Registered JFG deployment and piston analysis — 2026-10-25

The user authorized replacing the validation builds with published JFG packages.
The [installed receipt](registered-20261025/registered-deployment-verification.json)
checks exact native Running status, GUI remote, package hashes and retired owners.
The new CUDA/UInt16 session is `pipewireao-session@b2d0dbc58064.service`, invocation
`a74fdec4dac745d789f33e76ae2dcb40`, manager PID 3232735. GUI PID 3276751 uses the
unchanged accepted display binary SHA-256
`7c0152ffdc718315714abf6bcb437c70c8a18426d71c3dec4720b8a3ef24110a`.
Its Wayland display remains `wayland-sRK0etWWY9`; software-renderer overrides are
absent. Process/remote checks are not a new manual visual or hardware-rendering
qualification. The original GUI state was copied to preserve the layout.

| Package | Installed public version | Exact package tree |
| --- | --- | --- |
| FilterGraphAlgorithms | 0.8.0 | df13ddb0181f81c0e74667fb964ea0e04aadefec |
| JuliaFilterGraph | 0.4.2 | a258b9d1b8cf398a653ade4ac44ddb56c53b99d7 |
| FilterGraphPipeWire | 0.1.7 | 424549653d3ce28e30de84c42be8cc1202edb521 |
| FilterGraphIsland | 0.1.3 | c9d357b7999b63db61070caddb7fb16ff2fbc8ec |

The existing AOS, HIL, calibration and headless RTC package trees remain frozen.
The staged instrument definition, controller, parameter bindings, session and
simulation definition match the preceding application byte for byte; all
calibration assets match too. Neither gains nor atmosphere nor limits changed.
Cold checks pass 242 package/retained-science assertions, the existing 54 native
contract assertions and 3 actual-graph preparation assertions. All 31 startup FITS
bindings load before execution using the registered providers. The new CPU
feedback implementation was already numerically qualified in its JFG release.

Initial Pkg attempts retained private build variants visible through secondary
depot registries; an inherited Project source override also caused a Pkg
`normpath(nothing)` error. Only the task-owned staging environment was affected.
A dedicated registry view with public JFG versions and cache-only secondary depots
resolved the intended four package changes. The final cold checks verify that
all other package source versions/hashes remain unchanged. Failed preparation
logs are retained with the successful final log.

The old exact GPI invocation received one native Quit. Its reply was unknown
again. [Retirement evidence](registered-20261025/previous-retirement.json)
confirms cleanup and absence of the manager and all four owners before starting
its replacement. This does not close the native Quit timeout finding. Foreign
RTC sessions received no lifecycle or configuration requests.

[Read-only fourteen-stream verification](registered-20261025/native-stream-verification.json)
passes coherent acquisition identities, exact role and offset/shape baselines,
and same-sequence demanded-metre/Applied-micrometre conversion. All observers
were retired afterward. In this fresh capture, woofer clips average 4.42/97,
with maximum reconstructed request 1.03018 µm; tweeter clips average 58.57/2304,
with maximum request 1.16765 µm. Every nonzero feedback sample accompanies a
command exactly at its signed Float32 ±1 µm limit. These are finite observations,
not an optical-performance comparison against the earlier atmosphere trajectory.
A final script initially called a calibration-specific compatibility getter,
which rejects this source's `pipewireao.source-control/1` endpoint. Verification
instead uses the public native session Status command and requires Running.
The rejected getter log is retained; no production API was changed.

The user also authorized merging JFG's registered release with its source-channel
work into main, and merging the validated GPI GUI branch into GUI main. JFG main
merge `8889e22` passes 986 focused composition/declaration/source-channel/schema
assertions. Both mains are pushed. Public release tags and registry entries stay
immutable; later source-channel work on main is additional unpublished package
source, not a replacement of the installed package trees listed above.

### Piston and saturation

A [CPU-only saved-frame analysis](registered-20261025/piston-analysis/result.json)
reuses the prior 32-frame annular capture and exact Gaussian mirror prescription.
The [driver](registered-20261025/piston-analysis/measure.jl) records its source,
input hashes and pupil sampling. Its demanded woofer piston-removed RMS samples
reproduce the earlier saved optical analysis exactly.

Before clipping, woofer commands span 2.03387–2.08074 µm per frame. Every retained
frame therefore exceeds the 2 µm interval available between the provisional
limits: even a uniform shift of actuator coefficients cannot eliminate all these
clips. Requested command mean averages 148.09 nm, whereas pupil optical piston
averages 325.47 nm and piston-removed woofer surface RMS averages 1019.67 nm.
Actuator coefficient mean and optical piston are distinct quantities.

The atmosphere zeros full-screen DC but does not center each moving pupil
footprint. The wavefront diagnostic subtracts pupil piston for both displayed
OPD and reported RMS without changing physical commands. Calibration centers
probe OPD to calculate normalization weights and applies relative TSVD; it is
not a universal command-mean constraint. Subtracting actuator mean would change
the finite Gaussian influence-function surface. The measured spans and optical
structure reject an explanation consisting solely of a removable common command
offset. Stronger turbulence can require more stroke, but its contribution versus
allocation remains unresolved without a controlled atmosphere-strength replay.
No numerical correction is justified solely to remove clipping indications.
