# Julia package cleanup review — 2026-11-04

## Scope and source

Source: `4658e7f676c538df01c919b4902c9df25a63a105`, `main`, three
commits ahead of `origin/main`, with no tracked or untracked changes reported
by `git status --short --branch` at review start. Work is isolated on
`codex/package-cleanup-20261104` in the sibling `pipewireao-rtc-cleanup`
worktree. The existing local manifest was copied without resolving or updating
dependencies. Existing applications, services and other worktrees are outside
this review's mutation scope.

The review covered package organization, declared public documentation,
`Any` storage, type-based branching, dependency placement and relevant callers
and tests in `src/`, `ext/` and `test/`. A mechanical scan of 134 source files
was used for triage, followed by contextual inspection. Its hotspot counts are
not defect counts. This is a source/package-quality review, not a numerical,
allocation, latency or hardware qualification.

## Findings and disposition

### PKG-01 — Retained calibration evidence aliases mutable data

Severity: medium. Confidence: confirmed by regression tests. Disposition: fixed.

Affected code: `CalibrationActionClient._record!` in
[`calibration_action_client.jl`](../../../src/control/calibration_action_client.jl)
and `CalibrationCLI.record!` / `observe!` in
[`calibration_cli.jl`](../../../src/calibration_cli.jl).

The client retained a caller's dictionary request, including nested arrays.
Typed action/result document adapters also retained figure and measurement
arrays. The CLI deferred writing these objects until finalization. Mutating
the submitted dictionary, action figure or returned result after completion
therefore changed the record of an already completed operation.

Both journals now take an owned deep snapshot at the retention boundary.
Document adapters retain their existing shapes and borrowing behavior; the
journal owns the lifetime guarantee. Record vectors now store
`Dict{String,Any}` entries rather than unrestricted `Any` entries. The action
client's direct test constructors were updated to that internal storage contract.
Native records and saved document fields remain unchanged. The separate API
migration below changes Julia module names.

Required verification: mutate both dictionary and typed requests, returned
figures, response values and exposure vectors; check retained records and final
JSON-lines output. Before the fix, the new client test failed 6 of 8 assertions
and the CLI test failed 2 of 3. After the fix, both focused selectors passed
all 301 assertions, including the 11 new assertions.

The snapshots add copying on the cold evidence path. The existing CLI charge
check still occurs before building/snapshotting a record; acquisition continues
to disable duplicate client retention. This is not an RSS or allocation-budget
measurement, and the change introduces no frame-processing copy.

### PKG-02 — Declared public bindings lack Julia help documentation

Severity: medium. Confidence: observed by runtime reflection and source review.
Disposition: fixed for the inventoried bindings.

At the source revision, 63 of 238 bindings in the root module and its immediately
public modules had no binding docstring according to `Docs.hasdoc`. Missing
entries included all five public `Analysis` bindings, acquisition plans and
timeouts, owner bootstrap operations, several recovery observations, instrument
preparation and calibration extension points, parameter-source protocol types,
session handles/shutdown and simulator management queries.

Added docstrings covering signatures, units, ownership/reused buffers, return
values and lifecycle restrictions as applicable. Optional preparation functions
now have help entries before scientific extensions load. Also declared and
documented the README's callable `CalibrationCLI.main` entry point. The README
explains how to find these contracts in Julia help.

The inventory distinguishes explicitly declared APIs from internal qualified
helpers and exported bindings in internal protocol modules. Documentation
presence alone does not establish completeness or correctness of every existing
docstring. New contracts were checked against implementations and affected
callers; a separate reviewer checked the calibration, instrument and lifecycle
descriptions.

### PKG-03 — Source groups obscure component responsibilities

Severity: low. Confidence: observed. Disposition: fixed.

The user selected removal of both directory names `native` and `owners`.
The final grouping follows existing component roles, without adding new
lifecycle authorities or moving scientific algorithms into the RTC:

| Path | Responsibility and authority |
| --- | --- |
| `runtime/` | C host, Lua session policy and plugins, RTC-ARCH-026 |
| `src/control/` | Codecs, clients, endpoints, admission and source/parameter controls, RTC-DEV-030 |
| `src/correction/` | Correction loops, recovery, supervision and physical offsets, RTC-DEV-032–037 |
| `src/graphs/` | Graph execution entry point and graph supervision, RTC-ARCH-026 |
| `src/simulation/` | AOS simulation entry point and pupil configurations, RTC-DEV-025/026 |
| `src/diagnostics/` | Phase timing capture, RTC-DEV-006 |

