# RTC three-package graph cohort — 2026-11-06

This record covers the RTC source migration to PipeWireAORTC 0.6.0,
FilterGraphAlgorithms 0.12.0, FilterGraphs 0.9.0 and FilterGraphPipeWire 0.5.0.
FilterGraphs uses UUID `8053475d-7091-4a8a-adbc-8ed688b6da8d`; the retained
algorithm and PipeWire packages retain their UUIDs. The standalone
`filtergraph-island` command retains its name.

## Source and environment

RTC started clean at `4658e7f676c538df01c919b4902c9df25a63a105`. Work used
branch `migrate-three-packages` in the dedicated sibling worktree
`pipewireao-rtc-three-packages`. The original checkout and its processes were
preserved. Validation used Julia 1.13.3 and isolated task environments; the graph
environment developed the three graph packages from the sibling
`JuliaFilterGraph-three-packages` worktree. These are source-validation results,
not registered-package or installed-application acceptance.

Both environments selected registered PipeWireAO 0.9.1 and
PipeWireAO_jll 4.0.1+0. The native prefix was selected from
`PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir`. No SDK/JLL source develop,
product preference or artifact override was added. Registered scientific
providers were AdaptiveOpticsSim 0.3.19, AdaptiveOpticsSimPipeWireHIL 0.5.0 and
AdaptiveOpticsCalibration 0.17.3. Their dependency/source inventory contains no
legacy graph-core or Island dependency requiring a provider migration.

## Changed boundaries

RTC weak dependencies and extension triggers select the three current graph
packages. Programmatic preparation passes a graph path and typed keyword
arguments directly. CLI owners still parse their launcher arguments, select
Algorithm providers and forward row-worker placement, matrix layout, raw startup
parameters, FITS startup arrays and capture selection to the shared API.
Composition owners retain rejection of separately declared feedback.

Scientific configurations, numerical coefficients, native protocol identities,
requirement meanings, frozen receipts and generated instrument exports were not
changed. The tracked RTC Manifest was regenerated through Julia Pkg; SDK/JLL
versions and RTC version/extension metadata changed without unrelated upgrades.

## Observed checks

| Selector | Result |
| --- | --- |
| `test/runtests.jl` in the isolated core environment | 8,528 assertions in 376 testset summaries passed |
| `test/test_package.jl` after the final 0.6.0 version change | 409 assertions passed |
| `test/test_graph_owner_integration.jl` | 25 testset assertions and 3 top-level checks passed |
| Analysis/correction selectors below | 187 assertions passed |
| Calibration/export/schema/loading selectors below | 203 assertions passed |
| Julia syntax, dependency/extension metadata and `git diff --check` | Passed |

The core suite preceded the final version-only metadata change; the package
export selector was rerun afterwards. The core suite's missing-Git-object
rejection emitted its expected diagnostic. No test warning or unexpected test
failure remained.

Analysis/correction selectors were `analysis_synchronized_inputs.jl`,
`analysis_metadata.jl`, `analysis_links.jl`, `analysis_statistics.jl`,
`test_correction_loop_control.jl` and `test_correction_observer.jl` under `test/`.
Calibration selectors were `calibrated_graph_exports.jl`,
`calibration_named_commands.jl`, `reference_stage_cleanup.jl`,
`session_graph_schema.jl` and `test_session_configuration_integration.jl`.
Each batch included its files in separate Julia modules, using three default
threads and no interactive thread (`--threads=3,0`).

The analysis batch first failed in the existing `analysis_native_buffer` helper:
SDK 4's generated `pw_ndarray_filter_buffer` has explicit fields and no
single-tuple constructor. The helper also referenced retired inline Header
metadata fields. The corrected helper uses the current `MetadataSnapshot`
descriptor API already exercised by `analysis_metadata.jl`. The same analysis
batch then passed all 187 assertions, including unchanged Header propagation
and numerical output checks. No production fallback was added.

To reproduce, resolve the test-project dependencies in an isolated environment,
develop this RTC and the three selected graph sources, and add the exact
registered scientific providers above. Select the native prefix explicitly:

```julia
using PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
include("test/runtests.jl")
```

Run the optional selectors in fresh processes with their scientific environment;
the owner integration selector must start before graph packages are imported.
The core environment must not load optional scientific packages.

## Limits

No RTC service, native core, GPU owner, hardware experiment or instrument export
was started or replaced. CPU preparation and native-buffer callback checks do
not establish installed lifecycle acceptance, hardware correctness, cadence,
latency or deadlines. Existing dated evidence retains its original dependency
scope. Custom-registry publication and installed-application qualification are
separate coordinated gates.
