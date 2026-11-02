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
