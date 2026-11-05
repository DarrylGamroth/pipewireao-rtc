# MediaSession migration evidence — 2026-11-04

## Scope and baseline

Implementation continues from `a0e47d2` on
`codex/julia-session-policy-20261104`. The user selected removal of both Lua and
libwireplumber, using public PipeWireAO.jl APIs, and requested a Julia module in
its own directory. Terminology follows upstream media-session, inspected at
`7376c167f1ad20b3968d7a5d6c395a8b698d31d8`, with Julia naming conventions.
The module is `MediaSession` in `src/media_session/`.

RTC-ARCH-024/026 retain one RTC application authority and a separate scientific
graph process. The [migration plan](../../SESSION_POLICY_MIGRATION.md) records
the requirement closure. The replacement is not yet integrated or qualified.

## Pure lifecycle and control slice

Observed: `test/test_media_session.jl` passes 507 assertions. The Hsm implements
prepare/warmup/admit, queries, groups, start/stop/reset, all-managed-state Quit,
source-first fault compensation, exact effect correlation, cancellation fencing
and bounded reply/cancellation slots. Opaque effect completion means the backend
has already validated native evidence; the machine does not fabricate successful
native effects. Source completion uses a typed `SourceEnd` observation.

Observed at the initial slice: `test/media_session_controls.jl` passed 67
assertions for owner and source semantics, correction/recovery admission,
scalar property transactions and sparse parameter submission. The adapters use
existing native codecs and preserve request/receipt correlation. These tests
use controlled I/O boundaries; they do not qualify live transport.

The renamed module and both selectors were loaded together in a fresh Julia
1.13.3 process; all 574 assertions passed with exit status zero. No `Any` fields,
`isa` branches or field-presence type selectors were added to these sources.

## Consistent interfaces and clocks

