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

## Tip/tilt allocation investigation — 2026-10-25

A [read-only capture](tiptilt-20261025/capture.jl) observed the registered live
invocation without reset, parameter changes or lifecycle requests. It received
554 or more frames per stream over at least 55 seconds and retained the final
128 same-sequence stage, woofer, tweeter and mirror constraint-feedback samples
(sequences 52880–53015). The bounded ring contains gaps; this is not a claim of
lossless recording. [Raw samples](tiptilt-20261025/native-samples.json.gz) retain
the exact invocation and contracts. The observer helper is preserved in the
preceding [registered record](registered-20261025/native_observation_helpers.jl).

The [offline optical projection](tiptilt-20261025/inspect-optics.jl) uses the
actual Gaussian influence functions and the 44,456-pixel annular pupil. Its
piston and normalized-pupil ramp coefficients agree with direct mirror-surface
evaluation within 4.4 × 10⁻¹⁷ m for the test commands. These coefficients are
OPD amplitudes, not mechanical stage angles. The
[projection report](tiptilt-20261025/optical-maps-report.json.gz) records the
package paths, zero offsets and identity temporal filters.

The [sample analysis](tiptilt-20261025/analyze-samples.jl) first restores JSON
values to their Float32 wire representation. Both mirrors then pass exact
signed-limit feedback checks. [Results](tiptilt-20261025/sample-analysis.json):

| Quantity | Observed result |
| --- | --- |
| Stage tip coefficient | +486 to +531 nm OPD |
| Stage tilt coefficient | −277 to −213 nm OPD |
| Stage samples at provisional ±1 µm limits | 0 |
| Woofer mean clipped actuators | 2.625 / 97 |
| Tweeter mean clipped actuators | 54.891 / 2304 |
| Woofer requested optical tip/tilt | Mean −270 / −435 nm OPD coefficients |
| Tweeter requested optical tip/tilt | Mean −1262 / −47 nm OPD coefficients |

The calibrated first two woofer command coordinates are removed to numerical
precision (largest recovered tip/tilt coordinate norm below 6.6 × 10⁻⁵ nm).
However, their actuator-space orthogonal complement is not an optical
tip/tilt-free basis: the other modes have nonzero pupil ramp projections.
This is observed leakage between the two definitions, not evidence that stage
subtraction failed. A static counterfactual subtracting the woofer's optical
tip/tilt through its fitted ramp commands increases mean predicted clipped
actuators from 2.625 to 4.391 and mean peak request from 1.010 to 1.273 µm.
It does not establish a closed-loop improvement or justify a production change.

The stage is unsaturated in this window. Optical tip/tilt on the mirrors is
confirmed, but accumulation from reset remains untested by this running-session
capture. It contains no atmosphere or residual OPD measurement. A from-reset
replay with command/adoption alignment and paired atmosphere/residual quantities
is the next discriminator. No gain, pole, anti-windup, atmosphere, limit,
calibration or allocation has been changed.

The subsequent [512-frame CPU replay](tiptilt-20261025/replay-cpu-result.json.gz)
passes with the untouched deployed controller graph, actual startup artifacts
and zero shape offsets. A decoded graph comparison verifies that the shape
seams are the only additions to the calibrated science graph. Frozen-source
and deployed optical graph documents agree after resolution. The
[driver](tiptilt-20261025/replay.jl) reuses the maintained closed-loop
[helper definitions](tiptilt-20261025/gpi2_closed_loop_helpers.jl), removing only
their final selector invocation. Early scratch attempts stopped before stepping
on an authored-graph hash mismatch and a missing wrapper import; the final
checks explicitly account for the shape additions instead of ignoring the
hash difference.

Atmosphere and residual quantities at frame n use command n−1; the command
series records the newly produced command n. The independent optical
tip/tilt sum closes within 9 × 10⁻⁶ nm. After settling, frames 385–512 average
54.94 nm residual RMS against 1112.82 nm uncorrected, with mean clipped counts
2.93 woofer and 29.33 tweeter. This covers only 0.256 s of model time and cannot
rule out slow accumulation. The CPU and CUDA replays do not produce
identical atmospheric realizations from the configured seed; a backend change
is not a controlled replay of the same atmosphere.