Production protocol filenames no longer repeat a `native_` prefix. The deployment compiler
is named `pipewire_configuration.jl` for the format it emits. Includes,
export tests, script lookups, build guidance and active documentation follow
the relocated files. The C/Lua implementation and installed paths are preserved.
Historical dated evidence retains its original path spellings.

### PKG-04 — Public names repeat the selected transport

Severity: low. Confidence: observed. Disposition: fixed; breaking API migration.

The user explicitly selected public API renaming, accepting downstream migration.
Remove `Native` from the 19 Julia module names below. These names denote existing
generic protocol or private implementation roles defined by RTC-ARCH-024,
RTC-ARCH-026 and the operating contract, rather than new scientific concepts.
The qualifier is unnecessary because native local controls are the sole selected
transport. Wire identifiers, profile versions, property names and saved report
fields remain protected external boundaries. No compatibility aliases are added.

| Existing identifier | Accepted identifier | Role and authority |
| --- | --- | --- |
| `NativeControlCodec` | `ControlCodec` | Shared control envelope, RTC-DEV-030 |
| `NativeControlClient` | `ControlClient` | Bounded local control client, RTC-DEV-030 |
| `NativeControlEndpoint` | `ControlEndpoint` | Owner endpoint ingress, RTC-DEV-030 |
| `NativeRunnerCodec` | `RunnerCodec` | Existing runner command profile, RTC-DEV-030 |
| `NativeSessionCodec` | `SessionCodec` | Session control profile, RTC-ARCH-026 |
| `NativeSessionProfile` | `SessionProfile` | Session capability profile, RTC-ARCH-026 |
| `NativeSessionClient` | `SessionClient` | Exact session client, RTC-ARCH-026 |
| `NativeSessionDiscovery` | `SessionDiscovery` | Session listing and verification, RTC-ARCH-026 |
| `NativeOwnerBootstrapCodec` | `OwnerBootstrapCodec` | Owner admission protocol, RTC-DEV-030 |
| `NativeOwnerBootstrapClient` | `OwnerBootstrapClient` | Owner admission client, RTC-DEV-030 |
| `NativeOwnerBootstrapRuntime` | `OwnerBootstrapRuntime` | Cold owner monitor, RTC-ARCH-026 |
| `NativeSourceControl` | `SourceControl` | Existing source lifecycle controls, RTC-DEV-025 |
| `NativeParameterSource` | `ParameterSource` | Parameter-only owner, RTC-DEV-030 |
| `NativeAcquisitionLifecycleCodec` | `AcquisitionLifecycleCodec` | Acquisition ownership protocol, RTC-DEV-029/030 |
| `NativeAcquisitionLifecycleClient` | `AcquisitionLifecycleClient` | Acquisition lifecycle client, RTC-DEV-029/030 |
| `NativeAcquisitionLifecycleRuntime` | `AcquisitionLifecycleRuntime` | Acquisition lifecycle owner, RTC-DEV-029/030 |
| `NativeCalibrationActionCodec` | `CalibrationActionCodec` | Typed calibration actions, RTC-DEV-029/030 |
| `NativeCalibrationActionClient` | `CalibrationActionClient` | Correlated calibration client, RTC-DEV-029/030 |
| `NativeCalibrationEndpoint` | `CalibrationEndpoint` | Calibration action owner, RTC-DEV-029/030 |

Rejected alternatives: preserve redundant prefixes; invent new manager/service
roles; add parallel aliases for the same API. Required validation includes all
maintained callers, generated-source templates, cold package loading, public
help, runtime export and the core suite. Frozen deployment outputs retain their
own package pins and are not rewritten in place.

Downstream source audit found no current direct `PipeWireAORTC.Native*` consumer
in the linked instrument, GUI or shared scientific source checkouts. Legacy
SPIDERSSim examples at `b479871` already use the retired `PipeWireAODeployment`
package and flat source includes. Those pre-existing migration gaps were
recorded rather than partially rewritten; sibling changes and installed
application upgrades are not part of this patch.