User decisions are recorded in the package-wide
[Julia design conventions](../../architecture.md#julia-design-conventions).
Commit `5f7ac7b` records interfaces, traits, hierarchy, ownership, clock units,
terminology and formatting rules. Commit `c8c8b16` applies `Abstract` prefixes to
local abstract types and updates callers without compatibility aliases. Focused
control, bootstrap, acquisition, calibration, recovery and optical selectors
passed; the root reran the 23-assertion control client selector. This does not
qualify the optional graph worker against a live core.

Commit `aaaa690` replaces generated Hsm declarations with explicit types and
hierarchical handlers, derives operations from codecs, uses
`RunnerCodec.Lifecycle`, and uses direct signed Clocks nanoseconds. The same
machine selector passes 553 assertions: the prior 507 and 46 clock/interface
checks. Negative clock origins, checked deadline overflow and one-nanosecond
boundaries are covered. `budgeted(::AbstractEffect)` expresses the independent
deadline property; emergency disconnection has no scientific-operation budget.

The control adapter selector now passes 95 assertions. Source bindings are
`AcquisitionBinding` and `SourceControlBinding` behind `AbstractSource`; names
describe their public protocols. Instrument-specific profile code was removed.
Run/reset builders and parsers reuse PipeWireAO's public interface. All internal
deadlines and freshness comparisons use signed nanoseconds; conversion to
seconds occurs only at the existing ControlClient observation/reply interface.
Read-only status requests do not mark the scientific effect as submitted.
The three read-only regression failures were reproduced against the initial
slice before the fix. These remain controlled-I/O software checks.

| Finding | Classification | Disposition |
| --- | --- | --- |
| HSM-S01 — expired source Hold cancels emergency Disconnect | Confirmed by independent cached-clock reproduction | Fixed: transport teardown has an unbudgeted terminal path; later Tick/loss events cannot revoke it; same reproduction and 36 boundary checks pass |
| Quit acknowledgement cannot be fenced before publication exists | Confirmed source-ordering mismatch | Publish the accepted Offline reply before the final sync/disconnect effect; failure/expiry preserves the accepted outcome; 70 disposition checks pass |
| First control-event compilation can exceed five seconds | Observed integration risk | Main must warm the actual production machine/event types before exposing the native endpoint; real deadline qualification remains open |

Independent review inspected cancellation, hierarchy-specific expiry, fault
uncertainty and Quit fencing. No further blocking pure-machine defect was found.
Backend qualification must still prove cancellation drain before replacement,
exact native identity/format evidence and withdrawal while creation is pending.

## Native loop support

PipeWireAO.jl commit `2a95e74` provides owner-thread bounded nonblocking `iterate!` and
`enum_params!(...; sequence_out=Ref{Cint}())`. Existing enumeration callers still
receive the object. The returned native sequence, rather than the caller's
requested sequence, correlates parameter events through a core sync fence.
One native loop iteration can dispatch several callbacks; its count is not a
callback-count or time bound.

Observed upstream verification: 2,240 assertions across 75 printed testsets,
including 42 focused checks against the isolated native 4 SDK. Generated bindings,
dependencies and version are unchanged. Logs are
`/tmp/pipewireao-session-api-suite-20261104.log` and
`/tmp/pipewireao-session-api-focused-final-20261104.log`.

The discarded libwireplumber bridge experiment is preserved at `24ad2e9` on
`codex/libwireplumber-bridge-evaluation-20261104`. Its six native/sanitizer cases
do not qualify the selected direct-PipeWire implementation.

## Independent backend review

The independent review began at `aaaa690` plus the uncommitted direct object,
transport and journal adapters, in the dedicated migration worktree. It checked
the RTC-DEV-003/004/021/025/022 closure obligations in the migration plan. The
following findings were independently reproduced and adjudicated before fixes.
Confidence is high for the demonstrated software behavior; these findings do
not establish a hardware or timing qualification result.

| Finding | Severity and evidence | Disposition |
| --- | --- | --- |
| MSR-001 — Link withdrawal discards owner identity captures | P1, confirmed. A captured control node passed identity validation before `remove_links!`; successful withdrawal emptied all captures, and the following owner check failed with `object is not captured`. The machine next issues source and owner Shutdown effects. | Fixed: withdrawal retains the remaining captures after the native Link absence fence. A regression checks that the same captured control endpoint remains valid through withdrawal. No fresh recapture substitutes for the original identity. |
| MSR-002 — Acknowledged owner retirement is treated as unexpected loss | P1, confirmed. Removing a captured owner always emitted RequiredLost; during ordered shutdown that event enters Fault. The adapter had no receipt-proven retirement handoff. | Fixed with `retire_owner!`: a validated bootstrap Quit receipt, matching declaration and native ClientInfo provenance authorize exact cohort retirement. Exact global-ID/serial targets remain for absence checks. Unacknowledged, foreign and shared-client captures retain loss detection. An acquisition Shutdown receipt cannot retire an entire process. Root effect integration must call this handoff and enforce the final absence fence. |
| MSR-003 — Preparation can consume the fresh transport deadline check | P1, confirmed. An injected clock advanced to the effect deadline during identity validation; `setparam!` still invoked the native send after its earlier fresh-time check. | Fixed in transport: a final `check_job` runs immediately before enumeration or parameter submission, after identity, object and parameter preparation. The same injected-delay reproduction now refuses the send. An already-set submission marker remains conservative; the fix does not erase earlier cohort mutations. |
| MSR-004 — Created Link admission omits LinkInfo ID correlation | P2, confirmed validation gap. Otherwise-valid LinkInfo ID 32 was admitted for bound ID 31. A sparse merge could also conceal a later raw event's changed ID by retaining the previous ID. A real native corruption trigger was not established. | Fixed: raw LinkUpdated events are checked before merging, LinkBound is checked against any earlier info, and validation compares the known bound ID. Tests cover both callback orders, changes after a valid observation, valid same-ID events and first-failure retention. |
| MSR-005 — Link withdrawal suppresses unrelated required losses | P1, confirmed by the same controlled observations before/after. `runtime.withdrawing` suppressed every required-loss report and skipped captured identity checks. Graph removal, graph errors, identity changes and a foreign Link's removal were hidden. | Fixed: loss events always reach the machine; only destruction/error observations of an exact retiring session-created Link `(ID, serial)` are expected. Captured identity validation remains active. A copied path does not confer retirement. Required owner/graph evidence is retained until its separate receipt-proven handoff. |
| MSR-006 — Property adapters discard the Hsm's admission origin | P2, confirmed interface mismatch. The machine records Ready/Running origin in the effect ticket, but adapters reread mutable lifecycle to decide correction admission and active adoption. Opposite-origin controlled cases reproduced four failures. | Fixed: `perform!` passes the ticket origin; property baseline/completion and correction/recovery guards dispatch on `ReadyOrigin` / `RunningOrigin`. Native owner, group, value and generation proofs remain required. No new phase trait or second state machine was introduced. |
| MSR-007 — Final/emergency close retains created Link handles | P1, confirmed on a private core. Registry bindings closed, but distinct session-created Link proxies remained; Core close refused those live handles. | Fixed: shared best-effort transport cleanup closes created listeners/proxies before bound objects/endpoints/Core, preserves failed resources and aggregates failures. Disconnect completes only after actual Core closure; final close owns Context/MainLoop. Separate-peer resources survive with their exact identities. |
| MSR-008 — Terminal ingress publishes through a disconnected endpoint | P2, independently confirmed. A real mapped native request reached emergency Disconnect, then `drain!` attempted `update_params!` on the closed Filter. The same test failed twice, including receipt-driven journal publication. No durable-data loss was established. | Fixed: only `PublishRecords` skips an actually closed endpoint. Reply correlation and journal actions still drain; open-endpoint publication errors remain visible. No wire delivery is claimed after transport retirement. |

Observed verification: the object selector passes **103 assertions**, including
16 against an isolated private core and 11 Link-ID regression assertions. The
same 11 assertions against the saved pre-MSR-004 source produced seven failures;
they all pass after the fix. Existing pending-creation withdrawal, native sync
and absence checks still pass. Object-selector host deadlines now use direct
Clocks signed `Int64` nanoseconds, including the private-core polling loop.

```sh
julia --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/media_session_objects.jl")'
```

The MSR-004 logs are `/tmp/media-session-msr004-before.log` and
`/tmp/media-session-msr004-after.log`; the saved pre-fix source is
`/tmp/media-session-objects-before-msr004.jl`. The MSR-003 discriminating script
is `/tmp/rtc-msr003-deadline.jl`; before the fix it reported
`send_at_expired_deadline=true`, and after the fix it reports `false` with an
expiry refusal. The persistent object regressions retain the MSR-001/002/004
invariants independently of these temporary artifacts.

MSR-005 adds nine contract assertions: four failed and three dependent assertions
errored on empty loss collections before the fix; all nine pass afterwards.
The whole selector passes, including the existing 16 private-core checks and
pending-creation, native sync and exact absence fences. Logs are
`/tmp/media-session-withdrawal-before-20261105.log` and
`/tmp/media-session-withdrawal-after-20261105.log`. The implementation uses
concrete `Object{P,LinkInfo}` dispatch to identify Link evidence; it adds no
phase-dependent logic to the event loop.

The complete control selector passes **186 assertions** and the effect selector
passes **64**. The unchanged property-origin regression went from two passing /
four failing assertions to six passing assertions. It checks that a Ready
ticket reports submission without active adoption and a Running ticket waits
for exact adoption, regardless of the opposite mutable wire status; each
submits once. Additional correction/recovery cases retain stopped group and
native owner rejection. Logs are `/tmp/rtc-correction-origin-before.log`,
`/tmp/rtc-correction-origin-after.log`, `/tmp/rtc-correction-origin-effects.log`
and the root rerun `/tmp/rtc-typed-session-effects-20261105.log`.

No additional journal defect was confirmed in this review. PipeWireAO publicly
provides `InfoTracker`, `track_info!`, `has_current_info` and `current_info` for
Node/Port/Device/Link snapshots, but no public callback-free merge operation or
Client/Factory tracker. Reuse must preserve every Link observation: reading only
the latest snapshot after a pump could hide a bad event followed by a good one.
Sparse-merge duplication is an interface ownership concern, not an additional
established failure of the currently consumed RTC fields.

## Management companion dependency removal

The selected source tree now retires 31 files belonging exclusively to the old
WirePlumber host, modules, Lua policy and their implementation-specific tests.
Git retains their implementation history. Generated build outputs, frozen
evidence, protocol inputs and scientific integration selectors are preserved.
The independent management-only Meson build and its native JSON test still pass
after source retirement. Old policy unit receipts do not qualify the replacement.

Observed: the independent C management helper used libwireplumber only for its
JSON utility. It now uses json-c 0.18 or newer and the existing GLib/GIO Unix
interfaces. The selected Meson build creates only the management companion and
its test helpers; it does not build or install the retired session executable,
plugins or scripts. The Julia launcher is generated separately. This does not
add another session authority.

Observed software verification: the unchanged management IPC selector passes
150 assertions covering peer credentials, descriptor transfer, worker lifetime,
durable acceptance, bounded capacity, no replay and crash-to-unknown behavior.
Five native JSON test groups pass with warnings treated as errors, and under
ASan/UBSan with leak detection. An old-helper/new-helper comparison passes 21
checks for numeric, Unicode and receipt compatibility. The root independently
reviewed ownership/type checks and reran configuration, compilation and the
native tests after removing the unused build option.

UInt64 identities and floating-point token spellings are preserved. Duplicate
decoded keys now reject at every object depth; integers outside −2⁶³ through
2⁶⁴−1 reject. JSON whitespace, Unicode escapes and integer `-0` may normalize.
Receipt identity, rather than a digest of request serialization, prevents replay.
The existing lexical validator remains necessary: an isolated json-c 0.18 probe
rejects valid non-ASCII input with its strict flag, whereas ordinary parsing
accepts it. The production path validates strict syntax, depth, NUL exclusion,
UTF-8 and decoded-key uniqueness before invoking the library parser.

Logs: `/tmp/rtc-management-json-endpoint-20261105.log`,
`/tmp/rtc-management-json-golden-20261105.log`, and the `meson-logs/testlog.txt`
files under `/tmp/rtc-management-json-build-20261105` and
`/tmp/rtc-management-json-asan-20261105`. No service or installation changed.

## Maintained tool and type-selector cleanup

The implementation-specific `session_items.jl` and `session_policy_faults.jl`
integration selectors were retired with links to their Git history. Their
frozen protocol/test inputs and dated receipts remain unchanged. Valuable
scientific, lifecycle, fault and exact-cleanup selectors remain. Their shared
`runtime_cohort` helper replaces old WirePlumber/Lua asset hash requirements
with the sealed generated launcher, selected Julia/project/Manifest and exact
live process binding. Harness MediaSession source hashes are explicitly
separate: a package pin or harness checkout does not prove a child's loaded
source hash. Cold checks pass 125 assertions, including 27 new cohort checks,
and lifecycle/CAL2/shutdown selectors load without invoking live methods.
The process verifier's positive boundary is injected in these cold helper tests;
the generated-process selector separately checks actual `/proc` verification.
Log: `/tmp/rtc-session-receipt-cold-final-20261105.log`.

Retained `deployment/wireplumber` observer/realization probes are a separate
development product. No selected RTC Meson target, export or core-test caller
requires their Lua files. They are not another RTC session authority or an RTC
Lua/libwireplumber dependency.

The three standalone private-core graph providers now dispatch their expected
PipeWire EPIPE classification on `PipeWireError`; unrelated errors still
propagate and the existing RTC-unloaded marker remains required. Twelve direct
checks cover matching operation/code, a different operation/code and a non-native
exception. Each provider is copied and launched independently, so its two small
predicate methods remain local; introducing a shared include would change the
sealed launch closure. These checks do not run a graph or qualify shutdown.

The unreferenced `scripts/prepare_calibration_lamp.jl` tool was retired. A fresh
package load confirms all three of its entry dependencies (`Deployment`,
`HILExport`, `CalibrationCampaign`) are absent. It could not execute against the
current API. Its instrument-specific sealed-plant rewriting remains in Git
history; it was not silently remapped to new scientific APIs. The maintained
package scripts and runtime sources contain no `isa` or `@eval` selectors after
this cleanup. Frozen evidence, protocol data and independent historical probes
retain their original content.

## Direct owner, launcher and native lifetime integration — 2026-11-05

The host now supplies the Agent duty cycle, bounded callback observations,
correlated effect result slot, controller admission, journal actions and public
native endpoint. All Hsm dispatch and PipeWire resource mutation stay on the
session's opening OS thread. A separate journal worker owns SQLite. The cache is
sampled once per duty cycle; transport submission still checks the fresh source
clock. No graph scheduling, data-thread priority or installed service changed.

The generator emits only the direct PipeWire context and `pipewireao.session`
policy. Its packaged shell launcher executes the selected Julia binary/project
with shared canonical arguments. Saved process bindings are checked after JSON
round-trip against `/proc` executable/arguments. Removed native build-selector
keywords and WirePlumber staging APIs have no compatibility aliases.

Observed checks on Julia 1.13.3:

| Selector | Observed result and boundary |
| --- | --- |
| Configuration / installed launcher / stop / auxiliary-source cohort | 75 + 26 + 12 + 30 assertions pass. No installation, service or device is started. |
| `media_session_process.jl` | Eight assertions pass with the actual generated shell launcher, separate Julia process and test-owned private core: saved binding, tampered binding rejection, Configuring Warmup/Status/Groups, accepted Offline Quit and exit zero. This cancels incomplete startup; it is not full Ready/Run science admission. |
| `media_session_private_core.jl` | 42 assertions pass: native discovery/coalesced controller publication, startup cancellation, active and not-yet-pumped created Link release, exact separate-peer resource preservation, actual Core closure before emergency completion, and best-effort continuation after a bound-object close failure. |
| `media_session_acquisition_private_core.jl` | 35 assertions pass using real AcquisitionLifecycleRuntime/native envelopes with controlled Status/Shutdown handlers: first Preparing, repeated Preparing and Prepared cleanup; no fabricated cursor, Pause or Connect; one acknowledged Shutdown. Production scientific preparation is outside this selector. |
| `media_session_host.jl` | 53 assertions pass after independent host review: real native request/controller ingress, emergency closure with mapped replies, durable requested/unknown rows with exact terminal POD bytes, and accepted Quit publication failure/expiry plus late callbacks. Scientific failures are injected; this is not an actual graph fault run. The unchanged test previously passed 51 and failed two on closed-Filter publication. |

The owner tests require the local PipeWireAO 0.9.1 command-endpoint source cohort
with public `iterate!`/enumeration sequence APIs, matching native4 SDK
`/tmp/pipewire-command-endpoint-native4-sdk-20261104`, and
`/tmp/pipewireao-rtc-optical-types-env`. The registered 0.9.0 client lacks the
owner-thread pump; there is no private-layout fallback. The optional selectors
run with `--threads=2,1` and an explicit matching `PIPEWIREAO_PREFIX`.

The lifetime test failed before the fix: created Link proxies remained open,
and Core close refused them. The shared transport cleanup now detaches listeners,
closes every created handle and bound object, then closes endpoints/registry/Core;
failed resources remain available for final cleanup. Context/MainLoop lifetime
remains with final `close`. `main` preserves a primary `serve!` exception before
any cleanup exception. Logs are
`/tmp/rtc-session-resource-close-before-validated-20261105.log`,
`/tmp/rtc-session-resource-close-formatted-20261105.log`,
`/tmp/rtc-acquisition-after-transport-close-20261105.log` and
`/tmp/rtc-media-session-generated-process-20261105.log`.

Cold compilation initially crossed the unchanged five-second cleanup bound.
Separately, unchanged controller facts caused a publication feedback loop:
8,926 publications in a nine-second probe became four after exact fact
coalescing. That fix alone did not resolve the cold deadline. Compiler timing
showed first-use dispatch dominated the long spans. Shared typed effect receipts
removed ticket-parameter specialization from result delivery; bounded offline
dispatch preparation before public endpoint connection compiles cleanup without
executing native or scientific effects. The strict first cold acquisition Quit
then completed in 2.108 seconds, with repeated Preparing/Prepared cases in
0.063/0.070 seconds. The formal 35-assertion selector also passes in a fresh
process. These finite observations do not establish worst-case or tail latency.
The proposed missing-MainLoop-entry cause was independently probed and not
confirmed; no loop-entry workaround was added. Timing logs retain the failed
attempts under `/tmp/rtc-cold-acquisition-*20261105*`.

The independent host review found no additional terminal-hook defect after
MSR-007/008. Matching PublishQuit completion, failure or expiry ends the process
after the already accepted Offline outcome. A retired Disconnect does not end
it: a new Quit may preempt emergency cleanup and owns the replacement effect.
Terminal host logs are `/tmp/rtc-media-session-host-before.log` and
`/tmp/rtc-media-session-host-after.log`.

## Package formatting and verification — 2026-11-05

The shared formatter is JuliaFormatter 2.14.8 BlueStyle with the explicit
repository configuration, four-space indentation, a 92-column margin and up to
three iterations to reach a fixed layout. DefaultStyle 2.14.8 preserves mixed
operator spacing; the earlier DefaultStyle pass did not resolve that inconsistency.
The final profile normalizes operators and `for ... in` while disabling optional
syntax rewrites, keyword restructuring and implicit `Any` field annotations.
Ten bare early returns in seven authored files now explicitly return `nothing`.
Their scopes were reviewed; no `nothing` binding is shadowed.

The initial final-profile cohort checks 406 authored Julia files, with 384
changed and conditional layouts expanded in 32 files. Every output is
idempotent. Comparison against the committed source plus the ten explicit early
returns preserves branch conditions/results, call order, quoted expressions
and literal values. This comparison normalizes single-expression condition/
branch blocks and `if`/`elseif` layout; it is branch-structure equivalence,
not a claim of byte-identical ASTs. Generated files and immutable evidence are
excluded. No scientific coefficient, threshold or declaration was retuned.

After formatting, the session machine/control/effect/ingress/transport/object
cohort passes 1,179 assertions. The warmed Hsm selector passes 17 checks and
measures zero heap bytes for each 1,000-cycle nominal loop, recovery, coupled
recovery and preparation path. This is scoped allocation evidence; the cold
MediaSession host is not an allocation-free/GC-independent real-time callback.
Logs: `/tmp/rtc-spacing-apply-20261105.log` and
`/tmp/rtc-formatted-hsm-cohort-20261105.log`.

The official core command exits zero. Its log prints 486 passing summary rows
and 10,806 assertions including the separate journal child selector. The first
run stopped on an obsolete `wireplumber.components` expectation in the
instrument-publication test; that test now checks the direct policy publication
and exclusion from other nodes. Its focused selector and the complete rerun
pass. Logs: `/tmp/rtc-core-suite-20261105.log`,
`/tmp/rtc-instrument-publication-20261105.log` and
`/tmp/rtc-core-suite-rerun-20261105.log`. This full run predates the subsequent
private-ledger version migration, which has its own focused checks.

## Remaining integration gate

Full graph Ready/Run/Stop/Reset and fault qualification on newly built sealed
applications remains open. Existing sealed/installed applications, services,
devices and graph threads are unchanged. No hardware, strict deadline,
tail-latency, GPU or sustained-cadence claim follows from these software slices.