The [CUDA replay](tiptilt-20261025/replay-cuda-result.json.gz) completes 65,536
frames, or 32.768 s of model time, with the same deployed controller, parameters
and production optical declaration. Its [driver](tiptilt-20261025/replay-cuda.jl)
records the first 32 startup frames, then one observation every 64 frames, plus
512-frame clipping aggregates from every command. All recorded numerical series
are finite and optical tip/tilt closure remains below 2.1 × 10⁻⁵ nm. Processing
takes 540 s on the shared host; this is not a fixed-rate or deadline test.
The final residual is 55.37 nm RMS.

[Uniform-cadence analysis](tiptilt-20261025/replay-cuda-summary.json), generated
by the [summary script](tiptilt-20261025/summarize-replay.jl), compares equal
8.192 s windows without overweighting the densely recorded startup:

| Mean quantity, OPD | Model 8.192–16.384 s | Model 24.576–32.768 s |
| --- | --- | --- |
| Atmospheric tip coefficient | +626.50 nm | +623.82 nm |
| Summed correction tip coefficient | −619.77 nm | −613.49 nm |
| Stage tip coefficient | +304.35 nm | +543.29 nm |
| Woofer tip coefficient | +6.82 nm | −116.69 nm |
| Tweeter tip coefficient | −930.94 nm | −1040.09 nm |
| Residual wavefront RMS | 59.63 nm | 60.75 nm |
| Mean woofer peak preclip request | 1.01641 µm | 1.01704 µm |
| Mean tweeter peak preclip request | 1.11673 µm | 1.11778 µm |

There is observed opposing redistribution: stage tip gains 238.94 nm while the
mirrors gain an opposing contribution despite little change in mean atmospheric
tip. This is consistent with slow allocation drift, but full latent controller
state was not retained, so it does not establish a nullspace or windup cause.
It also is not an exploding-stroke observation: peak requests and residual
correction remain bounded in this finite run.

Unlike the shorter live window, this trajectory sometimes saturates the stage:
69 of 992 uniform post-settling samples. Saturated samples have stronger mean
atmosphere (1205 versus 991 nm RMS). Mean woofer clip counts are 6.72 versus
6.15 and tweeter counts 53.04 versus 57.65 for saturated versus unsaturated
samples. These associations do not isolate stage saturation as the cause of
mirror clipping. No numerical or live-runtime change follows from this evidence
alone; the projection and anti-windup mapping require separate adjudication.

### Discarded calibration components

The retained full native command/feedback vectors permit an additional
[reconstruction](tiptilt-20261025/native-discarded-subspace.jl) without another
live mutation or optical replay. Requested commands are demanded plus feedback.
With the zero offsets and identity filters, invert the declared woofer basis
after adding back the stage contribution; invert the tweeter completion using
its declared feedback maps. This recovers correction output cₙ, not the
separately named same-frame controller state. Command roundtrip errors are below
0.00125 nm. Absolute reconstructed components assume unchanged offsets and
matrices; contemporaneous parameter readbacks were not part of this five-stream
window. A fixed offset cancels from consecutive differences.

Calibration retains 1445 of 1509 weighted singular directions. If J is its
interaction matrix, R its reconstructor and W the positive diagonal column
normalization, then RJ = W VᵣVᵣᵀ W⁻¹. Thus N = I − RJ is oblique in raw
controller coordinates. Discarded directions have weak nonzero optical
response; they must not be described as exact optical null modes. Coordinate
norms, including norms scaled by W⁻¹, are not physical optical RMS.

The deployed pole and anti-windup gain are both one, so consecutive outputs obey
cₙ − cₙ₋₁ = −bₙ₋₁ − 0.3eₙ, where b is mapped mirror constraint feedback and
e is reconstructed error. Since Ne is small, test NΔc ≈ −Nbₙ₋₁. The
[results](tiptilt-20261025/native-discarded-subspace.json) verify this in 126
consecutive pairs from sequences 52880–53006, excluding the gap to 53015:

- Mean raw-coordinate ‖Nbₙ₋₁‖ is 19.059 nm, versus 0.002574 nm recurrence residual.
- Relative residual is 1.21 × 10⁻⁴; the W⁻¹-scaled result is 6.03 × 10⁻⁵.
- Direction agreement is 0.9999999927. Reversing the feedback sign gives relative
  residual 2.0; using the wrong frame gives 0.867.