The user selected Lua replacement as the next implementation task after this
cleanup. Lua currently implements RTC session policy through libwireplumber
hooks; it is not required by the scientific algorithms or PipeWire transport.
The replacement must preserve the separate filter-graph process. C/Rust owns
strict RT deadlines and work better served by compiled code. Any Julia work on
a deadline-sensitive path requires demonstrated steady-state allocation/GC
behavior. Neither process separation nor a successful functional test proves
those timing and resource properties. This cleanup does not claim Lua removal
or GC/deadline qualification.

### PKG-05 — Follow-up naming audit remains incomplete

Severity: low (maintainability). Confidence: observed. Disposition: open naming
work, identified by the user's subsequent whole-package search on 2026-11-04.
The earlier source/API migration did not complete every naming surface.

The case-insensitive content scan found 22,176 matches in 1,337 of 3,160 searched
files. Most are evidence, protocol terminology or descriptions of compiled
interfaces. Filename inspection separately found 436 paths containing `native`:

| Surface | Observed result | Disposition |
| --- | --- | --- |
| Root `native/`, `src/native/`, `src/owners/` | All absent | Completed |
| Production filenames under `src/` and `ext/` | No paths containing `native` | Completed |
| The 19 retired public Julia module names | No remaining production declarations or uses | Completed |
| Top-level Julia tests | 32 filenames retain `native_` or `test_native_`; several test module names do too | Rename using the existing component names, and update maintained includes/selectors |
| Production module aliases | `CalibrationAcquisition.Native`, `CalibrationCLI.Native`, and extension-local `Native` still alias canonical modules | Remove redundant transport aliases or use their actual component roles |
| Exported protocol classifiers | `native_bootstrap`, `native_heart`, `native_source`, `native_acquisition` in deployment configuration | Remaining rename candidates; select names from their protocol/capability semantics before implementation |
| Private implementation types | `NativeRecoveryTransport` and `NativeInputs` | Review candidates; the former is an actual transport boundary, so a mechanical prefix deletion is not justified |
| Top-level documentation | 62 filenames contain `native`, including current guides and historical reviews/designs | Current navigation needs a naming decision; preserve historical provenance and recorded command paths |
| Test records and dated validation paths | 95 test-data paths and 246 validation paths contain `native` | Preserve records, formats and generated provenance; change their authoring/generation path before any migration |
| Benchmark profile | One recorded profile filename contains `native` | Retain its recorded configuration identity |

The table groups filename counts without double-counting the 95 test-data paths
inside the overall 127 test paths or the 246 validation paths inside 308 docs
paths. It does not classify every English occurrence as an identifier defect.
`native_token`, protocol/profile names, physical native-command units, adopted
dependency APIs and exact historical quotations remain protected boundaries.

Specific remaining locations include `src/calibration_acquisition.jl:12`,
`src/calibration_cli.jl:9`, `ext/calibration_owner.jl:6`,
`src/configuration/deployment_configuration.jl:174–181`,
`src/correction/recovery_client.jl:15`,
`ext/PipeWireAORTCOffsetInputsExt.jl:8` and
`test/test_native_control_codec.jl`. All replacement work must include maintained
callers and explicit filename selectors; examples of recorded old paths are not
live callers.

Adjudication: a missing-helper hypothesis was rejected. Direct source inspection and a fresh package process
confirmed `_figure`, `_fields`, `_integer`, `_rule` and `_valid_result` all exist
in `CalibrationActionClient`. That runtime-defect hypothesis is rejected. The
aliases are naming debt, not demonstrated missing API failures.

This follow-up changed review/navigation documentation only. It did not rename
code, test files, immutable records or historical artifacts. The audit worktree
status was unchanged before those documentation updates; no runtime suite was
rerun for this read-only source audit. Raw inventory is retained in
`/tmp/rtc-native-{all-hits,source-hits,paths}.txt`.

## Type and Julia convention adjudication

- `Dict{String,Any}` at JSON/YAML authoring and report boundaries represents
  heterogeneous documents. Replacing it with a fabricated schema hierarchy is
  not justified by the reviewed contracts. The two retained-record vectors had
  a narrower common entry type and were changed accordingly.
- Most reviewed `isa` checks validate untrusted document values or distinguish
  closed protocol outcomes. They are not evidence of missing multiple dispatch.
  Existing typed calibration actions and results already dispatch by method.
  No broad conversion to dispatch is warranted without an identified contract
  or implementation benefit.
