# Optional synchronized analysis construction — 2026-11-02

RTC baseline `837fa60e63f38f92d0f7ea65f20ecefbcf744f91`, isolated branch
`codex/rtc39-optical-clock`, clean before this repair. This record addresses
[RTC issue #40](https://github.com/DarrylGamroth/pipewireao-rtc/issues/40).

## Observed defect and repair

Ordinary WFS analysis uses acquisition-matched `PreparedSynchronizedInputs` for
its slopes, flux and validity inputs. `run_analysis_graph` unconditionally
passed `frame_observer=capture`, including when `capture === nothing`. The
FilterGraphPipeWire 0.3 synchronized Node constructor rejects this keyword,
preventing optional analysis from starting; the required RTC remains independent.

The repair omits the observer keyword when capture is absent. Explicit finite
capture still receives its original `frame_observer=capture` keyword. Input
synchronization, capture admission, science and lifecycle semantics are unchanged;
there is no fallback to unmatched ordinary inputs.

## Source validation

Julia 1.13.3, registered FilterGraphPipeWire 0.3.0, JuliaFilterGraph 0.6.0 and
FilterGraphAlgorithms 0.10.0; private copied science environment described in
the [preceding clock record](../optical-observation-clock-20261102/README.md).
The environment's only source override is this RTC worktree via `Pkg.develop`.
Run from the RTC worktree:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env test/analysis_synchronized_inputs.jl
```

The test prepares the real small CPU `shack-hartmann-summary-f32` graph and
checks its three-input synchronized owner. It invokes the production
`run_analysis_graph` path with a unique absent private socket: the expected
native `pw_ndarray_filter_connect` error proves the real Node constructor has
succeeded, without opening a server or modifying an installed session.

The identical test fails before the repair (two prerequisites pass, constructor
gate fails) and passes afterward (**3/3**, exit 0). The existing selectors also
pass in this environment:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env test/analysis_statistics.jl
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env test/test_analysis_capture.jl
```

Statistics passes **49/49**, covering actual CPU statistics, finite capture
callbacks, warmed callback allocation and typed FITS preparation. Capture passes
**115/115**, covering admission, immutable snapshots, artifacts, mixed/incomplete
acquisition rejection and provenance. Neither selector's assertions were changed.
Final source/test review, changed local Markdown links and `git diff --check`
pass. The production diff contains only conditional observer-keyword omission.

This is constructor/dispatch software evidence, not managed readiness, WFS
publication, captured-acquisition, hardware or timing qualification. No running
core, service, instrument or GUI session is touched.

## Upstream 0.4.1 merge

Merge `38615d48f47c4dd52c99e151dfb458266a8260c5` incorporates origin/main
`778a7e2033604d430efd2726ac0f1800638b1629` without conflicts, preserving the
separate clock repair `837fa60` and analysis repair `8c28b72`. The upstream
Project/version and external-pupil publication changes are unmodified.

The private copied environment now selects source RTC 0.4.1 and registered
HIL 0.4.1 via `Pkg.compat`, a targeted `Pkg.add` with `PRESERVE_ALL`, and
`Pkg.resolve`; all other recorded exact cohort selections remain unchanged.
The original generated application environment is untouched.

The four selectors run in separate modules in one fresh process to reuse
compilation while isolating their test globals:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env -e '
module OpticalClockChecks; include("test/test_session_configuration_integration.jl"); end
module SynchronizedAnalysisChecks; include("test/analysis_synchronized_inputs.jl"); end
module StatisticsChecks; include("test/analysis_statistics.jl"); end
module CaptureChecks; include("test/test_analysis_capture.jl"); end'
```

The merged-cohort run passes **253 assertions** (clock/integration 86,
synchronized analysis 3, statistics 49, capture 115), with the same **one TAI
check skipped** because the shared constructor cannot verify this host's offset.
Exit status is 0; no assertions or production changes were added to accommodate
the merge. The resolved private Manifest SHA-256 is
`e4c730608215c8fd4ef47bb09db367e91cf17ae9b8fd7f112ba195e092856d31`.

These checks do not exercise the upstream external-sensor elected-driver
publication path, qualify managed readiness on HIL 0.4.1, or supersede any
separate live receipt from the earlier private 0.4.0 cohort.
