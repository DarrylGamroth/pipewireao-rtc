# Optional analysis metadata preservation — 2026-11-02

RTC source baseline `7dd959e`, following the upstream 0.4.1 merge and the
separate optical clock/analysis constructor repairs. Worktree was clean before
this focused change.

## Observed failure and source cause

The parent's private live optional WFS analysis unit failed with
`InvalidStateException: output cannot preserve required source metadata` while
the required RTC and detector observations continued. No live buffer metadata
was captured by this source investigation.

RTC `run_analysis_graph` did not declare `input_metadata` or `output_metadata`.
FilterGraphPipeWire defaults those declarations to Header-only. The summary
Algorithm declares `metadata_from=:slopes`, so its output must preserve the
source facts. Its native callback correctly rejects a source record tuple that
cannot fit in the output's negotiated slots.

The discriminating native-buffer test establishes this source defect without
using a core or service: the actual RTC Node has empty additional output
requirements, all input facts are valid, and `metadata_fits(output, source)`
is false. The real callback then throws the same metadata-preservation error.
This demonstrates the missing declaration as a sufficient cause; the subsequent
managed deployment still owns confirmation of the complete live path.

## Repair and validation boundary

Node preparation now uses `Common.telemetry_metadata_ports` for inputs and
outputs, matching the existing RTC main Graph and calibration owners. Required
scientific facts still come from `FilterGraphPipeWire.required_input_metadata`.
The constructor is extracted as `prepare_analysis_node` so the test exercises
the production declaration policy. Acquisition matching, source provenance,
optional-observer policy, explicit capture behavior and owner validation remain
intact. There is no fallback to unmatched inputs or dropped facts.

The test uses real small CPU Shack-Hartmann summary Algorithms and native
callback buffers. Input facts include acquisition identity, exposure timing,
absolute acquisition time, optical classification and electrical trigger state.
The output storage follows the actual Node's declared requirements. The test
checks the scientific summary, output availability, Header and all five facts.