- Bootstrap/observation/pupil task handles are cold lifecycle storage.
  ThreadPinning 1.1.1 delegates `@spawnat` to StableTasks, whose installed README
  explicitly warns against relying on a concrete or version-stable return type.
  Retaining `Any` here avoids depending on a private concrete handle type.
- `Common.metadata_json_value` deliberately suppresses specialization while
  lowering large tuple trees. Its heterogeneous staging buffer is not a reason
  to undo the compiler-memory boundary. No performance defect was established.
- `InitialCalibration.control::Any` participates in an owner/endpoint lifecycle;
  narrowing it requires a separate lifecycle design. Publication and exception
  references in extensions remain candidates for focused investigation, not
  confirmed performance or correctness defects.
- No concrete dependency-placement or compatibility defect was found in the
  root/test projects. Development used Julia 1.13.3; the existing Julia 1.12
  compatibility floor was not changed or newly qualified.
- Formatting is inconsistent in existing compact source sections. No maintained
  formatter configuration or repository formatting gate was found. New prose
  uses conventional Julia docstrings; a repository-wide formatter rewrite would
  need a selected style and its own reviewable change. It is not included here.

## Verification

Focused behavior command (passed, 301 assertions):

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/test_native_calibration_action_client.jl");
include("test/test_calibration_acquisition.jl")'
```

Final API/source checks passed: all 19 new module bindings exist and their old
bindings are absent; the three removed source directories are absent; all 239
inventoried public bindings have help documentation. A fresh Julia/REPL process
rendered plan, preparation and bootstrap help. Markdown structure, final
newlines and all 12 added local links passed checks across 17 changed documents.
`git diff --check` passed.

The relocated runtime configured and built with
`PKG_CONFIG_PATH=/home/dgamroth/.local/opt/pipewireao-compact-metadata-sdk-4.0.0/lib/pkgconfig`
and upstream WirePlumber harness source
`9fbe964c5815380391b469667ad1a448ace67c22`. The cohort supplies PipeWireAO
4.0.0, SPA AO 0.2 and WirePlumber 0.5.18. Existing unused-parameter warnings
remain in unchanged C callbacks and upstream harness code. No installation ran.

```sh
meson setup runtime/build runtime --prefix=/tmp/pipewireao-rtc-cleanup-install \
  --libdir=lib -Dwp_source_dir=/home/dgamroth/workspaces/codex/pipewire/wireplumber
meson compile -C runtime/build
meson test -C runtime/build --print-errorlogs
```

Runtime result: **11 passed, 1 failed**. `ao-session-hooks` aborts at Lua line
266 with `Native hook did not reach expected checkpoint`. An independent build
of untouched source `4658e7f` archived to
`/tmp/pipewireao-rtc-baseline-4658e7f-9GNDT2` reproduced the same focused failure
against the same dependency/harness cohort. A temporary diagnostic identified
the sentinel dispatch checkpoint after interrupted-operation cleanup (line 513).
The cause remains unconfirmed. This failed gate predates the cleanup and remains
open for the session-policy replacement; it is not a passing lifecycle claim.
Logs are retained in the runtime build's `meson-logs/testlog.txt` and the
baseline build's corresponding path. Production code and timing limits were not
changed to obtain a pass.

The final core selector passed with exit status 0: **8,568 assertions across
378 reported testsets**. This includes the renamed-module callers, runtime
export and relocated policy/script checks. The Git `cat-file` diagnostic comes
from the existing corruption test that deliberately removes a content object;
the test confirms the expected `ProcessFailedException`.

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/runtests.jl")'
```

The raw output is retained at `/tmp/pipewireao-rtc-cleanup-final-core.log`.
No installed service, device or existing private core is selected by these
commands. The core selector uses the explicitly selected native artifact prefix
and its own test-owned resources. Optional scientific/backend, installed
application, hardware and deadline/GC qualification were not performed.

Independent final source review found no blocking issue in the snapshot fix,
renames, regression coverage or assigned documentation. It confirmed preserved
wire/document shapes and the existing retention-budget boundary. Primary
verification of the complete diff, public help, source paths, documentation and
required core suite also passed. The separate runtime failure above remains open.
