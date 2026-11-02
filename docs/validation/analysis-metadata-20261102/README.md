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

No core, service, device, sibling source or parent live session is modified.
Native-buffer evidence does not qualify actual negotiated live publication,
managed startup, hardware or timing.