This establishes feedback coupling into the discarded calibration subspace
during the captured interval. It does not establish the origin or indefinite
growth of its existing component. Its requested optical tip contributions
average stage +542.7, woofer −369.1 and tweeter −148.5 nm, mostly opposing one
another. The coordinate norm declines in the short window; first/last summaries
also span the unobserved final gap and must not be telescoped through it.

An independent source-and-method review found no sign or unit error and accepts
the local recurrence interpretation. It distinguishes this mechanism from a
harmful defect: the discarded component could help redistribute stroke under
clipping. Projecting feedback to RJb is therefore a diagnostic intervention,
not an automatically justified production correction. With pole one, doing so
on an already-running controller would retain its existing Nc; prevention from
reset does not demonstrate removal of existing state.

### Retained-feedback A/B: rejected as a remedy

One [private CUDA diagnostic](tiptilt-20261025/replay-feedback-projected.jl)
replaces only the next frame's delayed constraint-feedback input by
Float32(Float64(R) × Float64(J)) × b. No state, error, gain, limit, optical
declaration or live setting is changed. It starts from reset and completes
16,384 frames (8.192 s). The original baseline file remains unchanged. The
[comparison](tiptilt-20261025/compare-feedback-projection.jl) uses matching
uniform-cadence samples and full 512-frame clipping windows. All recorded
atmospheric RMS and tip/tilt values are bit-identical at matching observations;
the baseline did not retain full atmospheric-field checksums, so this is not
a full-field bit-identity claim.

The [A/B summary](tiptilt-20261025/feedback-projection-ab-summary.json) reports
the fixed post-settling interval 1.024–8.192 s:

| Quantity | Baseline | Retained feedback |
| --- | --- | --- |
| Mean residual RMS | 59.68 nm | 106.15 nm |
| Maximum sampled residual RMS | 89.28 nm | 351.56 nm |
| Mean woofer peak preclip request | 1.01751 µm | 1.09178 µm |
| Maximum sampled woofer peak preclip request | 1.04373 µm | 1.24409 µm |
| Mean tweeter peak preclip request | 1.11439 µm | 1.10726 µm |
| Mean woofer clipped actuators | 6.285 | 4.869 |
| Mean tweeter clipped actuators | 54.822 | 41.040 |
| Component tip/tilt cancellation metric | 462.60 nm RMS | 82.77 nm RMS |
| Sampled stage saturation | 5.80% | 0% |

The intervention isolates the coupling route: sent discarded-feedback norm is
6.31 × 10⁻⁶ of the raw value, and reconstructed Nc ends at 5.229 nm raw
coordinate norm. Neither is optical RMS; the baseline did not retain matched
full c/b samples. The approximate Float32 projector has relative idempotence
error 3.12 × 10⁻⁶. [Recorded output](tiptilt-20261025/replay-feedback-projected-result.json.gz)
passes optical closure below 1.0 × 10⁻⁵ nm and command reconstruction below
0.00144 nm. Full projected-run c/b samples remain in the diagnostic cache at
the path/hash recorded by the summary.

Adjudication: reject this projection as a production remedy. Fewer clipped
actuators, less opposing allocation and less discarded content coexist with
77.9% worse mean residual RMS and larger woofer excursions. The measured
redistribution is real, but eliminating it is not inherently beneficial. The
current feedback can use weak calibration directions to improve constrained
correction. This finite comparison does not prove a globally optimal allocator
or long-term stability. The live science controller remains unchanged.

## HEART-style hidden-mode removal — 2026-10-25

The deployed GPI integrator has no hidden projection ports. Its zero inherited
`hidden-mode-gain` property does not implement removal. The selected work adds
an opt-in controller using JFG's existing `closed-loop-correction-f32`, with
the original integrator retained as the default comparison. Both use the same
optics, reconstructor, command maps, limits and native endpoints. No live
controller change is authorized by a build or projection identity check alone.

