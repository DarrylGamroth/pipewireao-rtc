# Naming cleanup completion — 2026-11-04

Status: implementation and software verification complete.

## Scope and naming authority

The user authorized completion of the follow-up naming audit before Lua work.
Work continues in `pipewireao-rtc-cleanup`, branch
`codex/package-cleanup-20261104`, based at
`4658e7f676c538df01c919b4902c9df25a63a105`, preserving 240 existing changed paths.
The subsequent user request extends this increment to type dispatch throughout
maintained Julia source and extensions. Scientific algorithms, lifecycle rules,
wire records, saved fields, installed processes and upstream sources retain
their existing semantics.

Disposition: the remaining naming work recorded as
[PKG-05](../20261104-package-cleanup/REVIEW.md#pkg-05--follow-up-naming-audit-remains-incomplete)
is delivered in this increment. The earlier audit remains an unchanged record
of the source it inspected.

RTC-ARCH-024/026 and RTC-DEV-029/030 establish the existing component/protocol
roles. The source modules and adopted public interfaces identify the narrower
private responsibilities. This preflight records the accepted names before
source changes; no compatibility aliases are introduced.

| Existing identifier | Accepted identifier | Meaning and authority |
| --- | --- | --- |
| Acquisition/CLI `Native` alias | `ActionClient` | Existing CalibrationActionClient; distinguish it from ControlClient |
| Calibration extension `Native` alias | `Endpoint` | Existing CalibrationEndpoint module |
| `native_bootstrap` | `uses_bootstrap_protocol` | Exact `bootstrap-protocol` profile selection, OwnerBootstrapCodec |
| `native_heart` | `uses_heart_protocol` | Exact HEART `control-protocol` selection; unchanged external HEART boundary |
| `native_source` | `uses_source_control_protocol` | Exact SourceControl profile selection |
| `native_acquisition` | `uses_acquisition_protocol` | Existing calibration/correction lifecycle profile group, AcquisitionLifecycleCodec |
| `NativeRecoveryTransport` | `SessionTransport` | RecoveryTransport implementation over SessionClient.Connection |
| Offset extension `NativeInputs` | `StreamReceiver` | Live receiver supplied by PhysicalOffsets.with_receiver over HIL array streams |
| `native_*.jl`, `test_native_*.jl` | Component filename without redundant qualifier | Existing component source and test roles |
| `test_native_configuration.jl` | `test_pipewire_configuration.jl` | Existing PipeWire configuration compiler |

Test module aliases follow their actual canonical module or existing component
role. Physical native-command units, `native_token` and other saved fields,
PipeWire/C APIs, frozen protocol/profile names, historical commands and evidence
paths remain unchanged. Generated records require their authoring/generation
path before any future migration; this work does not move them.

Historical/data hashes are captured before implementation in
`/tmp/rtc-naming-cleanup/protected-sha256.tsv`. The test filename mapping is
`/tmp/rtc-test-name-mapping.tsv`. Current guide moves and final validation results
are recorded below.

## Delivered names and migration

The 32 top-level test selectors drop `native_` or `test_native_`; the
configuration compiler selector becomes `test_pipewire_configuration.jl`.
Static includes, generated suite selectors, helper imports and maintained test
commands follow those paths. The shared private-core helper is now
`test/control_private_core.jl`. Test aliases use the component's canonical
module. Private fake-connection names describe their connection role.

The following current guides move together with their maintained navigation:

| Previous guide | Current guide |
| --- | --- |
| `NATIVE_CONTROL_MIGRATION_DESIGN.md` | [CONTROL_MIGRATION_DESIGN.md](../../CONTROL_MIGRATION_DESIGN.md) |
| `NATIVE_SUPERVISOR_CONTROL.md` | [SUPERVISOR_CONTROL.md](../../SUPERVISOR_CONTROL.md) |
| `NATIVE_SESSION_DISCOVERY.md` | [SESSION_DISCOVERY.md](../../SESSION_DISCOVERY.md) |
| `NATIVE_OWNER_BOOTSTRAP_DESIGN.md` | [OWNER_BOOTSTRAP_DESIGN.md](../../OWNER_BOOTSTRAP_DESIGN.md) |
| `NATIVE_CALIBRATION_ACTION_CONTROL.md` | [CALIBRATION_ACTION_CONTROL.md](../../CALIBRATION_ACTION_CONTROL.md) |
| `NATIVE_ACQUISITION_LIFECYCLE_HELPERS.md` | [ACQUISITION_LIFECYCLE_HELPERS.md](../../ACQUISITION_LIFECYCLE_HELPERS.md) |
| `NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md` | [ACQUISITION_LIFECYCLE_CONTROL.md](../../ACQUISITION_LIFECYCLE_CONTROL.md) |
| `NATIVE_CONTROL_ENVELOPE.md` | [CONTROL_ENVELOPE.md](../../CONTROL_ENVELOPE.md) |
| `NATIVE_RUNNER_CONTROL.md` | [RUNNER_CONTROL.md](../../RUNNER_CONTROL.md) |
| `NATIVE_HEART_CONTROL.md` | [HEART_WRAPPER_CONTROL.md](../../HEART_WRAPPER_CONTROL.md) |
| `LIVE_CONTROL_NATIVE.md` | [SIMULATOR_CONTROL.md](../../SIMULATOR_CONTROL.md) |

Historical commands and evidence links retain their recorded spelling. For a
historical `test/native_X.jl` command, run `test/X.jl` in this source cohort;
likewise replace `test/test_native_X.jl` with `test/test_X.jl`, except the
configuration selector described above. Historical Rust test names and external
retired-client API selectors remain unchanged. There are no compatibility
aliases for the renamed public classifiers. Downstream callers must adopt the
four `uses_*_protocol` names in the table above. The compiled-source export
keyword `native_source` retains its meaning and spelling.

## Type dispatch

The source audit found 592 lines containing `isa` across `src/` and `ext/`.
The completed source has none. Typed methods now select representation-specific
parsing, validation, command replies, cleanup, scientific preparation and
publication. Common code retains the actual operations; error fallbacks preserve
the admitted types, validation order and error text. Boolean/integer and
String/AbstractString distinctions remain explicit where the boundary previously
made those distinctions. Genuine scalar identity comparisons remain unchanged.

`RunnerScalar{T}` stores its exact scalar representation. `FITSBinding{T}`
preserves its element type through `Type{T}`. Existing parameterized graph,
measurement, command-coordinate, observation and procedure types remain the
selection interfaces. No replacement `typeof(x) <: T` selectors were introduced.
Heterogeneous JSON dictionaries and compilation-budget annotations retain their
existing cold-boundary role. This is not a claim that all `Any` storage has been
removed or that arbitrary Julia execution is allocation-free.

The source count excludes type assertions in tests and legacy standalone tools.
An exploratory include of `scripts/prepare_calibration_lamp.jl` fails on its
pre-existing `PipeWireAORTC.Deployment` reference; it also names retired
`HILExport`/`CalibrationCampaign` APIs. The script is unchanged. It is not a
maintained package entry point or a passing calibration gate in this increment.

The new `ext/optical_execution.jl` keeps AOS-dependent typed methods inside the
optional scientific loading boundary. Standalone numerical selectors continue
loading without AOS. Runtime source export already copies the extension source
directory, including this file.

## Verification evidence

The fresh final core suite passes **9,660 assertions across 429 testsets**,
exit status 0. This includes the added control dispatch boundary selector.
The `git cat-file` diagnostic is expected from the store test that deliberately
removes a loose Git object and asserts retrieval failure. No test failures or
unexpected core warnings remain.

Final static checks parse all 377 Julia source/extension/test files, resolve the
maintained local navigation targets, preserve requirement identities in all
11 moved guides and pass `git diff --check`. All worker/reviewer source-hash
manifests match the final source. Root `native/`, `src/native/` and `src/owners/`
are absent. The renamed test selectors have no remaining `native_` filenames.

Observed focused results, before the final whole-suite run:

| Cohort | Passing checks |
| --- | ---: |
| Renamed test selectors (11 files, 22 sets) | 968 |
| Control/calibration/correction selectors | 2,767 |
| Added control dispatch boundary selector | 89 |
| Control-worker deployment selectors | 998 |
| Data/configuration/instrument selectors | 2,297 |
| Deployment-profile selectors | 694 |
| Management/store/simulator selectors | 185 |
| Optical, publication, detector, reference and cleanup | 419 |
| Classic parameter sources and projections | 107 |
| GPI cold loading and AOS boundaries | 92 |
| Graph configuration, materialization and optional feedback | 284 |

These cohorts overlap; they must not be added into a unique suite total.
Snapshot comparisons also preserve exact results or exception class/message:
capture 1,770; deployment authoring/queue metadata 534; artifacts 175;
deployment profiles 569; optical graph configuration 159; management/store 175.
The optical oracle preserves all 378 numerical/report/identity/FITS/bundle
records byte for byte, SHA-256
`fa7e0931599e291b32577011862b30f70201cb2c70b4444975c8db1d25757550`.

The initial integration attempt exposed an over-broad naming replacement of the
legitimate `stage_rtc!(...; native_source=...)` keyword. Restoring that keyword
resolved the installed-export failure; fresh focused reruns pass. The optional
feedback test initially lacked direct `FilterGraphIsland` in the core project;
its rerun in the declared optional environment passes 70 assertions. Neither
failure is removed from the session logs. Optional runs emitted dependency-cache
build-ID warnings; passing software tests do not establish deadline or hardware
qualification.

All 2,495 protected historical/evidence/data files match the SHA-256 snapshot
taken before this increment. The separately checked live evidence index changes
only navigation to the moved guides and the new increment entry; its existing
evidence descriptions match the snapshot after those navigation edits are
normalized. Existing generated records were neither authored nor migrated.
Lua replacement remains the next separately authorized task.

Independent read-only review found no actionable regressions in the root
serialization/configuration/CLI changes or the selected control, profile,
artifact and influence-function boundaries. The CLI review compares 3,370
constructed reply/check combinations against the previous guards, preserving
returns or exception class/text. Its expanded ambiguity check found none.

Final calibration-worker private-core verification passes 97 assertions, plus
99 projection prerequisite assertions. The source-owned P/Q receiver passes
23 assertions in a fresh process. An initial combined invocation passed the
worker and the receiver's behavior checks but violated the receiver's explicit
no-graph-package-loaded assertion; the isolated rerun corrects the invocation.
No source change was needed for that test-process isolation failure.

Reproduction uses Julia 1.13.3. The core environment retains registered
PipeWireAO 0.9.0 and selects its artifact explicitly:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
```

Private-core checks use the optional environment and matching rebuilt SDK from
the [worker source cohort](../20261104-calibration-worker/REVIEW.md), in separate
Julia processes:

```sh
OPENBLAS_NUM_THREADS=1 PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104 julia --startup-file=no --threads=4,1 --project=/tmp/pipewireao-rtc-optical-types-env test/calibration_worker.jl
OPENBLAS_NUM_THREADS=1 PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104 julia --startup-file=no --threads=3,1 --project=/tmp/pipewireao-rtc-optical-types-env test/physical_offset_inputs_private_core.jl
```

Session logs and source manifests are retained under `/tmp/rtc-naming-cleanup/`,
`/tmp/rtc-*-dispatch*`, `/tmp/data_dispatch*`, `/tmp/data-dispatch*` and
`/tmp/deployment-dispatch*`. These temporary paths describe this session rather
than a portable released SDK. No service, live application, physical device or
accelerator was started or changed by these checks.

## Committed checkpoint — 2026-11-04

The user requested commits before further implementation and incremental commits
as subsequent changesets pass verification. Repository guidance now records that
workflow. The accumulated Julia changes share source files and interfaces, so
their verified implementation is committed together; the runtime relocation and
documentation are separate changesets.

| Repository / branch | Commit | Change |
| --- | --- | --- |
| Native PipeWireAO / `codex/ndarray-command-endpoint-native4-20261104` | `c34dc252b` | Borrowed owner-loop accessor and native tests |
| PipeWireAO.jl / `codex/filter-command-endpoint-20261104` | `e57fa07` | Typed command receiver roots, following endpoint commit `a7b46ae` |
| JuliaFilterGraph / `codex/filter-command-endpoint-20261104` | `07f08a9` | PipeWireNode command endpoint and optional live Parameter Ports |
| RTC / `codex/package-cleanup-20261104` | `85233dd` | Runtime directory relocation and its maintained references |
| RTC / `codex/package-cleanup-20261104` | `0b13727` | Verified Julia source, dependency and test migration |

The documentation checkpoint follows these implementation commits. Committing
does not alter the tested source or publish packages/artifacts. The registered
native artifact release remains a separate delivery boundary.
