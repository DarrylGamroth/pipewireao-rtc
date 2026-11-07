# RTC migration to FilterGraphs 0.10

Date: 2026-11-07. Baseline: `0048cfc41f7605d125ffcdda05479b40a0e68e18`,
branch `codex/filtergraphs-010-20261107`, worktree `pipewireao-rtc-fg010`.
The source worktree was clean; the original checkout and cleanup branch are
preserved. Verification is in progress.

## Change and ownership

RTC 0.7.1 selects FilterGraphs 0.10 instead of 0.9. Comparison of the published
graph versions shows the existing CPU preparation, format, metadata, processing
and reset implementations unchanged. Version 0.10 adds controller preparation
and execution APIs. RTC continues to use its existing public graph interfaces;
this migration does not opt into early controller publication. An independent
read-only API review confirms this boundary.

FilterGraphPipeWire 0.5.2 already accepts both graph versions. AOS 0.3.21 and
HIL 0.5.0 do not depend on FilterGraphs and need no metadata or implementation
changes. Calibration graphs, native admission, the single MediaSession
authority, Hsm/clock conventions, message-owned calibration workers, generic
capture and dependency-only exports remain as implemented by the cleanup.

## Selected cohort and evidence reuse

| Package | Version |
| --- | --- |
| PipeWireAORTC | 0.7.1 candidate |
| FilterGraphs | 0.10.0 |
| FilterGraphAlgorithms | 0.12.0 |
| FilterGraphPipeWire | 0.5.2 |
| PipeWireAO | 0.9.2 |
| PipeWireAO_jll / native SDK | 4.0.2+0 / 4.0.2 |
| AdaptiveOpticsSim | 0.3.21 |
| AdaptiveOpticsSimPipeWireHIL | 0.5.0 |
| AdaptiveOpticsCalibration | 0.17.3 |

Except for RTC, packages resolve from the public registry without source
overrides. RTC 0.7.1 has no release tag or shared-registry entry: cold installation
uses a temporary candidate registry containing commit `650871a`, tree
`a8e6530bb07d2c475228960979b2ea03f56d5300`, from the canonical public repository.
The shared registry and existing immutable releases are unchanged.
The [previous release receipt](../rtc-cohort-402-20261106/README.md)
provides full native/artifact, PipeWireAO, FGA and AOS CPU gates on the same
immutable sources and artifacts. Those unchanged package gates are reused;
graph-engine, adapter and affected RTC integration gates are rerun on 0.10.
The independently published controller release's CPU/CUDA evidence is retained
in its [release receipt](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/blob/853bba9/docs/validation/controller-release-20261107/README.md).

## Verification

| Gate | Result |
| --- | --- |
| FilterGraphs complete CPU suite | 23,459 assertions; pass |
| RTC complete core suite | 11,049 assertions; pass |
| RTC calibration worker / private core | 206 assertions; pass |
| RTC named-command transport / private core | 133 assertions; pass |
| RTC capture publication / private core | 173 assertions; pass |
| Documentation structure, links and requirement IDs | 713 assertions; pass |
| Captured physical/chopped optical calibration, CPU | 47 assertions; pass after correcting test data |
| Fresh candidate consumer integrity and extensions | 45 assertions; pass |
| Full adapter and cold installation | In progress |

The development core manifest is regenerated with `Pkg.resolve()` and
`Pkg.instantiate()`. It does not load optional science packages. The separate
cohort environment explicitly pins all selected versions, develops only RTC,
and includes the existing test dependencies and Proper CPU backend.

Core command:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/runtests.jl")'
```

The graph-engine and adapter suites run from their registered package source
with `--threads=4,0` and the cohort project. Private-core worker selectors use
their documented interactive-thread layout. Science selectors use CPU
preparation and do not load an accelerator backend. Logs are retained under
`/tmp/rtc-fg010-*-20261107.log`; results will be recorded after completion.

No deployed application is replaced or started. Software tests do not establish
physical-device, cadence, latency or real-time deadline qualification.

## Corrected test setup

The original optional `test/captured_optical_calibration.jl` selector stopped with
one passing assertion and a `KeyError("selected_pixel_count")`. Its hand-built
publication plan omitted the selected-pixel dimension and per-branch frame
contract required by `optical_chopped_template`. The same incomplete dimensions
reproduce that exception on the published RTC 0.7.0 / FilterGraphs 0.9 cohort,
before graph preparation. This is an existing test-data defect, not a 0.10
execution regression.

The test now declares the full image shape, its derived pixel count, and the
existing `test.relative-image/1` frame schema. The same shape supplies the
template and calibration mask. The unchanged Float32/Float64 numerical and
held-out checks then pass all 47 assertions; no production implementation,
coefficient, tolerance or expected numerical result changes. Repository
formatting also passes. The original failure, baseline reproduction and passing
rerun logs are retained as `/tmp/rtc-fg010-captured_optical_calibration-20261107.log`,
`/tmp/rtc-fg010-captured-calibration-baseline-20261107.log` and
`/tmp/rtc-fg010-captured_optical_calibration-after-20261107.log`.