The first explicit policy derives discarded right singular vectors Vd from the
parent calibration's RMS-weighted TSVD. With W = diag(1 / mode_rms), the existing
JFG projection names mean H = VdᵀW⁻¹ (`shape-to-hidden`) and B = WVd
(`hidden-to-shape`). These identify weak discarded directions, not exact optical
nulls. Existing HEART and JFG terminology governs the controller gain,
projection ports and generated mode labels; no new wire vocabulary is needed.

Preparation must verify parent bytes, dimensions, retained rank, reconstructor
agreement, HB ≈ I and projection identities before writing derived artifacts.
The replay must first prove gain-zero equivalence, then compare genuine removal
from the preceding realized shape c−b with matched atmosphere/noise from reset.
Assess residual WFE, hidden components, command excursions and clipping together.
Reject a candidate that merely reduces clips while degrading correction. The
earlier feedback-only projection experiment does not test this algorithm.

Application modes select a generated graph and complete FITS binding set;
the single handwritten graph remains unchanged. A separate allocation policy
can be assessed against this baseline later; it is not claimed implemented or
optimal by adding a profile name.

The [matched replay record](hidden-20261025/RUN.md) now contains three completed
4,096-frame CUDA cases using the genuine JFG correction algorithm. At gain zero,
every graph output matches the original integrator bit-for-bit for every frame.
Recorded full atmospheric-field hashes match after reset across all cases, and
the state/output recurrence checks have zero Float32 error. The shared cold
calibration helper passes 65 checks for projections, stale/invalid inputs,
Float32 tolerance and unchanged parent artifacts.
The two-mode offline export selector passes 27/27 checks, loading the exact FITS
bindings and checking selected RTC/simulator/publication identity consistency.
See [source verification and failed harness attempts](hidden-20261025/VALIDATION.md)
and the [independent review](hidden-20261025/REVIEW.md).

| Hidden-mode gain | Mean residual WFE, frames 2049–4096 | Mean woofer / tweeter clipped actuators |
| --- | ---: | ---: |
| 0 | 66.37 nm | 11.31 / 60.75 |
| 0.1 | 97.77 nm | 8.78 / 38.95 |
| 1 | 148.73 nm | 5.59 / 43.01 |

**Reject enabling this discarded-TSVD removal policy.** Fewer clips and smaller
hidden state do not establish better optical correction. No long extension ran;
the live integrator and science settings are unchanged. The selectable generated
`heart` mode has gain zero. The diagnostic replay independently recomputed its
basis; the exact generated production FITS projector differs by 8.79 × 10⁻⁶
relative in raw coordinates (5.50 × 10⁻⁶ weighted). Those FITS received static
comparison, not positive runtime qualification. The result does not establish
global stability, physical hardware behavior, optimal allocation or 2 kHz timing.
Both failed resource-location setup attempts are retained separately from the
completed scientific results.

## Native shutdown investigation — 2026-10-25

The original Running-to-Quit timeout remains unresolved. Isolated attempts
preserve that distinction:

| Attempt | Configuration and result |
| --- | --- |
| 001 | CPU source-trace overlay; expired during graph preparation before Ready. No Quit request. |
| 002 | Same CPU diagnostic, graph optimization disabled only to investigate cold preparation; failed before Ready. No Quit request. |
| 003 | Original registered CUDA packages, native Lua phase tracing, diagnostic placement on separate physical cores; clean Ready-to-Quit in 3.459886 s. |
| 004 | Original registered CUDA packages, intended Running-to-Quit; bootstrap monitor initialization expired before Ready. No Start or Quit request. |
| 005 | Patched bootstrap monitor preparation, original CUDA science/packages, simulator compiler tracing; Ready-to-Running-to-Quit passes after 52 frames, with successful owned cleanup. |

All dedicated processes were retired. The live GPI RTC and GUI received no
lifecycle or parameter requests. Attempts 001/002 and their limitations are in
the [initial record](shutdown-20261025/INVESTIGATION.txt) and
[second record](shutdown-20261025/INVESTIGATION-V2.txt). The
[Ready-to-Quit receipt](shutdown-20261025/trial-003-receipt.json) confirms
accepted terminal completion and cleanup. Its original diagnostic driver has
soft-scope warnings, and the orchestrator was briefly paused during startup;
neither is a production change or a qualified timing environment.

