# Shared endpoint resources — 2026-11-06

Baseline: clean `2af5ac1`, branch `codex/julia-session-policy-20261104`, dedicated
worktree `pipewireao-rtc-cleanup`. The user selected NEC-03 from the package scope
review and asked for further removal candidates. No unrelated edits were present.

## Removed duplication

`ControlEndpoint.Transport` now owns the shared ThreadLoop, Context, Core,
Endpoint, registry listener, Core acknowledgement and atomic wake hint. Its
constructor, partial-failure cleanup, close and terminal synchronization replace
the copies in bootstrap and acquisition. The change removes 183 physical source
lines overall, including comments/docstrings, and deletes the acquisition runtime
file. No service framework or additional coordinator is introduced.

The removed `AcquisitionLifecycleRuntime` had two test callers in this repository;
production calibration constructs a borrowed `ControlEndpoint.Endpoint` on its
existing loop in `ext/calibration_owner.jl`. Those test owners now use the common
transport. Bootstrap retains its Hsm/Agent monitor, message ownership, connection
hooks and controller-retirement policy; its private resource type and redundant
poll/take/state/completion wrappers are removed.

## Interface and lifetime decisions

| Interface | Meaning and authority | Migration |
| --- | --- | --- |
| `ControlEndpoint.Transport` | Established transport/resource ownership from the two former runtimes; public PipeWireAO loop, Context, Core and endpoint APIs | Supply the profile and initial lifecycle. Caller owns `close`. Existing-loop users keep the borrowed Endpoint constructor. |
| `ControlClient.command_type(profile)` | Bounded request type, following the existing profile `lifecycle_type`/`completion_type` interface | Bootstrap declares its three-command union; acquisition declares its six-command union. No concrete-profile checks in the resource implementation. |
| `ControlEndpoint.complete!` / `flush_terminal!` | Existing completion and publication-synchronization operations | Common transport overloads encode through the existing profile codecs. Remove the acquisition module and bootstrap's exported `flush_terminal!` binding without compatibility wrappers. |

Lifecycle updates use `ControlEndpoint.state!(transport.endpoint, state)`, whose
handler still owns the endpoint state. Scientific effects remain outside native
callbacks and dispatch. No wire identities, POD shapes or lifecycle IDs change.

Acquisition-style `poll!`/`take!` consume the old wake hint before refreshing the
endpoint under the ThreadLoop lock. Bootstrap consumes it once in `_poll_ready!`,
checks quiet health/pending state, then calls the underlying Endpoint operations
without clearing it again. A callback's newly published hint must survive that
cycle. The native lock still serializes endpoint state and Core acknowledgement;
the atomic flag is a notification hint, not a shared scientific-state channel.

Terminal synchronization retains the original absolute signed deadline and a
fresh clock sample under the native lock before submission and each observation.
Registry-listener release precedes endpoint/core/context destruction; loop close
is attempted even after other cleanup errors, with the primary error preserved.

## Verified gates

Julia 1.13.3, unchanged dependency environments. All final processes exit 0:

| Gate | Passing assertions | Log under `/tmp/` |
| --- | ---: | --- |
| Bootstrap/acquisition codecs and representation dispatch | 330 | `rtc-endpoint-focused-final-20261106.log` |
| Package API/load and runtime export/provenance | 492 | `rtc-endpoint-package-export-20261106.log` |
| Native bootstrap preparation/connect/cancel/terminal cleanup | 51 | `rtc-endpoint-bootstrap-final-20261106.log` |
| Both acquisition lifecycle profiles, expiry/removal/terminal fence | 74 | `rtc-endpoint-acquisition-20261106.log` |
| Native endpoint admission/controller/publication faults | 151 | `rtc-endpoint-faults-final-20261106.log` |
| Native endpoint protocol and terminal release | 112 | `rtc-endpoint-native-20261106.log` |
| Bootstrap idle/wake behavior | 12 | `rtc-endpoint-idle-20261106.log` |
| MediaSession initial acquisition Hold/cold Shutdown | 35 | `rtc-endpoint-session-acquisition-20261106.log` |

The bootstrap idle selector reports 0 B for both warmed connected measurement
windows, direct poll, cancellation and preparation checks; the acquisition
selector retains 0 B for its idle wake/service checks. These are the existing
scoped allocation oracles, not transport-latency or RT qualification.

Private-core selectors use the existing optional environment
`/tmp/pipewireao-rtc-optical-types-env` and explicit
`PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104`. Bootstrap
uses `--threads=2,0`; MediaSession acquisition uses `--threads=1,0`. For selectors
importing Clocks or ThreadPinning directly, the command stacks the RTC package
environment with `push!(LOAD_PATH, pwd())` before including the test. No environment
or manifest is modified. Each selector owns and closes only its private core.

Initial harness attempts failed before the relevant tests: a bare test module
lacked `include`, and the optional environment did not directly expose
ThreadPinning/Clocks. The corrected commands use ordinary Julia modules and the
stacked RTC environment. Original logs remain `rtc-endpoint-focused-20261106.log`,
`rtc-endpoint-bootstrap-20261106.log`, and `rtc-endpoint-faults-20261106.log`.

An independent read-only source review found no blocking defects in constructor
cleanup, wake ownership, Core-error propagation, fresh deadline checks or codec
dispatch. The existing JuliaFormatter 2.14.8 harness verifies formatting,
syntax/literal preservation and idempotence. Documentation checks pass 582
assertions for local targets, requirement identities, fences and whitespace;
they preserve the existing retired Rust-test link in the roadmap. A missing
RTC-DEV-030 reference in the draft helper guide was restored before committing.
The broad core suite from the prior
journal changeset is not represented as rerun for this slice; affected selectors
above provide the new evidence. No installed application or live service changes.

## Next removals, with prerequisites

1. **NEC-05: deployment test payload.** `ScienceExport.RUNTIME_ENTRIES` still copies
   `test/`; the validator explicitly requires its project and runner. Root
   `Project.toml` declares that workspace, so derive a runtime environment closure
   and change exporter, validator and source-provenance handling together. Verify
   cold package resolution, export, install and relocation. Keep development tests
   in the source repository.
2. **NEC-01: scientific implementations in RTC.** The detector layout node and
   influence interpolation have current callers. Transfer their calculations and
   numerical/reset/capture tests to the scientific package, preserve configured
   contracts, then delete the RTC copies. The influence transfer can remove RTC's
   direct Interpolations dependency; path/hash/admission checks remain necessary.
3. **NEC-02: Classic capture product.** Its fixed geometry, manifest writer and
   reader need an instrument-owned receiving API and schema tests before removing
   the shared-package implementation. Keep generic transport/acquisition admission.

A bounded independent follow-up confirmed those callers and prerequisite gaps.
It found no additional major implementation proven safely dead. NEC-04 is already
superseded by the journal removal, not a remaining schema-consolidation task.