Julia 1.13.3; source RTC 0.4.1, registered HIL 0.4.1, AOS 0.3.18,
FilterGraphPipeWire 0.3.0, JuliaFilterGraph 0.6.0, FilterGraphAlgorithms 0.10.0,
PipeWireAO 0.8.0/native 3.0.0. The private copied environment and source override
are described in the [merged-cohort record](../analysis-construction-20261102/README.md#upstream-041-merge).

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env test/analysis_metadata.jl
```

Before declaring profiles: two prerequisites pass, output-profile and capacity
checks fail, and the real callback throws the exact metadata-preservation error.
After declaring profiles: **12/12 pass**, exit 0. The first post-repair callback
preserved all five facts; the new test needed an explicit row-major boundary
and a corrected native-struct flag read before this final verification.

Compatibility checks run in isolated modules in a fresh process:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env -e '
module StatisticsChecks; include("test/analysis_statistics.jl"); end
module CaptureChecks; include("test/test_analysis_capture.jl"); end
module ConstructorChecks; include("test/analysis_synchronized_inputs.jl"); end'
```

All **169 assertions pass**: statistics 51, capture 115 and synchronized
construction 3. Statistics adds two production-constructor checks that finite
capture retains its ordinary single-input owner and exact prepared callback;
all existing numerical, rejection, provenance and allocation checks remain.
Together with the native-buffer regression, this is **181 passing assertions**.
Final source/test review, local evidence links and `git diff --check` pass.

The selectors above modify no core, service, device, sibling source or parent
live session. Native-buffer evidence alone does not qualify actual negotiated
live publication, managed startup, hardware or timing.

## Managed CPU integration

A separate parent integration run uses source `85851c8` with upstream RTC/HIL
0.4.1, PipeWireAO 0.8.0 and native/JLL 3.0.0. The private unpublished immutable
validation version is `0.4.1+rtc39.20261102.3`, tree
`5d1a69c241a323819410725381d5cec1ae9b4a31`; its production analysis source has
SHA-256 `42cdb7e9dff5614aa90b3cfb6f7c9e6afdd39edf3b856a733da20a4ad30aa100`,
identical to this fix. The SDK native library matches the registered artifact:
`78673c46f7875421531dcb7391a5e6f8b1d1e6b0de0b892cb2a2a3f664fab76a`.

The sealed Classic CPU application reaches Ready and Running through
`SessionRuntime.start!` and the public native Start. The optional owner reports
`PIPEWIREAO_ANALYSIS_READY name=rtc-wfs-analysis links=4` and remains running.
The production native observer receives eight finite eight-element summaries;
a fresh WASM browser receives advancing summaries in all fifteen one-second
samples, publication sequence 1101–1244, without page or protocol errors.
These observations establish negotiated publication in addition to the callback
checks above. Initial browser attachment before optional-owner preparation
exposed a separate GUI recovery policy gap; the GUI repair creates fresh,
verified read-only leases and does not gate required RTC readiness.

Exactly one browser simulator rebuild changes only `atmosphere.L0` from 30 to 31.
The job completes from UUID `d0a2477b-48d5-4faf-8fed-50ad9cc1c7d9` to
`f8f1ba75-84e9-4615-836e-d5ac47776b28`; old RTC loss is observed before one
explicit Reconnect. Fresh native verification, cleared engineering opt-in,
advancing detector data and exact persisted settings pass. The owner resumes
Running. No unknown mutation or rebuild is retried. The preceding private
sessions shut down through the public owner interface with cleanup confirmed.

These are software/application checks of a non-actuating CPU fixture. They do
not qualify physical hardware, TAI clock authority, real-time deadlines or the
upstream external-sensor elected-driver change. Raw logs, screenshots and copied
applications are temporary; this summary and the GUI module validation record
retain the outcome and source identity.

## Final RTC 0.4.3 source integration

Merge `db1eadc` incorporates origin/main
`37fb818e00b06ce11ec77f71a031bd92ea7d6019` without conflicts. The analysis and
optical-observation source files retain their pre-merge SHA-256 identities
`42cdb7e9dff5614aa90b3cfb6f7c9e6afdd39edf3b856a733da20a4ad30aa100` and
`e08cee42328362fa6c6b41a3fd35c80275ac8174680759d1cc6c1510d0007da6`.
Upstream coupled-recovery code, external-sensor pool defaults, generated
Manifest and version changes are merged unchanged.

Only the private copied test environment is updated through public `Pkg.compat`,
targeted `Pkg.add(...; preserve=Pkg.PRESERVE_ALL)` and `Pkg.resolve`: source RTC
0.4.3, registered FilterGraphAlgorithms 0.10.1 and FilterGraphPipeWire 0.3.1.
HIL remains 0.4.1; AOS 0.3.18, JFG 0.6.0, FilterGraphIsland 0.3.0,
PipeWireAO 0.8.0/native 3.0.0 and calibration 0.17.3 remain unchanged. The
resolved private Manifest SHA-256 is
`d94107d8e5a48b0821b51343c36ad42ae9b5a85da770ffdbfb5ef738852df6a7`.

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env -e '
module OpticalClockChecks; include("test/test_session_configuration_integration.jl"); end
module MetadataChecks; include("test/analysis_metadata.jl"); end
module ConstructorChecks; include("test/analysis_synchronized_inputs.jl"); end
module StatisticsChecks; include("test/analysis_statistics.jl"); end
module CaptureChecks; include("test/test_analysis_capture.jl"); end'
```

These focused CPU source checks do not qualify the newly merged coupled recovery
or optical pool behavior. The preceding managed GUI/WFS/rebuild evidence remains
specific to its RTC 0.4.1 application cohort; no RTC 0.4.3 live fixture is claimed.

The RTC 0.4.3 run completed before the requested pause: **267 assertions pass**
(clock/integration 86, native metadata 12, constructor 3, statistics 51, capture
115), with **one host-verified TAI check skipped** and exit status 0. The worktree
and running-check results were preserved during the pause; no additional work
was performed until the user resumed integration.