The [CPU profile summary](shutdown-20261025/trial-003-perf-summary.txt) records
source shutdown request-to-acknowledgement in 2.325715 s. Of 227 CPU samples in
that source phase, 123 include LLVM and 48 include Julia compiler frames
(overlapping counts). The Ready baseline has none. Thus compilation is a
material observed CPU contributor during shutdown. Sampling cannot apportion
wall time or prove the cause of the earlier timeout. Missing JIT map symbols
prevent attribution to a specific cleanup method; the initial assumption that
Julia necessarily created and deleted a map was incorrect. No environment
profiling listener was enabled in that process.

The [Running attempt](shutdown-20261025/INVESTIGATION-RUNNING.txt) instead
reached the bootstrap constructor's five-second monitor-start deadline, followed
by failed-start cleanup warnings and an abort. Its
[receipt](shutdown-20261025/trial-004-receipt.json) and
[final service identities](shutdown-20261025/trial-004-final-owned-units.json)
retain the failure and confirmed retirement. It is a separate startup failure,
not evidence that Quit failed again. Both the native session effect deadline
and owner initialization deadline remain unchanged.

Fresh-process private-core [compilation probes](shutdown-20261025/bootstrap/probe-summary.json)
show 1.55–1.66 s of first-use compilation for the bootstrap monitor. These
probes all started successfully; they do not reproduce attempt 004 or establish
the original Quit cause. The runtime now explicitly compiles the concrete
monitor entry point before spawning it and starting the unchanged five-second
thread-start clock. Compilation runs inside the existing cleanup scope and
does not execute monitor authority or remove the actual thread-start check.

The patched fresh constructor reports `monitor_ready=true` in 2.399 s total,
including transport setup and preparation outside the monitor clock. The
unchanged native bootstrap selector passes [49/49 checks](shutdown-20261025/bootstrap/lifecycle.log),
including blocked-main responsiveness, Quit cleanup, Fault and controller
loss/expiry. The [validation summary](shutdown-20261025/bootstrap/patched-summary.json)
records source and selector hashes. These are source-override software checks,
not production timing qualification.

The [patched Running-to-Quit receipt](shutdown-20261025/trial-005-receipt.json)
confirms fresh Ready, Start, Running for at least five seconds, one accepted
Quit and a stopped source report with sequence 52 and no failures. All five
services are inactive with successful results, no remaining PIDs and empty
[saved cgroups](shutdown-20261025/trial-005-final-owned-units.json). The 137 frozen
source/configuration files remained unchanged throughout the test. Original
science files, calibration, Project and Manifest were preserved; the diagnostic
RTC source override and separate-core placement limit comparison with the live
registered deployment.

Native Quit effects took 3.225139 s, including 1.970939 s from source shutdown
request to the next owner. The [compiler/phase analysis](shutdown-20261025/trial-005-phase-compile-analysis.json.gz)
directly records 1334.6 ms compiling the concrete two-argument
`OpticalObservation.close!(observation, pipewire)` call during this interval.
Its 117,082-character signature was reassembled from three journal chunks and
parsed successfully; no incomplete fragments remain. This identifies avoidable
first-use work during successful cleanup, without establishing the original
timeout cause or an equivalent wall-time saving.

The runtime now prepares that exact cleanup specialization after optical
warming and before admission, without executing cleanup or changing its order
or deadline. The corrected fresh private-core CUDA check passes
[41/41 checks](shutdown-20261025/optical-cleanup/validation-summary.json):
compilation preserves the actual worker, snapshots and native resources; the
worker publishes another observation; actual cleanup joins it and closes
snapshots and transport. A fresh public core roundtrip succeeds afterward.
The disabled-observation branch also passes, and the owned private core exits.
The concrete optical cleanup entry does not compile again during actual close.
Enabled cleanup still compiles lower-level HIL methods for 0.640 s and takes
0.673 s overall; this is not a zero-compilation shutdown claim or a measured
full-session speedup. An initial test-script import error is explicitly retained
as a failed harness run. See [commands and limits](shutdown-20261025/optical-cleanup/RESULTS.md).
Independent source review found no blocker. No full native session was rerun
after this second preparation change, and the live deployment has not changed.
